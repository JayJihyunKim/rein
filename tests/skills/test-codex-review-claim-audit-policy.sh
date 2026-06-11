#!/bin/bash
# tests/skills/test-codex-review-claim-audit-policy.sh
# Plan B Phase 3 Task 3.3 — Claim Audit slot policy (wrapper).
#
# Scope IDs covered:
#   - TO-claim-audit-numeric-mapping-policy

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_DIR/scripts/rein-codex-review.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-codex-review-claim-audit-policy.sh"
echo ""

echo "### Test 1: Numeric claim 매핑 문구"
if grep -q "Claim 에 숫자가 포함" "$WRAPPER"; then
  _pass "Numeric claim 조건 명시"
else
  _fail "Numeric claim 조건 없음"
fi

echo "### Test 2: 1:1 mapping 명시"
if grep -q "1:1 mapping" "$WRAPPER"; then
  _pass "1:1 mapping 명시"
else
  _fail "1:1 mapping 없음"
fi

echo "### Test 3: 기능 이름 claim 조건"
if grep -q "기능 이름 claim" "$WRAPPER"; then
  _pass "기능 이름 claim 문구 있음"
else
  _fail "기능 이름 claim 문구 없음"
fi

echo "### Test 4: Matrix deferred 행 사유 체크"
if grep -q "Matrix .deferred. 행" "$WRAPPER"; then
  _pass "Matrix deferred 체크 명시"
else
  _fail "Matrix deferred 체크 없음"
fi

echo "### Test 5: Claim source 우선순위 문구"
if grep -q "Claim source 우선순위" "$WRAPPER"; then
  _pass "Claim source 우선순위 명시"
else
  _fail "Claim source 우선순위 없음"
fi

echo "### Test 6: Evidence freshness rule text (claim-audit-hardening)"
if grep -q "Evidence freshness" "$WRAPPER"; then
  _pass "Evidence freshness 문구 있음"
else
  _fail "Evidence freshness 문구 없음"
fi

echo "### Test 7: Claim discrepancy escalation rule text (claim-audit-hardening)"
if grep -q "Claim discrepancy escalation" "$WRAPPER"; then
  _pass "Claim discrepancy escalation 문구 있음"
else
  _fail "Claim discrepancy escalation 문구 없음"
fi

echo "### Test 8: Evidence-freshness degrade marker (anchor-based extraction)"
# Extract Claim Audit slot heredoc block using anchors: from `4. Claim Audit `
# header (column 0) to the slot-region end marker `응답 출력 형식` (column 0).
# This isolates slot-internal text from other (unavailable) usages like
# _resolve_commit_iso fallback that lives above the heredoc.
# ENV-SUBJ (2026-06-11): end anchor 를 `^SLOTS$` 에서 교체 — B5(2026-06-09)부터
# slot 4 가 동적 주입(printf)을 위해 여러 heredoc 으로 분할되어 첫 SLOTS
# 종결자가 sub-item 4 직후에 와 freshness 텍스트(sub-item 5)가 추출 범위 밖
# 으로 빠졌다 (latent fail — skills 묶음이 CI 미등록이라 미관측). 영역 종료
# 표식 기준이면 이후 분할이 늘어도 추출이 안정적이다.
slot_block=$(awk '/^4\. Claim Audit /,/^응답 출력 형식/' "$WRAPPER")
if printf '%s' "$slot_block" | grep -qE "ISO = \(unavailable\)"; then
  _pass "'(unavailable)' degrade 문구가 Claim Audit slot 내부에 명시"
else
  _fail "'(unavailable)' degrade 문구가 Claim Audit slot 에서 찾지 못함"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
