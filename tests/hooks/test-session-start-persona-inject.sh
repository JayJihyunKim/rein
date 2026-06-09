#!/usr/bin/env bash
# tests/hooks/test-session-start-persona-inject.sh — Persona preset Phase 2 Task 2.2
#
# Functional regression test for the persona injection block in
# plugins/rein-core/hooks/session-start-rules.sh (PP-13).
#
# The hook, after concatenating the 6 default rule bodies, probes the loader
# (`python3 rein-policy-loader.py --persona`). When persona is enabled the
# loader prints the VALIDATED active preset name; the hook then appends
# `${CLAUDE_PLUGIN_ROOT}/rules/persona/<preset>.md` to additionalContext.
# Injection happens AFTER response-tone ("tone applied last") — but that is
# ORDER ONLY; precedence authority lives in the preset body text (PP-10).
#
# Assertions (all drive the real hook via stdout envelope -> additionalContext):
#   (a) enabled:true, preset:boss-ace -> boss-ace.md body present.
#   (b) enabled:false               -> boss-ace.md body ABSENT (opt-out).
#   (c) unknown preset (mentor)      -> downgraded to default boss-ace, body
#                                       present (PP-3 membership fail-safe).
#   (d) persona body sits AFTER response-tone body (response-tone marker index
#       < persona marker index) (PP-9 order).
#   (e) persona.yaml absent          -> default ON, boss-ace.md body present
#                                       (PP-2 fail-open default-ON).
#
# Scope ID: PP-13
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-rules.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"
BOSS_ACE="$PLUGIN_ROOT/rules/persona/boss-ace.md"

[ -f "$HOOK" ]     || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ]     || { echo "FAIL: $HOOK is not executable" >&2; exit 1; }
[ -f "$LOADER" ]   || { echo "FAIL: $LOADER missing" >&2; exit 1; }
[ -f "$BOSS_ACE" ] || { echo "FAIL: $BOSS_ACE missing (Wave 1 bossace-rule)" >&2; exit 1; }

# Fingerprints — substrings unique to each body file. Kept literal so a body
# rewrite that drops these markers fails loudly (and is fixed deliberately).
PERSONA_FINGERPRINT="# Persona: boss-ace"   # boss-ace.md heading
TONE_FINGERPRINT="# Response Tone"          # response-tone.md heading

TMP_ROOT="$(mktemp -d "/tmp/test-session-start-persona-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# Run the hook from a given workdir so the loader reads that workdir's
# .rein/policy/persona.yaml. Capture stdout + stderr separately. Echo rc.
run_hook() {
  local workdir="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  set +e
  ( cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" \
      </dev/null >"$stdout_file" 2>"$stderr_file" )
  local rc=$?
  set -e
  echo "$rc"
}

# Extract additionalContext (string) from envelope JSON.
extract_ctx() {
  local stdout_file="$1"
  python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    raw = fh.read()
if not raw.strip():
    sys.exit(0)  # empty stdout: no envelope
data = json.loads(raw)
hso = data.get("hookSpecificOutput") or {}
ctx = hso.get("additionalContext", "")
sys.stdout.write(ctx if isinstance(ctx, str) else "")
' "$stdout_file"
}

# -----------------------------------------------------------------------------
# (a) enabled:true, preset:boss-ace -> boss-ace body present.
# -----------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein/policy"
cat >"$A_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: true
preset: boss-ace
YAML
A_OUT="$A_DIR/stdout"; A_ERR="$A_DIR/stderr"
rc="$(run_hook "$A_DIR" "$A_OUT" "$A_ERR")"
[ "$rc" = "0" ] || { cat "$A_ERR" >&2; fail "(a): hook rc=$rc, expected 0"; }
A_CTX="$(extract_ctx "$A_OUT")"
[ -n "$A_CTX" ] || fail "(a): additionalContext is empty"
case "$A_CTX" in
  *"$PERSONA_FINGERPRINT"*) : ;;
  *) fail "(a): boss-ace body absent when enabled:true preset:boss-ace" ;;
esac
ok "(a) enabled:true preset:boss-ace -> boss-ace body injected"

# -----------------------------------------------------------------------------
# (b) enabled:false -> boss-ace body ABSENT (opt-out).
# -----------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein/policy"
cat >"$B_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: false
preset: boss-ace
YAML
B_OUT="$B_DIR/stdout"; B_ERR="$B_DIR/stderr"
rc="$(run_hook "$B_DIR" "$B_OUT" "$B_ERR")"
[ "$rc" = "0" ] || { cat "$B_ERR" >&2; fail "(b): hook rc=$rc, expected 0"; }
B_CTX="$(extract_ctx "$B_OUT")"
[ -n "$B_CTX" ] || fail "(b): additionalContext is empty (6 default rules expected)"
case "$B_CTX" in
  *"$PERSONA_FINGERPRINT"*)
    fail "(b): boss-ace body present despite enabled:false (opt-out broken)" ;;
esac
# Sanity: the 6 default rules are still emitted (only persona is suppressed).
case "$B_CTX" in
  *"$TONE_FINGERPRINT"*) : ;;
  *) fail "(b): response-tone body missing — opt-out suppressed too much" ;;
esac
ok "(b) enabled:false -> boss-ace body suppressed, default rules intact"

# -----------------------------------------------------------------------------
# (c) unknown preset (mentor) -> downgraded to default boss-ace (PP-3).
# -----------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR/.rein/policy"
cat >"$C_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: true
preset: mentor
YAML
C_OUT="$C_DIR/stdout"; C_ERR="$C_DIR/stderr"
rc="$(run_hook "$C_DIR" "$C_OUT" "$C_ERR")"
[ "$rc" = "0" ] || { cat "$C_ERR" >&2; fail "(c): hook rc=$rc, expected 0"; }
C_CTX="$(extract_ctx "$C_OUT")"
[ -n "$C_CTX" ] || fail "(c): additionalContext is empty"
case "$C_CTX" in
  *"$PERSONA_FINGERPRINT"*) : ;;
  *) fail "(c): unknown preset 'mentor' not downgraded to boss-ace (PP-3 fail-safe broken)" ;;
esac
ok "(c) unknown preset 'mentor' -> downgraded to boss-ace, body injected"

# -----------------------------------------------------------------------------
# (d) persona body sits AFTER response-tone body (PP-9 order).
#     Reuse the enabled:true context from (a).
# -----------------------------------------------------------------------------
python3 - "$A_OUT" "$TONE_FINGERPRINT" "$PERSONA_FINGERPRINT" <<'PY' || fail "(d): persona body not positioned after response-tone"
import json, sys
out_path, tone_fp, persona_fp = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out_path, "r", encoding="utf-8") as fh:
    ctx = (json.load(fh).get("hookSpecificOutput") or {}).get("additionalContext", "")
tone_idx = ctx.find(tone_fp)
persona_idx = ctx.find(persona_fp)
if tone_idx < 0:
    print(f"FAIL (d): response-tone marker not found in additionalContext", file=sys.stderr)
    sys.exit(1)
if persona_idx < 0:
    print(f"FAIL (d): persona marker not found in additionalContext", file=sys.stderr)
    sys.exit(1)
if not (tone_idx < persona_idx):
    print(f"FAIL (d): persona marker (idx={persona_idx}) is not AFTER response-tone (idx={tone_idx})", file=sys.stderr)
    sys.exit(1)
PY
ok "(d) persona body positioned after response-tone (order preserved)"

# -----------------------------------------------------------------------------
# (e) persona.yaml absent -> default ON, boss-ace body present (PP-2).
# -----------------------------------------------------------------------------
E_DIR="$TMP_ROOT/E"
mkdir -p "$E_DIR"
[ ! -e "$E_DIR/.rein/policy/persona.yaml" ] || fail "(e) setup: persona.yaml should not exist"
E_OUT="$E_DIR/stdout"; E_ERR="$E_DIR/stderr"
rc="$(run_hook "$E_DIR" "$E_OUT" "$E_ERR")"
[ "$rc" = "0" ] || { cat "$E_ERR" >&2; fail "(e): hook rc=$rc, expected 0"; }
E_CTX="$(extract_ctx "$E_OUT")"
[ -n "$E_CTX" ] || fail "(e): additionalContext is empty"
case "$E_CTX" in
  *"$PERSONA_FINGERPRINT"*) : ;;
  *) fail "(e): boss-ace body absent when persona.yaml missing (default-ON broken)" ;;
esac
ok "(e) persona.yaml absent -> default ON, boss-ace body injected"

echo "test-session-start-persona-inject: OK (5 asserts: enabled/opt-out/downgrade/order/default-ON)"
