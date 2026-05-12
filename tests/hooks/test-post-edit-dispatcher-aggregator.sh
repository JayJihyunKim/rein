#!/usr/bin/env bash
# Verify dispatcher aggregator behavior:
#   (1) Two sub-hooks emit envelopes → dispatcher emits ONE envelope with
#       additionalContext = "<a>\n\n---\n\n<b>"
#   (2) Any sub-hook exit 2 → dispatcher exit 2
#   (3) Invalid JSON sub-hook output → stderr diagnostic + dropped + other
#       envelopes still aggregated
#   (4) Empty aggregator → no stdout
#
# Unit-tests the aggregator helper directly (decoupled from dispatcher's
# 7-sub-hook wiring, which is exercised by test-post-edit-dispatcher.sh).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HELPER="$PROJECT_DIR/plugins/rein-core/hooks/lib/aggregator.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }

# (1) two envelopes → concat with separator
OUT1=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"AAA\"}}' 0
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"BBB\"}}' 0
aggregator_emit
")
OUT1="$OUT1" python3 - <<'PY' || exit 1
import json, os
data = json.loads(os.environ["OUT1"])
ctx = data["hookSpecificOutput"]["additionalContext"]
assert ctx == "AAA\n\n---\n\nBBB", repr(ctx)
assert data["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
PY
echo "  ok: (1) two envelopes concatenated with \\n\\n---\\n\\n separator"

# (2) exit 2 propagation — order should not matter (OR-based, not max)
RC2=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"X\"}}' 0
aggregator_add '' 2
aggregator_exit_code
")
[ "$RC2" = "2" ] || { echo "FAIL: exit-2 propagation (post-positioned) got '$RC2'" >&2; exit 1; }

# Reverse order — exit-2 emitted first
RC2B=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '' 2
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"X\"}}' 0
aggregator_exit_code
")
[ "$RC2B" = "2" ] || { echo "FAIL: exit-2 propagation (pre-positioned) got '$RC2B'" >&2; exit 1; }

# 127 (sub-hook missing) must NOT override 2 → final rc should be 2 not 127.
RC2C=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '' 127
aggregator_add '' 2
aggregator_add '' 127
aggregator_exit_code
" 2>/dev/null)
[ "$RC2C" = "2" ] || { echo "FAIL: 127 should not mask exit 2; got '$RC2C'" >&2; exit 1; }

# Pure 127 (no exit 2) → rc 0 (best-effort, diagnostic only)
RC0=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '' 127
aggregator_exit_code
" 2>/dev/null)
[ "$RC0" = "0" ] || { echo "FAIL: 127 alone should yield rc 0; got '$RC0'" >&2; exit 1; }
echo "  ok: (2) exit-2 propagates regardless of position; 127 does not mask 2 and alone is ignored"

# (3) invalid JSON dropped, valid one preserved, diagnostic on stderr
TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT
OUT3=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add 'not json at all' 0
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"VALID\"}}' 0
aggregator_emit
" 2>"$TMP_ERR")
OUT3="$OUT3" python3 - <<'PY' || exit 1
import json, os
data = json.loads(os.environ["OUT3"])
ctx = data["hookSpecificOutput"]["additionalContext"]
assert ctx == "VALID", repr(ctx)
PY
grep -q "rein-dispatcher: sub-hook stdout is not a valid JSON envelope" "$TMP_ERR" \
  || { echo "FAIL: missing stderr diagnostic for invalid JSON" >&2; cat "$TMP_ERR" >&2; exit 1; }
echo "  ok: (3) invalid JSON dropped with stderr diagnostic; valid envelope preserved"

# (3b) Wrong-shape JSON (valid JSON but no hookSpecificOutput) → drop + diagnostic
: > "$TMP_ERR"
OUT3B=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '{\"foo\":\"bar\"}' 0
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"OK\"}}' 0
aggregator_emit
" 2>"$TMP_ERR")
OUT3B="$OUT3B" python3 - <<'PY' || exit 1
import json, os
data = json.loads(os.environ["OUT3B"])
assert data["hookSpecificOutput"]["additionalContext"] == "OK"
PY
grep -q "rein-dispatcher: sub-hook stdout is not a valid JSON envelope" "$TMP_ERR" \
  || { echo "FAIL: wrong-shape JSON should produce diagnostic" >&2; cat "$TMP_ERR" >&2; exit 1; }
echo "  ok: (3b) wrong-shape JSON dropped with diagnostic"

# (4) empty aggregator → no stdout
OUT4=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_emit
")
[ -z "$OUT4" ] || { echo "FAIL: empty emit produced output: $OUT4" >&2; exit 1; }
echo "  ok: (4) empty aggregator → no stdout"

# (5) single envelope → no trailing separator
OUT5=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"ONLY\"}}' 0
aggregator_emit
")
OUT5="$OUT5" python3 - <<'PY' || exit 1
import json, os
data = json.loads(os.environ["OUT5"])
ctx = data["hookSpecificOutput"]["additionalContext"]
assert ctx == "ONLY", repr(ctx)
# Verify no trailing '\n\n---\n\n' separator
assert not ctx.endswith("---"), "trailing separator leaked"
PY
echo "  ok: (5) single envelope → no trailing separator"

# (6) sub-hook stdout that is empty (silent success) → contributes nothing
# but does not break the chain
OUT6=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '' 0
aggregator_add '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"AFTER_EMPTY\"}}' 0
aggregator_add '' 0
aggregator_emit
")
OUT6="$OUT6" python3 - <<'PY' || exit 1
import json, os
data = json.loads(os.environ["OUT6"])
ctx = data["hookSpecificOutput"]["additionalContext"]
assert ctx == "AFTER_EMPTY", repr(ctx)
PY
echo "  ok: (6) empty sub-hook stdout contributes nothing; other envelopes preserved"

# (7) multi-line additionalContext preserved exactly (NUL-safe transport)
OUT7=$(bash -c "
source '$HELPER'
aggregator_init
aggregator_add '$(python3 -c 'import json; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"line1\nline2\n\n  indented"}}))')' 0
aggregator_add '$(python3 -c 'import json; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"otherA\notherB"}}))')' 0
aggregator_emit
")
OUT7="$OUT7" python3 - <<'PY' || exit 1
import json, os
data = json.loads(os.environ["OUT7"])
ctx = data["hookSpecificOutput"]["additionalContext"]
assert ctx == "line1\nline2\n\n  indented\n\n---\n\notherA\notherB", repr(ctx)
PY
echo "  ok: (7) multi-line additionalContext preserved exactly"

echo "test-post-edit-dispatcher-aggregator: OK (7/7 scenarios)"
