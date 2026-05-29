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
# injected-rule-language-follow-user (2026-05-29): the per-turn short summaries
# are now English so the recurring hot-path context does not soft-anchor output
# to Korean for English users. Assert the English answer-only title instead of
# the old '행동 강령' header.
if "Answer-only quick rule" not in ctx:
    print("FAIL: additionalContext missing 'Answer-only quick rule' (short answer-only summary)", file=sys.stderr); sys.exit(1)
# The Korean action-mandate header must NOT appear in the per-turn hot path —
# it was the soft anchor biasing output toward Korean.
if "행동 강령" in ctx:
    print("FAIL: per-turn envelope still carries Korean '행동 강령' anchor — hot path must be English", file=sys.stderr); sys.exit(1)
# TONE-1 (2026-05-27) + communication-improve (2026-05-28):
# Per-turn envelope ships the SHORT response-tone summary, not the full body.
# Header text: "# Response Tone — per-turn quick rule".
if "Response Tone" not in ctx:
    print("FAIL: additionalContext missing 'Response Tone' (short summary)", file=sys.stderr); sys.exit(1)
# injected-rule-language-follow-user (2026-05-29): every turn must carry the
# output-language policy so the model follows the user's message language
# rather than the repo's Korean context.
if "Respond in the language of the user" not in ctx:
    print("FAIL: additionalContext missing output-language policy (follow user's language)", file=sys.stderr); sys.exit(1)
# Sanity — the per-turn injection must NOT carry the full body's translation
# table (delivered once via session-start instead, to keep per-turn cost flat).
if "| 내부 표현 | 사용자 언어 |" in ctx:
    print("FAIL: per-turn envelope unexpectedly contains full body's translation table — should be short summary only", file=sys.stderr); sys.exit(1)
PY

# ---------- (b) graceful degrade ---------------------------------------------
DEGRADE_OUT=$(mktemp)
env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" </dev/null >"$DEGRADE_OUT" 2>/dev/null
[ -s "$DEGRADE_OUT" ] && { echo "FAIL: degrade stdout non-empty" >&2; cat "$DEGRADE_OUT" >&2; exit 1; }

echo "test-user-prompt-submit-rules: OK (envelope + graceful-degrade)"
