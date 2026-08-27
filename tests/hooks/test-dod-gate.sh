#!/bin/bash
# tests/hooks/test-dod-gate.sh
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대, 2026-08-21): pre-edit-dod-gate.sh 는
# 삭제되고 pre-edit-discipline-gate.sh + pre-edit-task-gate.sh 로 교대된다.
#
# 이 파일이 검증하던 lib/dod-found.sh 의 스캔(신 포맷 dod-*.md 존재 여부 +
# 매칭 inbox 제외 + 레거시(날짜 없음) 파일 무시) 자체는 여전히
# pre-edit-discipline-gate.sh 가 소유한다(계약상 "dod-found" 는 discipline-gate
# 의 몫) — spec-review-gate/routing-gate 가 "활성 작업이 있는가" 를 판단하는
# 선행조건으로 계속 쓰인다.
#
# 그러나 예전에 이 스캔 결과(DOD_FOUND)를 근거로 "활성 작업 없음 → 소스 편집
# 차단"(exit 2, "[rein] Source files cannot be edited yet") 을 최종 판정하던
# 로직은 활성작업(active-task) 축 전체와 함께 pre-edit-task-gate.sh 로
# 이관됐고, 그 축의 v1 폴백 판정 자체가 소멸했다(task-gate 계약: 미전환 상태는
# exit 0, 전환 상태의 최종 판정은 전적으로 v2 위임에 맡긴다 — dod-found.sh 의
# "매칭 inbox 제외"·"레거시 무시" 같은 스캔 세부 규칙은 v2 판정 엔진에
# 그대로 이식된다는 보장이 없다). 그 결과 discipline-gate 는 이제 DOD_FOUND
# 값과 무관하게 항상 통과(exit 0)한다 — 아래 세 시나리오(매칭 inbox / DoD
# 전무 / 레거시 DoD)는 "여전히 차단"에서 "이제는 discipline-gate 단독으로는
# 차단하지 않는다"로 성격이 바뀌었다. 케이스 자체는 삭제하지 않고 새 계약을
# 고정하는 characterization test 로 전환한다(신규 케이스 (c) 의 구체 사례).

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
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"

  # then
  assert_exit 0 "pending dod 있으면 통과"
}

# ---- 이하 세 테스트: 구 v1 active-task 폴백의 "차단" 단언 → discipline-gate
# 단독으로는 더 이상 차단하지 않는다는 characterization 으로 전환
# (2026-08-21, 편집 게이트 교대). 차단 semantics 자체를 검증하려면
# tests/hooks/test-active-task-authority-switch.sh (v2 위임 ALLOW/DENY/FAIL
# 전체 배선) 를 참조 — 단, 그 스위트는 dod-found.sh 의 "매칭 inbox
# 제외"·"레거시 무시" 세부 규칙을 재현하지 않는다(v2 판정 엔진은 이 스캔과
# 무관하게 자신의 상태로 판정하므로).

test_gate_matched_inbox_no_longer_blocks_at_discipline_gate() {
  # given: dod + 매칭 inbox (작업이 이미 완료됨 → DOD_FOUND=false)
  seed_dod "dod-2026-04-13-done-task.md" "# done"
  seed_inbox "2026-04-13-done-task.md" "# completed"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"

  # then: discipline-gate 는 활성작업 판정을 하지 않으므로 통과 — 차단은
  # (전환된 경우) task-gate 의 v2 위임 몫이다.
  assert_exit 0 "매칭 inbox 있는 dod (DOD_FOUND=false) 여도 discipline-gate 단독으로는 차단하지 않음"
}

test_gate_no_dod_no_longer_blocks_at_discipline_gate() {
  # given: dod 없음 (DOD_FOUND=false)
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"

  # then
  assert_exit 0 "DoD 가 전혀 없어도(DOD_FOUND=false) discipline-gate 단독으로는 차단하지 않음"
}

test_gate_legacy_dod_no_longer_blocks_at_discipline_gate() {
  # given: 레거시 dod (날짜 없음) 만 있음 → 신 포맷이 아니므로 여전히
  # DOD_FOUND=false 로 스캔됨(dod-found.sh 스캔 규칙 자체는 불변)
  seed_dod "dod-old-task.md" "# legacy"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # when
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"

  # then: 레거시 dod 는 여전히 pending 으로 치지 않지만(스캔 규칙 불변),
  # 그 사실 자체가 이제는 discipline-gate 를 차단시키지 않는다.
  assert_exit 0 "레거시(날짜 없음) dod 만 있어도(DOD_FOUND=false) discipline-gate 단독으로는 차단하지 않음"
}

test_gate_non_source_file_exempt() {
  # given: 소스 외 경로 (docs/)
  mkdir -p "$SANDBOX/docs"
  touch "$SANDBOX/docs/foo.md"

  # when
  run_hook "pre-edit-discipline-gate.sh" "$(make_input docs/foo.md)"

  # then: 소스 경로 아니면 gate 자체가 적용 안 됨 → 통과
  assert_exit 0
}

test_gate_repeat_invocation_after_inbox_creation_stays_consistent() {
  # given: pending dod (Plan A Phase 4 Task 4.3 — 세션 캐시 제거, 매 호출마다
  # 재스캔). 예전엔 "1차 통과 → inbox 생성으로 캐시 무효화 → 2차 차단" 을
  # 검증했다. discipline-gate 는 이제 DOD_FOUND 값으로 차단하지 않으므로,
  # 캐시 없음(매 호출 재스캔) 자체는 여전히 유효한 불변식이지만 그 관측
  # 가능한 결과는 "양쪽 다 통과"로 바뀌었다 — 재호출이 예외 없이 일관되게
  # 동작함(캐시가 stale 상태를 만들어 크래시하거나 다른 분기로 새지 않음)을
  # characterize 한다.
  seed_dod "dod-2026-04-13-task.md" "# DoD"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # 1차: 통과
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"
  assert_exit 0 "1차는 통과"

  # 매칭 inbox 생성 (작업 완료) → trail/inbox/ 디렉토리 mtime 변경
  sleep 1  # 디렉토리 mtime 분해능 확보
  seed_inbox "2026-04-13-task.md" "# done"

  # 2차: 재스캔되어도(캐시 없음) discipline-gate 는 여전히 통과
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"
  assert_exit 0 "inbox 생성 후 재스캔되어도 discipline-gate 단독으로는 여전히 통과"
}

# ============================================================
# Windows Git Bash stub 시뮬레이션 테스트 (WGB-12c / Task 4.3)
#
# 검증 대상: pre-edit-discipline-gate.sh 가 python-runner.sh resolver 를
# 통과 못하면 [rein] prefix + 분기별 메시지 (rc=10/11/12) + Windows 진단을
# 출력하고 exit 2 로 차단한다. 이 하드닝은 discipline-gate/task-gate 양쪽
# 모두 resolve_python 을 최상단에서 호출하므로 원칙적으로 공유되지만, 이
# 스위트는 (구 dod-gate 의) 본체 로직을 대부분 물려받은 discipline-gate 만
# 검증한다.
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
    "pre-edit-discipline-gate.sh" \
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
  # 회귀 보증: fake 없이 실제 macOS/Linux 호스트에서는 기존 테스트들이 이미
  # 그대로 green 이다. 이 테스트는 resolver 실패 분기가 POSIX 호스트에서
  # 트리거되지 않음을 명시적으로 확인한다.
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"
  seed_dod "dod-2026-04-13-unchanged.md" "# DoD"

  # when: 환경 변경 없이 (host python3 사용)
  run_hook "pre-edit-discipline-gate.sh" "$(make_input scripts/foo.sh)"

  # then: resolver 관련 메시지 없이 통과
  assert_exit 0 "host python3 사용 시 resolver 실패 분기 미트리거"
  echo "$HOOK_STDERR" | grep -qF "[rein] The edit gate cannot run" \
    && fail "POSIX 호스트에서는 [rein] resolver 에러 메시지가 나오면 안 됨"
  echo "$HOOK_STDERR" | grep -qE '9009|WSL2|App execution alias' \
    && fail "POSIX 호스트에서는 Windows 진단이 나오면 안 됨"
  return 0
}

main() {
  run_test test_gate_pending_dod_passes              pre-edit-discipline-gate.sh
  run_test test_gate_matched_inbox_no_longer_blocks_at_discipline_gate    pre-edit-discipline-gate.sh
  run_test test_gate_no_dod_no_longer_blocks_at_discipline_gate           pre-edit-discipline-gate.sh
  run_test test_gate_legacy_dod_no_longer_blocks_at_discipline_gate       pre-edit-discipline-gate.sh
  run_test test_gate_non_source_file_exempt          pre-edit-discipline-gate.sh
  run_test test_gate_repeat_invocation_after_inbox_creation_stays_consistent pre-edit-discipline-gate.sh
  run_test test_gate_windows_stub_blocks_with_diagnostics pre-edit-discipline-gate.sh
  run_test test_gate_posix_host_resolver_unchanged   pre-edit-discipline-gate.sh
  summary
}

main "$@"
