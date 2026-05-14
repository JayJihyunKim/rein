#!/usr/bin/env bash
# test-state-path-inventory-plugin.sh — Phase 3 Task 3.4.
#
# Verifies that plugins/rein-core/scripts/rein-generate-skill-mcp-guide.py
# resolves its inventory + guide output paths through rein-state-paths.py
# in plugin mode (Plan §775-786).
#
# Contract:
#   * mode=plugin + CLAUDE_PLUGIN_DATA=/abs/path
#       inventory and guide are written under
#       /abs/path/runtime/inventory/.
#   * The resolver path itself returns
#       /abs/path/runtime/inventory   (no trailing slash; Path() drops it)
#
# Scope ID: inventory-cache-uses-claude-plugin-data-runtime-when-mode-plugin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER="$PROJECT_DIR/plugins/rein-core/scripts/rein-state-paths.py"
GUIDE_GEN="$PROJECT_DIR/plugins/rein-core/scripts/rein-generate-skill-mcp-guide.py"

[ -f "$RESOLVER" ] || { echo "FAIL: resolver missing: $RESOLVER" >&2; exit 1; }
[ -f "$GUIDE_GEN" ] || { echo "FAIL: guide generator missing: $GUIDE_GEN" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# ---------------------------------------------------------------------------
# A: resolver returns plugin path for inventory state
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
    python3 "$RESOLVER" inventory </dev/null \
    >"$A_DIR/stdout" 2>"$A_DIR/stderr" )
A_RC=$?
set -e
[ "$A_RC" = "0" ] || { cat "$A_DIR/stderr" >&2; fail "A: rc=$A_RC"; }
A_GOT="$(cat "$A_DIR/stdout")"
A_WANT="$PLUGIN_DATA/runtime/inventory"
[ "$A_GOT" = "$A_WANT" ] || fail "A: got '$A_GOT' want '$A_WANT'"
ok "A: mode=plugin -> $A_WANT"

# ---------------------------------------------------------------------------
# B: rein-generate-skill-mcp-guide.py routes outputs through resolver in
#    plugin mode. We exercise this by:
#    1) creating a minimal inventory.json at the plugin-mode path
#    2) running the generator with mode=plugin + CLAUDE_PLUGIN_DATA set
#    3) asserting skill-mcp-guide.md is written under the plugin runtime dir
# ---------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein"
cat >"$B_DIR/.rein/project.json" <<'JSON'
{"mode": "plugin"}
JSON
PLUGIN_DATA_B="$TMP_ROOT/plugin-data-B"
mkdir -p "$PLUGIN_DATA_B/runtime/inventory"
cat >"$PLUGIN_DATA_B/runtime/inventory/skill-mcp-inventory.json" <<'JSON'
{
  "schema_version": 1,
  "skills": {"project": [], "user": []},
  "mcps":   {"project": [], "user": []},
  "agents": {"project": [], "user": []}
}
JSON
# Plugin-mode generator needs CLAUDE_PLUGIN_ROOT (resolver lookup) AND
# CLAUDE_PLUGIN_DATA (path computation). In test we point both at the
# plugin install root + isolated runtime dir respectively.
set +e
( cd "$B_DIR" \
    && CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" \
       CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_B" \
       python3 "$GUIDE_GEN" </dev/null \
       >"$B_DIR/stdout" 2>"$B_DIR/stderr" )
B_RC=$?
set -e
# Generator failure isn't itself a test failure (generator is best-effort), but
# the OUTPUT path must be the plugin runtime dir if the generator did succeed.
if [ "$B_RC" = "0" ]; then
  [ -f "$PLUGIN_DATA_B/runtime/inventory/skill-mcp-guide.md" ] \
    || fail "B: guide not written to plugin runtime path"
  # Reverse assertion: generator must NOT have written to .claude/cache/.
  [ ! -f "$B_DIR/.claude/cache/skill-mcp-guide.md" ] \
    || fail "B: guide leaked to legacy .claude/cache/"
  ok "B: generator routed output to plugin runtime path"
else
  echo "  warn: generator exited rc=$B_RC; stderr:"
  sed 's/^/    /' "$B_DIR/stderr" >&2
  fail "B: generator failed under plugin-mode fixture"
fi

echo "test-state-path-inventory-plugin: OK (2/2 assertions)"
