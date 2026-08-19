#!/usr/bin/env bash
# Builds the evidence packet the verifier judges from, and owns the attempt
# counter.
#
# The orchestrator invokes this between IMPLEMENT and VERIFY. It is a script on
# disk precisely so the orchestrator can run it but not author its contents:
# the verifier must read a diff that bash produced, not a summary the
# implementer wrote about itself.
#
# Usage: avengers-12/lib/evidence.sh <issue-number>
#
# Writes:
#   .loop/evidence/issue.md    the issue as filed
#   .loop/evidence/diff.patch  merge-base..HEAD, including staged work
#   .loop/evidence/build.txt  compile + unit test output
#   .loop/evidence/files.txt   changed paths
#   .loop/attempts.json        incremented, with per-attempt history
#
# Always exits 0 on a failing build. A red build is evidence, not an error --
# the verifier needs to see it to REJECT for the right reason.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

require_cmd git jq
ISSUE="${1:-}"
[[ -n "$ISSUE" ]] || die "usage: evidence.sh <issue-number>"

loop_init_dirs

# --- attempt counter (bash-owned; the model cannot lose count) ---------------
MAX_ATTEMPTS="${LOOP_MAX_ATTEMPTS:-3}"
ATTEMPT="$(( $(loop_attempts) + 1 ))"

# Refuse, don't just count. The limit is documented as machine-enforced in
# avengers-12/rules/constraints.md, and a counter the orchestrator is merely asked to read is
# not machine enforcement — it is the same "ask the model nicely" this harness
# exists to avoid.
if [[ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]]; then
  problem "attempt $ATTEMPT exceeds the limit of $MAX_ATTEMPTS"
  {
    printf '## Loop blocked — attempt limit reached\n\n'
    printf '**Stopped at:** EVIDENCE (attempt %s of %s)\n\n' "$ATTEMPT" "$MAX_ATTEMPTS"
    printf '**What I need from you:** three attempts did not satisfy the verifier.\n'
    printf 'Decide whether the acceptance criteria need rewriting or the issue needs splitting.\n\n'
  } > "$LOOP_DIR/blocked.md"
  die "attempt limit reached — refusing to produce further evidence"
fi

log "evidence for issue #$ISSUE, attempt $ATTEMPT of $MAX_ATTEMPTS"

# issue.md is written once by preflight.sh, deliberately: the agent holds no
# GitHub credential, so there is nothing here to refresh it with.
[[ -s "$LOOP_EVIDENCE_DIR/issue.md" ]] || warn "no issue.md in the evidence packet"

# --- the diff ----------------------------------------------------------------
if ! MERGE_BASE="$(git merge-base "origin/$LOOP_BASE_BRANCH" HEAD 2>/dev/null)"; then
  MERGE_BASE="$(git merge-base "$LOOP_BASE_BRANCH" HEAD 2>/dev/null || echo HEAD)"
fi

# Include uncommitted work: the implementer is told not to commit, so at this
# point the change is still in the working tree.
git add -A -- . >/dev/null 2>&1 || true
git diff --cached "$MERGE_BASE" > "$LOOP_EVIDENCE_DIR/diff.patch" 2>/dev/null || true
if [[ ! -s "$LOOP_EVIDENCE_DIR/diff.patch" ]]; then
  git diff "$MERGE_BASE"..HEAD > "$LOOP_EVIDENCE_DIR/diff.patch" 2>/dev/null || true
fi
git diff --cached --name-only "$MERGE_BASE" > "$LOOP_EVIDENCE_DIR/files.txt" 2>/dev/null || true

FILES_CHANGED="$(wc -l < "$LOOP_EVIDENCE_DIR/files.txt" | tr -d ' ')"
log "diff: $FILES_CHANGED file(s), $(wc -l < "$LOOP_EVIDENCE_DIR/diff.patch" | tr -d ' ') line(s) of patch"

# --- the build ---------------------------------------------------------------
# Runs the SAME verify steps the workflow runs after the agent exits, from
# avengers-12/config.yml. It used to invoke Gradle with a hardcoded task list,
# which had two problems: no other project could use it, and the evidence pass
# could drift from the real gate — the agent would see green here and the job
# would fail later on a command this file had never heard of.
#
# The build result is EVIDENCE, not a script error. A failing build is exactly
# what the next attempt needs to read, so the exit code is recorded and the
# script carries on.
group "Verify (evidence pass, attempt $ATTEMPT)"
set +e
"$HERE/verify.sh" "$LOOP_EVIDENCE_DIR/files.txt" > "$LOOP_EVIDENCE_DIR/build.txt" 2>&1
BUILD_STATUS=$?
set -e
tail -n 40 "$LOOP_EVIDENCE_DIR/build.txt" >&2 || true
endgroup

if [[ "$BUILD_STATUS" -eq 0 ]]; then
  log "build: PASS"
else
  warn "build: FAIL (exit $BUILD_STATUS) — recorded as evidence, not treated as a script error"
fi

# --- update the counter ------------------------------------------------------
TMP="$(mktemp)"
jq \
  --argjson attempt "$ATTEMPT" \
  --argjson issue "$ISSUE" \
  --argjson files "${FILES_CHANGED:-0}" \
  --argjson build "$BUILD_STATUS" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.issue = $issue
   | .attempts = $attempt
   | .history += [{attempt: $attempt, at: $at, files_changed: $files, build_exit: $build}]' \
  "$LOOP_ATTEMPTS_FILE" > "$TMP" && mv "$TMP" "$LOOP_ATTEMPTS_FILE"

# --- quarantine the implementer's rationale ---------------------------------
# The verifier must judge the diff, not the maker's account of the diff. It has
# Read and Bash, so it *could* open .loop/changes.md sitting right next to the
# evidence it was pointed at. Moving the file outside the repo means reading it
# takes deliberate searching rather than one obvious `cat`.
#
# Be clear-eyed: this raises the bar, it is not a hard boundary. Real isolation
# would need a separate filesystem view for the verifier, which the action does
# not give us. The honest state of this control is written up in avengers-12/README.md.
PRIVATE_DIR="${RUNNER_TEMP:-/tmp}/loop-private"
mkdir -p "$PRIVATE_DIR"
if [[ -f "$LOOP_DIR/changes.md" ]]; then
  mv "$LOOP_DIR/changes.md" "$PRIVATE_DIR/changes-attempt-$ATTEMPT.md"
  log "quarantined changes.md → $PRIVATE_DIR/changes-attempt-$ATTEMPT.md"
fi

# Never shown to the verifier — this is the orchestrator's bookkeeping.
set_output "attempt" "$ATTEMPT"
set_output "build_status" "$BUILD_STATUS"
set_output "files_changed" "${FILES_CHANGED:-0}"

cat <<EOF

Evidence packet ready (attempt $ATTEMPT):
  .loop/evidence/issue.md     the acceptance criteria
  .loop/evidence/diff.patch   $FILES_CHANGED file(s)
  .loop/evidence/build.txt   build exit $BUILD_STATUS
EOF
