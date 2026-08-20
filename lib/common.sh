#!/usr/bin/env bash
# Shared helpers for the loop harness. Source this; don't execute it.
#
# Every script in avengers-12/lib/ is part of the enforcement layer: it runs as a
# GitHub Actions step, not inside the agent. Nothing here should ever ask the
# model for its opinion about whether a rule was followed.
#
# Nothing here may hardcode a value that belongs to one project either. Paths,
# build commands, column names, limits and labels all come from config.yml,
# through the `cfg` helper below. A project-specific string in this directory is
# a bug — it is the thing that stops anyone else reusing the harness.

set -euo pipefail

AVENGERS_HOME="${AVENGERS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AVENGERS_CONFIG="${AVENGERS_CONFIG:-$AVENGERS_HOME/config.yml}"

# The harness shells out to python constantly. Left alone, that litters a
# consumer's repository with avengers-12/lib/__pycache__/ — inside a directory
# the gate denies, so it is noise they cannot even clean up through the loop.
# The scripts are small; the cache buys nothing.
export PYTHONDONTWRITEBYTECODE=1

LOOP_DIR="${LOOP_DIR:-.loop}"
LOOP_EVIDENCE_DIR="$LOOP_DIR/evidence"
LOOP_ATTEMPTS_FILE="$LOOP_DIR/attempts.json"
# Always set by the workflow from the dispatched ref. The fallback only matters
# when running a script by hand: use the current branch, not a hardcoded `main`,
# because work in this repo happens on feature branches.
LOOP_BASE_BRANCH="${LOOP_BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"

# --- config ------------------------------------------------------------------
#
# config.yml is parsed ONCE per job into .loop/config.json, then read with jq.
# jq is already a hard dependency of this harness and python3 already is too,
# for the gate — so this adds no tool to the runner.
#
# It fails closed on purpose. A config that cannot be parsed is not "a config
# with no denylist"; it is a reason to stop. Degrading to an empty config would
# silently turn the gate off, which is the single worst failure this file could
# have.
_AVENGERS_CONFIG_JSON="$LOOP_DIR/config.json"

avengers_load_config() {
  # Reuse the cache only while it is NEWER than the config it came from.
  #
  # A bare `[[ -s ... ]] && return 0` looked right and was not: editing
  # config.yml left every `cfg` call reading the previous parse, so doctor.sh
  # reported that a config it had just been handed was fine. A cache with no
  # invalidation is a cache that lies, and this one lies about the denylist.
  # `-nt` is a bash builtin and behaves the same on macOS and Linux.
  # The cache is only good for the file it came from. Comparing mtimes alone
  # meant that pointing AVENGERS_CONFIG at a different file silently reused the
  # previous parse, so a script would answer questions about a config it had
  # never read. That cannot happen in a workflow, where a job has one config, but
  # it happens constantly when testing by hand -- which is exactly when a wrong
  # answer is most likely to be believed.
  local stamp="$LOOP_DIR/config.source"
  if [[ -s "$_AVENGERS_CONFIG_JSON" && -s "$stamp" ]] \
     && [[ "$(cat "$stamp" 2>/dev/null)" == "$AVENGERS_CONFIG" ]] \
     && [[ ! "$AVENGERS_CONFIG" -nt "$_AVENGERS_CONFIG_JSON" ]]; then
    return 0
  fi
  mkdir -p "$LOOP_DIR"
  if ! python3 "$AVENGERS_HOME/lib/config.py" "$AVENGERS_CONFIG" > "$_AVENGERS_CONFIG_JSON" 2>"$LOOP_DIR/config.err"; then
    rm -f "$_AVENGERS_CONFIG_JSON"
    rm -f "$LOOP_DIR/config.source"
    printf '[loop] FATAL: cannot read %s\n' "$AVENGERS_CONFIG" >&2
    sed 's/^/  /' "$LOOP_DIR/config.err" >&2 || true
    exit 1
  fi
  printf '%s' "$AVENGERS_CONFIG" > "$LOOP_DIR/config.source"
  return 0
}

# cfg <jq-path> [default]
#
# Reads one value out of config.yml. Strings come back bare, everything else as
# JSON, which is what the callers want: `cfg gate.maxFilesChanged` is a number
# to compare, `cfg gate.deny` is a list to iterate.
cfg() {
  local path="$1" fallback="${2:-}" value
  avengers_load_config
  # Note what this does NOT use: jq's `//`. That operator treats `false` as
  # absent, so `board.optional: false` came back empty and silently took the
  # default `true` -- the board became optional exactly when you asked for it to
  # be required. Only an explicit `== null` test can tell "not set" from "set to
  # false". A missing intermediate key still yields null, so absence works too.
  value="$(jq -r --arg d "$fallback" \
    "(.${path}) as \$v | if \$v == null then \$d elif (\$v|type) == \"string\" then \$v else (\$v|tojson) end" \
    "$_AVENGERS_CONFIG_JSON" 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$fallback"
  printf '%s' "$value"
}

# cfg_list <jq-path> -> one item per line
cfg_list() {
  avengers_load_config
  jq -r "(.${1} // []) | .[]" "$_AVENGERS_CONFIG_JSON" 2>/dev/null || true
}

# Values used often enough to be worth naming once. Environment wins, so a
# workflow or a test can still override any of them without editing config.
LOOP_RUN_LOG="${LOOP_RUN_LOG:-$(cfg paths.runLog "avengers-12/state/run-log.md")}"
LOOP_STATE_FILE="${LOOP_STATE_FILE:-$(cfg paths.state "avengers-12/state/STATE.md")}"
LOOP_GATE_FILE="${LOOP_GATE_FILE:-$AVENGERS_CONFIG}"
LOOP_BRANCH_PREFIX="${LOOP_BRANCH_PREFIX:-$(cfg branch.prefix "loop/issue-")}"
LOOP_LABEL_PREFIX="${LOOP_LABEL_PREFIX:-$(cfg labels.prefix "loop:")}"
LOOP_LABEL_READY="${LOOP_LABEL_READY:-$(cfg labels.ready "loop:ready")}"
LOOP_LABEL_IN_PROGRESS="${LOOP_LABEL_IN_PROGRESS:-$(cfg labels.inProgress "loop:in-progress")}"
LOOP_LABEL_IN_REVIEW="${LOOP_LABEL_IN_REVIEW:-$(cfg labels.inReview "loop:in-review")}"
LOOP_LABEL_BLOCKED="${LOOP_LABEL_BLOCKED:-$(cfg labels.blocked "loop:blocked")}"
LOOP_LABEL_NEEDS_SPEC="${LOOP_LABEL_NEEDS_SPEC:-$(cfg labels.needsSpec "loop:needs-spec")}"
LOOP_COL_TODO="${LOOP_COL_TODO:-$(cfg board.columns.todo "Todo")}"
LOOP_COL_IN_PROGRESS="${LOOP_COL_IN_PROGRESS:-$(cfg board.columns.inProgress "In Progress")}"
LOOP_COL_IN_REVIEW="${LOOP_COL_IN_REVIEW:-$(cfg board.columns.inReview "In Review")}"
LOOP_COL_BLOCKED="${LOOP_COL_BLOCKED:-$(cfg board.columns.blocked "Blocked")}"
LOOP_COL_DONE="${LOOP_COL_DONE:-$(cfg board.columns.done "Done")}"
# The board is a tracking surface, not a safety control, so a project that has
# not configured one should still be able to run. The workflow used to write
# this default itself, which meant the env var was ALWAYS set and the config
# value below was never read. Defaults belong here, next to every other one.
LOOP_BOARD_OPTIONAL="${LOOP_BOARD_OPTIONAL:-$(cfg board.optional true)}"
LOOP_MAX_RUNS_PER_DAY="${LOOP_MAX_RUNS_PER_DAY:-$(cfg budget.maxRunsPerDay 4)}"
LOOP_MAX_ATTEMPTS="${LOOP_MAX_ATTEMPTS:-$(cfg budget.maxAttemptsPerRun 3)}"
LOOP_STALE_CLAIM_HOURS="${LOOP_STALE_CLAIM_HOURS:-$(cfg budget.staleClaimHours 2)}"
LOOP_PRIOR_FILES_MAX="${LOOP_PRIOR_FILES_MAX:-$(cfg budget.priorFilesMax 200)}"
LOOP_GIT_NAME="${LOOP_GIT_NAME:-$(cfg git.userName "avengers-12")}"
LOOP_GIT_EMAIL="${LOOP_GIT_EMAIL:-$(cfg git.userEmail "loop@users.noreply.github.com")}"

# --- acceptance criteria -----------------------------------------------------
#
# Reads an issue body on stdin, prints one line per usable acceptance criterion.
# The caller counts the lines; zero means the issue cannot be implemented.
#
# This lives here, once, because two things need the same answer: preflight,
# which refuses to start a run without criteria, and check-issue.sh, which tells
# you whether your issue will pass BEFORE you spend a run finding out. Two copies
# of this parser would drift, and then the tool that says "your issue is fine"
# would be describing a different rule from the one that rejects it.
#
# What counts:
#   - a heading line matching "acceptance criteria", case-insensitive, with or
#     without #'s and **bold** markers
#   - followed by lines that start with a real list marker: - * + 1. 1)
#   - the section ends at the next heading
#
# A LIST MARKER IS REQUIRED. Counting any non-blank line meant a section reading
# only "Acceptance criteria are unclear here." scored 1 and sailed through --
# the single worst case to admit, because it is an explicit statement that
# nobody knows what done looks like.
acceptance_items() {
  awk '
      BEGIN { inSec = 0 }
      tolower($0) ~ /^[[:space:]]*#{0,6}[[:space:]]*\**acceptance[[:space:]]+criteria/ { inSec = 1; next }
      inSec && /^[[:space:]]*#{1,6}[[:space:]]/ { inSec = 0 }
      inSec { print }
    ' \
    | grep -E '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+' \
    | sed -E 's/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]*(\[[ xX]\])?[[:space:]]*//' \
    | grep -vE '^[[:space:]]*$' \
    || true
}

# --- comment markers ---------------------------------------------------------
#
# Every comment the harness posts on an issue carries one of these HTML markers.
# They are load-bearing, not decoration: the resume rule in issue-state.sh asks
# "did a human speak after the last escalation?", and the only way to answer that
# from bash is to recognise the loop's own comments and discount them.
#
# All three comment kinds are posted with the project PAT, i.e. as the repository
# owner, so `author.login` cannot tell loop text from human text. The marker can.
# An unmarked loop comment reads as a human reply and re-triggers the loop on
# itself — which is why `Loop opened a draft PR` carries one too.
LOOP_MARKER_ESCALATION='<!-- loop-escalation -->'
LOOP_MARKER_VERDICT='<!-- loop-triage-verdict -->'
LOOP_MARKER_NOTICE='<!-- loop-notice -->'
# One ERE covering all three, for jq `test()` and grep.
LOOP_MARKER_ANY='<!-- loop-(escalation|triage-verdict|notice) -->'

# A jq expression: the comment body with quoted lines removed.
#
# GitHub's "Quote reply" copies the raw markdown you are replying to, HTML
# comments included, each line prefixed with "> ". Reply to an escalation that
# way and your answer contains `<!-- loop-escalation -->`. Every marker test
# must strip quotes first, or two things go wrong at once: your reply is filed
# as a loop comment, AND it becomes the newest escalation — so your answer can
# never be newer than "the last escalation", and the issue is blocked forever.
#
# A marker inside a quote records what was said. Only an unquoted marker says
# who is speaking.
LOOP_JQ_UNQUOTED='(.body | split("\n") | map(select(test("^\\s*>") | not)) | join("\n"))'

# --- output -----------------------------------------------------------------

_loop_stamp() { date -u +%H:%M:%S; }

log()  { printf '[loop %s] %s\n'        "$(_loop_stamp)" "$*" >&2; }
warn() { printf '[loop %s] WARN: %s\n'  "$(_loop_stamp)" "$*" >&2; }
die()  { printf '[loop %s] FATAL: %s\n' "$(_loop_stamp)" "$*" >&2; exit 1; }

# Group output in the Actions log so a failing run is readable.
group()    { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }

# Surface a message on the run summary page, not just buried in the log.
notice()  { printf '::notice::%s\n' "$*"; }
problem() { printf '::error::%s\n' "$*"; }
caution() { printf '::warning::%s\n' "$*"; }

# --- guards -----------------------------------------------------------------

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "required environment variable not set: $v"
  done
}

# --- .loop scaffolding ------------------------------------------------------

loop_init_dirs() {
  mkdir -p "$LOOP_EVIDENCE_DIR"
  [[ -f "$LOOP_ATTEMPTS_FILE" ]] || printf '{"issue":null,"attempts":0,"history":[]}\n' > "$LOOP_ATTEMPTS_FILE"
}

loop_attempts() {
  [[ -f "$LOOP_ATTEMPTS_FILE" ]] || { echo 0; return; }
  jq -r '.attempts // 0' "$LOOP_ATTEMPTS_FILE" 2>/dev/null || echo 0
}

# Write a value into $GITHUB_OUTPUT when running under Actions, else stdout.
set_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

# Multi-line variant, needed for anything containing newlines.
set_output_multiline() {
  local key="$1" value="$2" delim
  delim="EOF_$(date +%s)_$RANDOM"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { printf '%s<<%s\n' "$key" "$delim"; printf '%s\n' "$value"; printf '%s\n' "$delim"; } >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

# Create or update a file on a branch through the Contents API.
#
# Preferred over `git push` for the harness's own bookkeeping files. Two auth
# paths (gh's GH_TOKEN and git's persisted credential helper) means two ways to
# fail, and they fail differently: we have seen the API write succeed in the
# same job where git push returned "Invalid username or token". One path, one
# failure mode, one thing to configure.
#
# gh_put_file <repo-path> <local-file> <commit-message> [branch]
gh_put_file() {
  local path="$1" src="$2" message="$3" branch="${4:-}"
  local get_path="repos/${GITHUB_REPOSITORY}/contents/${path}"
  [[ -n "$branch" ]] && get_path="${get_path}?ref=${branch}"

  local sha="" encoded
  # Missing file is fine — omitting sha creates it.
  sha="$(gh api "$get_path" --jq '.sha' 2>/dev/null || true)"
  encoded="$(base64 < "$src" | tr -d '\n')"

  local -a args=(
    --method PUT "repos/${GITHUB_REPOSITORY}/contents/${path}"
    -f message="$message"
    -f content="$encoded"
  )
  [[ -n "$sha" ]] && args+=(-f sha="$sha")
  [[ -n "$branch" ]] && args+=(-f branch="$branch")

  gh api "${args[@]}" --silent >/dev/null 2>&1
}

# Write markdown to the run summary page. Anything important enough to fail a
# run belongs here: the summary is the first thing you see, whereas a step log
# has to be hunted for and expanded.
summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
}

# An ISO8601 UTC timestamp N hours in the past.
#
# Used to age out a stale claim. ISO8601 UTC strings sort lexicographically, so
# the caller can compare with `[[ "$a" < "$b" ]]` and never needs epoch maths.
#
# GNU date (`-d`) and BSD date (`-v`) disagree on relative-time syntax, and this
# harness is written on macOS and run on ubuntu, so both spellings are tried.
iso_hours_ago() {
  local hours="${1:-0}"
  date -u -d "-${hours} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${hours}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ
}

# Create a label if it does not exist yet. Always returns 0.
#
# `gh issue edit --add-label X` FAILS OUTRIGHT when X does not exist, and it
# fails the whole invocation — so a missing label silently cancels the
# --remove-label arguments sitting beside it. That is precisely the bug this
# harness has already been bitten by once, so the label is created up front and
# adds are issued separately from removes.
ensure_label() {
  local name="$1" color="${2:-EDEDED}" desc="${3:-}"
  gh label create "$name" --color "$color" --description "$desc" >/dev/null 2>&1 \
    && log "created missing label $name"
  return 0
}

# Post a comment that the loop can later recognise as its own.
#
# loop_comment <issue> <body-file>
# The marker is prepended here rather than by each caller, so no future comment
# can be added without one.
loop_comment() {
  local issue="$1" body_file="$2" tmp
  tmp="$(mktemp)"
  { printf '%s\n' "$LOOP_MARKER_NOTICE"; cat "$body_file"; } > "$tmp"
  local err
  if err="$(gh issue comment "$issue" --body-file "$tmp" 2>&1 >/dev/null)"; then
    log "commented on #$issue"
  else
    warn "could not comment on #$issue"
    [[ -n "$err" ]] && printf '  GitHub said: %s\n' "$err" >&2
  fi
  rm -f "$tmp"
  return 0
}

run_url() {
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s/%s/actions/runs/%s' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  else
    printf 'local-run'
  fi
}
