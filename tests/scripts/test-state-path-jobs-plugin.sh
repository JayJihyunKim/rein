#!/usr/bin/env bash
# test-state-path-jobs-plugin.sh — Phase 3 Task 3.3.
#
# Verifies plugins/rein-core/scripts/rein-state-paths.py jobs resolution in
# plugin mode. The wrapper itself takes paths as arguments and is NOT mode-
# aware (Plan §763-773 step 2 wording is shorthand — the hardcoded jobs path
# lives in scripts/rein.sh ``rein_jobs_dir()`` and is migrated separately in
# Phase 4 ``rein migrate``). This Phase 3 test asserts the resolver contract
# only; ``rein job start`` plumbing is exercised by existing test-job-* suite.
#
# Contract:
#   * mode=plugin + CLAUDE_PLUGIN_DATA=/abs/path
#       -> /abs/path/runtime/jobs/   (note trailing slash from STATE_FILES tuple)
#   * Resolver path is ATOMIC-WRITE friendly: callers can mkdir -p the result
#     and write tmp+rename inside it without permission issues.
#
# Scope ID: jobs-cache-uses-claude-plugin-data-runtime-when-mode-plugin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER="$PROJECT_DIR/plugins/rein-core/scripts/rein-state-paths.py"

[ -f "$RESOLVER" ] || { echo "FAIL: resolver missing: $RESOLVER" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# A: plugin mode -> runtime/jobs/ under CLAUDE_PLUGIN_DATA
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein"
cat >"$A_DIR/.rein/project.json" <<'JSON'
{"mode": "plugin"}
JSON
PLUGIN_DATA="$TMP_ROOT/plugin-data-A"
mkdir -p "$PLUGIN_DATA"
set +e
( cd "$A_DIR" && CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    python3 "$RESOLVER" jobs </dev/null >"$A_DIR/stdout" 2>"$A_DIR/stderr" )
A_RC=$?
set -e
[ "$A_RC" = "0" ] || { cat "$A_DIR/stderr" >&2; fail "A: rc=$A_RC"; }
A_GOT="$(cat "$A_DIR/stdout")"
A_WANT="$PLUGIN_DATA/runtime/jobs"
[ "$A_GOT" = "$A_WANT" ] || fail "A: got '$A_GOT' want '$A_WANT'"
ok "A: mode=plugin -> $A_WANT"

# B: atomic-write friendly — mkdir + tmp+rename inside resolved dir works.
mkdir -p "$A_GOT"
echo '{"name":"smoke"}' > "$A_GOT/foo.json.tmp.$$"
mv -f "$A_GOT/foo.json.tmp.$$" "$A_GOT/foo.json"
[ -f "$A_GOT/foo.json" ] || fail "B: atomic write failed at $A_GOT"
ok "B: atomic mkdir + tmp+rename inside resolved jobs/ works"

# C: plugin mode without CLAUDE_PLUGIN_DATA -> fail-closed
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR/.rein"
cat >"$C_DIR/.rein/project.json" <<'JSON'
{"mode": "plugin"}
JSON
set +e
( cd "$C_DIR" && env -u CLAUDE_PLUGIN_DATA \
    python3 "$RESOLVER" jobs </dev/null >"$C_DIR/stdout" 2>"$C_DIR/stderr" )
C_RC=$?
set -e
[ "$C_RC" != "0" ] || fail "C: expected fail-closed, got rc=0"
ok "C: mode=plugin without CLAUDE_PLUGIN_DATA -> fail-closed (rc=$C_RC)"

echo "test-state-path-jobs-plugin: OK (3/3 assertions)"
