#!/usr/bin/env bash
# Run the `verify` steps from config.yml. This is how a change proves itself.
#
# These commands used to be written into loop.yml as two hardcoded Gradle
# invocations. That was the single biggest thing stopping anyone else using the
# harness: a Node project, a Go project, a Rails project all need different
# commands, and none of them should have to edit a workflow to say so.
#
# Every step must pass. A failure here means nothing is pushed and no pull
# request is opened — which is the point. A step that cannot run is a step that
# proves nothing, so an empty verify list is refused rather than skipped.
#
# Usage: avengers-12/lib/verify.sh [changed-files-file]
#
# The changed-files list defaults to .loop/changed-files.txt, written by
# check-gate.sh. It is what `when:` is matched against.
#
# With no such list -- an agent running this by hand mid-run, before check-gate
# has produced one -- every `when:` step RUNS. Skipping them instead would mean a
# missing file quietly narrowed the checks, and the agent would read green from a
# pass that never touched half the project. Not knowing what changed is a reason
# to check more, never less.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

require_cmd jq python3
avengers_load_config

CHANGED="${1:-$LOOP_DIR/changed-files.txt}"

COUNT="$(jq '(.verify // []) | length' "$_AVENGERS_CONFIG_JSON")"
if [[ "${COUNT:-0}" -eq 0 ]]; then
  problem "config.yml has no verify steps"
  die "nothing would prove a change works — add at least one step under 'verify:'"
fi

# `when` is matched with the same glob rules the gate uses, so a path pattern
# means one thing across the whole harness. Reusing gate_check.py's translator
# rather than shelling out to `grep` also keeps `**` crossing directories and
# `*` not, which is the part everyone gets wrong.
matches_when() {
  local pattern="$1"
  AVENGERS_LIB="$HERE" python3 "$HERE/match_paths.py" "$pattern" "$CHANGED"
}

# Decided once, up front, so the reason appears in the log rather than being
# inferred from which steps ran.
KNOW_CHANGED=true
if [[ ! -s "$CHANGED" ]]; then
  KNOW_CHANGED=false
  warn "no changed-files list at '$CHANGED' — running every step, including conditional ones"
fi

FAILED=0
for i in $(seq 0 $((COUNT - 1))); do
  NAME="$(jq -r ".verify[$i].name" "$_AVENGERS_CONFIG_JSON")"
  RUN="$(jq -r ".verify[$i].run" "$_AVENGERS_CONFIG_JSON")"
  DIR="$(jq -r ".verify[$i].workingDirectory // \".\"" "$_AVENGERS_CONFIG_JSON")"
  WHEN="$(jq -r ".verify[$i].when // empty" "$_AVENGERS_CONFIG_JSON")"
  CHMOD="$(jq -r ".verify[$i].chmod // empty" "$_AVENGERS_CONFIG_JSON")"

  if [[ -n "$WHEN" ]] && [[ "$KNOW_CHANGED" == true ]]; then
    if ! matches_when "$WHEN"; then
      log "verify '$NAME': diff does not touch '$WHEN' — skipping"
      continue
    fi
    log "verify '$NAME': diff touches '$WHEN'"
  fi

  [[ -n "$CHMOD" ]] && chmod +x "$DIR/${CHMOD#./}" 2>/dev/null || true

  group "verify: $NAME"
  log "in '$DIR': $RUN"
  if ( cd "$DIR" && eval "$RUN" ); then
    endgroup
    notice "verify '$NAME' passed"
  else
    STATUS=$?
    endgroup
    problem "verify '$NAME' failed (exit $STATUS)"
    FAILED=1
    # Keep going. Seeing every failing step in one run beats fixing them one
    # per run, and each run costs a slot out of the daily budget.
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  die "one or more verify steps failed — nothing will be pushed"
fi

notice "all verify steps passed"
