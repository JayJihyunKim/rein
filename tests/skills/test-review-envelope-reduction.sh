#!/usr/bin/env bash
# tests/skills/test-review-envelope-reduction.sh
#
# C 축 — 통과답변 출력축소 envelope 계약 스위트.
# (spec docs/specs/2026-07-20-review-cycle-efficiency.md §4.5,
#  plan docs/plans/2026-07-20-review-cycle-efficiency.md Phase 2)
#
# Scope 매핑:
#   C1 MATCH 항목 = 검사수/통과수 한 줄 요약, 발견은 전량 상세          → ER1
#   C2 입력 없는 섹션 생략 지시                                        → ER2
#   C4 REIN_REVIEW_VERBOSE=1 → 전량 서술 복원 (감사 모드)              → ER3
#   C5 축소 envelope 에 네 검사 지시문 전부 존재 (정적)                → ER4
#   C3 FINAL_VERDICT tail-match parser + PASS 도장 + verdict exit 불변 → ER5
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh.
# Idiom: e2e sandbox + FAKE_CODEX_CAPTURE envelope 캡처
# (test-review-evidence-manifest.sh 와 동일 하네스). sandbox 는 clean tree —
# A 축 자가검증 관문은 변경 0건 skip 경로로 자연 통과 (계약 간섭 없음).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER_SRC="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

TEST_COUNT=0
FAIL_COUNT=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" = "$2" ]; then echo "  ok: $3"
  else fail "$3 (expected='$2' got='$1')"; fi
}
assert_file_grep() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qF -- "$1" "$2" 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (pattern '$1' not in $2)"; fi
}
assert_file_no_grep() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qF -- "$1" "$2" 2>/dev/null; then fail "$3 (unexpected '$1' in $2)"
  else echo "  ok: $3"; fi
}

find_lib() {
  if [ -f "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  elif [ -f "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  fi
}
LIB="$(find_lib)"
[ -n "$LIB" ] || { echo "FATAL: select-active-dod.sh not found" >&2; exit 1; }
LIB_DIR="$(dirname "$LIB")"

SANDBOX=""
cleanup() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

e2e_setup() {
  SANDBOX=$(mktemp -d "/tmp/rein-envreduce-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  # 자가검증 관문의 untracked 감지 아래에서 clean tree 를 보존 — 준비물 커밋 +
  # 부산물 .gitignore + 빈 head 커밋(committed-range 폴백 빈 diff 유지).
  cat > "$SANDBOX/.gitignore" <<'IGN'
.gitignore
.stdin.txt
.out.txt
.err.txt
.capture*
tmpdir/
trail/
.claude/cache/
IGN
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git add -A && git commit -q -m base \
    && git commit --allow-empty -q -m head )
}
e2e_teardown() {
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

RC=""; OUT=""; ERR=""; CAPTURE=""
run_wrapper() {
  local stdin_content="$1"; shift
  CAPTURE="$SANDBOX/.capture.txt"
  rm -f "$CAPTURE"
  printf '%s' "$stdin_content" > "$SANDBOX/.stdin.txt"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$CAPTURE"
    export TMPDIR="$SANDBOX/tmpdir"
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive "$@" \
      < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
  )
  RC=$?
  OUT=$(cat "$SANDBOX/.out.txt")
  ERR=$(cat "$SANDBOX/.err.txt")
}

echo "== review envelope reduction tests =="

echo "-- ER1: 축소 모드(기본) — MATCH 카운트 요약 + 발견 전량 상세 지시 (C1)"
e2e_setup
run_wrapper "code review please"
assert_eq "$RC" "0" "ER1 verdict PASS → exit 0"
assert_file_grep "출력 밀도 (기본 — 축소)" "$CAPTURE" "ER1 축소 모드 지시 블록 존재"
assert_file_grep "한 줄 요약" "$CAPTURE" "ER1 MATCH 카운트 요약 지시"
assert_file_grep "전량 상세" "$CAPTURE" "ER1 발견(High/Medium) 전량 상세 지시"
assert_file_grep "축소 금지" "$CAPTURE" "ER1 발견 축소 금지 지시"

echo "-- ER2: 입력 없는 섹션 생략 지시 (C2)"
assert_file_grep "입력 없는 섹션" "$CAPTURE" "ER2 빈 섹션 생략 지시"
e2e_teardown

echo "-- ER3: REIN_REVIEW_VERBOSE=1 → 전량 서술 복원, 축소 지시 부재 (C4)"
e2e_setup
REIN_REVIEW_VERBOSE=1 run_wrapper "code review please"
assert_eq "$RC" "0" "ER3 verbose 모드 verdict exit 0"
assert_file_grep "감사 모드" "$CAPTURE" "ER3 감사 모드(전량 서술) 지시 존재"
assert_file_grep "전량 서술" "$CAPTURE" "ER3 전량 서술 복원 지시"
assert_file_no_grep "출력 밀도 (기본 — 축소)" "$CAPTURE" "ER3 축소 지시 블록 부재"
e2e_teardown

echo "-- ER4: 축소 envelope 에 네 검사 지시문 전부 존재 — 정적 검사 (C5)"
e2e_setup
run_wrapper "code review please"
assert_file_grep "Code defects and regressions" "$CAPTURE" "ER4 결함 검출 지시문 존재"
assert_file_grep "Design Alignment" "$CAPTURE" "ER4 설계 정합 지시문 존재"
assert_file_grep "Test Alignment" "$CAPTURE" "ER4 테스트 정합 지시문 존재"
assert_file_grep "Claim Audit" "$CAPTURE" "ER4 주장 검증 지시문 존재"
e2e_teardown

echo "-- ER5: FINAL_VERDICT tail-match + PASS 도장 + verdict exit 계약 불변 (C3)"
e2e_setup
# 본문 앞쪽 인용 FINAL_VERDICT 는 결론이 아니다 — 마지막 줄 tail-match 가 이긴다.
FAKE_CODEX_VERDICT='분석 본문. 인용 예시: FINAL_VERDICT: REJECT (예시일 뿐)
상세 서술 계속.
FINAL_VERDICT: PASS' run_wrapper "code review please"
assert_eq "$RC" "0" "ER5 tail FINAL_VERDICT: PASS → exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$SANDBOX/trail/dod/.codex-reviewed" ]; then echo "  ok: ER5 PASS → 도장 생성"
else fail "ER5 PASS 인데 .codex-reviewed 미생성"; fi
rm -f "$SANDBOX/trail/dod/.codex-reviewed"
FAKE_CODEX_VERDICT='본문.
FINAL_VERDICT: NEEDS-FIX' run_wrapper "code review please"
assert_eq "$RC" "1" "ER5 FINAL_VERDICT: NEEDS-FIX → exit 1"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]; then echo "  ok: ER5 NEEDS-FIX → 도장 미생성"
else fail "ER5 NEEDS-FIX 인데 도장 생성됨"; fi
FAKE_CODEX_VERDICT='본문.
FINAL_VERDICT: REJECT' run_wrapper "code review please"
assert_eq "$RC" "2" "ER5 FINAL_VERDICT: REJECT → exit 2"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
