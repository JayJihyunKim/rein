#!/bin/bash
# tests/hooks/test-pre-bash-guard-coverage-self-heal.sh
#
# Verifies the consumer-side coverage marker self-heal added to
# pre-bash-guard.sh by dod-2026-05-15-pre-bash-guard-marker-self-heal.
#
# Contract under test (pre-bash-guard.sh `revalidate_coverage_marker`):
#   rc=0  validator PASS for >=1 actually-validated target → caller silent rm + continue
#   rc=1  validator FAIL → caller blocks + emits target in message
#   rc=2  cannot revalidate → caller conservatively blocks (legacy behavior)
#
# Sandbox model: copy pre-bash-guard.sh + lib/ + a stub validator into a
# tempdir, drive the hook with synthetic JSON on stdin, assert exit code + stderr.

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) return 0 ;;
  esac
  echo "  FAIL [$label]: '$needle' not in stderr" >&2
  echo "    stderr: $haystack" >&2
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

mk_sandbox() {
  SANDBOX=$(mktemp -d "/tmp/pbg-self-heal-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/trail/incidents"

  # Plugin SSOT (Option C Phase 3): hooks live under plugins/rein-core/.
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/pre-bash-guard.sh" "$SANDBOX/.claude/hooks/"
  cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/." "$SANDBOX/.claude/hooks/lib/"
  chmod +x "$SANDBOX/.claude/hooks/pre-bash-guard.sh"

  # Stub validator: any target file containing literal "VALIDATOR_PASS" → exit 0.
  # Otherwise exit 1 (mimicking real coverage validator failure).
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

rm_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# Run pre-bash-guard.sh with the given Bash command on stdin, capture stderr+exit.
# Sets HOOK_EXIT and HOOK_STDERR.
#
# INFO-2 (security review): unset CLAUDE_PLUGIN_ROOT before invoking the hook
# so the policy-loader block at the top of pre-bash-guard.sh runs in scaffold
# mode (skips loader). Maintainer dev environments export CLAUDE_PLUGIN_ROOT
# pointing at the real plugin tree, which would let the loader resolve real
# files outside the sandbox and mask test failures. `env -u` produces a
# hermetic execution environment regardless of the parent shell.
HOOK_STDOUT=""

run_hook() {
  local cmd="$1"
  local input
  input=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")
  local out_file err_file
  out_file=$(mktemp)
  err_file=$(mktemp)
  HOOK_EXIT=0
  printf '%s' "$input" \
    | (cd "$SANDBOX" && env -u CLAUDE_PLUGIN_ROOT bash .claude/hooks/pre-bash-guard.sh) \
    > "$out_file" 2> "$err_file"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

# Make a "valid" plan/DoD that will pass the stub validator.
mk_pass_target() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  echo "VALIDATOR_PASS" > "$path"
}

# Make a "failing" plan/DoD.
mk_fail_target() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  echo "no marker" > "$path"
}

# Test 1: stale .coverage-mismatch with validator PASS → silent self-heal
test_coverage_mismatch_stale_pass() {
  start_test "T1: stale .coverage-mismatch + validator PASS → marker cleared, command allowed"
  mk_sandbox
  mk_pass_target "$SANDBOX/docs/plans/foo-plan.md"
  echo "$SANDBOX/docs/plans/foo-plan.md" > "$SANDBOX/trail/dod/.coverage-mismatch"

  run_hook "bash tests/hooks/test-stop-gate.sh"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  if [ -f "$SANDBOX/trail/dod/.coverage-mismatch" ]; then
    echo "  FAIL [marker_cleared]: .coverage-mismatch still exists" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# Test 2: real .coverage-mismatch with validator FAIL → JSON deny (P2, rc=1)
# [P2] rc=1 = identifiable failing target → JSON deny COVERAGE_MISMATCH (exit 0 + JSON).
# The target path appears in additionalContext (untrusted_input slot of deny_emit).
test_coverage_mismatch_real_fail() {
  start_test "T2: real .coverage-mismatch + validator FAIL → JSON deny COVERAGE_MISMATCH"
  mk_sandbox
  mk_fail_target "$SANDBOX/docs/plans/bar-plan.md"
  echo "$SANDBOX/docs/plans/bar-plan.md" > "$SANDBOX/trail/dod/.coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  # permissionDecision must be "deny"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecision"])
' 2>/dev/null)
  assert_eq "permissionDecision" "deny" "$decision"
  # reason_code COVERAGE_MISMATCH must appear in permissionDecisionReason
  local pdr
  pdr=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecisionReason"])
' 2>/dev/null)
  case "$pdr" in
    *"COVERAGE_MISMATCH"*) ;;
    *) CURRENT_FAILS=$((CURRENT_FAILS + 1))
       echo "  FAIL [reason_code]: 'COVERAGE_MISMATCH' not in permissionDecisionReason: '$pdr'" >&2 ;;
  esac
  # target path must appear somewhere in the JSON output (additionalContext)
  case "$HOOK_STDOUT" in
    *"bar-plan.md"*) ;;
    *) CURRENT_FAILS=$((CURRENT_FAILS + 1))
       echo "  FAIL [target_in_json]: 'bar-plan.md' not in JSON output: $HOOK_STDOUT" >&2 ;;
  esac
  end_test
  rm_sandbox
}

# Test 3: .coverage-mismatch with all paths deleted → conservative block
# (must NOT silent-heal — no positive PASS evidence)
# [I3] infra integrity — rc=2 (cannot revalidate, all entries deleted) → exit 2 PRESERVED.
# JSON deny conversion applies ONLY to rc=1 (P2). rc=2 stays exit 2. Do NOT convert.
test_coverage_mismatch_all_deleted() {
  start_test "T3: .coverage-mismatch with all entries deleted → conservative block (no positive evidence)"
  mk_sandbox
  # plan paths in marker but files don't exist
  printf '%s\n%s\n' "$SANDBOX/docs/plans/gone-a.md" "$SANDBOX/docs/plans/gone-b.md" \
    > "$SANDBOX/trail/dod/.coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "2" "$HOOK_EXIT"
  assert_contains "conservative_msg" "could not be identified" "$HOOK_STDERR"
  if [ ! -f "$SANDBOX/trail/dod/.coverage-mismatch" ]; then
    echo "  FAIL [marker_preserved]: .coverage-mismatch was incorrectly cleared" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# Test 4: empty .coverage-mismatch → conservative block
# [I3] infra integrity — rc=2 (cannot revalidate, marker is empty) → exit 2 PRESERVED.
# JSON deny conversion applies ONLY to rc=1 (P2). rc=2 stays exit 2. Do NOT convert.
test_coverage_mismatch_empty() {
  start_test "T4: empty .coverage-mismatch → conservative block"
  mk_sandbox
  : > "$SANDBOX/trail/dod/.coverage-mismatch"  # 0 bytes

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "2" "$HOOK_EXIT"
  assert_contains "conservative_msg" "could not be identified" "$HOOK_STDERR"
  end_test
  rm_sandbox
}

# Test 5: stale .dod-coverage-mismatch (Tier 1 + validator PASS) → silent heal
test_dod_mismatch_tier1_pass() {
  start_test "T5: stale .dod-coverage-mismatch + Tier 1 + validator PASS → marker cleared"
  mk_sandbox
  # DoD with `## 범위 연결` so it's a valid coverage target + VALIDATOR_PASS
  cat > "$SANDBOX/trail/dod/dod-2026-05-15-active.md" <<'DOD'
# DoD
VALIDATOR_PASS

## 범위 연결
plan ref: docs/plans/foo.md
DOD
  echo "path=trail/dod/dod-2026-05-15-active.md" > "$SANDBOX/trail/dod/.active-dod"
  : > "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  if [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ]; then
    echo "  FAIL [marker_cleared]: .dod-coverage-mismatch still exists" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# Test 6: real .dod-coverage-mismatch (Tier 1 + validator FAIL) → JSON deny (P2, rc=1)
# [P2] rc=1 = identifiable failing target → JSON deny COVERAGE_MISMATCH (exit 0 + JSON).
# The DoD path appears in additionalContext (untrusted_input slot of deny_emit).
test_dod_mismatch_tier1_fail() {
  start_test "T6: real .dod-coverage-mismatch + Tier 1 + validator FAIL → JSON deny COVERAGE_MISMATCH"
  mk_sandbox
  cat > "$SANDBOX/trail/dod/dod-2026-05-15-active.md" <<'DOD'
# DoD (failing)

## 범위 연결
plan ref: docs/plans/foo.md
DOD
  echo "path=trail/dod/dod-2026-05-15-active.md" > "$SANDBOX/trail/dod/.active-dod"
  : > "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "0" "$HOOK_EXIT"
  # permissionDecision must be "deny"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecision"])
' 2>/dev/null)
  assert_eq "permissionDecision" "deny" "$decision"
  # reason_code COVERAGE_MISMATCH must appear in permissionDecisionReason
  local pdr
  pdr=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecisionReason"])
' 2>/dev/null)
  case "$pdr" in
    *"COVERAGE_MISMATCH"*) ;;
    *) CURRENT_FAILS=$((CURRENT_FAILS + 1))
       echo "  FAIL [reason_code]: 'COVERAGE_MISMATCH' not in permissionDecisionReason: '$pdr'" >&2 ;;
  esac
  # target path must appear somewhere in the JSON output (additionalContext)
  case "$HOOK_STDOUT" in
    *"dod-2026-05-15-active.md"*) ;;
    *) CURRENT_FAILS=$((CURRENT_FAILS + 1))
       echo "  FAIL [target_in_json]: 'dod-2026-05-15-active.md' not in JSON output: $HOOK_STDOUT" >&2 ;;
  esac
  end_test
  rm_sandbox
}

# Test 7: .dod-coverage-mismatch with no .active-dod → Tier 2 fallback → DON'T heal
# (Tier 2 might be a different DoD than the one that produced the marker)
# [I3] infra integrity — rc=2 (Tier 2 fallback, cannot trust target identity) → exit 2 PRESERVED.
test_dod_mismatch_tier2_no_heal() {
  start_test "T7: .dod-coverage-mismatch with Tier 2 fallback → conservative block (don't trust)"
  mk_sandbox
  # No .active-dod marker. trail/dod/ has 1 DoD with 범위 연결 → Tier 2 selection.
  cat > "$SANDBOX/trail/dod/dod-2026-05-14-fallback.md" <<'DOD'
# DoD
VALIDATOR_PASS

## 범위 연결
plan ref: docs/plans/foo.md
DOD
  : > "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "2" "$HOOK_EXIT"
  if [ ! -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ]; then
    echo "  FAIL [marker_preserved]: .dod-coverage-mismatch was incorrectly cleared via Tier 2" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# Test 8: .dod-coverage-mismatch with no candidates → Tier 0 → conservative block
# [I3] infra integrity — rc=2 (Tier 0, no candidates) → exit 2 PRESERVED.
test_dod_mismatch_tier0() {
  start_test "T8: .dod-coverage-mismatch with no DoD candidates → Tier 0 → conservative block"
  mk_sandbox
  # No .active-dod, no DoD files in trail/dod/.
  : > "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "2" "$HOOK_EXIT"
  assert_contains "conservative_msg" "could not be identified" "$HOOK_STDERR"
  end_test
  rm_sandbox
}

# Test 9: validator missing → return 2 → conservative block
# [I3] infra integrity — rc=2 (validator missing, cannot revalidate) → exit 2 PRESERVED.
test_validator_missing() {
  start_test "T9: validator stub missing → conservative block (fail-closed)"
  mk_sandbox
  rm -f "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  mk_pass_target "$SANDBOX/docs/plans/foo-plan.md"
  echo "$SANDBOX/docs/plans/foo-plan.md" > "$SANDBOX/trail/dod/.coverage-mismatch"

  run_hook "bash tests/hooks/test-foo.sh"
  assert_eq "exit_code" "2" "$HOOK_EXIT"
  assert_contains "conservative_msg" "could not be identified" "$HOOK_STDERR"
  end_test
  rm_sandbox
}

main() {
  test_coverage_mismatch_stale_pass
  test_coverage_mismatch_real_fail
  test_coverage_mismatch_all_deleted
  test_coverage_mismatch_empty
  test_dod_mismatch_tier1_pass
  test_dod_mismatch_tier1_fail
  test_dod_mismatch_tier2_no_heal
  test_dod_mismatch_tier0
  test_validator_missing

  echo ""
  echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
