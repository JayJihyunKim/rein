#!/usr/bin/env bash
# Test UPS-1: short rule injection acceptance criteria
#
# Verifies:
#   1. short rule 3 파일 존재 + 각 ≤ 600 B (단, response-tone-summary 는 ≤ 1300 B —
#      번역 테이블 + 보고 구조 + 질문 형식 4 항목 포함이라 더 큼)
#   2. user-prompt-submit-rules.sh 가 short/answer-only-summary inject (full body 미참조)
#   3. user-prompt-submit-rules.sh 가 short/response-tone-summary inject (full body 미참조)
#   4. pre-tool-use-bash-rules.sh 가 short/background-jobs-summary inject (full body 미참조)
#   5. session-start-rules.sh 의 6-rule (response-tone 포함) inject (이전 4-rule anchor 갱신)
#   6. original full body 파일은 plugin source 에 보존
#
# Covers: UPS-1-user-prompt-submit-rules-and-pre-tool-use-bash-rules-hooks-inject-short-summary-bodies-instead-of-full-answer-only-mode-and-background-jobs-text-while-session-start-rules-keeps-its-existing-four-rule-full-inject-unchanged + communication-improve-2026-05-28
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

# 1. short rule 3 파일 존재
check "answer-only-summary.md 존재" \
  '[ -f plugins/rein-core/rules/short/answer-only-summary.md ]'
check "background-jobs-summary.md 존재" \
  '[ -f plugins/rein-core/rules/short/background-jobs-summary.md ]'
check "response-tone-summary.md 존재 (communication-improve, 2026-05-28)" \
  '[ -f plugins/rein-core/rules/short/response-tone-summary.md ]'

# 2. 크기 한계
ANSWER_SIZE=$(wc -c < plugins/rein-core/rules/short/answer-only-summary.md | tr -d ' ')
BG_SIZE=$(wc -c < plugins/rein-core/rules/short/background-jobs-summary.md | tr -d ' ')
TONE_SIZE=$(wc -c < plugins/rein-core/rules/short/response-tone-summary.md | tr -d ' ')
check "answer-only-summary ≤ 600 B (실측 ${ANSWER_SIZE} B)" \
  "[ ${ANSWER_SIZE} -le 600 ]"
check "background-jobs-summary ≤ 600 B (실측 ${BG_SIZE} B)" \
  "[ ${BG_SIZE} -le 600 ]"
check "response-tone-summary ≤ 1300 B (실측 ${TONE_SIZE} B — 번역 테이블·보고 구조·질문 형식 4 항목 포함이라 더 큼)" \
  "[ ${TONE_SIZE} -le 1300 ]"

# 3. user-prompt-submit-rules.sh — single-spawn --turn-brief delegation (PT-8).
#    The hook no longer calls rule_inject_body per rule; the loader's
#    --turn-brief mode composes answer-only + response-tone + persona summaries
#    AND json-encodes the envelope in ONE process. (Body markers are verified
#    by tests/scripts/test-policy-loader-turn-brief.sh.)
check "user-prompt-submit-rules.sh 가 --turn-brief 위임 (PT-8)" \
  'grep -q -- "--turn-brief" plugins/rein-core/hooks/user-prompt-submit-rules.sh'
# negative: per-rule rule_inject_body 호출이 사라졌는지 (주석 언급은 슬래시/규칙명 없음)
check "user-prompt-submit-rules.sh 가 per-rule rule_inject_body 미호출" \
  '! grep -qE "rule_inject_body (short/|answer-only|response-tone)" plugins/rein-core/hooks/user-prompt-submit-rules.sh'
check "user-prompt-submit-rules.sh 가 inline python3 -c json 미사용 (단일 spawn)" \
  '! grep -q "python3 -c" plugins/rein-core/hooks/user-prompt-submit-rules.sh'
check "persona-summary.md 존재 (--turn-brief 매턴 nudge, PT-6)" \
  '[ -f plugins/rein-core/rules/short/persona-summary.md ]'
check "persona-summary ≤ 600 B" \
  '[ "$(wc -c < plugins/rein-core/rules/short/persona-summary.md | tr -d " ")" -le 600 ]'
# Trust boundary (codex code-review HIGH): an INHERITED REIN_TURN_BRIEF_PREPEND
# must NOT leak into the per-turn envelope. The hook is the sole legitimate
# source of the prepend; it sets the var explicitly (empty when no bootstrap
# guidance), overriding any inherited value.
check "user-prompt-submit-rules.sh 가 상속 REIN_TURN_BRIEF_PREPEND 미누출" \
  'CTX=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/rein-core" REIN_TURN_BRIEF_PREPEND="INHERITED_BAD_PREPEND" bash plugins/rein-core/hooks/user-prompt-submit-rules.sh 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[\"hookSpecificOutput\"][\"additionalContext\"])"); ! printf "%s" "$CTX" | grep -q "INHERITED_BAD_PREPEND"'

# 4. pre-tool-use-bash-rules.sh — short summary inject + full body 미참조
check "pre-tool-use-bash-rules.sh 가 short/background-jobs-summary 참조" \
  'grep -q "rule_inject_body short/background-jobs-summary" plugins/rein-core/hooks/pre-tool-use-bash-rules.sh'
check "pre-tool-use-bash-rules.sh 가 full background-jobs 미참조" \
  '! grep -qE "rule_inject_body background-jobs([^-]|$)" plugins/rein-core/hooks/pre-tool-use-bash-rules.sh'

# 5. session-start-rules.sh 의 6-rule loop (response-tone 포함, communication-improve 2026-05-28)
check "session-start-rules.sh 가 6-rule loop (code-style/security/testing/operating-sequence/routing-map/response-tone)" \
  'grep -q "for RULE in code-style security testing operating-sequence routing-map response-tone" plugins/rein-core/hooks/session-start-rules.sh'

# 6. original full body 파일은 plugin source 에 보존 (R1 mitigation — 본문 복원 가능)
check "answer-only-mode.md (full, 7 KB) plugin source 보존" \
  '[ -f plugins/rein-core/rules/answer-only-mode.md ]'
check "background-jobs.md (full, 6 KB) plugin source 보존" \
  '[ -f plugins/rein-core/rules/background-jobs.md ]'
check "response-tone.md (full) plugin source 보존" \
  '[ -f plugins/rein-core/rules/response-tone.md ]'

echo ""
echo "==== Summary: ${PASS} PASS, ${FAIL} FAIL ===="
if [ "${FAIL}" -gt 0 ]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
