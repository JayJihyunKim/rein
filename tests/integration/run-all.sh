#!/bin/bash
# tests/integration/run-all.sh
# 모든 integration 테스트를 순차 실행하고 종합 결과를 출력.
# 각 파일을 별도 bash 프로세스로 호출하여 한 파일의 실패가 다른 파일로
# 전염되지 않도록 한다 (tests/scripts/run-all.sh 와 동일 원칙).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0

for test_file in \
  "$SCRIPT_DIR/test-governance-e2e.sh" \
  "$SCRIPT_DIR/test-fresh-design-spec-review-no-fallback.sh" \
  "$SCRIPT_DIR/test-slash-command-namespace.sh" \
  "$SCRIPT_DIR/test-git-required-onboarding-e2e.sh"
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
