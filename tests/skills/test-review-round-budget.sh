#!/usr/bin/env bash
# tests/skills/test-review-round-budget.sh
#
# 리뷰 회차 예산 스위트 (DoD trail/dod/dod-2026-08-04-review-scope-and-round-budget.md).
#
# 배경: 회차 상한이 산문 지시로만 존재해 두 번 무력화됐다 (13회차 무보고 연속
# 실행 / 종결 명령 후 5회차 폭주). 래퍼에는 회차 카운터도 상한도 없었고,
# SKILL.md 가 서술하던 `review_round` 도장 필드는 실제로 존재하지 않았다.
# 본 스위트는 예산을 코드 계약으로 고정한다.
#
# 검증 축:
#   RB1 미통과 회차가 누적 계수된다
#   RB2 상한 도달 후 호출은 codex 미실행 + 전용 종료코드 + 앵커 진단
#   RB3 호출자 연장 선언 시 통과 + 연장 사실이 기록·경고로 남음 (조용한 연장 불가)
#   RB4 사전검사에서 거부된 호출은 회차를 소모하지 않는다
#   RB5 서로 다른 사이클 키는 독립 계수
#   RB6 통과(PASS)로 사이클이 끝나면 카운터가 제거된다
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh.
# Idiom: e2e sandbox + FAKE_CODEX_CAPTURE (행위 기반 — 실제 실행 + 종료코드/
# 파일 상태 단언. 함수 source 후 내부 변수만 보는 방식은 금지).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER_SRC="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

# 예산 초과 전용 종료코드 (기존 사용: 0 PASS / 1 NEEDS-FIX / 2 REJECT·fatal /
# 3 codex 실행 실패 / 4 요청서 사전검사 거부 / 5 워치독 정지).
EXIT_BUDGET=6
# 카운터를 신뢰할 수 없는 상태(디렉토리 쓰기 불가·count 손상) 전용. 예산 소진과
# 구분해야 호출자가 인프라 복구 대신 사람 핸드오프로 오분류하지 않는다.
EXIT_UNAVAILABLE=7

TEST_COUNT=0
FAIL_COUNT=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" = "$2" ]; then echo "  ok: $3"
  else fail "$3 (expected='$2' got='$1')"; fi
}
assert_contains() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    *"$2"*) echo "  ok: $3" ;;
    *) fail "$3 (missing '$2')" ;;
  esac
}
assert_not_contains() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    *"$2"*) fail "$3 (unexpected '$2')" ;;
    *) echo "  ok: $3" ;;
  esac
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
  SANDBOX=$(mktemp -d "/tmp/rein-roundbudget-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir" "$SANDBOX/docs/specs"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  for n in a b; do
    cat > "$SANDBOX/docs/specs/sample-$n.md" <<DOC
# 샘플 설계 문서 $n

## Scope Items

| Scope ID | 설명 |
|---|---|
| \`sample-$n-does-thing-when-condition\` | 조건 시 동작 |
DOC
  done
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

# 카운터 디렉토리에 기록된 회차 값 (키 하나만 있는 경우) — 없으면 빈 문자열.
counter_count_for() {
  local needle="$1" f
  for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
    [ -f "$f" ] || continue
    if grep -qF -- "$needle" "$f" 2>/dev/null; then
      grep -E '^count=' "$f" | head -1 | sed 's/^count=//'
      return 0
    fi
  done
  printf ''
}
counter_file_count() {
  local n=0 f
  for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

NEEDS_FIX_BODY='리뷰 본문.
FINAL_VERDICT: NEEDS-FIX'
PASS_BODY='리뷰 본문.
FINAL_VERDICT: PASS'

PROMPT_A='[NON_INTERACTIVE] spec review for design: docs/specs/sample-a.md
Validate technical soundness.'
PROMPT_B='[NON_INTERACTIVE] spec review for design: docs/specs/sample-b.md
Validate technical soundness.'

echo "== review round budget tests =="

echo "-- RB1: 미통과 회차 누적 계수 (기본 상한 5)"
e2e_setup
i=1
while [ "$i" -le 5 ]; do
  FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
  assert_eq "$RC" "1" "RB1 회차 $i — NEEDS-FIX exit 1 (예산 내)"
  i=$((i + 1))
done
assert_eq "$(counter_count_for 'sample-a.md')" "5" "RB1 카운터가 5회차까지 누적"

echo "-- RB2: 상한 도달 후 호출 — codex 미실행 + 전용 종료코드 + 앵커 진단"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_BUDGET" "RB2 6회차 → 예산 초과 종료코드"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: RB2 codex 미실행 (envelope 캡처 없음)"
else fail "RB2 예산 초과인데 codex 가 실행됨"; fi
assert_contains "$ERR" "ERROR: [codex-review][round-budget-exceeded]" "RB2 앵커 진단행"
assert_eq "$(counter_count_for 'sample-a.md')" "5" "RB2 거부 회차는 카운터를 늘리지 않음"

echo "-- RB3: 호출자 연장 선언 — 통과 + 연장 기록 + 경고 (조용한 연장 불가)"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[MAX_ROUNDS:8]
$PROMPT_A"
assert_eq "$RC" "1" "RB3 연장 선언 후 정상 리뷰 수행"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: RB3 codex 실행됨"
else fail "RB3 연장 선언인데 codex 미실행"; fi
assert_contains "$ERR" "WARNING: [codex-review][round-budget-extended]" "RB3 연장 경고 방출"
assert_eq "$(counter_count_for 'sample-a.md')" "6" "RB3 연장 후 회차 계수 계속"
TEST_COUNT=$((TEST_COUNT + 1))
if grep -qE '^extensions=.*8' "$SANDBOX"/trail/dod/.review-rounds/* 2>/dev/null; then
  echo "  ok: RB3 연장 이력이 카운터 파일에 기록됨"
else fail "RB3 연장 이력 미기록"; fi
e2e_teardown

echo "-- RB4: 사전검사 거부(요청서 형식)는 회차 미소모"
e2e_setup
run_wrapper "구현 완료. 테스트 21건 GREEN 입니다."
assert_eq "$RC" "4" "RB4 무증거 정량 주장 → 사전검사 거부"
assert_eq "$(counter_file_count)" "0" "RB4 거부된 호출은 카운터를 만들지 않음"
e2e_teardown

echo "-- RB5: 서로 다른 사이클 키는 독립 계수"
e2e_setup
i=1
while [ "$i" -le 5 ]; do
  FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
  i=$((i + 1))
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_BUDGET" "RB5 문서 A 는 예산 소진"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_B"
assert_eq "$RC" "1" "RB5 문서 B 는 독립적으로 1회차 통과"
assert_eq "$(counter_count_for 'sample-b.md')" "1" "RB5 문서 B 카운터 독립"
e2e_teardown

echo "-- RB7: 정수가 아닌 마커 표기는 선언이 아니며 본문을 건드리지 않는다"
# 회귀: 스킬·규칙 문서가 마커 문법을 `[MAX_ROUNDS:<n>]` 로 설명하는데, 초기
# 구현이 그 표기까지 strip 해 리뷰 요청서 내용이 조용히 바뀌었다 (본 기능의
# 첫 실전 리뷰에서 실측).
e2e_setup
i=1
while [ "$i" -le 5 ]; do
  FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
  i=$((i + 1))
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A
문서에는 [MAX_ROUNDS:n] 이라고 쓰면 연장된다고 설명돼 있다."
assert_eq "$RC" "$EXIT_BUDGET" "RB7 무효 표기는 연장 효력 없음 — 기본 상한으로 거부"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "code review please
문서에는 [MAX_ROUNDS:n] 이라고 쓰면 연장된다고 설명돼 있다."
assert_eq "$RC" "1" "RB7 무효 표기 자체는 리뷰를 막지 않음 (다른 사이클 키)"
TEST_COUNT=$((TEST_COUNT + 1))
if grep -qF -- "[MAX_ROUNDS:n]" "$CAPTURE" 2>/dev/null; then
  echo "  ok: RB7 무효 표기가 본문에 보존됨 (리뷰어가 원문 그대로 받음)"
else fail "RB7 무효 표기가 본문에서 제거됨 — 요청서 내용이 조용히 바뀐다"; fi
e2e_teardown

echo "-- RB8: 리뷰가 완료되지 않은 종료는 회차를 소모하지 않는다"
# 근거: SKILL.md §4.2 — 워치독 정지(exit 5)·실행 실패는 "리뷰가 수행되지 않았다"
# 이므로 재리뷰 카운트에 포함하지 않는다. 실측 회귀: 초기 구현은 spawn 직전에
# 계수해 타임아웃된 리뷰가 회차를 먹은 채 남았다.
e2e_setup
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
  REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 \
  REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=1 \
  run_wrapper "$PROMPT_A"
assert_eq "$RC" "5" "RB8 워치독 정지 → 전용 종료코드"
assert_eq "$(counter_file_count)" "0" "RB8 정지로 끝난 리뷰는 회차 미소모"
FAKE_CODEX_EXIT=1 run_wrapper "$PROMPT_A"
assert_eq "$(counter_file_count)" "0" "RB8 codex 실행 실패도 회차 미소모"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$(counter_count_for 'sample-a.md')" "1" "RB8 정상 리뷰 이후에야 1회차"
e2e_teardown

echo "-- RB9: 환경변수로 상한을 조용히 올릴 수 없다 (R1 High)"
e2e_setup
i=1
while [ "$i" -le 5 ]; do
  FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
  i=$((i + 1))
done
REIN_ROUND_LIMIT_DEFAULT=999 FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_BUDGET" "RB9 환경변수 상한 override 무효 — 여전히 거부"
e2e_teardown

echo "-- RB10: 카운터 손상은 fail-closed 이며 예산 소진과 구분된다 (R1 High + R2 Medium)"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
  [ -f "$f" ] && printf 'key=x\ncount=corrupt\nlimit=5\n' > "$f"
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB10 손상된 카운터 → 인프라 전용 종료코드 (예산 소진 아님)"
assert_contains "$ERR" "ERROR: [codex-review][round-budget-unavailable]" "RB10 인프라 전용 앵커"
assert_not_contains "$ERR" "round-budget-exceeded" "RB10 예산 소진 앵커와 혼동되지 않음"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: RB10 손상 시 codex 미실행"
else fail "RB10 손상인데 codex 가 실행됨 (fail-open)"; fi
e2e_teardown

echo "-- RB13: 카운터 디렉토리를 쓸 수 없으면 인프라 오류로 중단 (R2 Medium)"
e2e_setup
mkdir -p "$SANDBOX/trail/dod/.review-rounds"
chmod 500 "$SANDBOX/trail/dod/.review-rounds"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB13 쓰기 불가 → 인프라 전용 종료코드"
assert_contains "$ERR" "ERROR: [codex-review][round-budget-unavailable]" "RB13 인프라 전용 앵커"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: RB13 쓰기 불가 시 codex 미실행"
else fail "RB13 예산 강제 불가인데 codex 가 실행됨"; fi
chmod 700 "$SANDBOX/trail/dod/.review-rounds"
e2e_teardown

echo "-- RB11: 콜론 뒤 공백을 포함한 유효 마커도 본문에서 제거된다 (R1 High)"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[MAX_ROUNDS: 8]
$PROMPT_A"
assert_eq "$RC" "1" "RB11 공백 포함 마커 — 문서 리뷰 모드 유지"
TEST_COUNT=$((TEST_COUNT + 1))
if grep -qF -- "MAX_ROUNDS" "$CAPTURE" 2>/dev/null; then
  fail "RB11 유효 마커가 본문에 남아 리뷰어에게 전달됨"
else echo "  ok: RB11 유효 마커가 본문에서 제거됨"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if grep -qF "Decision Soundness" "$CAPTURE" 2>/dev/null; then
  echo "  ok: RB11 문서 리뷰 슬롯이 정상 방출 (모드 감지 무손상)"
else fail "RB11 마커 잔존으로 모드 감지가 깨짐"; fi
e2e_teardown

echo "-- RB12: 같은 키 동시 실행에서 회차가 유실되지 않는다 (R1 High)"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
# 두 리뷰를 동시에 띄운다 — 기록이 판정 시점 값을 그대로 쓰면 최종 카운터가
# 2 에 머문다 (한 건 유실). 재읽기 기반 증가면 3 이 된다.
printf '%s' "$PROMPT_A" > "$SANDBOX/.stdin.txt"
(
  cd "$SANDBOX"
  export CODEX_BIN="$FAKE_CODEX" TMPDIR="$SANDBOX/tmpdir"
  export FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY"
  bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
    < "$SANDBOX/.stdin.txt" >/dev/null 2>&1 &
  bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
    < "$SANDBOX/.stdin.txt" >/dev/null 2>&1 &
  wait
)
assert_eq "$(counter_count_for 'sample-a.md')" "3" "RB12 동시 2건 후 회차 3 (유실 없음)"
e2e_teardown

echo "-- RB14: 같은 문서의 다른 경로 표기는 같은 예산을 쓴다 (R3 High)"
# 우회 실측: `docs/specs/sample-a.md` 와 `./docs/specs/sample-a.md` 가 각각
# 독립된 5회를 받았다. 절대 경로 전환도 같은 우회였다.
e2e_setup
i=1
while [ "$i" -le 3 ]; do
  FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
  i=$((i + 1))
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[NON_INTERACTIVE] spec review for design: ./docs/specs/sample-a.md
Validate."
assert_eq "$(counter_file_count)" "1" "RB14 상대 표기 변형이 새 예산을 만들지 않음"
assert_eq "$(counter_count_for 'sample-a.md')" "4" "RB14 같은 예산에 누적 (3+1)"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[NON_INTERACTIVE] spec review for design: $SANDBOX/docs/specs/sample-a.md
Validate."
assert_eq "$(counter_file_count)" "1" "RB14 절대 경로 표기도 같은 예산"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_BUDGET" "RB14 표기를 바꿔도 상한에 도달한다"
e2e_teardown

echo "-- RB15: 상한 선언은 첫 줄 단독일 때만 인정된다 (R3 High)"
# 우회 실측: 프롬프트 어디에 있든 유효 마커가 선언으로 처리돼, 이전 리뷰 출력을
# 인용하기만 해도 사람 승인 없이 예산이 늘었다.
e2e_setup
i=1
while [ "$i" -le 5 ]; do
  FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
  i=$((i + 1))
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A
직전 리뷰 인용: 사용자는 [MAX_ROUNDS:8] 연장을 승인하지 않았다."
assert_eq "$RC" "$EXIT_BUDGET" "RB15 본문 인용 마커는 연장 효력 없음"
assert_not_contains "$ERR" "round-budget-extended" "RB15 인용만으로 연장 경고가 뜨지 않음"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "code review please
본문 인용: [MAX_ROUNDS:8] 는 첫 줄에서만 유효하다."
assert_eq "$RC" "1" "RB15 인용 마커는 리뷰를 막지 않음 (다른 사이클 키)"
TEST_COUNT=$((TEST_COUNT + 1))
if grep -qF -- "[MAX_ROUNDS:8]" "$CAPTURE" 2>/dev/null; then
  echo "  ok: RB15 본문 인용 마커가 원문 그대로 보존됨"
else fail "RB15 본문 인용 마커가 제거돼 요청서 내용이 바뀜"; fi
e2e_teardown

echo "-- RB16: 파일 심볼릭 링크와 경로 뒤 잔여도 같은 예산으로 모인다 (R4 High)"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
ln -s "$SANDBOX/docs/specs/sample-a.md" "$SANDBOX/docs/specs/link-a.md" 2>/dev/null
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/link-a.md
Validate."
assert_eq "$(counter_file_count)" "1" "RB16 파일 심볼릭 링크가 새 예산을 만들지 않음"
# 경로 뒤에 지시문을 같은 줄에 붙이는 호출 형식도 같은 키여야 한다.
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/sample-a.md Validate technical soundness.
Second line."
assert_eq "$(counter_file_count)" "1" "RB16 한 줄 호출 형식도 같은 예산"
assert_eq "$(counter_count_for 'sample-a.md')" "3" "RB16 세 표기가 한 예산에 누적"
e2e_teardown

echo "-- RB17: 회차 기록 실패는 조용히 통과하지 않는다 (R4 High)"
# 중단된 리뷰가 남긴 잠금 하나로 이후 회차가 계수되지 않으면 상한이 무력화된다.
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
  [ -f "$f" ] && mkdir -p "${f}.lock"
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB17 기록 불가 → 인프라 전용 종료코드 (성공 위장 금지)"
assert_contains "$ERR" "ERROR: [codex-review][round-budget-unavailable]" "RB17 인프라 전용 앵커"
assert_eq "$(counter_count_for 'sample-a.md')" "1" "RB17 기록되지 않은 회차는 증가하지 않음"
for f in "$SANDBOX"/trail/dod/.review-rounds/*.lock; do
  [ -d "$f" ] && rmdir "$f"
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "1" "RB17 잠금 해소 후 정상 복귀"
assert_eq "$(counter_count_for 'sample-a.md')" "2" "RB17 복귀 후 정상 계수"
e2e_teardown

echo "-- RB18: 카운터 경로가 심볼릭 링크면 기록을 거부한다 (보안 리뷰)"
# 실측 재현: 임시 파일명이 고정이라 그 자리에 링크를 심으면 카운터 내용이
# 저장소 밖 파일로 쓰이고, 이어지는 교체가 그 링크를 카운터 자리에 심었다.
# 코드 리뷰 2026-08-05 정정: 이전 판은 외부 파일이 비어 있어 count 손상 검사
# (exit 7)가 링크 검사보다 먼저 발화하는 false-green 이었다 — 링크 검사에
# 실제로 도달하도록 외부 파일에 **유효한 카운터 내용**을 두고, 거부 사유가
# 링크 진단임을 함께 단언한다.
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
OUTSIDE="$SANDBOX/../rein-budget-outside-$$.txt"
printf 'key=probe\ncount=1\nlimit=5\nupdated=2026-08-04T00:00:00Z\nextensions=\n' > "$OUTSIDE"
cp "$OUTSIDE" "$OUTSIDE.orig"
for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
  [ -f "$f" ] && { rm -f "$f"; ln -s "$OUTSIDE" "$f"; }
done
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB18 링크 카운터 → 인프라 전용 종료코드"
assert_contains "$ERR" "심볼릭 링크" "RB18 거부 사유가 링크 진단 (count 손상 경로 아님)"
TEST_COUNT=$((TEST_COUNT + 1))
if cmp -s "$OUTSIDE" "$OUTSIDE.orig"; then echo "  ok: RB18 저장소 밖 파일 무변조"
else fail "RB18 링크를 따라가 외부 파일이 변조됨"; fi
rm -f "$OUTSIDE" "$OUTSIDE.orig"
e2e_teardown

echo "-- RB20: 카운터 디렉토리가 링크면 판정 초입에서 거부한다 (코드 리뷰 2026-08-05 High)"
# 격리 재현: 링크 검사가 미통과 기록 경로에만 있어, PASS 정리(rm -f)가 디렉토리
# 링크를 따라 저장소 밖 해시 파일을 삭제한 뒤 정상 통과했다 (pass_rc=0,
# external_counter=deleted). 여기서는 호출 **이전에** 링크가 설치된 경우를
# 다룬다 — 판정 초입 검사가 mkdir/읽기·codex 실행 이전에 거부해야 한다.
# 리뷰 **도중** 링크로 바뀌는 경우(통과 정리 재검사)는 RB21 이 다룬다.
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
EXTDIR="$SANDBOX/../rein-budget-extdir-$$"
mkdir -p "$EXTDIR"
mv "$SANDBOX"/trail/dod/.review-rounds/* "$EXTDIR"/
rmdir "$SANDBOX/trail/dod/.review-rounds"
ln -s "$EXTDIR" "$SANDBOX/trail/dod/.review-rounds"
EXT_BEFORE=$(ls "$EXTDIR" | wc -l | tr -d ' ')
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB20 디렉토리 링크 → PASS verdict 설정이어도 인프라 전용 종료코드"
assert_contains "$ERR" "심볼릭 링크" "RB20 거부 사유가 링크 진단"
assert_eq "$(ls "$EXTDIR" | wc -l | tr -d ' ')" "$EXT_BEFORE" "RB20 저장소 밖 해시 파일 보존"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: RB20 판정 초입 거부 — codex 미실행 (envelope 캡처 없음)"
else fail "RB20 링크 상태인데 codex 가 실행됨 (초입 검사 미발화)"; fi
rm -rf "$EXTDIR"
e2e_teardown

echo "-- RB21: 리뷰 도중 카운터 디렉토리가 링크로 바뀌면 통과 정리가 거부한다 (코드 리뷰 2026-08-05 R2)"
# clear 재검사 경로의 실행 오라클: 판정 초입 검사는 정상 디렉토리를 보고
# 통과시키고, fake codex 가 verdict 방출 직전(= 래퍼의 통과 정리 이전)에
# 디렉토리를 외부 링크로 바꾼다. code-review 모드라 통과 표식 생성 직전
# 경로가 실제로 실행된다 — exit 7 + 외부 보존 + 표식 미생성이어야 한다.
e2e_setup
cat > "$SANDBOX/trail/dod/dod-2026-08-05-rb21.md" <<'DOD'
# DoD: RB21 clear 재검사
- slug: rb21-clear-recheck
DOD
echo "path=trail/dod/dod-2026-08-05-rb21.md" > "$SANDBOX/trail/dod/.active-dod"
CODE_PROMPT='code review please
verification_commands: none
diff_self_review: harness fixture pass'
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$(counter_file_count)" "1" "RB21 사전 미통과 회차로 카운터 존재"
EXTDIR="$SANDBOX/../rein-budget-extdir-live-$$"
SWAP_CMD="mkdir -p '$EXTDIR' && mv '$SANDBOX'/trail/dod/.review-rounds/* '$EXTDIR'/ && rmdir '$SANDBOX/trail/dod/.review-rounds' && ln -s '$EXTDIR' '$SANDBOX/trail/dod/.review-rounds'"
FAKE_CODEX_VERDICT="$PASS_BODY" FAKE_CODEX_PRE_VERDICT_CMD="$SWAP_CMD" run_wrapper "$CODE_PROMPT"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB21 도중 링크 전환 → 통과 정리 거부 (인프라 전용 종료코드)"
assert_contains "$ERR" "심볼릭 링크" "RB21 거부 사유가 링크 진단"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: RB21 codex 실행에 도달함 (초입 검사는 통과 — clear 재검사가 오라클)"
else fail "RB21 codex 미실행 — clear 경로가 아니라 초입에서 걸러짐"; fi
assert_eq "$(ls "$EXTDIR" | wc -l | tr -d ' ')" "1" "RB21 저장소 밖 해시 파일 보존"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]; then echo "  ok: RB21 통과 표식 미생성 (정리 실패가 표식보다 먼저 중단)"
else fail "RB21 정리 실패인데 통과 표식이 생성됨"; fi
rm -rf "$EXTDIR"
e2e_teardown

echo "-- RB19: 대상 문자열의 와일드카드가 파일명으로 확장되지 않는다 (보안 리뷰)"
# 실측: 인용 없는 확장으로 "sample-*.md 를 검토하라" 가 경고 없이 특정 파일
# 한 건으로 좁혀져 리뷰 대상과 예산 키가 조용히 바뀌었다.
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/sample-*.md 를 검토하라
Validate."
TEST_COUNT=$((TEST_COUNT + 1))
if grep -qF -- "sample-a.md" "$SANDBOX"/trail/dod/.review-rounds/* 2>/dev/null; then
  fail "RB19 와일드카드가 실제 파일명으로 확장돼 대상이 바뀜"
else echo "  ok: RB19 와일드카드가 확장되지 않음 (대상 문자열 보존)"; fi
e2e_teardown

echo "-- RB22: 통과 정리는 자신이 획득하지 않은 활성 락을 지우지 않는다 (코드 리뷰 2026-08-05 R3)"
# R2 High 의 직접 회귀 오라클: 이전 결함 판에서는 clear 가 락 없이 rmdir 을
# 실행해, 다른 프로세스의 commit 이 쥔(비어 있는) 락 디렉토리를 제거하고
# 카운터를 지운 뒤 통과 표식까지 작성했다. 수리 후에는 락 대기 초과 →
# exit 7 + 카운터·기존 락 보존 + 표식 미생성이어야 한다.
e2e_setup
cat > "$SANDBOX/trail/dod/dod-2026-08-05-rb22.md" <<'DOD'
# DoD: RB22 clear 락 소유권
- slug: rb22-clear-lock-ownership
DOD
echo "path=trail/dod/dod-2026-08-05-rb22.md" > "$SANDBOX/trail/dod/.active-dod"
CODE_PROMPT='code review please
verification_commands: none
diff_self_review: harness fixture pass'
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$(counter_file_count)" "1" "RB22 사전 미통과 회차로 카운터 존재"
for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
  [ -f "$f" ] && mkdir -p "${f}.lock"
done
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$RC" "$EXIT_UNAVAILABLE" "RB22 활성 락 존재 시 통과 정리 거부 (인프라 전용 종료코드)"
assert_contains "$ERR" "락을 얻지 못해 통과 정리" "RB22 거부 사유가 락 미획득 진단"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: RB22 codex 실행에 도달함 (clear 경로가 오라클)"
else fail "RB22 codex 미실행 — clear 경로에 도달하지 못함"; fi
assert_eq "$(counter_count_for 'rb22')" "1" "RB22 카운터 보존 (남의 락 아래에서 삭제 금지)"
TEST_COUNT=$((TEST_COUNT + 1))
LOCK_ALIVE=0
for f in "$SANDBOX"/trail/dod/.review-rounds/*.lock; do
  [ -d "$f" ] && LOCK_ALIVE=1
done
if [ "$LOCK_ALIVE" = "1" ]; then echo "  ok: RB22 자신이 획득하지 않은 락 보존"
else fail "RB22 남의 활성 락이 제거됨 (R2 High 회귀)"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]; then echo "  ok: RB22 통과 표식 미생성"
else fail "RB22 정리 실패인데 통과 표식이 생성됨"; fi
e2e_teardown

echo "-- RB6: 통과로 사이클 종료 시 카운터 제거"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$PROMPT_A"
assert_eq "$(counter_count_for 'sample-a.md')" "1" "RB6 미통과 1회차 계수"
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$PROMPT_A"
assert_eq "$RC" "0" "RB6 통과 → exit 0"
assert_eq "$(counter_file_count)" "0" "RB6 통과 후 카운터 제거 (사이클 종료)"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
