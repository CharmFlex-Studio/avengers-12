#!/usr/bin/env bash
# Report which setup steps are already done, as JSON. Facts only.
#
# Setting this harness up spans a browser and a terminal, and the browser half
# cannot be automated: installing a GitHub App, minting a fine-grained token,
# creating a Projects board. What CAN be checked is whether each of those left
# the trace it should have.
#
# So this reports what is true right now, and `/setup-workflow` turns that into
# "here is the next thing only you can do". Nothing here writes anything.
#
# Usage: avengers-12/lib/setup-status.sh
# Prints JSON to stdout. Exit 0 whatever it finds -- an unfinished setup is the
# normal case for this script, not an error.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

json_array() {
  if [[ -z "${1:-}" ]]; then printf '[]'; else printf '%s' "$1" | jq -R . | jq -s .; fi
}

GH_PRESENT=false; GH_AUTHED=false; REPO=""; DEFAULT_BRANCH=""
if command -v gh >/dev/null 2>&1; then
  GH_PRESENT=true
  if gh auth status >/dev/null 2>&1; then
    GH_AUTHED=true
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)"
  fi
fi

# Labels, variables and secrets are all readable with the same token, so a
# failure to read them means the token is wrong rather than the thing missing.
# Reported as empty lists either way; the skill checks gh.authenticated first.
LABELS=""; VARS=""; SECRETS=""
if $GH_AUTHED; then
  LABELS="$(gh label list --limit 100 --json name --jq '.[].name' 2>/dev/null \
    | grep "^${LOOP_LABEL_PREFIX}" || true)"
  VARS="$(gh variable list --json name --jq '.[].name' 2>/dev/null || true)"
  SECRETS="$(gh secret list --json name --jq '.[].name' 2>/dev/null || true)"
fi

want_labels() {
  printf '%s\n' "$LOOP_LABEL_READY" "$LOOP_LABEL_IN_PROGRESS" "$LOOP_LABEL_IN_REVIEW" \
                "$LOOP_LABEL_BLOCKED" "$LOOP_LABEL_NEEDS_SPEC"
}
MISSING_LABELS=""
while IFS= read -r want; do
  [[ -n "$want" ]] || continue
  grep -qxF "$want" <<<"$LABELS" || MISSING_LABELS="${MISSING_LABELS}${want}"$'\n'
done < <(want_labels)

# The workflow files must be on the DEFAULT branch or `issue_comment` never
# fires, which is the whole resume path. This is the step people finish last and
# notice never.
ON_DEFAULT=false
if [[ -n "$DEFAULT_BRANCH" ]] && \
   git cat-file -e "origin/${DEFAULT_BRANCH}:.github/workflows/loop.yml" 2>/dev/null; then
  ON_DEFAULT=true
fi

jq -n \
  --arg  repo           "$REPO" \
  --arg  defaultBranch  "$DEFAULT_BRANCH" \
  --argjson ghPresent   "$GH_PRESENT" \
  --argjson ghAuthed    "$GH_AUTHED" \
  --argjson onDefault   "$ON_DEFAULT" \
  --argjson labels      "$(json_array "$LABELS")" \
  --argjson missing     "$(json_array "$(printf '%s' "$MISSING_LABELS")")" \
  --argjson vars        "$(json_array "$VARS")" \
  --argjson secrets     "$(json_array "$SECRETS")" \
  --argjson configFound "$( [[ -s "$AVENGERS_CONFIG" ]] && echo true || echo false )" \
  '{
     gh:       { installed: $ghPresent, authenticated: $ghAuthed },
     repo:     (if $repo == "" then null else $repo end),
     defaultBranch: (if $defaultBranch == "" then null else $defaultBranch end),
     workflowsOnDefaultBranch: $onDefault,
     configPresent: $configFound,
     labels:   { present: $labels, missing: $missing },
     variables: $vars,
     secrets:  $secrets
   }'
