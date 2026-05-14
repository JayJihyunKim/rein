#!/bin/bash
# tests/hooks/test-extract-hook-json.sh
#
# Unit tests for .claude/hooks/lib/extract-hook-json.py — the Python CLI helper
# that all hooks delegate JSON-field extraction to.  Scope (15 cases) per
# plan Task 4.2 (WGB-12b) / spec §5.3:
#
#   1.  valid single field                 — dotted path → stdout, rc=0
#   2.  valid multi field                  — two --field flags, order preserved
#   3.  invalid JSON                       — rc=20
#   4.  missing field, no default          — rc=21
#   5.  missing field, with --default ''   — rc=0, empty stdout
#   6.  CRLF payload                       — rc=0 (json 모듈이 관용, NOT rc=22)  ★CRITICAL
#   7.  Unicode (한글)                     — UTF-8 value round-trip
#   8.  Windows path C:\Users\x            — backslash escape round-trip
#   9.  array index in field               — a.0.b
#   10. --array-of + --subfield 2단 API    — list of dicts → one line per element
#   11. --strip-newlines                   — LF / CR 제거
#   12. --input-file                       — stdin 대신 파일 입력
#   13. 경로 type mismatch                 — int 필드 인덱싱 → missing → rc=21
#   14. bracket 정규화                     — a[0].b ≡ a.0.b
#   15. non-UTF-8 stream                   — rc=22
#
# 이 테스트는 실제 프로젝트 루트의 helper 를 그대로 호출한다 (샌드박스 불필요).
# 기존 test-harness.sh 는 훅 sandbox 용이라 여기서는 source 하지 않고,
# 가벼운 자체 runner 로 충분히 커버한다.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PROJECT_DIR/.claude/hooks/lib/extract-hook-json.py"

if [ ! -f "$HELPER" ]; then
  echo "FATAL: $HELPER not found" >&2
  exit 1
fi
if [ ! -x "$HELPER" ]; then
  # 직접 python3 으로 호출하므로 executable 여부는 fatal 은 아님
  :
fi

# UTF-8 locale 보장 (한글/Unicode 테스트 안정성).
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="${LANG:-en_US.UTF-8}"
export PYTHONIOENCODING="utf-8"

# ---- 결과 누적 ----
TEST_COUNT=0
FAIL_COUNT=0
CURRENT_FAILS=0
CURRENT_TEST=""

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

run_test() {
  local fn="$1"
  CURRENT_TEST="$fn"
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $fn"
  "$fn"
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
  CURRENT_TEST=""
}

summary() {
  local pass=$((TEST_COUNT - FAIL_COUNT))
  echo ""
  echo "================================"
  echo "Tests run: $TEST_COUNT"
  echo "Passed:    $pass"
  echo "Failed:    $FAIL_COUNT"
  echo "================================"
  [ "$FAIL_COUNT" -eq 0 ]
}

# ---- helper: run extract-hook-json with stdin ----
# Writes stdin via a temp file (not heredoc) so we can pass arbitrary bytes
# including CRLF and non-UTF-8. Populates globals EH_STDOUT / EH_STDERR / EH_RC.
run_extract_bytes() {
  # $1 = path to stdin payload file, remaining args = CLI args
  local stdin_file="$1"; shift
  local tmp_out tmp_err
  tmp_out=$(mktemp)
  tmp_err=$(mktemp)
  python3 "$HELPER" "$@" < "$stdin_file" > "$tmp_out" 2> "$tmp_err"
  EH_RC=$?
  EH_STDOUT=$(cat "$tmp_out")
  EH_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"
  return 0
}

# Convenience wrapper: stdin is a plain string passed via printf '%s'.
run_extract_str() {
  local stdin_str="$1"; shift
  local tmp_in
  tmp_in=$(mktemp)
  printf '%s' "$stdin_str" > "$tmp_in"
  run_extract_bytes "$tmp_in" "$@"
  rm -f "$tmp_in"
}

# ============================================================================
# Tests
# ============================================================================

# Test 1: valid single field — dotted path extraction.
test_valid_single_field_정상경로_값반환() {
  run_extract_str '{"tool_input":{"file_path":"/a/b"}}' \
    --field tool_input.file_path
  [ "$EH_RC" = "0" ]       || fail "exit=0 expected, got $EH_RC (stderr: $EH_STDERR)"
  [ "$EH_STDOUT" = "/a/b" ] || fail "stdout='/a/b' expected, got '$EH_STDOUT'"
}

# Test 2: valid multi field — argparse 순서 보존 확인.
test_valid_multi_field_순서보존_구분자로출력() {
  run_extract_str '{"a":"A","b":"B"}' \
    --field a --field b
  [ "$EH_RC" = "0" ] || fail "exit=0 expected, got $EH_RC"
  local expected=$'A\nB'
  [ "$EH_STDOUT" = "$expected" ] \
    || fail "stdout='A\\nB' expected, got '$EH_STDOUT'"

  # 반대 순서도 확인 (--field b --field a → B\nA)
  run_extract_str '{"a":"A","b":"B"}' \
    --field b --field a
  [ "$EH_RC" = "0" ] || fail "exit=0 expected (reverse), got $EH_RC"
  local reversed=$'B\nA'
  [ "$EH_STDOUT" = "$reversed" ] \
    || fail "stdout='B\\nA' expected (reverse), got '$EH_STDOUT'"
}

# Test 3: invalid JSON → exit 20.
test_invalid_json_파싱실패_exit20() {
  run_extract_str 'not json at all' --field x
  [ "$EH_RC" = "20" ] || fail "exit=20 expected, got $EH_RC"
}

# Test 4: missing field with no --default → exit 21.
test_missing_field_default없음_exit21() {
  run_extract_str '{}' --field x.y
  [ "$EH_RC" = "21" ] || fail "exit=21 expected, got $EH_RC"
  # stderr 에 'missing field' 포함 확인
  echo "$EH_STDERR" | grep -qF "missing field" \
    || fail "stderr missing 'missing field' marker (got: $EH_STDERR)"
}

# Test 5: missing field with --default '' → exit 0, empty stdout.
test_missing_field_default빈값_exit0_빈stdout() {
  run_extract_str '{}' --field x.y --default ''
  [ "$EH_RC" = "0" ]   || fail "exit=0 expected, got $EH_RC"
  [ -z "$EH_STDOUT" ]  || fail "empty stdout expected, got '$EH_STDOUT'"
}

# Test 6: CRLF payload — json.loads 는 CRLF 를 관용. rc=22 여서는 안 됨. ★CRITICAL
test_crlf_payload_정상파싱_exit0_not22() {
  # 실제 CRLF 바이트(\r\n) 을 포함한 JSON 을 전달.
  local tmp_in
  tmp_in=$(mktemp)
  printf '{"x":"y"}\r\n' > "$tmp_in"
  run_extract_bytes "$tmp_in" --field x
  rm -f "$tmp_in"

  # CRITICAL: CRLF 는 decode 실패(22) 가 절대 아니고, 파싱(20) 실패도 아니다.
  [ "$EH_RC" != "22" ] \
    || fail "CRLF MUST NOT produce exit=22 (UTF-8 decode fail); got $EH_RC"
  [ "$EH_RC" = "0" ] \
    || fail "exit=0 expected for CRLF payload, got $EH_RC (stderr: $EH_STDERR)"
  [ "$EH_STDOUT" = "y" ] \
    || fail "stdout='y' expected, got '$EH_STDOUT'"
}

# Test 7: Unicode (한글) — UTF-8 라운드트립.
test_unicode_한글_라운드트립_정상반환() {
  run_extract_str '{"name":"한글값"}' --field name
  [ "$EH_RC" = "0" ] \
    || fail "exit=0 expected, got $EH_RC (stderr: $EH_STDERR)"
  [ "$EH_STDOUT" = "한글값" ] \
    || fail "stdout='한글값' expected, got '$EH_STDOUT'"
}

# Test 8: Windows path — JSON 내부 `\\` 이 `\` 단일 문자로 복원되어야 함.
test_windows_path_backslash_escape_라운드트립() {
  # JSON payload 는 "path":"C:\\Users\\x" (JSON 스펙상 \\ == \).
  # bash printf '%s' 에 전달할 때 우리가 보는 문자열은 네 개의 \ → 두 개의 \ → JSON 디코드 후 각각 한 개의 \.
  local payload='{"path":"C:\\Users\\x"}'
  run_extract_str "$payload" --field path
  [ "$EH_RC" = "0" ] \
    || fail "exit=0 expected, got $EH_RC (stderr: $EH_STDERR)"
  # 기대 stdout: C:\Users\x (실제 단일 backslash 3개).
  local expected='C:\Users\x'
  [ "$EH_STDOUT" = "$expected" ] \
    || fail "stdout='$expected' expected, got '$EH_STDOUT'"
}

# Test 9: array index in --field (a.0.b).
test_array_index_in_field_인덱스로원소접근() {
  run_extract_str '{"a":[{"b":"1"},{"b":"2"}]}' --field a.0.b
  [ "$EH_RC" = "0" ]       || fail "exit=0 expected, got $EH_RC"
  [ "$EH_STDOUT" = "1" ]   || fail "stdout='1' expected, got '$EH_STDOUT'"

  # 두 번째 원소도 확인
  run_extract_str '{"a":[{"b":"1"},{"b":"2"}]}' --field a.1.b
  [ "$EH_RC" = "0" ]       || fail "exit=0 expected (index 1), got $EH_RC"
  [ "$EH_STDOUT" = "2" ]   || fail "stdout='2' expected (index 1), got '$EH_STDOUT'"
}

# Test 10: --array-of + --subfield — 2단 API.
test_array_of_subfield_각원소에서추출_한줄씩() {
  run_extract_str '{"edits":[{"file_path":"/a"},{"file_path":"/b"}]}' \
    --array-of edits --subfield file_path
  [ "$EH_RC" = "0" ] || fail "exit=0 expected, got $EH_RC"
  local expected=$'/a\n/b'
  [ "$EH_STDOUT" = "$expected" ] \
    || fail "stdout='/a\\n/b' expected, got '$EH_STDOUT'"
}

# Test 11: --strip-newlines 옵션 — LF/CR 을 값에서 제거.
test_strip_newlines_LF제거_한줄로합쳐짐() {
  # JSON escape \n → 파싱 후 실제 LF 문자. printf '%s' 는 \\ 을 \ 로 변환하지 않음.
  # bash 싱글쿼트 안의 `\n` 은 literal backslash-n (두 문자) 이므로 JSON 이 보면 escape 로 처리 → 실제 LF.
  run_extract_str '{"x":"line1\nline2"}' --field x --strip-newlines
  [ "$EH_RC" = "0" ] || fail "exit=0 expected, got $EH_RC"
  [ "$EH_STDOUT" = "line1line2" ] \
    || fail "stdout='line1line2' expected (newline stripped), got '$EH_STDOUT'"

  # CR 도 제거되는지 함께 확인
  run_extract_str '{"x":"line1\rline2"}' --field x --strip-newlines
  [ "$EH_RC" = "0" ] || fail "exit=0 expected (CR case), got $EH_RC"
  [ "$EH_STDOUT" = "line1line2" ] \
    || fail "stdout='line1line2' expected (CR stripped), got '$EH_STDOUT'"
}

# Test 12: --input-file 옵션 — stdin 대신 파일 입력.
test_input_file_파일에서읽기_stdin미제공() {
  local tmp_in tmp_out tmp_err rc
  tmp_in=$(mktemp)
  tmp_out=$(mktemp)
  tmp_err=$(mktemp)
  printf '{"x":"from_file"}' > "$tmp_in"

  # stdin 은 주지 않는다 (/dev/null 로 닫음).
  python3 "$HELPER" --input-file "$tmp_in" --field x \
    < /dev/null > "$tmp_out" 2> "$tmp_err"
  rc=$?

  [ "$rc" = "0" ] \
    || fail "exit=0 expected (--input-file), got $rc (stderr: $(cat "$tmp_err"))"
  local out
  out=$(cat "$tmp_out")
  [ "$out" = "from_file" ] \
    || fail "stdout='from_file' expected, got '$out'"

  rm -f "$tmp_in" "$tmp_out" "$tmp_err"
}

# Test 13: 경로 type mismatch — int 필드를 인덱싱하면 TypeError → missing → exit 21.
# (string 을 인덱싱하면 Python 은 문자 반환이라 mismatch 가 아님. int/bool 사용.)
test_type_mismatch_int필드_인덱싱_missing_exit21() {
  run_extract_str '{"a":123}' --field a.0
  [ "$EH_RC" = "21" ] \
    || fail "exit=21 expected (int not indexable), got $EH_RC (stdout: '$EH_STDOUT')"
  echo "$EH_STDERR" | grep -qF "missing field" \
    || fail "stderr missing 'missing field' marker (got: $EH_STDERR)"
}

# Test 14: bracket 정규화 — a[0].b 가 a.0.b 와 동일 결과.
test_bracket_notation_a0b와_동일결과() {
  local out_dotted out_bracket
  # dotted
  run_extract_str '{"a":[{"b":"X"}]}' --field a.0.b
  [ "$EH_RC" = "0" ]     || fail "dotted: exit=0 expected, got $EH_RC"
  out_dotted="$EH_STDOUT"

  # bracket
  run_extract_str '{"a":[{"b":"X"}]}' --field 'a[0].b'
  [ "$EH_RC" = "0" ]     || fail "bracket: exit=0 expected, got $EH_RC"
  out_bracket="$EH_STDOUT"

  [ "$out_dotted" = "$out_bracket" ] \
    || fail "dotted('$out_dotted') != bracket('$out_bracket')"
  [ "$out_bracket" = "X" ] \
    || fail "stdout='X' expected, got '$out_bracket'"
}

# Test 15: non-UTF-8 stream — UnicodeDecodeError → exit 22.
test_non_utf8_stream_decode실패_exit22() {
  local tmp_in
  tmp_in=$(mktemp)
  # UTF-16 BOM(0xff 0xfe) + ASCII JSON.  UTF-8 로는 decode 불가.
  printf '\xff\xfe{"x":"y"}' > "$tmp_in"
  run_extract_bytes "$tmp_in" --field x
  rm -f "$tmp_in"

  [ "$EH_RC" = "22" ] \
    || fail "exit=22 expected (non-UTF-8), got $EH_RC (stderr: $EH_STDERR)"
  echo "$EH_STDERR" | grep -qF "UTF-8" \
    || fail "stderr should mention UTF-8 (got: $EH_STDERR)"
}

# ---- bonus: wildcard rejection (spec 금지 확인) ----
# plan 15 tests 에는 직접 포함되지 않지만, spec 규정(`*` → exit 21) 을 지키는지
# 빠르게 검증. 이 케이스는 추가 정보이므로 TEST_COUNT 에 영향 주지 않도록
# 메인 15개와 분리해서 guard test 로 돌린다.
test_wildcard_rejected_exit21_spec준수() {
  run_extract_str '{"a":{"b":{"c":"x"}}}' --field 'a.*.c'
  [ "$EH_RC" = "21" ] \
    || fail "exit=21 expected (wildcard rejected), got $EH_RC"
  echo "$EH_STDERR" | grep -qF "wildcard" \
    || fail "stderr should mention 'wildcard' (got: $EH_STDERR)"
}

# ============================================================================
# Main
# ============================================================================
main() {
  run_test test_valid_single_field_정상경로_값반환                 #  1
  run_test test_valid_multi_field_순서보존_구분자로출력            #  2
  run_test test_invalid_json_파싱실패_exit20                       #  3
  run_test test_missing_field_default없음_exit21                   #  4
  run_test test_missing_field_default빈값_exit0_빈stdout           #  5
  run_test test_crlf_payload_정상파싱_exit0_not22                  #  6 ★
  run_test test_unicode_한글_라운드트립_정상반환                   #  7
  run_test test_windows_path_backslash_escape_라운드트립           #  8
  run_test test_array_index_in_field_인덱스로원소접근              #  9
  run_test test_array_of_subfield_각원소에서추출_한줄씩            # 10
  run_test test_strip_newlines_LF제거_한줄로합쳐짐                 # 11
  run_test test_input_file_파일에서읽기_stdin미제공                # 12
  run_test test_type_mismatch_int필드_인덱싱_missing_exit21        # 13
  run_test test_bracket_notation_a0b와_동일결과                    # 14
  run_test test_non_utf8_stream_decode실패_exit22                  # 15

  # 보조 guard test (spec 준수: wildcard 거부)
  run_test test_wildcard_rejected_exit21_spec준수

  summary
}

main "$@"
