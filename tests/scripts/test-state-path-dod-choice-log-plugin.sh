#!/usr/bin/env bash
# test-state-path-dod-choice-log-plugin.sh — Phase 3 Task 3.5.
#
# Verifies plugins/rein-core/scripts/rein-state-paths.py active-dod-choice-log
# resolution in plugin mode, and that select-active-dod.sh's choice-log
# append routes through the resolver (Plan §788-799).
#
# Contract:
#   * mode=plugin + CLAUDE_PLUGIN_DATA=/abs/path
#       -> /abs/path/runtime/active-dod-choice.log
#   * select-active-dod.sh _sad_record_session_choice writes to the resolved
#     plugin path under plugin install rather than .claude/cache/.
#
# Scope ID: active-dod-choice-log-uses-claude-plugin-data-runtime-when-mode-plugin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER="$PROJECT_DIR/plugins/rein-core/scripts/rein-state-paths.py"
SAD_LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"

[ -f "$RESOLVER" ] || { echo "FAIL: resolver missing: $RESOLVER" >&2; exit 1; }
[ -f "$SAD_LIB" ]  || { echo "FAIL: select-active-dod lib missing: $SAD_LIB" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# ---------------------------------------------------------------------------
# A: resolver returns the plugin runtime path for active-dod-choice-log
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
    python3 "$RESOLVER" active-dod-choice-log </dev/null \
    >"$A_DIR/stdout" 2>"$A_DIR/stderr" )
A_RC=$?
set -e
[ "$A_RC" = "0" ] || { cat "$A_DIR/stderr" >&2; fail "A: rc=$A_RC"; }
A_GOT="$(cat "$A_DIR/stdout")"
A_WANT="$PLUGIN_DATA/runtime/active-dod-choice.log"
[ "$A_GOT" = "$A_WANT" ] || fail "A: got '$A_GOT' want '$A_WANT'"
ok "A: mode=plugin -> $A_WANT"

# ---------------------------------------------------------------------------
# B: select-active-dod _sad_record_session_choice routes through resolver
#    when CLAUDE_PLUGIN_ROOT + CLAUDE_PLUGIN_DATA are set.
# ---------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein"
cat >"$B_DIR/.rein/project.json" <<'JSON'
{"mode": "plugin"}
JSON
PLUGIN_DATA_B="$TMP_ROOT/plugin-data-B"
mkdir -p "$PLUGIN_DATA_B"
mkdir -p "$B_DIR/trail/dod"
echo "dummy dod content" > "$B_DIR/trail/dod/dod-2026-04-28-stub.md"

set +e
( cd "$B_DIR" \
    && CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" \
       CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_B" \
       REIN_SESSION_ID="test-3.5" \
       bash -c "source '$SAD_LIB' && _sad_record_session_choice 1 'trail/dod/dod-2026-04-28-stub.md' 'unit-test'" \
       </dev/null >"$B_DIR/stdout" 2>"$B_DIR/stderr" )
B_RC=$?
set -e
[ "$B_RC" = "0" ] || { cat "$B_DIR/stderr" >&2; fail "B: rc=$B_RC"; }

# Plugin path must contain the appended line.
PLUGIN_LOG="$PLUGIN_DATA_B/runtime/active-dod-choice.log"
[ -f "$PLUGIN_LOG" ] || fail "B: plugin log not created at $PLUGIN_LOG"
grep -q 'unit-test' "$PLUGIN_LOG" || fail "B: plugin log missing record"
# Legacy path must NOT have been written.
[ ! -f "$B_DIR/.claude/cache/active-dod-choice.log" ] \
  || fail "B: write leaked to .claude/cache/active-dod-choice.log"
ok "B: _sad_record_session_choice routed to plugin runtime path"

echo "test-state-path-dod-choice-log-plugin: OK (2/2 assertions)"
