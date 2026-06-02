#!/bin/bash
# tests/agents/run-all.sh
# 모든 agents 테스트를 순차 실행하고 종합 결과를 출력.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0

for test_file in \
  "$SCRIPT_DIR/test-ag2-worktree-frontmatter.sh" \
  "$SCRIPT_DIR/test-plan-writer-exec-strategy-v2.sh" \
  "$SCRIPT_DIR/test-dod-changed-files-section.sh" \
  "$SCRIPT_DIR/test-spec-writer-auto-review-contract.sh" \
  "$SCRIPT_DIR/test-plan-path-consistency.sh"
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
