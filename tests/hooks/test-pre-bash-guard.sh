#!/bin/bash
# tests/hooks/test-pre-bash-guard.sh
#
# Test suites:
#
# 1. Windows Git Bash stub (existing, WGB-12c / Task 4.3 Step 2).
# 2. BLOCK_MARKERS array (Plan A Phase 5 / GI-dod-mismatch-marker-consumer).
#    Verifies pre-bash-guard consumes both legacy `.coverage-mismatch` (plan
#    coverage) and new `.dod-coverage-mismatch` (DoD coverage) as blocking
#    markers, while leaving `.dod-coverage-advisory` non-blocking.
#
# Test isolation:
#   - Each test runs inside `run_test` → sandbox_setup → sandbox_teardown.
#   - Stamp + DoD + inbox are seeded to isolate the marker gate as the sole
#     failure cause (other gates must pass).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# ============================================================
# Suite 1: Windows Git Bash stub (unchanged).
# ============================================================

# _invoke_guard_with_windows_stub <stdin-json>
#   subshell 안에서 fake python(exit 49) + fake uname(MINGW) 을 세팅하고
#   SANDBOX 에 복사된 pre-bash-guard.sh 를 실행. stdout 말미에 _RC=<exit> 를
#   덧붙여 caller 가 exit code 를 파싱할 수 있게 한다.
_invoke_guard_with_windows_stub() {
  local stdin_json="$1"
  (
    with_empty_path
    with_fake_uname 'MINGW64_NT-10.0-22000'
    with_fake_python 49
    printf '%s' "$stdin_json" \
      | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/pre-bash-guard.sh" 2>&1
    local rc=$?
    printf '_RC=%s\n' "$rc"
    cleanup_fakes
  )
}

test_pre_bash_guard_windows_stub_blocks() {
  local stdin_json='{"tool_input":{"command":"ls -la"}}'

  local out rc
  out=$(_invoke_guard_with_windows_stub "$stdin_json")
  rc=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)

  [ "$rc" = "2" ] \
    || fail "expected exit 2, got rc='$rc' (out first lines: $(printf '%s' "$out" | head -3 | tr '\n' ' | '))"
  printf '%s' "$out" | grep -qF "[Bash guard]" \
    || fail "stderr missing '[Bash guard]' prefix (out: $(printf '%s' "$out" | head -5 | tr '\n' ' | '))"
  printf '%s' "$out" | grep -qE '9009|WSL2|App execution alias' \
    || fail "stderr missing Windows diagnostics keyword (9009/WSL2/App execution alias)"
}

test_pre_bash_guard_posix_resolver_unchanged() {
  local stdin_json='{"tool_input":{"command":"ls -la"}}'
  run_hook "pre-bash-guard.sh" "$stdin_json"

  assert_exit 0 "host python3 사용 + 안전 명령이므로 통과"
  echo "$HOOK_STDERR" | grep -qF "[Bash guard]" \
    && fail "POSIX 호스트에서는 [Bash guard] resolver 에러가 나오면 안 됨"
  echo "$HOOK_STDERR" | grep -qE '9009|WSL2|App execution alias' \
    && fail "POSIX 호스트에서는 Windows 진단이 나오면 안 됨"
  return 0
}

# ============================================================
# Suite 2: BLOCK_MARKERS (Plan A Phase 5).
# ============================================================
#
# Fixture contract for these tests: stamps + DoD + inbox are seeded so the
# *only* blocking gate in play is the coverage-marker array. run_hook uses
# SANDBOX/.claude/hooks/pre-bash-guard.sh which requires:
#   - the hook itself
#   - lib/extract-commit-msg.py (for commit-msg helper — pre-bash-guard BLOCKs
#     if helper missing)
#   - stamp files under trail/dod
#
# assert_stderr_contains / assert_exit come from the harness.

_seed_review_stamps() {
  # Copy the commit-msg helper so the `git commit` gate doesn't fail open.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/.claude/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-21-marker-test.md"
  seed_inbox "2026-04-21-marker-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
}

# Scenario 1: only .coverage-mismatch exists → exit 2.
test_block_markers_coverage_mismatch_blocks_commit() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "plan coverage marker should block commit"
  assert_stderr_contains ".coverage-mismatch"
}

# Scenario 2: only .dod-coverage-mismatch exists → exit 2.
test_block_markers_dod_coverage_mismatch_blocks_commit() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "DoD coverage marker should block commit"
  assert_stderr_contains ".dod-coverage-mismatch"
}

# Scenario 3: both markers exist → exit 2 (legacy first per iteration order).
test_block_markers_both_markers_block_commit() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.coverage-mismatch"
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "both markers should block commit"
  # Iteration order is fixed: .coverage-mismatch first, so its message wins.
  assert_stderr_contains ".coverage-mismatch"
}

# Scenario 4: neither marker → coverage gate should not fire; commit proceeds.
test_block_markers_neither_marker_passes() {
  _seed_review_stamps
  # Explicitly no markers.

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  # stderr must not contain the coverage-matrix block message.
  echo "$HOOK_STDERR" | grep -qF "coverage matrix 검증 실패" \
    && fail "coverage gate fired without any marker present"
  echo "$HOOK_STDERR" | grep -qF ".dod-coverage-mismatch" \
    && fail "DoD coverage gate fired without any marker present"
  return 0
}

# Scenario 5: only .dod-coverage-advisory → advisory marker must NOT block.
test_block_markers_advisory_does_not_block() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.dod-coverage-advisory"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  # Advisory marker must never be in BLOCK_MARKERS.
  echo "$HOOK_STDERR" | grep -qF ".dod-coverage-advisory" \
    && fail ".dod-coverage-advisory should be non-blocking, but guard cited it"
  return 0
}

# Scenario 6: .dod-coverage-mismatch blocks pytest as well as commit.
test_block_markers_dod_marker_blocks_pytest() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  local input='{"tool_input":{"command":"pytest tests/"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "DoD coverage marker should block pytest"
  assert_stderr_contains ".dod-coverage-mismatch"
}

# ============================================================
# Suite 3: Pipe-bash block (rein-dev wrapper-context-lifecycle 후속)
# ============================================================
#
# Hook line 107 은 `(^|[[:space:]])\| *(bash|sh)( |$)` 패턴으로 stdin pipe 을
# 흘려넣는 shell 호출을 차단한다. 38회 누적 incident 의 근본 원인:
# (a) Claude 가 wrapper 호출 시 자연스럽게 pipe 사용 + (b) 차단 메시지에 우회
# 안내 부재 + (c) 일부 false positive (alternation 안 substring).
#
# 본 Suite 는 fix 후 동작을 검증:
#   3.1 — 진짜 pipe-bash 차단 + 새 우회 가이드 메시지 노출
#   3.2 — alternation 안 `|bash` substring (grep 인자) 는 통과 (false positive 해소)
#   3.3 — file redirect 형태는 통과 (정상 우회 패턴)

# Scenario 3.1: pipe + bash + script path → block + 우회 가이드 메시지
test_pipe_bash_blocks_with_redirect_hint() {
  local input='{"tool_input":{"command":"printf hello | bash scripts/wrapper.sh"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "pipe + bash + script 는 차단되어야 함"
  assert_stderr_contains "파이프로 쉘 스크립트 실행"
  assert_stderr_contains "file redirect"
  assert_stderr_contains "bash <script> < /tmp/<input>.txt"
}

# Scenario 3.2: grep alternation 안 `|bash` substring → 통과 (false positive 해소)
test_pipe_bash_pattern_false_positive_in_grep_alternation_passes() {
  # Quote 안의 `|bash` 는 shell pipe 가 아님. word-boundary 로 false-positive 차단.
  local input='{"tool_input":{"command":"grep -E \"x|bash tests\" file.md | head -3"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  # pipe 자체는 있으나 (`grep ... | head`), bash/sh 토큰이 pipe 직후가 아님.
  echo "$HOOK_STDERR" | grep -qF "파이프로 쉘 스크립트 실행" \
    && fail "alternation 안 |bash substring 이 차단됨 (false positive)"
  return 0
}

# Scenario 3.3: file redirect 형태 → 통과 (정상 우회)
test_bash_with_file_redirect_passes() {
  local input='{"tool_input":{"command":"bash scripts/wrapper.sh < /tmp/prompt.txt"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  echo "$HOOK_STDERR" | grep -qF "파이프로 쉘 스크립트 실행" \
    && fail "file redirect 가 잘못 차단됨"
  return 0
}

main() {
  # Suite 1
  run_test test_pre_bash_guard_windows_stub_blocks       pre-bash-guard.sh
  run_test test_pre_bash_guard_posix_resolver_unchanged  pre-bash-guard.sh
  # Suite 2 — BLOCK_MARKERS (Plan A Phase 5)
  run_test test_block_markers_coverage_mismatch_blocks_commit      pre-bash-guard.sh
  run_test test_block_markers_dod_coverage_mismatch_blocks_commit  pre-bash-guard.sh
  run_test test_block_markers_both_markers_block_commit            pre-bash-guard.sh
  run_test test_block_markers_neither_marker_passes                pre-bash-guard.sh
  run_test test_block_markers_advisory_does_not_block              pre-bash-guard.sh
  run_test test_block_markers_dod_marker_blocks_pytest             pre-bash-guard.sh
  # Suite 3 — Pipe-bash block (A + B fix)
  run_test test_pipe_bash_blocks_with_redirect_hint                              pre-bash-guard.sh
  run_test test_pipe_bash_pattern_false_positive_in_grep_alternation_passes      pre-bash-guard.sh
  run_test test_bash_with_file_redirect_passes                                   pre-bash-guard.sh
  summary
}

main "$@"
