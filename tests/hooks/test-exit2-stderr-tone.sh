#!/bin/bash
# tests/hooks/test-exit2-stderr-tone.sh
#
# Task 3.4 tone assertions for residual exit2 stderr messages (S7).
#
# Verifies that hook exit2 stderr messages are in assistant tone:
#   - Start with "[rein]" informational prefix (not uppercase imperative "BLOCKED:")
#   - Contain natural-sentence language
#
# Hooks covered:
#   pre-bash guards (safety-guard + test-commit-gate)  — I1 (Python resolver failure), I2 (JSON parse failure),
#                        I3 (coverage marker target unidentifiable),
#                        I4 (commit msg helper missing), I5 (commit msg helper failed)
#   pre-edit-dod-gate.sh — DoD missing (no active task record)
#   stop-session-gate.sh — MISSING check (exit2 block path)
#
# Exit code protocol: exit2 stderr messages are fixed English (Claude does not
# process them), so they must be friendly but language-fixed.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# ============================================================
# Shared helpers
# ============================================================

# assert_tone_ok STDERR_CONTENT TEST_LABEL
#   - Must NOT start with "BLOCKED:" prefix (case-sensitive)
#   - Must contain "[rein]" prefix token
assert_tone_ok() {
  local stderr_content="$1"
  local label="$2"

  # Must NOT have uppercase "BLOCKED:" imperative prefix anywhere at line start
  printf '%s' "$stderr_content" | grep -qE '^BLOCKED:' \
    && fail "$label: stderr starts with 'BLOCKED:' imperative prefix — not assistant tone"

  # Must contain "[rein]" token (consistent with emitter fail-closed tone)
  printf '%s' "$stderr_content" | grep -qF '[rein]' \
    || fail "$label: stderr missing '[rein]' prefix token"

  return 0
}

# ============================================================
# Suite A: pre-bash-safety-guard.sh I1 — Windows Python stub (exit 2)
# ============================================================
# [I1] path: resolver exits 11 (WindowsApps stub detected).
# The test harness provides with_fake_python / with_fake_uname to simulate
# the Windows stub path used by Suite 1 in test-pre-bash-safety-guard.sh.

_invoke_guard_windows_stub() {
  local stdin_json="$1"
  (
    with_empty_path
    with_fake_uname 'MINGW64_NT-10.0-22000'
    with_fake_python 49
    printf '%s' "$stdin_json" \
      | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/pre-bash-safety-guard.sh" 2>&1
    local rc=$?
    printf '_RC=%s\n' "$rc"
    cleanup_fakes
  )
}

test_exit2_stderr_tone_pre_bash_safety_guard_i1_windows_stub() {
  local stdin_json='{"tool_input":{"command":"ls -la"}}'

  local out
  out=$(_invoke_guard_windows_stub "$stdin_json")
  local rc
  rc=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)

  [ "$rc" = "2" ] \
    || fail "I1 Windows stub: expected exit 2, got $rc"

  # stderr is merged into 'out' by 2>&1 in _invoke_guard_windows_stub
  assert_tone_ok "$out" "pre-bash-safety-guard I1 Windows stub"
}

# ============================================================
# Suite B: pre-bash-test-commit-gate.sh I3 — coverage marker target unidentifiable
# ============================================================
# [I3] path: .coverage-mismatch exists but is empty → revalidate_coverage_marker
# returns 2 (target unidentifiable) → exit 2 stderr.

test_exit2_stderr_tone_pre_bash_test_commit_gate_i3_coverage_marker() {
  # Seed stamps and DoD so only I3 fires (other gates pass).
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-05-18-i3-test.md"
  seed_inbox "2026-05-18-i3-test.md"
  # Content-rich stamps (docs/specs/2026-06-16-review-stamp-freshness.md): an
  # empty `touch` stamp now fail-closes at the M2/M3 review-stamp check, so we
  # write PASS stamps with a shared cycle to reach the infra (I3/I4/I5) path.
  cat > "$SANDBOX/trail/dod/.codex-reviewed" <<'STAMP'
reviewed_at: 2026-06-16T01:00:00Z
reviewer: codex
diff_base: N/A
verdict: PASS
cycle: tone-test
scope: wrapper-generated
STAMP
  cat > "$SANDBOX/trail/dod/.security-reviewed" <<'STAMP'
reviewer=security-reviewer
reviewed=2026-06-16T02:00:00Z
security_level=standard
cycle=tone-test
verdict=PASS
mechanism=llm-security-review
STAMP
  # Empty marker → rc=2 path
  touch "$SANDBOX/trail/dod/.coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: i3 tone test\""},"tool_result":{}}'
  run_hook "pre-bash-test-commit-gate.sh" "$input"

  assert_exit 2 "I3: empty coverage marker should exit 2"
  assert_tone_ok "$HOOK_STDERR" "pre-bash-test-commit-gate I3 coverage marker"
}

# ============================================================
# Suite C: pre-bash-test-commit-gate.sh I4 — commit msg helper missing
# ============================================================
# [I4] path: EXTRACT_SCRIPT missing → exit 2 stderr.

test_exit2_stderr_tone_pre_bash_test_commit_gate_i4_helper_missing() {
  # Seed stamps and DoD so commit passes P3-P6 gates and reaches I4.
  # sandbox_setup copies lib/ (including extract-commit-msg.py) automatically,
  # so we remove it after setup to simulate the missing-helper path [I4].
  seed_dod "dod-2026-05-18-i4-test.md"
  seed_inbox "2026-05-18-i4-test.md"
  # Content-rich stamps (docs/specs/2026-06-16-review-stamp-freshness.md): an
  # empty `touch` stamp now fail-closes at the M2/M3 review-stamp check, so we
  # write PASS stamps with a shared cycle to reach the infra (I3/I4/I5) path.
  cat > "$SANDBOX/trail/dod/.codex-reviewed" <<'STAMP'
reviewed_at: 2026-06-16T01:00:00Z
reviewer: codex
diff_base: N/A
verdict: PASS
cycle: tone-test
scope: wrapper-generated
STAMP
  cat > "$SANDBOX/trail/dod/.security-reviewed" <<'STAMP'
reviewer=security-reviewer
reviewed=2026-06-16T02:00:00Z
security_level=standard
cycle=tone-test
verdict=PASS
mechanism=llm-security-review
STAMP
  # Remove the helper so I4 fires (sandbox_setup already copied it from lib/).
  rm -f "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"

  local input='{"tool_input":{"command":"git commit -m \"feat: i4 tone test\""},"tool_result":{}}'
  run_hook "pre-bash-test-commit-gate.sh" "$input"

  assert_exit 2 "I4: missing commit msg helper should exit 2"
  assert_tone_ok "$HOOK_STDERR" "pre-bash-test-commit-gate I4 helper missing"
}

# ============================================================
# Suite D: pre-edit-dod-gate.sh — DoD missing (no active task record)
# ============================================================
# When no dod-*.md file exists, the gate exits 2 with a "[rein]" message.
# The sandbox has no DoD files and a source file path as the edit target.

test_exit2_stderr_tone_pre_edit_dod_gate_dod_missing() {
  # No DoD file seeded → DOD_FOUND=false → exit 2.
  # Target a scripts/ path so IS_SOURCE=true fires.
  local input='{"tool_input":{"file_path":"scripts/example.sh"}}'
  run_hook "pre-edit-dod-gate.sh" "$input"

  assert_exit 2 "DoD gate: no DoD file should exit 2"
  assert_tone_ok "$HOOK_STDERR" "pre-edit-dod-gate DoD missing"
}

# ============================================================
# Suite E: stop-session-gate.sh — MISSING check exit2 stderr
# ============================================================
# When inbox is absent and no git activity, MISSING is non-empty → exit 2.
# We set .session-has-src-edit so the gate body is reached, seed
# .rein/project.json for BG-1, but provide no inbox file and no git repo.

test_exit2_stderr_tone_stop_session_gate_missing_inbox() {
  # BG-1 bootstrap contract
  mkdir -p "$SANDBOX/.rein"
  printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' \
    > "$SANDBOX/.rein/project.json"

  # Mark that source edits happened so the gate body is reached
  touch "$SANDBOX/trail/dod/.session-has-src-edit"

  # index.md present but stale (yesterday) so it contributes to MISSING
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
EOF
  # Set mtime to yesterday
  touch -t "$(date -v-1d +%Y%m%d)0000" "$SANDBOX/trail/index.md" 2>/dev/null \
    || touch -d "yesterday" "$SANDBOX/trail/index.md" 2>/dev/null || true

  # No inbox file for today → INBOX_TODAY=false
  # No git repo in SANDBOX → HAS_GIT_ACTIVITY=false → MISSING non-empty → exit 2

  run_hook "stop-session-gate.sh"

  assert_exit 2 "stop-gate: missing inbox should exit 2"
  assert_tone_ok "$HOOK_STDERR" "stop-session-gate MISSING check"
}

# ============================================================
# Suite F: pre-bash-safety-guard.sh I2 — hook input JSON parse failure
# ============================================================
# [I2] path: extract-hook-json.py exits non-zero because stdin is not valid
# JSON. This fires AFTER resolve_python() succeeds and BEFORE the empty-command
# guard. The malformed payload must reach extract-hook-json.py — we use
# a raw non-JSON byte string that Python's json.loads will reject (exit 20).
# Sandbox keeps lib/ intact (Python + extract-hook-json.py present), so only
# the JSON parse step fails.

test_exit2_stderr_tone_pre_bash_safety_guard_i2_json_parse_failure() {
  # No extra setup needed — sandbox_setup already copied lib/ including
  # extract-hook-json.py. Python is available. We just send malformed JSON.
  local malformed_input='NOT_VALID_JSON { broken:'

  run_hook "pre-bash-safety-guard.sh" "$malformed_input"

  assert_exit 2 "I2: malformed JSON input should exit 2"
  # The exact I2 message includes "extract-hook-json.py exited" (exit code 20
  # for invalid JSON as defined in extract-hook-json.py exit code table).
  printf '%s' "$HOOK_STDERR" | grep -qF "extract-hook-json.py exited" \
    || fail "I2: stderr missing 'extract-hook-json.py exited' (I2 marker)"
  assert_tone_ok "$HOOK_STDERR" "pre-bash-safety-guard I2 JSON parse failure"
}

# ============================================================
# Suite G: pre-bash-test-commit-gate.sh I5 — commit msg helper execution failure
# ============================================================
# [I5] path: extract-commit-msg.py is PRESENT but exits non-zero. This fires
# when EXTRACT_RC != 0 after calling "${PYTHON_RUNNER[@]} $EXTRACT_SCRIPT $COMMAND".
# Strategy: mirror the I4 "helper missing" pattern, but instead of removing the
# helper we replace it with a stub that exits 1. All other gates must pass so
# the code reaches the helper invocation: DoD + stamps seeded, no coverage
# markers, valid conventional commit format (format check never fires because
# the helper fails first).

test_exit2_stderr_tone_pre_bash_test_commit_gate_i5_helper_exec_failure() {
  # Seed stamps and DoD so commit passes P3-P6 gates and reaches I5.
  seed_dod "dod-2026-05-18-i5-test.md"
  seed_inbox "2026-05-18-i5-test.md"
  # Content-rich stamps (docs/specs/2026-06-16-review-stamp-freshness.md): an
  # empty `touch` stamp now fail-closes at the M2/M3 review-stamp check, so we
  # write PASS stamps with a shared cycle to reach the infra (I3/I4/I5) path.
  cat > "$SANDBOX/trail/dod/.codex-reviewed" <<'STAMP'
reviewed_at: 2026-06-16T01:00:00Z
reviewer: codex
diff_base: N/A
verdict: PASS
cycle: tone-test
scope: wrapper-generated
STAMP
  cat > "$SANDBOX/trail/dod/.security-reviewed" <<'STAMP'
reviewer=security-reviewer
reviewed=2026-06-16T02:00:00Z
security_level=standard
cycle=tone-test
verdict=PASS
mechanism=llm-security-review
STAMP
  # Replace the helper with a stub that exits 1 to trigger [I5].
  # sandbox_setup already copied the real extract-commit-msg.py from lib/;
  # we overwrite it with a failing stub.
  cat > "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py" <<'PYSTUB'
#!/usr/bin/env python3
import sys
sys.exit(1)
PYSTUB

  local input='{"tool_input":{"command":"git commit -m \"feat: i5 tone test\""},"tool_result":{}}'
  run_hook "pre-bash-test-commit-gate.sh" "$input"

  assert_exit 2 "I5: failing commit msg helper should exit 2"
  # The exact I5 message includes "helper script failed" (the assistant-tone
  # rewrite at pre-bash-test-commit-gate.sh ~line 431).
  printf '%s' "$HOOK_STDERR" | grep -qF "helper script failed" \
    || fail "I5: stderr missing 'helper script failed' (I5 marker)"
  assert_tone_ok "$HOOK_STDERR" "pre-bash-test-commit-gate I5 helper exec failure"
}

main() {
  # Suite A — pre-bash-safety-guard I1 Windows stub
  run_test test_exit2_stderr_tone_pre_bash_safety_guard_i1_windows_stub  pre-bash-safety-guard.sh
  # Suite B — pre-bash-test-commit-gate I3 coverage marker target unidentifiable
  run_test test_exit2_stderr_tone_pre_bash_test_commit_gate_i3_coverage_marker  pre-bash-test-commit-gate.sh
  # Suite C — pre-bash-test-commit-gate I4 commit msg helper missing
  run_test test_exit2_stderr_tone_pre_bash_test_commit_gate_i4_helper_missing   pre-bash-test-commit-gate.sh
  # Suite D — pre-edit-dod-gate DoD missing
  run_test test_exit2_stderr_tone_pre_edit_dod_gate_dod_missing      pre-edit-dod-gate.sh
  # Suite E — stop-session-gate MISSING exit2
  run_test test_exit2_stderr_tone_stop_session_gate_missing_inbox     stop-session-gate.sh
  # Suite F — pre-bash-safety-guard I2 JSON parse failure
  run_test test_exit2_stderr_tone_pre_bash_safety_guard_i2_json_parse_failure  pre-bash-safety-guard.sh
  # Suite G — pre-bash-test-commit-gate I5 commit msg helper exec failure
  run_test test_exit2_stderr_tone_pre_bash_test_commit_gate_i5_helper_exec_failure pre-bash-test-commit-gate.sh
  summary
}

main "$@"
