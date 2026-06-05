#!/bin/bash
# tests/hooks/run-all.sh
# 모든 훅 테스트를 순차 실행하고 종합 결과를 출력

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_FAIL=0

for test_file in \
  "$SCRIPT_DIR/test-bootstrap-check-helper.sh" \
  "$SCRIPT_DIR/test-pre-edit-trail-bootstrap-gate.sh" \
  "$SCRIPT_DIR/test-pre-tool-use-bash-bootstrap-gate.sh" \
  "$SCRIPT_DIR/test-bootstrap-gate-hooks-json-order.sh" \
  "$SCRIPT_DIR/test-user-prompt-submit-bootstrap-advisory.sh" \
  "$SCRIPT_DIR/test-session-start-bootstrap-helper-refactor.sh" \
  "$SCRIPT_DIR/test-bootstrap-trigger-parity.sh" \
  "$SCRIPT_DIR/test-dod-rotation.sh" \
  "$SCRIPT_DIR/test-dod-gate.sh" \
  "$SCRIPT_DIR/test-pre-edit-dod-gate-sr-1-b.sh" \
  "$SCRIPT_DIR/test-pre-edit-dod-gate-spec-tests-exempt.sh" \
  "$SCRIPT_DIR/test-pre-edit-dod-gate-pln1-enforce.sh" \
  "$SCRIPT_DIR/test-stop-gate.sh" \
  "$SCRIPT_DIR/test-stop-gate-deadlock.sh" \
  "$SCRIPT_DIR/test-stat-portability.sh" \
  "$SCRIPT_DIR/test-index-sync-inbox.sh" \
  "$SCRIPT_DIR/test-commit-msg.sh" \
  "$SCRIPT_DIR/test-session-start.sh" \
  "$SCRIPT_DIR/test-spec-review-gate.sh" \
  "$SCRIPT_DIR/test-incidents-automation.sh" \
  "$SCRIPT_DIR/test-stop-incident-gate.sh" \
  "$SCRIPT_DIR/test-incidents-semi-automation-full.sh" \
  "$SCRIPT_DIR/test-coverage-matrix.sh" \
  "$SCRIPT_DIR/test-session-start-line-stamp.sh" \
  "$SCRIPT_DIR/test-incident-advisory-check.sh" \
  "$SCRIPT_DIR/test-bash-guard-split.sh" \
  "$SCRIPT_DIR/test-bash-dispatcher.sh" \
  "$SCRIPT_DIR/test-pre-bash-safety-guard.sh" \
  "$SCRIPT_DIR/test-pre-bash-test-commit-gate.sh" \
  "$SCRIPT_DIR/test-security-tier-gate.sh" \
  "$SCRIPT_DIR/test-python-runner.sh" \
  "$SCRIPT_DIR/test-extract-hook-json.sh" \
  "$SCRIPT_DIR/test-path-policy.sh" \
  "$SCRIPT_DIR/test-governance-stage.sh" \
  "$SCRIPT_DIR/test-select-active-dod.sh" \
  "$SCRIPT_DIR/test-pre-edit-dod-gate.sh" \
  "$SCRIPT_DIR/test-bad-test-candidates-log-format.sh" \
  "$SCRIPT_DIR/test-project-dir-resolution.sh" \
  "$SCRIPT_DIR/test-post-edit-dispatcher.sh" \
  "$SCRIPT_DIR/test-post-edit-dispatcher-aggregator.sh" \
  "$SCRIPT_DIR/test-post-edit-dispatcher-deprecated.sh" \
  "$SCRIPT_DIR/test-post-edit-parallel-entries.sh" \
  "$SCRIPT_DIR/test-post-edit-aggregator.sh" \
  "$SCRIPT_DIR/test-post-edit-aggregator-merge.sh" \
  "$SCRIPT_DIR/test-perf-2-resolver-cache.sh" \
  "$SCRIPT_DIR/test-action-mandate-existing-rules.sh" \
  "$SCRIPT_DIR/test-action-mandate-new-rules.sh" \
  "$SCRIPT_DIR/test-design-plan-coverage-plugin-size.sh" \
  "$SCRIPT_DIR/test-dev-only-rules-not-in-plugin.sh" \
  "$SCRIPT_DIR/test-rule-inject-helper.sh" \
  "$SCRIPT_DIR/test-json-deny-emitter.sh" \
  "$SCRIPT_DIR/test-user-prompt-submit-rules.sh" \
  "$SCRIPT_DIR/test-pre-tool-use-agent-rules.sh" \
  "$SCRIPT_DIR/test-pre-tool-use-bash-rules.sh" \
  "$SCRIPT_DIR/test-post-edit-design-plan-coverage-rule.sh" \
  "$SCRIPT_DIR/test-design-provenance-marker.sh" \
  "$SCRIPT_DIR/test-hooks-json-schema.sh" \
  "$SCRIPT_DIR/test-overflow-handoff-no-truncation.sh" \
  "$SCRIPT_DIR/test-pre-edit-dod-gate-no-orchestrator-ref.sh" \
  "$SCRIPT_DIR/test-post-edit-dod-routing-check-no-orchestrator-ref.sh" \
  "$SCRIPT_DIR/test-rein-validate-plugin-rules.sh" \
  "$SCRIPT_DIR/test-rein-validate-plugin-rules-hardening.sh" \
  "$SCRIPT_DIR/test-post-agent-review-trigger.sh" \
  "$SCRIPT_DIR/test-plan-coverage-deferral.sh" \
  "$SCRIPT_DIR/test-state-machine.sh" \
  "$SCRIPT_DIR/test-state-machine-integration.sh" \
  "$SCRIPT_DIR/test-state-fast-path-skip.sh" \
  "$SCRIPT_DIR/test-onboarding-primer.sh" \
  "$SCRIPT_DIR/test-teach-forward-gates.sh" \
  "$SCRIPT_DIR/test-git-snapshot.sh" \
  "$SCRIPT_DIR/test-routing-map-emit.sh"
do
  echo ""
  echo "######## $(basename "$test_file") ########"
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
