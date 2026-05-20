#!/usr/bin/env bash
set -euo pipefail

# rein CLI surface 회귀 안전망.
#
# 본 runner 는 `scripts/rein.sh` 의 **현재 dispatch 표면** 만 검증한다.
# v1.0.0 에서 제거된 `rein new` / scaffold 시대의 `rein merge` 산출물 검증은
# 의도적으로 제외 — bootstrap 산출물 검증은 `tests/hooks/` + `tests/integration/`
# suite 가 담당. 본 파일은 rein.sh 자체의 dispatch + version 보고 + plugin
# redirect + job subcmd 분기만 책임진다.
#
# 갱신 회고: trail/dod/dod-2026-05-20-cycle-x1-scaffold-cleanup.md

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REIN_CLI="$SCRIPT_DIR/scripts/rein.sh"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_contains() {
  local description="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected to contain: $needle"
    echo "        actual output:       $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local description="$1"
  local expected_code="$2"
  local actual_code="$3"
  if [[ "$expected_code" == "$actual_code" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected exit code: $expected_code"
    echo "        actual exit code:   $actual_code"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test: --help
# ---------------------------------------------------------------------------
echo ""
echo "Test: --help"
help_output="$("$REIN_CLI" --help 2>&1 || true)"
assert_contains "--help output contains 'Usage'" "Usage" "$help_output"
assert_contains "--help advertises 'rein update'" "rein update" "$help_output"
assert_contains "--help advertises 'rein job'"    "rein job"    "$help_output"

# ---------------------------------------------------------------------------
# Test: --version
# ---------------------------------------------------------------------------
echo ""
echo "Test: --version"
version_output="$("$REIN_CLI" --version 2>&1 || true)"
assert_contains "--version output contains 'rein'" "rein" "$version_output"

# ---------------------------------------------------------------------------
# Test: update redirects to plugin update message
# ---------------------------------------------------------------------------
echo ""
echo "Test: update redirects to plugin update"
set +e
update_output="$("$REIN_CLI" update 2>&1)"
update_exit=$?
set -e
assert_exit_code "update exits 0 (informational redirect)" 0 "$update_exit"
assert_contains "update message points to 'claude plugin update rein'" "claude plugin update rein" "$update_output"

# ---------------------------------------------------------------------------
# Test: merge is alias of update redirect
# ---------------------------------------------------------------------------
echo ""
echo "Test: merge redirects to plugin update"
set +e
merge_output="$("$REIN_CLI" merge 2>&1)"
merge_exit=$?
set -e
assert_exit_code "merge exits 0 (informational redirect)" 0 "$merge_exit"
assert_contains "merge message points to 'claude plugin update rein'" "claude plugin update rein" "$merge_output"

# ---------------------------------------------------------------------------
# Test: unknown command exits 1
# ---------------------------------------------------------------------------
echo ""
echo "Test: unknown command exits 1"
set +e
( "$REIN_CLI" definitely-not-a-real-command > /dev/null 2>&1 )
unknown_exit=$?
set -e
assert_exit_code "unknown command exit code is 1" 1 "$unknown_exit"

# ---------------------------------------------------------------------------
# Test: rein new is removed (scaffold era artifact)
# ---------------------------------------------------------------------------
# `rein new` was removed in v1.0.0 — plugin-install replaces local scaffolding.
# This test pins the removal so a future regression that re-adds a `new` case
# trips a CLI-surface review instead of silently shipping.
echo ""
echo "Test: rein new is no longer dispatched"
set +e
( "$REIN_CLI" new whatever > /dev/null 2>&1 )
new_exit=$?
set -e
assert_exit_code "'new' is treated as unknown command (exit 1)" 1 "$new_exit"

# ---------------------------------------------------------------------------
# Test: job requires a subcommand
# ---------------------------------------------------------------------------
echo ""
echo "Test: job requires a subcommand"
set +e
( "$REIN_CLI" job > /dev/null 2>&1 )
job_no_sub_exit=$?
set -e
assert_exit_code "'job' with no subcommand exits 1" 1 "$job_no_sub_exit"

# ---------------------------------------------------------------------------
# Test: job rejects unknown subcommands
# ---------------------------------------------------------------------------
echo ""
echo "Test: job rejects unknown subcommands"
set +e
( "$REIN_CLI" job not-a-subcmd > /dev/null 2>&1 )
job_bad_sub_exit=$?
set -e
assert_exit_code "'job not-a-subcmd' exits 1" 1 "$job_bad_sub_exit"

# ---------------------------------------------------------------------------
# Test: job list is dispatchable (smoke — output may be empty in a clean env)
# ---------------------------------------------------------------------------
echo ""
echo "Test: job list is dispatchable"
set +e
list_output="$("$REIN_CLI" job list 2>&1)"
list_exit=$?
set -e
assert_exit_code "'job list' exits 0" 0 "$list_exit"

# ---------------------------------------------------------------------------
# Test: no-arg invocation prints usage and exits 1
# ---------------------------------------------------------------------------
echo ""
echo "Test: no-arg invocation"
set +e
no_arg_output="$("$REIN_CLI" 2>&1)"
no_arg_exit=$?
set -e
assert_exit_code "no-arg invocation exits 1" 1 "$no_arg_exit"
assert_contains  "no-arg output contains 'Usage'" "Usage" "$no_arg_output"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
