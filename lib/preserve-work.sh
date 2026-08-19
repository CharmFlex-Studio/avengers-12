#!/usr/bin/env bash
# Push whatever the agent produced, even when the run failed.
#
# Without this, a run that writes good code and then dies in a later step
# (PR creation, board update, a gate rejection) leaves the work only inside a
# 14-day run artifact. Recovering it means downloading a zip and applying a
# patch by hand, and most people simply re-run and pay for the work twice.
#
# Pushing a branch is not the same as opening a PR. Nothing merges, nothing is
# reviewed, no gate is bypassed — the branch is a parking space. The gate still
# decides whether a pull request is ever created.
#
# Usage: avengers-12/lib/preserve-work.sh <branch> <base-sha>
#
# Always exits 0. Failing to preserve work must never mask the original failure.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

BRANCH="${1:-}"
BASE_SHA="${2:-}"

[[ -n "$BRANCH" ]] || { warn "no branch name — nothing to preserve"; exit 0; }
[[ -n "${LOOP_PROJECT_TOKEN:-}" ]] || { warn "no token — cannot preserve work"; exit 0; }

# Both come from config.yml via common.sh, which already applied its own
# defaults. Repeating a fallback here would mean two places to change and one
# of them wrong.
git config user.name  "$LOOP_GIT_NAME"
git config user.email "$LOOP_GIT_EMAIL"

# --- is there anything worth keeping? ---------------------------------------
HAS_COMMITS=false
HAS_DIRTY=false
[[ -n "$BASE_SHA" && "$(git rev-parse HEAD)" != "$BASE_SHA" ]] && HAS_COMMITS=true
[[ -n "$(git status --porcelain)" ]] && HAS_DIRTY=true

if ! $HAS_COMMITS && ! $HAS_DIRTY; then
  log "no commits and a clean tree — nothing to preserve"
  exit 0
fi

# --- drop anything the gate forbids -------------------------------------------
# Saving work must not save a landmine. check-gate.sh reads the whole branch
# (merge-base..HEAD), so one denied path committed here fails not just this run
# but every future run on this issue, identically, whatever the next agent does —
# and nothing in the escalation ever told anyone to delete the branch.
#
# The denied content is not lost: the workflow captures the working tree and the
# patches into the run artifact BEFORE this step, so it is still recoverable if a
# human decides it belongs.
if ! MERGE_BASE="$(git merge-base "origin/$LOOP_BASE_BRANCH" HEAD 2>/dev/null)"; then
  MERGE_BASE="${BASE_SHA:-}"
fi
if [[ -n "$MERGE_BASE" ]]; then
  # Invoked through `bash` rather than as an executable. The `|| true` below is
  # there so a strip failure cannot mask the original failure — which also means
  # it would happily swallow "Permission denied" if the execute bit were ever
  # lost in a checkout or a patch, silently turning this guard off and pushing
  # the denied paths anyway. Naming the interpreter removes that failure mode.
  bash "$HERE/strip-denied.sh" "$MERGE_BASE" >/dev/null || true
  # Stripping may have made a previously clean tree dirty (a denied file being
  # restored to its base content) or a dirty tree clean (the only change was a
  # denied new file). Re-read rather than trusting the earlier snapshot.
  HAS_DIRTY=false
  [[ -n "$(git status --porcelain)" ]] && HAS_DIRTY=true
fi

# --- commit whatever is loose -------------------------------------------------
# The coder is told never to commit, so on most failure paths the work is sitting
# uncommitted. Commit it plainly as WIP rather than losing it.
if $HAS_DIRTY; then
  git add -A -- . >/dev/null 2>&1 || true
  if git commit -q -m "wip: loop run $(date -u +%Y-%m-%dT%H:%MZ) — preserved after a failed run

This commit was made by the harness, not by the agent, to keep work that would
otherwise exist only in a run artifact. It has NOT passed the gate or the build.
Review before building on it." >/dev/null 2>&1; then
    log "committed uncommitted work as WIP"
  else
    warn "could not commit loose changes"
  fi
fi

# --- push ---------------------------------------------------------------------
REMOTE="https://x-access-token:${LOOP_PROJECT_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# --force-with-lease, not --force: this branch belongs to the loop, and a later
# run legitimately rewrites it — but never at the cost of clobbering a commit
# somebody else pushed while the run was going.
#
# THE LEASE VALUE IS PASSED EXPLICITLY, and that is not a style choice.
#
# Bare `--force-with-lease` works out what to expect from the remote-tracking
# ref, and it finds that ref through the remote's FETCH REFSPEC. We push to a
# URL rather than to `origin`, because checkout runs with
# persist-credentials: false and `origin` therefore carries no token. A URL is
# an anonymous remote with no fetch refspec, so the lookup finds nothing — and
# git does not complain, it silently falls back to expecting the branch NOT TO
# EXIST. The server disagrees, and the push is rejected with "stale info".
#
# That failure is invisible on a first run, because the branch really is new.
# It bites on the SECOND failure on the same issue — the resume case — where
# the push is refused, `.loop/preserved-branch` is never written, and
# escalate.sh then tells the owner their work was not pushed. Which is the
# exact report this whole file exists to stop being wrong.
#
# origin/$BRANCH is present whenever the branch exists on the server: the
# implement job checks out with fetch-depth: 0. When it is absent the branch is
# new, there is nothing to clobber, and the flag is dropped entirely.
LEASE="$(git rev-parse --verify --quiet "origin/${BRANCH}" 2>/dev/null || true)"
if [[ -n "$LEASE" ]]; then
  log "pushing $BRANCH with a lease on ${LEASE:0:12}"
else
  log "pushing $BRANCH — no remote branch yet, so no lease is needed"
fi

if git push ${LEASE:+--force-with-lease="refs/heads/${BRANCH}:${LEASE}"} \
     "$REMOTE" "HEAD:refs/heads/${BRANCH}" >/dev/null 2>&1; then
  URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/tree/${BRANCH}"

  # Leave a note for escalate.sh, which runs next and has to tell the owner
  # whether their work survived.
  #
  # It used to answer that with `git ls-remote --heads origin`, which cannot work
  # here: the implement job checks out with persist-credentials: false against a
  # private repository, so `origin` has no credential and the query fails or
  # hangs. The report then said "no branch was pushed" moments after this step
  # pushed one — and someone reads that and rebuilds work that already exists.
  # A file written by the step that did the pushing cannot be wrong about it.
  mkdir -p "$LOOP_DIR"
  printf '%s\n' "$BRANCH" > "$LOOP_DIR/preserved-branch"

  log "preserved work on branch $BRANCH"
  notice "Work preserved on branch ${BRANCH} — nothing was lost. ${URL}"
  summary "### Work preserved"
  summary ""
  summary "This run failed, but the code is safe on \`${BRANCH}\`: [view branch](${URL})"
  summary ""
  summary "It has **not** passed the gate or the build. The next run on this issue continues from it."
  set_output "preserved_branch" "$BRANCH"
else
  warn "could not push $BRANCH — the work remains in the run artifact only"
fi

exit 0
