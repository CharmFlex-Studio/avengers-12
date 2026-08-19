#!/usr/bin/env bash
# Build the tarball, install it into a throwaway project, and check the result.
#
# This replaces two checks that used to live in doctor.sh and could not survive
# the split: one compared templates/ against the workflows this repository ran,
# the other compared templates/config.yml against a real config. Neither has
# anything to compare against here -- this repository is the package, not a
# consumer of it.
#
# What is checked instead is the thing those two were proxies for: does an
# install actually work? A consumer is built from scratch, `init` runs against
# it, and `doctor` has to pass with the config untouched.
#
# The scratch project is deliberately a NODE project. This package was extracted
# from a Gradle repository, and every hardcoded path that survives that origin
# shows up here as a failure rather than in someone else's repository.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

say "environment"
printf '   %s\n' "$(uname -s) $(uname -m)" "node $(node --version)" "npm $(npm --version)" \
                  "$(bash --version | head -n1)" "jq $(jq --version)" "$(python3 --version)"

say "pack"
TARBALL="$(cd "$HERE" && npm pack --pack-destination "$WORK" --silent | tail -n1)"
[[ -f "$WORK/$TARBALL" ]] || fail "npm pack produced nothing"
printf '   %s\n' "$TARBALL"

say "nothing private in the tarball"
tar -tzf "$WORK/$TARBALL" | sed 's|^package/||' > "$WORK/manifest.txt"
# Anchored on purpose: `templates/config.yml` SHOULD ship, the root
# `config.yml` should not. An unanchored match cannot tell them apart.
for forbidden in '^config\.yml$' '^state/' '__pycache__' '\.pyc$'; do
  if grep -qE "$forbidden" "$WORK/manifest.txt"; then
    grep -E "$forbidden" "$WORK/manifest.txt" >&2
    fail "tarball contains something matching /$forbidden/"
  fi
done
grep -q '^templates/config.yml$' "$WORK/manifest.txt" || fail "templates/config.yml is missing"
printf '   %s files, none of them private\n' "$(wc -l < "$WORK/manifest.txt" | tr -d ' ')"

say "install into a scratch Node project"
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER/test"
cd "$CONSUMER"
git init -q .
git config user.name  "avengers-12 test"
git config user.email "test@example.invalid"
git commit -q --allow-empty -m init
printf '{"name":"scratch","version":"1.0.0","scripts":{"test":"node -e 0"}}\n' > package.json
printf 'console.log("ok");\n' > test/example.test.js
printf '# House rules\n' > AGENTS.md
printf '# Claude notes\n' > CLAUDE.md
npm install --no-audit --no-fund "$WORK/$TARBALL" >"$WORK/install.log" 2>&1 || {
  cat "$WORK/install.log" >&2
  fail "npm install failed"
}

CLI="./node_modules/.bin/avengers-12"
[[ -x "$CLI" ]] || fail "npm install did not produce $CLI"

say "init"
"$CLI" init >/dev/null || fail "init failed"
for want in avengers-12/config.yml avengers-12/lib/doctor.sh avengers-12/rules/constraints.md \
            .github/workflows/loop.yml .claude/agents/loop-implementer.md; do
  [[ -e "$want" ]] || fail "init did not produce $want"
done
[[ -x avengers-12/lib/doctor.sh ]] || fail "init lost the executable bit"

say "doctor passes on an untouched install"
"$CLI" doctor || fail "doctor failed on a fresh install"

say "init is idempotent and never eats your config"
echo "# my edit" >> avengers-12/config.yml
"$CLI" init --force >/dev/null || fail "second init failed"
grep -q "# my edit" avengers-12/config.yml || fail "init --force destroyed config.yml"

say "the harness runs the scratch project's own build"
bash avengers-12/lib/verify.sh >/dev/null 2>&1 || fail "verify.sh failed"

say "no Gradle or iOS leaked out of the repository this came from"
if grep -rnliE 'gradlew|composeApp|iosApp|webview-sdk' avengers-12/lib avengers-12/rules \
     .github/workflows .claude 2>/dev/null; then
  fail "a path from the origin repository survived the extraction"
fi

printf '\nAll checks passed.\n'
