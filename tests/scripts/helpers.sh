#!/usr/bin/env bash
# tests/scripts/helpers.sh — shared Plan C test utilities (Task 1.4).
#
# Provides:
#   REIN_PROJECT_ROOT — absolute path to this rein-dev repo
#   REIN_SCRIPT       — absolute path to scripts/rein.sh
#   sandbox_repo      — mktemp a fresh git-initialized sandbox, seeded from
#                       tests/scripts/fixtures/rein-template-min/. Prints the
#                       sandbox path so callers can `cd "$(sandbox_repo)"`.
#   rein_exec         — invoke rein with REIN_PROJECT_ROOT bound absolutely,
#                       so tests can `cd` into a sandbox and still run rein.
#   rein_source       — source scripts/rein.sh in --source-only mode,
#                       making helper functions available in the caller.
#
# Callers should `set -e` and `source tests/scripts/helpers.sh` from any
# test script. This file must be side-effect-free until a helper is invoked.

# Resolve once so later `cd` calls inside a test don't re-anchor us.
if [ -z "${REIN_PROJECT_ROOT:-}" ]; then
  _helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REIN_PROJECT_ROOT="$(cd "$_helpers_dir/../.." && pwd)"
  unset _helpers_dir
fi
REIN_SCRIPT="$REIN_PROJECT_ROOT/scripts/rein.sh"

# --- sandbox_repo ----------------------------------------------------------
# Creates a fresh tempdir with:
#   - git init
#   - minimal .claude/ directory structure
#   - fixture files copied from rein-template-min if present
# Prints the sandbox path. Caller must `cd "$path"` and clean up when done.
sandbox_repo() {
  local d
  d=$(mktemp -d -t rein-sandbox-XXXXXX)
  mkdir -p "$d/.claude/rules" "$d/.claude/skills"
  ( cd "$d" && git init -q )
  if [ -d "$REIN_PROJECT_ROOT/tests/scripts/fixtures/rein-template-min" ]; then
    # copy the contents (including dotfiles) into the sandbox root
    ( cd "$REIN_PROJECT_ROOT/tests/scripts/fixtures/rein-template-min" \
        && cp -R . "$d/" )
  fi
  echo "$d"
}

# --- rein_exec -------------------------------------------------------------
# Run rein.sh with all caller args. Uses absolute REIN_SCRIPT so the test can
# `cd` into a sandbox before invoking.
rein_exec() {
  bash "$REIN_SCRIPT" "$@"
}

# --- rein_source -----------------------------------------------------------
# Source rein.sh in --source-only mode. Helpers become available in caller.
# shellcheck disable=SC1090
rein_source() {
  # shellcheck source=/dev/null
  source "$REIN_SCRIPT" --source-only
}
