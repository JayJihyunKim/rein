#!/bin/bash
# tests/hooks/test-plan-coverage-deferral.sh
#
# X3.B.1 + X3.B.2 — Area B plan-coverage deferral implementation.
#
# Design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md
#   - §5.1 (post-edit-plan-coverage.sh 축소): validator 호출 제거, dirty append 만
#   - §5.2 (pre-bash-test-commit-gate.sh flush): atomic mv → .processing → validator
#   - §7 Scope ID 1 (post-edit-plan-coverage-defers-validator-to-commit-gate...)
#   - §7 Scope ID 2 (commit-gate-flushes-plan-coverage-dirty-list-and-runs-...)
#
# Test categories:
#   T1~T5: post-edit-plan-coverage.sh dirty append behavior (B.1)
#   T6~T11: pre-bash-test-commit-gate.sh flush behavior (B.2)
#
# Sandbox harness reused from existing tests/hooks/ pattern (manual sandbox,
# not the lib/test-harness.sh helper — the commit-gate test pattern needs more
# control over CLAUDE_PLUGIN_ROOT and stub validator).

set -u

REAL_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
CURRENT_FAILS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then return 0; fi
  echo "  FAIL [$label]: expected='$expected' actual='$actual'" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

assert_file_exists() {
  local label="$1" path="$2"
  [ -f "$path" ] && return 0
  echo "  FAIL [$label]: file missing: $path" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

assert_file_missing() {
  local label="$1" path="$2"
  [ ! -e "$path" ] && return 0
  echo "  FAIL [$label]: file should not exist: $path" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

assert_line_count() {
  local label="$1" expected="$2" path="$3"
  local actual
  actual=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
  [ "$actual" = "$expected" ] && return 0
  echo "  FAIL [$label]: expected $expected lines in $path, got $actual" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

assert_file_contains() {
  local label="$1" path="$2" needle="$3"
  if [ ! -f "$path" ]; then
    echo "  FAIL [$label]: file missing: $path" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
    return
  fi
  grep -qF "$needle" "$path" && return 0
  echo "  FAIL [$label]: $path missing pattern: $needle" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

start_test() {
  CURRENT_TEST="$1"
  CURRENT_FAILS=0
  echo "TEST: $CURRENT_TEST"
}

end_test() {
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Sandbox setup for post-edit hook test ---
mk_sandbox_post_edit() {
  SANDBOX=$(mktemp -d "/tmp/plan-cov-deferral-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/docs/plans"

  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-edit-plan-coverage.sh" "$SANDBOX/.claude/hooks/"
  cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/." "$SANDBOX/.claude/hooks/lib/"
  chmod +x "$SANDBOX/.claude/hooks/post-edit-plan-coverage.sh"

  # Stub validator — only called as fallback (PIPE_BUF over) or by commit gate flush.
  # Returns PASS if file contains "VALIDATOR_PASS", else FAIL.
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
#!/usr/bin/env python3
import sys
# Accept legacy (single-arg) and new (subcommand) calling forms.
# legacy:    rein-validate-coverage-matrix.py <plan>
# new:       rein-validate-coverage-matrix.py plan <plan>
path = None
if len(sys.argv) == 2:
    path = sys.argv[1]
elif len(sys.argv) >= 3 and sys.argv[1] in ("plan", "dod"):
    path = sys.argv[2]
if not path:
    sys.exit(2)
try:
    with open(path) as f:
        if "VALIDATOR_PASS" in f.read():
            sys.exit(0)
    # Match real validator contract (rein-validate-coverage-matrix.py):
    # rc 0 = PASS, rc 2 = validation FAIL. Any other non-zero (e.g., 1, 127)
    # is a runtime/infra error from the caller's perspective.
    sys.exit(2)
except OSError:
    sys.exit(2)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
}

# --- Sandbox setup for commit-gate flush test ---
mk_sandbox_commit_gate() {
  SANDBOX=$(mktemp -d "/tmp/plan-cov-deferral-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/trail/incidents"
  mkdir -p "$SANDBOX/docs/plans"

  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/pre-bash-test-commit-gate.sh" "$SANDBOX/.claude/hooks/"
  cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/." "$SANDBOX/.claude/hooks/lib/"
  chmod +x "$SANDBOX/.claude/hooks/pre-bash-test-commit-gate.sh"

  # Stub validator (same as post-edit sandbox).
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
#!/usr/bin/env python3
import sys
path = None
if len(sys.argv) == 2:
    path = sys.argv[1]
elif len(sys.argv) >= 3 and sys.argv[1] in ("plan", "dod"):
    path = sys.argv[2]
if not path:
    sys.exit(2)
try:
    with open(path) as f:
        if "VALIDATOR_PASS" in f.read():
            sys.exit(0)
    # Match real validator contract (rein-validate-coverage-matrix.py):
    # rc 0 = PASS, rc 2 = validation FAIL. Any other non-zero (e.g., 1, 127)
    # is a runtime/infra error from the caller's perspective.
    sys.exit(2)
except OSError:
    sys.exit(2)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"

  # Seed a DoD so the commit gate's review-stamp branch can proceed past the
  # "no DoD" early-return (we are testing the flush path, not stamps).
  cat > "$SANDBOX/trail/dod/dod-test.md" <<'EOF'
# DoD: test
- placeholder
EOF
  # Pre-create the two stamps so the gate doesn't deny on P5/P6 — we are
  # exercising the new flush logic at the top of the gate, not the existing
  # stamp checks.
  : > "$SANDBOX/trail/dod/.codex-reviewed"
  : > "$SANDBOX/trail/dod/.security-reviewed"
}

rm_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# Run post-edit hook with a synthetic edit JSON.
# $1=file_path
run_post_edit() {
  local file_path="$1"
  local input
  input=$(printf '{"tool_input":{"file_path":"%s"},"tool_result":{}}' "$file_path")
  local out_file err_file
  out_file=$(mktemp)
  err_file=$(mktemp)
  printf '%s' "$input" \
    | (cd "$SANDBOX" && env -u CLAUDE_PLUGIN_ROOT REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash .claude/hooks/post-edit-plan-coverage.sh) \
    > "$out_file" 2> "$err_file"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

# Run commit gate with synthetic bash command.
run_commit_gate() {
  local cmd="$1"
  local input
  input=$(printf '{"tool_input":{"command":%s}}' \
    "$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")
  local out_file err_file
  out_file=$(mktemp)
  err_file=$(mktemp)
  printf '%s' "$input" \
    | (cd "$SANDBOX" && env -u CLAUDE_PLUGIN_ROOT REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash .claude/hooks/pre-bash-test-commit-gate.sh) \
    > "$out_file" 2> "$err_file"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

# Make a plan file with VALIDATOR_PASS sentinel (validator-pass).
mk_pass_plan() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  echo "VALIDATOR_PASS" > "$path"
}

# Make a plan file without the sentinel (validator-fail).
mk_fail_plan() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  echo "no marker here" > "$path"
}

# ======================================================================
# B.1 — post-edit-plan-coverage.sh dirty append behavior
# ======================================================================

# T1: plan edit appends abs path to .plan-coverage-dirty, no validator call,
#     no .coverage-mismatch.
test_post_edit_appends_one_line() {
  start_test "T1: plan edit → .plan-coverage-dirty 1 line, no .coverage-mismatch"
  mk_sandbox_post_edit
  mk_pass_plan "$SANDBOX/docs/plans/2026-05-20-foo-plan.md"

  run_post_edit "$SANDBOX/docs/plans/2026-05-20-foo-plan.md"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  assert_file_exists "dirty_list_created" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  assert_line_count "single_line" "1" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  assert_file_contains "abs_path_in_dirty" \
    "$SANDBOX/trail/dod/.plan-coverage-dirty" \
    "$SANDBOX/docs/plans/2026-05-20-foo-plan.md"
  assert_file_missing "no_coverage_mismatch" "$SANDBOX/trail/dod/.coverage-mismatch"
  end_test
  rm_sandbox
}

# T2: plan edit with content that would fail validator — still just appends,
#     does NOT call validator (deferral contract). marker not created either.
test_post_edit_fail_content_still_appends_no_marker() {
  start_test "T2: plan edit (would-fail content) → append only, NO validator call, no .coverage-mismatch"
  mk_sandbox_post_edit
  mk_fail_plan "$SANDBOX/docs/plans/2026-05-20-bad-plan.md"

  run_post_edit "$SANDBOX/docs/plans/2026-05-20-bad-plan.md"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  assert_file_exists "dirty_list_created" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  assert_file_missing "no_coverage_mismatch_yet" "$SANDBOX/trail/dod/.coverage-mismatch"
  end_test
  rm_sandbox
}

# T3: three distinct plan edits → 3 lines (dedup happens at flush, not append).
test_post_edit_three_distinct_plans() {
  start_test "T3: 3 distinct plan edits → 3 lines in .plan-coverage-dirty"
  mk_sandbox_post_edit
  mk_pass_plan "$SANDBOX/docs/plans/a.md"
  mk_pass_plan "$SANDBOX/docs/plans/b.md"
  mk_pass_plan "$SANDBOX/docs/plans/c.md"

  run_post_edit "$SANDBOX/docs/plans/a.md"
  run_post_edit "$SANDBOX/docs/plans/b.md"
  run_post_edit "$SANDBOX/docs/plans/c.md"
  assert_line_count "three_lines" "3" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  end_test
  rm_sandbox
}

# T4: non-plan edit (e.g., source code) → no dirty list creation.
test_post_edit_non_plan_skip() {
  start_test "T4: non-plan edit (e.g., .py) → no .plan-coverage-dirty"
  mk_sandbox_post_edit
  mkdir -p "$SANDBOX/src"
  echo "print('hi')" > "$SANDBOX/src/foo.py"

  run_post_edit "$SANDBOX/src/foo.py"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  assert_file_missing "no_dirty_list" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  end_test
  rm_sandbox
}

# T5: deleted plan path (file doesn't exist) → no append (existing
#     `[ -f "$ABS" ] || continue` guard preserved).
test_post_edit_deleted_plan_skip() {
  start_test "T5: deleted plan path → no append (existing guard preserved)"
  mk_sandbox_post_edit
  # NOTE: do NOT create the plan file.

  run_post_edit "$SANDBOX/docs/plans/never-existed.md"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  assert_file_missing "no_dirty_list" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  end_test
  rm_sandbox
}

# ======================================================================
# B.2 — pre-bash-test-commit-gate.sh flush behavior
# ======================================================================

# T6: .plan-coverage-dirty present with PASS plan → flush runs validator,
#     PASS → .processing removed, command allowed.
test_flush_pass_clears_processing() {
  start_test "T6: dirty list with PASS plan → flush PASS, .processing removed, commit allowed"
  mk_sandbox_commit_gate
  mk_pass_plan "$SANDBOX/docs/plans/good.md"
  echo "$SANDBOX/docs/plans/good.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  # On PASS, the gate must have cleaned up .processing and not created marker.
  assert_file_missing "processing_removed" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  assert_file_missing "no_coverage_marker" "$SANDBOX/trail/dod/.coverage-mismatch"
  end_test
  rm_sandbox
}

# T7: .plan-coverage-dirty present with FAIL plan → flush FAILS, .coverage-
#     mismatch created, JSON deny emitted (exit 0 + permissionDecision=deny).
test_flush_fail_creates_marker_and_denies() {
  start_test "T7: dirty list with FAIL plan → flush FAIL, .coverage-mismatch created, commit denied"
  mk_sandbox_commit_gate
  mk_fail_plan "$SANDBOX/docs/plans/bad.md"
  echo "$SANDBOX/docs/plans/bad.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  # Deny via JSON envelope (exit 0 + permissionDecision deny).
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
  data=json.load(sys.stdin)
  print(data["hookSpecificOutput"]["permissionDecision"])
except Exception:
  print("")
' 2>/dev/null)
  assert_eq "permissionDecision_deny" "deny" "$decision"
  # Marker must now exist.
  assert_file_exists "coverage_marker_created" "$SANDBOX/trail/dod/.coverage-mismatch"
  end_test
  rm_sandbox
}

# T8: .plan-coverage-dirty with all deleted plans → flush cannot validate
#     anything → conservative block. .processing retained.
test_flush_all_deleted_conservative_block() {
  start_test "T8: dirty list with all-deleted plans → conservative block, .processing retained"
  mk_sandbox_commit_gate
  # NOTE: do not create the plan file.
  echo "$SANDBOX/docs/plans/ghost.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  # Conservative block: validator was not actually run on any path → I3-style
  # exit 2 OR JSON deny (we accept either; the contract is "blocking").
  case "$HOOK_EXIT" in
    0)
      # JSON deny path acceptable.
      local decision
      decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
  data=json.load(sys.stdin)
  print(data["hookSpecificOutput"]["permissionDecision"])
except Exception:
  print("")
' 2>/dev/null)
      assert_eq "permissionDecision_deny" "deny" "$decision"
      ;;
    2)
      # exit 2 path also acceptable (fail-closed).
      ;;
    *)
      echo "  FAIL [exit_code]: expected 0 (json deny) or 2 (fail-closed), got $HOOK_EXIT" >&2
      CURRENT_FAILS=$((CURRENT_FAILS + 1))
      ;;
  esac
  # .processing must still exist for next-cycle retry.
  assert_file_exists "processing_retained" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  end_test
  rm_sandbox
}

# T9: .plan-coverage-dirty with mixed (valid PASS + deleted) → flush validates
#     PASS one, removes .processing (validated_count >= 1, no FAIL).
test_flush_mixed_pass_deleted() {
  start_test "T9: dirty list mixed (PASS + deleted) → flush PASSes, .processing removed"
  mk_sandbox_commit_gate
  mk_pass_plan "$SANDBOX/docs/plans/exists.md"
  # docs/plans/ghost.md doesn't exist.
  printf '%s\n%s\n' \
    "$SANDBOX/docs/plans/exists.md" \
    "$SANDBOX/docs/plans/ghost.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  assert_file_missing "processing_removed" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  assert_file_missing "no_coverage_marker" "$SANDBOX/trail/dod/.coverage-mismatch"
  end_test
  rm_sandbox
}

# T10: stale .plan-coverage-dirty.processing leftover from previous crashed
#      flush → next flush handles it (processes the stale processing first).
test_flush_stale_processing_handled() {
  start_test "T10: stale .processing leftover → next flush handles it"
  mk_sandbox_commit_gate
  mk_pass_plan "$SANDBOX/docs/plans/stale-good.md"
  # Simulate previous crashed flush: .processing exists with content, no .plan-coverage-dirty.
  echo "$SANDBOX/docs/plans/stale-good.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"

  run_commit_gate "git commit -m 'feat(x): test'"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  # Stale .processing must have been consumed (cleaned up since validator PASSed).
  assert_file_missing "stale_processing_consumed" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  end_test
  rm_sandbox
}

# T11: dirty list empty (no marker) + no other markers → flush is a no-op,
#      commit allowed (no regression on the common path).
test_flush_no_dirty_list_noop() {
  start_test "T11: no dirty list → no-op, commit allowed"
  mk_sandbox_commit_gate
  # No .plan-coverage-dirty, no .plan-coverage-dirty.processing.

  run_commit_gate "git commit -m 'feat(x): test'"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  end_test
  rm_sandbox
}

# ======================================================================
# B.1+B.2 — concurrent append vs flush race (codex Round 1 HIGH fix)
# ======================================================================

# T12: lock-based mutex prevents post-edit appends from being lost when a
#      concurrent flush happens. We approximate the race by holding the
#      lock externally (mkdir) and verifying the post-edit hook's
#      acquire/release behaves correctly. Direct race testing in bash is
#      flaky; this test pins down the lock CONTRACT rather than racing
#      threads — if the lock semantics are preserved, the race cannot
#      strip entries.
test_post_edit_lock_held_falls_back_to_immediate() {
  start_test "T12: lock held → post-edit falls back to immediate validator (no silent drop)"
  mk_sandbox_post_edit
  mk_pass_plan "$SANDBOX/docs/plans/locked.md"
  # Hold the lock externally (simulating a concurrent flush in critical section).
  mkdir -p "$SANDBOX/trail/dod/.plan-coverage-dirty.lock"

  run_post_edit "$SANDBOX/docs/plans/locked.md"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  # Contended lock → fallback path. Append did not happen.
  assert_file_missing "no_dirty_append_under_contention" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  # Fallback ran the validator inline. Since plan is PASS, no marker is created
  # (immediate validator only writes marker on FAIL).
  assert_file_missing "validator_pass_no_marker" "$SANDBOX/trail/dod/.coverage-mismatch"
  # Most importantly: stderr is vocal about the fallback — no silent skip.
  if ! echo "$HOOK_STDERR" | grep -qE "contended|fallback"; then
    echo "  FAIL [vocal_fallback]: stderr should mention lock contention or fallback" >&2
    echo "    actual stderr: $HOOK_STDERR" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  # Cleanup external lock so other tests aren't affected.
  rmdir "$SANDBOX/trail/dod/.plan-coverage-dirty.lock" 2>/dev/null || true
  end_test
  rm_sandbox
}

# T13: lock is released after a normal append (no stale lock leftover).
test_post_edit_lock_released_after_append() {
  start_test "T13: post-edit releases lock after append (no stale lock)"
  mk_sandbox_post_edit
  mk_pass_plan "$SANDBOX/docs/plans/a.md"
  mk_pass_plan "$SANDBOX/docs/plans/b.md"

  run_post_edit "$SANDBOX/docs/plans/a.md"
  # After first append, lock must be released.
  assert_file_missing "lock_released_1" "$SANDBOX/trail/dod/.plan-coverage-dirty.lock"
  # Second append (sequential) must therefore succeed without contention.
  run_post_edit "$SANDBOX/docs/plans/b.md"
  assert_file_missing "lock_released_2" "$SANDBOX/trail/dod/.plan-coverage-dirty.lock"
  assert_line_count "two_entries" "2" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  end_test
  rm_sandbox
}

# T15: codex Round 2 HIGH fix — stale .processing + fresh .plan-coverage-dirty
#      with invalid plan must block current commit (not defer the fresh entry).
test_flush_stale_processing_plus_fresh_invalid_blocks() {
  start_test "T15: stale .processing PASS + fresh dirty INVALID → both validated, fresh FAIL blocks commit"
  mk_sandbox_commit_gate
  # Stale .processing pointing to a PASS plan (e.g., previous flush crashed
  # before cleanup but its content was already validated and is now valid).
  mk_pass_plan "$SANDBOX/docs/plans/stale-good.md"
  echo "$SANDBOX/docs/plans/stale-good.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  # Fresh dirty list with an INVALID plan from a recent post-edit burst.
  mk_fail_plan "$SANDBOX/docs/plans/fresh-bad.md"
  echo "$SANDBOX/docs/plans/fresh-bad.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  # Both should be validated in one flush call → fresh-bad FAIL surfaces
  # → P2 deny path fires.
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
  data=json.load(sys.stdin)
  print(data["hookSpecificOutput"]["permissionDecision"])
except Exception:
  print("")
' 2>/dev/null)
  assert_eq "permissionDecision_deny" "deny" "$decision"
  assert_file_exists "marker_created_for_fresh_invalid" "$SANDBOX/trail/dod/.coverage-mismatch"
  assert_file_contains "marker_has_fresh_bad" "$SANDBOX/trail/dod/.coverage-mismatch" "fresh-bad.md"
  # processing must be consumed (both stale and fresh were merged + processed).
  assert_file_missing "processing_consumed" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  # fresh dirty file must also be gone (merged into processing before validate).
  assert_file_missing "fresh_dirty_consumed" "$SANDBOX/trail/dod/.plan-coverage-dirty"
  end_test
  rm_sandbox
}

# T16: codex Round 2 — fallback validation-fail also emits vocal NOTICE
#      (not just missing-validator).
test_post_edit_lock_held_fail_plan_falls_back_vocal() {
  start_test "T16: lock held + FAIL plan → fallback emits vocal NOTICE on validation failure"
  mk_sandbox_post_edit
  mk_fail_plan "$SANDBOX/docs/plans/falls-back.md"
  # Hold the lock externally to force the fallback path.
  mkdir -p "$SANDBOX/trail/dod/.plan-coverage-dirty.lock"

  run_post_edit "$SANDBOX/docs/plans/falls-back.md"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  # Fallback path → immediate validator → FAIL → marker created.
  assert_file_exists "marker_from_fallback_fail" "$SANDBOX/trail/dod/.coverage-mismatch"
  # Vocal stderr: must mention validation failure + marker update (not silent).
  if ! echo "$HOOK_STDERR" | grep -qE "validation failed|fallback path|marker updated"; then
    echo "  FAIL [vocal_fallback_fail]: stderr should mention validation failure / fallback / marker update" >&2
    echo "    actual stderr: $HOOK_STDERR" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  rmdir "$SANDBOX/trail/dod/.plan-coverage-dirty.lock" 2>/dev/null || true
  end_test
  rm_sandbox
}

# T14: PIPE_BUF + missing validator → vocal NOTICE (codex Round 1 Medium fix).
#      The old silent-skip behavior is replaced by stderr NOTICE so the
#      user knows the path was not tracked.
test_pipe_buf_overflow_validator_missing_vocal() {
  start_test "T14: PIPE_BUF overflow + validator missing → vocal NOTICE (no silent skip)"
  mk_sandbox_post_edit
  # Remove the stub validator so the missing-validator branch fires.
  rm -f "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  # Construct a plan path longer than PIPE_BUF_LIMIT (512 bytes) by nesting
  # many directories (each component ≤ 255 bytes, filesystem-compatible).
  # 10 dirs × ~60-char component = ~600+ byte total path.
  local segment="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  local long_dir="$SANDBOX/docs/plans"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    long_dir="$long_dir/$segment"
  done
  mkdir -p "$long_dir"
  local long_plan="$long_dir/p.md"
  mk_pass_plan "$long_plan"

  run_post_edit "$long_plan"
  assert_eq "exit_code_zero" "0" "$HOOK_EXIT"
  # No silent skip — stderr must mention the issue.
  if ! echo "$HOOK_STDERR" | grep -qE "validator unavailable|cannot track"; then
    echo "  FAIL [vocal_missing_validator]: stderr should mention unavailable validator" >&2
    echo "    actual stderr: $HOOK_STDERR" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# T17: X3.B.5 — validator runtime error (rc != 0,2) → flush fail-closed.
#      Stub returns rc 1 simulating Python crash / uncaught exception.
#      Expected: exit 2 + stderr mentions "validator runtime error" + rc=1 +
#      .processing retained for retry + .coverage-mismatch NOT created from
#      this entry (no false-positive validation FAIL marker).
test_flush_validator_runtime_error_fail_closed() {
  start_test "T17: validator rc=1 (runtime error) → flush fail-closed (exit 2), .processing retained"
  mk_sandbox_commit_gate
  # Replace stub with one that always returns rc 1 (runtime error per real
  # validator contract — only 0/2 are clean rc values).
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(1)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  mk_pass_plan "$SANDBOX/docs/plans/runtime-err.md"
  echo "$SANDBOX/docs/plans/runtime-err.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  assert_eq "exit_code_fail_closed" "2" "$HOOK_EXIT"
  # Both tokens must appear — phrase + rc value. `|` would let one alone pass,
  # weakening the contract (codex Round 1 Low advisory).
  if ! echo "$HOOK_STDERR" | grep -qF "validator runtime error"; then
    echo "  FAIL [stderr_phrase]: stderr should contain 'validator runtime error'" >&2
    echo "    actual stderr: $HOOK_STDERR" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  if ! echo "$HOOK_STDERR" | grep -qF "rc=1"; then
    echo "  FAIL [stderr_rc_value]: stderr should contain 'rc=1' (precise rc surfaced)" >&2
    echo "    actual stderr: $HOOK_STDERR" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  # .processing retained for retry (evidence preservation).
  assert_file_exists "processing_retained_on_runtime_error" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  # No .coverage-mismatch — runtime error must NOT be conflated with validation FAIL.
  assert_file_missing "no_marker_on_runtime_error" "$SANDBOX/trail/dod/.coverage-mismatch"
  end_test
  rm_sandbox
}

# T18: X3.B.5 — mixed runtime error + validation FAIL. Per design, runtime
#      error wins (fail-closed), but the FAIL marker IS preserved for next
#      flush (evidence). .processing also retained.
test_flush_mixed_runtime_and_fail_runtime_wins() {
  start_test "T18: mixed validator rc=1 (runtime) + rc=2 (FAIL) → fail-closed exit 2, FAIL marker preserved"
  mk_sandbox_commit_gate
  # Stub: rc 2 for plans containing FAIL_PLAN sentinel, rc 1 (runtime err)
  # otherwise, rc 0 only if VALIDATOR_PASS present.
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
#!/usr/bin/env python3
import sys
path = None
if len(sys.argv) == 2:
    path = sys.argv[1]
elif len(sys.argv) >= 3 and sys.argv[1] in ("plan", "dod"):
    path = sys.argv[2]
if not path:
    sys.exit(2)
try:
    with open(path) as f:
        body = f.read()
        if "VALIDATOR_PASS" in body:
            sys.exit(0)
        if "FAIL_PLAN" in body:
            sys.exit(2)
    sys.exit(1)
except OSError:
    sys.exit(2)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  echo "FAIL_PLAN" > "$SANDBOX/docs/plans/bad.md"
  echo "neither" > "$SANDBOX/docs/plans/runtime.md"
  printf '%s\n%s\n' "$SANDBOX/docs/plans/bad.md" "$SANDBOX/docs/plans/runtime.md" > "$SANDBOX/trail/dod/.plan-coverage-dirty"

  run_commit_gate "git commit -m 'feat(x): test'"
  # Runtime error must win — fail-closed exit 2.
  assert_eq "exit_code_runtime_wins" "2" "$HOOK_EXIT"
  # But validation FAIL evidence preserved in marker (so next flush attempt
  # has the FAIL information after user fixes the runtime issue).
  assert_file_exists "marker_preserved_alongside_runtime" "$SANDBOX/trail/dod/.coverage-mismatch"
  assert_file_contains "marker_has_fail_plan" "$SANDBOX/trail/dod/.coverage-mismatch" "$SANDBOX/docs/plans/bad.md"
  # .processing retained for retry.
  assert_file_exists "processing_retained_on_mixed" "$SANDBOX/trail/dod/.plan-coverage-dirty.processing"
  end_test
  rm_sandbox
}

# ======================================================================
# Run all tests
# ======================================================================

run_all() {
  test_post_edit_appends_one_line
  test_post_edit_fail_content_still_appends_no_marker
  test_post_edit_three_distinct_plans
  test_post_edit_non_plan_skip
  test_post_edit_deleted_plan_skip
  test_flush_pass_clears_processing
  test_flush_fail_creates_marker_and_denies
  test_flush_all_deleted_conservative_block
  test_flush_mixed_pass_deleted
  test_flush_stale_processing_handled
  test_flush_no_dirty_list_noop
  test_post_edit_lock_held_falls_back_to_immediate
  test_post_edit_lock_released_after_append
  test_pipe_buf_overflow_validator_missing_vocal
  test_flush_stale_processing_plus_fresh_invalid_blocks
  test_post_edit_lock_held_fail_plan_falls_back_vocal
  test_flush_validator_runtime_error_fail_closed
  test_flush_mixed_runtime_and_fail_runtime_wins
}

run_all

echo ""
echo "================================"
echo "Tests run: $((PASS_COUNT + FAIL_COUNT))"
echo "Passed:    $PASS_COUNT"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
