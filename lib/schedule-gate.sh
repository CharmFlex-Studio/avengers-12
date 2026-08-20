#!/usr/bin/env bash
# Should this scheduled run carry on, or stop here?
#
# GitHub cannot read config.yml when it decides whether to fire a cron, so the
# workflow has a fixed schedule and this script decides what to do about it.
# That is the only way to let somebody turn the timer on by changing one number
# instead of editing YAML.
#
# Only scheduled runs come through here. A run you started yourself, or one from
# replying on an issue, is never blocked: you asked for it.
#
# Usage: avengers-12/lib/schedule-gate.sh
#
# Exit 0  carry on
# Exit 1  stop, and the workflow ends quietly

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

# The timer's off switch, and the only one you can flip without a commit.
#
# It stops the CLOCK, not the loop: pressing Run in the Actions tab still works,
# and replying to a blocked issue still resumes it. That is the whole point of
# having it separate from LOOP_PAUSE_ALL, which stops those too.
#
# A repo variable rather than a config key because turning the timer off is
# usually something you want to do NOW — you are on holiday, or a run is
# misbehaving overnight. Editing `schedule.everyHours: 0` means a commit, a
# push, and a merge to the default branch before it takes effect. This takes
# effect on the next firing.
#
# The variable is the override; config.yml is the default. Same rule as
# LOOP_MAX_RUNS_PER_DAY and the rest.
#
# is_true accepts true/yes/on/1 in any case, because this is a STOP switch and
# the only mistake that hurts is one that fails to stop. Unset is still off.
if is_true "${LOOP_PAUSE_SCHEDULE:-}"; then
  notice "Timer paused (repo variable LOOP_PAUSE_SCHEDULE=true). Runs you start yourself still work."
  exit 1
fi

EVERY="$(cfg schedule.everyHours 24)"

# Anything that is not a whole number is treated as off. A typo should stop the
# timer, not start it every hour.
if [[ ! "$EVERY" =~ ^[0-9]+$ ]]; then
  warn "schedule.everyHours is '$EVERY', which is not a whole number — treating the timer as off"
  exit 1
fi

if [[ "$EVERY" -eq 0 ]]; then
  log "schedule is off (schedule.everyHours: 0) — nothing to do"
  exit 1
fi

# One hour is the floor. GitHub is asked once an hour, so anything smaller would
# just mean "every time you are asked" while reading as though it meant less.
if [[ "$EVERY" -lt 1 ]]; then
  EVERY=1
fi

# The last run of any kind, from the run log. An entry is written whenever a run
# reaches an outcome, so this is the same record the daily cap counts.
#
# This is a clock that something else has to wind. EVERY scheduled firing that
# gets past this gate must end with an entry here, including the ones that find
# an empty queue and do nothing — the workflow's "Record an empty scheduled run"
# step exists for exactly that. Without it the newest timestamp never moves, the
# comparison below stays true for ever, and the loop starts a full run every
# hour while schedule.everyHours appears to be ignored. An empty queue is the
# normal state of a healthy repository, so that is the common case, not an edge.
LAST=""
if [[ -f "$LOOP_RUN_LOG" ]]; then
  LAST="$(grep -oE '"run_id":"[0-9TZ:.-]+"' "$LOOP_RUN_LOG" 2>/dev/null \
          | sed 's/.*"run_id":"//; s/"//' | sort | tail -n1 || true)"
fi

if [[ -z "$LAST" ]]; then
  notice "Scheduled run: no previous run on record, starting."
  exit 0
fi

# Seconds since that timestamp. GNU date and BSD date disagree about flags, so
# both are tried; if neither parses it, carry on rather than block forever.
NOW_S="$(date -u +%s)"
LAST_S="$(date -u -d "$LAST" +%s 2>/dev/null \
       || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST" +%s 2>/dev/null || echo "")"
if [[ -z "$LAST_S" ]]; then
  warn "could not read the time of the last run ('$LAST') — starting rather than stalling"
  exit 0
fi

ELAPSED_H=$(( (NOW_S - LAST_S) / 3600 ))
if [[ "$ELAPSED_H" -lt "$EVERY" ]]; then
  log "last run was ${ELAPSED_H}h ago, schedule wants ${EVERY}h — stopping"
  exit 1
fi

notice "Scheduled run: ${ELAPSED_H}h since the last one, schedule wants ${EVERY}h. Starting."
exit 0
