#!/usr/bin/env bash
# Check that the board can actually be driven, and that every column the config
# names really exists on it.
#
# Why this exists: every board operation in board.sh is deliberately non-fatal.
# The board tracks work, it is not a safety control, so a broken board must
# never kill a run that is otherwise fine. The cost of that choice is silence --
# `board: no 'Status' option named 'Blocked' — skipping` is a warning in the
# middle of a job log, and the first anyone notices is a card sitting in the
# wrong lane days later.
#
# So the warnings get a place to be loud, once, at setup time. Nothing here
# writes to the board.
#
# Usage:
#   avengers-12/lib/check-board.sh            human-readable, exit 1 on a problem
#   avengers-12/lib/check-board.sh --quiet    same exit code, no output
#
# Exit codes:
#   0  the board works, or is deliberately not configured (board.optional: true)
#   1  the board is configured and something about it is wrong

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true
say() { $QUIET || printf '%s\n' "$*"; }
bad() { $QUIET || printf '  ✗ %s\n' "$*" >&2; }
good() { $QUIET || printf '  ✓ %s\n' "$*"; }

PROBLEMS=0

# --- 1. is a board even wanted? ---------------------------------------------
if ! board_enabled; then
  if [[ "$LOOP_BOARD_OPTIONAL" == "true" ]]; then
    good "no board configured — running in label mode (board.optional: true)"
    say  "    Set the LOOP_PROJECT_NUMBER and LOOP_PROJECT_OWNER repository"
    say  "    variables to use a Projects v2 board."
    exit 0
  fi
  bad "board.optional is false but LOOP_PROJECT_NUMBER / LOOP_PROJECT_OWNER are not set"
  exit 1
fi

say "board: $BOARD_OWNER / project #$BOARD_NUMBER"

# --- 1b. can we talk to GitHub at all? --------------------------------------
# Everything below asks the Projects API a question, and every one of those
# questions fails the same way when there is no credential: empty answer, no
# error. Reporting that as "your board cannot be read" sends people to check
# their board number, their token scopes and their org approval, when the real
# answer is that this particular step was never given a token.
if ! command -v gh >/dev/null 2>&1; then
  good "gh is not installed here, so the board cannot be checked from this machine"
  say  "    This is not a board problem. Run it where gh is available, or read the"
  say  "    Board section of a workflow run."
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  good "gh is not authenticated here, so the board cannot be checked"
  say  "    This is not a board problem. Locally: run \`gh auth login\`."
  say  "    In a workflow: the step needs GH_TOKEN set to your Projects token."
  exit 0
fi

# --- 2. can the token read it? ----------------------------------------------
# The usual cause of failure here is not a missing board. It is a token without
# account-level "Projects: Read and write", which authenticates perfectly and
# then sees nothing.
PROJECT_ID="$(board_project_id 2>/dev/null || true)"
if [[ -z "$PROJECT_ID" ]]; then
  bad "cannot read project #$BOARD_NUMBER for owner '$BOARD_OWNER'"
  say "    Check, in this order:"
  say "      - the number and owner are right (read them off the board's URL)"
  say "      - /orgs/<owner>/ boards need the token's resource owner to be that org"
  say "      - the fine-grained PAT has Projects: Read and write"
  say "      - an org owner has APPROVED the token (pending tokens see nothing)"
  exit 1
fi
good "project resolves"

# --- 3. does the status field exist, under the name the config uses? --------
FIELD_ID="$(board_status_field_id 2>/dev/null || true)"
if [[ -z "$FIELD_ID" ]]; then
  bad "no field named '$BOARD_STATUS_FIELD' on the board"
  say "    Fields found: $(_board_fields 2>/dev/null | jq -r '[.fields[]?.name] | join(", ")')"
  say "    Rename the field, or set board.statusField in $AVENGERS_CONFIG."
  exit 1
fi
good "'$BOARD_STATUS_FIELD' field exists"

# --- 4. does every column the config names exist as an option? --------------
# This is the one that actually bites. A default GitHub Project ships with Todo,
# In Progress and Done -- no In Review, no Blocked. The loop then moves cards
# into two lanes that are not there, warns twice per run, and the owner sees
# work vanish from the board at exactly the moment it needs attention.
OPTIONS="$(_board_fields 2>/dev/null \
  | jq -r --arg f "$BOARD_STATUS_FIELD" '.fields[]? | select(.name == $f) | .options[]?.name')"

MISSING=""
for key in todo inProgress inReview blocked done; do
  want="$(cfg "board.columns.$key")"
  [[ -n "$want" ]] || continue
  if grep -qxF "$want" <<<"$OPTIONS"; then
    good "column '$want'  (board.columns.$key)"
  else
    bad "column '$want' is missing  (board.columns.$key)"
    MISSING="${MISSING}${want}"$'\n'
    PROBLEMS=$((PROBLEMS + 1))
  fi
done

if [[ -n "$MISSING" ]]; then
  say ""
  # `paste -sd', '` treats the argument as a LIST of delimiters and cycles
  # through them, so it joins with ',' then ' ' alternately. jq does it properly.
  say "    The board has: $(printf '%s' "$OPTIONS" | jq -R . | jq -rs 'join(", ")')"
  say ""
  say "    This is expected on a new board, not a mistake you made: a GitHub"
  say "    Project ships with Todo, In Progress and Done. The other two have to"
  say "    be added, and until they are, cards cannot reach them -- the run stays"
  say "    green and the card stays put."
  say ""
  say "    To add them:"
  say "      1. open the board"
  say "      2. click any card, then the '$BOARD_STATUS_FIELD' field"
  say "      3. Edit options -> New option, one per missing name above"
  say ""
  say "    Or, if your board already calls them something else, rename them in"
  say "    $AVENGERS_CONFIG under board.columns to match what you use."
fi

# --- 5. can the token WRITE? ------------------------------------------------
# Everything above is a read, and a read-only token passes every one of them.
# That is exactly how a board sails through setup and then silently refuses
# every move at run time: "Resource not accessible by personal access token",
# once per card, inside a job log nobody opens until the board looks wrong.
#
# The test is a no-op write: set some card's Status to the value it already has.
# GitHub still requires the write permission for that, so it proves access
# without moving anything or leaving a trace on the board.
group_written=false
# --limit 1 used to sample exactly one card and then report a fact about the
# whole board. A card added by board_ensure_item has NO status until something
# moves it, so the one card sampled was often the one card that could not be
# used — and the check skipped itself on a board full of usable ones.
FIRST_ITEM="$(gh project item-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" \
                --format json --limit 100 2>/dev/null \
              | jq -r --arg f "$BOARD_STATUS_FIELD" '
                  [.items[]?
                   | {id: .id, status: (.[$f] // .[$f | ascii_downcase] // .status // "")}
                   | select(.status != "")]
                  | first // empty
                  | "\(.id)\t\(.status)"' 2>/dev/null || true)"

if [[ -z "$FIRST_ITEM" ]]; then
  say ""
  say "    Write access NOT tested: no card on this board has a status yet, so"
  say "    there is nothing to write to harmlessly. A read-only token would pass"
  say "    every check above and then refuse every move at run time."
  say "    Add one issue to it and run this again — a read-only token passes"
  say "    every check above and then refuses every move at run time."
else
  ITEM_ID="${FIRST_ITEM%%$'\t'*}"
  ITEM_STATUS="${FIRST_ITEM##*$'\t'}"
  SAME_OPTION="$(board_status_option_id "$ITEM_STATUS")"
  if [[ -n "$SAME_OPTION" ]]; then
    WRITE_ERR="$(gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
                   --field-id "$FIELD_ID" --single-select-option-id "$SAME_OPTION" \
                   2>&1 >/dev/null)" && good "the token can write (tested by setting a card to the lane it is already in)" || {
      bad "the token can READ this board but cannot WRITE to it"
      [[ -n "$WRITE_ERR" ]] && say "        GitHub said: $WRITE_ERR"
      say ""
      say "    Cards will never move. Every other check above passes, because"
      say "    every other check is a read."
      say ""
      say "    Fix: the fine-grained PAT needs Projects: Read and write."
      say "      - an ORG-owned board -> Organisation permissions -> Projects"
      say "      - a personal board   -> Account permissions -> Projects"
      say "    Then an org owner must approve it again: any permission change"
      say "    puts the token back in Settings -> Personal access tokens ->"
      say "    Pending requests, and a pending token reads fine and writes nothing."
      PROBLEMS=$((PROBLEMS + 1))
    }
  fi
fi

[[ "$PROBLEMS" -eq 0 ]] || exit 1
exit 0
