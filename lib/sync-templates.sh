#!/usr/bin/env bash
# Keep avengers-12/templates/ identical to the files this repository actually runs.
#
# Why this exists: GitHub fixes the location of workflow files, and Claude Code
# fixes the location of skills and subagents. Neither can live inside
# avengers-12/. But npm can only ship files inside the package directory, so the
# package needs its own copy of both -- and two copies of anything drift.
#
# So they are copied by a script, and doctor.sh checks they still match. The
# alternative is a package that quietly ships last month's workflow.
#
# Usage:
#   avengers-12/lib/sync-templates.sh           copy live files into templates/
#   avengers-12/lib/sync-templates.sh --check   compare only; exit 1 on any drift
#
# config.yml is NOT synced. templates/config.yml is a starter for a new project;
# avengers-12/config.yml is this project's. They are meant to differ.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

TEMPLATES="$AVENGERS_HOME/templates"

CHECK=false
[[ "${1:-}" == "--check" ]] && CHECK=true

# live path -> path under templates/
PAIRS=(
  ".github/workflows/loop.yml|workflows/loop.yml"
  ".github/workflows/loop-board-done.yml|workflows/loop-board-done.yml"
  ".github/ISSUE_TEMPLATE/loop-task.yml|ISSUE_TEMPLATE/loop-task.yml"
  ".claude/agents/loop-implementer.md|claude/agents/loop-implementer.md"
  ".claude/agents/loop-verifier.md|claude/agents/loop-verifier.md"
  ".claude/skills/loop-implement/SKILL.md|claude/skills/loop-implement/SKILL.md"
  ".claude/skills/loop-triage/SKILL.md|claude/skills/loop-triage/SKILL.md"
  ".claude/skills/loop-constraints/SKILL.md|claude/skills/loop-constraints/SKILL.md"
  ".claude/skills/loop-budget/SKILL.md|claude/skills/loop-budget/SKILL.md"
)

DRIFT=0
COPIED=0

for pair in "${PAIRS[@]}"; do
  live="${pair%%|*}"
  tpl="$TEMPLATES/${pair##*|}"

  if [[ ! -f "$live" ]]; then
    problem "missing live file: $live"
    DRIFT=1
    continue
  fi

  if $CHECK; then
    if [[ ! -f "$tpl" ]]; then
      problem "templates/ is missing ${pair##*|} — run avengers-12/lib/sync-templates.sh"
      DRIFT=1
    elif ! cmp -s "$live" "$tpl"; then
      problem "templates/${pair##*|} differs from $live — run avengers-12/lib/sync-templates.sh"
      DRIFT=1
    fi
  else
    mkdir -p "$(dirname "$tpl")"
    cp "$live" "$tpl"
    COPIED=$((COPIED + 1))
  fi
done

if $CHECK; then
  [[ "$DRIFT" -eq 0 ]] || die "templates/ is out of date"
  notice "templates/ matches the live files (${#PAIRS[@]} checked)"
else
  [[ "$DRIFT" -eq 0 ]] || die "could not sync: see above"
  notice "synced $COPIED file(s) into templates/"
fi
