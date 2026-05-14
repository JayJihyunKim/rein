#!/bin/bash
# tests/rules/test-test-oracle-state-init.sh
# Plan B Phase 5 Task 5.1 — test-oracle.json 초기 상태 파일 + gitignore + branch-strategy.
#
# Scope IDs covered:
#   - TO-rollout-warn-first-independent-of-spec-a-stage

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE="$PROJECT_DIR/.claude/.rein-state/test-oracle.json"
GITIGNORE="$PROJECT_DIR/.gitignore"
BRANCH="$PROJECT_DIR/.claude/rules/branch-strategy.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-test-oracle-state-init.sh"
echo ""

echo "### Test 1: test-oracle.json 파일 존재"
if [ -f "$STATE" ]; then
  _pass "test-oracle.json 존재"
else
  _fail "test-oracle.json 없음"
fi

echo "### Test 2: JSON 파싱 가능"
if python3 -c "import json; json.load(open('$STATE'))" 2>/dev/null; then
  _pass "JSON 파싱 성공"
else
  _fail "JSON 파싱 실패"
fi

echo "### Test 3: severity_hard: false 초기값"
if python3 -c "
import json, sys
d = json.load(open('$STATE'))
sys.exit(0 if d.get('severity_hard') is False else 1)
" 2>/dev/null; then
  _pass "severity_hard=false 초기값"
else
  _fail "severity_hard 초기값 틀림"
fi

echo "### Test 4: .gitignore 에 test-oracle.json 관련 entry"
# Spec A gov.json 과 동일 패턴: /.claude/.rein-state/ 로 디렉토리 전체 ignore.
# 이 entry 가 이미 있으므로 test-oracle.json 도 자동 ignore 됨.
if grep -q '/.claude/.rein-state/' "$GITIGNORE"; then
  _pass ".gitignore 에 /.claude/.rein-state/ 디렉토리 ignore"
else
  _fail ".gitignore 에 .rein-state 항목 없음"
fi

echo "### Test 5: branch-strategy.md 에 test-oracle.json 언급 or .rein-state 제외"
if grep -qE '\.rein-state|test-oracle\.json' "$BRANCH"; then
  _pass "branch-strategy.md 제외 목록에 포함"
else
  _fail "branch-strategy.md 제외 목록 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
