#!/usr/bin/env bash
# tests/hooks/test-meta-check-policy-parity.sh — G3-perf-NFR Phase 3 Task 3.6
#
# Shell-vs-Python parity test (PERF-PARITY-FIXTURE). Each fixture sets up
# `.rein/policy/meta-check.yaml` in an isolated tmp project, then calls
# (a) shell helper `meta_check_policy_shell` and
# (b) python rein-policy-loader.py --meta-check-policy
# and asserts both against the explicit expected matrix.
#
# Intentional deviations (PERF-YAML-SUBSET-CONTRACT) are encoded as separate
# expected_shell / expected_python columns. Regression alarms when either side
# changes unexpectedly.
#
# Scope IDs: PERF-PARITY-FIXTURE PERF-YAML-SUBSET-CONTRACT
#            PERF-PYTHON-API-BACKCOMPAT
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/meta-check-policy.sh"
PY="$REPO_ROOT/plugins/rein-core/scripts/rein-policy-loader.py"

[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }
[ -f "$PY" ] || { echo "FAIL: $PY not found" >&2; exit 1; }

FAILED=0

run_pair() {
  local name="$1" yaml="$2" expected_shell="$3" expected_python="$4"
  local proj
  proj=$(mktemp -d "/tmp/mc-parity-XXXXXX")
  mkdir -p "$proj/.rein/policy"
  if [ -n "$yaml" ]; then
    printf '%s' "$yaml" > "$proj/.rein/policy/meta-check.yaml"
  fi
  local shell_got py_got
  shell_got=$(cd "$proj" && bash -c ". '$LIB' && meta_check_policy_shell" 2>/dev/null)
  py_got=$(cd "$proj" && python3 "$PY" --meta-check-policy 2>/dev/null)
  local ok=1
  if [ "$shell_got" != "$expected_shell" ]; then
    echo "FAIL [$name-shell]: expected '$expected_shell' got '$shell_got'" >&2
    FAILED=$((FAILED+1))
    ok=0
  fi
  if [ "$py_got" != "$expected_python" ]; then
    echo "FAIL [$name-python]: expected '$expected_python' got '$py_got'" >&2
    FAILED=$((FAILED+1))
    ok=0
  fi
  if [ "$ok" = "1" ]; then
    if [ "$shell_got" = "$py_got" ]; then
      echo "OK [$name] (parity: both '$shell_got')"
    else
      echo "OK [$name] (intentional deviation: shell='$shell_got' python='$py_got')"
    fi
  fi
  rm -rf "$proj"
}

# ---- 18 parity fixtures (PERF-PARITY-FIXTURE) ----

# 1. file absent — both auto
proj=$(mktemp -d "/tmp/mc-parity-XXXXXX")
shell_got=$(cd "$proj" && bash -c ". '$LIB' && meta_check_policy_shell" 2>/dev/null)
py_got=$(cd "$proj" && python3 "$PY" --meta-check-policy 2>/dev/null)
if [ "$shell_got" = "auto" ] && [ "$py_got" = "auto" ]; then
  echo "OK [F1-file-absent] (parity: both 'auto')"
else
  echo "FAIL [F1-file-absent]: shell='$shell_got' python='$py_got'" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$proj"

# 2-4. supported subset happy path
run_pair "F2-enabled-true"  "enabled: true"  "true"  "true"
run_pair "F3-enabled-false" "enabled: false" "false" "false"
run_pair "F4-enabled-auto"  "enabled: auto"  "auto"  "auto"

# 5. enabled empty
run_pair "F5-enabled-empty" "enabled:" "auto" "auto"

# 6. unknown value
run_pair "F6-enabled-maybe" "enabled: maybe" "auto" "auto"

# 7. trailing comment
run_pair "F7-trailing-comment" "enabled: true   # comment" "true" "true"

# 8. case-insensitive — both true (shell awk tolower, Python PyYAML bool True)
run_pair "F8-enabled-TRUE" "enabled: TRUE" "true" "true"

# 9. quoted string — intentional deviation
# shell awk takes literal `"true"` which won't match supported subset -> auto
# Python PyYAML parses quoted "true" as string then lowercase matches -> true
run_pair "F9-quoted-true-DEVIATION" 'enabled: "true"' "auto" "true"

# 10-13. YAML bool aliases — all intentional deviations
run_pair "F10-yes-DEVIATION" "enabled: yes" "auto" "true"
run_pair "F11-no-DEVIATION"  "enabled: no"  "auto" "false"
run_pair "F12-on-DEVIATION"  "enabled: on"  "auto" "true"
run_pair "F13-off-DEVIATION" "enabled: off" "auto" "false"

# 14. nested mapping — both auto (top-level `enabled:` absent)
run_pair "F14-nested-mapping" "meta:
  enabled: true" "auto" "auto"

# 15. enabled key absent (other top-level keys)
run_pair "F15-version-only" "version: 1" "auto" "auto"

# 16. malformed yaml (no colon)
run_pair "F16-malformed-no-colon" "random text without colon" "auto" "auto"

# 17. anchor/alias — intentional deviation
# shell awk takes literal `&x true` which won't match supported subset -> auto
# Python PyYAML resolves anchor -> bool True -> true
run_pair "F17-anchor-DEVIATION" "enabled: &x true" "auto" "true"

# 18. multi-doc YAML — intentional deviation
# shell awk ignores `---` separator and matches first `enabled:` line -> true
# Python PyYAML safe_load fails on multi-doc -> auto
run_pair "F18-multi-doc-DEVIATION" "---
enabled: true
---" "true" "auto"

# ---- Result ----
if [ "$FAILED" -gt 0 ]; then
  echo "test-meta-check-policy-parity: FAIL ($FAILED assertion(s))" >&2
  exit 1
fi
echo "test-meta-check-policy-parity: OK (18 fixtures × 2 = 36 assertions covered)"
