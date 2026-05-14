#!/bin/bash
# tests/skills/run-all.sh
# 모든 skills 테스트를 순차 실행하고 종합 결과를 출력.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0

for test_file in \
  "$SCRIPT_DIR/test-codex-review-wrapper.sh" \
  "$SCRIPT_DIR/test-codex-review-design-alignment-policy.sh" \
  "$SCRIPT_DIR/test-codex-review-test-alignment-policy.sh" \
  "$SCRIPT_DIR/test-codex-review-claim-audit-policy.sh"
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
