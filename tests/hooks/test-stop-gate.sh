#!/bin/bash
# tests/hooks/test-stop-gate.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# stop-session-gate 는 오늘 날짜 inbox + 오늘 갱신된 index.md 를 요구하므로
# 모든 테스트에서 이 두 전제를 먼저 세팅한다.
seed_valid_session_state() {
  local today
  today=$(date +%Y-%m-%d)
  seed_inbox "${today}-session-marker.md" "# session marker"
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: stop gate
- next: verify
- note: fixture
EOF
  # index.md mtime 을 오늘로 보장
  touch "$SANDBOX/trail/index.md"
  # QA 세션 감지: 소스 편집이 있었던 세션으로 마킹 (없으면 gate 가 즉시 exit 0)
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
  # BG-1 contract: stop-session-gate.sh exits early when .rein/project.json is
  # absent ("bootstrap incomplete — incident gate skipped"), so the stale-DoD
  # WARNING loop is never reached. Seed the marker so the gate proceeds past
  # the bootstrap-incomplete escape hatch.
  mkdir -p "$SANDBOX/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.0.0"}' \
    > "$SANDBOX/.rein/project.json"
}

test_stop_gate_warns_on_stale_dod() {
  seed_valid_session_state

  # given: 20일 된 미완료 DoD (날짜가 박힌 파일명)
  local old
  old=$(date -v-20d +%Y-%m-%d 2>/dev/null || date -d '20 days ago' +%Y-%m-%d)
  seed_dod "dod-${old}-ghost.md" "# ghost"

  # when
  run_hook "stop-session-gate.sh"

  # then: 차단 안 함, stderr 에 경고
  assert_exit 0 "stale 경고는 차단 아님"
  assert_stderr_contains "WARNING"
  assert_stderr_contains "dod-${old}-ghost.md"
}

test_stop_gate_no_warning_for_fresh_dod() {
  seed_valid_session_state

  # given: 오늘 생성된 미완료 DoD
  local today
  today=$(date +%Y-%m-%d)
  seed_dod "dod-${today}-fresh.md" "# fresh"

  # when
  run_hook "stop-session-gate.sh"

  # then: WARNING 없음
  assert_exit 0
  echo "$HOOK_STDERR" | grep -qF "WARNING" \
    && fail "fresh dod 에 대해 WARNING 이 나옴" || true
}

test_stop_gate_threshold_boundary() {
  seed_valid_session_state

  # given: 정확히 14일 된 DoD (임계값 경계)
  local boundary
  boundary=$(date -v-14d +%Y-%m-%d 2>/dev/null || date -d '14 days ago' +%Y-%m-%d)
  seed_dod "dod-${boundary}-boundary.md" "# boundary"

  # when
  run_hook "stop-session-gate.sh"

  # then: 14일 이상(>=)은 경고
  assert_exit 0
  assert_stderr_contains "WARNING"
}

test_stop_gate_legacy_dod_skipped() {
  seed_valid_session_state

  # given: 레거시 포맷 (날짜 없음). 파일명에서 날짜를 못 추출하므로 경고 대상 아님
  seed_dod "dod-legacy-no-date.md" "# legacy"

  # when
  run_hook "stop-session-gate.sh"

  # then
  assert_exit 0
  echo "$HOOK_STDERR" | grep -qF "dod-legacy-no-date.md" \
    && fail "레거시 dod 가 stale 경고에 나타남" || true
}

main() {
  run_test test_stop_gate_warns_on_stale_dod      stop-session-gate.sh
  run_test test_stop_gate_no_warning_for_fresh_dod stop-session-gate.sh
  run_test test_stop_gate_threshold_boundary       stop-session-gate.sh
  run_test test_stop_gate_legacy_dod_skipped       stop-session-gate.sh
  summary
}

main "$@"
