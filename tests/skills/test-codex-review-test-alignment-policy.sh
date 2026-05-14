#!/bin/bash
# tests/skills/test-codex-review-test-alignment-policy.sh
# Plan B Phase 3 Task 3.2 — Test Alignment slot policy (unified rule + corroboration).
#
# Scope IDs covered:
#   - TO-bad-test-alignment-unified-rule
#   - TO-bad-test-corroboration-same-contract

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_DIR/scripts/rein-codex-review.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-codex-review-test-alignment-policy.sh"
echo ""

echo "### Test 1: Step 1 (Status 판정) 존재"
if grep -q "Step 1: Status 판정" "$WRAPPER"; then
  _pass "Step 1 명시"
else
  _fail "Step 1 없음"
fi

echo "### Test 2: Step 2 (Severity 판정) 존재"
if grep -q "Step 2: Severity 판정" "$WRAPPER"; then
  _pass "Step 2 명시"
else
  _fail "Step 2 없음"
fi

echo "### Test 3: same-result 가 divergence 요구 시에만 CONTRADICTS"
if grep -q "same-result 는 design 이 divergence 를 요구하는 경우에만" "$WRAPPER"; then
  _pass "same-result false-positive guard 명시"
else
  _fail "same-result guard 문구 없음"
fi

echo "### Test 4: test_entity 언급"
if grep -q "test_entity" "$WRAPPER"; then
  _pass "test_entity 추출 요소 명시"
else
  _fail "test_entity 없음"
fi

echo "### Test 5: test_direction 언급"
if grep -q "test_direction" "$WRAPPER"; then
  _pass "test_direction 추출 요소 명시"
else
  _fail "test_direction 없음"
fi

echo "### Test 6: test_scenario 언급"
if grep -q "test_scenario" "$WRAPPER"; then
  _pass "test_scenario 추출 요소 명시"
else
  _fail "test_scenario 없음"
fi

echo "### Test 7: fail-safe corroboration 0 명시"
if grep -q "corroboration 0 으로 처리" "$WRAPPER"; then
  _pass "corroboration 0 fail-safe 명시"
else
  _fail "corroboration 0 처리 없음"
fi

echo "### Test 8: 세 축 모두 일치 강제"
if grep -q "세 축이 모두 일치" "$WRAPPER"; then
  _pass "3 축 동시 매칭 규칙 명시"
else
  _fail "세 축이 모두 일치 문구 없음"
fi

echo "### Test 9: parent/child 분리 구조 사용 금지"
if grep -q "parent/child 분리 구조 사용 금지" "$WRAPPER"; then
  _pass "single rule 재확인"
else
  _fail "parent/child 금지 문구 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
