#!/bin/bash
# tests/rules/test-testing-rule-categories.sh
# Plan B Phase 2 Task 2.1 — 테스트 카테고리 (unit/integration/behavioral-contract).
#
# Scope IDs covered:
#   - TO-behavioral-contract-test-categorize

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/testing.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-testing-rule-categories.sh"
echo ""

echo "### Test 1: behavioral-contract 카테고리 명시"
if grep -q "behavioral-contract" "$RULE_FILE"; then
  _pass "behavioral-contract 카테고리 존재"
else
  _fail "behavioral-contract 카테고리 없음"
fi

echo "### Test 2: unit 행 존재"
if grep -q "| unit |" "$RULE_FILE"; then
  _pass "unit 행 존재"
else
  _fail "unit 행 없음"
fi

echo "### Test 3: integration 행 존재"
if grep -q "| integration |" "$RULE_FILE"; then
  _pass "integration 행 존재"
else
  _fail "integration 행 없음"
fi

echo "### Test 4: design 이 명시한 contrast 설명"
if grep -q "design 이 명시한 contrast" "$RULE_FILE"; then
  _pass "contrast 설명 있음"
else
  _fail "design 이 명시한 contrast 문구 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
