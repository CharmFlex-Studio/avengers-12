#!/usr/bin/env bash
# Read (or write) the base branch a loop branch was cut from.
#
# The guard this replaces did not work. preflight.sh used to test
# `git merge-base "origin/$BASE" "origin/$BRANCH"`, which succeeds whenever two
# refs share ANY ancestor — always true inside one repository. So the refusal
# branch was unreachable, and running an issue against `main` and then re-running
# it against a feature branch happily reused the branch, merged `main` into it,
# and opened a pull request that dragged all of `main` along.
#
# History shape cannot answer "which branch was this cut from?" — that fact is
# only knowable if somebody records it. So it is recorded, in a trailer on an
# empty marker commit made when the branch is created:
#
#     chore(loop): start issue 42
#
#     Loop-Base-Branch: jiaming/transcription
#
# An empty commit is the only place available. `.loop/` is gitignored, the first
# real commit is written by the agent rather than the harness, and a side ref
# would need a push at a point where the job holds no push credential.
#
# Usage:
#   avengers-12/lib/recorded-base.sh read  <ref> <issue>      print the recorded base, or nothing
#   avengers-12/lib/recorded-base.sh write <issue> <base>     make the marker commit on HEAD
#
# `read` needs the ISSUE NUMBER as well as the ref. See read_base below: without
# it there is no way to tell this branch's own marker from one it inherited.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

TRAILER="Loop-Base-Branch"

read_base() {
  local ref="${1:?usage: recorded-base.sh read <ref> <issue>}"
  local issue="${2:-}"

  # IDENTIFY THE MARKER BY NAME, NOT BY POSITION.
  #
  # This used to collect every `Loop-Base-Branch:` line reachable from $ref and
  # take `tail -n1`, the oldest, on the reasoning that the oldest marker is the
  # one written when the branch was created.
  #
  # That is only true while exactly one marker exists in the repository. A
  # marker commit does not go away when its pull request merges — it becomes
  # part of the shared history, and every branch cut afterwards inherits it. So
  # once issue 5 has merged, `read origin/loop/issue-9` sees:
  #
  #     jiaming/feature     <- issue 9's own marker
  #     main                <- issue 5's, inherited through the merge
  #
  # and `tail -n1` confidently returns `main`. Two things then happen, both bad:
  # a dispatched re-run refuses to start and tells the owner to delete a branch
  # that is fine, and a reply-to-resume silently adopts `main`, merges it in,
  # and opens the pull request against the wrong base — which is precisely the
  # damage the recorded base exists to prevent.
  #
  # write_base already puts the issue number in the SUBJECT. Use it. Issue 5's
  # marker cannot be mistaken for issue 9's when the subject is part of the
  # question.
  if [[ -z "$issue" ]]; then
    warn "recorded-base.sh read: no issue number given — refusing to guess which marker is this branch's"
    return 1
  fi
  if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
    warn "recorded-base.sh read: issue number must be numeric, got '$issue'"
    return 1
  fi

  local sha
  # --basic-regexp pins the pattern dialect. It is the default, but a repository
  # or a runner image can set grep.patternType, and under `extended` the parens
  # in `chore(loop)` become a group — the pattern would then quietly match
  # nothing and the guard would abstain without saying so.
  # ^ and $ anchor to the whole subject line, so `issue 1` never matches
  # `issue 19`.
  sha="$(git log --format='%H' --basic-regexp \
           --grep="^chore(loop): start issue ${issue}\$" -1 "$ref" 2>/dev/null || true)"

  # No marker for this issue: a branch created before markers existed. Print
  # nothing, exactly as before — preflight.sh treats an empty answer as "the
  # guard is abstaining" and says so.
  [[ -n "$sha" ]] || return 0

  git log -1 --format='%B' "$sha" 2>/dev/null \
    | sed -n "s/^${TRAILER}:[[:space:]]*//p" \
    | head -n1
}

write_base() {
  local issue="${1:?usage: recorded-base.sh write <issue> <base>}"
  local base="${2:?usage: recorded-base.sh write <issue> <base>}"
  git commit --allow-empty -q \
    -m "chore(loop): start issue ${issue}" \
    -m "${TRAILER}: ${base}" \
    || { warn "could not write the base-branch marker commit"; return 1; }
  log "recorded base branch '$base' on the marker commit"
  return 0
}

case "${1:-}" in
  read)  shift; read_base "$@" ;;
  write) shift; write_base "$@" ;;
  *)     die "usage: recorded-base.sh read <ref> <issue> | write <issue> <base>" ;;
esac
