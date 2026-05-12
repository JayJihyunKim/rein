#!/usr/bin/env bash
# Verify user-prompt-submit-rules.sh:
#   (a) happy path — emits valid JSON envelope for UserPromptSubmit with
#       additionalContext containing the answer-only-mode action mandate header
#   (b) graceful degrade — missing CLAUDE_PLUGIN_ROOT → exit 0, empty stdout
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/user-prompt-submit-rules.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

# ---------- (a) happy path ---------------------------------------------------
HAPPY_OUT=$(mktemp)
trap 'rm -f "$HAPPY_OUT" "$DEGRADE_OUT" 2>/dev/null || true' EXIT
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$HAPPY_OUT" 2>/dev/null
python3 - "$HAPPY_OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL: happy stdout empty", file=sys.stderr); sys.exit(1)
data = json.loads(raw)
hso = data.get("hookSpecificOutput", {})
if hso.get("hookEventName") != "UserPromptSubmit":
    print(f"FAIL: hookEventName {hso.get('hookEventName')!r}", file=sys.stderr); sys.exit(1)
ctx = hso.get("additionalContext", "")
if "행동 강령" not in ctx:
    print("FAIL: additionalContext missing '행동 강령' header", file=sys.stderr); sys.exit(1)
PY

# ---------- (b) graceful degrade ---------------------------------------------
DEGRADE_OUT=$(mktemp)
env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" </dev/null >"$DEGRADE_OUT" 2>/dev/null
[ -s "$DEGRADE_OUT" ] && { echo "FAIL: degrade stdout non-empty" >&2; cat "$DEGRADE_OUT" >&2; exit 1; }

echo "test-user-prompt-submit-rules: OK (envelope + graceful-degrade)"
