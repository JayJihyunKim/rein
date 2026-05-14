#!/bin/bash
# tests/scripts/run-all.sh
# 모든 scripts 테스트를 순차 실행하고 종합 결과를 출력.
# 각 파일을 별도 bash 프로세스로 호출하여 한 파일의 실패가 다른 파일로
# 전염되지 않도록 한다. `bash tests/scripts/*.sh` 같은 wildcard 한 줄
# 호출은 쉘이 여러 파일을 한 프로세스에 넘기므로 금지.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0

for test_file in \
  "$SCRIPT_DIR/test-rein-policy-loader-bootstrap-gate.sh" \
  "$SCRIPT_DIR/test-rein-bootstrap-project-non-git.sh" \
  "$SCRIPT_DIR/test-advisory-summary.sh" \
  "$SCRIPT_DIR/test-route-record-validation.sh" \
  "$SCRIPT_DIR/test-incident-agent-eligible.sh" \
  "$SCRIPT_DIR/test-rein-govcheck.sh" \
  "$SCRIPT_DIR/test-rein-validator-v2.sh" \
  "$SCRIPT_DIR/test-validator-v2-scope-id-version.sh" \
  "$SCRIPT_DIR/test-validator-v2-behavioral-contract-checkbox.sh" \
  "$SCRIPT_DIR/test-test-oracle-promotion-check.sh" \
  "$SCRIPT_DIR/test-platform-detect.sh" \
  "$SCRIPT_DIR/test-helpers-smoke.sh" \
  "$SCRIPT_DIR/test-job-start-skeleton.sh" \
  "$SCRIPT_DIR/test-job-transport.sh" \
  "$SCRIPT_DIR/test-job-completion-wrapper.sh" \
  "$SCRIPT_DIR/test-job-detach-posix.sh" \
  "$SCRIPT_DIR/test-job-detach-mingw.sh" \
  "$SCRIPT_DIR/test-job-status.sh" \
  "$SCRIPT_DIR/test-job-stop-posix.sh" \
  "$SCRIPT_DIR/test-job-stop-mingw.sh" \
  "$SCRIPT_DIR/test-job-tail.sh" \
  "$SCRIPT_DIR/test-job-list.sh" \
  "$SCRIPT_DIR/test-job-gc.sh" \
  "$SCRIPT_DIR/test-bg-guide-exists.sh" \
  "$SCRIPT_DIR/test-ci-matrix.sh" \
  "$SCRIPT_DIR/test-local-marketplace.sh" \
  "$SCRIPT_DIR/../hooks/test-session-start-bootstrap.sh" \
  "$SCRIPT_DIR/test-plugin-hooks-bundle.sh" \
  "$SCRIPT_DIR/test-plugin-scripts-bundle.sh" \
  "$SCRIPT_DIR/test-policy-hooks-toggle.sh" \
  "$SCRIPT_DIR/test-policy-yaml-fallback.sh" \
  "$SCRIPT_DIR/test-policy-yaml-fails-open.sh" \
  "$SCRIPT_DIR/test-rein-init-unknown.sh" \
  "$SCRIPT_DIR/test-rein-route-record-paths.sh" \
  "$SCRIPT_DIR/test-rein-route-record-default.sh" \
  "$SCRIPT_DIR/test-plugin-agents-bundle.sh" \
  "$SCRIPT_DIR/test-plugin-skills-bundle.sh" \
  "$SCRIPT_DIR/test-version-parity.sh" \
  "$SCRIPT_DIR/test-rules-prompt-bundle-drift.sh" \
  "$SCRIPT_DIR/test-plugin-drift-detection.sh" \
  "$SCRIPT_DIR/../integration/test-slash-command-namespace.sh"
do
  echo ""
  echo "######## $(basename "$test_file") ########"
  # Fail loudly if a listed test file is missing — rename/delete/typo should
  # turn the CI red, not be silently skipped.
  if [ ! -f "$test_file" ]; then
    echo "MISSING: $test_file (update tests/scripts/run-all.sh after rename/delete)" >&2
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
