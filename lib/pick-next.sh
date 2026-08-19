#!/usr/bin/env bash
# Choose the next issue to implement. Deterministic, and deliberately not the
# model's decision.
#
# Triage produces a ranked queue and that ranking is useful to read, but it is
# model output: it can be wrong, it can drift between runs, and you cannot
# reproduce it. What actually gets worked on is decided here, by rules you can
# check by hand:
#
#   0. housekeeping first, in every mode:
#        - a claim behind a dead run is released          (stale sweep)
#        - a blocked issue whose question has been answered is unblocked
#   1. the issue is open
#   2. it carries loop:ready          (a human or triage vouched for it)
#   3. it does NOT carry loop:in-progress or loop:blocked
#   4. it has no open pull request from loop/issue-N — that work is finished
#   5. order: issues the owner just answered, then the board's Todo column
#      order, then the lowest issue number (oldest first, FIFO)
#
# Prints the issue number to stdout and sets the `issue` GITHUB_OUTPUT.
# Prints nothing and exits 0 when the queue is empty — an empty queue is a
# normal outcome, not an error.
#
# Usage:
#   avengers-12/lib/pick-next.sh [--label loop:ready]   pick automatically
#   avengers-12/lib/pick-next.sh --issue <N>            the owner named this issue
#   avengers-12/lib/pick-next.sh --resume <N>           an issue comment asked for it

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"
# shellcheck source=avengers-12/lib/issue-state.sh
source "$HERE/issue-state.sh"

require_cmd gh jq
require_env GH_TOKEN

READY_LABEL="$LOOP_LABEL_READY"
MODE="auto"
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)  READY_LABEL="${2:?--label needs a value}"; shift 2 ;;
    --issue)  MODE="explicit"; TARGET="${2:?--issue needs a value}"; shift 2 ;;
    --resume) MODE="resume";   TARGET="${2:?--resume needs a value}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n "$TARGET" && ! "$TARGET" =~ ^[0-9]+$ ]]; then
  die "issue number must be numeric, got: $TARGET"
fi

loop_init_dirs

# --- 0. housekeeping ----------------------------------------------------------
# Both sweeps run in every mode, including an explicitly named issue. They fix
# state that a previous run left behind, and leaving that state in place is what
# makes the harness need a human to click things.

group "Releasing stale claims"
clear_stale_claims
endgroup

group "Resuming answered issues"
resume_answered_issues
endgroup

RESUMED_JSON="$(jq -Rn '[inputs | select(length > 0) | tonumber]' < "$LOOP_DIR/resumed.txt")"
RESUMED_COUNT="$(jq 'length' <<<"$RESUMED_JSON")"
if [[ "$RESUMED_COUNT" -gt 0 ]]; then
  notice "Loop: $RESUMED_COUNT issue(s) had an answer waiting and are back in the queue"
fi

# --- helpers ------------------------------------------------------------------

# why_not_eligible <n> -> prints a reason, or nothing when the issue is eligible
why_not_eligible() {
  local issue="$1" json state labels
  json="$(gh issue view "$issue" --json state,labels 2>/dev/null || echo '{}')"
  state="$(jq -r '.state // "UNKNOWN"' <<<"$json")"
  labels="$(jq -r '[.labels[]?.name] | join(",")' <<<"$json")"

  if [[ "$state" != "OPEN" ]]; then
    printf 'it is %s, and only open issues are implementable' "$state"; return 0
  fi
  # Blocked is checked before ready, because it is the more informative answer:
  # escalate.sh strips loop:ready when it blocks, so "not ready" is a true but
  # useless thing to tell someone whose reply did not qualify as an answer.
  if [[ ",$labels," == *",loop:blocked,"* ]]; then
    # issue_answered fills ISSUE_ANSWER_DETAIL with the timestamps it compared.
    # Without them this line reads the same whether the loop asked a new
    # question, whether a reply was misfiled, or whether nobody replied at all —
    # three situations needing three different responses from the reader.
    issue_answered "$issue" >/dev/null 2>&1 || true
    printf 'it is still `loop:blocked`. %s' "$ISSUE_ANSWER_DETAIL"
    return 0
  fi
  if [[ ",$labels," == *",loop:in-progress,"* ]]; then
    printf 'it is `loop:in-progress` — another run holds the claim'; return 0
  fi
  if [[ ",$labels," != *",$READY_LABEL,"* ]]; then
    printf 'it does not carry `%s` (labels: %s)' "$READY_LABEL" "${labels:-none}"; return 0
  fi
  if issue_has_open_pr "$issue"; then
    printf 'it already has an open pull request from `loop/issue-%s` — that work is done' "$issue"
    return 0
  fi
  return 0
}

hand_over() {
  local issue="$1" title
  title="$(gh issue view "$issue" --json title --jq '.title' 2>/dev/null || echo "issue #$issue")"
  set_output "issue" "$issue"
  set_output "title" "$title"
  set_output "count" "1"
  log "handing #$issue to the implement job — $title"
  summary "## Loop picked #${issue}"
  summary ""
  summary "**${title}**"
  summary ""
}

decline() {
  set_output "issue" ""
  set_output "count" "0"
  notice "Loop: nothing to implement — see the run summary for why."
}

# --- explicit mode ------------------------------------------------------------
# The owner named an issue on the dispatch form. Hand it straight over: the
# readiness rules still apply, but preflight.sh owns them and refuses there,
# with a full explanation, before a single token is spent. Second-guessing an
# explicit instruction here would just move that refusal somewhere less visible.
if [[ "$MODE" == "explicit" ]]; then
  hand_over "$TARGET"
  summary "Named explicitly on the dispatch form. Preflight still applies."
  exit 0
fi

# --- resume mode --------------------------------------------------------------
# An issue comment fired the workflow. Unlike the explicit path this one is not
# a human pressing a button on purpose, so it must be able to decline quietly:
# every comment on a blocked issue reaches here, and only some of them are the
# answer the loop was waiting for.
if [[ "$MODE" == "resume" ]]; then
  REASON="$(why_not_eligible "$TARGET")"
  if [[ -n "$REASON" ]]; then
    log "resume declined for #$TARGET: $REASON"
    summary "## Loop: comment on #${TARGET} did not resume anything"
    summary ""
    summary "The comment was seen, but the issue is not implementable right now — ${REASON}."
    summary ""
    summary "This run is green because nothing failed, not because work was done."
    decline
    exit 0
  fi
  hand_over "$TARGET"
  summary "Resumed by a comment on the issue. The answer is in \`.loop/answer.md\` for the coder."
  exit 0
fi

# --- automatic mode -----------------------------------------------------------
log "looking for open issues labelled '$READY_LABEL'"

CANDIDATES="$(
  gh issue list \
    --state open \
    --label "$READY_LABEL" \
    --limit 100 \
    --json number,title,labels,updatedAt 2>/dev/null \
  || echo '[]'
)"

# No `2>/dev/null || echo '[]'` on the pure-jq transforms below. A silent
# fallback to an empty array turns a broken expression into "the queue is
# empty" — a green run that did nothing, which is the hardest kind of failure
# to notice. Network calls stay defensive; local data shaping fails loudly.
LABEL_ELIGIBLE="$(
  jq -c --arg busy "$LOOP_LABEL_IN_PROGRESS" --arg blocked "$LOOP_LABEL_BLOCKED" '
    [ .[]
      | select(
          ([.labels[].name] | index($busy))    == null and
          ([.labels[].name] | index($blocked)) == null
        )
    ]
  ' <<<"$CANDIDATES"
)" || die "could not filter the candidate issues — jq failed on the gh output"

# An issue whose loop branch already has an open PR is finished as far as this
# harness is concerned. `Closes #N` only fires on merge, so the issue is still
# open and would otherwise be picked again on every run: the work would be
# redone, and `gh pr create` would then fail with "a pull request already
# exists", killing the job and marking a perfectly healthy issue blocked.
KEPT="[]"
while read -r number; do
  [[ -n "$number" ]] || continue
  if issue_has_open_pr "$number"; then
    log "skipping #$number — an open PR already exists on loop/issue-$number"
    continue
  fi
  KEPT="$(jq -c --argjson n "$number" '. + [$n]' <<<"$KEPT")"
done < <(jq -r '.[].number' <<<"$LABEL_ELIGIBLE")

# --- ordering -----------------------------------------------------------------
# The board is the source of truth for WHAT ORDER work happens in; the labels
# stay the source of truth for WHETHER it may happen at all. Keeping those two
# jobs apart is what lets the board be authoritative without becoming a safety
# control that can fail the harness closed when it is misconfigured.
BOARD_ORDER="$(board_issue_order "$LOOP_COL_TODO" | jq -Rn '[inputs | select(length > 0) | tonumber]')"
BOARD_COUNT="$(jq 'length' <<<"$BOARD_ORDER")"
log "board Todo column: $BOARD_COUNT item(s)"

ELIGIBLE="$(
  jq -c \
    --argjson kept "$KEPT" \
    --argjson order "$BOARD_ORDER" \
    --argjson resumed "$RESUMED_JSON" '
      [ .[]
        # Bind the item before piping into the lookup arrays. Inside
        # `($order | index(.number))` the dot is $order, not the issue, so the
        # unbound spelling silently fails with "cannot index array with string".
        | . as $i
        | select($kept | index($i.number))
        | . + {
            # 0 = the owner answered this one just now. Their reply is the most
            # recent instruction anybody has given the loop, so it outranks
            # every other signal.
            rank_answered: (if ($resumed | index($i.number)) then 0 else 1 end),
            # Position in the board Todo column; anything the board does not
            # mention sorts after everything it does.
            rank_board: (($order | index($i.number)) // 999999)
          }
      ]
      | sort_by(.rank_answered, .rank_board, .number)
    ' <<<"$LABEL_ELIGIBLE"
)" || die "could not rank the eligible issues — jq failed"

COUNT="$(jq 'length' <<<"$ELIGIBLE")"

if [[ "$COUNT" -eq 0 ]]; then
  log "no eligible issues — nothing to implement"

  # An empty queue is the most common outcome, and "no eligible issues" on its
  # own doesn't tell you what to DO about it. Enumerate the near-misses so the
  # summary answers the actual question: which issue is blocked on what.
  BLOCKERS="$(
    gh issue list --state open --limit 100 \
      --json number,title,labels 2>/dev/null \
    | jq -r --arg prefix "$LOOP_LABEL_PREFIX" '
        .[]
        | . as $i
        | ([.labels[].name] | map(select(startswith($prefix)))) as $loop
        | select(($loop | length) > 0)
        | "- #\($i.number) — \($i.title) — `\($loop | join("`, `"))`"
      ' 2>/dev/null || true
  )"

  summary "## Loop: nothing to do"
  summary ""
  summary "The implement job was **skipped** — no open issue carries \`$READY_LABEL\` without also being \`loop:in-progress\`, \`loop:blocked\`, or already covered by an open loop pull request. This run is green because nothing failed, not because work was done."
  summary ""

  # Call out the contradiction specifically. An issue that is both ready and
  # blocked was judged implementable and then withheld — almost always a stale
  # label from an earlier verdict, and a one-click fix. Buried in the list below
  # it reads like every other ineligible issue; it is not.
  CONTRADICTORY="$(
    gh issue list --state open --limit 100 --json number,title,labels 2>/dev/null \
    | jq -r --arg ready "$LOOP_LABEL_READY" \
            --arg blocked "$LOOP_LABEL_BLOCKED" \
            --arg needsspec "$LOOP_LABEL_NEEDS_SPEC" '
        .[]
        | select([.labels[].name] as $l
                 | ($l | index($ready)) != null
                 and (($l | index($blocked)) != null
                      or ($l | index($needsspec)) != null))
        | "- #\(.number) — \(.title) — has `\($ready)` **and** `\([.labels[].name]
            | map(select(. == $blocked or . == $needsspec)) | join("`, `"))`"
      ' 2>/dev/null || true
  )"
  if [[ -n "$CONTRADICTORY" ]]; then
    summary "> [!IMPORTANT]"
    summary "> **These issues carry \`loop:ready\` together with \`loop:needs-spec\`.**"
    summary "> \`loop:ready\` wins: they ARE eligible and the loop will pick them up. The"
    summary "> issue template stamps \`loop:needs-spec\` on every new issue, so this is"
    summary "> normal until you clear it. Remove \`loop:needs-spec\` to stop seeing them here."
    summary ""
    printf '%s\n' "$CONTRADICTORY" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    summary ""
    printf '%s\n' "$CONTRADICTORY" >&2
  fi

  if [[ -n "$BLOCKERS" ]]; then
    summary "Open issues the loop knows about, and why each is not eligible:"
    summary ""
    printf '%s\n' "$BLOCKERS" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    summary ""
    summary "| Label | What unblocks it |"
    summary "|---|---|"
    summary "| \`loop:needs-spec\` | Rewrite the acceptance criteria, or split it — see the verdict in \`avengers-12/state/STATE.md\` |"
    summary "| \`loop:in-progress\` | A run claimed it. A claim with no live run behind it is released automatically after \`LOOP_STALE_CLAIM_HOURS\` (default 2) |"
    summary "| \`loop:blocked\` | **Reply to the escalation comment on the issue.** The loop resumes by itself on your comment — you do not need to touch the label |"
    summary "| \`loop:in-review\` | A draft PR is open. Review and merge it |"
  else
    summary "No open issue carries any \`loop:*\` label at all — the queue is genuinely empty."
    summary ""
    summary "File an issue with the **Loop task** template, then label it \`$READY_LABEL\` once its acceptance criteria are checkable."
  fi
  summary ""
  summary "Read \`avengers-12/state/STATE.md\` on the base branch for the full triage verdicts."

  decline
  exit 0
fi

NUMBER="$(jq -r '.[0].number' <<<"$ELIGIBLE")"
TITLE="$(jq -r '.[0].title'  <<<"$ELIGIBLE")"

log "picked #$NUMBER — $TITLE  (from $COUNT eligible)"

# Show the whole shortlist, so the choice is auditable rather than a black box.
summary "## Loop picked #${NUMBER}"
summary ""
summary "**${TITLE}**"
summary ""
if [[ "$BOARD_COUNT" -gt 0 ]]; then
  summary "Ordered by: answered-by-you first, then the board's Todo column, then issue number. ${COUNT} eligible issue(s):"
else
  summary "The board's Todo column is empty or unreadable, so ordering fell back to issue number. ${COUNT} eligible issue(s):"
fi
summary ""
jq -r '.[] | "- #\(.number) — \(.title)" + (if .rank_answered == 0 then "  ← you answered this" else "" end)' \
  <<<"$ELIGIBLE" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

set_output "issue" "$NUMBER"
set_output "title" "$TITLE"
set_output "count" "$COUNT"
