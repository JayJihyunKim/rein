#!/bin/bash
# tests/rules/test-design-plan-coverage-v2-version-meta.sh
# Plan B Phase 1 Task 1.2 — scope-id-version frontmatter meta 규칙.
#
# Scope IDs covered:
#   - TO-scope-id-version-meta-in-design

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/design-plan-coverage.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-design-plan-coverage-v2-version-meta.sh"
echo ""

echo "### Test 1: scope-id-version: v2 명시"
if grep -q "scope-id-version: v2" "$RULE_FILE"; then
  _pass "scope-id-version: v2 명시"
else
  _fail "scope-id-version: v2 없음"
fi

echo "### Test 2: design 문서 상단 frontmatter 위치"
if grep -q "design 문서 상단 frontmatter" "$RULE_FILE"; then
  _pass "design 문서 상단 frontmatter 위치 명시"
else
  _fail "design 문서 상단 frontmatter 명시 없음"
fi

echo "### Test 3: v1 legacy 호환 명시"
if grep -q "v1 으로 간주" "$RULE_FILE"; then
  _pass "v1 으로 간주 (legacy 호환)"
else
  _fail "v1 legacy 호환 설명 없음"
fi

echo "### Test 4: unknown fail-closed 명시"
if grep -q "fail-closed" "$RULE_FILE"; then
  _pass "unknown 값 fail-closed 명시"
else
  _fail "fail-closed 명시 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
