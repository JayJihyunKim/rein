#!/bin/bash
# tests/rules/test-design-plan-coverage-v2-rule.sh
# Plan B Phase 1 Task 1.1 — behavior-level rule + measurable contract 본문.
#
# Scope IDs covered:
#   - TO-scope-id-behavior-level-rule
#   - TO-scope-id-measurable-contract-required

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULE_FILE="$PROJECT_DIR/plugins/rein-core/rules/design-plan-coverage.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-design-plan-coverage-v2-rule.sh"
echo ""

echo "### Test 1: behavior-level contract 용어 존재"
if grep -q "behavior-level contract" "$RULE_FILE"; then
  _pass "'behavior-level contract' 용어가 rule 문서에 있다"
else
  _fail "'behavior-level contract' 용어가 rule 문서에 없다"
fi

echo "### Test 2: direction / 임계값 요소 문구"
if grep -q "direction / 임계값" "$RULE_FILE"; then
  _pass "'direction / 임계값' 표현 있음"
else
  _fail "'direction / 임계값' 표현 없음"
fi

echo "### Test 3: scenario / window 요소 문구"
if grep -q "scenario / window" "$RULE_FILE"; then
  _pass "'scenario / window' 표현 있음"
else
  _fail "'scenario / window' 표현 없음"
fi

echo "### Test 4: entity + verb 요소 문구"
if grep -q "entity + verb" "$RULE_FILE"; then
  _pass "'entity + verb' 표현 있음"
else
  _fail "'entity + verb' 표현 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
