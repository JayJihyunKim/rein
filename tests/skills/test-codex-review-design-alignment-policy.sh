#!/bin/bash
# tests/skills/test-codex-review-design-alignment-policy.sh
# Plan B Phase 3 Task 3.1 — Design Alignment slot policy injection (wrapper).
#
# Scope IDs covered:
#   - TO-bad-test-alignment-unified-rule (status policy portion)
#   - TO-scope-id-measurable-contract-required (self-enforcement)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_DIR/scripts/rein-codex-review.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-codex-review-design-alignment-policy.sh"
echo ""

echo "### Test 1: MATCH 판정 기준 (entity/direction/scenario)"
if grep -q "MATCH: 해당 ID 가 기술한 entity/direction/scenario" "$WRAPPER"; then
  _pass "MATCH 판정 기준 명시"
else
  _fail "MATCH 판정 기준 없음"
fi

echo "### Test 2: CONTRADICTS 판정 (direction 반전)"
if grep -q "CONTRADICTS: direction 이 반대로 구현" "$WRAPPER"; then
  _pass "CONTRADICTS 정의 있음"
else
  _fail "CONTRADICTS 정의 없음"
fi

echo "### Test 3: measurable-contract 자기 강제 (ID 포맷 미달)"
if grep -q "TO-scope-id-measurable-contract-required" "$WRAPPER"; then
  _pass "measurable-contract self-enforcement 포함"
else
  _fail "self-enforcement ID 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
