#!/usr/bin/env bash
# test-state-path-governance-plugin.sh — Phase 3 Task 3.2.
#
# Verifies plugins/rein-core/scripts/rein-state-paths.py governance resolution
# in plugin mode (Plan §704-760).
#
# Contract:
#   * mode=plugin + CLAUDE_PLUGIN_DATA=/abs/path
#       -> /abs/path/runtime/governance.json
#   * mode=plugin + CLAUDE_PLUGIN_DATA unset
#       -> exit non-zero with explicit "fail-closed" message (Round 6 fix —
#          spec §5.5 plugin-mode IDs require deterministic resolution; silent
#          fallback to .rein/cache forbidden).
#
# Scope ID: governance-state-uses-claude-plugin-data-runtime-when-mode-plugin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER="$PROJECT_DIR/plugins/rein-core/scripts/rein-state-paths.py"

if [ ! -f "$RESOLVER" ]; then
  echo "FAIL: resolver missing: $RESOLVER" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# ---------------------------------------------------------------------------
# A: mode=plugin + CLAUDE_PLUGIN_DATA set -> runtime path under plugin data
# ---------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein"
cat >"$A_DIR/.rein/project.json" <<'JSON'
{"mode": "plugin"}
JSON
PLUGIN_DATA="$TMP_ROOT/plugin-data-A"
mkdir -p "$PLUGIN_DATA"
set +e
( cd "$A_DIR" && CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    python3 "$RESOLVER" governance </dev/null \
    >"$A_DIR/stdout" 2>"$A_DIR/stderr" )
A_RC=$?
set -e
[ "$A_RC" = "0" ] || { cat "$A_DIR/stderr" >&2; fail "A: expected exit 0, got $A_RC"; }
A_GOT="$(cat "$A_DIR/stdout")"
A_WANT="$PLUGIN_DATA/runtime/governance.json"
[ "$A_GOT" = "$A_WANT" ] || fail "A: got '$A_GOT' want '$A_WANT'"
ok "A: mode=plugin + CLAUDE_PLUGIN_DATA -> $PLUGIN_DATA/runtime/governance.json"

# ---------------------------------------------------------------------------
# B: mode=plugin + CLAUDE_PLUGIN_DATA UNSET -> fail-closed (non-zero exit)
# Round 6 fix: silent fallback to .rein/cache contradicts spec §5.5.
# ---------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein"
cat >"$B_DIR/.rein/project.json" <<'JSON'
{"mode": "plugin"}
JSON
set +e
# Explicitly unset CLAUDE_PLUGIN_DATA. env -u preserves other env so we can
# guarantee the only difference vs A is the missing var.
( cd "$B_DIR" && env -u CLAUDE_PLUGIN_DATA \
    python3 "$RESOLVER" governance </dev/null \
    >"$B_DIR/stdout" 2>"$B_DIR/stderr" )
B_RC=$?
set -e
[ "$B_RC" != "0" ] || fail "B: expected non-zero exit (fail-closed), got 0"
B_ERR="$(cat "$B_DIR/stderr")"
case "$B_ERR" in
  *CLAUDE_PLUGIN_DATA*) ;;
  *) fail "B: stderr missing CLAUDE_PLUGIN_DATA mention; got: $B_ERR" ;;
esac
ok "B: mode=plugin + env unset -> fail-closed (rc=$B_RC, stderr names CLAUDE_PLUGIN_DATA)"

# ---------------------------------------------------------------------------
# C: unknown state name -> non-zero exit
# ---------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR"
set +e
( cd "$C_DIR" && python3 "$RESOLVER" totally-unknown </dev/null \
    >"$C_DIR/stdout" 2>"$C_DIR/stderr" )
C_RC=$?
set -e
[ "$C_RC" != "0" ] || fail "C: expected non-zero exit for unknown state, got 0"
ok "C: unknown state name -> non-zero exit (rc=$C_RC)"

echo "test-state-path-governance-plugin: OK (3/3 assertions)"
