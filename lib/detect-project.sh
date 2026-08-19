#!/usr/bin/env bash
# Report what kind of project this is, as JSON. Facts only, no decisions.
#
# The hardest part of setting this harness up is writing config.yml: what proves
# a change works, where tests live, what must never be touched. Those are
# judgement calls, and this script does not make them. It answers the questions
# the judgement needs -- which build files exist, which test directories exist,
# what secret-shaped files are lying around -- and leaves the deciding to
# whoever runs `/setup-workflow`.
#
# That split is deliberate. A detector that guessed your build command and wrote
# it into config.yml would be wrong quietly, and "verify passed" would stop
# meaning anything. Facts can be checked by eye; guesses cannot.
#
# Usage: avengers-12/lib/detect-project.sh
# Prints JSON to stdout. Exit 0 even when it finds nothing.

set -euo pipefail

exists() { [[ -e "$1" ]] && echo true || echo false; }

# Only tracked files, and only the top few levels: a vendored copy of somebody
# else's project under node_modules/ says nothing about yours.
tracked() {
  git ls-files -- "$@" 2>/dev/null \
    | grep -vE '(^|/)(node_modules|vendor|third_party|build|dist)/' \
    | head -n 50
}

json_array() {
  if [[ -z "${1:-}" ]]; then printf '[]'; else printf '%s' "$1" | jq -R . | jq -s .; fi
}

BUILD_FILES="$(tracked 'build.gradle*' 'settings.gradle*' 'pom.xml' 'package.json' \
  'go.mod' 'Cargo.toml' 'pyproject.toml' 'setup.py' 'requirements.txt' 'Makefile' \
  'composer.json' 'Gemfile' '*.csproj' '*.sln' || true)"

LOCKFILES="$(tracked 'package-lock.json' 'pnpm-lock.yaml' 'yarn.lock' 'go.sum' \
  'Cargo.lock' 'poetry.lock' 'Gemfile.lock' 'gradle/libs.versions.toml' || true)"

# Directories that look like they hold tests. Reported as directories, because
# `tests.directory` in config.yml is a directory.
TEST_DIRS="$(git ls-files 2>/dev/null \
  | grep -iE '(^|/)(test|tests|spec|__tests__)(/|$)|Test\.[a-z]+$|_test\.[a-z]+$|\.test\.[a-z]+$|\.spec\.[a-z]+$' \
  | grep -vE '(^|/)(node_modules|vendor|build|dist)/' \
  | sed -E 's|/[^/]+$||' | sort -u | head -n 20 || true)"

# Anything shaped like a secret or a signing artefact. These belong on
# gate.deny and permissions.denyRead, and missing one is the expensive mistake.
SECRETS="$(git ls-files 2>/dev/null \
  | grep -iE '(^|/)(\.env|local\.properties|google-services\.json|.*\.keystore|.*\.jks|.*\.pem|.*\.p12)$|(^|/)(secrets|credentials)/' \
  | head -n 20 || true)"
# Untracked ones matter too -- more, if anything, since they are the real ones.
SECRETS_UNTRACKED="$(git status --porcelain --ignored 2>/dev/null \
  | sed -E 's/^.{3}//' \
  | grep -iE '(^|/)(\.env|local\.properties|google-services\.json|.*\.keystore|.*\.jks)$' \
  | head -n 20 || true)"

NPM_TEST=""
if [[ -f package.json ]] && command -v jq >/dev/null 2>&1; then
  NPM_TEST="$(jq -r '.scripts.test // empty' package.json 2>/dev/null || true)"
fi

# A second build with its own wrapper is the thing people forget to configure,
# and the failure is a green run that never built half the repository.
NESTED_BUILDS="$(git ls-files 2>/dev/null \
  | grep -E '.+/(gradlew|package\.json|go\.mod|pom\.xml|Cargo\.toml)$' \
  | grep -vE '(^|/)(node_modules|vendor|build|dist)/' \
  | sed -E 's|/[^/]+$||' | sort -u | head -n 10 || true)"

jq -n \
  --argjson buildFiles      "$(json_array "$BUILD_FILES")" \
  --argjson lockFiles       "$(json_array "$LOCKFILES")" \
  --argjson testPaths       "$(json_array "$TEST_DIRS")" \
  --argjson secretsTracked  "$(json_array "$SECRETS")" \
  --argjson secretsIgnored  "$(json_array "$SECRETS_UNTRACKED")" \
  --argjson nestedBuilds    "$(json_array "$NESTED_BUILDS")" \
  --arg     npmTest         "$NPM_TEST" \
  --arg     gradleWrapper   "$(exists gradlew)" \
  --arg     isGitRepo       "$(git rev-parse --is-inside-work-tree 2>/dev/null || echo false)" \
  '{
     isGitRepo:      ($isGitRepo == "true"),
     buildFiles:     $buildFiles,
     lockFiles:      $lockFiles,
     nestedBuilds:   $nestedBuilds,
     testPaths:      $testPaths,
     secretsTracked: $secretsTracked,
     secretsIgnored: $secretsIgnored,
     hints: {
       gradleWrapper: ($gradleWrapper == "true"),
       npmTestScript: (if $npmTest == "" then null else $npmTest end)
     }
   }'
