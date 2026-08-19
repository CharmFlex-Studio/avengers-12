#!/usr/bin/env bash
# One-time bootstrap: turn unchecked `- [ ]` items in existing markdown into
# loop issues.
#
# Most projects already have a to-do list or a fix list written with real
# acceptance detail. Rather than start the loop against an empty board, lift it.
#
# Which files to read comes from `seed.sources` in avengers-12/config.yml. Those
# paths used to be written into this script, which meant the one script whose
# whole job is "start from what you already have" only worked for the repository
# it was born in.
#
# Deliberately conservative: dry-run by default, one label, no board writes
# unless asked. Read the output before you commit to it.
#
# Usage:
#   avengers-12/lib/seed-board.sh                 # dry run, prints what it would create
#   avengers-12/lib/seed-board.sh --create        # actually create issues
#   avengers-12/lib/seed-board.sh --create --add-to-board
#   avengers-12/lib/seed-board.sh --file path/to/one-list.md --create

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"

require_cmd gh

CREATE=false
ADD_TO_BOARD=false
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create)        CREATE=true; shift ;;
    --add-to-board)  ADD_TO_BOARD=true; shift ;;
    --file)          FILES+=("$2"); shift 2 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r source; do
    [[ -n "$source" ]] && FILES+=("$source")
  done < <(cfg_list seed.sources)
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
  die "no files to read: set seed.sources in $AVENGERS_CONFIG, or pass --file"
fi

$CREATE || log "DRY RUN — pass --create to actually open issues"

created=0
skipped=0

for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || { warn "no such file: $file"; continue; }
  log "scanning $file"

  section=""
  while IFS= read -r line; do
    # Track the nearest heading so the issue carries some context.
    if [[ "$line" =~ ^#{1,6}[[:space:]]+(.*)$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # Only unchecked top-level items. Nested detail lines become the body.
    [[ "$line" =~ ^-[[:space:]]\[[[:space:]]\][[:space:]]+(.*)$ ]] || continue
    title="${BASH_REMATCH[1]}"

    # Strip markdown emphasis from the title so it reads cleanly in a list.
    title="$(printf '%s' "$title" | sed -E 's/\*\*//g; s/`//g' | cut -c1-100)"
    [[ -n "$title" ]] || continue

    if gh issue list --search "\"$title\" in:title" --state all --limit 1 --json number \
        | grep -q '"number"'; then
      skipped=$((skipped + 1))
      continue
    fi

    body="$(cat <<EOF
## Goal

$title

## Acceptance criteria

- [ ] _TODO: fill this in before adding \`loop:ready\` — preflight refuses to run without it_

## Files or areas likely touched

_TODO_

## Out of scope

- Unrelated refactors
- Tests unrelated to this change

## Context / prior art

Lifted from \`$file\`${section:+, section "$section"}.
EOF
)"

    if $CREATE; then
      url="$(gh issue create --title "[loop] $title" --body "$body" --label "$LOOP_LABEL_NEEDS_SPEC" 2>/dev/null)" \
        || { warn "failed to create: $title"; continue; }
      log "created $url"
      if $ADD_TO_BOARD && board_enabled; then
        gh project item-add "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$url" >/dev/null 2>&1 \
          || warn "could not add $url to the board"
      fi
    else
      printf '  would create: [loop] %s\n' "$title"
    fi
    created=$((created + 1))
  done < "$file"
done

log "done — $created new, $skipped already existed"
$CREATE || log "nothing was created; re-run with --create"

cat <<'EOF'

Note: every issue is created with `loop:needs-spec`, never `loop:ready`.
Acceptance criteria lifted from a checklist are titles, not specifications.
Run Loop Triage, or fill them in yourself, before letting the loop near them.
EOF
