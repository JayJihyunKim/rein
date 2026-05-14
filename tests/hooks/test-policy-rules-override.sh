#!/usr/bin/env bash
# tests/hooks/test-policy-rules-override.sh — Plugin-First Restructure Phase 2 Task 2.8
#
# Functional test for `.rein/policy/rules.yaml` per-rule REPLACE semantics
# in plugins/rein-core/hooks/session-start-rules.sh.
#
# Contract (per spec §5.4):
#   For each prompt-only rule (code-style / security / testing), if the user
#   defines `<rule>: { override: <body> }` in `.rein/policy/rules.yaml`, the
#   override BODY replaces the default rule body in `additionalContext`.
#   Replace, not append. Per-rule, not all-or-nothing — a rule with no
#   override entry still emits the default body alongside others that DO
#   have overrides.
#
# Fixtures:
#   1. partial override   — only code-style overridden; security + testing default
#   2. no yaml file       — Group C behavior preserved (3 default bodies)
#   3. all 3 overridden   — emits only the 3 override bodies (no defaults)
#   4. malformed yaml     — fail-open: 3 default bodies + stderr warning
#   + CLI mode tests for `python3 rein-policy-loader.py --rule-override <name>`
#
# Scope ID: policy-rules-yaml-overrides-rule-text-when-present
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-rules.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK is not executable" >&2; exit 1; }
[ -f "$LOADER" ] || { echo "FAIL: $LOADER missing" >&2; exit 1; }

# Default rule body fingerprints — substrings unique to each default file.
# Used to assert "default body present" or "default body REPLACED (absent)".
DEFAULT_FINGERPRINT_CODE_STYLE="# Code Style Rules"
DEFAULT_FINGERPRINT_SECURITY="# Security Rules"
DEFAULT_FINGERPRINT_TESTING="# Testing Rules"

TMP_ROOT="$(mktemp -d "/tmp/test-policy-rules-override-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# Run the hook from a given workdir (so the loader sees the right
# `.rein/policy/rules.yaml`). Capture stdout + stderr separately.
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
    sys.exit(0)  # empty stdout: no envelope; let caller decide
data = json.loads(raw)
hso = data.get("hookSpecificOutput") or {}
ctx = hso.get("additionalContext", "")
sys.stdout.write(ctx if isinstance(ctx, str) else "")
' "$stdout_file"
}

# -----------------------------------------------------------------------------
# Fixture 1: partial override (only code-style).
# Expect: code-style override body replaces default; security + testing
# defaults still present.
# -----------------------------------------------------------------------------
F1_DIR="$TMP_ROOT/F1"
mkdir -p "$F1_DIR/.rein/policy"
F1_OVERRIDE_BODY="Custom code style content for fixture 1"
cat >"$F1_DIR/.rein/policy/rules.yaml" <<YAML
code-style:
  override: |
    ${F1_OVERRIDE_BODY}
YAML
F1_OUT="$F1_DIR/stdout"; F1_ERR="$F1_DIR/stderr"
rc="$(run_hook "$F1_DIR" "$F1_OUT" "$F1_ERR")"
[ "$rc" = "0" ] || { cat "$F1_ERR" >&2; fail "F1: hook rc=$rc, expected 0"; }
F1_CTX="$(extract_ctx "$F1_OUT")"
[ -n "$F1_CTX" ] || fail "F1: additionalContext is empty"

case "$F1_CTX" in
  *"$F1_OVERRIDE_BODY"*) : ;;
  *) fail "F1: override body absent from additionalContext" ;;
esac

# Default code-style fingerprint must NOT be present (replace, not append).
case "$F1_CTX" in
  *"$DEFAULT_FINGERPRINT_CODE_STYLE"*)
    fail "F1: default code-style.md fingerprint still present after override (replace semantics violated)"
    ;;
esac

# Default security + testing must still be there (no override for them).
case "$F1_CTX" in
  *"$DEFAULT_FINGERPRINT_SECURITY"*) : ;;
  *) fail "F1: default security.md fingerprint missing (no override → default expected)" ;;
esac
case "$F1_CTX" in
  *"$DEFAULT_FINGERPRINT_TESTING"*) : ;;
  *) fail "F1: default testing.md fingerprint missing (no override → default expected)" ;;
esac
ok "Fixture 1: partial override replaces only code-style; security + testing defaults preserved"

# -----------------------------------------------------------------------------
# Fixture 2: no rules.yaml at all → Group C behavior preserved (3 defaults).
# -----------------------------------------------------------------------------
F2_DIR="$TMP_ROOT/F2"
mkdir -p "$F2_DIR"
[ ! -e "$F2_DIR/.rein/policy/rules.yaml" ] || fail "F2 setup: yaml should not exist"
F2_OUT="$F2_DIR/stdout"; F2_ERR="$F2_DIR/stderr"
rc="$(run_hook "$F2_DIR" "$F2_OUT" "$F2_ERR")"
[ "$rc" = "0" ] || { cat "$F2_ERR" >&2; fail "F2: hook rc=$rc, expected 0"; }
F2_CTX="$(extract_ctx "$F2_OUT")"
[ -n "$F2_CTX" ] || fail "F2: additionalContext is empty (Group C envelope expected)"
for fp in "$DEFAULT_FINGERPRINT_CODE_STYLE" "$DEFAULT_FINGERPRINT_SECURITY" "$DEFAULT_FINGERPRINT_TESTING"; do
  case "$F2_CTX" in
    *"$fp"*) : ;;
    *) fail "F2: default fingerprint missing: $fp" ;;
  esac
done
ok "Fixture 2: no yaml → 3 default bodies (Group C preserved)"

# -----------------------------------------------------------------------------
# Fixture 3: all 3 overridden → only override bodies, no defaults.
# -----------------------------------------------------------------------------
F3_DIR="$TMP_ROOT/F3"
mkdir -p "$F3_DIR/.rein/policy"
cat >"$F3_DIR/.rein/policy/rules.yaml" <<'YAML'
code-style:
  override: "Override 1"
security:
  override: "Override 2"
testing:
  override: "Override 3"
YAML
F3_OUT="$F3_DIR/stdout"; F3_ERR="$F3_DIR/stderr"
rc="$(run_hook "$F3_DIR" "$F3_OUT" "$F3_ERR")"
[ "$rc" = "0" ] || { cat "$F3_ERR" >&2; fail "F3: hook rc=$rc, expected 0"; }
F3_CTX="$(extract_ctx "$F3_OUT")"
[ -n "$F3_CTX" ] || fail "F3: additionalContext is empty"
for needle in "Override 1" "Override 2" "Override 3"; do
  case "$F3_CTX" in
    *"$needle"*) : ;;
    *) fail "F3: override body missing: $needle" ;;
  esac
done
# None of the default fingerprints may appear.
for fp in "$DEFAULT_FINGERPRINT_CODE_STYLE" "$DEFAULT_FINGERPRINT_SECURITY" "$DEFAULT_FINGERPRINT_TESTING"; do
  case "$F3_CTX" in
    *"$fp"*) fail "F3: default fingerprint leaked through override: $fp" ;;
  esac
done
ok "Fixture 3: all 3 overridden → no default leakage"

# -----------------------------------------------------------------------------
# Fixture 4: malformed yaml → fail-open (3 defaults) + stderr warning.
# -----------------------------------------------------------------------------
F4_DIR="$TMP_ROOT/F4"
mkdir -p "$F4_DIR/.rein/policy"
cat >"$F4_DIR/.rein/policy/rules.yaml" <<'YAML'
:::
not yaml: at all: extra: colons:
  : invalid
YAML
F4_OUT="$F4_DIR/stdout"; F4_ERR="$F4_DIR/stderr"
rc="$(run_hook "$F4_DIR" "$F4_OUT" "$F4_ERR")"
[ "$rc" = "0" ] || { cat "$F4_ERR" >&2; fail "F4: hook rc=$rc, expected 0 (fail-open)"; }
F4_CTX="$(extract_ctx "$F4_OUT")"
[ -n "$F4_CTX" ] || fail "F4: additionalContext is empty (defaults expected on fail-open)"
for fp in "$DEFAULT_FINGERPRINT_CODE_STYLE" "$DEFAULT_FINGERPRINT_SECURITY" "$DEFAULT_FINGERPRINT_TESTING"; do
  case "$F4_CTX" in
    *"$fp"*) : ;;
    *) fail "F4: default fingerprint missing on fail-open: $fp" ;;
  esac
done
if ! grep -q -i "warning" "$F4_ERR"; then
  echo "  loader stderr captured:" >&2
  cat "$F4_ERR" >&2
  fail "F4: expected 'warning' in stderr on malformed yaml"
fi
ok "Fixture 4: malformed yaml → 3 defaults + stderr warning (fail-open)"

# -----------------------------------------------------------------------------
# CLI mode: --rule-override <name>
# -----------------------------------------------------------------------------
# CLI-A: no yaml present → empty stdout, exit 0.
CLI_A_DIR="$TMP_ROOT/CLI_A"
mkdir -p "$CLI_A_DIR"
CLI_A_OUT="$CLI_A_DIR/stdout"
set +e
( cd "$CLI_A_DIR" && python3 "$LOADER" --rule-override code-style >"$CLI_A_OUT" 2>/dev/null )
rc=$?
set -e
[ "$rc" = "0" ] || fail "CLI-A: expected exit 0, got $rc"
[ ! -s "$CLI_A_OUT" ] || fail "CLI-A: expected empty stdout, got $(cat "$CLI_A_OUT")"
ok "CLI-A: --rule-override (no yaml) → empty stdout, exit 0"

# CLI-B: yaml present with override → prints body, exit 0.
CLI_B_DIR="$TMP_ROOT/CLI_B"
mkdir -p "$CLI_B_DIR/.rein/policy"
cat >"$CLI_B_DIR/.rein/policy/rules.yaml" <<'YAML'
code-style:
  override: "CLI body sentinel"
YAML
CLI_B_OUT="$CLI_B_DIR/stdout"
set +e
( cd "$CLI_B_DIR" && python3 "$LOADER" --rule-override code-style >"$CLI_B_OUT" 2>/dev/null )
rc=$?
set -e
[ "$rc" = "0" ] || fail "CLI-B: expected exit 0, got $rc"
grep -q "CLI body sentinel" "$CLI_B_OUT" || {
  echo "  stdout: $(cat "$CLI_B_OUT")" >&2
  fail "CLI-B: expected override body in stdout"
}
ok "CLI-B: --rule-override (yaml present) → prints override body"

# CLI-C: yaml present, no override for queried rule → empty stdout, exit 0.
CLI_C_OUT="$CLI_B_DIR/stdout-c"
set +e
( cd "$CLI_B_DIR" && python3 "$LOADER" --rule-override security >"$CLI_C_OUT" 2>/dev/null )
rc=$?
set -e
[ "$rc" = "0" ] || fail "CLI-C: expected exit 0, got $rc"
[ ! -s "$CLI_C_OUT" ] || fail "CLI-C: expected empty stdout for absent rule, got $(cat "$CLI_C_OUT")"
ok "CLI-C: --rule-override for absent rule → empty stdout, exit 0"

# CLI-D: missing rule-name argv → exit 0 (fail-open), empty stdout.
CLI_D_OUT="$CLI_B_DIR/stdout-d"
set +e
( cd "$CLI_B_DIR" && python3 "$LOADER" --rule-override >"$CLI_D_OUT" 2>/dev/null )
rc=$?
set -e
[ "$rc" = "0" ] || fail "CLI-D: expected exit 0 (fail-open on missing arg), got $rc"
[ ! -s "$CLI_D_OUT" ] || fail "CLI-D: expected empty stdout, got $(cat "$CLI_D_OUT")"
ok "CLI-D: --rule-override with no arg → exit 0 + empty stdout (fail-open)"

echo "test-policy-rules-override: OK (4 hook fixtures + 4 CLI fixtures)"
