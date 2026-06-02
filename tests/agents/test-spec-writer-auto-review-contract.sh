#!/usr/bin/env bash
# tests/agents/test-spec-writer-auto-review-contract.sh
#
# Phase 3 Task 3.1 regression: spec-writer.md 의 자동 리뷰 계약을 잠근다.
# spec 작성 후 자동 codex-review 경로(SW-1)·프롬프트 첫 줄 경로 규약(SW-2)·
# 표식 스크립트 plugin-root 우선 경로(SW-3)·self-fix loop 부재(SW-4)·
# spec-review stamp 분리(SW-8) 의 본문 토큰을 6 assertion 으로 검증한다.
#
# 주의: coverage-matrix validator 의 **실행 호출** 만 금지한다(assertion c).
# 본문이 "validator 단계 없음" 을 산문으로 명시하는 것은 허용 — 실행 명령
# 패턴(python3/bash ... rein-validate-coverage-matrix.py)만 차단한다.
#
# Scope ID: SW-7 (spec-writer-auto-review-contract)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

AGENT="plugins/rein-core/agents/spec-writer.md"

PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

echo "=== test-spec-writer-auto-review-contract ==="

# -----------------------------------------------------------------------
# (0) agent file presence — 부재 시 즉시 FAIL exit
# -----------------------------------------------------------------------
echo ""
echo "[0] spec-writer.md presence"

if [ -f "$AGENT" ]; then
  pass "$AGENT exists"
else
  fail "$AGENT MISSING"
  echo ""
  echo "======================================"
  echo "PASS: $PASS  FAIL: $FAIL"
  echo "SOME CHECKS FAILED"
  exit 1
fi

# -----------------------------------------------------------------------
# (a) spec review for design: prefix 사용
# -----------------------------------------------------------------------
echo ""
echo "[a] 'spec review for design:' prefix"

if grep -qF "spec review for design:" "$AGENT"; then
  pass "contains 'spec review for design:' prefix"
else
  fail "MISSING 'spec review for design:' prefix"
fi

# -----------------------------------------------------------------------
# (b) rein-mark-spec-reviewed.sh 호출 지시 존재
# -----------------------------------------------------------------------
echo ""
echo "[b] 'rein-mark-spec-reviewed.sh' invocation"

if grep -qF "rein-mark-spec-reviewed.sh" "$AGENT"; then
  pass "contains 'rein-mark-spec-reviewed.sh'"
else
  fail "MISSING 'rein-mark-spec-reviewed.sh'"
fi

# -----------------------------------------------------------------------
# (c) coverage validator 실행 호출 미사용
#     invocation 패턴만 차단; 부재 설명 산문은 허용
# -----------------------------------------------------------------------
echo ""
echo "[c] coverage validator invocation ABSENT (prose mention allowed)"

if ! grep -qE '(python3|bash)[^[:space:]]*[[:space:]]+[^[:space:]]*rein-validate-coverage-matrix\.py' "$AGENT"; then
  pass "no rein-validate-coverage-matrix.py execution invocation"
else
  fail "validator execution invocation present (only prose mention allowed)"
fi

# -----------------------------------------------------------------------
# (d) self-fix loop 부재 명시 — 'self-fix' + 부재 문맥('없음') 인접
# -----------------------------------------------------------------------
echo ""
echo "[d] self-fix loop absence STATED"

if grep -qF "self-fix" "$AGENT"; then
  if grep -qE 'self-fix[^[:alnum:]]*loop[^。.\n]*없음|self-fix[^。.\n]*없음' "$AGENT"; then
    pass "'self-fix' present with absence context ('없음')"
  else
    fail "'self-fix' present but absence context ('없음' adjacency) NOT found"
  fi
else
  fail "MISSING 'self-fix' absence statement"
fi

# -----------------------------------------------------------------------
# (e) 프롬프트 첫 줄 = 경로 규약(SW-2) — '첫 줄' + '경로' 토큰 공존
# -----------------------------------------------------------------------
echo ""
echo "[e] prompt first-line = path convention (SW-2)"

if grep -qF "첫 줄" "$AGENT" && grep -qF "경로" "$AGENT"; then
  pass "both '첫 줄' and '경로' tokens present"
else
  fail "MISSING '첫 줄' and/or '경로' token (first-line path convention)"
fi

# -----------------------------------------------------------------------
# (f) 표식 스크립트 plugin-root 우선 경로(SW-3)
# -----------------------------------------------------------------------
echo ""
echo "[f] marker script plugin-root precedence (SW-3)"

if grep -qF '${CLAUDE_PLUGIN_ROOT' "$AGENT"; then
  pass 'contains ${CLAUDE_PLUGIN_ROOT prefix'
else
  fail 'MISSING ${CLAUDE_PLUGIN_ROOT prefix'
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "======================================"
TOTAL=$((PASS + FAIL))
echo "PASS: $PASS  FAIL: $FAIL  ($PASS/$TOTAL PASS)"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
