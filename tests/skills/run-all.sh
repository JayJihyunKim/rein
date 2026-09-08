#!/bin/bash
# tests/skills/run-all.sh
# 모든 skills 테스트를 순차 실행하고 종합 결과를 출력.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0
FAILED_SUITES=""

for test_file in \
  "$SCRIPT_DIR/test-codex-review-wrapper.sh" \
  "$SCRIPT_DIR/test-codex-review-design-alignment-policy.sh" \
  "$SCRIPT_DIR/test-codex-review-test-alignment-policy.sh" \
  "$SCRIPT_DIR/test-codex-review-claim-audit-policy.sh" \
  "$SCRIPT_DIR/test-codex-model-failsoft.sh" \
  "$SCRIPT_DIR/test-codex-model-profile-routing.sh" \
  "$SCRIPT_DIR/test-review-evidence-manifest.sh" \
  "$SCRIPT_DIR/test-review-selfverify-gate.sh" \
  "$SCRIPT_DIR/test-review-envelope-reduction.sh" \
  "$SCRIPT_DIR/test-review-watchdog.sh" \
  "$SCRIPT_DIR/test-review-doc-mode-slots.sh" \
  "$SCRIPT_DIR/test-review-round-budget.sh" \
  "$SCRIPT_DIR/test-persona-skill.sh" \
  "$SCRIPT_DIR/test-parallel-execute-skill.sh"
do
  echo ""
  echo "######## $(basename "$test_file") ########"
  if [ ! -f "$test_file" ]; then
    echo "MISSING: $test_file" >&2
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_SUITES="$FAILED_SUITES $(basename "$test_file")"
    continue
  fi
  if ! bash "$test_file"; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_SUITES="$FAILED_SUITES $(basename "$test_file")"
  fi
done

echo ""
echo "####################################"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "ALL SUITES PASSED"
  exit 0
else
  echo "${TOTAL_FAIL} SUITE(S) FAILED"
  for _failed_suite in $FAILED_SUITES; do
    echo "  - $_failed_suite"
  done
  exit 1
fi
