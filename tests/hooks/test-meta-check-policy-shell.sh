#!/usr/bin/env bash
# tests/hooks/test-meta-check-policy-shell.sh — G3-perf-NFR Phase 3 Task 3.1
#
# Unit test for plugins/rein-core/hooks/lib/meta-check-policy.sh.
# Source the helper and call meta_check_policy_shell from inside an isolated
# tmp project. Verify supported schema + fail-open paths + intentional
# deviations per PERF-FAIL-OPEN-PARITY.
#
# Scope IDs: PERF-SHELL-POLICY-LOADER PERF-FAIL-OPEN-PARITY
#            PERF-YAML-SUBSET-CONTRACT
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/meta-check-policy.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

FAILED=0

run_fixture() {
  local name="$1" yaml="$2" expected="$3"
  local proj
  proj=$(mktemp -d "/tmp/mc-policy-XXXXXX")
  mkdir -p "$proj/.rein/policy"
  if [ -n "$yaml" ]; then
    printf '%s' "$yaml" > "$proj/.rein/policy/meta-check.yaml"
  fi
  local got
  got=$(cd "$proj" && bash -c ". '$LIB' && meta_check_policy_shell" 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    echo "OK [$name]"
  else
    echo "FAIL [$name]: expected '$expected' got '$got'" >&2
    FAILED=$((FAILED+1))
  fi
  rm -rf "$proj"
}

run_chmod_fixture() {
  # Special case: file with 000 permissions
  local name="$1" yaml="$2" expected="$3"
  local proj
  proj=$(mktemp -d "/tmp/mc-policy-XXXXXX")
  mkdir -p "$proj/.rein/policy"
  printf '%s' "$yaml" > "$proj/.rein/policy/meta-check.yaml"
  chmod 000 "$proj/.rein/policy/meta-check.yaml"
  local got
  got=$(cd "$proj" && bash -c ". '$LIB' && meta_check_policy_shell" 2>/dev/null)
  # Cleanup chmod so rm works
  chmod 644 "$proj/.rein/policy/meta-check.yaml" 2>/dev/null
  if [ "$got" = "$expected" ]; then
    echo "OK [$name]"
  else
    echo "FAIL [$name]: expected '$expected' got '$got'" >&2
    FAILED=$((FAILED+1))
  fi
  rm -rf "$proj"
}

# ---- 20 fixtures (PERF-FAIL-OPEN-PARITY + PERF-YAML-SUBSET-CONTRACT) ----

# 1. file absent
proj=$(mktemp -d "/tmp/mc-policy-XXXXXX")
got=$(cd "$proj" && bash -c ". '$LIB' && meta_check_policy_shell" 2>/dev/null)
if [ "$got" = "auto" ]; then echo "OK [F1-file-absent]"; else echo "FAIL [F1-file-absent]: got '$got'" >&2; FAILED=$((FAILED+1)); fi
rm -rf "$proj"

# 2. file unreadable (chmod 000)
run_chmod_fixture "F2-file-unreadable-chmod-000" "enabled: true" "auto"

# 3-5. happy path supported values
run_fixture "F3-enabled-true" "enabled: true" "true"
run_fixture "F4-enabled-false" "enabled: false" "false"
run_fixture "F5-enabled-auto" "enabled: auto" "auto"

# 6. enabled value empty
run_fixture "F6-enabled-empty-value" "enabled:" "auto"

# 7. unknown string value
run_fixture "F7-enabled-maybe" "enabled: maybe" "auto"

# 8. trailing comment
run_fixture "F8-trailing-comment" "enabled: true   # comment" "true"

# 9. case-insensitive
run_fixture "F9-enabled-TRUE-uppercase" "enabled: TRUE" "true"

# 10. leading-whitespace `enabled:` -> auto (treated as potential nested per PERF-FAIL-OPEN-PARITY)
# Note: trailing whitespace + multi-spaces after colon are still tolerated (see F8).
# Strict top-level no-leading-space matches Python schema intent (avoid nested mapping FP).
run_fixture "F10-leading-whitespace-rejected" "  enabled:    false   " "auto"

# 11. quoted string -> auto (shell unsupported)
run_fixture "F11-quoted-string-true" 'enabled: "true"' "auto"

# 12-15. YAML bool aliases -> auto (shell unsupported, intentional deviation vs python)
run_fixture "F12-yes-deviation" "enabled: yes" "auto"
run_fixture "F13-no-deviation" "enabled: no" "auto"
run_fixture "F14-on-deviation" "enabled: on" "auto"
run_fixture "F15-off-deviation" "enabled: off" "auto"

# 16. nested mapping (top-level enabled absent)
run_fixture "F16-nested-mapping" "meta:
  enabled: true" "auto"

# 17. enabled key absent (other top-level keys)
run_fixture "F17-version-only" "version: 1" "auto"

# 18. malformed yaml (no colon)
run_fixture "F18-malformed-no-colon" "random text without colon" "auto"

# 19. anchor/alias -> auto (shell awk takes literal "&x true" which won't match supported subset)
run_fixture "F19-anchor-deviation" "enabled: &x true" "auto"

# 20. multi-doc YAML — shell awk ignores `---` and matches first `enabled:` line
# Documented intentional deviation vs Python (Python parse fails -> auto)
run_fixture "F20-multi-doc-shell-true" "---
enabled: true
---" "true"

# ---- Result ----
if [ "$FAILED" -gt 0 ]; then
  echo "test-meta-check-policy-shell: FAIL ($FAILED assertion(s))" >&2
  exit 1
fi
echo "test-meta-check-policy-shell: OK (20 fixtures covered)"
