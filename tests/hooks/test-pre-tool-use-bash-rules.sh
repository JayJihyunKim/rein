#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/pre-tool-use-bash-rules.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
OUT=$(mktemp); DEG=$(mktemp); trap 'rm -f "$OUT" "$DEG"' EXIT

# (a) happy path — envelope with PreToolUse + background-jobs mandate
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$OUT" 2>/dev/null
python3 - "$OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(raw)
hso = data.get("hookSpecificOutput", {})
assert hso.get("hookEventName") == "PreToolUse", f"hookEventName {hso.get('hookEventName')!r}"
ctx = hso.get("additionalContext", "")
assert "행동 강령" in ctx, "missing 행동 강령"
assert "background" in ctx.lower() or "rein job" in ctx.lower(), "missing background-jobs marker"
PY

# (b) graceful degrade
env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" </dev/null >"$DEG" 2>/dev/null
[ -s "$DEG" ] && { echo "FAIL: degrade non-empty" >&2; exit 1; }

# (c) no exit 2 — advisory only (must not block)
set +e
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: advisory hook exited with $RC (must be 0)" >&2; exit 1; }

echo "test-pre-tool-use-bash-rules: OK (envelope + degrade + no-block)"
