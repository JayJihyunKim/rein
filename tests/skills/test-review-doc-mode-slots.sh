#!/usr/bin/env bash
# tests/skills/test-review-doc-mode-slots.sh
#
# 문서 리뷰 판정 계약 스위트 (DoD trail/dod/dod-2026-08-04-review-scope-and-round-budget.md).
#
# 배경: build_envelope() 에 리뷰 모드 분기가 없어, 설계·계획 문서 리뷰에도
# 코드 리뷰 슬롯("resource leak 을 찾아라", "Test Alignment")이 그대로 방출됐다.
# 리뷰어가 계획서를 놓고 파일 핸들 수명주기를 소송한 것은 지시받은 그대로 수행한
# 결과다. 본 스위트는 모드별 슬롯 분기와 문서 판정 규율 3종을 고정한다.
#
# 검증 축:
#   DM1 문서 모드 — 코드 결함 슬롯 미방출
#   DM2 문서 모드 — 테스트 정합 슬롯 미방출
#   DM3 문서 모드 — 결정 건전성 / 범위 추적성 슬롯 방출
#   DM4 문서 모드 — 판정 규율 3종(심도-계층 / 결함 족 일괄 / 근거 출처 분리) 방출
#   DM5 문서 모드 — 주장 감사 슬롯은 유지
#   DM6 코드 모드 — 4슬롯 전부 유지 + 문서 규율 문구 미방출 (무회귀)
#   DM7 plan/design 두 문서 마커 모두 동일 적용
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh.
# Idiom: e2e sandbox + FAKE_CODEX_CAPTURE envelope 캡처
# (test-review-envelope-reduction.sh 와 동일 하네스 — 행위 기반. 함수 source 후
#  내부 변수만 보는 방식은 금지: SCRIPT_DIR 오염으로 false-green 이 난 전례).

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
  SANDBOX=$(mktemp -d "/tmp/rein-docmode-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir" "$SANDBOX/docs/specs"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  cat > "$SANDBOX/docs/specs/sample.md" <<'DOC'
# 샘플 설계 문서

## Scope Items

| Scope ID | 설명 |
|---|---|
| `sample-does-thing-when-condition` | 조건 시 동작 |
DOC
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

DESIGN_PROMPT='[NON_INTERACTIVE] spec review for design: docs/specs/sample.md
Validate technical soundness, scope coverage, and brainstorm alignment.'
PLAN_PROMPT='[NON_INTERACTIVE] spec review for plan: docs/specs/sample.md
Validate coverage matrix.'

echo "== review doc-mode slot contract tests =="

echo "-- DM1/DM2: 문서 리뷰 — 코드 결함·테스트 정합 슬롯 미방출"
e2e_setup
run_wrapper "$DESIGN_PROMPT"
assert_eq "$RC" "0" "DM1 문서 리뷰 PASS → exit 0"
assert_file_no_grep "Code defects and regressions" "$CAPTURE" "DM1 코드 결함 슬롯 미방출"
assert_file_no_grep "resource leak" "$CAPTURE" "DM1 자원 누수 지시문 미방출"
assert_file_no_grep "Test Alignment" "$CAPTURE" "DM2 테스트 정합 슬롯 미방출"

echo "-- DM3: 문서 리뷰 — 결정 건전성 / 범위 추적성 슬롯 방출"
assert_file_grep "Decision Soundness" "$CAPTURE" "DM3 결정 건전성 슬롯 방출"
assert_file_grep "Scope & Traceability" "$CAPTURE" "DM3 범위 추적성 슬롯 방출"

echo "-- DM4: 문서 리뷰 — 판정 규율 3종 방출"
assert_file_grep "문서 리뷰 판정 축" "$CAPTURE" "DM4 판정 축 선언 방출"
assert_file_grep "구현 단계 이관" "$CAPTURE" "DM4 (i) 심도-계층 — 구현 결함은 이관 advisory"
assert_file_grep "일괄 열거" "$CAPTURE" "DM4 (ii) 결함 족 일괄 열거"
assert_file_grep "저장소 계약 위반" "$CAPTURE" "DM4 (iii) 근거 출처 분리"

echo "-- DM5: 문서 리뷰 — 주장 감사 슬롯은 유지"
assert_file_grep "Claim Audit" "$CAPTURE" "DM5 주장 감사 슬롯 유지"

echo "-- DM7a: plan 마커도 동일 적용"
run_wrapper "$PLAN_PROMPT"
assert_eq "$RC" "0" "DM7a plan 문서 리뷰 PASS → exit 0"
assert_file_no_grep "Code defects and regressions" "$CAPTURE" "DM7a plan 모드 코드 슬롯 미방출"
assert_file_grep "Decision Soundness" "$CAPTURE" "DM7a plan 모드 결정 건전성 슬롯 방출"
e2e_teardown

echo "-- DM8: 코드 리뷰 envelope 전문 골든 비교 (공백·개행·순서 회귀 포착)"
# 문자열 존재 검사만으로는 공백·개행·슬롯 순서 회귀를 잡지 못한다 (R1 Medium).
# 실행마다 달라지는 커밋 해시·타임스탬프만 정규화하고 나머지를 전량 대조한다.
# 골든 갱신은 의도적 변경일 때만: REIN_GOLDEN_UPDATE=1 로 재실행.
GOLDEN="$REAL_PROJECT_DIR/tests/fixtures/envelope-code-review.golden"
normalize_envelope() {
  sed -E 's/[0-9a-f]{40}/<SHA>/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}/<ISO>/g' "$1"
}
e2e_setup
run_wrapper "code review please"
if [ "${REIN_GOLDEN_UPDATE:-}" = "1" ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  normalize_envelope "$CAPTURE" > "$GOLDEN"
  echo "  (골든 갱신됨: $GOLDEN)"
fi
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$GOLDEN" ]; then
  fail "DM8 골든 파일 부재 ($GOLDEN) — REIN_GOLDEN_UPDATE=1 로 생성하라"
elif diff -u "$GOLDEN" <(normalize_envelope "$CAPTURE") >/dev/null 2>&1; then
  echo "  ok: DM8 코드 리뷰 envelope 이 골든과 전량 일치"
else
  fail "DM8 코드 리뷰 envelope 이 골든과 다름 — 아래 diff 확인 후 의도적 변경이면 REIN_GOLDEN_UPDATE=1"
  diff -u "$GOLDEN" <(normalize_envelope "$CAPTURE") | head -20 >&2
fi
e2e_teardown

echo "-- DM6: 코드 리뷰 모드 무회귀 — 4슬롯 유지 + 문서 규율 미방출"
e2e_setup
run_wrapper "code review please"
assert_eq "$RC" "0" "DM6 코드 리뷰 PASS → exit 0"
assert_file_grep "Code defects and regressions" "$CAPTURE" "DM6 코드 결함 슬롯 유지"
assert_file_grep "Design Alignment" "$CAPTURE" "DM6 설계 정합 슬롯 유지"
assert_file_grep "Test Alignment" "$CAPTURE" "DM6 테스트 정합 슬롯 유지"
assert_file_grep "Claim Audit" "$CAPTURE" "DM6 주장 감사 슬롯 유지"
assert_file_no_grep "Decision Soundness" "$CAPTURE" "DM6 문서용 슬롯 미유입"
assert_file_no_grep "문서 리뷰 판정 축" "$CAPTURE" "DM6 문서 규율 미유입"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
