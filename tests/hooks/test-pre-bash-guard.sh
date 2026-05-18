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
# Classification: [I1] infra integrity — python3 resolver failure.
# Contract: exit 2 + stderr. NOT converted to JSON deny.
# Ref: docs/specs/2026-05-17-hook-message-assistant-tone.md §1
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
  printf '%s' "$out" | grep -qF "[rein]" \
    || fail "stderr missing '[rein]' prefix (out: $(printf '%s' "$out" | head -5 | tr '\n' ' | '))"
  printf '%s' "$out" | grep -qE '9009|WSL2|App execution alias' \
    || fail "stderr missing Windows diagnostics keyword (9009/WSL2/App execution alias)"
}

test_pre_bash_guard_posix_resolver_unchanged() {
  local stdin_json='{"tool_input":{"command":"ls -la"}}'
  run_hook "pre-bash-guard.sh" "$stdin_json"

  assert_exit 0 "host python3 사용 + 안전 명령이므로 통과"
  echo "$HOOK_STDERR" | grep -qF "[rein] The Bash guard cannot run" \
    && fail "POSIX 호스트에서는 [rein] resolver 에러가 나오면 안 됨"
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
#
# Classification (OQ4 corrected):
#   Scenario 1/2/3/6: empty marker → revalidate_coverage_marker rc=2 → [I3]
#     infra integrity (target unidentifiable) → exit 2 PRESERVED. NOT JSON deny.
#   Scenario 4/5: no marker / advisory marker → pass-through. Unchanged.
#   The real P2 (rc=1, identifiable failing target) is covered by Suite 5
#   (Task 2.5 Step 2) which seeds a non-empty marker with a failing target.

_seed_review_stamps() {
  # Copy the commit-msg helper so the `git commit` gate doesn't fail open.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-21-marker-test.md"
  seed_inbox "2026-04-21-marker-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
}

# Scenario 1: only .coverage-mismatch exists (empty) → exit 2.
# [I3] empty marker → rc=2 (target unidentifiable) → exit 2 PRESERVED (not JSON deny).
test_block_markers_coverage_mismatch_blocks_commit() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "plan coverage marker should block commit"
  assert_stderr_contains ".coverage-mismatch"
}

# Scenario 2: only .dod-coverage-mismatch exists (empty, no .active-dod) → exit 2.
# [I3] empty marker → rc=2 (target unidentifiable) → exit 2 PRESERVED (not JSON deny).
test_block_markers_dod_coverage_mismatch_blocks_commit() {
  _seed_review_stamps
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_exit 2 "DoD coverage marker should block commit"
  assert_stderr_contains ".dod-coverage-mismatch"
}

# Scenario 3: both markers exist (both empty) → exit 2 (legacy first per iteration order).
# [I3] empty marker → rc=2 (target unidentifiable) → exit 2 PRESERVED (not JSON deny).
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

# Scenario 6: .dod-coverage-mismatch (empty) blocks pytest as well as commit.
# [I3] empty marker → rc=2 (target unidentifiable) → exit 2 PRESERVED (not JSON deny).
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

# Scenario 3.1: pipe + bash + script path → JSON deny PIPE_SHELL_BLOCKED
# (P1 was converted from exit 2 + stderr to exit 0 + JSON deny in Task 2.2)
test_pipe_bash_blocks_with_redirect_hint() {
  local input='{"tool_input":{"command":"printf hello | bash scripts/wrapper.sh"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "PIPE_SHELL_BLOCKED" "pipe + bash + script 는 JSON deny 를 발행해야 함"
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

# ============================================================
# assert_json_deny helper
# Asserts: HOOK_EXIT==0, stdout is valid JSON,
# permissionDecision=="deny", and reason_code appears in
# permissionDecisionReason.
# Usage: assert_json_deny "REASON_CODE" ["message for failure"]
# ============================================================
assert_json_deny() {
  local reason_code="$1"
  local msg="${2:-JSON deny with reason_code=$reason_code}"
  # exit 0
  [ "$HOOK_EXIT" = "0" ] \
    || fail "$msg: expected exit 0 (JSON deny), got exit $HOOK_EXIT"
  # valid JSON with permissionDecision=deny
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecision"])
' 2>/dev/null)
  [ "$decision" = "deny" ] \
    || fail "$msg: permissionDecision not \"deny\" (got: '$decision', stdout: $HOOK_STDOUT)"
  # reason_code present in permissionDecisionReason
  local pdr
  pdr=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecisionReason"])
' 2>/dev/null)
  case "$pdr" in
    *"$reason_code"*) ;;
    *) fail "$msg: reason_code '$reason_code' not found in permissionDecisionReason: '$pdr'" ;;
  esac
}

# ============================================================
# Suite 4: JSON deny — P1, P7, P8, P11 representative (Task 2.2)
# ============================================================

# Suite 4 Scenario 4.1: P1 — pipe + bash → JSON deny PIPE_SHELL_BLOCKED
test_json_deny_p1_pipe_bash() {
  local input='{"tool_input":{"command":"printf hello | bash scripts/wrapper.sh"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "PIPE_SHELL_BLOCKED" "P1 pipe-bash should emit JSON deny"
}

# Suite 4 Scenario 4.2: P7 — bad commit msg format → JSON deny COMMIT_MSG_FORMAT
test_json_deny_p7_commit_msg_format() {
  _seed_review_stamps
  # Bad commit message: missing conventional commits type
  local input='{"tool_input":{"command":"git commit -m \"bad message without type\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "COMMIT_MSG_FORMAT" "P7 bad commit msg should emit JSON deny"
}

# Suite 4 Scenario 4.3: P8 — cat .env → JSON deny ENV_READ_BLOCKED
test_json_deny_p8_env_read() {
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "P8 cat .env should emit JSON deny"
}

# Suite 4 Scenario 4.4: P11 — git reset --hard → JSON deny DESTRUCTIVE_GIT_CONFIRM
test_json_deny_p11_destructive_git() {
  local input='{"tool_input":{"command":"git reset --hard HEAD~1"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "DESTRUCTIVE_GIT_CONFIRM" "P11 destructive git should emit JSON deny"
}

# ============================================================
# Suite 5: JSON deny regression — P2, P3, P4, P5, P6 (Task 2.5)
# ============================================================
#
# OQ4 corrected classification:
#   P2 — rc=1 (validator FAIL, identifiable target) → JSON deny COVERAGE_MISMATCH
#   P3 — .review-pending present + no .codex-reviewed → JSON deny REVIEW_PENDING_NO_STAMP
#   P4 — .review-pending newer than .codex-reviewed → JSON deny CODE_EDITED_AFTER_REVIEW
#   P5 — DoD present + no .review-pending + no .codex-reviewed → JSON deny CODEX_STAMP_MISSING
#   P6 — DoD present + .codex-reviewed + no .security-reviewed → JSON deny SECURITY_STAMP_MISSING
#
# P2 fixture: drop a stub validator at SANDBOX/scripts/ (resolve_helper_script
# priority 2: PROJECT_DIR/scripts/). Non-empty .coverage-mismatch with a
# failing target triggers revalidate_coverage_marker rc=1 → [P2] JSON deny.
#
# P3-P6 fixture: DoD seed + .review-pending seed (P3/P4) or stamps absent (P5/P6).
# Input: `git commit -m "feat: test"` — passes through P1/P2 gates to reach
# check_review_stamp() which houses P3-P6.

# Shared fixture: put a stub validator in the sandbox that fails for any target
# not containing literal "VALIDATOR_PASS".
_seed_stub_validator() {
  mkdir -p "$SANDBOX/scripts"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
#!/usr/bin/env python3
import sys
if len(sys.argv) < 3:
    sys.exit(2)
path = sys.argv[2]
try:
    with open(path) as f:
        if "VALIDATOR_PASS" in f.read():
            sys.exit(0)
    sys.exit(1)
except OSError:
    sys.exit(2)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
}

# Suite 5 Scenario 5.1: P2 — non-empty .coverage-mismatch with failing target → JSON deny
# [P2] rc=1 (validator FAIL, identifiable target) → exit 0 + JSON deny COVERAGE_MISMATCH.
# Counterpart to Suite 2 Scenario 1 (empty marker → [I3] exit 2 preserved).
test_json_deny_p2_coverage_mismatch_failing_target() {
  _seed_stub_validator
  # Put a plan file that the stub validator will FAIL (no "VALIDATOR_PASS" content).
  mkdir -p "$SANDBOX/docs/plans"
  echo "# Plan without validator pass token" > "$SANDBOX/docs/plans/failing-plan.md"
  # Seed the marker with the failing plan path.
  printf '%s\n' "$SANDBOX/docs/plans/failing-plan.md" \
    > "$SANDBOX/trail/dod/.coverage-mismatch"
  # Also seed stamps/dod/inbox so the only blocking gate is the coverage marker.
  seed_dod "dod-2026-04-21-p2-test.md"
  seed_inbox "2026-04-21-p2-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"

  local input='{"tool_input":{"command":"git commit -m \"feat: p2-test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "COVERAGE_MISMATCH" \
    "P2: non-empty .coverage-mismatch with failing target should emit JSON deny"
}

# Suite 5 Scenario 5.2: P3 — .review-pending + no .codex-reviewed → JSON deny
# [P3] HIGH-2: deny_emit inside check_review_stamp() calls exit, not return.
test_json_deny_p3_review_pending_no_stamp() {
  _seed_review_stamps
  # Remove .codex-reviewed so P3 fires (.review-pending present → no stamp).
  rm -f "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.review-pending"

  local input='{"tool_input":{"command":"git commit -m \"feat: p3-test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "REVIEW_PENDING_NO_STAMP" \
    "P3: .review-pending present but no .codex-reviewed should emit JSON deny"
}

# Suite 5 Scenario 5.3: P4 — .review-pending newer than .codex-reviewed → JSON deny
# [P4] HIGH-2: deny_emit inside check_review_stamp() calls exit, not return.
test_json_deny_p4_code_edited_after_review() {
  _seed_review_stamps
  # Make .codex-reviewed older than .review-pending so the staleness check fires.
  touch -t 202601010000 "$SANDBOX/trail/dod/.codex-reviewed"
  sleep 1
  touch "$SANDBOX/trail/dod/.review-pending"

  local input='{"tool_input":{"command":"git commit -m \"feat: p4-test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "CODE_EDITED_AFTER_REVIEW" \
    "P4: .review-pending newer than .codex-reviewed should emit JSON deny"
}

# Suite 5 Scenario 5.4: P5 — DoD exists + no .review-pending + no .codex-reviewed
# → JSON deny CODEX_STAMP_MISSING.
# [P5] HIGH-2: deny_emit inside check_review_stamp() calls exit, not return.
test_json_deny_p5_codex_stamp_missing() {
  # Seed DoD + inbox but no stamps.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-21-p5-test.md"
  seed_inbox "2026-04-21-p5-test.md"
  # Explicitly no .codex-reviewed, no .review-pending, no .security-reviewed.

  local input='{"tool_input":{"command":"git commit -m \"feat: p5-test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" \
    "P5: DoD exists but no .codex-reviewed should emit JSON deny"
}

# Suite 5 Scenario 5.5: P6 — DoD exists + .codex-reviewed + no .security-reviewed
# → JSON deny SECURITY_STAMP_MISSING.
# [P6] HIGH-2: deny_emit inside check_review_stamp() calls exit, not return.
test_json_deny_p6_security_stamp_missing() {
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-21-p6-test.md"
  seed_inbox "2026-04-21-p6-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  # Explicitly no .security-reviewed.

  local input='{"tool_input":{"command":"git commit -m \"feat: p6-test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "P6: .codex-reviewed present but no .security-reviewed should emit JSON deny"
}

# ============================================================
# Suite 6: P9, P10 direct JSON deny + emitter-unavailable fail-closed
# ============================================================
#
# P9  — git add -A with .env present → JSON deny ENV_STAGE_BLOCKED
# P10 — git commit -am with .env present → JSON deny ENV_COMMIT_AM_BLOCKED
# I6  — emitter (json-deny-emitter.sh) absent from sandbox lib/ → exit 2,
#        no JSON on stdout. This is the regression test that would have caught
#        the "rc=127, exit 127" defect fixed by the [I6] guard in Fix 1.

# Scenario 6.1: P9 — git add -A with .env present → JSON deny ENV_STAGE_BLOCKED
# [P9] policy block: exit 0 + JSON deny. NOT an infra error.
test_json_deny_p9_env_stage_blocked() {
  # Seed a .env file in the sandbox root so the P9 condition fires.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git add -A"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_STAGE_BLOCKED" \
    "P9: git add -A with .env present should emit JSON deny ENV_STAGE_BLOCKED"
}

# Scenario 6.2: P10 — git commit -am with .env present → JSON deny ENV_COMMIT_AM_BLOCKED
# [P10] policy block: exit 0 + JSON deny. NOT an infra error.
# Seeds review stamps so the commit reaches the P10 gate (not blocked earlier by P5/P6).
test_json_deny_p10_env_commit_am_blocked() {
  # Seed review stamps so commit-related gates (P5/P6) pass and P10 fires.
  _seed_review_stamps
  # Seed a .env file in the sandbox root so the P10 condition fires.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -am \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" \
    "P10: git commit -am with .env present should emit JSON deny ENV_COMMIT_AM_BLOCKED"
}

# Scenario 6.3: emitter unavailable — hook exits 2 with no JSON on stdout.
# [I6] infra integrity regression: when json-deny-emitter.sh is absent from the
# sandbox lib/, deny_emit is undefined. The [I6] guard added by Fix 1 must detect
# this and exit 2 (+ stderr), NOT exit 127 or exit 0. No JSON must appear on
# stdout (an exit-0 empty or malformed stdout would be fail-open).
# Technique: remove json-deny-emitter.sh from the sandbox lib/ AFTER sandbox_setup
# copies it (sandbox_setup runs before this test function body), then run a
# policy-blocking input (cat .env → would trigger P8) to confirm the guard fires
# before any policy block executes.
test_emitter_unavailable_fails_closed() {
  # Remove the emitter from the sandbox so deny_emit is never defined.
  rm -f "$SANDBOX/.claude/hooks/lib/json-deny-emitter.sh"

  # Use a P8-triggering input: "cat .env" would call deny_emit if the emitter
  # were present. With the emitter absent the [I6] guard must fire first.
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"

  # Must exit 2 (infra integrity block) — NOT 127 (undefined command) or 0 (fail-open).
  [ "$HOOK_EXIT" = "2" ] \
    || fail "emitter-unavailable: expected exit 2, got exit $HOOK_EXIT (was the [I6] guard added?)"

  # Must NOT emit any JSON on stdout (exit 0 + JSON would be fail-open).
  if [ -n "$HOOK_STDOUT" ]; then
    # Any stdout with exit!=0 is unusual; any valid JSON permissionDecision deny
    # on stdout is outright wrong since the exit code was 2 (Claude Code ignores
    # JSON on exit!=0, but the test still verifies the correct contract).
    local decision
    decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
    print(data.get("hookSpecificOutput",{}).get("permissionDecision","none"))
except Exception:
    print("not-json")
' 2>/dev/null)
    [ "$decision" = "not-json" ] \
      || fail "emitter-unavailable: got JSON deny on stdout despite exit 2 — fail-open risk (decision=$decision)"
  fi

  # Stderr must contain the [I6] diagnostic (not be silent).
  [ -n "$HOOK_STDERR" ] \
    || fail "emitter-unavailable: stderr was empty — the [I6] guard should emit a diagnostic message"
}


# Scenario 6.4: emitter removed AND a fake deny_emit executable placed on PATH.
# [I6] bypass regression: the old `command -v deny_emit` guard would pass when a
# stray deny_emit binary exists on PATH, even though the shell function was never
# defined. This would allow policy blocks to call the external binary (rc=127 or
# rc=0 from the fake), producing fail-open behavior. The Fix 1 `declare -F`
# guard closes this by requiring deny_emit to be a defined SHELL FUNCTION.
# With Fix 1 applied: the hook must still exit 2 (infra integrity) even when a
# deny_emit executable is reachable on PATH.
test_emitter_unavailable_fake_deny_emit_on_path_fails_closed() {
  # Remove the emitter from the sandbox so the shell function is never defined.
  rm -f "$SANDBOX/.claude/hooks/lib/json-deny-emitter.sh"

  # Place a fake deny_emit executable on PATH that silently exits 0 (fail-open
  # worst case: policy-blocking input would appear to be "allowed").
  local fake_dir
  fake_dir=$(mktemp -d "/tmp/fake-deny-emit-XXXXXX")
  cat > "$fake_dir/deny_emit" <<'EOF'
#!/usr/bin/env bash
# Fake deny_emit: exits 0 without emitting JSON (simulates fail-open bypass).
exit 0
EOF
  chmod +x "$fake_dir/deny_emit"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$fake_dir:$PATH"
  _FAKE_DIRS+=("$fake_dir")

  # Use "cat .env" — would trigger P8 if a real deny_emit function were present.
  # With the emitter absent and only a PATH executable, the [I6] guard must fire.
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"

  # Restore PATH before any assertion (cleanup_fakes resets PATH + removes tmpdir).
  cleanup_fakes

  # Must exit 2 — NOT 0 (fail-open via fake binary) or 127 (undefined function).
  [ "$HOOK_EXIT" = "2" ] \
    || fail "fake deny_emit on PATH bypass: expected exit 2, got exit $HOOK_EXIT (declare -F guard missing?)"

  # Must NOT emit JSON deny on stdout (exit 0 + JSON would be fail-open).
  if [ -n "$HOOK_STDOUT" ]; then
    local decision
    decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
    print(data.get("hookSpecificOutput",{}).get("permissionDecision","none"))
except Exception:
    print("not-json")
' 2>/dev/null)
    [ "$decision" = "not-json" ] \
      || fail "fake deny_emit on PATH bypass: got JSON deny on stdout despite exit 2 (decision=$decision)"
  fi

  # Stderr must contain the [I6] diagnostic message.
  [ -n "$HOOK_STDERR" ] \
    || fail "fake deny_emit on PATH bypass: stderr was empty — [I6] guard should emit diagnostic"
}

# ============================================================
# Suite 7: Task 3.1 — tone assertion for JSON deny trusted_reason (S7)
# ============================================================
#
# P8 (ENV_READ_BLOCKED) is the representative. Its permissionDecisionReason
# must be a natural English sentence (contains "blocked"/"because"/"instead"
# as natural-sentence tokens) and must NOT start with an uppercase imperative
# "BLOCKED:" prefix.

test_json_deny_tone_p8_natural_sentence() {
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "P8 tone: must emit JSON deny"

  # Extract the permissionDecisionReason for tone checks.
  local pdr
  pdr=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecisionReason"])
' 2>/dev/null)

  # Must contain natural-sentence tokens (what → why → how-to-fix flow).
  printf '%s' "$pdr" | grep -qiE 'blocked|because|instead' \
    || fail "P8 tone: permissionDecisionReason missing natural-sentence tokens (blocked/because/instead): '$pdr'"

  # Must NOT start with uppercase imperative "BLOCKED:" prefix.
  printf '%s' "$pdr" | grep -qE '^BLOCKED:' \
    && fail "P8 tone: permissionDecisionReason starts with 'BLOCKED:' imperative prefix — not assistant tone: '$pdr'"

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
  # Suite 4 — JSON deny: P1, P7, P8, P11 representative (Task 2.2)
  run_test test_json_deny_p1_pipe_bash          pre-bash-guard.sh
  run_test test_json_deny_p7_commit_msg_format  pre-bash-guard.sh
  run_test test_json_deny_p8_env_read           pre-bash-guard.sh
  run_test test_json_deny_p11_destructive_git   pre-bash-guard.sh
  # Suite 5 — JSON deny regression: P2, P3, P4, P5, P6 (Task 2.5)
  run_test test_json_deny_p2_coverage_mismatch_failing_target  pre-bash-guard.sh
  run_test test_json_deny_p3_review_pending_no_stamp           pre-bash-guard.sh
  run_test test_json_deny_p4_code_edited_after_review          pre-bash-guard.sh
  run_test test_json_deny_p5_codex_stamp_missing               pre-bash-guard.sh
  run_test test_json_deny_p6_security_stamp_missing            pre-bash-guard.sh
  # Suite 6 — P9, P10 direct JSON deny + emitter-unavailable fail-closed (Fix 1 regression)
  run_test test_json_deny_p9_env_stage_blocked                             pre-bash-guard.sh
  run_test test_json_deny_p10_env_commit_am_blocked                        pre-bash-guard.sh
  run_test test_emitter_unavailable_fails_closed                           pre-bash-guard.sh
  run_test test_emitter_unavailable_fake_deny_emit_on_path_fails_closed    pre-bash-guard.sh
  # Suite 7 — Task 3.1 tone assertions (S7)
  run_test test_json_deny_tone_p8_natural_sentence                          pre-bash-guard.sh
  summary
}

main "$@"
