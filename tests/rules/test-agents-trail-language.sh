#!/bin/bash
# tests/rules/test-agents-trail-language.sh
# Task 3.5 (S8) — AGENTS.md trail/docs 작성 언어 규칙 존재 검증
#
# Scope IDs covered:
#   - S8

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_FILE="$PROJECT_DIR/AGENTS.md"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-agents-trail-language.sh"
echo ""

# Test 1: 사용자 대화 언어 따르기 규칙 존재
echo "### Test 1: trail/docs 작성 시 사용자 대화 언어 규칙 존재"
if grep -q "사용자 대화 언어" "$AGENTS_FILE"; then
  _pass "사용자 대화 언어 규칙 존재"
else
  _fail "사용자 대화 언어 규칙 없음"
fi

# Test 2: agent-authored 범위 명시
echo "### Test 2: agent-authored 기록 범위 명시"
if grep -q "agent-authored" "$AGENTS_FILE"; then
  _pass "agent-authored 범위 명시"
else
  _fail "agent-authored 범위 미명시"
fi

# Test 3: bootstrap/hook/script 제외 명시 (범위 경계)
echo "### Test 3: bootstrap/hook/script 생성 텍스트 제외 범위 명시"
if grep -qE "bootstrap.*hook.*script|hook.*script.*bootstrap|bootstrap.*(i18n|언어 규칙).*(밖|제외)" "$AGENTS_FILE"; then
  _pass "bootstrap/hook/script 제외 범위 명시"
else
  _fail "bootstrap/hook/script 제외 범위 미명시"
fi

# Test 4: trail/ 경로가 규칙 본문에 등장
echo "### Test 4: trail/ 경로가 규칙 본문에 등장"
if grep -q "trail/" "$AGENTS_FILE"; then
  _pass "trail/ 경로 언급"
else
  _fail "trail/ 경로 미언급"
fi

# Test 5: docs/ 경로가 규칙 본문에 등장
echo "### Test 5: docs/ 경로가 규칙 본문에 등장"
if grep -q "docs/" "$AGENTS_FILE"; then
  _pass "docs/ 경로 언급"
else
  _fail "docs/ 경로 미언급"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
