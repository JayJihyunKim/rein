#!/usr/bin/env bash
# tests/agents/test-plan-verification-cost.sh
#
# 검증 비용 규칙 사이클(PVC) 회귀: 계획 작성 절차·plan-writer·barrier·규칙·
# 코드 리뷰어·리뷰 래퍼 두 사본에 spec §6.1 의 리터럴이 있는지(또는 없는지) 단언한다.
# bash 3.2 호환. 리터럴 매칭은 전부 grep -F.
set -u
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P="$REPO_ROOT/plugins/rein-core"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# 파일이 없으면 단언 하나를 FAIL 로 센다. 있으면 0 반환.
need_file() {
  if [ -f "$1" ]; then
    return 0
  fi
  fail "$2 (파일 없음: $1)"
  return 1
}

assert_present() { # file literal
  need_file "$1" "present '$2'" || return 0
  if grep -q -F -- "$2" "$1"; then pass "$(basename "$1") has '$2'"; else fail "$(basename "$1") missing '$2'"; fi
}

assert_absent() { # file literal
  need_file "$1" "absent '$2'" || return 0
  local n
  n=$(grep -c -F -- "$2" "$1")
  if [ "$n" -eq 0 ]; then pass "$(basename "$1") lacks '$2'"; else fail "$(basename "$1") still has '$2' (count=$n)"; fi
}

assert_count() { # file literal n
  need_file "$1" "count '$2'" || return 0
  local n
  n=$(grep -c -F -- "$2" "$1")
  if [ "$n" -eq "$3" ]; then pass "$(basename "$1") has '$2' x$3"; else fail "$(basename "$1") '$2' count=$n (expected $3)"; fi
}

assert_order() { # file lit_a lit_b
  need_file "$1" "order '$2' < '$3'" || return 0
  local a b
  a=$(grep -n -F -- "$2" "$1" | head -n 1 | cut -d: -f1)
  b=$(grep -n -F -- "$3" "$1" | head -n 1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    pass "$(basename "$1") order '$2' (L$a) < '$3' (L$b)"
  else
    fail "$(basename "$1") order '$2' (L${a:-none}) < '$3' (L${b:-none})"
  fi
}

# 영역 추출은 줄 시작 앵커로만 한다(문서 안의 교차 참조 문구가 영역을 일찍 여는 것을 막는다).
# 기본: 마커가 열 1 에서 시작. 5번째 인자 trim 이면 앞 공백을 제거한 줄 기준.
assert_region_present() { # file start_literal end_literal literal [trim]
  need_file "$1" "region '$2'..'$3' has '$4'" || return 0
  local region mode="${5:-col1}"
  region=$(awk -v s="$2" -v e="$3" -v mode="$mode" '
    function hit(m,   line) {
      line = $0
      if (mode == "trim") sub(/^[ \t]+/, "", line)
      return index(line, m) == 1
    }
    !on && hit(s) { on = 1; print; next }
    on { print; if (hit(e)) exit }
  ' "$1")
  if [ -z "$region" ]; then
    fail "$(basename "$1") region '$2'..'$3' 없음"
    return 0
  fi
  if printf '%s\n' "$region" | grep -q -F -- "$4"; then
    pass "$(basename "$1") region '$2'..'$3' has '$4'"
  else
    fail "$(basename "$1") region '$2'..'$3' missing '$4'"
  fi
}

# 특정 literal 을 포함한 줄 중 anchor 로 시작하는 줄 안에 literal 이 있는지
assert_line_starting_with() { # file prefix literal
  need_file "$1" "line starting '$2' has '$3'" || return 0
  if grep -F -- "$2" "$1" | grep -F -- "$3" | grep -q -F -- "$3"; then
    local ok=0 line
    while IFS= read -r line; do
      case "$line" in
        "$2"*) case "$line" in *"$3"*) ok=1 ;; esac ;;
      esac
    done < <(grep -F -- "$2" "$1")
    if [ "$ok" -eq 1 ]; then pass "$(basename "$1") line starting '$2' has '$3'"; return 0; fi
  fi
  fail "$(basename "$1") line starting '$2' missing '$3'"
}

echo "=== test-plan-verification-cost ==="

# ---------------------------------------------------------------------
echo ""
echo "[1] writing-plans-procedure.md"
F="$P/docs/writing-plans-procedure.md"
assert_absent "$F" 'all prior tests still pass'
assert_absent "$F" 'Commit: `feat(scope)'
assert_absent "$F" 'Frequent commits'
assert_absent "$F" '근거 있는 범위 추정'
assert_present "$F" '## 검증 비용 규칙'
assert_present "$F" '## 검증 계획'
assert_present "$F" 'Run targeted tests'
assert_present "$F" 'Commit at barriers'
assert_present "$F" '5. **Verification cost**'
assert_present "$F" '같은 코드 상태'
assert_present "$F" '미측정'
assert_present "$F" '전체 테스트 재실행으로 돌아가는 조건'
assert_region_present "$F" '## 검증 비용 규칙' '## Self-review' '복귀 조건을 명시한 재실행은 제외'
assert_line_starting_with "$F" '5. **Verification cost**' '복귀 조건을 명시한 재실행은 제외'

# ---------------------------------------------------------------------
echo ""
echo "[2] agents/plan-writer.md"
F="$P/agents/plan-writer.md"
assert_present "$F" '## 검증 비용 (plan 작성 시 필수)'
assert_present "$F" '하한'
assert_present "$F" 'rein-affected-tests.py'
assert_present "$F" '복귀 조건을 명시한 재실행은 제외'
assert_order "$F" '## 검증 비용 (plan 작성 시 필수)' '## 담당 아님 (경계)'

# ---------------------------------------------------------------------
echo ""
echo "[3] skills/parallel-execute/SKILL.md"
F="$P/skills/parallel-execute/SKILL.md"
assert_present "$F" '**테스트 범위**: 웨이브 델타가 닿는 테스트만'
assert_present "$F" '전체 테스트 재실행으로 돌아가는 조건'
assert_present "$F" '웨이브당 1커밋'

# ---------------------------------------------------------------------
echo ""
echo "[4] agents/orchestrator.md"
F="$P/agents/orchestrator.md"
assert_count "$F" '<!-- anchor:barrier-procedure -->' 1
assert_count "$F" '<!-- /anchor:barrier-procedure -->' 1
assert_region_present "$F" '<!-- anchor:barrier-procedure -->' '<!-- /anchor:barrier-procedure -->' '웨이브 델타가 닿는 테스트' trim
assert_region_present "$F" '<!-- anchor:barrier-procedure -->' '<!-- /anchor:barrier-procedure -->' '전체 테스트 재실행으로 돌아가는 조건' trim

# ---------------------------------------------------------------------
echo ""
echo "[5] rules/testing.md"
F="$P/rules/testing.md"
assert_present "$F" '## 검증 실행 범위'
assert_present "$F" '같은 코드 상태에서 전체 검사는 최대 1회'
assert_present "$F" '전체 포맷·린트·타입검사'
assert_present "$F" '미측정'
assert_present "$F" '전체 테스트 재실행으로 돌아가는 조건'
assert_absent "$F" '근거 있는 범위 추정'

# ---------------------------------------------------------------------
echo ""
echo "[6] rules/short/testing-summary.md"
F="$P/rules/short/testing-summary.md"
assert_present "$F" 'one full check per code state'
assert_present "$F" 'unless a full-rerun condition applies'

# ---------------------------------------------------------------------
echo ""
echo "[7] rules/operating-sequence.md"
F="$P/rules/operating-sequence.md"
S='## 작업 운영 원칙'
E='## DoD 의무 섹션 (Step 2)'
assert_region_present "$F" "$S" "$E" '5. **승인된 계획서의 과한 검증은 멈추고 제안한다**'
assert_region_present "$F" "$S" "$E" '조용히 무시하거나 덮어쓰지 않는다'
assert_region_present "$F" "$S" "$E" '복귀 조건을 명시한 재실행은 제외'

# ---------------------------------------------------------------------
echo ""
echo "[8] rules/short/operating-sequence-summary.md"
F="$P/rules/short/operating-sequence-summary.md"
assert_present "$F" 'stop and propose a plan edit'
assert_present "$F" 'no full-rerun condition'

# ---------------------------------------------------------------------
echo ""
echo "[9] skills/code-reviewer/SKILL.md"
F="$P/skills/code-reviewer/SKILL.md"
S='### Spec-review fallback 분기'
E='### PASS 시 v2 발급'
assert_region_present "$F" "$S" "$E" 'Verification Cost'
assert_region_present "$F" "$S" "$E" '복귀 조건을 명시한 재실행은 위반이 아니다'
assert_region_present "$F" "$S" "$E" '이전 실행 기록을 인용하지 않은 모든 소요 수치(단일값·범위·추정)는 NEEDS-FIX'
assert_region_present "$F" "$S" "$E" '참고사항이다'
assert_region_present "$F" "$S" "$E" '`for design:` prefix 와 코드 리뷰 경로에는 적용하지 않는다'

# ---------------------------------------------------------------------
echo ""
echo "[10] rein-codex-review.sh (두 사본)"
W1="$P/scripts/rein-codex-review.sh"
W2="$REPO_ROOT/scripts/rein-codex-review.sh"
for F in "$W1" "$W2"; do
  assert_present "$F" 'SPEC_REVIEW_KIND=""'
  assert_present "$F" 'SPEC_REVIEW_KIND="plan"'
  assert_present "$F" 'SPEC_REVIEW_KIND="design"'
  assert_present "$F" '4. Verification Cost (계획 문서 전용)'
  assert_present "$F" '세 축(계획 문서는 검증 비용 포함)'
  assert_region_present "$F" '4. Verification Cost (계획 문서 전용)' 'SLOTS' '복귀 조건을 명시한 재실행은 위반이 아니다' trim
  assert_region_present "$F" '4. Verification Cost (계획 문서 전용)' 'SLOTS' '참고사항으로 적고 verdict 를 승격시키지 않는다' trim
  assert_region_present "$F" '4. Verification Cost (계획 문서 전용)' 'SLOTS' '이전 실행 기록을 인용하지 않은 모든 소요 수치(단일값·범위·추정)는 NEEDS-FIX' trim
done
if [ -f "$W1" ] && [ -f "$W2" ]; then
  if cmp -s "$W1" "$W2"; then pass "두 래퍼 사본 바이트 동일"; else fail "두 래퍼 사본이 다름"; fi
else
  fail "두 래퍼 사본 바이트 동일 (파일 없음)"
fi

# ---------------------------------------------------------------------
echo ""
echo "=== 결과: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
