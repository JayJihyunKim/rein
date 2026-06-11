#!/usr/bin/env bash
# tests/scripts/test-policy-loader-turn-brief.sh — --turn-brief mode (PT-10)
#
# rein-policy-loader.py --turn-brief composes the per-turn UserPromptSubmit
# envelope (answer-only + response-tone + persona summaries, optional bootstrap
# prepend via env) in ONE process — replacing the per-turn hook's previous
# three python spawns. This test drives the real loader.
#
# Assertions:
#   (a) two loader copies byte-identical (PT-7 drift)
#   (b) persona enabled  -> valid envelope with answer-only + response-tone +
#       persona markers
#   (c) persona disabled -> persona marker absent, other two present
#   (d) answer-only summary absent -> empty stdout (hard-requirement fail-open)
#   (e) response-tone summary absent -> answer-only still emitted (optional skip)
#   (f) CLAUDE_PLUGIN_ROOT unset -> empty stdout + exit 0 (env fail-open)
#   (g) REIN_TURN_BRIEF_PREPEND set -> text prepended at the front of body
#   (h) every path exits 0
#
# Scope ID: PT-10
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"
LOADER_FALLBACK="$PROJECT_DIR/scripts/rein-policy-loader.py"

PASS=0; FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }

TMP_ROOT="$(mktemp -d "/tmp/test-turn-brief-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Decode hookSpecificOutput.additionalContext; print '' when no envelope.
extract_ctx() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
data = json.loads(raw)  # raises on invalid JSON -> test sees nonzero
ctx = (data.get("hookSpecificOutput") or {}).get("additionalContext", "")
ev = (data.get("hookSpecificOutput") or {}).get("hookEventName", "")
assert ev == "UserPromptSubmit", f"event={ev!r}"
sys.stdout.write(ctx)
'
}

# (a) byte-identical copies ---------------------------------------------------
if diff -q "$LOADER" "$LOADER_FALLBACK" >/dev/null 2>&1; then
  ok "(a) loader 2 copies byte-identical"
else
  fail "(a) loader copies differ (PT-7 drift)"
fi

# (b) persona enabled ---------------------------------------------------------
B_DIR="$TMP_ROOT/b"; mkdir -p "$B_DIR/.rein/policy"
printf 'enabled: true\npreset: boss-ace\n' > "$B_DIR/.rein/policy/persona.yaml"
B_OUT="$( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null )"
B_RC=$?
B_CTX="$(printf '%s' "$B_OUT" | extract_ctx)"
if [ "$B_RC" = "0" ] && printf '%s' "$B_CTX" | grep -q 'Answer-only' \
   && printf '%s' "$B_CTX" | grep -q 'Response Tone' \
   && printf '%s' "$B_CTX" | grep -q '보스'; then
  ok "(b) persona enabled -> answer-only + response-tone + persona markers"
else
  fail "(b) persona-enabled turn-brief missing a marker (rc=$B_RC)"
fi

# (c) persona disabled --------------------------------------------------------
C_DIR="$TMP_ROOT/c"; mkdir -p "$C_DIR/.rein/policy"
printf 'enabled: false\n' > "$C_DIR/.rein/policy/persona.yaml"
C_CTX="$( cd "$C_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$C_CTX" | grep -q 'Answer-only' \
   && printf '%s' "$C_CTX" | grep -q 'Response Tone' \
   && ! printf '%s' "$C_CTX" | grep -q '보스'; then
  ok "(c) persona disabled -> persona absent, other two present"
else
  fail "(c) persona-disabled turn-brief wrong markers"
fi

# Build a fake plugin root with a controllable rules/short/ for (d)/(e).
fake_root() {
  local dir="$1"; shift
  mkdir -p "$dir/rules/short"
  for f in "$@"; do
    printf '# %s marker\n' "$f" > "$dir/rules/short/$f.md"
  done
  echo "$dir"
}

# (d) answer-only absent -> empty stdout --------------------------------------
D_ROOT="$(fake_root "$TMP_ROOT/d" response-tone-summary)"  # no answer-only-summary
D_OUT="$( CLAUDE_PLUGIN_ROOT="$D_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null )"
D_RC=$?
if [ "$D_RC" = "0" ] && [ -z "$D_OUT" ]; then
  ok "(d) answer-only absent -> empty stdout + exit 0"
else
  fail "(d) answer-only absent should be empty (rc=$D_RC, len=${#D_OUT})"
fi

# (e) response-tone absent -> answer-only still emitted ------------------------
E_ROOT="$(fake_root "$TMP_ROOT/e" answer-only-summary)"  # no response-tone, no persona
E_OUT="$( CLAUDE_PLUGIN_ROOT="$E_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null )"
E_CTX="$(printf '%s' "$E_OUT" | extract_ctx)"
if printf '%s' "$E_CTX" | grep -q 'answer-only-summary marker'; then
  ok "(e) response-tone absent -> answer-only still emitted (optional skip)"
else
  fail "(e) answer-only-only turn-brief failed"
fi

# (f) CLAUDE_PLUGIN_ROOT unset -> empty + exit 0 ------------------------------
F_OUT="$( env -u CLAUDE_PLUGIN_ROOT python3 "$LOADER" --turn-brief 2>/dev/null )"
F_RC=$?
if [ "$F_RC" = "0" ] && [ -z "$F_OUT" ]; then
  ok "(f) CLAUDE_PLUGIN_ROOT unset -> empty stdout + exit 0"
else
  fail "(f) unset env should be empty exit 0 (rc=$F_RC, len=${#F_OUT})"
fi

# (g) REIN_TURN_BRIEF_PREPEND prepended --------------------------------------
G_CTX="$( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_TURN_BRIEF_PREPEND="PREPEND_SENTINEL_123" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
case "$G_CTX" in
  "PREPEND_SENTINEL_123"*) ok "(g) REIN_TURN_BRIEF_PREPEND prepended at front" ;;
  *) fail "(g) prepend not at front of body" ;;
esac

# (h) every invocation above exited 0 (implicit: loader contract). Spot-check a
#     malformed persona.yaml still exits 0.
H_DIR="$TMP_ROOT/h"; mkdir -p "$H_DIR/.rein/policy"
printf 'enabled: : :\n' > "$H_DIR/.rein/policy/persona.yaml"
( cd "$H_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief >/dev/null 2>&1 )
if [ "$?" = "0" ]; then
  ok "(h) malformed persona.yaml -> exit 0 (fail-open)"
else
  fail "(h) malformed persona.yaml should exit 0"
fi

echo "test-policy-loader-turn-brief: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
