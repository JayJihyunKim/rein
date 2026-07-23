#!/usr/bin/env bash
# tests/hooks/test-session-start-byte-budget.sh — per-hook cap regression (PT-9)
#
# The original persona/rule-loss bug: session-start-rules.sh concatenated 6
# full rule bodies + persona into ONE additionalContext envelope (~22.6KB),
# overflowing the Claude Code per-hook additionalContext cap (10,000 chars).
# The harness persisted the oversized output to a file and inlined only a ~2KB
# preview, so the tail (persona + 4 rules) never reached the model.
#
# Truncation is PER-HOOK (documented + live-evidenced: in the incident session,
# load-trail's ~6.6KB survived inline despite ~29KB total SessionStart — a
# total-aggregate cap would have truncated it too). So safety reduces to "each
# hook's emitted additionalContext stays under the per-hook cap". This test
# guards that with conservative budgets (well under 10,000) so a future rule/
# persona/summary growth is caught before release.
#
# Output-shape branch (PT-9): envelope hooks (rules/persona/ups) carry their
# payload inside hookSpecificOutput.additionalContext (measured decoded);
# plain-stdout hooks (bootstrap/load-trail) emit raw stdout that Claude Code
# absorbs as additionalContext (measured as raw bytes).
#
# Scope ID: PT-9
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
HOOKS="$PLUGIN_ROOT/hooks"

# Conservative per-hook budgets (bytes). All well under the platform per-hook
# cap (10,000 chars) so growth is caught with headroom to spare.
BUDGET_RULES=8000        # rules summaries (~4.8KB today)
BUDGET_PERSONA=6000      # invariant layer (<=1,000 chars Korean ~ <=3,000B
                         # UTF-8) + builtin preset body (<=1,536B) + separator
                         # (~10B) ~ <=4.6KB worst case -> 6,000B budget keeps
                         # headroom while staying well under the 10,000-char cap
BUDGET_UPS=4000          # per-turn brief (~2.2KB today)
BUDGET_PLAIN=8000        # bootstrap / load-trail raw stdout

PASS=0
FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }

# Measure an ENVELOPE hook: decode hookSpecificOutput.additionalContext and
# print its UTF-8 byte length (0 when stdout is empty / not an envelope).
ctx_bytes() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print(0); sys.exit(0)
try:
    ctx = (json.loads(raw).get("hookSpecificOutput") or {}).get("additionalContext", "")
except Exception:
    print(-1); sys.exit(0)
print(len(ctx.encode("utf-8")) if isinstance(ctx, str) else -1)
'
}

# Measure a PLAIN-stdout hook: byte length of raw stdout.
raw_bytes() { wc -c | tr -d ' '; }

# ---- (a) session-start-rules.sh additionalContext <= BUDGET_RULES ----------
RULES_CTX_FILE="$(mktemp)"
( cd "$(mktemp -d)" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS/session-start-rules.sh" </dev/null 2>/dev/null ) > "$RULES_CTX_FILE"
RULES_BYTES="$(ctx_bytes < "$RULES_CTX_FILE")"
if [ "$RULES_BYTES" -ge 0 ] && [ "$RULES_BYTES" -le "$BUDGET_RULES" ]; then
  ok "(a) session-start-rules additionalContext ${RULES_BYTES}B <= ${BUDGET_RULES}B"
else
  fail "(a) session-start-rules additionalContext ${RULES_BYTES}B exceeds ${BUDGET_RULES}B"
fi

# ---- (b) session-start-persona.sh additionalContext <= BUDGET_PERSONA -------
# Neutral default emits NOTHING with no persona.yaml (0B would be vacuous), so
# measure with explicit enabled:true fixtures for BOTH builtin presets. Require
# >= 1B so a silently-empty envelope can't fake a pass.
for preset in boss-ace jennie; do
  P_DIR="$(mktemp -d)"
  mkdir -p "$P_DIR/.rein/policy"
  printf 'enabled: true\npreset: %s\n' "$preset" > "$P_DIR/.rein/policy/persona.yaml"
  PERSONA_BYTES="$( ( cd "$P_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS/session-start-persona.sh" </dev/null 2>/dev/null ) | ctx_bytes )"
  if [ "$PERSONA_BYTES" -ge 1 ] && [ "$PERSONA_BYTES" -le "$BUDGET_PERSONA" ]; then
    ok "(b) session-start-persona [$preset] additionalContext ${PERSONA_BYTES}B in 1..${BUDGET_PERSONA}B"
  else
    fail "(b) session-start-persona [$preset] additionalContext ${PERSONA_BYTES}B outside 1..${BUDGET_PERSONA}B"
  fi
  rm -rf "$P_DIR"
done

# ---- (b2) persona source-file size contracts ---------------------------------
# The BUDGET_PERSONA arithmetic above only holds if the source files respect
# their own caps: _invariant.md <= 1,000 CHARS (UTF-8 decoded) and the largest
# builtin preset jennie.md <= 1,536 BYTES.
INVARIANT_MD="$PLUGIN_ROOT/rules/persona/_invariant.md"
JENNIE_MD="$PLUGIN_ROOT/rules/persona/jennie.md"
if [ -f "$INVARIANT_MD" ]; then
  INV_CHARS="$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$INVARIANT_MD")"
  if [ "$INV_CHARS" -le 1000 ]; then
    ok "(b2) _invariant.md ${INV_CHARS} chars <= 1000"
  else
    fail "(b2) _invariant.md ${INV_CHARS} chars exceeds 1000"
  fi
else
  fail "(b2) _invariant.md missing at $INVARIANT_MD (invariant layer not shipped)"
fi
if [ -f "$JENNIE_MD" ]; then
  JENNIE_BYTES="$(wc -c < "$JENNIE_MD" | tr -d ' ')"
  if [ "$JENNIE_BYTES" -le 1536 ]; then
    ok "(b2) jennie.md ${JENNIE_BYTES}B <= 1536B"
  else
    fail "(b2) jennie.md ${JENNIE_BYTES}B exceeds 1536B"
  fi
else
  fail "(b2) jennie.md missing at $JENNIE_MD (builtin preset not shipped)"
fi

# ---- (c) bootstrap + load-trail raw stdout <= BUDGET_PLAIN ------------------
# Plain-stdout hooks; run from the real project root so load-trail reads the
# actual trail/index.md (its ~6.6KB narrow-margin case). Empty stdout -> 0 -> pass.
for plain in session-start-bootstrap.sh session-start-load-trail.sh; do
  PBYTES="$( ( cd "$PROJECT_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS/$plain" </dev/null 2>/dev/null ) | raw_bytes )"
  if [ "$PBYTES" -le "$BUDGET_PLAIN" ]; then
    ok "(c) $plain raw stdout ${PBYTES}B <= ${BUDGET_PLAIN}B"
  else
    fail "(c) $plain raw stdout ${PBYTES}B exceeds ${BUDGET_PLAIN}B"
  fi
done

# ---- (d) user-prompt-submit-rules.sh additionalContext <= BUDGET_UPS --------
UPS_BYTES="$( ( cd "$(mktemp -d)" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS/user-prompt-submit-rules.sh" </dev/null 2>/dev/null ) | ctx_bytes )"
if [ "$UPS_BYTES" -ge 0 ] && [ "$UPS_BYTES" -le "$BUDGET_UPS" ]; then
  ok "(d) user-prompt-submit-rules additionalContext ${UPS_BYTES}B <= ${BUDGET_UPS}B"
else
  fail "(d) user-prompt-submit-rules additionalContext ${UPS_BYTES}B exceeds ${BUDGET_UPS}B"
fi

# ---- (e) rules envelope carries summaries, not full bodies ------------------
RULES_CTX="$(ctx_bytes < "$RULES_CTX_FILE" >/dev/null; python3 -c '
import json,sys
raw=open(sys.argv[1],encoding="utf-8").read()
print((json.loads(raw).get("hookSpecificOutput") or {}).get("additionalContext","") if raw.strip() else "")
' "$RULES_CTX_FILE")"
if printf '%s' "$RULES_CTX" | grep -q '전체 본문은' && ! printf '%s' "$RULES_CTX" | grep -q '## 임포트 순서'; then
  ok "(e) rules envelope has summary pointer + omits full-body-only marker"
else
  fail "(e) rules envelope summary-marker check failed (summaries not injected?)"
fi
rm -f "$RULES_CTX_FILE"

echo "test-session-start-byte-budget: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
