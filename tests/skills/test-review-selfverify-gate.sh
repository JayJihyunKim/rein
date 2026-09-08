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
bin/
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

# ============================================================
# Task 2.1 harness extension (spec §3.4/§6.1/§7 Axis 3) — SV21~SV32.
# ============================================================

# 문서-only dirty 재현: docs/note.md 를 커밋한 뒤 unstaged 로 수정한다
# (스테이징하지 않음 — 스테이징도 unstaged 도 _selfverify_observation_
# consistent 의 재관측(§6.1(3))에서 같은 집합으로 취급되므로 어느 쪽이든
# 무방하지만, "review-before-commit" 관례(2026-06-09 B4)를 따라 unstaged
# 로 둔다).
mk_docs_dirty() {
  mkdir -p "$SANDBOX/docs"
  echo "base note" > "$SANDBOX/docs/note.md"
  ( cd "$SANDBOX" && git add docs/note.md && git commit -q -m "docs note" )
  echo "unstaged edit" >> "$SANDBOX/docs/note.md"
}

# clean 트리 + 커밋 범위(DIFF_BASE..HEAD)에 코드 파일 재현 (§7 (l)).
mk_code_commit() {
  echo "print('x')" > "$SANDBOX/f.py"
  ( cd "$SANDBOX" && git add f.py && git commit -q -m "add f.py" )
}

# fake bin/rein 스텁 — tests/scripts/test-codex-review-evidence-issuance.sh
# ::_mk_fixture_plugin 의 python 스텁에서 `--print-subject` 분기만 남겨
# 복제한다(FAKE_REIN_SUBJECT_JSON 을 stdout 에 그대로 + 개행, 종료코드
# FAKE_REIN_DIGEST_RC, 기본 0). 래퍼 self-location(`$_script_dir/../bin/
# rein`, `$_script_dir` = `$SANDBOX/scripts`)이 `$SANDBOX/bin/rein` 을
# 찾는다 — `.gitignore` 의 `bin/` 항목이 이 스텁을 untracked 관측(A1/A6/
# untracked probe)에서 제외한다.
mk_fake_rein_bin() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/rein" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys


def main():
    argv = sys.argv[1:]
    if len(argv) < 2 or argv[0] != "issue-evidence" or argv[1] != "code_review":
        sys.stderr.write("fake-bin-rein: unsupported invocation: %r\n" % (argv,))
        return 2
    rest = argv[2:]
    if "--print-subject" in rest:
        raw_json = os.environ.get("FAKE_REIN_SUBJECT_JSON", "")
        rc = int(os.environ.get("FAKE_REIN_DIGEST_RC", "0"))
        if raw_json:
            sys.stdout.write(raw_json)
            if not raw_json.endswith("\n"):
                sys.stdout.write("\n")
        return rc
    sys.stderr.write("fake-bin-rein: unrecognized args: %r\n" % (rest,))
    return 2


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "$SANDBOX/bin/rein"
}

# mk_git_shim <subcommand> — 실제 git 을 감싼 shim 디렉토리를 stdout 으로
# 반환한다. `-C <dir>` 를 건너뛴 첫 인자가 <subcommand> 면 exit 128(취득
# 실패 재현), 아니면 실제 git 으로 exec. WRAP_PATH_PREFIX 로 PATH 앞에
# 꽂아 이 subcommand 호출만 골라 실패시킨다(다른 git 호출은 정상 동작).
REAL_GIT="$(command -v git)"
mk_git_shim() {
  local subcmd="$1" dir
  dir=$(mktemp -d "$SANDBOX/gitshim-XXXXXX")
  cat > "$dir/git" <<EOF
#!/usr/bin/env bash
i=0
if [ "\${1:-}" = "-C" ]; then i=2; fi
args=("\$@")
if [ "\${args[\$i]:-}" = "$subcmd" ]; then
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$dir/git"
  printf '%s' "$dir"
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
    # Task 2.1 seam — a git shim (mk_git_shim) prepended ahead of the real
    # git so a single subcommand can be made to fail without touching the
    # rest of the sandbox's git behavior.
    if [ -n "${WRAP_PATH_PREFIX:-}" ]; then export PATH="$WRAP_PATH_PREFIX:$PATH"; fi
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

# Task 2.1 — FAKE_REIN_SUBJECT_JSON 리터럴 (spec §7 Axis 3).
SUBJ_EMPTY_DOCS='{"subject": "empty:no-subject", "paths": [], "changeset_paths": ["docs/note.md"]}'
SUBJ_EMPTY_NOKEY='{"subject": "empty:no-subject", "paths": []}'
SUBJ_EMPTY_CLEAN='{"subject": "empty:no-subject", "paths": [], "changeset_paths": []}'
SUBJ_CODE_F='{"subject": "sha256:0000000000000000000000000000000000000000000000000000000000000000", "paths": ["f.txt"], "changeset_paths": ["f.txt"]}'
SUBJ_CODE_DOCS='{"subject": "sha256:0000000000000000000000000000000000000000000000000000000000000000", "paths": ["docs/note.md"], "changeset_paths": ["docs/note.md"]}'

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
# Task 2.1 / A7 — 문서-only SUBJECT_EMPTY 조기 통과 + 관측 일관성
# (spec §3.4/§6.1(3)/§7 Axis 3)
# ============================================================
echo "-- SV21: 문서-only 변경 + 두 관측 일관(A7) → 자가검증 skip → codex 도달 (typecheck/test 증거 없이)"
e2e_setup
mk_docs_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_DOCS" run_wrapper "code review please"
assert_eq "$RC" "0" "SV21 문서-only + 관측 일관 → verdict exit 0"
assert_capture_exists "SV21 codex 도달 (typecheck/test 증거 없이)"
assert_eq "$(count_reject_lines)" "0" "SV21 거부 진단행 0"
e2e_teardown

echo "-- SV22: 코드 파일이 첫 관측부터 포함(digest) → 여전히 발동 (A7 값 조건 불성립, 회귀)"
e2e_setup
mk_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_CODE_F" run_wrapper "code review please"
assert_eq "$RC" "4" "SV22 코드 subject → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV22 anchored 거부 진단행"
assert_no_capture "SV22 codex spawn 이전 종료"
e2e_teardown

echo "-- SV23: --print-subject 조회 실패(rc!=0) → REIN_REVIEWED_DIGEST=\"\" 는 센티널과 다른 값 → A1 로 발동"
e2e_setup
mk_docs_dirty
mk_fake_rein_bin
FAKE_REIN_DIGEST_RC=1 run_wrapper "code review please"
assert_eq "$RC" "4" "SV23 조회 실패 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV23 anchored 거부 진단행"
assert_no_capture "SV23 codex spawn 이전 종료"
e2e_teardown

echo "-- SV24: 센티널 + changed_files 취득 실패(A6) 동시 → A6 이 A7 보다 먼저 발동 (순서 고정, 행위)"
e2e_setup
mk_docs_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_DOCS" GIT_DIR="$SANDBOX/no-such-gitdir" run_wrapper "code review please"
assert_eq "$RC" "4" "SV24 A6 우선 발동 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV24 anchored 거부 진단행"
assert_no_capture "SV24 codex spawn 이전 종료"
e2e_teardown

echo "-- SV24s: 정적 순서 검사 — _selfverify_should_fire 본문에서 CHANGED_FILES_RC 검사 라인이 empty:no-subject 검사 라인보다, 그것이 -n \"\$CHANGED_FILES\" 검사 라인보다 앞"
sv24s_body=$(awk '/^_selfverify_should_fire\(\)/,/^}/' "$WRAPPER_SRC")
sv24s_a6=$(printf '%s\n' "$sv24s_body" | grep -n 'CHANGED_FILES_RC' | head -1 | cut -d: -f1)
sv24s_a7=$(printf '%s\n' "$sv24s_body" | grep -n 'empty:no-subject' | head -1 | cut -d: -f1)
sv24s_a1=$(printf '%s\n' "$sv24s_body" | grep -n '\-n "\$CHANGED_FILES"' | head -1 | cut -d: -f1)
TEST_COUNT=$((TEST_COUNT + 1))
if [ -n "$sv24s_a6" ] && [ -n "$sv24s_a7" ] && [ -n "$sv24s_a1" ] \
   && [ "$sv24s_a6" -lt "$sv24s_a7" ] && [ "$sv24s_a7" -lt "$sv24s_a1" ]; then
  echo "  ok: SV24s 정적 순서 A6 < A7 < A1"
else
  fail "SV24s 정적 순서 위반 (a6=$sv24s_a6 a7=$sv24s_a7 a1=$sv24s_a1)"
fi

echo "-- SV25: 관측 불일치(추적 파일) — CHANGED_FILES 에 changeset_paths 밖 코드 경로 → 발동"
e2e_setup
mk_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_DOCS" run_wrapper "code review please"
assert_eq "$RC" "4" "SV25 추적 파일 불일치 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV25 anchored 거부 진단행"
assert_no_capture "SV25 codex spawn 이전 종료"
e2e_teardown

echo "-- SV26: 관측 불일치(untracked) — 새 미추적 코드 파일 → 발동 (A7 이 probe 를 가리지 않음)"
e2e_setup
mk_docs_dirty
echo "x" > "$SANDBOX/new.py"
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_DOCS" run_wrapper "code review please"
assert_eq "$RC" "4" "SV26 untracked 불일치 → exit 4"
assert_no_capture "SV26 codex spawn 이전 종료"
e2e_teardown

echo "-- SV27: changeset_paths 키 부재(구 CLI 목) → 발동 (fail-closed)"
e2e_setup
mk_docs_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_NOKEY" run_wrapper "code review please"
assert_eq "$RC" "4" "SV27 키 부재 → exit 4"
assert_no_capture "SV27 codex spawn 이전 종료"
e2e_teardown

echo "-- SV28: untracked 목록 취득 실패(목) → 발동 (fail-closed)"
e2e_setup
mk_docs_dirty
mk_fake_rein_bin
WRAP_PATH_PREFIX="$(mk_git_shim ls-files)" FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_DOCS" run_wrapper "code review please"
assert_eq "$RC" "4" "SV28 untracked 취득 실패 → exit 4"
assert_no_capture "SV28 codex spawn 이전 종료"
e2e_teardown

echo "-- SV29: 반대 방향(subject 가 센티널 아니면 A7 자체가 불성립) → 발동 (SV21 과 문서-only 관측 동일, subject 만 비센티널 → 발동)"
e2e_setup
mk_docs_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_CODE_DOCS" run_wrapper "code review please"
assert_eq "$RC" "4" "SV29 반대 방향 → exit 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "SV29 anchored 거부 진단행"
assert_no_capture "SV29 codex spawn 이전 종료"
e2e_teardown

echo "-- SV30: clean 트리 + 커밋 범위 코드 → subject 센티널이어도 CHANGED_FILES(커밋 범위) ⊄ 빈 집합 → 발동"
e2e_setup
mk_code_commit
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_EMPTY_CLEAN" run_wrapper "code review please"
assert_eq "$RC" "4" "SV30 clean + 커밋 범위 코드 → exit 4"
assert_no_capture "SV30 codex spawn 이전 종료"
e2e_teardown

echo "-- SV31: 개행 포함 파일명 — NUL 안전 부분집합 비교 (개행 분할이었다면 발동했을 것)"
e2e_setup
mkdir -p "$SANDBOX/docs"
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import os,sys; open(os.path.join(sys.argv[1],"docs","a\nb.md"),"w").write("x\n")' "$SANDBOX"
( cd "$SANDBOX" && git add -A && git commit -q -m "newline filename" )
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import os,sys; open(os.path.join(sys.argv[1],"docs","a\nb.md"),"a").write("y\n")' "$SANDBOX"
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON='{"subject": "empty:no-subject", "paths": [], "changeset_paths": ["docs/a\nb.md"]}' run_wrapper "code review please"
assert_eq "$RC" "0" "SV31 개행 파일명 부분집합 일치 → verdict exit 0"
assert_capture_exists "SV31 codex 도달"
e2e_teardown

echo "-- SV32: 발동 시 _selfverify_check 요구 축 무변경 (typecheck 만 있고 test 축 부재 → 여전히 거부 + 문구 동일)"
e2e_setup
mk_dirty
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$SUBJ_CODE_F" run_wrapper "review request
$TC_BLOCK
$DIFF_LINE"
assert_eq "$RC" "4" "SV32 test 축 부재 → exit 4"
assert_contains "$ERR" "[axis:test]" "SV32 진단에 [axis:test] 언급 (SV8 과 같은 문구)"
assert_no_capture "SV32 codex spawn 이전 종료"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
