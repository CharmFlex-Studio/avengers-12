#!/usr/bin/env bash
# The reporter. Runs on `if: always()` — including cancellation and runner
# death, which `if: failure()` does not cover.
#
# Two rules shape this script:
#   1. A model cannot report its own crash. So bash writes the report, using
#      .loop/blocked.md when the orchestrator managed to leave one and
#      synthesising one from job status when it did not.
#   2. A card left in "In Progress" behind a dead run is invisible to the next
#      triage. So the issue always goes back to a state triage can see.
#
# Usage: avengers-12/lib/escalate.sh <issue-number> <job-status>
#   job-status: success | failure | cancelled  (from ${{ job.status }})

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"

ISSUE="${1:-}"
JOB_STATUS="${2:-failure}"
[[ -n "$ISSUE" ]] || die "usage: escalate.sh <issue-number> <job-status>"

RUN_URL="$(run_url)"
ATTEMPTS="$(loop_attempts)"
NOTIFY_USER="${LOOP_NOTIFY_USER:-${GITHUB_REPOSITORY_OWNER:-}}"

# --- success path: the issue is finished until the PR is reviewed ------------
#
# Removing only loop:in-progress was not enough, and the consequence was the
# harness's most frequent breakage. loop:ready survived, and the issue stays open
# because `Closes #N` fires on merge and nothing had merged — so the very next
# run picked the same issue again (lowest number wins), redid all the work, and
# then died on "a pull request already exists for loop/issue-N". escalate.sh then
# marked a perfectly healthy issue loop:blocked.
#
# A finished issue has to stop looking like queued work. loop:ready comes off,
# loop:in-review goes on, and the card is already in In Review.
if [[ "$JOB_STATUS" == "success" ]]; then
  ensure_label "$LOOP_LABEL_IN_REVIEW" "1D76DB" "A loop draft PR is open and waiting for review"
  # Removes first and as one call, add second and separately: an add naming a
  # label that does not exist fails the whole invocation, and would take the
  # removes down with it.
  gh issue edit "$ISSUE" \
    --remove-label "$LOOP_LABEL_IN_PROGRESS" \
    --remove-label "$LOOP_LABEL_READY" >/dev/null 2>&1 \
    || warn "could not clear the working labels on #$ISSUE"
  gh issue edit "$ISSUE" --add-label "$LOOP_LABEL_IN_REVIEW" >/dev/null 2>&1 \
    || warn "could not add loop:in-review to #$ISSUE"
  log "run succeeded — #$ISSUE is in review, nothing to escalate"
  exit 0
fi

# --- never-claimed path: the run refused before touching the issue -----------
# preflight.sh writes .loop/claimed only after every check has passed. Without
# this branch, dispatching on a wrong issue number would comment on that issue,
# label it loop:blocked, and strip loop:ready — punishing an issue the loop
# never started work on, and one that only a human can un-block.
if [[ ! -f "$LOOP_DIR/claimed" ]]; then
  log "run failed before claiming #$ISSUE — leaving the issue untouched"
  notice "Loop run failed during preflight. Issue #$ISSUE was not modified. See $RUN_URL"
  "$HERE/append-run-log.sh" "no-op" "issue=$ISSUE" "reason=preflight-refused" || true
  exit 0
fi

log "escalating issue #$ISSUE (job status: $JOB_STATUS, attempts: $ATTEMPTS)"

# --- build the report --------------------------------------------------------
REPORT="$LOOP_DIR/escalation.md"
mkdir -p "$LOOP_DIR"

# Marker so triage can tell a run-failure block from a condition block. A block
# raised here means a run tried and failed, and whether to try again is the
# human's call — triage must never clear it. A block raised by a triage verdict
# ("that path is denylisted") rests on a checkable fact, and triage may clear it
# once the fact stops being true.
printf '<!-- loop-escalation -->\n' > "$REPORT"

if [[ -s "$LOOP_DIR/blocked.md" ]]; then
  # The orchestrator got far enough to explain itself. Use its words.
  cat "$LOOP_DIR/blocked.md" >> "$REPORT"
else
  # Nobody survived to write a report. Synthesise the most useful one we can
  # from what the filesystem and the job status tell us.
  {
    case "$JOB_STATUS" in
      cancelled) headline="Loop run cancelled" ;;
      *)         headline="Loop run failed" ;;
    esac

    printf '## %s\n\n' "$headline"

    if [[ -s "$LOOP_DIR/gate-violations.txt" ]]; then
      printf '**Stopped at:** GATE — the diff touched denied paths\n\n'
      printf '**What I need from you:** decide whether the change genuinely needs those\n'
      printf 'paths. If it does, this issue is out of loop scope and should be done by hand.\n\n'
      printf '```\n%s\n```\n\n' "$(cat "$LOOP_DIR/gate-violations.txt")"
    elif [[ -s "$LOOP_DIR/verdict.json" ]] \
         && [[ "$(jq -r '.verdict // ""' "$LOOP_DIR/verdict.json" 2>/dev/null)" =~ ^(REJECT|ESCALATE_HUMAN)$ ]]; then
      # Only claim the run stopped at VERIFY when the verdict actually stopped
      # it. A verdict file exists after every verify pass, including APPROVE —
      # keying on its mere presence reports an approved run as a rejection and
      # sends the reader hunting for reasons that do not exist.
      verdict="$(jq -r '.verdict // "unknown"' "$LOOP_DIR/verdict.json" 2>/dev/null || echo unknown)"
      codes="$(jq -r '[.reasons[]?.code] | unique | join(", ")' "$LOOP_DIR/verdict.json" 2>/dev/null || echo "")"
      printf '**Stopped at:** VERIFY (verdict %s%s)\n\n' "$verdict" "${codes:+, codes: $codes}"
      printf '**What I need from you:** review the rejection reasons below and decide whether\n'
      printf 'the acceptance criteria or the implementation approach should change.\n\n'
      jq -r '.reasons[]? | "- **\(.code)** — \(.detail)"' "$LOOP_DIR/verdict.json" 2>/dev/null || true
      printf '\n'
    elif [[ -s "$LOOP_DIR/verdict.json" ]] \
         && [[ "$(jq -r '.verdict // ""' "$LOOP_DIR/verdict.json" 2>/dev/null)" == "APPROVE" ]]; then
      # The agent's half all passed — verifier approved, gate clean, build green.
      # Whatever failed came after, in a workflow step: the push, the PR create,
      # the board update. Say that plainly and point at the run, rather than
      # inventing a problem with the code.
      printf '**Stopped at:** after VERIFY — the change itself passed.\n\n'
      printf 'The verifier approved it, the gate found no denied paths, and the build was green.\n'
      printf 'The run then failed in a later workflow step — pushing the branch, opening the\n'
      printf 'draft PR, or updating the board.\n\n'
      printf '**What I need from you:** open the run log and look at which step is red.\n'
      printf 'Common causes: a pull request already exists for this branch, the branch is\n'
      printf 'protected, or the token lost a permission it needs to push.\n\n'
      printf 'The work is not lost — the patch is attached to this run as an artifact.\n\n'

    elif [[ "$JOB_STATUS" == "cancelled" ]]; then
      printf '**Stopped at:** unknown — the run was cancelled or the runner died before\n'
      printf 'the agent could report anything.\n\n'
      printf '**What I need from you:** nothing yet. Re-run the workflow; if it dies again\n'
      printf 'at the same point, the issue is probably too large for one run and should be split.\n\n'
    else
      printf '**Stopped at:** unknown — the job failed before the agent wrote a report.\n\n'
      printf '**What I need from you:** open the run log below. The failure is most likely in a\n'
      printf 'setup step (checkout, JDK, gradle cache) rather than in the agent itself.\n\n'
    fi

    if [[ -s "$LOOP_ATTEMPTS_FILE" ]]; then
      printf '**Attempts**\n\n'
      jq -r '.history[]? | "\(.attempt). \(.files_changed) file(s), build exit \(.build_exit) — \(.at)"' \
        "$LOOP_ATTEMPTS_FILE" 2>/dev/null | sed 's/^/  /' || true
      printf '\n'
    fi

    if [[ -s "$LOOP_EVIDENCE_DIR/build.txt" ]]; then
      printf '**Last build output (tail)**\n\n```\n%s\n```\n\n' \
        "$(tail -n 25 "$LOOP_EVIDENCE_DIR/build.txt")"
    fi
  } >> "$REPORT"
fi

# --- append the standard footer ---------------------------------------------
{
  printf '\n---\n\n'
  # Say how to restart it, because the answer is now "just reply". The
  # issue_comment trigger on loop.yml fires on any comment from the owner, a
  # member or a collaborator on a loop:blocked issue, and pick-next.sh clears
  # the label in bash once a human comment is newer than this escalation. Nobody
  # should be clicking labels or re-running workflows.
  printf '**To restart this work: reply to this comment.** The loop watches for your\n'
  printf 'answer, clears `loop:blocked` by itself, and resumes on the same branch. You do\n'
  printf 'not need to touch a label or re-run anything.\n\n'
  printf '**Evidence:** [run](%s) · artifact `loop-%s` · attempts used: %s of 3\n' \
    "$RUN_URL" "${GITHUB_RUN_ID:-local}" "$ATTEMPTS"
  # Do not assert "nothing was pushed" — a run can fail *after* the push (PR
  # create, board update), and telling someone their work is gone when a branch
  # is sitting on the remote sends them rebuilding it.
  #
  # Do not ask git either. This used to run `git ls-remote --heads origin`, which
  # cannot answer the question in this job: checkout runs with
  # persist-credentials: false on a private repository, so `origin` carries no
  # credential and the query fails or hangs — and the report then told the owner
  # their work was gone immediately after preserve-work.sh had pushed it.
  # preserve-work.sh writes this file itself, at the moment the push returns 0.
  PRESERVED_BRANCH=""
  [[ -s "$LOOP_DIR/preserved-branch" ]] && PRESERVED_BRANCH="$(head -n1 "$LOOP_DIR/preserved-branch")"
  if [[ -n "$PRESERVED_BRANCH" ]]; then
    printf '\n_The branch `%s` **was pushed** and holds the work — nothing is lost.\n' "$PRESERVED_BRANCH"
    printf 'The next run on this issue continues from it; you do not need to do anything\n'
    printf 'with the branch yourself._\n'
  else
    printf '\n_No branch was pushed. The working patch is attached to this run as an artifact\n'
    printf 'if you want to apply it by hand._\n'
  fi
  [[ -n "$NOTIFY_USER" ]] && printf '\ncc @%s\n' "$NOTIFY_USER"
} >> "$REPORT"

# --- defang agent-authored trigger phrases -----------------------------------
# This comment is posted with the PAT, i.e. as a human, so it DOES trigger
# workflows. `.loop/blocked.md` is written by the agent and may quote an issue
# body verbatim. If any of it contains "@claude", posting it starts an
# interactive run — and that workflow is a different, less constrained
# environment. A constrained agent must not be able to summon an unconstrained
# one by choosing a string.
# `@<!-- -->claude` still renders as "@claude" to a human reader, but the raw
# body no longer contains the literal trigger phrase. Written portably rather
# than with `sed -i`, whose suffix syntax differs between GNU and BSD.
sed -E 's/@([Cc]laude)/@<!-- -->\1/g' "$REPORT" > "$REPORT.safe" && mv "$REPORT.safe" "$REPORT"

# --- 1. comment on the issue -------------------------------------------------
if gh issue comment "$ISSUE" --body-file "$REPORT" >/dev/null 2>&1; then
  log "posted blocked comment on #$ISSUE"
else
  warn "could not comment on #$ISSUE — the report survives only in the artifact"
fi

# --- 2. relabel so triage and the picker can see it -------------------------
# Removes and the add are separate calls: `--add-label X` fails the whole
# invocation when X does not exist on the repository, and would silently cancel
# the removes sitting beside it.
ensure_label "$LOOP_LABEL_BLOCKED" "B60205" "Escalated — needs a human decision"
gh issue edit "$ISSUE" \
  --remove-label "$LOOP_LABEL_IN_PROGRESS" \
  --remove-label "$LOOP_LABEL_READY" >/dev/null 2>&1 \
  || warn "could not clear the working labels on #$ISSUE"
gh issue edit "$ISSUE" --add-label "$LOOP_LABEL_BLOCKED" >/dev/null 2>&1 \
  || warn "could not add loop:blocked to #$ISSUE"

# --- 3. move the board card to Blocked --------------------------------------
# Blocked, not Todo. The board is the source of truth and the owner commands
# from it, so a card that says Todo while the label says blocked is the board
# lying: the item looks available and is not. It also has to leave In Progress —
# an item stuck behind a dead run is exactly the work that silently disappears.
#
# board_set_status warns and continues when a board has no Blocked column, so
# adding the column is an improvement rather than a prerequisite.
board_set_status "$ISSUE" "$LOOP_COL_BLOCKED"

# --- 4. run log --------------------------------------------------------------
OUTCOME="escalated"
[[ -s "$LOOP_DIR/gate-violations.txt" ]] && OUTCOME="gate-failed"
[[ "$JOB_STATUS" == "cancelled" ]] && OUTCOME="died"
"$HERE/append-run-log.sh" "$OUTCOME" "issue=$ISSUE" "attempts=$ATTEMPTS" || true

# --- 5. optional push channel ------------------------------------------------
if [[ -n "${LOOP_WEBHOOK_URL:-}" ]]; then
  curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "Loop blocked on issue #$ISSUE ($JOB_STATUS) — $RUN_URL" '{content: $t, text: $t}')" \
    "$LOOP_WEBHOOK_URL" >/dev/null 2>&1 \
    && log "webhook notified" \
    || warn "webhook post failed"
fi

problem "Loop escalated on issue #$ISSUE — see the comment on the issue"
exit 0
