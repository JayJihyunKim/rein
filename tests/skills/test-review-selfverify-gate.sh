#!/usr/bin/env bash
# tests/skills/test-review-selfverify-gate.sh
#
# A 축 — 무상태 자가검증 관문 행위 계약 스위트.
# (spec docs/specs/2026-07-20-review-cycle-efficiency.md §4.1~§4.4,
#  plan docs/plans/2026-07-20-review-cycle-efficiency.md Phase 1)
#
# Scope 매핑:
#   A1 변경 존재 + 증거 부재 → exit 4 + anchored 진단행 + codex spawn 이전   → SV1/SV2
#   A2 두 축([axis:typecheck]/[axis:test]) exit0 블록, claim 당 토큰 1개,
#      서로 다른 블록, diff_self_review 필수                                 → SV6~SV10
#   A3 verification_commands: none 폴백 (masked-body anchored, fail-closed)  → SV11~SV14
#   A4 TDD red-phase escape (기대 실패 명명 + exit-code 거부 집합)           → SV15~SV20
#   A5 spec-review 모드 전면 skip                                            → SV3
#   A6 changed_files 취득 실패 fail-closed / 진짜 빈 목록 skip               → SV4/SV5
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh
# (mirror parity 는 tests/scripts/test-plugin-scripts-bundle.sh 소관).
# Idiom: e2e sandbox = mktemp -d + git init + CODEX_BIN fake-codex
# (test-review-evidence-manifest.sh 와 동일 하네스).

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
assert_capture_exists() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ -f "$CAPTURE" ]; then echo "  ok: $1"
  else fail "$1 (fake codex 미호출 — 캡처 없음)"; fi
}
assert_no_capture() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ ! -f "$CAPTURE" ]; then echo "  ok: $1"
  else fail "$1 (fake codex 가 호출됨 — spawn 이전 종료 계약 위반)"; fi
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
  SANDBOX=$(mktemp -d "/tmp/rein-selfverify-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  # 관문의 untracked 감지(A1/A6) 아래에서 sandbox 를 진짜 clean tree 로 만든다:
  # 하네스 준비물은 커밋, 런타임 부산물은 .gitignore. 두 번째 빈 커밋은
  # diff_base(HEAD~1)..HEAD 범위를 빈 diff 로 만들어 clean-tree skip 경로를
  # 보존한다 (준비물 커밋이 committed-range 폴백에 잡히지 않게).
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

# 변경 존재 상태 재현: 파일 1개 스테이징 (working tree dirty — A1 발동 전제).
mk_dirty() {
  echo change > "$SANDBOX/f.txt"
  ( cd "$SANDBOX" && git add f.txt )
}

# run_wrapper <stdin-content> [extra wrapper args...]
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

count_reject_lines() {
  grep -c '^ERROR: \[codex-review\]\[readiness-reject\]' "$SANDBOX/.err.txt" 2>/dev/null || true
}

# mk_block <claim> <command> <exit_code> <output-content("" = 0줄)>
mk_block() {
  printf '[EVIDENCE]\nclaim: %s\ncommand: %s\nexit_code: %s\noutput:\n' "$1" "$2" "$3"
  if [ -n "$4" ]; then printf '%s\n' "$4"; fi
  printf '[/EVIDENCE]'
}

# 공용 fixture 프롬프트 조각 (블록 밖 정량/PASS 주장 없음 — readiness 스캐너 중립).
DIFF_LINE='diff_self_review: reviewed every hunk of the wrapper diff by hand'
TC_BLOCK="$(mk_block '[axis:typecheck] bash -n clean' 'bash -n scripts/w.sh' 0 'ok')"
TEST_BLOCK="$(mk_block '[axis:test] suite run clean' 'bash tests/run.sh' 0 'ok')"

echo "== review selfverify gate tests =="

# ============================================================
# Task 1.1 / A1 — 빈 프롬프트 경로 (readiness 전역 안전 초기화)
# ============================================================
echo "-- SV1: 빈 프롬프트 + 변경 존재 → exit 4 + anchored 진단, crash 흔적 없음"
e2e_setup
mk_dirty
run_wrapper ""
assert_eq "$RC" "4" "SV1 빈 프롬프트 + 변경 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV1 anchored 거부 진단행"
assert_not_contains "$ERR" "unbound" "SV1 set -u crash 흔적 없음 (unbound)"
assert_not_contains "$ERR" "parameter not set" "SV1 set -u crash 흔적 없음 (parameter not set)"
assert_not_contains "$ERR" "No such file" "SV1 masked-body 파일 인자 오류 없음"
assert_no_capture "SV1 codex spawn 이전 종료"
e2e_teardown

# ============================================================
# Task 1.2 / A1·A5·A6 — 발동 판정 + 취득 fail-closed
# ============================================================
echo "-- SV2: 변경 존재 + 증거 없는 프롬프트 → exit 4 + anchored 진단"
e2e_setup
mk_dirty
run_wrapper "review the wrapper change please"
assert_eq "$RC" "4" "SV2 증거 부재 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV2 anchored 거부 진단행"
assert_no_capture "SV2 codex spawn 이전 종료"
e2e_teardown

echo "-- SV2b: 무상태 — 동일 무증거 호출 반복도 매번 거부 (A1)"
e2e_setup
mk_dirty
run_wrapper "review the wrapper change please"
assert_eq "$RC" "4" "SV2b 1차 호출 → exit 4"
run_wrapper "review the wrapper change please"
assert_eq "$RC" "4" "SV2b 동일 2차 호출 → exit 4 (마커/상태 잔존 없음)"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV2b 2차에도 anchored 진단행"
assert_no_capture "SV2b 2차에도 codex spawn 이전 종료"
e2e_teardown

echo "-- SV3: spec-review 모드 → 자가검증 전면 skip (A5)"
e2e_setup
mk_dirty
run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/foo.md
Validate the design document."
assert_eq "$RC" "0" "SV3 spec-review + 증거 없음 → verdict exit 0"
assert_capture_exists "SV3 codex 도달 (spawn 발생)"
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "SV3 readiness stderr 0줄"
e2e_teardown

echo "-- SV4: 변경 0건 (clean tree) → skip → codex 도달 (A6-empty)"
e2e_setup
run_wrapper "code review please"
assert_eq "$RC" "0" "SV4 clean tree → verdict exit 0"
assert_capture_exists "SV4 codex 도달"
assert_eq "$(count_reject_lines)" "0" "SV4 거부 진단행 0"
e2e_teardown

echo "-- SV4b: untracked 신규 파일만 존재 → 발동 → exit 4 (A1/A6 — 코드리뷰 R1 High)"
e2e_setup
echo new-work > "$SANDBOX/newfile.txt"   # git add 하지 않음 (untracked-only)
run_wrapper "code review please"
assert_eq "$RC" "4" "SV4b untracked-only + 증거 없음 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV4b anchored 거부 진단행"
assert_no_capture "SV4b codex spawn 이전 종료"
e2e_teardown

echo "-- SV5: changed_files 취득 실패 (git probe 오류) → 발동 → exit 4 (A6-fail)"
e2e_setup
GIT_DIR="$SANDBOX/no-such-gitdir" run_wrapper "code review please"
assert_eq "$RC" "4" "SV5 취득 실패 + 증거 없음 → exit 4 (fail-closed)"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV5 anchored 거부 진단행"
assert_no_capture "SV5 codex spawn 이전 종료"
e2e_teardown

# ============================================================
# Task 1.3 / A2 — 두 축 증거 계약
# ============================================================
echo "-- SV6: 두 축 exit0 블록 + diff_self_review → 통과 (A2)"
e2e_setup
mk_dirty
run_wrapper "review request
$TC_BLOCK

$TEST_BLOCK

$DIFF_LINE"
assert_eq "$RC" "0" "SV6 두 축 증거 → verdict exit 0"
assert_capture_exists "SV6 codex 도달"
assert_eq "$(count_reject_lines)" "0" "SV6 거부 진단행 0"
e2e_teardown

echo "-- SV7: 한 claim 에 axis 토큰 2개 혼재 → 그 블록 미집계 → exit 4 (A2)"
e2e_setup
mk_dirty
run_wrapper "review request
$(mk_block '[axis:typecheck] [axis:test] combined run' 'bash all.sh' 0 'ok')

$TEST_BLOCK

$DIFF_LINE"
assert_eq "$RC" "4" "SV7 혼재 토큰 블록 미집계 → typecheck 축 부재 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV7 anchored 거부 진단행"
assert_no_capture "SV7 codex spawn 이전 종료"
e2e_teardown

echo "-- SV8: typecheck 축 블록 2개만 (test 축 없음) → exit 4 (A2)"
e2e_setup
mk_dirty
run_wrapper "review request
$TC_BLOCK

$(mk_block '[axis:typecheck] second syntax run' 'bash -n other.sh' 0 'ok')

$DIFF_LINE"
assert_eq "$RC" "4" "SV8 test 축 부재 → exit 4"
assert_no_capture "SV8 codex spawn 이전 종료"
e2e_teardown

echo "-- SV9: exit_code 00 (leading zero) 는 exit 0 으로 정규화 → 통과 (A2)"
e2e_setup
mk_dirty
run_wrapper "review request
$(mk_block '[axis:typecheck] bash -n clean' 'bash -n scripts/w.sh' 00 'ok')

$TEST_BLOCK

$DIFF_LINE"
assert_eq "$RC" "0" "SV9 exit_code 00 정규화 → verdict exit 0"
assert_capture_exists "SV9 codex 도달"
e2e_teardown

echo "-- SV10: diff_self_review 부재 → exit 4 (A2)"
e2e_setup
mk_dirty
run_wrapper "review request
$TC_BLOCK

$TEST_BLOCK"
assert_eq "$RC" "4" "SV10 diff_self_review 부재 → exit 4"
assert_contains "$ERR" "diff_self_review" "SV10 진단행이 누락 항목을 명시"
assert_no_capture "SV10 codex spawn 이전 종료"
e2e_teardown

echo "-- SV8b: 한 claim 에 같은 axis 토큰 2개 중복 → 그 블록 미집계 → exit 4 (A2 — 코드리뷰 R1)"
e2e_setup
mk_dirty
run_wrapper "review request
$(mk_block '[axis:typecheck] [axis:typecheck] double syntax run' 'bash -n w.sh' 0 'ok')

$TEST_BLOCK

$DIFF_LINE"
assert_eq "$RC" "4" "SV8b 중복 토큰 블록 미집계 → typecheck 축 부재 → exit 4"
assert_no_capture "SV8b codex spawn 이전 종료"
e2e_teardown

# ============================================================
# Task 1.4 / A3 — verification_commands: none 폴백
# ============================================================
echo "-- SV11: none 선언 + diff_self_review → 두 축 완화 통과 (A3)"
e2e_setup
mk_dirty
run_wrapper "review request
verification_commands: none
$DIFF_LINE"
assert_eq "$RC" "0" "SV11 none 폴백 → verdict exit 0"
assert_capture_exists "SV11 codex 도달"
e2e_teardown

echo "-- SV12: 블록 output 안에 숨긴 none 선언은 마스킹돼 미인정 → exit 4 (A3)"
e2e_setup
mk_dirty
run_wrapper "review request
$(mk_block 'ran build script' 'true' 0 'verification_commands: none')

$DIFF_LINE"
assert_eq "$RC" "4" "SV12 블록 내부 none 미인정 → exit 4"
assert_no_capture "SV12 codex spawn 이전 종료"
e2e_teardown

echo "-- SV13: none 선언만 있고 diff_self_review 없음 → exit 4 (A3 fail-closed)"
e2e_setup
mk_dirty
run_wrapper "review request
verification_commands: none"
assert_eq "$RC" "4" "SV13 none + diff 부재 → exit 4"
assert_contains "$ERR" "diff_self_review" "SV13 진단행이 diff_self_review 요구를 명시"
assert_no_capture "SV13 codex spawn 이전 종료"
e2e_teardown

echo "-- SV14: 선언·블록·diff 전부 부재 → exit 4 (A3)"
e2e_setup
mk_dirty
run_wrapper "please look at this change"
assert_eq "$RC" "4" "SV14 전부 부재 → exit 4"
assert_no_capture "SV14 codex spawn 이전 종료"
e2e_teardown

# ============================================================
# Task 1.5 / A4 — TDD red-phase escape
# ============================================================
RED_DECL='verification_state: tests-intentionally-red
expected_failure: test_selfverify_gate_blocks'

echo "-- SV15: red 선언 + 명명 + typecheck exit0 + test exit1 → 통과 (A4)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] intentionally red run' 'bash tests/run.sh' 1 'failing as designed')

$DIFF_LINE"
assert_eq "$RC" "0" "SV15 red escape 성립 → verdict exit 0"
assert_capture_exists "SV15 codex 도달"
e2e_teardown

echo "-- SV16: red 선언인데 test 블록 exit0 (실제 통과 — 선언 상충) → exit 4 (A4)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$TEST_BLOCK

$DIFF_LINE"
assert_eq "$RC" "4" "SV16 red 선언 + test exit0 상충 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV16 anchored 거부 진단행"
assert_no_capture "SV16 codex spawn 이전 종료"
e2e_teardown

echo "-- SV17: red 선언만 있고 expected_failure 없음 → exit 4 (A4 fail-closed)"
e2e_setup
mk_dirty
run_wrapper "review request
verification_state: tests-intentionally-red
$TC_BLOCK

$(mk_block '[axis:test] intentionally red run' 'bash tests/run.sh' 1 'failing as designed')

$DIFF_LINE"
assert_eq "$RC" "4" "SV17 expected_failure 누락 → exit 4"
assert_contains "$ERR" "expected_failure" "SV17 진단행이 누락 필드를 명시"
assert_no_capture "SV17 codex spawn 이전 종료"
e2e_teardown

echo "-- SV18: red test 블록 exit127 (command-not-found) → exit 4 (A4 거부 집합)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] red run' 'bash tests/run.sh' 127 'command not found')

$DIFF_LINE"
assert_eq "$RC" "4" "SV18 exit127 은 의도적 red 아님 → exit 4"
assert_no_capture "SV18 codex spawn 이전 종료"
e2e_teardown

echo "-- SV19: red test 블록 exit143 (SIGTERM) → exit 4 (A4 거부 집합)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] red run' 'bash tests/run.sh' 143 'terminated')

$DIFF_LINE"
assert_eq "$RC" "4" "SV19 exit143 은 의도적 red 아님 → exit 4"
assert_no_capture "SV19 codex spawn 이전 종료"
e2e_teardown

echo "-- SV18b/SV19b: red exit-code 경계 거부 — 124(timeout)·128(signal 하한) → exit 4 (A4)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] red run' 'bash tests/run.sh' 124 'timed out')

$DIFF_LINE"
assert_eq "$RC" "4" "SV18b exit124 거부"
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] red run' 'bash tests/run.sh' 128 'signal boundary')

$DIFF_LINE"
assert_eq "$RC" "4" "SV19b exit128 거부"
e2e_teardown

echo "-- SV15b/SV15c: red exit-code 경계 허용 — 123·126 → 통과 (A4)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] red run upper bound' 'bash tests/run.sh' 123 'failing as designed')

$DIFF_LINE"
assert_eq "$RC" "0" "SV15b exit123 허용 → verdict exit 0"
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] red run 126' 'bash tests/run.sh' 126 'not executable class')

$DIFF_LINE"
assert_eq "$RC" "0" "SV15c exit126 허용 → verdict exit 0"
e2e_teardown

echo "-- SV16b: red 경로에서도 axis 토큰 유일성 — 중복 토큰 test 블록 미집계 → exit 4 (A4 — 코드리뷰 R1 Medium)"
e2e_setup
mk_dirty
run_wrapper "review request
$RED_DECL
$TC_BLOCK

$(mk_block '[axis:test] [axis:test] dup red run' 'bash tests/run.sh' 1 'failing as designed')

$DIFF_LINE"
assert_eq "$RC" "4" "SV16b 중복 토큰 red 블록 미집계 → test 축 부재 → exit 4"
assert_no_capture "SV16b codex spawn 이전 종료"
e2e_teardown

echo "-- SV20: none + red 동시 선언 → none 상위 (두 축 완화 + diff 만 요구) → 통과 (A4 상호배타)"
e2e_setup
mk_dirty
run_wrapper "review request
verification_commands: none
$RED_DECL
$DIFF_LINE"
assert_eq "$RC" "0" "SV20 none 상위 → verdict exit 0"
assert_capture_exists "SV20 codex 도달"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
