#!/usr/bin/env bash
# tests/hooks/test-session-start-persona-inject.sh — persona isolation (PT-3/PT-11)
#
# Functional regression test for the DEDICATED persona SessionStart hook
# plugins/rein-core/hooks/session-start-persona.sh.
#
# Persona used to be appended to session-start-rules.sh's single envelope and
# got truncated when that envelope overflowed the per-hook cap. PT-3 moved it
# into its own hook with its own envelope + size budget. This hook probes the
# loader (`python3 rein-policy-loader.py --persona`): when persona is enabled it
# emits a SessionStart envelope carrying ${CLAUDE_PLUGIN_ROOT}/rules/persona/
# <preset>.md; when disabled it emits nothing.
#
# Assertions (drive the real persona hook via stdout envelope):
#   (a) enabled:true, preset:boss-ace -> own envelope with boss-ace.md body.
#   (b) enabled:false               -> EMPTY stdout (no envelope; opt-out).
#   (c) unknown preset (mentor)      -> downgraded to default boss-ace, body
#                                       present (PP-3 membership fail-safe).
#   (d) hooks.json registers session-start-persona.sh AFTER session-start-
#       rules.sh ("tone applied last" ordering — replaces the old same-envelope
#       order check now that persona is a separate hook).
#   (e) persona.yaml absent          -> default ON, boss-ace.md body present
#                                       (fail-open default-ON).
#
# Scope ID: PT-11 (was PP-13)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-persona.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"
BOSS_ACE="$PLUGIN_ROOT/rules/persona/boss-ace.md"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$HOOK" ]     || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ]     || { echo "FAIL: $HOOK is not executable" >&2; exit 1; }
[ -f "$LOADER" ]   || { echo "FAIL: $LOADER missing" >&2; exit 1; }
[ -f "$BOSS_ACE" ] || { echo "FAIL: $BOSS_ACE missing" >&2; exit 1; }

# Fingerprint — substring unique to boss-ace.md. Kept literal so a body rewrite
# that drops it fails loudly (and is fixed deliberately).
PERSONA_FINGERPRINT="# Persona: boss-ace"   # boss-ace.md heading

TMP_ROOT="$(mktemp -d "/tmp/test-session-start-persona-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# Run the persona hook from a given workdir so the loader reads that workdir's
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

# Extract additionalContext (string) from envelope JSON; empty when no envelope.
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
# (a) enabled:true, preset:boss-ace -> own envelope with boss-ace body present.
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
[ -n "$A_CTX" ] || fail "(a): additionalContext is empty (persona envelope expected)"
case "$A_CTX" in
  *"$PERSONA_FINGERPRINT"*) : ;;
  *) fail "(a): boss-ace body absent when enabled:true preset:boss-ace" ;;
esac
ok "(a) enabled:true preset:boss-ace -> own envelope with boss-ace body"

# -----------------------------------------------------------------------------
# (b) enabled:false -> EMPTY stdout (no envelope; opt-out).
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
[ -s "$B_OUT" ] && fail "(b): persona hook emitted output despite enabled:false (opt-out broken)"
ok "(b) enabled:false -> empty stdout (opt-out)"

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
# (d) hooks.json registers persona hook AFTER rules hook ("tone applied last").
#     Replaces the old same-envelope order check now that persona is its own
#     SessionStart hook (PT-5).
# -----------------------------------------------------------------------------
python3 - "$HOOKS_JSON" <<'PY' || fail "(d): persona hook not registered after rules hook in hooks.json"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    hooks = json.load(fh)
ss = [h["command"].split("/")[-1]
      for grp in hooks["hooks"]["SessionStart"] for h in grp["hooks"]]
if "session-start-persona.sh" not in ss:
    print(f"FAIL (d): persona hook not in SessionStart: {ss}", file=sys.stderr); sys.exit(1)
if "session-start-rules.sh" not in ss:
    print(f"FAIL (d): rules hook not in SessionStart: {ss}", file=sys.stderr); sys.exit(1)
if not (ss.index("session-start-rules.sh") < ss.index("session-start-persona.sh")):
    print(f"FAIL (d): persona not after rules: {ss}", file=sys.stderr); sys.exit(1)
PY
ok "(d) hooks.json: persona hook registered after rules hook"

# -----------------------------------------------------------------------------
# (e) persona.yaml absent -> default ON, boss-ace body present (fail-open).
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

echo "test-session-start-persona-inject: OK (5 asserts: enabled/opt-out/downgrade/hook-order/default-ON)"
