#!/usr/bin/env bash
# Will this issue pass preflight? Answer it BEFORE spending a run finding out.
#
# preflight.sh refuses to start on an issue whose Acceptance criteria section it
# cannot parse, and the refusal arrives at the top of a red run. That is the
# right place to enforce it and the wrong place to learn it: by then you have
# pressed the button, waited, and read a log.
#
# So the same parser is available here, on text you can paste. It is literally
# the same function -- acceptance_items() in common.sh -- because a checker that
# disagreed with the gate would be worse than no checker.
#
# Usage:
#   avengers-12/lib/check-issue.sh <file>        check a file
#   pbpaste | avengers-12/lib/check-issue.sh     check what you just copied
#   avengers-12/lib/check-issue.sh --issue 36    fetch it from GitHub (needs gh)
#
# Exit 0 when the issue would be accepted, 1 when it would be refused.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

BODY=""
case "${1:-}" in
  --issue)
    ISSUE="${2:?--issue needs a number}"
    require_cmd gh
    BODY="$(gh issue view "$ISSUE" --json body --jq .body 2>/dev/null)" \
      || die "cannot read issue #$ISSUE (is gh authenticated for this repo?)"
    printf 'issue #%s\n\n' "$ISSUE"
    ;;
  ""|-)
    BODY="$(cat)" ;;
  *)
    [[ -f "$1" ]] || die "no such file: $1"
    BODY="$(cat "$1")" ;;
esac

ITEMS="$(printf '%s\n' "$BODY" | acceptance_items)"
COUNT="$(printf '%s' "$ITEMS" | grep -cE '.' || true)"

if [[ "${COUNT:-0}" -lt 1 ]]; then
  printf 'REFUSED — no usable acceptance criteria\n\n'

  if printf '%s\n' "$BODY" | grep -qiE 'acceptance'; then
    printf 'There IS a line mentioning "acceptance", so the heading is not the problem.\n'
    printf 'The items under it are. Each one needs a list marker:\n\n'
    printf '    - [ ] like this\n    - like this\n    1. or like this\n\n'
    printf 'A paragraph is not an item. The verifier has to judge "does the diff\n'
    printf 'satisfy item 3?", so there has to be an item 3.\n\n'
    printf 'What is under your heading right now:\n'
    printf '%s\n' "$BODY" | awk '
        tolower($0) ~ /^[[:space:]]*#{0,6}[[:space:]]*\**acceptance[[:space:]]+criteria/ { inSec=1; print "  > " $0; next }
        inSec && /^[[:space:]]*#{1,6}[[:space:]]/ { inSec=0 }
        inSec { print "  > " $0 }
      '
  else
    printf 'No heading matching "Acceptance criteria" was found at all.\n\n'
    printf 'It must be a line containing those two words, in that order, separated\n'
    printf 'by a space. All of these work:\n\n'
    printf '    ## Acceptance criteria\n    Acceptance Criteria:\n    **Acceptance criteria**\n\n'
    printf 'These do NOT: "AC", "Acceptance-criteria", "Criteria".\n'
  fi
  exit 1
fi

printf 'ACCEPTED — %s criterion(s) found:\n\n' "$COUNT"
printf '%s\n' "$ITEMS" | sed 's/^/  - /'
printf '\nThis issue will pass preflight. Label it %s to queue it.\n' "$LOOP_LABEL_READY"
exit 0
