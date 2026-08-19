#!/usr/bin/env bash
# GitHub Projects v2 helpers. Source this after common.sh.
#
# Projects v2 is invisible to GITHUB_TOKEN and to the Claude GitHub App, so every
# call here needs GH_TOKEN to hold the fine-grained PAT (account-level
# "Projects: Read and write").
#
# Board operations are deliberately NON-FATAL. The board is how a human tracks
# the queue; it is not a safety control. A misconfigured board should degrade to
# a warning, never abort a run that is otherwise fine — losing the card position
# is annoying, losing the work is not acceptable.

# shellcheck source=/dev/null
[[ -n "${LOOP_DIR:-}" ]] || { echo "source common.sh first" >&2; exit 1; }

BOARD_NUMBER="${LOOP_PROJECT_NUMBER:-}"
BOARD_OWNER="${LOOP_PROJECT_OWNER:-}"
BOARD_STATUS_FIELD="${LOOP_PROJECT_STATUS_FIELD:-$(cfg board.statusField "Status")}"

_board_cache_dir="${LOOP_DIR}/.board-cache"

board_enabled() {
  [[ -n "$BOARD_NUMBER" && -n "$BOARD_OWNER" ]]
}

_board_require() {
  if ! board_enabled; then
    warn "board not configured (LOOP_PROJECT_NUMBER / LOOP_PROJECT_OWNER unset) — skipping board update"
    return 1
  fi
  return 0
}

# Cache the project metadata for the life of the job; it costs two API calls.
_board_meta() {
  mkdir -p "$_board_cache_dir"
  local f="$_board_cache_dir/project.json"
  if [[ ! -s "$f" ]]; then
    gh project view "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json > "$f" 2>/dev/null \
      || { warn "cannot read project $BOARD_OWNER/#$BOARD_NUMBER"; return 1; }
  fi
  cat "$f"
}

_board_fields() {
  mkdir -p "$_board_cache_dir"
  local f="$_board_cache_dir/fields.json"
  if [[ ! -s "$f" ]]; then
    gh project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json --limit 50 > "$f" 2>/dev/null \
      || { warn "cannot list fields for project #$BOARD_NUMBER"; return 1; }
  fi
  cat "$f"
}

board_project_id() { _board_meta | jq -r '.id // empty'; }

# board_status_option_id <option-name> -> prints the single-select option id
board_status_option_id() {
  local want="$1"
  _board_fields | jq -r --arg f "$BOARD_STATUS_FIELD" --arg o "$want" '
    .fields[]? | select(.name == $f) | .options[]? | select(.name == $o) | .id
  ' | head -n1
}

board_status_field_id() {
  _board_fields | jq -r --arg f "$BOARD_STATUS_FIELD" '.fields[]? | select(.name == $f) | .id' | head -n1
}

# board_item_id_for_issue <issue-number> -> prints the project item id
board_item_id_for_issue() {
  local issue="$1"
  gh project item-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json --limit 500 2>/dev/null \
    | jq -r --argjson n "$issue" '.items[]? | select(.content.number == $n) | .id' | head -n1
}

# board_ensure_item <issue-number> -> prints the project item id
#
# The board is the source of truth, and a board only tells the truth about work
# it can see. Nothing used to put an issue on it except a manual run of
# seed-board.sh, so anything filed after the seeding was worked on invisibly:
# labels moved, runs happened, and the board showed nothing.
#
# Adding is idempotent — `gh project item-add` on an issue that is already there
# returns the existing item — but the lookup is done first anyway so the common
# case costs no write.
board_ensure_item() {
  local issue="$1" item_id url
  _board_require || return 0

  item_id="$(board_item_id_for_issue "$issue")" || true
  if [[ -n "$item_id" ]]; then
    printf '%s\n' "$item_id"
    return 0
  fi

  url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/issues/${issue}"

  # Take the id straight from the add when gh gives it. That is the only way to
  # get it without asking the API a second question -- see the retry below for
  # why asking twice is not reliable.
  local added
  added="$(gh project item-add "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$url" \
            --format json 2>/dev/null || true)"
  if [[ -z "$added" ]]; then
    # Either the add failed, or this gh predates `--format json` on item-add.
    # Those must not be confused: reporting "could not add" for a version
    # difference would be a lie that hides a working board. Retry plainly and
    # let the exit code decide.
    if gh project item-add "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$url" >/dev/null 2>&1; then
      added="{}"
    else
      warn "board: could not add issue #$issue to project #$BOARD_NUMBER"
      return 0
    fi
  fi
  log "board: added issue #$issue to project #$BOARD_NUMBER"

  item_id="$(jq -r '.id // empty' <<<"$added" 2>/dev/null || true)"
  if [[ -n "$item_id" ]]; then
    printf '%s\n' "$item_id"
    return 0
  fi

  # Older gh does not print the id, so it has to be read back -- and this is
  # where a card silently fails to move. Projects v2 is GraphQL-backed and its
  # item listing does NOT reflect an add immediately. One read used to be enough
  # in testing and not enough in a real run: preflight added the card, asked for
  # it, got nothing, and skipped the move. The card then sat in whatever lane it
  # was in for the entire implement run, and the In Review move forty minutes
  # later worked perfectly -- because by then the listing had caught up. That
  # asymmetry is exactly what it looks like from the outside: "In Review works,
  # In Progress never does."
  local attempt
  for attempt in 1 2 3 4 5; do
    item_id="$(board_item_id_for_issue "$issue")" || true
    if [[ -n "$item_id" ]]; then
      [[ "$attempt" -gt 1 ]] && log "board: item for #$issue appeared after ${attempt} reads"
      printf '%s\n' "$item_id"
      return 0
    fi
    sleep "$attempt"
  done

  warn "board: issue #$issue was added to project #$BOARD_NUMBER but the item did not appear in time"
  return 0
}

# board_report_mode
#
# Say, once per job and on the run summary, whether cards are going to move.
#
# This exists because of a specific afternoon: an owner watching a board, seeing
# an issue picked up and labelled loop:in-progress, and no card moving. Every
# board call is non-fatal by design, so the only trace was one `warn` inside a
# collapsed log group. The loop knew perfectly well it had no board and never
# said so anywhere the owner was looking.
board_report_mode() {
  if ! board_enabled; then
    caution "Board: not configured — labels move, cards do not. Set the LOOP_PROJECT_NUMBER and LOOP_PROJECT_OWNER repository variables, or ignore this if you run on labels alone."
    return 0
  fi
  if [[ -z "$(board_project_id)" ]]; then
    caution "Board: #$BOARD_NUMBER for '$BOARD_OWNER' cannot be read — cards will not move. Check the PAT has Projects: Read and write, and that an org owner approved it."
    return 0
  fi
  log "board: $BOARD_OWNER / project #$BOARD_NUMBER"
  return 0
}

# board_set_status <issue-number> <status-name>
# Always returns 0. Warns on any failure.
board_set_status() {
  local issue="$1" status="$2"
  _board_require || return 0

  local project_id field_id option_id item_id
  project_id="$(board_project_id)"       || true
  field_id="$(board_status_field_id)"    || true
  option_id="$(board_status_option_id "$status")" || true
  # Add-if-missing rather than lookup-only: a status update that silently skips
  # because the card was never created is how the board falls behind reality.
  item_id="$(board_ensure_item "$issue")"         || true

  if [[ -z "$project_id" || -z "$field_id" ]]; then
    caution "Board: cannot reach project #$BOARD_NUMBER or its '$BOARD_STATUS_FIELD' field — issue #$issue stays where it is."
    return 0
  fi
  if [[ -z "$option_id" ]]; then
    caution "Board: no '$BOARD_STATUS_FIELD' option named '$status' — issue #$issue stays where it is. Add that column, or rename it under board.columns in $AVENGERS_CONFIG."
    return 0
  fi
  if [[ -z "$item_id" ]]; then
    caution "Board: issue #$issue is not on project #$BOARD_NUMBER and could not be added — it stays where it is."
    return 0
  fi

  if gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$field_id" \
      --single-select-option-id "$option_id" >/dev/null 2>&1; then
    log "board: issue #$issue → $status"
  else
    caution "Board: failed to move issue #$issue to '$status'. The token needs Projects: Read and write on '$BOARD_OWNER'."
  fi
  return 0
}

# board_items_with_status <status-name> -> JSON lines of {number,title,url}
#
# Read by pick-next.sh to order the queue. `gh project item-list --format json`
# exports each single-select field under its lower-cased name, so the Status
# column arrives as `.status`; `.[$f]` is kept as a fallback for a board whose
# field is named something else via LOOP_PROJECT_STATUS_FIELD.
board_items_with_status() {
  local status="$1"
  _board_require || return 0
  gh project item-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json --limit 500 2>/dev/null \
    | jq -c --arg f "$BOARD_STATUS_FIELD" --arg s "$status" '
        .items[]?
        | select((.[$f] // .[$f | ascii_downcase] // .status // "") == $s)
        | select(.content.type == "Issue")
        | {number: .content.number, title: .content.title, url: .content.url}
      ' || warn "board: could not list items with status '$status'"
  return 0
}

# board_issue_order <status-name> -> issue numbers in the order the board returns
#
# This is the board's own ordering of a column, which is the closest thing the
# API gives us to "the order the owner dragged them into". It is advisory: the
# labels remain the eligibility filter, and the issue number remains the
# tiebreak for anything the board does not mention.
board_issue_order() {
  board_items_with_status "$1" | jq -r '.number' 2>/dev/null || true
}
