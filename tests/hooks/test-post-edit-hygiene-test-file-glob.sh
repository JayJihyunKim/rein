#!/bin/bash
# tests/hooks/test-post-edit-hygiene-test-file-glob.sh
#
# FU-4 regression — post-edit-hygiene 의 테스트 파일 제외 glob.
#
# 버그 (need-to-confirm.md FU-4): 제외 case 의 `*test_*` 는 substring glob 이라
# `latest_release.py` 같은 일반 소스를 test 파일로 오인해 hygiene 스캔에서
# 제외했다. fix 는 `*/test_*|test_*` 로 좁혀 basename 이 `test_` 로 시작하는
# 파일 (pytest 규약) 만 제외한다.
#
# Contract:
#   - basename 에 test_ substring 만 있는 일반 소스 (latest_config.py) → 스캔됨
#   - basename 이 test_ 로 시작하는 진짜 테스트 파일 (test_helper.py) → 제외됨
#
# post-edit-hygiene 은 advisory (항상 exit 0) — "스캔됨" 은 print() WARNING 이
# stderr 에 나타나는 것으로, "제외됨" 은 WARNING 이 없는 것으로 검증한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# `*test_*` substring glob 은 latest_config.py 를 test 파일로 오인했다 →
# fix 후에는 스캔 대상이라 print() WARNING 이 나와야 한다.
test_hygiene_scans_non_test_source_with_test_substring() {
  printf 'print("hello")\n' > "$SANDBOX/latest_config.py"
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/latest_config.py"}}'
  run_hook "post-edit-hygiene.sh" "$input"
  assert_exit 0 "hygiene 은 advisory — 항상 exit 0"
  echo "$HOOK_STDERR" | grep -qF "print()" \
    || fail "latest_config.py 는 test 파일이 아님 — print() 스캔이 실행되어야 함 (stderr: $HOOK_STDERR)"
}

# basename 이 test_ 로 시작하는 진짜 테스트 파일은 여전히 제외된다.
test_hygiene_exempts_real_test_file() {
  printf 'print("hello")\n' > "$SANDBOX/test_helper.py"
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/test_helper.py"}}'
  run_hook "post-edit-hygiene.sh" "$input"
  assert_exit 0 "hygiene 은 advisory — 항상 exit 0"
  echo "$HOOK_STDERR" | grep -qF "print()" \
    && fail "test_helper.py 는 진짜 테스트 파일 — hygiene 스캔에서 제외되어야 함"
  return 0
}

main() {
  run_test test_hygiene_scans_non_test_source_with_test_substring  post-edit-hygiene.sh
  run_test test_hygiene_exempts_real_test_file                     post-edit-hygiene.sh
  summary
}

main "$@"
