#!/usr/bin/env bash
# Test PERF-3: background-jobs advisory hook (pre-tool-use-bash-rules.sh) cold-path skip
#
# Verifies hooks.json structure (grep-contract — runtime spawn 검증은 Claude Code 통합 테스트):
#   1. pre-tool-use-bash-rules.sh 가 unconditional (if 필드 없음) 으로 등록되지 않음
#   2. pre-tool-use-bash-rules.sh 가 13 hot-path 패턴별 if-gated entry 로 등록됨
#   3. pre-tool-use-bash-bootstrap-gate.sh 는 always-on (if 필드 없음) 유지
#   4. pre-bash-safety-guard.sh 는 always-on (if 필드 없음) 유지
#   5. 모든 if 패턴이 Bash(<pattern> *) 형식
#
# Covers: PERF-3-background-jobs-advisory-hook-skipped-via-if-field-hot-path-whitelist-pattern-while-bootstrap-gate-and-safety-guard-remain-always-on
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

HOOKS_JSON="plugins/rein-core/hooks/hooks.json"

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

# 0. hooks.json JSON 유효성
check "hooks.json JSON parse 가능" \
  'python3 -c "import json; json.load(open(\"${HOOKS_JSON}\"))"'

# 1. pre-tool-use-bash-rules.sh 가 unconditional entry 로 등록 안 됨
# (Bash PreToolUse 블록 내에서 if 필드 없는 entry 가 0 인지 확인)
UNCONDITIONAL=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
count = 0
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('command', '').endswith('pre-tool-use-bash-rules.sh') and 'if' not in h:
            count += 1
print(count)
")
check "pre-tool-use-bash-rules.sh 의 unconditional entry 0개 (실측 ${UNCONDITIONAL})" \
  "[ ${UNCONDITIONAL} -eq 0 ]"

# 2. pre-tool-use-bash-rules.sh 가 13 hot-path entry 로 등록됨
HOTPATH_COUNT=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
count = 0
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('command', '').endswith('pre-tool-use-bash-rules.sh') and 'if' in h:
            count += 1
print(count)
")
check "pre-tool-use-bash-rules.sh 의 hot-path entry 26개 — 13 hot path × bare+args (실측 ${HOTPATH_COUNT})" \
  "[ ${HOTPATH_COUNT} -eq 26 ]"

# 2b. bare + args 패턴 양쪽 모두 등록되었는지 검증 (Round 1 codex-review NEEDS-FIX 대응)
HOT_PATHS=("pytest" "npm test" "yarn test" "pnpm test" "npm run test" "cargo build" "docker build" "playwright" "make" "tsc" "python -m pytest" "npx jest" "npx vitest")
for cmd in "${HOT_PATHS[@]}"; do
  BARE=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
target = 'Bash(${cmd})'
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('if') == target and h.get('command', '').endswith('pre-tool-use-bash-rules.sh'):
            print('FOUND')
            break
")
  ARGS=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
target = 'Bash(${cmd} *)'
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('if') == target and h.get('command', '').endswith('pre-tool-use-bash-rules.sh'):
            print('FOUND')
            break
")
  check "hot path '${cmd}' bare entry 존재" "[ '${BARE}' = 'FOUND' ]"
  check "hot path '${cmd}' args entry 존재" "[ '${ARGS}' = 'FOUND' ]"
done

# 3. pre-tool-use-bash-bootstrap-gate.sh 가 always-on 유지 (if 필드 없는 entry 1개)
BOOTSTRAP_UNCONDITIONAL=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
count = 0
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('command', '').endswith('pre-tool-use-bash-bootstrap-gate.sh') and 'if' not in h:
            count += 1
print(count)
")
check "pre-tool-use-bash-bootstrap-gate.sh always-on 유지 (실측 ${BOOTSTRAP_UNCONDITIONAL} unconditional entry)" \
  "[ ${BOOTSTRAP_UNCONDITIONAL} -eq 1 ]"

# 4. pre-bash-safety-guard.sh 가 always-on 유지
SAFETY_UNCONDITIONAL=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
count = 0
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('command', '').endswith('pre-bash-safety-guard.sh') and 'if' not in h:
            count += 1
print(count)
")
check "pre-bash-safety-guard.sh always-on 유지 (실측 ${SAFETY_UNCONDITIONAL} unconditional entry)" \
  "[ ${SAFETY_UNCONDITIONAL} -eq 1 ]"

# 5. 모든 if 패턴이 Bash(<pattern> *) 형식
INVALID_IF=$(python3 -c "
import json, re
d = json.load(open('${HOOKS_JSON}'))
pattern = re.compile(r'^Bash\(.+\)$')
invalid = 0
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if 'if' in h:
            if not pattern.match(h['if']):
                invalid += 1
print(invalid)
")
check "모든 if 필드가 Bash(<pattern> *) 형식 (실측 invalid=${INVALID_IF})" \
  "[ ${INVALID_IF} -eq 0 ]"

# 6. HK-2 의 13 entry 도 그대로 존재 (회귀 방지 — test-commit-gate)
TEST_COMMIT_GATE_COUNT=$(python3 -c "
import json
d = json.load(open('${HOOKS_JSON}'))
count = 0
for block in d.get('hooks', {}).get('PreToolUse', []):
    if block.get('matcher') != 'Bash':
        continue
    for h in block.get('hooks', []):
        if h.get('command', '').endswith('pre-bash-test-commit-gate.sh') and 'if' in h:
            count += 1
print(count)
")
check "HK-2 의 pre-bash-test-commit-gate.sh 13 entry 유지 (실측 ${TEST_COMMIT_GATE_COUNT})" \
  "[ ${TEST_COMMIT_GATE_COUNT} -eq 13 ]"

echo ""
echo "==== Summary: ${PASS} PASS, ${FAIL} FAIL ===="
if [ "${FAIL}" -gt 0 ]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
