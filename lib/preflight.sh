#!/usr/bin/env bash
# Pre-run gate for loop-implement. Runs BEFORE Claude is invoked, so a refusal
# here costs zero tokens — which is the entire point of the readiness contract.
#
# Usage: avengers-12/lib/preflight.sh <issue-number>
#
# Exits non-zero (and explains why) unless every condition holds:
#   - kill switch is off
#   - issue exists, is open, and is not a pull request
#   - issue carries loop:ready and does NOT carry loop:in-progress
#   - issue body has an Acceptance criteria section with at least one real item
#   - today's implement runs are under the daily cap
#
# On success it claims the issue (labels + board) and creates the work branch.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"
# shellcheck source=avengers-12/lib/issue-state.sh
source "$HERE/issue-state.sh"

require_cmd gh jq git
require_env GH_TOKEN

ISSUE="${1:-}"
[[ -n "$ISSUE" ]] || die "usage: preflight.sh <issue-number>"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue number must be numeric, got: $ISSUE"

# Resolved in common.sh from budget.maxRunsPerDay, with the repository variable
# LOOP_MAX_RUNS_PER_DAY as the override. Do not re-default it here.
MAX_RUNS_PER_DAY="$LOOP_MAX_RUNS_PER_DAY"

loop_init_dirs

# --- 1. kill switch ----------------------------------------------------------
# Also gated at job level, but a second check costs nothing and covers the case
# where someone flips the variable while a run is queued.
if [[ "${LOOP_PAUSE_ALL:-false}" == "true" ]]; then
  problem "loop-pause-all is active — refusing to start"
  die "kill switch engaged (repo variable LOOP_PAUSE_ALL=true)"
fi

# --- 2. issue exists and is actionable --------------------------------------
group "Reading issue #$ISSUE"
if ! gh issue view "$ISSUE" --json number,title,state,body,labels,url > "$LOOP_DIR/issue.json" 2>"$LOOP_DIR/issue.err"; then
  endgroup
  problem "issue #$ISSUE could not be read"
  die "gh issue view failed: $(head -c 500 "$LOOP_DIR/issue.err")"
fi
endgroup

STATE="$(jq -r '.state' "$LOOP_DIR/issue.json")"
TITLE="$(jq -r '.title' "$LOOP_DIR/issue.json")"
BODY="$(jq -r '.body // ""' "$LOOP_DIR/issue.json")"
LABELS="$(jq -r '[.labels[].name] | join(",")' "$LOOP_DIR/issue.json")"

[[ "$STATE" == "OPEN" ]] || die "issue #$ISSUE is $STATE — only open issues are implementable"

# --- 3. labels ---------------------------------------------------------------
has_label() { [[ ",$LABELS," == *",$1,"* ]]; }

if ! has_label "$LOOP_LABEL_READY"; then
  problem "issue #$ISSUE is not labelled loop:ready"
  cat >&2 <<EOF

  Refusing to start. An issue becomes loop:ready only after a human (or the
  triage run) has confirmed its acceptance criteria are checkable without
  asking a question. Current labels: ${LABELS:-none}
EOF
  exit 1
fi

if has_label "$LOOP_LABEL_IN_PROGRESS"; then
  problem "issue #$ISSUE is already loop:in-progress"
  die "another run has claimed this issue — clear the label if that run is dead"
fi

# --- 4. acceptance criteria --------------------------------------------------
# An unfilled template ships with empty "- [ ]" bullets. Those must NOT pass:
# a run with no criteria is exactly the run that wanders.
#
# A LIST MARKER IS REQUIRED. Counting any non-blank line meant a section reading
# only "Acceptance criteria are unclear here." scored 1 and sailed through — the
# single worst case to admit, because it is an explicit statement that nobody
# knows what done looks like. The verifier judges "does the diff satisfy item
# N?", so an item has to be an item.
#
# `|| true` on the pipeline is load-bearing under `set -euo pipefail`: grep exits
# 1 when a section contains no items at all, which without it would abort the
# script here with no message instead of printing the refusal below.
ACCEPTANCE_ITEMS="$(
  printf '%s\n' "$BODY" \
    | awk '
        BEGIN { inSec = 0 }
        # Case-insensitive on the whole line: real issues write "Acceptance Criteria",
        # "acceptance criteria", and "## Acceptance criteria" interchangeably.
        tolower($0) ~ /^[[:space:]]*#{0,6}[[:space:]]*\**acceptance[[:space:]]+criteria/ { inSec = 1; next }
        inSec && /^[[:space:]]*#{1,6}[[:space:]]/ { inSec = 0 }
        inSec { print }
      ' \
    | grep -E '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+' \
    | sed -E 's/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]*(\[[ xX]\])?[[:space:]]*//' \
    | grep -vE '^[[:space:]]*$' \
    | wc -l | tr -d ' ' \
    || true
)"

if [[ "${ACCEPTANCE_ITEMS:-0}" -lt 1 ]]; then
  problem "issue #$ISSUE has no usable Acceptance criteria"
  cat >&2 <<EOF

  Refusing to start. The verifier judges the diff against the acceptance
  criteria and nothing else, so an empty section means there is no
  specification to build against.

  What counts: an "Acceptance criteria" heading followed by at least one list
  item — "- ", "* ", "- [ ] " or "1. " — with real text after the marker.
  Prose under the heading does not count, however well written; "the criteria
  are unclear" is not a criterion.

  Add one, or label the issue loop:needs-spec and let triage rewrite it.
EOF
  exit 1
fi
log "acceptance criteria: $ACCEPTANCE_ITEMS item(s)"

# --- 5. daily budget ---------------------------------------------------------
TODAY="$(date -u +%Y-%m-%d)"
RUNS_TODAY=0
if [[ -f "$LOOP_RUN_LOG" ]]; then
  # Count implement runs that actually reached an outcome. Two things must NOT
  # count: triage runs (documented as unmetered, but they share this log), and
  # runs refused by this very script — otherwise a mistyped issue number burns
  # budget, and repeated refusals lock you out of your own harness.
  RUNS_TODAY="$(
    grep "\"run_id\": *\"$TODAY" "$LOOP_RUN_LOG" 2>/dev/null \
      | grep '"pattern": *"implement"' \
      | grep -cE '"outcome": *"(pr-opened|escalated|gate-failed|died)"' \
      || true
  )"
  RUNS_TODAY="${RUNS_TODAY:-0}"
fi
if [[ "$RUNS_TODAY" -ge "$MAX_RUNS_PER_DAY" ]]; then
  problem "daily implement budget exhausted ($RUNS_TODAY/$MAX_RUNS_PER_DAY)"

  # Say so on the issue, not only in the run log.
  #
  # This refusal happens BEFORE `.loop/claimed` is written, so escalate.sh takes
  # its never-claimed path and deliberately leaves the issue untouched: no
  # comment, no label. Correct for a mistyped issue number, wrong here — the
  # owner sees a red run against their issue and no reason anywhere near it.
  # The cap is not a fault in the issue, so the comment explains and stops.
  CAP_NOTE="$LOOP_DIR/cap-note.md"
  {
    printf '## Loop: daily run cap reached\n\n'
    printf 'This issue was next in the queue, but the loop has already used its\n'
    printf '%s implement run(s) for today (UTC). Nothing was started and nothing is wrong\n' "$MAX_RUNS_PER_DAY"
    printf 'with the issue — it stays `loop:ready` and will be picked up again.\n\n'
    printf '**Resets:** %sT00:00Z (the next UTC day)\n\n' "$(date -u -d 'tomorrow' +%Y-%m-%d 2>/dev/null || date -u -v+1d +%Y-%m-%d 2>/dev/null || echo 'the next UTC day')"
    printf '**To run it sooner:** raise `budget.maxRunsPerDay` in `avengers-12/config.yml`, or set the `LOOP_MAX_RUNS_PER_DAY` repository variable to override it.\n'
  } > "$CAP_NOTE"
  loop_comment "$ISSUE" "$CAP_NOTE"

  summary "## Loop: daily run cap reached"
  summary ""
  summary "Used ${RUNS_TODAY} of ${MAX_RUNS_PER_DAY} implement runs today. #${ISSUE} was not started and keeps its labels."
  die "raise budget.maxRunsPerDay in avengers-12/config.yml, or wait until tomorrow"
fi
log "budget: run $((RUNS_TODAY + 1)) of $MAX_RUNS_PER_DAY today"

# --- 6. claim the issue ------------------------------------------------------
BRANCH="${LOOP_BRANCH_PREFIX}${ISSUE}"

log "claiming issue #$ISSUE"
# Add and remove are separate calls on purpose. `gh issue edit --add-label X
# --remove-label Y` fails as a unit when X does not exist on the repository, and
# the failure silently cancels the removal of Y — which is how an issue ends up
# claimed and still blocked.
ensure_label "$LOOP_LABEL_IN_PROGRESS" "FBCA04" "Claimed by a loop run"
gh issue edit "$ISSUE" --add-label "$LOOP_LABEL_IN_PROGRESS" >/dev/null 2>&1 \
  || warn "could not add loop:in-progress to #$ISSUE"
gh issue edit "$ISSUE" --remove-label "$LOOP_LABEL_BLOCKED" >/dev/null 2>&1 || true

# Put the card on the board before moving it. The board is the source of truth,
# and an issue the loop is actively working on must never be missing from it —
# previously nothing added issues except a manual seed-board.sh run, so anything
# filed afterwards was worked on invisibly.
board_ensure_item "$ISSUE" >/dev/null
board_set_status "$ISSUE" "$LOOP_COL_IN_PROGRESS"

# The claim marker. escalate.sh reads this to tell "the run claimed this issue
# and then failed" from "the run refused before touching it" — without it, a
# mistyped issue number gets labelled loop:blocked and stripped of loop:ready,
# punishing an issue the loop never started.
printf '%s\n' "$ISSUE" > "$LOOP_DIR/claimed"

# --- 7. work branch ----------------------------------------------------------
# Both come from config.yml via common.sh, which already applied its own
# defaults. Repeating a fallback here would mean two places to change and one
# of them wrong.
git config user.name  "$LOOP_GIT_NAME"
git config user.email "$LOOP_GIT_EMAIL"

log "base branch: $LOOP_BASE_BRANCH"

if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
  # A leftover branch is only safe to reuse if it grew out of this base branch.
  # The same issue re-run against a *different* base would otherwise stack the
  # change on unrelated history and open a PR that looks enormous.
  #
  # This used to be tested with `git merge-base origin/BASE origin/BRANCH`, which
  # succeeds whenever two refs share ANY ancestor — always true inside one
  # repository — so the refusal below was unreachable and the guard advertised
  # in avengers-12/README.md did not exist. History shape cannot answer the question. The base
  # is recorded when the branch is created and read back here; see
  # avengers-12/lib/recorded-base.sh.
  # Through `bash`, not the execute bit: this reads into a guard whose failure
  # mode is "abstain and reuse the branch", so a lost execute bit would quietly
  # disable the wrong-base check rather than announcing itself.
  RECORDED_BASE="$(bash "$HERE/recorded-base.sh" read "origin/$BRANCH" "$ISSUE" || true)"

  if [[ -z "$RECORDED_BASE" ]]; then
    # A branch from before base recording existed. Refusing would strand work
    # that is probably fine, so reuse it — but say plainly that the guard is
    # abstaining rather than passing.
    warn "branch $BRANCH carries no base-branch marker (created before this was recorded)"
    warn "cannot verify it was cut from $LOOP_BASE_BRANCH — reusing it unverified"
    summary "> [!WARNING]"
    summary "> \`$BRANCH\` predates base-branch recording, so the wrong-base guard could not run."
    summary "> If the resulting pull request looks far larger than the change, delete the branch and re-run."
  elif [[ "$RECORDED_BASE" != "$LOOP_BASE_BRANCH" ]]; then
    problem "branch $BRANCH was cut from '$RECORDED_BASE', not '$LOOP_BASE_BRANCH'"
    cat >&2 <<EOF

  Refusing to start. \`$BRANCH\` records \`$RECORDED_BASE\` as its base branch,
  and this run is based on \`$LOOP_BASE_BRANCH\`.

  Reusing it would merge \`$LOOP_BASE_BRANCH\` into history cut from somewhere
  else and open a pull request that drags every unrelated commit along with it.

  Either delete the stale branch:
      git push origin --delete $BRANCH
  or dispatch again with base_branch set to $RECORDED_BASE.
EOF
    exit 1
  fi

  warn "branch $BRANCH already exists — reusing it (recorded base: ${RECORDED_BASE:-unrecorded})"
  git checkout -B "$BRANCH" "origin/$BRANCH"

  # The base may have moved on while this branch sat. Bring it up to date, so
  # the run builds against current code rather than a stale snapshot — the
  # same thing a person would do before picking work back up.
  if ! git merge-base --is-ancestor "origin/$LOOP_BASE_BRANCH" HEAD 2>/dev/null; then
    BEHIND="$(git rev-list --count "HEAD..origin/$LOOP_BASE_BRANCH" 2>/dev/null || echo '?')"
    log "$LOOP_BASE_BRANCH has moved $BEHIND commit(s) ahead — merging it in"
    if git merge --no-edit "origin/$LOOP_BASE_BRANCH" >/dev/null 2>&1; then
      log "merged $LOOP_BASE_BRANCH into $BRANCH cleanly"
    else
      git merge --abort >/dev/null 2>&1 || true
      problem "cannot merge $LOOP_BASE_BRANCH into the existing $BRANCH — conflicts"
      cat >&2 <<EOF

  Refusing to start. \`$BRANCH\` holds work from an earlier run, and
  \`$LOOP_BASE_BRANCH\` has since changed in a way that conflicts with it.

  Resolving a merge conflict is not something to do unattended. Either resolve
  it yourself on that branch, or delete it and let the loop start fresh:
      git push origin --delete $BRANCH
EOF
      exit 1
    fi
  fi

  # Repair a branch that an older run poisoned.
  #
  # check-gate.sh reads the WHOLE branch, merge-base..HEAD, not just this run's
  # work. So a single gate-denied file saved by an earlier failed run makes every
  # future run on this issue fail at the gate, identically, no matter what the
  # new agent does. Stripping it here means the branch heals on the next run
  # rather than needing a human to delete it.
  REUSE_MERGE_BASE="$(git merge-base "origin/$LOOP_BASE_BRANCH" HEAD 2>/dev/null || echo '')"
  if [[ -n "$REUSE_MERGE_BASE" ]]; then
    STRIPPED="$(bash "$HERE/strip-denied.sh" "$REUSE_MERGE_BASE" || true)"
    if [[ -n "$STRIPPED" ]] && [[ -n "$(git status --porcelain)" ]]; then
      git commit -q -m "chore(loop): drop gate-denied paths left by an earlier run

check-gate.sh reads the whole branch, so a denied path saved by a previous run
would fail this run and every run after it. Removed here by the harness, not by
the agent. The content is in that run's artifact if it is genuinely needed." \
        >/dev/null 2>&1 || warn "could not commit the denied-path cleanup"
      notice "Loop: removed gate-denied path(s) an earlier run left on $BRANCH"
    fi
  fi

  # If an earlier run left work here, the agent must know, or it will treat
  # existing files as someone else's code and either duplicate them or work
  # around them.
  #
  # Key this on the branch having actual content, not merely existing. A
  # branch with nothing on it would otherwise produce a "read the earlier
  # work before writing" instruction pointing at nothing.
  #
  # The cap used to be a bare `head -40` with no indication that it had bitten,
  # so a resumed branch touching more than forty files handed the coder a
  # truncated list it had no way to know was truncated — and the coder treats
  # anything missing from that list as untouched project code.
  PRIOR_MAX="${LOOP_PRIOR_FILES_MAX:-200}"
  PRIOR_TOTAL="$(git diff --name-only "origin/$LOOP_BASE_BRANCH"...HEAD 2>/dev/null | wc -l | tr -d ' ')"
  PRIOR_FILES="$(git diff --name-only "origin/$LOOP_BASE_BRANCH"...HEAD 2>/dev/null | head -n "$PRIOR_MAX")"
  PRIOR_TRUNCATED=""
  if [[ "${PRIOR_TOTAL:-0}" -gt "$PRIOR_MAX" ]]; then
    PRIOR_TRUNCATED="$((PRIOR_TOTAL - PRIOR_MAX))"
    warn "prior-work list truncated: showing $PRIOR_MAX of $PRIOR_TOTAL changed file(s)"
  fi
  if [[ -n "$PRIOR_FILES" ]]; then
    RESUMING=true
    log "resuming: $PRIOR_TOTAL file(s) already changed on this branch"
  else
    log "branch exists but has no changes against $LOOP_BASE_BRANCH — treating as a fresh start"
  fi
else
  git checkout -b "$BRANCH"
  # Record the base branch on an empty marker commit, so a later run can ask
  # what this branch was cut from instead of guessing it from history shape.
  bash "$HERE/recorded-base.sh" write "$ISSUE" "$LOOP_BASE_BRANCH" || true
fi
log "working on branch $BRANCH (base: $LOOP_BASE_BRANCH)"

# The SHA the agent starts from. The push step compares against THIS, not against
# origin/main: on a re-run of an issue whose branch already exists, HEAD is
# already ahead of main, so a run that produced nothing would otherwise sail
# through the "no commit was produced" guard.
BASE_SHA="$(git rev-parse HEAD)"

# --- 8. the human's answer ----------------------------------------------------
# Bash extracts the reply and puts it in one named file. Everything downstream
# points AT that file rather than restating what is in it.
#
# The old path was: the whole comment thread goes into issue.md, the orchestrator
# is asked to carry the answer into the brief, and the coder reads only the
# brief. Three steps, one of them a paraphrase, and nothing checking that the
# copy happened — so the owner's answer could vanish between being written and
# being used, and the run would stop at exactly the place it stopped last time.
#
# Only comments newer than the last escalation go in. Older thread is context;
# this file is the answer to the question the loop actually asked.
ANSWER_FILE="$LOOP_DIR/answer.md"
rm -f "$ANSWER_FILE"
ESCALATED_AT="$(issue_last_escalation_at "$ISSUE")"
if [[ -n "$ESCALATED_AT" ]]; then
  REPLIES="$(
    issue_comments "$ISSUE" \
      | jq -r --arg since "$ESCALATED_AT" --arg m "$LOOP_MARKER_ANY" '
          .[]
          | select(.createdAt > $since)
          | select(.body | test($m) | not)
          | "### \(.login) — \(.createdAt)\n\n\(.body)\n"
        ' 2>/dev/null || true
  )"
  if [[ -n "$REPLIES" ]]; then
    {
      printf '# The answer to the question this loop asked\n\n'
      printf 'A previous run on issue #%s stopped and asked for a decision. Everything below\n' "$ISSUE"
      printf 'was written by a human AFTER that question, at %s.\n\n' "$ESCALATED_AT"
      printf 'This is the most recent instruction anybody has given about this issue. Where it\n'
      printf 'disagrees with the issue body, it wins. Read it in full before writing anything.\n\n'
      printf -- '---\n\n'
      printf '%s\n' "$REPLIES"
    } > "$ANSWER_FILE"
    log "wrote $ANSWER_FILE — the reply that arrived after the last escalation"
    notice "Loop: #$ISSUE was answered after its last escalation — the reply is in .loop/answer.md"
  fi
fi

# --- 9. hand off -------------------------------------------------------------
# Write the issue into the evidence packet here, so the agent never needs a
# GitHub credential of its own. Nothing downstream calls `gh issue view`.
mkdir -p "$LOOP_EVIDENCE_DIR"
{
  printf '# Issue #%s — %s\n\n' "$ISSUE" "$TITLE"
  printf '%s\n' "$BODY"
  printf '\n---\nLabels: %s\n' "$LABELS"
  printf 'URL: %s\n' "$(jq -r '.url' "$LOOP_DIR/issue.json")"

  if [[ "${RESUMING:-false}" == "true" ]]; then
    printf '\n---\n\n## You are resuming, not starting\n\n'
    printf 'An earlier run on this issue produced work and did not finish. That work is\n'
    printf 'already on this branch and in your working tree. It has NOT passed the gate or\n'
    printf 'the build.\n\n'
    printf 'Read what is there before writing anything. Continue and correct it — do not\n'
    printf 'rewrite it from scratch, and do not add a second implementation alongside it.\n'
    printf 'Whatever blocked the earlier run should be answered in the Discussion below.\n\n'
    if [[ -n "${PRIOR_FILES:-}" ]]; then
      printf 'Files the earlier run already changed:\n\n```\n%s\n```\n' "$PRIOR_FILES"
      if [[ -n "${PRIOR_TRUNCATED:-}" ]]; then
        printf '\n**This list is truncated: %s further file(s) were also changed and are not\n' "$PRIOR_TRUNCATED"
        printf 'listed.** Run `git diff --name-only %s...HEAD` to see all of them before you\n' "origin/$LOOP_BASE_BRANCH"
        printf 'assume any file is untouched project code.\n'
      fi
    fi
  fi

  if [[ -s "$ANSWER_FILE" ]]; then
    printf '\n---\n\n## A human answered the last escalation\n\n'
    printf 'Read `.loop/answer.md`. It holds every comment written since this loop asked its\n'
    printf 'question, and nothing else. It is the most recent instruction about this issue\n'
    printf 'and it overrides the body wherever the two disagree.\n'
  fi

  # Comments matter as much as the body. When a run escalates, the escalation
  # arrives as a comment and the human answers in a comment — so a packet built
  # from the body alone sends the next run in knowing nothing about the question
  # it already asked, and it stops at the same place. Include the thread.
  COMMENTS="$(gh issue view "$ISSUE" --json comments \
    --jq '.comments[] | "### \(.author.login) — \(.createdAt)\n\n\(.body)\n"' 2>/dev/null || true)"
  if [[ -n "$COMMENTS" ]]; then
    printf '\n---\n\n## Discussion\n\n'
    printf 'Comments on this issue, oldest first. A later comment overrides the body where\n'
    printf 'they disagree — it is the more recent instruction.\n\n'
    printf '%s\n' "$COMMENTS"
  fi
} > "$LOOP_EVIDENCE_DIR/issue.md"

jq -n \
  --argjson issue "$ISSUE" \
  --arg title "$TITLE" \
  --arg branch "$BRANCH" \
  --arg base_sha "$BASE_SHA" \
  --argjson criteria "$ACCEPTANCE_ITEMS" \
  '{issue: $issue, title: $title, branch: $branch, base_sha: $base_sha,
    acceptance_items: $criteria, attempts: 0, history: []}' \
  > "$LOOP_ATTEMPTS_FILE"

set_output "branch" "$BRANCH"
set_output "title" "$TITLE"
set_output "base_sha" "$BASE_SHA"
set_output "runs_today" "$RUNS_TODAY"

notice "Preflight passed for #$ISSUE — $TITLE"
