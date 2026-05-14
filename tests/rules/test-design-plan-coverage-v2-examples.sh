#!/bin/bash
# tests/rules/test-design-plan-coverage-v2-examples.sh
# Plan B Phase 1 Task 1.3 — acceptable/non-acceptable 예시 3+3.
#
# Scope IDs covered:
#   - TO-scope-id-examples-anchored

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/design-plan-coverage.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-design-plan-coverage-v2-examples.sh"
echo ""

echo "### Test 1: acceptable 예시 3개 존재 (대소문자 원문 보존)"
count=$(grep -cE '\b(CAUTION-nav-drawdown-less-than-ATTACK|rotation-leading-biases-risk-off-when-ge2-of-3-bearish|preflight-blocks-empty-universe-returns-false)\b' "$RULE_FILE")
if [ "$count" -ge 3 ]; then
  _pass "acceptable 예시 3개 이상 존재 ($count)"
else
  _fail "acceptable 예시 누락 (found=$count)"
fi

echo "### Test 2: non-acceptable 라벨 존재"
if grep -qi 'non-acceptable\|부적합' "$RULE_FILE"; then
  _pass "non-acceptable 또는 부적합 라벨 존재"
else
  _fail "non-acceptable / 부적합 라벨 없음"
fi

echo "### Test 3: 반례 3개 사유 라벨 '이유:' 존재"
# 각 반례 별도 line 에 '이유:' 가 있어야 한다. 3 line 이상.
count=$(grep -c '^.*이유:' "$RULE_FILE")
if [ "$count" -ge 3 ]; then
  _pass "이유: 라벨 3개 이상 ($count)"
else
  _fail "이유: 라벨 부족 ($count)"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
