#!/usr/bin/env bash
# The gate. Runs AFTER the agent has finished and BEFORE anything is pushed.
#
# This step does not ask the model whether it stayed in scope; it reads the
# diff. Everything else in the harness is advisory by comparison — if this
# check is wrong or skipped, none of the other guarantees hold.
#
# Usage: avengers-12/lib/check-gate.sh [base-branch]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

require_cmd git python3

BASE="${1:-$LOOP_BASE_BRANCH}"

[[ -f "$LOOP_GATE_FILE" ]] || die "$LOOP_GATE_FILE not found — refusing to run without a gate"

loop_init_dirs

# Compare against the merge base so commits that landed on main during the run
# don't show up as the agent's work.
if ! MERGE_BASE="$(git merge-base "origin/$BASE" HEAD 2>/dev/null)"; then
  MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null)" \
    || die "cannot determine merge base against '$BASE'"
fi

CHANGED_FILE="$LOOP_DIR/changed-files.txt"
: > "$CHANGED_FILE"

# Three sources, because work can be in three states when the agent stops and
# a gate that inspects only one of them is a gate with a blind spot:
#   1. committed        — the normal case, the orchestrator committed
#   2. staged/unstaged  — evidence.sh runs `git add -A`, so an agent that never
#                         committed leaves real edits sitting in the index
#   3. untracked        — a new file the agent wrote but never added
#
# Two git defaults have to be turned off or the gate has blind spots:
#   core.quotePath=false  — otherwise a path with any non-ASCII byte is emitted
#                           C-quoted, e.g. ".github/workflows/\303\251vil.yml"
#                           WITH the surrounding quotes, and every anchored
#                           pattern in gate_check.py fails to match it
#   --no-renames          — rename detection prints only the destination, so
#                           `git mv .github/workflows/x.yml .github/backup.yml`
#                           would delete a workflow while showing a clean path
GIT="git -c core.quotePath=false"

$GIT diff --no-renames --name-only "$MERGE_BASE"..HEAD >> "$CHANGED_FILE" 2>/dev/null || true
$GIT diff --no-renames --name-only HEAD                >> "$CHANGED_FILE" 2>/dev/null || true
$GIT ls-files --others --exclude-standard              >> "$CHANGED_FILE" 2>/dev/null || true
sort -u -o "$CHANGED_FILE" "$CHANGED_FILE"

COUNT="$(wc -l < "$CHANGED_FILE" | tr -d ' ')"

group "Gate: $COUNT changed file(s) against $LOOP_GATE_FILE"
if [[ "$COUNT" -eq 0 ]]; then
  endgroup
  problem "the agent produced no changes"
  die "empty diff — nothing to review, nothing to push"
fi
cat "$CHANGED_FILE" >&2
endgroup

set +e
VIOLATIONS="$(python3 "$HERE/gate_check.py" "$LOOP_GATE_FILE" "$CHANGED_FILE")"
STATUS=$?
set -e

if [[ "$STATUS" -eq 2 ]]; then
  problem "avengers-12/config.yml could not be parsed — failing closed"
  die "a gate that cannot be read is a gate that is not enforcing anything"
fi

if [[ "$STATUS" -ne 0 ]]; then
  problem "gate violation — refusing to push"
  {
    echo
    echo "The agent touched paths it is not allowed to touch, or changed too many files:"
    echo
    printf '%s\n' "$VIOLATIONS" | sed 's/^/  /'
    echo
    echo "No branch was pushed and no PR was opened. The patch is attached to this"
    echo "run as an artifact if you want to inspect or apply it by hand."
  } >&2
  printf '%s\n' "$VIOLATIONS" > "$LOOP_DIR/gate-violations.txt"
  exit 1
fi

notice "Gate passed: $COUNT file(s), no denylist hits"
set_output "files_changed" "$COUNT"
