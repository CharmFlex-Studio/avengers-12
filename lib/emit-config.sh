#!/usr/bin/env bash
# Publish config.yml values as GitHub Actions step outputs.
#
# A workflow expression cannot read a file. `${{ }}` sees contexts, inputs and
# step outputs, and nothing else — so the only way to drive a workflow from a
# config file is to have one step read it and emit what the later steps need.
#
# That is this script's entire job. Everything project-specific — the JDK, the
# cache paths, the models — reaches the workflow through here, and nowhere else.
# A literal value appearing in loop.yml again is a regression.
#
# Usage: avengers-12/lib/emit-config.sh
#
# Outputs:
#   java                  runtime.java, or empty (the setup step is then skipped)
#   java_distribution     runtime.javaDistribution, for actions/setup-java
#   cache_paths           newline-separated, for actions/cache
#   cache_key             digest of runtime.cacheKeyFiles, for the cache key
#   chmod_paths           newline-separated, made executable before verify
#   triage_model          models.triage.*
#   triage_effort
#   triage_max_turns
#   implement_model       models.implement.*
#   implement_effort
#   implement_max_turns

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=avengers-12/lib/common.sh
source "$HERE/common.sh"

require_cmd jq python3
avengers_load_config

# Defaults live HERE, not in the workflow, so a config missing an optional
# section still produces a runnable job — and so there is one place to look when
# you want to know what happens when you leave something out.
emit() {
  local key="$1" value="$2"
  set_output "$key" "$value"
  log "config: $key=${value:-<empty>}"
}

emit_multiline() {
  local key="$1" value="$2"
  set_output_multiline "$key" "$value"
  log "config: $key=$(printf '%s' "$value" | tr '\n' ' ')"
}

emit "java"                "$(cfg runtime.java "")"
emit "java_distribution"   "$(cfg runtime.javaDistribution "temurin")"
emit "triage_model"        "$(cfg models.triage.model     "claude-sonnet-5")"
emit "triage_effort"       "$(cfg models.triage.effort    "medium")"
emit "triage_max_turns"    "$(cfg models.triage.maxTurns  "30")"
emit "implement_model"     "$(cfg models.implement.model    "claude-opus-5")"
emit "implement_effort"    "$(cfg models.implement.effort   "high")"
emit "implement_max_turns" "$(cfg models.implement.maxTurns "80")"

emit_multiline "cache_paths" "$(cfg_list runtime.cache)"
emit_multiline "chmod_paths" "$(cfg_list runtime.chmod)"

# Actions' own hashFiles() cannot take its globs from a file, so the workflow
# used to hash a hardcoded manifest list while runtime.cacheKeyFiles did nothing.
# cache_key.py hashes exactly what the config names, using the harness's glob
# rules. It never fails: a missing cache is slow, not wrong.
CACHE_KEY="$(python3 "$HERE/cache_key.py" "$AVENGERS_CONFIG" || true)"
# Never emit an empty one. An empty key equals the restore-keys prefix, and
# actions/cache then restores the same entry forever and never saves a new one.
emit "cache_key" "${CACHE_KEY:-nokey-unavailable}"

notice "avengers-12 config loaded from $AVENGERS_CONFIG"
