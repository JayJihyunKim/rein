#!/usr/bin/env bash
# Verify neutral persona template in rein-bootstrap-project.py (Task 5.1).
#
# Contracts under test (plan 2026-07-22-persona-user-selection Task 5.1):
#   (a) Freshly bootstrapped .rein/policy/persona.yaml contains a non-comment
#       `enabled: false` line and NO non-comment `enabled: true` line.
#   (b) Template comments mention both built-in presets (boss-ace, jennie)
#       and show how to enable (a `preset:` example line).
#   (c) Existing persona.yaml is preserved on re-run (write_text_if_missing).
#   (d) End-to-end neutral start: with the freshly generated persona.yaml,
#       `rein-policy-loader.py --persona` prints empty stdout.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"
LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"

[ -f "$BOOTSTRAP" ] || { echo "FAIL: $BOOTSTRAP missing" >&2; exit 1; }
[ -f "$LOADER" ] || { echo "FAIL: $LOADER missing" >&2; exit 1; }

A_DIR=$(mktemp -d "/tmp/persona-neutral-A-XXXXXX")
C_DIR=$(mktemp -d "/tmp/persona-neutral-C-XXXXXX")
trap 'rm -rf "$A_DIR" "$C_DIR" 2>/dev/null || true' EXIT

# --- Fixture A: fresh bootstrap in a temp git repo ----------------------------
( cd "$A_DIR" && git init -q )
A_OUT=$(mktemp)
A_ERR=$(mktemp)
set +e
python3 "$BOOTSTRAP" --project-dir "$A_DIR" >"$A_OUT" 2>"$A_ERR"
A_RC=$?
set -e

if [ "$A_RC" != "0" ]; then
  echo "FAIL (A): bootstrap expected exit 0, got $A_RC" >&2
  echo "--- stdout ---" >&2; cat "$A_OUT" >&2
  echo "--- stderr ---" >&2; cat "$A_ERR" >&2
  exit 1
fi
rm -f "$A_OUT" "$A_ERR"

PERSONA_YAML="$A_DIR/.rein/policy/persona.yaml"
[ -f "$PERSONA_YAML" ] || {
  echo "FAIL (A): $PERSONA_YAML not created by bootstrap" >&2; exit 1;
}

# (a) non-comment `enabled: false` present; non-comment `enabled: true` absent.
grep -q '^enabled: false' "$PERSONA_YAML" || {
  echo "FAIL (a): persona.yaml lacks non-comment 'enabled: false' line" >&2
  cat "$PERSONA_YAML" >&2
  exit 1
}
if grep -q '^enabled: true' "$PERSONA_YAML"; then
  echo "FAIL (a): persona.yaml has non-comment 'enabled: true' line" >&2
  cat "$PERSONA_YAML" >&2
  exit 1
fi

# (b) comments mention both built-in presets and a preset: enable example.
grep -q 'boss-ace' "$PERSONA_YAML" || {
  echo "FAIL (b): persona.yaml comments do not mention boss-ace" >&2
  cat "$PERSONA_YAML" >&2
  exit 1
}
grep -q 'jennie' "$PERSONA_YAML" || {
  echo "FAIL (b): persona.yaml comments do not mention jennie" >&2
  cat "$PERSONA_YAML" >&2
  exit 1
}
grep -q 'preset:' "$PERSONA_YAML" || {
  echo "FAIL (b): persona.yaml comments lack a 'preset:' enable example" >&2
  cat "$PERSONA_YAML" >&2
  exit 1
}

# (d) end-to-end neutral start: loader --persona from the sandbox = empty stdout.
D_OUT=$(cd "$A_DIR" && python3 "$LOADER" --persona 2>/dev/null)
D_RC=$?
if [ "$D_RC" != "0" ]; then
  echo "FAIL (d): loader --persona expected exit 0, got $D_RC" >&2
  exit 1
fi
if [ -n "$D_OUT" ]; then
  echo "FAIL (d): loader --persona expected empty stdout for fresh bootstrap, got: $D_OUT" >&2
  exit 1
fi

# --- Fixture C: existing persona.yaml preserved on re-run ---------------------
( cd "$C_DIR" && git init -q )
mkdir -p "$C_DIR/.rein/policy"
printf 'enabled: true\npreset: boss-ace\n' > "$C_DIR/.rein/policy/persona.yaml"
C_BEFORE=$(cat "$C_DIR/.rein/policy/persona.yaml")

set +e
python3 "$BOOTSTRAP" --project-dir "$C_DIR" >/dev/null 2>&1
C_RC=$?
set -e
if [ "$C_RC" != "0" ]; then
  echo "FAIL (c): bootstrap re-run expected exit 0, got $C_RC" >&2
  exit 1
fi

C_AFTER=$(cat "$C_DIR/.rein/policy/persona.yaml")
if [ "$C_BEFORE" != "$C_AFTER" ]; then
  echo "FAIL (c): existing persona.yaml was modified by bootstrap re-run" >&2
  echo "--- before ---" >&2; printf '%s\n' "$C_BEFORE" >&2
  echo "--- after ---" >&2; printf '%s\n' "$C_AFTER" >&2
  exit 1
fi

echo "test-bootstrap-persona-neutral: OK (a neutral-default + b preset-comments + c preserve-existing + d loader-empty)"
