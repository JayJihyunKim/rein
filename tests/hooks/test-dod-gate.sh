#!/bin/bash
# tests/hooks/test-dod-gate.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# 소스 편집을 시뮬레이션하는 JSON stdin
make_input() {
  # $1=file_path (샌드박스 기준 상대 경로)
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$abs"
}

test_gate_pending_dod_passes() {
  # given: pending dod (매칭 inbox 없음)
  seed_dod "dod-2026-04-13-new-feature.md" "# DoD new-feature"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"

  # then
  assert_exit 0 "pending dod 있으면 통과"
}

test_gate_matched_inbox_blocks() {
  # given: dod + 매칭 inbox (작업이 이미 완료됨)
  seed_dod "dod-2026-04-13-done-task.md" "# done"
  seed_inbox "2026-04-13-done-task.md" "# completed"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"

  # then: 새 작업에는 새 dod 가 필요
  assert_exit 2 "매칭 inbox 있는 dod 는 pending 아님 → 차단"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

test_gate_no_dod_blocks() {
  # given: dod 없음
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"

  # then
  assert_exit 2
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

test_gate_legacy_dod_ignored() {
  # given: 레거시 dod (날짜 없음) 만 있음
  seed_dod "dod-old-task.md" "# legacy"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"

  # then: 레거시는 신 포맷이 아니므로 pending 으로 치지 않음 → 차단
  assert_exit 2
}

test_gate_non_source_file_exempt() {
  # given: 소스 외 경로 (docs/)
  mkdir -p "$SANDBOX/docs"
  touch "$SANDBOX/docs/foo.md"

  # when
  run_hook "pre-edit-dod-gate.sh" "$(make_input docs/foo.md)"

  # then: 소스 경로 아니면 gate 자체가 적용 안 됨 → 통과
  assert_exit 0
}

test_gate_cache_invalidated_by_inbox_creation() {
  # given: pending dod (캐시 키에 mtime 혼입되므로 inbox 생성 시 무효화)
  seed_dod "dod-2026-04-13-task.md" "# DoD"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # 1차: 통과 (pending dod 있음) → 캐시 생성
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"
  assert_exit 0 "1차는 통과"

  # 매칭 inbox 생성 (작업 완료) → trail/inbox/ 디렉토리 mtime 변경
  sleep 1  # 디렉토리 mtime 분해능 확보
  seed_inbox "2026-04-13-task.md" "# done"

  # 2차: 캐시 키가 달라져야 하므로 재판정되어 차단
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"
  assert_exit 2 "inbox 생성 후 캐시 무효화되어 재판정 → 차단"
}

# ============================================================
# Windows Git Bash stub 시뮬레이션 테스트 (WGB-12c / Task 4.3)
#
# 검증 대상: pre-edit-dod-gate.sh 가 python-runner.sh resolver 를 통과 못하면
# [DoD gate] prefix + 분기별 메시지 (rc=10/11/12) + Windows 진단을 출력하고
# exit 2 로 차단한다.
#
# 시나리오: fake uname=MINGW (MSYS 환경 시뮬레이션) + fake python3 exit 49
# (Windows 9009 stub 가 8bit truncate 된 값). resolver 는 health_check 실패
# → `py -3` fallback 실패 (fake py 없음) → rc=12 (launch fail) 반환.
#
# 격리: 각 테스트는 subshell `( ... )` 안에서 with_fake_*/with_empty_path 를
# 호출해 PATH 변조가 다른 테스트로 누수되지 않게 한다. run_hook 대신 직접
# hook 을 bash 로 실행하는 것은 SANDBOX 바깥에서 PATH 가 상속되기 때문에
# 어쩔 수 없이 inline 호출이 필요하기 때문이다.
# ============================================================

# _invoke_gate_with_windows_stub <hook-relative-path-under-.claude/hooks>
#   subshell 안에서 fake python(exit 49) + fake uname(MINGW) 을 세팅하고
#   SANDBOX 에 복사된 hook 을 직접 실행. stdout 말미에 _RC=<exit> 를 덧붙여
#   exit code 를 caller 가 파싱할 수 있게 한다.
_invoke_gate_with_windows_stub() {
  # $1=hook filename, $2=stdin JSON
  local hook_name="$1"
  local stdin_json="$2"
  (
    # subshell: PATH/trap isolation
    with_empty_path
    with_fake_uname 'MINGW64_NT-10.0-22000'
    with_fake_python 49
    printf '%s' "$stdin_json" \
      | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$hook_name" 2>&1
    local rc=$?
    printf '_RC=%s\n' "$rc"
    cleanup_fakes
  )
}

test_gate_windows_stub_blocks_with_diagnostics() {
  # given: 일반 소스 경로 (path exemption 회피). DoD 상태는 관계없음 —
  #        resolver 가 FILE_PATH 추출 전에 실패하므로 gate 는 결코 path 검사에
  #        도달하지 않는다.
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when: fake Windows Git Bash 환경으로 hook 실행
  local out rc
  out=$(_invoke_gate_with_windows_stub \
    "pre-edit-dod-gate.sh" \
    "$(make_input scripts/foo.sh)")
  rc=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)

  # then: exit 2 + [rein] prefix + Windows 진단 키워드 (9009/WSL2/
  #       App execution alias 중 하나 이상)
  [ "$rc" = "2" ] \
    || fail "expected exit 2, got rc='$rc' (out first lines: $(printf '%s' "$out" | head -3 | tr '\n' ' | '))"
  printf '%s' "$out" | grep -qF "[rein]" \
    || fail "stderr missing '[rein]' prefix (out: $(printf '%s' "$out" | head -5 | tr '\n' ' | '))"
  printf '%s' "$out" | grep -qE '9009|WSL2|App execution alias' \
    || fail "stderr missing Windows diagnostics keyword (9009/WSL2/App execution alias)"
}

test_gate_posix_host_resolver_unchanged() {
  # 회귀 보증: fake 없이 실제 macOS/Linux 호스트에서는 기존 테스트들(=pending
  # DoD 통과 / 매칭 inbox 차단 등) 이 이미 그대로 green 이다. 이 테스트는
  # resolver 실패 분기가 POSIX 호스트에서 트리거되지 않음을 명시적으로 확인한다.
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"
  seed_dod "dod-2026-04-13-unchanged.md" "# DoD"

  # when: 환경 변경 없이 (host python3 사용)
  run_hook "pre-edit-dod-gate.sh" "$(make_input scripts/foo.sh)"

  # then: resolver 관련 메시지 없이 DoD 판정만 수행 → 통과
  assert_exit 0 "host python3 사용 시 resolver 실패 분기 미트리거"
  echo "$HOOK_STDERR" | grep -qF "[rein] The edit gate cannot run" \
    && fail "POSIX 호스트에서는 [rein] resolver 에러 메시지가 나오면 안 됨"
  echo "$HOOK_STDERR" | grep -qE '9009|WSL2|App execution alias' \
    && fail "POSIX 호스트에서는 Windows 진단이 나오면 안 됨"
  return 0
}

main() {
  run_test test_gate_pending_dod_passes              pre-edit-dod-gate.sh
  run_test test_gate_matched_inbox_blocks            pre-edit-dod-gate.sh
  run_test test_gate_no_dod_blocks                   pre-edit-dod-gate.sh
  run_test test_gate_legacy_dod_ignored              pre-edit-dod-gate.sh
  run_test test_gate_non_source_file_exempt          pre-edit-dod-gate.sh
  run_test test_gate_cache_invalidated_by_inbox_creation pre-edit-dod-gate.sh
  run_test test_gate_windows_stub_blocks_with_diagnostics pre-edit-dod-gate.sh
  run_test test_gate_posix_host_resolver_unchanged   pre-edit-dod-gate.sh
  summary
}

main "$@"
