#!/bin/bash
# tests/hooks/test-pre-bash-test-commit-gate.sh
#
# HK-2 (docs/specs/2026-05-19-cc-feature-adoption.md §HK-2): the former single Bash guard
# was split into pre-bash-safety-guard.sh (always-on) + pre-bash-test-commit-
# gate.sh (if-gated). This suite verifies the TEST/COMMIT half enforces exactly
# its allocated block points.
#
# Spec block-point allocation for pre-bash-test-commit-gate.sh:
#   [P2]  coverage matrix mismatch
#   [P3]  review pending, no stamp
#   [P4]  code edited after review
#   [P5]  codex review stamp missing
#   [P6]  security review stamp missing
#   [P7]  commit message format
#   [I3]  coverage marker target unidentifiable (pairs with P2)
#   [I4]  commit-msg helper absent              (pairs with P7)
#   [I5]  commit-msg helper exec failure         (pairs with P7)
#   [I1]  python3 resolver failure   (common — lib/bash-guard-infra.sh)
#   [I2]  hook JSON parse failure    (common — lib/bash-guard-infra.sh)
#   [I6]  JSON deny emitter corrupt  (common — lib/bash-guard-infra.sh)
# GUARD-1: test *execution* (pytest etc.) is NOT stamp-gated — only commit is.
#
# Sandbox: test-harness.sh copies pre-bash-test-commit-gate.sh + the whole lib/
# (incl. bash-guard-infra.sh + extract-commit-msg.py + json-deny-emitter.sh).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-test-commit-gate.sh"

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
  assert_exit 0 "$1: should pass"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no JSON deny, got stdout: $HOOK_STDOUT"
}

# Seed a DoD so the stamp gate is active, plus both review stamps so the
# *only* failing gate in a test is the one under test.
_seed_dod_only() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
}
_seed_dod_and_stamps() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
}

# ============================================================
# [P5] codex review stamp missing — git commit, DoD present, no stamps.
# ============================================================
test_p5_codex_stamp_missing_blocks() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "P5 git commit without codex stamp should emit JSON deny"
}

# ============================================================
# [P6] security review stamp missing — codex stamp present, security missing.
# ============================================================
test_p6_security_stamp_missing_blocks() {
  _seed_dod_only
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "P6 git commit without security stamp should emit JSON deny"
}

# ============================================================
# [P3] review pending, no stamp — .review-pending present, no codex stamp.
# ============================================================
test_p3_review_pending_no_stamp_blocks() {
  _seed_dod_only
  touch "$SANDBOX/trail/dod/.review-pending"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "REVIEW_PENDING_NO_STAMP" "P3 .review-pending without stamp should emit JSON deny"
}

# ============================================================
# [P4] code edited after review — .codex-reviewed older than .review-pending.
# ============================================================
test_p4_code_edited_after_review_blocks() {
  _seed_dod_only
  # codex stamp older than review-pending → stale review.
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch -t "203001010000" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null \
    || touch -d "2030-01-01" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null
  # NOTE: we make the stamp OLD (1970-ish) and pending NEW instead.
  touch -t "197001020000" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null \
    || touch -d "1970-01-02" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null
  touch "$SANDBOX/trail/dod/.review-pending"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODE_EDITED_AFTER_REVIEW" "P4 code edited after review should emit JSON deny"
}

# ============================================================
# [P7] commit message format — stamps present, bad-format message.
# ============================================================
test_p7_commit_msg_format_blocks() {
  _seed_dod_and_stamps
  local input='{"tool_input":{"command":"git commit -m \"bad message without type\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "COMMIT_MSG_FORMAT" "P7 bad commit message format should emit JSON deny"
}

# Negative: a well-formed commit with stamps + no markers passes.
test_good_commit_passes() {
  _seed_dod_and_stamps
  local input='{"tool_input":{"command":"git commit -m \"feat: well formed\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "well-formed git commit with stamps should pass"
}

# ============================================================
# [P2] coverage matrix mismatch — non-empty marker, identifiable FAIL target.
# Uses a stub validator that always FAILs so revalidate rc=1 (P2 path).
# ============================================================
test_p2_coverage_mismatch_blocks() {
  _seed_dod_and_stamps
  # Stub validator: always exit 1 (FAIL). resolve_helper_script (plugin-script-
  # path.sh) resolves rein-validate-coverage-matrix.py from scripts/.
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
import sys
sys.exit(1)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  # Non-empty .coverage-mismatch with an existing plan file path.
  mkdir -p "$SANDBOX/docs/plans"
  echo "# plan" > "$SANDBOX/docs/plans/p.md"
  echo "$SANDBOX/docs/plans/p.md" > "$SANDBOX/trail/dod/.coverage-mismatch"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "COVERAGE_MISMATCH" "P2 coverage validator FAIL should emit JSON deny"
}

# ============================================================
# [I3] coverage marker target unidentifiable — empty marker → exit 2.
# ============================================================
test_i3_coverage_marker_unidentifiable_fails_closed() {
  _seed_dod_and_stamps
  touch "$SANDBOX/trail/dod/.coverage-mismatch"   # empty → rc=2 → I3
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I3 empty coverage marker should fail closed (exit 2)"
  assert_stderr_contains ".coverage-mismatch"
}

# ============================================================
# [I4] commit-msg helper absent — remove extract-commit-msg.py → exit 2.
# ============================================================
test_i4_commit_msg_helper_absent_fails_closed() {
  _seed_dod_and_stamps
  rm -f "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I4 missing commit-msg helper should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# [I5] commit-msg helper exec failure — replace helper with one that errors.
# ============================================================
test_i5_commit_msg_helper_exec_failure_fails_closed() {
  _seed_dod_and_stamps
  cat > "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py" <<'PY'
import sys
sys.exit(3)
PY
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I5 commit-msg helper exec failure should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# GUARD-1: test *execution* is NOT stamp-gated — pytest with a DoD and NO
# stamps must pass (only `git commit` is the hard gate).
# ============================================================
test_guard1_pytest_not_blocked_without_stamps() {
  _seed_dod_only
  local input='{"tool_input":{"command":"pytest tests/"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "GUARD-1 pytest without stamps should NOT be blocked"
}

# ============================================================
# [I1] python3 resolver failure (common infra — fail-closed exit 2).
# ============================================================
test_i1_python_resolver_failure_fails_closed() {
  local stdin_json='{"tool_input":{"command":"git commit -m \"feat: x\""}}'
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
# ============================================================
test_i6_emitter_unavailable_fails_closed() {
  rm -f "$SANDBOX/.claude/hooks/lib/json-deny-emitter.sh"
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I6 missing emitter should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

main() {
  # Policy block points P2-P7
  run_test test_p5_codex_stamp_missing_blocks                   "$HOOK"
  run_test test_p6_security_stamp_missing_blocks                "$HOOK"
  run_test test_p3_review_pending_no_stamp_blocks               "$HOOK"
  run_test test_p4_code_edited_after_review_blocks              "$HOOK"
  run_test test_p7_commit_msg_format_blocks                     "$HOOK"
  run_test test_good_commit_passes                              "$HOOK"
  run_test test_p2_coverage_mismatch_blocks                     "$HOOK"
  # Paired infra points I3-I5
  run_test test_i3_coverage_marker_unidentifiable_fails_closed  "$HOOK"
  run_test test_i4_commit_msg_helper_absent_fails_closed        "$HOOK"
  run_test test_i5_commit_msg_helper_exec_failure_fails_closed  "$HOOK"
  # GUARD-1 — test execution is not stamp-gated
  run_test test_guard1_pytest_not_blocked_without_stamps        "$HOOK"
  # Common infra I1·I2·I6
  run_test test_i1_python_resolver_failure_fails_closed         "$HOOK"
  run_test test_i2_json_parse_failure_fails_closed              "$HOOK"
  run_test test_i6_emitter_unavailable_fails_closed             "$HOOK"
  summary
}

main
