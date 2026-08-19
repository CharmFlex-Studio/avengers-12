#!/usr/bin/env bash
# Make every board card agree with the labels on its issue.
#
# The harness moves a card at each point where BASH changes a label:
# preflight.sh claims and moves to In Progress, escalate.sh blocks and moves to
# Blocked, the stale sweep and the unblock path move back to Todo, and
# loop-board-done.yml moves to Done on merge. Every one of those is a pair.
#
# Two things were never paired, and both left the board lying:
#
#   1. TRIAGE. The triage skill sets loop:ready / loop:needs-spec / loop:blocked
#      from its verdicts, and it has write access to labels and nothing else --
#      by design, so a model never drives the board directly. Nothing then moved
#      the card. A BLOCKED verdict left the card sitting in Todo, where it reads
#      as available work; a READY verdict left an earlier card stranded in
#      Blocked.
#
#   2. A HUMAN clicking a label in the GitHub UI. loop.yml has no
#      `issues: labeled` trigger, so nothing runs at all and no card moves.
#
# So the pairing is done here instead, in bash, from the labels as they actually
# stand. The model proposes a verdict; this disposes of the card. It is a
# reconcile rather than a transition: it reads the labels, works out the lane
# they imply, and moves anything that disagrees. That makes it safe to run at any
# point and safe to run twice.
#
# Usage: avengers-12/lib/sync-board.sh [--dry-run]
#
# Always exits 0. The board is a tracking surface, not a safety control: a
# misconfigured board must degrade to a warning and never fail a run that is
# otherwise fine.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"

require_cmd gh jq
loop_init_dirs

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if ! board_enabled; then
  log "board not configured (LOOP_PROJECT_NUMBER / LOOP_PROJECT_OWNER unset) — nothing to sync"
  exit 0
fi

# --- what lane do these labels mean? -----------------------------------------
# Precedence, highest first. It is the same order the picker and the triage
# skill's label-mode table use, and the order matters: an issue can briefly
# carry two of these while a relabel is half-applied, and the further along the
# pipeline a label is, the more it should win.
#
# loop:ready and loop:needs-spec both mean Todo. Todo is "not claimed, not
# blocked, not in review" -- needs-spec is a note about the issue's quality, not
# a different place in the pipeline.
lane_for_labels() {
  local labels="$1"
  if   printf '%s\n' "$labels" | grep -qxF "$LOOP_LABEL_IN_REVIEW";   then printf '%s' "$LOOP_COL_IN_REVIEW"
  elif printf '%s\n' "$labels" | grep -qxF "$LOOP_LABEL_IN_PROGRESS"; then printf '%s' "$LOOP_COL_IN_PROGRESS"
  elif printf '%s\n' "$labels" | grep -qxF "$LOOP_LABEL_BLOCKED";     then printf '%s' "$LOOP_COL_BLOCKED"
  elif printf '%s\n' "$labels" | grep -qxF "$LOOP_LABEL_READY";       then printf '%s' "$LOOP_COL_TODO"
  elif printf '%s\n' "$labels" | grep -qxF "$LOOP_LABEL_NEEDS_SPEC";  then printf '%s' "$LOOP_COL_TODO"
  fi
  # No loop label at all prints nothing, and the caller skips the issue. An
  # issue the loop has never touched is not the loop's card to move.
}

# --- current card positions, in ONE call -------------------------------------
# board_set_status re-reads the whole item list for every issue it touches, so
# calling it blindly for every open issue costs one full listing each. The
# listing is done once here and only genuine disagreements are written.
ITEMS="$LOOP_DIR/board-items.json"
if ! gh project item-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" \
       --format json --limit 500 > "$ITEMS" 2>/dev/null; then
  warn "board: cannot list items on project $BOARD_OWNER/#$BOARD_NUMBER — skipping sync"
  exit 0
fi

# Same field lookup board_items_with_status uses: `gh project item-list` exports
# each single-select field under its lower-cased name, so Status arrives as
# `.status`, with `.[$f]` kept for a board whose field is named something else.
current_lane_of() {
  jq -r --arg f "$BOARD_STATUS_FIELD" --argjson n "$1" '
    .items[]?
    | select(.content.type == "Issue" and .content.number == $n)
    | (.[$f] // .[$f | ascii_downcase] // .status // "")
  ' "$ITEMS" 2>/dev/null | head -n1
}

# --- every open issue carrying a loop label ----------------------------------
ISSUES="$LOOP_DIR/board-sync-issues.json"
if ! gh issue list --state open --limit 200 --json number,labels > "$ISSUES" 2>/dev/null; then
  warn "board: cannot list open issues — skipping sync"
  exit 0
fi

MOVED=0
FAILED=0
CHECKED=0
group "board: reconciling card lanes with labels"

# Read on fd 3, not stdin. Every iteration shells out to `gh`, which inherits
# stdin — and anything that reads it swallows the rest of the queue. The loop
# would then process the first issue and stop, silently, looking exactly like a
# board that only sometimes updates.
while IFS=$'\t' read -r NUMBER LABELS_CSV <&3; do
  [[ -n "$NUMBER" ]] || continue

  LABELS="$(printf '%s' "$LABELS_CSV" | tr ',' '\n')"
  WANT="$(lane_for_labels "$LABELS")"
  [[ -n "$WANT" ]] || continue          # no loop label — not ours to move

  CHECKED=$((CHECKED + 1))
  HAVE="$(current_lane_of "$NUMBER")"

  if [[ "$HAVE" == "$WANT" ]]; then
    log "board: #$NUMBER already in '$WANT'"
    continue
  fi

  # A card parked in a lane the config does not name is a human's doing --
  # a custom column, or a workflow this harness knows nothing about. Leave it,
  # and say so, rather than yanking it somewhere the owner did not ask for.
  case "$HAVE" in
    ""|"$LOOP_COL_TODO"|"$LOOP_COL_IN_PROGRESS"|"$LOOP_COL_IN_REVIEW"|"$LOOP_COL_BLOCKED"|"$LOOP_COL_DONE") ;;
    *)
      warn "board: #$NUMBER is in '$HAVE', which is not one of the configured columns — leaving it alone"
      continue
      ;;
  esac

  if [[ "$DRY_RUN" == true ]]; then
    notice "board (dry run): #$NUMBER would move '${HAVE:-<none>}' → '$WANT'"
    MOVED=$((MOVED + 1))
  else
    log "board: #$NUMBER '${HAVE:-<none>}' → '$WANT' (labels say so)"
    board_set_status "$NUMBER" "$WANT"
    # Count the move, not the attempt. This used to increment either way, so a
    # run where every single write was refused still finished with
    # "moved 4 of 5" -- a summary that contradicted the four warnings above it.
    if [[ "$BOARD_LAST_MOVE_OK" == true ]]; then
      MOVED=$((MOVED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  fi
done 3< <(
  jq -r '.[] | [(.number|tostring), ([.labels[].name] | join(","))] | @tsv' "$ISSUES" 2>/dev/null || true
)

endgroup

if [[ "$FAILED" -gt 0 ]]; then
  caution "Board: $FAILED of $CHECKED card(s) could not be moved. The labels are right; the board is behind them. See the warnings above — every one of them names its own cause."
fi
if [[ "$MOVED" -eq 0 && "$FAILED" -eq 0 ]]; then
  log "board: $CHECKED labelled issue(s) checked, every card already agreed"
elif [[ "$MOVED" -gt 0 ]]; then
  notice "board: moved $MOVED of $CHECKED labelled issue(s) into the lane their labels imply"
fi
exit 0
