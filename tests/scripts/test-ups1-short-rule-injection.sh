#!/usr/bin/env bash
# Test UPS-1: short rule injection acceptance criteria
#
# Verifies:
#   1. short rule 2 파일 존재 + 각 ≤ 600 B
#   2. user-prompt-submit-rules.sh 가 short/answer-only-summary inject (full body 미참조)
#   3. pre-tool-use-bash-rules.sh 가 short/background-jobs-summary inject (full body 미참조)
#   4. session-start-rules.sh 의 4-rule (code-style/security/testing/operating-sequence) inject 미변경
#   5. original full body 파일은 plugin source 에 보존
#
# Covers: UPS-1-user-prompt-submit-rules-and-pre-tool-use-bash-rules-hooks-inject-short-summary-bodies-instead-of-full-answer-only-mode-and-background-jobs-text-while-session-start-rules-keeps-its-existing-four-rule-full-inject-unchanged
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ERRORS=()

check() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("FAIL: $desc")
    echo "FAIL: $desc"
  fi
}

# 1. short rule 2 파일 존재
check "answer-only-summary.md 존재" \
  '[ -f plugins/rein-core/rules/short/answer-only-summary.md ]'
check "background-jobs-summary.md 존재" \
  '[ -f plugins/rein-core/rules/short/background-jobs-summary.md ]'

# 2. 각 ≤ 600 B (DoD criteria)
ANSWER_SIZE=$(wc -c < plugins/rein-core/rules/short/answer-only-summary.md | tr -d ' ')
BG_SIZE=$(wc -c < plugins/rein-core/rules/short/background-jobs-summary.md | tr -d ' ')
check "answer-only-summary ≤ 600 B (실측 ${ANSWER_SIZE} B)" \
  "[ ${ANSWER_SIZE} -le 600 ]"
check "background-jobs-summary ≤ 600 B (실측 ${BG_SIZE} B)" \
  "[ ${BG_SIZE} -le 600 ]"

# 3. user-prompt-submit-rules.sh — short summary inject + full body 미참조
check "user-prompt-submit-rules.sh 가 short/answer-only-summary 참조" \
  'grep -q "rule_inject_body short/answer-only-summary" plugins/rein-core/hooks/user-prompt-submit-rules.sh'
# negative: full body 인자 "answer-only-mode;" (semicolon 까지) 가 사라졌는지
check "user-prompt-submit-rules.sh 가 full answer-only-mode 미참조" \
  '! grep -qE "rule_inject_body answer-only-mode([^-]|$)" plugins/rein-core/hooks/user-prompt-submit-rules.sh'

# 4. pre-tool-use-bash-rules.sh — short summary inject + full body 미참조
check "pre-tool-use-bash-rules.sh 가 short/background-jobs-summary 참조" \
  'grep -q "rule_inject_body short/background-jobs-summary" plugins/rein-core/hooks/pre-tool-use-bash-rules.sh'
check "pre-tool-use-bash-rules.sh 가 full background-jobs 미참조" \
  '! grep -qE "rule_inject_body background-jobs([^-]|$)" plugins/rein-core/hooks/pre-tool-use-bash-rules.sh'

# 5. session-start-rules.sh 의 4-rule loop 미변경 (anchor 보존)
check "session-start-rules.sh 가 4-rule loop (code-style/security/testing/operating-sequence) 유지" \
  'grep -q "for RULE in code-style security testing operating-sequence" plugins/rein-core/hooks/session-start-rules.sh'

# 6. original full body 파일은 plugin source 에 보존 (R1 mitigation — 본문 복원 가능)
check "answer-only-mode.md (full, 7 KB) plugin source 보존" \
  '[ -f plugins/rein-core/rules/answer-only-mode.md ]'
check "background-jobs.md (full, 6 KB) plugin source 보존" \
  '[ -f plugins/rein-core/rules/background-jobs.md ]'

echo ""
echo "==== Summary: ${PASS} PASS, ${FAIL} FAIL ===="
if [ "${FAIL}" -gt 0 ]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
