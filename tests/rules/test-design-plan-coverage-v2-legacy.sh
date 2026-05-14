#!/bin/bash
# tests/rules/test-design-plan-coverage-v2-legacy.sh
# Plan B Phase 1 Task 1.4 — legacy migration (edit-only) 규칙.
#
# Scope IDs covered:
#   - TO-scope-id-legacy-migration-edit-only

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/design-plan-coverage.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-design-plan-coverage-v2-legacy.sh"
echo ""

echo "### Test 1: 'Scope Items history' 포맷 명시"
if grep -q "Scope Items history" "$RULE_FILE"; then
  _pass "'Scope Items history' 언급 존재"
else
  _fail "'Scope Items history' 언급 없음"
fi

echo "### Test 2: '편집 시에만 승격' 원칙"
if grep -q "편집 시에만 승격" "$RULE_FILE"; then
  _pass "편집 시에만 승격 원칙 명시"
else
  _fail "편집 시에만 승격 원칙 없음"
fi

echo "### Test 3: '자동 date-based 승격 없음' 원칙"
if grep -q "자동 date-based 승격 없음" "$RULE_FILE"; then
  _pass "자동 date-based 승격 없음 명시"
else
  _fail "자동 date-based 승격 없음 missing"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
