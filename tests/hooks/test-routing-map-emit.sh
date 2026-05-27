#!/usr/bin/env bash
# tests/hooks/test-routing-map-emit.sh — G3 Phase 1 Task 1.2 / Phase 4 Task 4.2
#
# Verifies plugins/rein-core/hooks/session-start-rules.sh emits the new
# routing-map.md rule body as part of the SessionStart additionalContext
# envelope, after the existing 4 rules.
#
# Assertions:
#   (a) routing-map.md standalone byte count <= 800B (NFR token budget)
#   (b) additionalContext contains routing-map.md substring
#       (`> 상세: plugins/rein-core/rules/routing-procedure.md`)
#   (c) Emit order: `code-style` body precedes `routing-map` body
#
# Scope ID: G3-RM
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="plugins/rein-core/hooks/session-start-rules.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
ROUTING_MAP="$PLUGIN_ROOT/rules/routing-map.md"

[ -f "$HOOK" ]        || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ]        || { echo "FAIL: $HOOK is not executable" >&2; exit 1; }
[ -f "$ROUTING_MAP" ] || { echo "FAIL: $ROUTING_MAP missing" >&2; exit 1; }

# ---------- (a) Byte count <= 800B ----------------------------------------
BYTES=$(wc -c < "$ROUTING_MAP")
if [ "$BYTES" -gt 800 ]; then
  echo "FAIL: routing-map.md $BYTES bytes exceeds 800B NFR budget" >&2
  exit 1
fi

# ---------- (b)+(c) Emit envelope + substring + order ---------------------
OUT=$(mktemp)
ERR=$(mktemp)
trap 'rm -f "$OUT" "$ERR" 2>/dev/null || true' EXIT

CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$OUT" 2>"$ERR"
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "FAIL: hook exited rc=$RC" >&2
  echo "----- stderr -----" >&2
  cat "$ERR" >&2
  exit 1
fi

python3 - "$OUT" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    raw = fh.read()

if not raw.strip():
    print("FAIL: hook produced empty stdout (expected JSON envelope)", file=sys.stderr)
    sys.exit(1)

try:
    payload = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"FAIL: stdout is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

ctx = payload.get("hookSpecificOutput", {}).get("additionalContext", "")
if not isinstance(ctx, str) or not ctx:
    print("FAIL: additionalContext missing or empty", file=sys.stderr)
    sys.exit(1)

# (b) Substring check — last line of routing-map.md
marker = "> 상세: plugins/rein-core/rules/routing-procedure.md"
if marker not in ctx:
    print(f"FAIL: additionalContext missing routing-map marker: {marker!r}", file=sys.stderr)
    print(f"----- additionalContext (last 500 chars) -----\n{ctx[-500:]}", file=sys.stderr)
    sys.exit(1)

# (c) Order check — code-style header precedes routing-map marker
cs_idx = ctx.find("# Code Style Rules")
rm_idx = ctx.find(marker)
if cs_idx < 0:
    print("FAIL: code-style header not found in envelope", file=sys.stderr)
    sys.exit(1)
if not (cs_idx < rm_idx):
    print(
        f"FAIL: emit order — code-style({cs_idx}) should precede routing-map({rm_idx})",
        file=sys.stderr,
    )
    sys.exit(1)

print("test-routing-map-emit: OK (byte<=800, marker present, code-style precedes routing-map)")
PY
