#!/usr/bin/env bash
# Verify credentials BEFORE spending a Claude run.
#
# Written after a triage run completed, produced a avengers-12/state/STATE.md from no board data,
# and only failed at the very last step with "Invalid username or token" — by
# which point the tokens were spent and the output was worthless. Credential
# problems should cost ten seconds, not a whole run.
#
# Usage: avengers-12/lib/check-auth.sh [--require-board]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=avengers-12/lib/board.sh
source "$HERE/board.sh"

require_cmd gh jq

REQUIRE_BOARD=false
[[ "${1:-}" == "--require-board" ]] && REQUIRE_BOARD=true
# Escape hatch: the board is the queue, but it should never be the thing that
# stops you using the harness at all while a token is being sorted out.
# Resolved in common.sh from board.optional, so there is no second default here
# to disagree with the config.
[[ "$LOOP_BOARD_OPTIONAL" == "true" ]] && REQUIRE_BOARD=false

REPO="${GITHUB_REPOSITORY:-}"
OWNER="${REPO%%/*}"

fail() {
  local headline="$1"
  shift
  problem "$headline"
  printf '\n' >&2
  printf '  %s\n' "$@" >&2
  printf '\n' >&2

  # Also on the run summary page, so the reason is visible without expanding a
  # step. A credential failure is the most likely thing to greet someone who has
  # not touched this harness in a month.
  summary "## ❌ Loop credential check failed"
  summary ""
  summary "**${headline}**"
  summary ""
  summary '```'
  printf '%s\n' "$@" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  summary '```'
  summary ""
  summary "Config seen by this run:"
  summary ""
  summary "| | |"
  summary "|---|---|"
  summary "| repository | \`${REPO:-unset}\` |"
  summary "| LOOP_PROJECT_OWNER | \`${BOARD_OWNER:-unset}\` |"
  summary "| LOOP_PROJECT_NUMBER | \`${BOARD_NUMBER:-unset}\` |"
  summary "| token present | $([[ -n "${GH_TOKEN:-}" ]] && echo yes || echo '**no**') |"
  summary ""
  summary "See \`avengers-12/docs/setup.md\` step 3."
  exit 1
}

# --- 1. is the token even present? ------------------------------------------
if [[ -z "${GH_TOKEN:-}" ]]; then
  fail "LOOP_PROJECT_TOKEN is empty or not set" \
    "The repository secret is missing, or is named something else." \
    "An unset secret resolves to an empty string, which then gets persisted" \
    "as the git credential — producing 'Invalid username or token' much later." \
    "" \
    "Fix: Settings -> Secrets and variables -> Actions -> New repository secret" \
    "     Name it exactly LOOP_PROJECT_TOKEN"
fi

# --- 2. does it authenticate at all? ----------------------------------------
if ! VIEWER="$(gh api user --jq '.login' 2>&1)"; then
  fail "the token does not authenticate against the GitHub API" \
    "Response: ${VIEWER}" \
    "" \
    "Most likely one of:" \
    "  - the token has expired" \
    "  - it was pasted with surrounding whitespace or truncated" \
    "  - this repo belongs to an organisation and the token's resource owner" \
    "    is your personal account instead of the organisation"
fi
log "authenticated as: $VIEWER"

# --- 3. can it see this repository? -----------------------------------------
# The failure mode that matters for an org repo: a fine-grained PAT whose
# resource owner is the org is INVISIBLE until an org owner approves it, and
# until then it behaves exactly like a token with no access at all.
if ! gh api "repos/$REPO" --jq '.full_name' >/dev/null 2>&1; then
  fail "the token cannot read $REPO" \
    "If '$OWNER' is an organisation, check both of these:" \
    "  1. the PAT's Resource owner is '$OWNER', not your personal account" \
    "  2. an org owner has APPROVED the token" \
    "     ($OWNER -> Settings -> Personal access tokens -> Pending requests)" \
    "" \
    "An unapproved org PAT authenticates fine but sees nothing, which is why" \
    "step 2 above passed and this one did not."
fi

# --- 4. can it write? --------------------------------------------------------
PERM="$(gh api "repos/$REPO" --jq '.permissions.push // false' 2>/dev/null || echo false)"
if [[ "$PERM" != "true" ]]; then
  warn "the token has no push permission on $REPO"
  warn "grant Repository permissions -> Contents: Read and write"
fi

# --- 5. the board ------------------------------------------------------------
if board_enabled; then
  if [[ -n "$(board_project_id)" ]]; then
    log "board: project #$BOARD_NUMBER readable"
  else
    # Phrased as "looked under", not "owned by". This script never discovers the
    # board's real owner — it only knows the value of LOOP_PROJECT_OWNER. Stating
    # a configured value as a discovered fact sends people to inspect the board
    # when the variable is what's wrong.
    MSG="no project #$BOARD_NUMBER found under owner '$BOARD_OWNER' (from LOOP_PROJECT_OWNER)"

    # "Number 2 doesn't resolve" says what's wrong but not what's right. List the
    # projects that DO exist so the correct number can be read off directly —
    # and if the listing itself is empty or fails, that distinguishes "wrong
    # number" from "token cannot see this owner's projects at all".
    log "listing projects visible to this token, to find the right number..."
    SEEN=""
    for candidate in "$BOARD_OWNER" "$OWNER" "$VIEWER"; do
      [[ -n "$candidate" ]] || continue
      # The configured owner, the repo owner, and the token's own login are
      # often the same value — check each distinct one once.
      case " $SEEN " in *" $candidate "*) continue ;; esac
      SEEN="$SEEN $candidate"
      FOUND="$(gh project list --owner "$candidate" --format json --limit 50 2>/dev/null \
                | jq -r '.projects[]? | "  #\(.number)  \(.title)"' 2>/dev/null || true)"
      if [[ -n "$FOUND" ]]; then
        printf '\n  Projects under %s:\n%s\n' "$candidate" "$FOUND" >&2
        summary "### Projects visible under \`$candidate\`"
        summary ""
        summary '```'
        printf '%s\n' "$FOUND" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
        summary '```'
        summary ""
        summary "Set \`LOOP_PROJECT_NUMBER\` to the number above, and \`LOOP_PROJECT_OWNER\` to \`$candidate\`."
      else
        printf '\n  No projects visible under %s (wrong owner, or the token lacks Projects access there).\n' \
          "$candidate" >&2
      fi
    done

    # A fine-grained PAT is bound to exactly ONE resource owner. When the repo
    # and the board have different owners, no single fine-grained token can
    # reach both — which is easy to mistake for a permissions problem and burn
    # an afternoon on.
    MISMATCH=""
    [[ -n "$OWNER" && "$BOARD_OWNER" != "$OWNER" ]] && MISMATCH="yes"

    if $REQUIRE_BOARD; then
      if [[ -n "$MISMATCH" ]]; then
        fail "$MSG" \
          "LOOP_PROJECT_OWNER is '$BOARD_OWNER' but this repository belongs to" \
          "'$OWNER'. Check the most likely cause FIRST:" \
          "" \
          "  1. Is LOOP_PROJECT_OWNER simply wrong?" \
          "     Open the board and read its URL:" \
          "       github.com/orgs/<owner>/projects/$BOARD_NUMBER   -> owner is the org" \
          "       github.com/users/<owner>/projects/$BOARD_NUMBER  -> owner is a person" \
          "     A board created inside an organisation is owned by '$OWNER'," \
          "     not by whoever clicked New project. If the URL says /orgs/," \
          "     set LOOP_PROJECT_OWNER=$OWNER and you are done." \
          "" \
          "  Only if the board really is personal do the rest apply — a" \
          "  fine-grained PAT is scoped to ONE resource owner and cannot span" \
          "  both:" \
          "  2. Move the board to '$OWNER' (Project -> Settings -> Transfer)." \
          "  3. Or use a CLASSIC PAT with 'repo' + 'project' scopes, which is" \
          "     account-wide. Broader access than the loop needs." \
          "  4. Or set LOOP_BOARD_OPTIONAL=true to run on labels only."
      fi
      fail "$MSG" \
        "For an organisation-owned board the PAT needs" \
        "  Organisation permissions -> Projects: Read and write" \
        "not the Account-level Projects permission (that one covers only your" \
        "own user-owned boards)." \
        "" \
        "For an org board, an org owner must also APPROVE the token." \
        "" \
        "To proceed without the board for now, set LOOP_BOARD_OPTIONAL=true."
    fi
    warn "$MSG — triage will fall back to labels only"
  fi
else
  warn "board not configured (LOOP_PROJECT_NUMBER / LOOP_PROJECT_OWNER unset)"
fi

notice "Credentials OK — authenticated as $VIEWER on $REPO"
