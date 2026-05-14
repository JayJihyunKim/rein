#!/bin/bash
# tests/rules/test-testing-rule-assertion-template.sh
# Plan B Phase 2 Task 2.2 — behavioral-contract assertion template.
#
# Scope IDs covered:
#   - TO-behavioral-contract-assertion-anchored

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/testing.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-testing-rule-assertion-template.sh"
echo ""

echo "### Test 1: Good 예시 — drawdown(result_caution"
if grep -q "drawdown(result_caution" "$RULE_FILE"; then
  _pass "Good 예시 존재"
else
  _fail "Good 예시 없음"
fi

echo "### Test 2: Bad 예시 — nav == 101_000_000"
if grep -q "nav == 101_000_000" "$RULE_FILE"; then
  _pass "Bad 예시 (contrast 없음) 존재"
else
  _fail "Bad 예시 없음"
fi

echo "### Test 3: contrast-only 금지 패턴 명시"
if grep -q "contrast-only" "$RULE_FILE"; then
  _pass "contrast-only 금지 명시"
else
  _fail "contrast-only 금지 언급 없음"
fi

echo "### Test 4: Scenario 명시 요점"
if grep -q "Scenario 명시" "$RULE_FILE"; then
  _pass "Scenario 명시 요점 있음"
else
  _fail "Scenario 명시 요점 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
