#!/usr/bin/env bash
# test-rein-policy-loader-bootstrap-gate.sh - rein v1.1.1 Wave 2 Task 1.5.
#
# Verifies rein-policy-loader.py umbrella key resolution for `bootstrap-gate`:
#   Fixture A: umbrella bool false               -> both individuals disabled
#   Fixture B: umbrella mapping {enabled: false} -> both individuals disabled
#   Fixture C: individual bool only              -> only target disabled
#   Fixture D: individual mapping only           -> only target disabled
#   Fixture E: umbrella + individual conflict    -> individual wins, sibling
#                                                   inherits umbrella
#   Fixture F: empty yaml                        -> both default enabled
#
# Loader contract (Wave 2 Task 1.5):
#   1. individual key (bool or {enabled: ...}) takes precedence
#   2. umbrella key `bootstrap-gate` (bool or mapping) applies to both
#      `pre-edit-trail-bootstrap-gate` and `pre-tool-use-bash-bootstrap-gate`
#      when the individual entry is absent
#   3. otherwise default enabled
#
# CLI contract: exit 0 -> enabled, exit 1 -> disabled.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"

if [ ! -f "$LOADER" ]; then
  echo "FAIL: loader missing: $LOADER" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "/tmp/policy-bootstrap-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

ok() {
  echo "  ok: $1"
}

run_loader() {
  # Run loader from given workdir with given hook-name; return exit code.
  local workdir="$1"
  local hook="$2"
  set +e
  ( cd "$workdir" && python3 "$LOADER" "$hook" >/dev/null 2>&1 )
  local rc=$?
  set -e
  echo "$rc"
}

assert_disabled() {
  local workdir="$1" hook="$2" label="$3"
  local rc
  rc="$(run_loader "$workdir" "$hook")"
  [ "$rc" = "1" ] || fail "$label: expected disabled (exit 1) for $hook, got $rc"
}

assert_enabled() {
  local workdir="$1" hook="$2" label="$3"
  local rc
  rc="$(run_loader "$workdir" "$hook")"
  [ "$rc" = "0" ] || fail "$label: expected enabled (exit 0) for $hook, got $rc"
}

# -----------------------------------------------------------------------------
# Fixture A: umbrella bool false -> both individuals disabled
# -----------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein/policy"
cat >"$A_DIR/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate: false
YAML
assert_disabled "$A_DIR" "pre-edit-trail-bootstrap-gate"     "Fixture A (umbrella bool, pre-edit)"
assert_disabled "$A_DIR" "pre-tool-use-bash-bootstrap-gate"  "Fixture A (umbrella bool, pre-bash)"
ok "Fixture A: umbrella bool false -> both bootstrap-gate individuals disabled"

# -----------------------------------------------------------------------------
# Fixture B: umbrella mapping {enabled: false} -> both individuals disabled
# -----------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein/policy"
cat >"$B_DIR/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate:
  enabled: false
YAML
assert_disabled "$B_DIR" "pre-edit-trail-bootstrap-gate"     "Fixture B (umbrella mapping, pre-edit)"
assert_disabled "$B_DIR" "pre-tool-use-bash-bootstrap-gate"  "Fixture B (umbrella mapping, pre-bash)"
ok "Fixture B: umbrella mapping {enabled: false} -> both bootstrap-gate individuals disabled"

# -----------------------------------------------------------------------------
# Fixture C: individual bool only (pre-edit false)
#   -> pre-edit disabled, pre-bash defaults enabled
# -----------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR/.rein/policy"
cat >"$C_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-edit-trail-bootstrap-gate: false
YAML
assert_disabled "$C_DIR" "pre-edit-trail-bootstrap-gate"     "Fixture C (individual pre-edit)"
assert_enabled  "$C_DIR" "pre-tool-use-bash-bootstrap-gate"  "Fixture C (pre-bash default)"
ok "Fixture C: individual bool only -> only targeted hook disabled"

# -----------------------------------------------------------------------------
# Fixture D: individual mapping only (pre-bash {enabled: false})
#   -> pre-bash disabled, pre-edit defaults enabled
# -----------------------------------------------------------------------------
D_DIR="$TMP_ROOT/D"
mkdir -p "$D_DIR/.rein/policy"
cat >"$D_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-tool-use-bash-bootstrap-gate:
  enabled: false
YAML
assert_enabled  "$D_DIR" "pre-edit-trail-bootstrap-gate"     "Fixture D (pre-edit default)"
assert_disabled "$D_DIR" "pre-tool-use-bash-bootstrap-gate"  "Fixture D (individual pre-bash)"
ok "Fixture D: individual mapping only -> only targeted hook disabled"

# -----------------------------------------------------------------------------
# Fixture E: umbrella false + individual true
#   -> individual wins for pre-edit, pre-bash falls back to umbrella (disabled)
# -----------------------------------------------------------------------------
E_DIR="$TMP_ROOT/E"
mkdir -p "$E_DIR/.rein/policy"
cat >"$E_DIR/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate: false
pre-edit-trail-bootstrap-gate: true
YAML
assert_enabled  "$E_DIR" "pre-edit-trail-bootstrap-gate"     "Fixture E (individual overrides umbrella)"
assert_disabled "$E_DIR" "pre-tool-use-bash-bootstrap-gate"  "Fixture E (pre-bash inherits umbrella)"
ok "Fixture E: individual key overrides umbrella; sibling inherits umbrella"

# -----------------------------------------------------------------------------
# Fixture F: empty yaml -> both default enabled
# -----------------------------------------------------------------------------
F_DIR="$TMP_ROOT/F"
mkdir -p "$F_DIR/.rein/policy"
cat >"$F_DIR/.rein/policy/hooks.yaml" <<'YAML'
{}
YAML
assert_enabled "$F_DIR" "pre-edit-trail-bootstrap-gate"     "Fixture F (default pre-edit)"
assert_enabled "$F_DIR" "pre-tool-use-bash-bootstrap-gate"  "Fixture F (default pre-bash)"
ok "Fixture F: empty yaml -> both bootstrap-gate individuals default enabled"

echo "test-rein-policy-loader-bootstrap-gate: OK (6/6 fixtures)"
