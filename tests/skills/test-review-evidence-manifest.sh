#!/usr/bin/env bash
# tests/skills/test-review-evidence-manifest.sh
#
# Behavioral suite for the review-readiness precheck + evidence manifest
# (spec docs/specs/2026-07-13-review-evidence-manifest.md, plan Phase 1/4).
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh
# (NOT the root mirror — mirror parity is tests/scripts/test-plugin-scripts-bundle.sh).
#
# spec §8 수용 기준 매핑 (suite 커버 범위 — 11=SKILL.md grep, 12=mirror bundle 은 suite 밖):
#   1  유효 블록 2개 → codex 호출 + envelope 블록 원문 + blocks: 2 + 3필드 요약  → E1
#   2  미폐쇄/필드 누락/비정수 exit_code → exit 4 + codex 미호출 + 사유별 stderr → U2/U3/U4 + E2
#   3  output 61/60줄 + 8000/8001B(다중바이트) + 17/16블록 + fence 예시 미취급   → U9/U10/U11/U12/U13
#   4  "테스트 21건 GREEN" + 블록 0 → exit 4 + 매칭 발췌 + 문법 안내            → S1 + E3
#   5  패턴·블록 0 → readiness stderr 0 + 신규 슬롯 0 + verdict exit 경로       → E5
#   6  블록 1 + "파일 5개" → 비차단 + WARNING + unbacked_quant_flags:           → S2 + E6
#   7  제외 토큰 7종만 → 통과 + 무발화 (+ 21/21 우선순위)                        → S3/S4
#   8  spec-review skip 차등 fixture                                            → E7
#   9  verdict 3종 exit 0/1/2 + PASS stamp + exit 4 경로 stamp 무변화           → E8 + E9
#   10 sub-item 7 존재/부재 + 미방출 시 기존 slot 인접성 보존                    → E1 + E5
#   14 passthrough 판별 3종 (a)(b)(c)                                           → E10/E11/E12
#   +  인프라 실패 2경로 (파서 awk / 스캐너 awk) — non-zero + codex 미호출 +
#      [readiness-reject] 부재 + 임시파일 정리                                   → E14/E15
#   +  [EFFORT:] strip-이후-원문 계약 (EV1 strip 상호작용)                       → E13
#   +  임시파일 trap 정리 3경로 (성공/거부/awk 실패)                             → E1/E3/E14
#
# Idioms: sandbox = mktemp -d + git init + CODEX_BIN fake codex
# (test-codex-review-wrapper.sh), 함수 단위 = source-and-call
# (test-codex-effort-deterministic.sh 의 REIN_PROJECT_DIR_OVERRIDE + source).

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

# ------------------------------------------------------------
# Unit fixture (source-and-call target).
# ------------------------------------------------------------
TMPROOT=$(mktemp -d "/tmp/rein-evmanifest-XXXXXX")
FIX="$TMPROOT/fix"
SANDBOX=""

mk_fixture() {
  local dir="$1"
  mkdir -p "$dir/trail/dod" "$dir/.claude/hooks/lib"
  cp "$LIB" "$dir/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$dir/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  ( cd "$dir" && git init -q && git config user.email t@e.com \
    && git config user.name t && git commit --allow-empty -q -m init )
}
mk_fixture "$FIX"

cleanup() {
  [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

# src_eval <snippet> — source the wrapper (functions only; PROMPT_BODY empty
# via /dev/null stdin, main block guarded by BASH_SOURCE), then eval snippet.
# Caller passes fixture bodies via exported BODY env var.
src_eval() {
  (
    export REIN_PROJECT_DIR_OVERRIDE="$FIX"
    export TMPDIR="$TMPROOT/unit-tmp"
    mkdir -p "$TMPDIR"
    # shellcheck disable=SC1090
    source "$WRAPPER_SRC" </dev/null >/dev/null 2>&1
    set +e; set +u; set +o pipefail
    eval "$1"
  )
}

# parse_all <body> — run _parse_evidence_blocks; emits its stderr + RC/COUNT line.
parse_all() {
  BODY="$1" src_eval 'PROMPT_BODY="$BODY"; _parse_evidence_blocks 2>&1; printf "RC=%s COUNT=%s\n" "$?" "${EVIDENCE_BLOCK_COUNT:-NA}"'
}

# scan_all <body> — parser then scanner; emits stderr + RC/MATCHES/FLAGS.
scan_all() {
  BODY="$1" src_eval 'PROMPT_BODY="$BODY"; _parse_evidence_blocks 2>&1 && _scan_quant_claims 2>&1; printf "RC=%s MATCHES=%s\nFLAGS<<%s>>\n" "$?" "${QUANT_MATCH_COUNT:-NA}" "${QUANT_FLAGS:-}"'
}

# summary_of <body> — parser then EVIDENCE_BLOCK_SUMMARY (3-line records).
summary_of() {
  BODY="$1" src_eval 'PROMPT_BODY="$BODY"; _parse_evidence_blocks 2>/dev/null; printf "%s" "${EVIDENCE_BLOCK_SUMMARY:-}"'
}

# mk_block <claim> <command> <exit_code> <output-content("" = 0줄)>
mk_block() {
  printf '[EVIDENCE]\nclaim: %s\ncommand: %s\nexit_code: %s\noutput:\n' "$1" "$2" "$3"
  if [ -n "$4" ]; then printf '%s\n' "$4"; fi
  printf '[/EVIDENCE]'
}

# ------------------------------------------------------------
# E2E sandbox helpers.
# ------------------------------------------------------------
e2e_setup() {
  SANDBOX=$(mktemp -d "/tmp/rein-evmanifest-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir" "$SANDBOX/docs/plans"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git commit --allow-empty -q -m init )
}
e2e_teardown() {
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# run_wrapper <stdin-content> [extra wrapper args...]
# RC / OUT / ERR / CAPTURE 설정. TMPDIR 는 sandbox 전용 디렉토리로 고정
# (임시파일 정리 assert 용). WRAP_PATH_PREFIX 가 있으면 PATH 선두에 삽입
# (awk 카운터 셔임 주입 seam).
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
    if [ -n "${WRAP_PATH_PREFIX:-}" ]; then export PATH="$WRAP_PATH_PREFIX:$PATH"; fi
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive "$@" \
      < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
  )
  RC=$?
  OUT=$(cat "$SANDBOX/.out.txt")
  ERR=$(cat "$SANDBOX/.err.txt")
}

# 거부 진단행(라인 시작 anchored) 카운트 — 판별 계약과 동일한 검사식.
count_reject_lines() {
  grep -c '^ERROR: \[codex-review\]\[readiness-reject\]' "$SANDBOX/.err.txt" 2>/dev/null || true
}
count_advisory_lines() {
  grep -c '^WARNING: \[codex-review\]\[readiness-advisory\]' "$SANDBOX/.err.txt" 2>/dev/null || true
}
# 래퍼 생성 임시파일 잔존 수 (trap EXIT 정리 검증).
count_tmp_leftovers() {
  find "$SANDBOX/tmpdir" -name 'rein-readiness*' 2>/dev/null | wc -l | tr -d ' '
}

# awk 카운터 셔임 — N번째 awk 호출만 실패시킨다 (인프라 실패 주입).
mk_awk_shim() {
  local realawk
  realawk=$(command -v awk)
  mkdir -p "$SANDBOX/awkshim"
  cat > "$SANDBOX/awkshim/awk" <<SHIM
#!/bin/bash
c=\$(cat "\$AWK_SHIM_COUNT_FILE" 2>/dev/null || echo 0)
c=\$((c+1))
printf '%s' "\$c" > "\$AWK_SHIM_COUNT_FILE"
if [ "\$c" = "\${AWK_SHIM_FAIL_ON:-0}" ]; then
  echo "awk: simulated infra failure" >&2
  exit 42
fi
exec "$realawk" "\$@"
SHIM
  chmod +x "$SANDBOX/awkshim/awk"
}

VALID_BLOCK_PROMPT="review request with evidence

$(mk_block '테스트 21건 GREEN' 'bash tests/skills/run-all.sh' 0 '21 passed, 0 failed')

$(mk_block '파일 2개 변경' 'git diff --name-only' 0 'a.sh
b.sh')"

echo "== review evidence manifest tests =="

# ============================================================
# U — 파서 단위 (Task 1.1)
# ============================================================
echo "-- U1: 유효 블록 2개 파싱"
res=$(parse_all "$VALID_BLOCK_PROMPT")
assert_contains "$res" "RC=0 COUNT=2" "U1 유효 2블록 → rc 0 + count 2"
summ=$(summary_of "$VALID_BLOCK_PROMPT")
assert_contains "$summ" "테스트 21건 GREEN" "U1 summary 에 블록1 claim"
assert_contains "$summ" "bash tests/skills/run-all.sh" "U1 summary 에 블록1 command"
assert_contains "$summ" "파일 2개 변경" "U1 summary 에 블록2 claim"

echo "-- U2: 미폐쇄 블록"
body="prose
[EVIDENCE]
claim: c
command: cmd
exit_code: 0
output:
line"
res=$(parse_all "$body")
assert_contains "$res" "RC=1" "U2 미폐쇄 → rc 1"
assert_contains "$res" "미폐쇄" "U2 사유: 미폐쇄"
assert_contains "$res" "ERROR: [codex-review][readiness-reject]" "U2 진단행 anchored 접두사"

echo "-- U3: 필수 필드 누락"
body="[EVIDENCE]
claim: c
command: cmd
[/EVIDENCE]"
res=$(parse_all "$body")
assert_contains "$res" "RC=1" "U3 필드 누락 → rc 1"
assert_contains "$res" "필수 필드 누락" "U3 사유: 필수 필드 누락"

echo "-- U4: 비정수 exit_code"
res=$(parse_all "$(mk_block c cmd abc 'x')")
assert_contains "$res" "RC=1" "U4 exit_code: abc → rc 1"
assert_contains "$res" "0–255 정수" "U4 사유: 0–255 정수 아님"
res=$(parse_all "$(mk_block c cmd 300 'x')")
assert_contains "$res" "RC=1" "U4b exit_code: 300 → rc 1 (범위 초과)"

echo "-- U5: 고아 [/EVIDENCE]"
res=$(parse_all "prose
[/EVIDENCE]
more")
assert_contains "$res" "RC=1" "U5 고아 폐쇄 마커 → rc 1"
assert_contains "$res" "고아" "U5 사유: 고아"

echo "-- U6: 필드 순서 위반"
body="[EVIDENCE]
command: cmd
claim: c
exit_code: 0
output:
[/EVIDENCE]"
res=$(parse_all "$body")
assert_contains "$res" "RC=1" "U6 순서 위반 → rc 1"
assert_contains "$res" "순서" "U6 사유: 순서"

echo "-- U7: 필드 중복"
body="[EVIDENCE]
claim: c
claim: c2
command: cmd
exit_code: 0
output:
[/EVIDENCE]"
res=$(parse_all "$body")
assert_contains "$res" "RC=1" "U7 중복 → rc 1"
assert_contains "$res" "중복" "U7 사유: 중복"

echo "-- U8: 블록 중첩 (output 영역 내 [EVIDENCE])"
res=$(parse_all "$(mk_block c cmd 0 '[EVIDENCE]')")
assert_contains "$res" "RC=1" "U8 중첩 → rc 1"
assert_contains "$res" "중첩" "U8 사유: 중첩"

echo "-- U9: output 줄수 경계 (60 통과 / 61 거부)"
res=$(parse_all "$(mk_block c cmd 0 "$(seq 1 60)")")
assert_contains "$res" "RC=0 COUNT=1" "U9 60줄 → 통과"
res=$(parse_all "$(mk_block c cmd 0 "$(seq 1 61)")")
assert_contains "$res" "RC=1" "U9 61줄 → rc 1"
assert_contains "$res" "60줄" "U9 사유: 60줄 상한"
assert_contains "$res" "발췌" "U9 안내: 발췌로 줄여라"

echo "-- U10: output 바이트 경계 (8000B 통과 / 8001B 거부, 다중바이트)"
ko=$(printf '가%.0s' {1..2666})     # 2666×3 = 7998 bytes
res=$(parse_all "$(mk_block c cmd 0 "${ko}x")")   # 7999 + LF = 8000
assert_contains "$res" "RC=0 COUNT=1" "U10 정확히 8000B → 통과"
res=$(parse_all "$(mk_block c cmd 0 "${ko}xy")")  # 8000 + LF = 8001
assert_contains "$res" "RC=1" "U10 8001B → rc 1"
assert_contains "$res" "8000바이트" "U10 사유: 8000바이트 상한"

echo "-- U11: 블록 수 경계 (16 통과 / 17 거부)"
body16=""
for _i in $(seq 1 16); do body16="$body16$(mk_block "c$_i" cmd 0 '')
"; done
res=$(parse_all "$body16")
assert_contains "$res" "RC=0 COUNT=16" "U11 16블록 → 통과"
body17="$body16$(mk_block c17 cmd 0 '')"
res=$(parse_all "$body17")
assert_contains "$res" "RC=1" "U11 17블록 → rc 1"
assert_contains "$res" "16" "U11 사유: 16 상한"

echo "-- U12: fence 안 [EVIDENCE] 예시는 블록/위반 미취급"
body='문법 예시:
```
[EVIDENCE]
claim: example only
[/EVIDENCE]
```
끝.'
res=$(parse_all "$body")
assert_contains "$res" "RC=0 COUNT=0" "U12 fence 예시 → 위반 아님 + 블록 0"

echo "-- U13: 블록 output 내 미폐쇄 fence 가 상태를 오염시키지 않음"
body="$(mk_block c1 cmd 0 '```bash
unterminated fence inside output')

$(mk_block c2 cmd 0 'plain')"
res=$(parse_all "$body")
assert_contains "$res" "RC=0 COUNT=2" "U13 output 내 \`\`\` 후에도 2블록 정상 계수"

echo "-- U14: claim 의 count= 유사 문자열이 요약 전달을 오염시키지 않음"
res=$(parse_all "$(mk_block 'count=999 문자열 포함 claim' cmd 7 '')")
assert_contains "$res" "RC=0 COUNT=1" "U14 count= 포함 claim → count 1 유지"
summ=$(summary_of "$(mk_block 'count=999 문자열 포함 claim' cmd 7 '')")
assert_contains "$summ" "count=999 문자열 포함 claim" "U14 claim 원문 보존"

# ============================================================
# S — 스캐너 단위 (Task 1.2)
# ============================================================
echo "-- S1: 정량+PASS 주장 매칭 (Q1/Q3)"
res=$(scan_all "테스트 21건 GREEN")
assert_contains "$res" "RC=0 MATCHES=1" "S1 '테스트 21건 GREEN' → 매칭 1"

echo "-- S2: 블록 밖 수량 주장 + 발췌 산출"
res=$(scan_all "서론
그리고 파일 5개 를 수정했다
결론")
assert_contains "$res" "MATCHES=1" "S2 '파일 5개' → 매칭 1"
assert_contains "$res" "L2: " "S2 라인 번호 산출"
assert_contains "$res" "파일 5개" "S2 발췌 내용"

echo "-- S3: 제외 토큰 7종만 → 매칭 0"
body='경로는 tests/foo.sh 와 21/21.md 를 참조한다.
날짜 2026-07-13 기준, 버전 v1.6.0 에서 L42 위치를 보라.
exit 4 와 exit code 3 은 정상이고 §4.2 절과 `숫자 7개` 를 참조.
Scope ID 는 EV1-block-count-over-16-exit4 다.
```
fenced 21건 GREEN 예시
```'
res=$(scan_all "$body")
assert_contains "$res" "MATCHES=0" "S3 제외 7종 → 매칭 0"

echo "-- S4: 21/21 단독 토큰은 경로 마스킹 예외 (Q2 매칭)"
res=$(scan_all "회귀 결과 21/21 확인")
assert_contains "$res" "MATCHES=1" "S4 '21/21' 단독 → Q2 매칭"

# ============================================================
# E — e2e (Task 1.3 / 1.4)
# ============================================================
echo "-- E1: 유효 2블록 → codex 호출 + manifest 슬롯 + sub-item 7 (수용 1, 10)"
e2e_setup
run_wrapper "$VALID_BLOCK_PROMPT"
assert_eq "$RC" "0" "E1 verdict PASS → exit 0"
assert_file_grep "[EVIDENCE]" "$CAPTURE" "E1 envelope 에 블록 원문 보존"
assert_file_grep "evidence_manifest:" "$CAPTURE" "E1 evidence_manifest: 슬롯"
assert_file_grep "  blocks: 2" "$CAPTURE" "E1 blocks: 2"
assert_file_grep "    claim: 테스트 21건 GREEN" "$CAPTURE" "E1 블록1 claim 요약"
assert_file_grep "    command: bash tests/skills/run-all.sh" "$CAPTURE" "E1 블록1 command 요약"
assert_file_grep "    exit_code: 0" "$CAPTURE" "E1 블록1 exit_code 요약"
assert_file_grep "Evidence manifest cross-check" "$CAPTURE" "E1 Claim Audit sub-item 7 방출"
assert_eq "$(count_reject_lines)" "0" "E1 거부 진단행 0"
assert_eq "$(count_advisory_lines)" "0" "E1 advisory 0 (블록 밖 정량 없음)"
assert_eq "$(count_tmp_leftovers)" "0" "E1 성공 경로 임시파일 정리"
e2e_teardown

echo "-- E2: 형식 위반 → exit 4 + codex 미호출 (수용 2)"
e2e_setup
run_wrapper "prose
[EVIDENCE]
claim: c
command: cmd
exit_code: 0
output:
never closed"
assert_eq "$RC" "4" "E2 형식 위반 → exit 4"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E2 fake codex 미호출"
else fail "E2 fake codex 가 호출됨 (캡처 파일 존재)"; fi
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "E2 거부 진단행 존재"
# readiness 진단행 전부가 anchored 접두사인지: 태그 포함 라인 수 == anchored 라인 수.
tag_lines=$(grep -c 'readiness-reject' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$(count_reject_lines)" "$tag_lines" "E2 전 거부 진단행이 라인 시작 anchored"
e2e_teardown

echo "-- E3: 무증거 정량 주장 → exit 4 + 발췌 + 문법 안내 (수용 4)"
e2e_setup
run_wrapper "구현 완료. 테스트 21건 GREEN 입니다."
assert_eq "$RC" "4" "E3 무증거 정량 → exit 4"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E3 fake codex 미호출"
else fail "E3 fake codex 가 호출됨"; fi
assert_contains "$ERR" "테스트 21건 GREEN" "E3 매칭 라인 발췌"
assert_contains "$ERR" "SKILL.md" "E3 [EVIDENCE] 문법 안내"
assert_contains "$ERR" "[EVIDENCE]" "E3 문법 안내에 블록 마커"
assert_eq "$(count_tmp_leftovers)" "0" "E3 거부 경로 임시파일 정리"
e2e_teardown

echo "-- E4: fence 예시 + fence 밖 정량 + 실블록 0 → exit 4 (수용 3 후반)"
e2e_setup
run_wrapper '예시:
```
[EVIDENCE]
claim: example
[/EVIDENCE]
```
실제로는 테스트 21건 GREEN 입니다.'
assert_eq "$RC" "4" "E4 예시가 유효 블록으로 오인되지 않음 → exit 4"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E4 fake codex 미호출"
else fail "E4 fake codex 가 호출됨"; fi
e2e_teardown

echo "-- E5: 패턴·블록 0 → 완전 무변경 passthrough (수용 5, 10)"
e2e_setup
run_wrapper "code review please"
assert_eq "$RC" "0" "E5 verdict PASS → exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: E5 fake codex 정상 호출"
else fail "E5 fake codex 미호출"; fi
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "E5 readiness stderr 0줄"
assert_not_contains "$ERR" "command not found" "E5 함수 정의 순서 스모크 (command-not-found 없음)"
assert_file_no_grep "evidence_manifest:" "$CAPTURE" "E5 envelope 신규 슬롯 부재 (manifest)"
assert_file_no_grep "unbacked_quant_flags:" "$CAPTURE" "E5 envelope 신규 슬롯 부재 (flags)"
assert_file_no_grep "Evidence manifest cross-check" "$CAPTURE" "E5 sub-item 7 부재"
# sub-item 6 말미 → (빈 줄) → 응답 출력 형식 인접성 보존 (기존 slot byte-무변경 증거).
adj=$(sed -n '/numeric mapping claim 전용/{n;n;p;}' "$CAPTURE")
assert_contains "$adj" "응답 출력 형식" "E5 sub-item 6 직후 기존 텍스트 인접 (diff 0)"
assert_eq "$(count_tmp_leftovers)" "0" "E5 통과 경로 임시파일 정리"
e2e_teardown

echo "-- E5a: Q3 후행 단어 경계 — 'testing passed'/'buildings passed' 미차단 (통합리뷰 R1 Medium 회귀)"
e2e_setup
run_wrapper "the testing passed smoothly and the buildings passed inspection"
assert_eq "$RC" "0" "E5a 후행 경계 오탐 없음 → verdict exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: E5a fake codex 정상 호출"
else fail "E5a fake codex 미호출 (오탐 차단 발생)"; fi
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "E5a readiness stderr 0줄"
e2e_teardown

echo "-- E5a2: Q3 복수형은 여전히 매칭 — 'all tests passed' + 블록 0 → exit 4"
e2e_setup
run_wrapper "all tests passed without issues"
assert_eq "$RC" "4" "E5a2 복수형 PASS 주장 차단 유지"
e2e_teardown

echo "-- E5a3: 이중 백틱 인라인 스팬 마스킹 — \`\`테스트 21건 GREEN\`\` 인용은 미차단 (통합리뷰 R2 Medium 회귀)"
e2e_setup
run_wrapper '문서 예시는 ``테스트 21건 GREEN`` 이다.'
assert_eq "$RC" "0" "E5a3 이중 백틱 스팬 오탐 없음 → verdict exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: E5a3 fake codex 정상 호출"
else fail "E5a3 fake codex 미호출 (이중 백틱 오탐 차단)"; fi
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "E5a3 readiness stderr 0줄"
e2e_teardown

echo "-- E5a4: 백틱 밖 실주장은 여전히 차단 — \`경로\` 인용 + 맨 텍스트 주장 → exit 4"
e2e_setup
run_wrapper '`tests/foo.sh` 를 고쳤고 테스트 21건 GREEN 이다.'
assert_eq "$RC" "4" "E5a4 스팬 밖 실주장 차단 유지"
e2e_teardown

echo "-- E5a5: 불균형 백틱 런 (1→2, 2→3) — 닫는 delimiter 길이 불일치는 스팬 아님, 주장 노출·차단 (통합리뷰 R3 Medium)"
e2e_setup
run_wrapper '이 문장은 `테스트 21건 GREEN`` 처럼 불균형이다.'
assert_eq "$RC" "4" "E5a5 1→2 불균형: 긴 런 앞부분을 closer 로 오인하지 않고 주장 차단"
e2e_teardown
e2e_setup
run_wrapper '이 문장은 ``테스트 21건 GREEN``` 처럼 불균형이다.'
assert_eq "$RC" "4" "E5a5 2→3 불균형: 주장 차단"
e2e_teardown

echo "-- E5a7: 4-backtick 외부 fence 안 3-backtick 예제 — 조기 폐쇄 없이 마스킹 유지 (통합리뷰 R4 Medium)"
e2e_setup
run_wrapper '문서 예시:
````
```
[EVIDENCE]
claim: example
[/EVIDENCE]
```
````
이상.'
assert_eq "$RC" "0" "E5a7 외부 fence 유지 — 예제가 블록/위반으로 오인되지 않음"
TEST_COUNT=$((TEST_COUNT + 1))
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "E5a7 readiness stderr 0줄"
e2e_teardown

echo "-- E5a8: 열린 fence 안 info-string 딸린 백틱 런 — 닫는 fence 아님 (통합리뷰 R4 Medium)"
e2e_setup
run_wrapper '예시:
```text
```not-a-closing-fence
[EVIDENCE]
claim: example
[/EVIDENCE]
```
이상.'
assert_eq "$RC" "0" "E5a8 info-string 런은 폐쇄 아님 — 예제 마스킹 유지"
e2e_teardown

echo "-- E5a9: 여러 줄 인라인 코드 스팬 — 스팬 내부 주장 미차단 (통합리뷰 R5 Medium)"
e2e_setup
run_wrapper '문서 인용: `
test suite PASS
` 이다.'
assert_eq "$RC" "0" "E5a9 여러 줄 스팬 내부 예시 마스킹 → 통과"
TEST_COUNT=$((TEST_COUNT + 1))
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "E5a9 readiness stderr 0줄"
e2e_teardown

echo "-- E5a10: 닫힘 없는 여러 줄 opener — 스팬 아님, 주장 노출·차단"
e2e_setup
run_wrapper '문서 인용: `
test suite PASS 그리고 닫는 백틱 없음'
assert_eq "$RC" "4" "E5a10 미폐쇄 opener 는 리터럴 — 주장 차단 유지"
e2e_teardown

echo "-- E5a13: 비-fence opener 는 마스킹 시작 안 함 — 4칸 들여쓴 백틱 런 / info string 에 백틱 (통합리뷰 R7 High)"
e2e_setup
run_wrapper '    ```
테스트 21건 GREEN 이라고 주장한다.'
assert_eq "$RC" "4" "E5a13 4칸 들여쓴 런은 fence 아님 — 뒤 주장 차단 유지"
e2e_teardown
e2e_setup
run_wrapper '```bad`info
테스트 21건 GREEN 이라고 주장한다.'
assert_eq "$RC" "4" "E5a13 info string 에 백틱 → fence 아님 — 뒤 주장 차단 유지"
e2e_teardown

echo "-- E5a14: malformed 유형별 e2e 승격 — 필드 누락/비정수 exit_code 도 exit 4 + codex 미호출 (통합리뷰 R7 Medium)"
e2e_setup
run_wrapper '[EVIDENCE]
claim: 필드 누락 케이스
command: true
[/EVIDENCE]'
assert_eq "$RC" "4" "E5a14 필드 누락 → exit 4"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E5a14 필드 누락 — fake codex 미호출"
else fail "E5a14 필드 누락인데 codex 호출됨"; fi
e2e_teardown
e2e_setup
run_wrapper '[EVIDENCE]
claim: 비정수 exit_code 케이스
command: true
exit_code: abc
output:
x
[/EVIDENCE]'
assert_eq "$RC" "4" "E5a14 비정수 exit_code → exit 4"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E5a14 비정수 exit_code — fake codex 미호출"
else fail "E5a14 비정수인데 codex 호출됨"; fi
e2e_teardown

echo "-- E5a11: 이스케이프 백틱(\\\`)은 구분자 아님 — 실주장 우회 차단 (통합리뷰 R6 Medium)"
e2e_setup
run_wrapper '증거는 \`test suite PASS\` 라고 적혀 있다.'
assert_eq "$RC" "4" "E5a11 escaped 백틱은 리터럴 — 주장 노출·차단"
e2e_teardown

echo "-- E5a12: 파서 진단 발췌의 UTF-8 경계 보존 — 한글 unknown 필드 (통합리뷰 R6 Medium)"
e2e_setup
run_wrapper '[EVIDENCE]
한글로만이어지는알수없는필드라인이팔십바이트경계를확실히넘어가도록충분히길게이어지는문장입니다
[/EVIDENCE]'
assert_eq "$RC" "4" "E5a12 형식 위반 → exit 4"
TEST_COUNT=$((TEST_COUNT + 1))
if iconv -f utf-8 -t utf-8 "$SANDBOX/.err.txt" >/dev/null 2>&1; then
  echo "  ok: E5a12 파서 진단 발췌 valid UTF-8"
else fail "E5a12 파서 진단에 invalid UTF-8"; fi
e2e_teardown

echo "-- E5a6: 발췌 UTF-8 문자 경계 보존 — 80바이트 절단이 한글 중간에 걸려도 valid UTF-8 (통합리뷰 R3 Medium)"
e2e_setup
LONG_KR="테스트 21건 GREEN 이고 이어지는 긴 한글 설명 문장이 팔십 바이트 경계를 정확히 넘어가도록 충분히 길게 이어진다"
run_wrapper "$(mk_block '수정 완료' 'git diff --stat' 0 'done')
$LONG_KR"
assert_eq "$RC" "0" "E5a6 advisory 비차단"
TEST_COUNT=$((TEST_COUNT + 1))
if iconv -f utf-8 -t utf-8 "$SANDBOX/.err.txt" >/dev/null 2>&1; then
  echo "  ok: E5a6 stderr 발췌 valid UTF-8"
else fail "E5a6 stderr 에 invalid UTF-8 (문자 경계 절단)"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ] && iconv -f utf-8 -t utf-8 "$CAPTURE" >/dev/null 2>&1; then
  echo "  ok: E5a6 envelope 발췌 valid UTF-8"
else fail "E5a6 envelope 에 invalid UTF-8"; fi
e2e_teardown

echo "-- E5b: 기준(HEAD) 래퍼 vs 신규 래퍼 — 무주장 요청서 envelope 실제 byte 비교 (통합리뷰 R1 Medium)"
e2e_setup
git -C "$REAL_PROJECT_DIR" show HEAD:plugins/rein-core/scripts/rein-codex-review.sh \
  > "$SANDBOX/scripts/base-wrapper.sh" 2>/dev/null
if [ -s "$SANDBOX/scripts/base-wrapper.sh" ]; then
  BASE_CAPTURE="$SANDBOX/.capture-base.txt"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$BASE_CAPTURE"
    export TMPDIR="$SANDBOX/tmpdir"
    printf '%s' "code review please" | bash "$SANDBOX/scripts/base-wrapper.sh" --non-interactive \
      > /dev/null 2>&1
  ) || true
  # 기준 실행이 남긴 도장/마커 제거 — 신규 실행의 diff 기준점 오염 방지.
  rm -f "$SANDBOX/trail/dod/.codex-reviewed" "$SANDBOX/trail/dod/.review-pending" 2>/dev/null
  run_wrapper "code review please"
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ -f "$BASE_CAPTURE" ] && [ -f "$CAPTURE" ]; then
    if diff -q "$BASE_CAPTURE" "$CAPTURE" >/dev/null 2>&1; then
      echo "  ok: E5b 무주장 요청서 envelope 이 기준 래퍼와 byte 동일"
    else
      fail "E5b envelope 이 기준 래퍼와 다름: $(diff "$BASE_CAPTURE" "$CAPTURE" | head -5)"
    fi
  else
    fail "E5b 캡처 파일 누락"
  fi
else
  echo "  ok: E5b SKIP — HEAD 에 기준 래퍼 없음"
  TEST_COUNT=$((TEST_COUNT + 1))
fi
e2e_teardown

echo "-- E6: 블록 1 + 블록 밖 '파일 5개' → 비차단 advisory (수용 6)"
e2e_setup
run_wrapper "$(mk_block '수정 완료' 'git diff --stat' 0 'done')
그리고 파일 5개 를 손봤다."
assert_eq "$RC" "0" "E6 advisory 는 비차단 → verdict exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: E6 fake codex 호출됨"
else fail "E6 fake codex 미호출"; fi
adv_hdr=$(grep -c '^WARNING: \[codex-review\]\[readiness-advisory\] 블록 밖 정량/PASS 패턴' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$adv_hdr" "1" "E6 advisory 헤더 1회"
assert_eq "$(count_reject_lines)" "0" "E6 거부 진단행 0"
assert_file_grep "unbacked_quant_flags:" "$CAPTURE" "E6 envelope unbacked_quant_flags: 슬롯"
assert_file_grep "파일 5개" "$CAPTURE" "E6 슬롯에 매칭 라인 발췌"
e2e_teardown

echo "-- E7: spec-review skip 차등 fixture (수용 8)"
e2e_setup
run_wrapper "automated check: test suite PASS 확인 요청"
assert_eq "$RC" "4" "E7a 동일 문장이 code-review 모드에선 exit 4 (스캐너 검증력)"
run_wrapper "[NON_INTERACTIVE] spec review for plan: docs/plans/foo-plan.md
Validate coverage — test suite PASS 확인 요청"
assert_eq "$RC" "0" "E7b spec-review 모드 → skip + verdict exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$CAPTURE" ]; then echo "  ok: E7b fake codex 호출됨"
else fail "E7b fake codex 미호출"; fi
readiness_lines=$(grep -c 'readiness' "$SANDBOX/.err.txt" 2>/dev/null || true)
assert_eq "$readiness_lines" "0" "E7b readiness stderr 0줄"
assert_file_no_grep "evidence_manifest:" "$CAPTURE" "E7b spec envelope 에 신규 슬롯 부재"
e2e_teardown

echo "-- E8: verdict 3종 exit 0/1/2 + PASS stamp (수용 9 전반)"
e2e_setup
run_wrapper "$VALID_BLOCK_PROMPT"
assert_eq "$RC" "0" "E8 PASS → exit 0"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -f "$SANDBOX/trail/dod/.codex-reviewed" ]; then echo "  ok: E8 PASS → stamp 생성"
else fail "E8 PASS 인데 .codex-reviewed 미생성"; fi
rm -f "$SANDBOX/trail/dod/.codex-reviewed"
FAKE_CODEX_VERDICT="NEEDS-FIX
needs work" run_wrapper "$VALID_BLOCK_PROMPT"
assert_eq "$RC" "1" "E8 NEEDS-FIX → exit 1"
FAKE_CODEX_VERDICT="REJECT
rejected" run_wrapper "$VALID_BLOCK_PROMPT"
assert_eq "$RC" "2" "E8 REJECT → exit 2"
e2e_teardown

echo "-- E9: exit 4 경로 stamp/pending/spec-reviews 무접촉 (수용 9 후반)"
e2e_setup
mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
printf 'seed-codex-reviewed\n' > "$SANDBOX/trail/dod/.codex-reviewed"
printf 'seed-review-pending\n' > "$SANDBOX/trail/dod/.review-pending"
printf 'seed-spec-reviewed\n' > "$SANDBOX/trail/dod/.spec-reviews/seed.reviewed"
cp "$SANDBOX/trail/dod/.codex-reviewed" "$SANDBOX/.seed1"
cp "$SANDBOX/trail/dod/.review-pending" "$SANDBOX/.seed2"
cp "$SANDBOX/trail/dod/.spec-reviews/seed.reviewed" "$SANDBOX/.seed3"
run_wrapper "구현 완료. 테스트 21건 GREEN 입니다."
assert_eq "$RC" "4" "E9 거부 경로 진입"
TEST_COUNT=$((TEST_COUNT + 1))
if cmp -s "$SANDBOX/trail/dod/.codex-reviewed" "$SANDBOX/.seed1"; then echo "  ok: E9 .codex-reviewed 무변화"
else fail "E9 .codex-reviewed 변화/삭제됨"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if cmp -s "$SANDBOX/trail/dod/.review-pending" "$SANDBOX/.seed2"; then echo "  ok: E9 .review-pending 무변화"
else fail "E9 .review-pending 변화/삭제됨"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if cmp -s "$SANDBOX/trail/dod/.spec-reviews/seed.reviewed" "$SANDBOX/.seed3"; then echo "  ok: E9 .spec-reviews/seed.reviewed 무변화"
else fail "E9 .spec-reviews/seed.reviewed 변화/삭제됨"; fi
e2e_teardown

echo "-- E10: passthrough (a) 무-advisory + fake codex exit 4 (수용 14a)"
e2e_setup
FAKE_CODEX_EXIT=4 run_wrapper "code review please"
assert_eq "$RC" "4" "E10 passthrough exit 4 전파"
assert_eq "$(count_reject_lines)" "0" "E10 거부 진단행 0 → 실행 실패로 판별"
e2e_teardown

echo "-- E11: passthrough (b) advisory + fake codex exit 4 (수용 14b)"
e2e_setup
FAKE_CODEX_EXIT=4 run_wrapper "$(mk_block c cmd 0 '')
파일 5개 손봄"
assert_eq "$RC" "4" "E11 passthrough exit 4 전파"
adv=$(count_advisory_lines)
TEST_COUNT=$((TEST_COUNT + 1))
if [ "$adv" -ge 1 ] 2>/dev/null; then echo "  ok: E11 advisory 진단행 존재"
else fail "E11 advisory 진단행 부재 (got $adv)"; fi
assert_eq "$(count_reject_lines)" "0" "E11 거부 진단행 0"
e2e_teardown

echo "-- E12: passthrough (c) 원문 [readiness-reject] 리터럴 소독 (수용 14c)"
e2e_setup
FAKE_CODEX_EXIT=4 run_wrapper "$(mk_block c cmd 0 '')
파일 5개 손봄 [readiness-reject] 리터럴 주입"
assert_eq "$RC" "4" "E12 passthrough exit 4 전파"
assert_eq "$(count_reject_lines)" "0" "E12 발췌 소독 → 거부 진단행 0"
assert_contains "$ERR" "[readiness-…]" "E12 예약 태그가 [readiness-…] 로 소독됨"
e2e_teardown

echo "-- E13: 블록 output 의 [EFFORT:] 리터럴 — strip-이후-원문 계약"
e2e_setup
run_wrapper "$(mk_block 'effort marker 실험' 'echo run' 0 'ran with [EFFORT:high] marker')"
assert_eq "$RC" "0" "E13 형식 통과 → verdict exit 0"
assert_file_no_grep "[EFFORT:" "$CAPTURE" "E13 envelope output 에 [EFFORT:] 리터럴 부재 (strip 계약)"
assert_file_grep "evidence_manifest:" "$CAPTURE" "E13 manifest 방출 유지"
e2e_teardown

echo "-- E14: 인프라 실패 — 파서 awk 실패 (fail-open 차단)"
e2e_setup
mk_awk_shim
: > "$SANDBOX/.awkcount"
AWK_SHIM_COUNT_FILE="$SANDBOX/.awkcount" AWK_SHIM_FAIL_ON=1 \
  WRAP_PATH_PREFIX="$SANDBOX/awkshim" run_wrapper "code review please"
TEST_COUNT=$((TEST_COUNT + 1))
if [ "$RC" -ne 0 ] 2>/dev/null; then echo "  ok: E14 non-zero 종료 (rc=$RC)"
else fail "E14 awk 실패가 fail-open (rc=0)"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E14 fake codex 미호출"
else fail "E14 fake codex 가 호출됨"; fi
assert_not_contains "$ERR" "readiness-reject" "E14 인프라 실패는 [readiness-reject] 태그 없음"
assert_contains "$ERR" "ERROR: [codex-review]" "E14 plain ERROR 방출"
assert_eq "$(count_tmp_leftovers)" "0" "E14 awk 실패 경로 임시파일 정리"
e2e_teardown

echo "-- E15: 인프라 실패 — 스캐너 awk 선택 실패 (파서는 성공)"
e2e_setup
mk_awk_shim
: > "$SANDBOX/.awkcount"
AWK_SHIM_COUNT_FILE="$SANDBOX/.awkcount" AWK_SHIM_FAIL_ON=2 \
  WRAP_PATH_PREFIX="$SANDBOX/awkshim" run_wrapper "$VALID_BLOCK_PROMPT"
TEST_COUNT=$((TEST_COUNT + 1))
if [ "$RC" -ne 0 ] 2>/dev/null; then echo "  ok: E15 non-zero 종료 (rc=$RC)"
else fail "E15 스캐너 awk 실패가 fail-open (rc=0)"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -f "$CAPTURE" ]; then echo "  ok: E15 fake codex 미호출"
else fail "E15 fake codex 가 호출됨"; fi
assert_not_contains "$ERR" "readiness-reject" "E15 인프라 실패는 [readiness-reject] 태그 없음"
assert_eq "$(count_tmp_leftovers)" "0" "E15 스캐너 실패 경로 임시파일 정리"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
