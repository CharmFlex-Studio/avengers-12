#!/usr/bin/env bash
# Remove gate-denied paths from the branch, so a saved branch can never poison
# every future run on the same issue.
#
# The failure this exists to prevent:
#
#   1. a run fails, preserve-work.sh commits everything it finds and pushes
#   2. one of those files is on the avengers-12/config.yml denylist
#   3. check-gate.sh reads the whole branch (merge-base..HEAD), not just the new
#      agent's work, so the NEXT run fails at the gate before it has done
#      anything wrong
#   4. preflight.sh reuses that branch, so step 3 repeats forever
#
# The branch becomes permanently unusable and nothing in the escalation says to
# delete it. Stripping the denied paths here breaks the cycle at step 2, and
# running it again on reuse repairs a branch that was poisoned before this
# existed.
#
# Nothing is lost by stripping. The workflow captures `.loop/working-tree.patch`
# and `.loop/patches/` BEFORE this runs, and both go into the run artifact, so
# the denied content is still recoverable by a human who decides it belongs.
#
# Usage: avengers-12/lib/strip-denied.sh <merge-base>
#
# Leaves the reverted state staged in the index. The caller decides whether to
# commit. Prints the stripped paths to stdout, one per line.
# Always exits 0: failing to strip must never mask the original failure.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

MERGE_BASE="${1:-}"
[[ -n "$MERGE_BASE" ]] || { warn "strip-denied: no merge base given — skipping"; exit 0; }
[[ -f "$LOOP_GATE_FILE" ]] || { warn "strip-denied: no $LOOP_GATE_FILE — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { warn "strip-denied: python3 missing — skipping"; exit 0; }

# Stage everything first, so committed, staged, unstaged and untracked work all
# appear in one diff. Missing any of those states is how a denied file slips
# through: the agent is told never to commit, so most of its output is untracked
# when a run dies.
git add -A -- . >/dev/null 2>&1 || true

CHANGED="$(mktemp)"
DENIED="$(mktemp)"
trap 'rm -f "$CHANGED" "$DENIED"' EXIT

# core.quotePath=false and --no-renames for the same reasons as check-gate.sh:
# a C-quoted non-ASCII path matches no gate pattern, and rename detection hides
# the source path of a `git mv` out of a denied directory.
git -c core.quotePath=false diff --cached --no-renames --name-only "$MERGE_BASE" \
  > "$CHANGED" 2>/dev/null || true

if [[ ! -s "$CHANGED" ]]; then
  log "strip-denied: nothing changed against $MERGE_BASE"
  exit 0
fi

python3 "$HERE/gate_check.py" --list-denied "$LOOP_GATE_FILE" "$CHANGED" > "$DENIED" 2>/dev/null || true

if [[ ! -s "$DENIED" ]]; then
  log "strip-denied: no denied paths among $(wc -l < "$CHANGED" | tr -d ' ') changed file(s)"
  exit 0
fi

COUNT=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if git cat-file -e "${MERGE_BASE}:${path}" 2>/dev/null; then
    # The path existed before the run touched it: put the original back, so the
    # branch shows no change to it at all.
    git checkout "$MERGE_BASE" -- "$path" >/dev/null 2>&1 || warn "strip-denied: could not restore $path"
  else
    # The run created it. Remove it from the index and the tree.
    git rm -q -f --ignore-unmatch -- "$path" >/dev/null 2>&1 || warn "strip-denied: could not remove $path"
  fi
  printf '%s\n' "$path"
  COUNT=$((COUNT + 1))
done < "$DENIED"

git add -A -- . >/dev/null 2>&1 || true

warn "strip-denied: dropped $COUNT gate-denied path(s) from the branch"
summary "### Gate-denied paths dropped from the saved branch"
summary ""
summary "$COUNT path(s) the gate forbids were removed before saving, so the branch stays reusable. They are still in this run's artifact if you need them:"
summary ""
summary '```'
cat "$DENIED" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
summary '```'

exit 0
