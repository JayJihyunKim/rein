#!/bin/bash
# tests/rules/test-agents-md-bad-test-checklist.sh
# Plan B Phase 2 Task 2.3 — AGENTS.md §5 bad-test 체크박스 (test-changing only).
#
# Scope IDs covered:
#   - TO-bad-test-dod-checkitem-test-changing-only

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_FILE="$PROJECT_DIR/AGENTS.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-agents-md-bad-test-checklist.sh"
echo ""

echo "### Test 1: 'bad-test pattern 없음' 체크박스"
if grep -q "bad-test pattern 없음" "$AGENTS_FILE"; then
  _pass "bad-test pattern 없음 체크박스 존재"
else
  _fail "bad-test pattern 없음 체크박스 없음"
fi

echo "### Test 2: test-changing-only scope 명시"
if grep -q "테스트 파일을 건드리는 경우에 한해" "$AGENTS_FILE"; then
  _pass "test-changing-only scope 명시"
else
  _fail "test-changing-only scope 문구 없음"
fi

echo "### Test 3: N/A (no test change) 허용 명시"
if grep -q "N/A (no test change)" "$AGENTS_FILE"; then
  _pass "N/A 허용 명시"
else
  _fail "N/A 허용 문구 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
