#!/bin/bash
# tests/rules/run-all.sh
# 모든 rule grep 테스트를 순차 실행하고 종합 결과를 출력.
# Plan B Phase 1/2/5 에서 신설된 rule 문서 검증 테스트 집합.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0

for test_file in \
  "$SCRIPT_DIR/test-design-plan-coverage-v2-rule.sh" \
  "$SCRIPT_DIR/test-design-plan-coverage-v2-version-meta.sh" \
  "$SCRIPT_DIR/test-design-plan-coverage-v2-examples.sh" \
  "$SCRIPT_DIR/test-design-plan-coverage-v2-legacy.sh" \
  "$SCRIPT_DIR/test-testing-rule-categories.sh" \
  "$SCRIPT_DIR/test-testing-rule-assertion-template.sh" \
  "$SCRIPT_DIR/test-agents-md-bad-test-checklist.sh" \
  "$SCRIPT_DIR/test-testing-rule-claim-audit-pr-only.sh" \
  "$SCRIPT_DIR/test-test-oracle-state-init.sh"
do
  echo ""
  echo "######## $(basename "$test_file") ########"
  if [ ! -f "$test_file" ]; then
    echo "MISSING: $test_file" >&2
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi
  bash "$test_file" || TOTAL_FAIL=$((TOTAL_FAIL + 1))
done

echo ""
echo "####################################"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "ALL SUITES PASSED"
  exit 0
else
  echo "${TOTAL_FAIL} SUITE(S) FAILED"
  exit 1
fi
