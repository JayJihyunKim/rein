#!/bin/bash
# tests/hooks/test-pre-bash-safety-guard.sh
#
# HK-2 (docs/specs/2026-05-19-cc-feature-adoption.md §HK-2): the former single Bash guard
# was split into pre-bash-safety-guard.sh (always-on) + pre-bash-test-commit-
# gate.sh (if-gated). This suite verifies the SAFETY half enforces exactly its
# allocated block points and NOTHING from the test/commit half.
#
# Spec block-point allocation for pre-bash-safety-guard.sh:
#   [P1]  pipe-to-shell
#   [P8]  .env read
#   [P9]  .env stage
#   [P10] .env commit -am
#   [P11] destructive git
#   [I1]  python3 resolver failure   (common — lib/bash-guard-infra.sh)
#   [I2]  hook JSON parse failure    (common — lib/bash-guard-infra.sh)
#   [I6]  JSON deny emitter corrupt  (common — lib/bash-guard-infra.sh)
# It must NOT enforce P2-P7 / I3-I5 — those belong to the test/commit gate.
#
# Sandbox: test-harness.sh copies pre-bash-safety-guard.sh + the whole lib/
# (incl. bash-guard-infra.sh + json-deny-emitter.sh) into a temp sandbox.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-safety-guard.sh"

# assert_json_deny REASON_CODE MESSAGE — assert HOOK emitted a JSON deny whose
# permissionDecisionReason carries REASON_CODE (mirrors the sibling test-commit-gate suite).
assert_json_deny() {
  local reason_code="$1"
  local msg="$2"
  assert_exit 0 "$msg: JSON deny path exits 0"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecision"])
' 2>/dev/null)
  [ "$decision" = "deny" ] \
    || fail "$msg: permissionDecision not \"deny\" (got: '$decision', stdout: $HOOK_STDOUT)"
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

assert_pass() {
  # HOOK passed: exit 0 + empty stdout (no JSON deny).
  assert_exit 0 "$1: should pass"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no JSON deny, got stdout: $HOOK_STDOUT"
}

# ============================================================
# [P1] pipe-to-shell
# ============================================================
test_p1_pipe_to_shell_blocks() {
  local input='{"tool_input":{"command":"printf hello | bash scripts/wrapper.sh"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "PIPE_SHELL_BLOCKED" "P1 pipe-bash should emit JSON deny"
}

# ============================================================
# [P8] .env read
# ============================================================
test_p8_env_read_blocks() {
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "P8 cat .env should emit JSON deny"
}

test_p8_env_example_not_blocked() {
  # Safe template file → must pass.
  local input='{"tool_input":{"command":"cat .env.example"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P8 cat .env.example"
}

# ============================================================
# [P9] .env stage
# ============================================================
test_p9_env_stage_blocks() {
  # .env present in repo root + git add -A → P9.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git add -A"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_STAGE_BLOCKED" "P9 git add -A with .env present should emit JSON deny"
}

# ============================================================
# [P10] .env commit -am
# ============================================================
test_p10_env_commit_am_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -am \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -am with .env present should emit JSON deny"
}

# ============================================================
# [P11] destructive git
# ============================================================
test_p11_destructive_git_blocks() {
  local input='{"tool_input":{"command":"git reset --hard HEAD~1"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "DESTRUCTIVE_GIT_CONFIRM" "P11 git reset --hard should emit JSON deny"
}

# ============================================================
# Negative: a plain command passes (no block point fires).
# ============================================================
test_plain_ls_passes() {
  local input='{"tool_input":{"command":"ls -la"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "plain ls -la"
}

# ============================================================
# Allocation boundary: the safety guard must NOT enforce P5/P7
# (codex stamp / commit-msg format) — those belong to the
# test/commit gate. A bad-format `git commit` with a DoD present
# and NO stamps must PASS through the safety guard untouched.
# ============================================================
test_safety_guard_does_not_enforce_commit_gate() {
  # Seed a DoD + NO review stamps + a bad-format commit message.
  seed_dod "dod-2026-05-19-allocation-boundary.md"
  local input='{"tool_input":{"command":"git commit -m \"bad message without type\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  # No .env in root, so P10 does not fire. The safety guard has no P5/P7,
  # so this must pass — proving the test/commit checks were NOT duplicated.
  assert_pass "git commit with bad msg + no stamps is NOT blocked by safety-guard"
}

# ============================================================
# [I1] python3 resolver failure (common infra — fail-closed exit 2).
# Simulated via the Windows python stub (exit 49) — same path the
# old combined-guard Suite 1 exercised.
# ============================================================
test_i1_python_resolver_failure_fails_closed() {
  local stdin_json='{"tool_input":{"command":"ls -la"}}'
  local out rc
  out=$(
    with_empty_path
    with_fake_uname 'MINGW64_NT-10.0-22000'
    with_fake_python 49
    printf '%s' "$stdin_json" \
      | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$HOOK" 2>&1
    printf '_RC=%s\n' "$?"
    cleanup_fakes
  )
  rc=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)
  [ "$rc" = "2" ] \
    || fail "I1 expected exit 2, got rc='$rc' (out: $(printf '%s' "$out" | head -3 | tr '\n' ' '))"
  printf '%s' "$out" | grep -qF "[rein]" \
    || fail "I1 stderr missing '[rein]' prefix"
}

# ============================================================
# [I2] hook input JSON parse failure (common infra — exit 2).
# ============================================================
test_i2_json_parse_failure_fails_closed() {
  # Raw non-JSON byte string that extract-hook-json.py's json.loads rejects
  # (exit 20) — same payload test-exit2-stderr-tone.sh Suite F uses.
  local malformed='NOT_VALID_JSON { broken:'
  run_hook "$HOOK" "$malformed"
  assert_exit 2 "I2 malformed hook JSON should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# [I6] JSON deny emitter corrupt (common infra — exit 2).
# Remove the emitter from the sandbox so bg_infra_init fails.
# ============================================================
test_i6_emitter_unavailable_fails_closed() {
  rm -f "$SANDBOX/.claude/hooks/lib/json-deny-emitter.sh"
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I6 missing emitter should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

main() {
  # Policy block points
  run_test test_p1_pipe_to_shell_blocks                   "$HOOK"
  run_test test_p8_env_read_blocks                        "$HOOK"
  run_test test_p8_env_example_not_blocked                "$HOOK"
  run_test test_p9_env_stage_blocks                       "$HOOK"
  run_test test_p10_env_commit_am_blocks                  "$HOOK"
  run_test test_p11_destructive_git_blocks                "$HOOK"
  run_test test_plain_ls_passes                           "$HOOK"
  # Allocation boundary — safety guard must NOT enforce the test/commit gate
  run_test test_safety_guard_does_not_enforce_commit_gate "$HOOK"
  # Common infra (I1·I2·I6)
  run_test test_i1_python_resolver_failure_fails_closed   "$HOOK"
  run_test test_i2_json_parse_failure_fails_closed        "$HOOK"
  run_test test_i6_emitter_unavailable_fails_closed       "$HOOK"
  summary
}

main
