#!/usr/bin/env bash
# Checkable facts about a loop issue. Source this after common.sh AND board.sh
# (the unblock and stale-sweep paths move the card as well as the label — the
# board is the source of truth, so the two must never drift apart).
#
# Every question here used to be answered by a model — "has the human replied?",
# "is that claim stale?", "did the last run already open a PR?" — and every one
# of them is a fact you can read off the API. This file exists so the picker can
# ask them in bash.
#
# The rule this whole file serves: the loop must resume by itself. A run that
# escalated asks a question on the issue; the owner replies with a comment; the
# next run picks the same work back up. Nobody clicks a label. That only works
# if "the human answered" is a fact, not a judgement.
#
# Every function is non-fatal: a GitHub hiccup must degrade to "not eligible",
# never to a crashed picker.

# shellcheck source=/dev/null
[[ -n "${LOOP_DIR:-}" ]] || { echo "source common.sh first" >&2; exit 1; }

_issue_cache_dir="${LOOP_DIR}/.issue-cache"

# --- comments ----------------------------------------------------------------

# issue_comments <n> -> JSON array of {createdAt, body, login}
#
# Cached for the life of the job. The picker asks several questions of the same
# issue and each `gh issue view` is a round trip.
issue_comments() {
  local issue="$1" f
  mkdir -p "$_issue_cache_dir"
  f="$_issue_cache_dir/comments-$issue.json"
  if [[ ! -s "$f" ]]; then
    gh issue view "$issue" --json comments \
      --jq '[.comments[] | {createdAt: .createdAt, body: .body, login: (.author.login // "")}]' \
      > "$f" 2>/dev/null || printf '[]\n' > "$f"
  fi
  cat "$f"
}

# issue_last_comment_at <n> <kind>
#   kind = loop   -> newest comment carrying any loop marker
#   kind = human  -> newest comment carrying none
# Prints an ISO8601 timestamp, or nothing when there is no such comment.
issue_last_comment_at() {
  local issue="$1" kind="$2" filter
  case "$kind" in
    loop)  filter='select(.body | test($m))' ;;
    human) filter='select(.body | test($m) | not)' ;;
    *)     warn "issue_last_comment_at: unknown kind '$kind'"; return 0 ;;
  esac
  issue_comments "$issue" \
    | jq -r --arg m "$LOOP_MARKER_ANY" "[.[] | $filter] | last | .createdAt // empty" 2>/dev/null \
    || true
}

# issue_last_escalation_at <n> -> ISO8601 of the newest escalation comment
issue_last_escalation_at() {
  issue_comments "$1" \
    | jq -r --arg m "$LOOP_MARKER_ESCALATION" \
        '[.[] | select(.body | contains($m))] | last | .createdAt // empty' 2>/dev/null \
    || true
}

# issue_answered <n>
#
# True when a human has spoken since the loop last asked a question — the exact
# condition the owner described as "I reply and it carries on".
#
# Both halves matter:
#   - there must BE an escalation. A block raised by a triage verdict is not a
#     question this run asked, and clearing it is triage's job, not the picker's.
#   - the newest non-loop comment must be newer than that escalation. ISO8601 UTC
#     sorts lexicographically, so this is a string comparison and needs no date
#     parsing on either GNU or BSD.
issue_answered() {
  local issue="$1" escalated_at answered_at
  escalated_at="$(issue_last_escalation_at "$issue")"
  [[ -n "$escalated_at" ]] || return 1
  answered_at="$(issue_last_comment_at "$issue" human)"
  [[ -n "$answered_at" ]] || return 1
  [[ "$answered_at" > "$escalated_at" ]]
}

# --- pull requests -----------------------------------------------------------

# issue_has_open_pr <n>
#
# An issue whose loop branch already has an open pull request is DONE as far as
# the loop is concerned: `Closes #N` only fires on merge, so the issue stays open
# and the picker would otherwise select it again, redo the work, and then die on
# "a pull request already exists for branch loop/issue-N".
issue_has_open_pr() {
  local issue="$1" branch="${LOOP_BRANCH_PREFIX}$1" found
  found="$(gh pr list --head "$branch" --state open --limit 1 --json number \
             --jq 'length' 2>/dev/null || echo 0)"
  [[ "${found:-0}" -gt 0 ]]
}

# --- stale claims ------------------------------------------------------------

# loop_runs_in_flight
#
# How many Loop runs are alive right now, NOT counting this one. The current run
# is always in_progress while it asks, so forgetting to exclude it makes every
# claim look live and the stale sweep never fires.
loop_runs_in_flight() {
  # Piped into jq rather than using gh's own --jq: gh passes no --arg through,
  # and the current run id has to be interpolated safely.
  gh run list --workflow=loop.yml --limit 20 --json databaseId,status 2>/dev/null \
    | jq -r --arg self "${GITHUB_RUN_ID:-0}" \
        '[.[] | select(.status == "in_progress" or .status == "queued")
              | select((.databaseId | tostring) != $self)] | length' 2>/dev/null \
    || echo 0
}

# issue_claimed_at <n> -> when loop:in-progress was last applied
#
# Read from the issue events API rather than from `updatedAt`: a comment or an
# edit bumps updatedAt, so a chatty issue would look freshly claimed forever.
# Falls back to nothing when the API is unavailable — the caller then declines
# to sweep, which is the safe direction.
issue_claimed_at() {
  local issue="$1" repo="${GITHUB_REPOSITORY:-}"
  [[ -n "$repo" ]] || return 0
  # --paginate emits one JSON array per page, and gh's own --jq would then run
  # once per page and print a result per page. Slurp the pages together first,
  # so `last` really means the most recent event across all of them.
  gh api "repos/$repo/issues/$issue/events?per_page=100" --paginate 2>/dev/null \
    | jq -rs --arg busy "$LOOP_LABEL_IN_PROGRESS" \
        '((add // []) | [.[] | select(.event == "labeled" and .label.name == $busy)]
          | last | .created_at // empty)' 2>/dev/null \
    || true
}

# clear_stale_claims [hours]
#
# A runner that dies with no `always()` step leaves loop:in-progress behind, and
# the picker then skips that issue forever while triage reports it every run and
# asks a human to clear it by hand. That is the opposite of self-healing.
#
# Two facts have to hold before the label is stripped, and both are checkable:
#   1. no Loop run other than this one is alive
#   2. the claim is older than the threshold
#
# The job times out at 45 minutes, so a claim older than a couple of hours with
# no run behind it cannot belong to anything that is still working.
clear_stale_claims() {
  local hours="${1:-${LOOP_STALE_CLAIM_HOURS:-2}}" cutoff claimed issue
  local in_flight

  in_flight="$(loop_runs_in_flight)"
  if [[ "${in_flight:-0}" -gt 0 ]]; then
    log "stale sweep: $in_flight other Loop run(s) in flight — not touching any claim"
    return 0
  fi

  cutoff="$(iso_hours_ago "$hours")"

  while read -r issue; do
    [[ -n "$issue" ]] || continue
    claimed="$(issue_claimed_at "$issue")"
    if [[ -z "$claimed" ]]; then
      warn "stale sweep: cannot date the claim on #$issue — leaving it alone"
      continue
    fi
    if [[ "$claimed" > "$cutoff" ]]; then
      log "stale sweep: #$issue claimed at $claimed, newer than $cutoff — leaving it"
      continue
    fi
    notice "Loop: clearing a stale loop:in-progress on #$issue (claimed $claimed, no run active)"
    gh issue edit "$issue" --remove-label "$LOOP_LABEL_IN_PROGRESS" >/dev/null 2>&1 \
      || warn "could not clear loop:in-progress on #$issue"
    board_set_status "$issue" "$LOOP_COL_TODO"
  done < <(
    gh issue list --state open --label "$LOOP_LABEL_IN_PROGRESS" --limit 100 \
      --json number --jq '.[].number' 2>/dev/null || true
  )
  return 0
}

# --- unblocking --------------------------------------------------------------

# issue_unblock <n>
#
# Put an answered issue back in the queue. This is the half of the resume that
# used to depend on the triage model deciding to re-add a label: escalate.sh sets
# loop:blocked and strips loop:ready, and nothing in bash ever restored either,
# so a reply sat unread until somebody clicked.
#
# Labels are changed with the add and the remove issued separately, because
# `gh issue edit --add-label X --remove-label Y` fails as a unit when X does not
# exist on the repository — silently cancelling the remove.
issue_unblock() {
  local issue="$1"
  ensure_label "$LOOP_LABEL_READY" "0E8A16" "Verified implementable unattended"

  gh issue edit "$issue" --remove-label "$LOOP_LABEL_BLOCKED" >/dev/null 2>&1 \
    || warn "could not remove loop:blocked from #$issue"
  gh issue edit "$issue" --add-label "$LOOP_LABEL_READY" >/dev/null 2>&1 \
    || warn "could not add loop:ready to #$issue"

  # The board is the source of truth, so the card has to come back out of the
  # Blocked column at the same moment the label does. A card left in Blocked
  # behind a ready label is the board lying about the queue.
  board_set_status "$issue" "$LOOP_COL_TODO"

  notice "Loop: #$issue was answered — cleared loop:blocked and restored loop:ready"
  return 0
}

# resume_answered_issues
#
# Sweep every blocked issue and unblock the ones that have been answered.
#
# The unblocked numbers are written to a FILE rather than printed, and that is
# deliberate: the functions this calls emit `::notice::` annotations on stdout,
# so a caller using command substitution would capture the annotations along
# with the numbers and choke on them. A file has one meaning.
#
# Prints nothing. Writes $LOOP_DIR/resumed.txt, one issue number per line.
resume_answered_issues() {
  local issue out="$LOOP_DIR/resumed.txt"
  mkdir -p "$LOOP_DIR"
  : > "$out"
  while read -r issue; do
    [[ -n "$issue" ]] || continue
    if issue_answered "$issue"; then
      issue_unblock "$issue"
      printf '%s\n' "$issue" >> "$out"
    else
      log "#$issue is blocked and has no answer newer than the last escalation — leaving it"
    fi
  done < <(
    gh issue list --state open --label "$LOOP_LABEL_BLOCKED" --limit 100 \
      --json number --jq '.[].number' 2>/dev/null || true
  )
  return 0
}
