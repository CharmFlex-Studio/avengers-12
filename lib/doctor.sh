#!/usr/bin/env bash
# Check that this installation of avengers-12 is coherent.
#
# The harness has one recurring failure mode, and it is not a crash: a document
# or a settings file claims a rule that no code enforces. That was an entire
# class of bug in this repo's history — a constraints file promising a 25-file
# cap while the gate allowed 100, permission rules missing half the denylist,
# docs naming a test folder that did not exist. Every one of them was checkable
# and nothing checked it.
#
# So this does. It compares the things that must agree, and fails loudly when
# they do not.
#
# Usage: avengers-12/lib/doctor.sh
# Exit 0 when everything agrees, 1 when it does not.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

require_cmd jq python3 git

PROBLEMS=0
note_problem() { printf '  ✗ %s\n' "$*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
note_ok()      { printf '  ✓ %s\n' "$*"; }

echo "avengers-12 doctor — $AVENGERS_CONFIG"
echo

# --- 1. the config parses and has what the code needs ------------------------
group "Config"
if python3 "$HERE/config.py" --check "$AVENGERS_CONFIG"; then
  note_ok "config.yml parses and has every required section"
else
  note_problem "config.yml is missing required values (see above)"
fi
endgroup

# --- 2. the generated permission rules cover the gate ------------------------
# A path the gate denies but settings allow is a path the agent can spend a
# whole run editing before being refused. Refusing at the write is cheaper.
#
# The rules are DERIVED from gate.deny by emit-settings.sh, so this can no
# longer catch a human forgetting to mirror a line. What it still catches is a
# broken generator, which is worth knowing about before a run rather than after:
# it builds the file here and checks the result, exactly as the workflow will.
#
# Only paths OUTSIDE avengers-12/ are compared: the rules collapse the whole
# harness folder into one `avengers-12/**` entry, which covers every path the
# gate lists inside it.
group "Gate vs write permissions"
SETTINGS_FILE="$LOOP_DIR/settings-implement.json"
if ! bash "$HERE/emit-settings.sh" "$SETTINGS_FILE" >/dev/null 2>&1; then
  note_problem "emit-settings.sh could not build the permission rules"
  bash "$HERE/emit-settings.sh" "$SETTINGS_FILE" 2>&1 | sed 's/^/      /' >&2 || true
elif [[ ! -s "$SETTINGS_FILE" ]]; then
  note_problem "emit-settings.sh produced nothing at $SETTINGS_FILE"
else
  MISSING=""
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    case "$pattern" in avengers-12/*) continue ;; esac
    if ! jq -e --arg p "Write($pattern)" '.permissions.deny | index($p)' "$SETTINGS_FILE" >/dev/null 2>&1; then
      MISSING="${MISSING}${pattern}"$'\n'
    fi
  done < <(cfg_list gate.deny)

  if [[ -n "$MISSING" ]]; then
    note_problem "gate.deny entries with no Write() deny in $SETTINGS_FILE:"
    printf '%s' "$MISSING" | sed 's/^/      /' >&2
  else
    note_ok "every gate.deny path outside avengers-12/ is Write-denied in the generated rules"
  fi

  if jq -e '.permissions.deny | index("Write(avengers-12/**)")' "$SETTINGS_FILE" >/dev/null 2>&1; then
    note_ok "the harness folder itself is write-denied"
  else
    note_problem "Write(avengers-12/**) is missing — the agent could edit its own rules"
  fi
fi
endgroup

# --- 3. the one literal a workflow cannot read --------------------------------
# A job-level `if:` is evaluated before any step runs, so loop-board-done.yml
# cannot ask config.yml what the branch prefix is. It carries the literal. That
# is unavoidable, but it does not have to be silent: if the two ever disagree,
# a merged loop pull request stops moving its card to Done and nothing says why.
group "Branch prefix"
BOARD_WORKFLOW=".github/workflows/loop-board-done.yml"
PREFIX="$(cfg branch.prefix "loop/issue-")"
if [[ ! -f "$BOARD_WORKFLOW" ]]; then
  note_problem "missing $BOARD_WORKFLOW"
elif grep -q "startsWith(github.event.pull_request.head.ref, '${PREFIX}')" "$BOARD_WORKFLOW"; then
  note_ok "branch.prefix '$PREFIX' matches the trigger in $BOARD_WORKFLOW"
else
  note_problem "branch.prefix is '$PREFIX' but $BOARD_WORKFLOW does not trigger on it"
  grep -n "startsWith(github.event.pull_request.head.ref" "$BOARD_WORKFLOW" | sed 's/^/      /' >&2
fi
endgroup

# --- 4. paths the config names actually exist --------------------------------
# A test directory that does not exist is the worst kind of green: the build
# passes with zero tests and the verifier's "tests are green" means nothing.
group "Paths"
TEST_DIR="$(cfg tests.directory)"
if [[ -n "$TEST_DIR" && ! -d "$TEST_DIR" ]]; then
  note_problem "tests.directory does not exist: $TEST_DIR"
elif [[ -n "$TEST_DIR" ]]; then
  COUNT="$(find "$TEST_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${COUNT:-0}" -eq 0 ]]; then
    note_problem "tests.directory is empty: $TEST_DIR — 'tests are green' would prove nothing"
  else
    note_ok "tests.directory has $COUNT file(s)"
  fi
fi

TEST_EXAMPLE="$(cfg tests.example)"
if [[ -n "$TEST_EXAMPLE" && ! -f "$TEST_EXAMPLE" ]]; then
  note_problem "tests.example does not exist: $TEST_EXAMPLE — the coder is pointed at nothing"
elif [[ -n "$TEST_EXAMPLE" ]]; then
  note_ok "tests.example exists"
fi

for key in paths.rules paths.settings paths.lib; do
  DIR="$(cfg "$key")"
  if [[ -n "$DIR" && ! -d "$DIR" ]]; then
    note_problem "$key points at a missing directory: $DIR"
  fi
done

# houseRules is what every agent is told to read before editing. A missing file
# there is silent: the agent reads nothing, follows nothing, and the verifier
# rejects it for breaking rules it was never shown.
HOUSE_COUNT=0
HOUSE_BAD=0
while IFS= read -r doc; do
  [[ -n "$doc" ]] || continue
  HOUSE_COUNT=$((HOUSE_COUNT + 1))
  if [[ ! -f "$doc" ]]; then
    note_problem "houseRules names a missing file: $doc — agents are told to read it"
    HOUSE_BAD=1
  elif ! python3 "$HERE/gate_check.py" --list-denied "$AVENGERS_CONFIG" <(printf '%s\n' "$doc") \
         | grep -qxF "$doc"; then
    # Not denied means a run can rewrite the rules it is judged against.
    note_problem "houseRules file is not on gate.deny: $doc — a run could edit its own rules"
    HOUSE_BAD=1
  fi
done < <(cfg_list houseRules)
if [[ "$HOUSE_COUNT" -eq 0 ]]; then
  note_problem "houseRules is empty — agents would be told to read nothing"
elif [[ "$HOUSE_BAD" -eq 0 ]]; then
  note_ok "$HOUSE_COUNT houseRules file(s) exist and are write-denied"
fi
endgroup

# --- 4b. every config key is actually read -----------------------------------
# A key nothing reads is worse than a missing one: it looks configurable and is
# not. `runtime.cacheKeyFiles`, `board.statusField`, `board.optional` and
# `tests.notRun` all shipped dead in the first version of this layout.
group "Config keys are read"
python3 "$HERE/check_config_used.py" "$AVENGERS_CONFIG" && KEYS_STATUS=0 || KEYS_STATUS=$?
case "$KEYS_STATUS" in
  0) note_ok "no orphaned keys in config.yml" ;;
  1) note_problem "config.yml has keys nothing reads (listed above)" ;;
  *) note_problem "could not check for orphaned keys (see above)" ;;
esac
endgroup

# --- 4c. the workflow must not out-shout the config --------------------------
# common.sh resolves each of these as `${ENV:-$(cfg ...)}`, so an env var that is
# always set means the config value is never read. loop.yml used to write
# `${{ vars.LOOP_MAX_RUNS_PER_DAY || '4' }}`, which made budget.maxRunsPerDay
# decorative: the file said 9 and the run still stopped at 4. A repository
# variable is the override; config.yml is the default; a literal default in the
# workflow is neither.
group "Config vs workflow defaults"
WORKFLOW="${LOOP_WORKFLOW_FILE:-.github/workflows/loop.yml}"
if [[ ! -f "$WORKFLOW" ]]; then
  note_problem "no workflow at $WORKFLOW"
else
  SHADOWED=0
  # Names common.sh falls back to the config for.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if grep -q "vars\.${name}[[:space:]]*||" "$WORKFLOW"; then
      note_problem "$WORKFLOW writes a literal default for \$$name — config.yml would never be read"
      SHADOWED=1
    fi
  done < <(grep -oE '^LOOP_[A-Z_]+="\$\{LOOP_[A-Z_]+:-\$\(cfg ' "$HERE/common.sh" \
             | sed -E 's/^(LOOP_[A-Z_]+)=.*/\1/')
  [[ "$SHADOWED" -eq 0 ]] && note_ok "no workflow default shadows a config value"
fi
endgroup

# --- 4d. the verifier is pointed at files that exist -------------------------
# The verifier judges from `.loop/evidence/`. It cannot ask for a different file
# and it cannot tell "this file is missing" from "the build wrote nothing" -- it
# just judges with less than it should. `loop-verifier.md` spent this whole
# refactor telling it to read `gradle.txt`, which `evidence.sh` renamed to
# `build.txt`. Nothing noticed, because nothing compared the two.
group "Evidence packet"
VERIFIER="${LOOP_VERIFIER_FILE:-.claude/agents/loop-verifier.md}"
EVIDENCE_SH="$HERE/evidence.sh"
if [[ ! -f "$VERIFIER" || ! -f "$EVIDENCE_SH" ]]; then
  note_problem "cannot compare evidence filenames: missing $VERIFIER or evidence.sh"
else
  MISSING=0
  # Every `<name>.<ext>` the verifier names in a backtick, that evidence.sh does
  # not also mention. Restricted to the extensions the packet actually uses, so
  # a stray filename in prose does not raise a false alarm.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qF "$name" "$EVIDENCE_SH" || {
      note_problem "$VERIFIER points at .loop/evidence/$name — evidence.sh never writes it"
      MISSING=1
    }
  done < <(grep -oE '`[a-z0-9_-]+\.(md|txt|patch|json)`' "$VERIFIER" \
             | tr -d '`' | sort -u)
  [[ "$MISSING" -eq 0 ]] && note_ok "every evidence file the verifier reads is written by evidence.sh"
fi
endgroup

# --- 4f. the board can actually be driven ------------------------------------
# Every board call in board.sh is non-fatal by design: the board tracks work, it
# is not a safety control, and a broken board must not kill an otherwise good
# run. The price is silence. A card that never moves produces one warning buried
# in a job log, and the owner finds out by looking at the board days later.
#
# This is where that silence gets a voice. Skipped entirely when no board is
# configured -- label mode is a supported way to run.
group "Board"
if bash "$HERE/check-board.sh" 2>&1 | sed 's/^/  /'; then
  :
else
  note_problem "the board is configured but cannot be driven (see above)"
fi
endgroup

# --- 4g. no script sits in lib/ with nothing calling it ----------------------
# sync-board.sh lived in one repository for days, correct and complete, wired to
# nothing. It was written to fix a real gap -- triage changes labels through a
# model, and a model is deliberately not allowed to move cards -- and then no
# workflow step ever ran it. Dead code that LOOKS alive is worse than missing
# code: you read the directory, see the file, and assume the job is done.
group "Every script has a caller"
ORPHANS=""
for script in "$HERE"/*.sh "$HERE"/*.py; do
  [[ -e "$script" ]] || continue
  base="$(basename "$script")"
  # common.sh and board.sh are sourced by name; the rest must be invoked.
  hits="$(grep -rlF "$base" \
            "$HERE" .github .claude "$AVENGERS_HOME/docs" "$AVENGERS_HOME/rules" 2>/dev/null \
          | grep -vxF "$script" | head -n1)"
  [[ -n "$hits" ]] || ORPHANS="${ORPHANS}${base}"$'"'"'\n'"'"'
done
if [[ -n "$ORPHANS" ]]; then
  note_problem "nothing anywhere calls or mentions:"
  printf '%s' "$ORPHANS" | sed 's/^/      /' >&2
else
  note_ok "every script in $(cfg paths.lib) is called from somewhere"
fi
endgroup

# --- 5. every script the harness calls is present and parses -----------------
group "Scripts"
BAD=0
for script in "$HERE"/*.sh; do
  bash -n "$script" 2>/dev/null || { note_problem "syntax error: ${script#"$PWD"/}"; BAD=1; }
done
[[ "$BAD" -eq 0 ]] && note_ok "every script in $(cfg paths.lib) parses"
endgroup

# --- 6. verify commands look runnable ----------------------------------------
# Not run here — they are slow and need a toolchain. But an empty list means a
# run would push code that nothing checked, which is worth refusing over.
group "Verify"
VERIFY_COUNT="$(jq '(.verify // []) | length' "$_AVENGERS_CONFIG_JSON")"
if [[ "${VERIFY_COUNT:-0}" -eq 0 ]]; then
  note_problem "verify is empty — nothing would prove a change works"
else
  note_ok "$VERIFY_COUNT verify step(s) configured"
  jq -r '.verify[] | "      \(.name): \(.run)"' "$_AVENGERS_CONFIG_JSON"
fi
endgroup

echo
if [[ "$PROBLEMS" -gt 0 ]]; then
  problem "avengers-12 doctor found $PROBLEMS problem(s)"
  exit 1
fi
notice "avengers-12 doctor: everything agrees"
exit 0
