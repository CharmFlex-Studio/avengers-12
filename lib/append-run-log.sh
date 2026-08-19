#!/usr/bin/env bash
# Append one JSON entry to avengers-12/state/run-log.md on the default branch.
#
# Uses the Contents API rather than a local commit because the implement job is
# sitting on a loop/ branch when this runs, and checking out main mid-job to
# write one line invites exactly the kind of conflict that leaves a run half
# finished. The API path also means a failed append can never fail the run.
#
# Usage:
#   append-run-log.sh <outcome> [key=value ...]
#
# outcome: no-op | report-only | pr-opened | escalated | gate-failed | died

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

require_cmd gh jq base64

OUTCOME="${1:-no-op}"
shift || true

# A run that failed must not record a healthy-looking outcome. The caller passes
# the intended outcome, but `status=failure` among the key=value pairs means the
# job did not actually do what that outcome claims — and Phase 5 reads these
# outcomes to decide whether to fix the issue template or the harness, so a
# failed auth check logged as "report-only" is worse than no entry at all.
for kv in "$@"; do
  case "$kv" in
    status=failure|status=cancelled)
      if [[ "$OUTCOME" != "escalated" && "$OUTCOME" != "gate-failed" && "$OUTCOME" != "died" ]]; then
        log "job status ${kv#status=} — recording outcome as 'failed' rather than '$OUTCOME'"
        OUTCOME="failed"
      fi
      ;;
  esac
done

PATTERN="${LOOP_PATTERN:-implement}"
REPO="${GITHUB_REPOSITORY:-}"
[[ -n "$REPO" ]] || { warn "GITHUB_REPOSITORY unset — skipping run log"; exit 0; }

# --- assemble the entry ------------------------------------------------------
ENTRY="$(jq -n \
  --arg run_id "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg pattern "$PATTERN" \
  --arg outcome "$OUTCOME" \
  --arg run_url "$(run_url)" \
  '{run_id: $run_id, pattern: $pattern, outcome: $outcome, run_url: $run_url}')"

for kv in "$@"; do
  key="${kv%%=*}"
  value="${kv#*=}"
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    ENTRY="$(jq --arg k "$key" --argjson v "$value" '. + {($k): $v}' <<<"$ENTRY")"
  else
    ENTRY="$(jq --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$ENTRY")"
  fi
done

BLOCK="$(printf '\n```json\n%s\n```\n' "$(jq -c '.' <<<"$ENTRY")")"
log "run log: $(jq -c '.' <<<"$ENTRY")"

# --- idempotency -------------------------------------------------------------
# One run must produce at most one entry. Two entries for the same run would
# skew the daily-cap count in preflight.sh and the pr-opened:escalated ratio
# that Phase 5 reads — both of which are the whole reason this log exists.
# Guard on the run id rather than trusting that nothing calls this twice.
GUARD="${LOOP_DIR}/.run-log-written"
if [[ -n "${GITHUB_RUN_ID:-}" && -f "$GUARD" ]] && grep -qx "$GITHUB_RUN_ID" "$GUARD" 2>/dev/null; then
  log "run log already written for run $GITHUB_RUN_ID — skipping duplicate"
  exit 0
fi

# --- append via the Contents API, retrying once on a concurrent write --------
# Reads and writes the BASE branch, not the repository default. Work here happens
# on feature branches, so a run log that always landed on the default branch
# would both miss the history of the branch you are on and mean preflight's
# daily-cap count read a file the runs never wrote to.
BRANCH_REF="${LOOP_BASE_BRANCH:-}"

append_once() {
  local current sha decoded updated encoded
  local get_path="repos/$REPO/contents/$LOOP_RUN_LOG"
  [[ -n "$BRANCH_REF" ]] && get_path="${get_path}?ref=${BRANCH_REF}"

  current="$(gh api "$get_path" --jq '{sha: .sha, content: .content}' 2>/dev/null)" || return 1
  sha="$(jq -r '.sha' <<<"$current")"
  decoded="$(jq -r '.content' <<<"$current" | tr -d '\n' | base64 --decode)"
  updated="${decoded}${BLOCK}"
  encoded="$(printf '%s' "$updated" | base64 | tr -d '\n')"

  local -a args=(
    --method PUT "repos/$REPO/contents/$LOOP_RUN_LOG"
    -f message="chore: loop run log ($PATTERN/$OUTCOME)"
    -f content="$encoded"
    -f sha="$sha"
  )
  [[ -n "$BRANCH_REF" ]] && args+=(-f branch="$BRANCH_REF")

  gh api "${args[@]}" --silent >/dev/null 2>&1
}

mark_written() {
  [[ -n "${GITHUB_RUN_ID:-}" ]] || return 0
  mkdir -p "$LOOP_DIR"
  printf '%s\n' "$GITHUB_RUN_ID" >> "$GUARD"
}

if append_once; then
  mark_written
  log "run log updated"
elif append_once; then
  mark_written
  log "run log updated (second attempt)"
else
  warn "could not append to $LOOP_RUN_LOG — entry preserved in the run artifact only"
  mkdir -p "$LOOP_DIR"
  printf '%s\n' "$BLOCK" >> "$LOOP_DIR/run-log-entry.md"
fi

exit 0
