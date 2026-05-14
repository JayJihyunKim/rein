#!/bin/bash
# tests/rules/test-testing-rule-claim-audit-pr-only.sh
# Plan B Phase 2 Task 2.4 — claim audit 은 PR review 단계에서만.
#
# Scope IDs covered:
#   - TO-claim-audit-pr-level-only

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/testing.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-testing-rule-claim-audit-pr-only.sh"
echo ""

echo "### Test 1: 'claim audit' 용어 명시"
if grep -q "claim audit" "$RULE_FILE"; then
  _pass "claim audit 용어 존재"
else
  _fail "claim audit 용어 없음"
fi

echo "### Test 2: 'PR review 단계' 명시"
if grep -q "PR review 단계" "$RULE_FILE"; then
  _pass "PR review 단계 명시"
else
  _fail "PR review 단계 문구 없음"
fi

echo "### Test 3: 'local commit hook 으로 만들지 않는다' 명시"
if grep -q "local commit hook 으로 만들지 않는다" "$RULE_FILE"; then
  _pass "local commit hook 금지 명시"
else
  _fail "local commit hook 금지 문구 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
