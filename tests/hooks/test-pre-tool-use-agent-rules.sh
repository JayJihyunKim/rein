#!/usr/bin/env bash
# Verify pre-tool-use-agent-rules.sh:
#   (a) happy path — emits valid JSON envelope for PreToolUse with
#       additionalContext containing the subagent-review action mandate header
#   (b) graceful degrade — missing CLAUDE_PLUGIN_ROOT → exit 0, empty stdout
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/pre-tool-use-agent-rules.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
OUT=$(mktemp); DEG=$(mktemp); trap 'rm -f "$OUT" "$DEG" 2>/dev/null || true' EXIT

# ---------- (a) happy path ---------------------------------------------------
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$OUT" 2>/dev/null
python3 - "$OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL: empty stdout", file=sys.stderr); sys.exit(1)
data = json.loads(raw)
hso = data.get("hookSpecificOutput", {})
if hso.get("hookEventName") != "PreToolUse":
    print(f"FAIL: hookEventName {hso.get('hookEventName')!r}", file=sys.stderr); sys.exit(1)
ctx = hso.get("additionalContext", "")
if "행동 강령" not in ctx:
    print("FAIL: additionalContext missing '행동 강령'", file=sys.stderr); sys.exit(1)
PY

# ---------- (b) graceful degrade ---------------------------------------------
env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" </dev/null >"$DEG" 2>/dev/null
[ -s "$DEG" ] && { echo "FAIL: degrade non-empty" >&2; cat "$DEG" >&2; exit 1; }

echo "test-pre-tool-use-agent-rules: OK"
