#!/bin/bash
# tests/hooks/test-bash-dispatcher.sh
#
# Cycle X2 (영역 A, plan §4.1) — pre-bash-dispatcher.sh + lib/bash-classifier.sh
# verification suite.
#
# Two suites:
#
# 1. classifier unit tests — exercise classify_bash_command() in isolation by
#    sourcing the library. Verifies CLASS_NEEDS_TC / CLASS_NEEDS_BR globals
#    for SAFE / TEST / COMMIT / BUILD commands plus edge cases (empty,
#    leading whitespace, comment-only).
#
# 2. dispatcher integration tests — invoke pre-bash-dispatcher.sh in the
#    sandbox with seeded downstream stubs. Verifies that the dispatcher
#    correctly invokes the right subset of helpers based on classification
#    and propagates exit codes.
#
# Why we stub downstream helpers in suite 2: the real helpers are end-to-end
# tested by their own files (test-bash-guard-split.sh etc). Here we only need
# to verify the dispatcher's invocation logic — i.e. that classifier output
# correctly drives which helpers fire.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER_LIB="$PROJECT_ROOT/plugins/rein-core/hooks/lib/bash-classifier.sh"
# GMF-1: canonical git subcommand model SSOT, sourced by classifier/dispatcher.
GIT_MODEL_LIB="$PROJECT_ROOT/plugins/rein-core/hooks/lib/git-subcommand-model.sh"

# ============================================================
# Suite 1: classify_bash_command() unit tests
# ============================================================
#
# Each test sources the classifier in a clean subshell so global state from
# previous classifications does not leak.

_classify() {
  # $1=command, prints "TC BR" pair
  (
    # shellcheck disable=SC1090
    . "$CLASSIFIER_LIB"
    classify_bash_command "$1"
    printf '%d %d\n' "$CLASS_NEEDS_TC" "$CLASS_NEEDS_BR"
  )
}

test_classifier_safe_command_needs_no_gates() {
  local result
  result=$(_classify "ls -la")
  assert_eq "0 0" "$result" "ls -la should classify as SAFE (no gates)"
}

test_classifier_empty_command_needs_no_gates() {
  local result
  result=$(_classify "")
  assert_eq "0 0" "$result" "empty command should classify as SAFE"
}

test_classifier_git_commit_needs_test_commit_gate() {
  local result
  result=$(_classify "git commit -m 'foo'")
  assert_eq "1 0" "$result" "git commit needs TC gate only (no rule injection)"
}

test_classifier_git_commit_bare_needs_test_commit_gate() {
  local result
  result=$(_classify "git commit")
  assert_eq "1 0" "$result" "bare 'git commit' needs TC gate"
}

test_classifier_pytest_needs_both_gates() {
  local result
  result=$(_classify "pytest tests/")
  assert_eq "1 1" "$result" "pytest needs both TC + BR gates"
}

test_classifier_pytest_bare_needs_both_gates() {
  local result
  result=$(_classify "pytest")
  assert_eq "1 1" "$result" "bare pytest needs both gates"
}

test_classifier_npm_test_needs_both_gates() {
  local result
  result=$(_classify "npm test")
  assert_eq "1 1" "$result" "npm test needs both gates"
}

test_classifier_npm_run_test_needs_both_gates() {
  local result
  result=$(_classify "npm run test")
  assert_eq "1 1" "$result" "npm run test needs both gates"
}

test_classifier_yarn_test_needs_both_gates() {
  local result
  result=$(_classify "yarn test foo")
  assert_eq "1 1" "$result" "yarn test needs both gates"
}

test_classifier_cargo_build_needs_only_rules() {
  local result
  result=$(_classify "cargo build --release")
  assert_eq "0 1" "$result" "cargo build needs only BR gate (advisory)"
}

test_classifier_docker_build_needs_only_rules() {
  local result
  result=$(_classify "docker build -t foo .")
  assert_eq "0 1" "$result" "docker build needs only BR gate"
}

test_classifier_make_needs_only_rules() {
  local result
  result=$(_classify "make all")
  assert_eq "0 1" "$result" "make needs only BR gate"
}

test_classifier_tsc_bare_needs_only_rules() {
  local result
  result=$(_classify "tsc")
  assert_eq "0 1" "$result" "bare tsc needs only BR gate"
}

test_classifier_bash_tests_needs_test_commit_only() {
  local result
  result=$(_classify "bash tests/run-all.sh")
  assert_eq "1 0" "$result" "bash tests/ needs TC gate only"
}

test_classifier_leading_whitespace_handled() {
  local result
  result=$(_classify "   pytest")
  assert_eq "1 1" "$result" "leading whitespace should not break classification"
}

test_classifier_substring_false_positive_avoided() {
  # "pytest" prefix should match. But "git commitfoo" should NOT match git commit,
  # because the case pattern requires either exact match or trailing-space form.
  local result
  result=$(_classify "git commitfoo")
  assert_eq "0 0" "$result" "git commitfoo (no space) must not match 'git commit' classifier"
}

# ------------------------------------------------------------
# GMF-1 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.1): canonical
# "git commit" detection SSOT. The old `"git commit" | "git commit "*`
# case missed multi-space + git global-option forms. These exercise the
# new shared lib/git-subcommand-model.sh matcher.
# ------------------------------------------------------------

# RED → GREEN: git -C <path> commit (global option between git and commit).
test_classifier_git_commit_dash_C_needs_test_commit_gate() {
  local result
  result=$(_classify "git -C . commit -m 'x'")
  assert_eq "1 0" "$result" "git -C . commit must classify as commit (TC gate)"
}

# RED → GREEN: double-space between git and commit.
test_classifier_git_commit_double_space_needs_test_commit_gate() {
  local result
  result=$(_classify "git  commit -m 'x'")
  assert_eq "1 0" "$result" "git  commit (double space) must classify as commit"
}

# RED → GREEN: git -c <kv> commit.
test_classifier_git_commit_dash_c_kv_needs_test_commit_gate() {
  local result
  result=$(_classify "git -c user.name=x commit -m 'x'")
  assert_eq "1 0" "$result" "git -c user.name=x commit must classify as commit"
}

# RED → GREEN: git --git-dir=.git commit.
test_classifier_git_commit_gitdir_needs_test_commit_gate() {
  local result
  result=$(_classify "git --git-dir=.git commit")
  assert_eq "1 0" "$result" "git --git-dir=.git commit must classify as commit"
}

# GREEN (over-match 0): config subcommand whose arg mentions commit.
test_classifier_git_config_commit_arg_not_gated() {
  local result
  result=$(_classify "git config commit.gpgsign true")
  assert_eq "0 0" "$result" "git config commit.gpgsign must NOT classify as commit"
}

# GREEN (over-match 0): echo mention of git commit is not an invocation.
test_classifier_echo_git_commit_mention_not_gated() {
  local result
  result=$(_classify 'echo "git commit"')
  assert_eq "0 0" "$result" "echo \"git commit\" mention must NOT classify as commit"
}

# GREEN (over-match 0): grep mention (clause-start anchor excludes it).
test_classifier_grep_git_commit_mention_not_gated() {
  local result
  result=$(_classify "grep git commit -m x")
  assert_eq "0 0" "$result" "grep git commit -m x mention must NOT classify as commit"
}

# GREEN (over-match 0): commit-graph is a different subcommand (shell-token boundary).
test_classifier_git_commit_graph_not_gated() {
  local result
  result=$(_classify "git commit-graph write")
  assert_eq "0 0" "$result" "git commit-graph write must NOT classify as commit (shell-token boundary)"
}

# GREEN (over-match 0): committer-foo bogus token.
test_classifier_git_committer_foo_not_gated() {
  local result
  result=$(_classify "git committer-foo")
  assert_eq "0 0" "$result" "git committer-foo must NOT classify as commit"
}

# GREEN (over-match 0): allowlist-outside option is conservative non-match.
test_classifier_git_bogus_option_commit_not_gated() {
  local result
  result=$(_classify "git --bogus commit")
  assert_eq "0 0" "$result" "git --bogus commit (allowlist-outside option) must NOT classify as commit"
}

# GREEN (over-match 0): unknown short option likewise.
test_classifier_git_dash_Z_commit_not_gated() {
  local result
  result=$(_classify "git -Z commit")
  assert_eq "0 0" "$result" "git -Z commit (allowlist-outside option) must NOT classify as commit"
}

test_classifier_jest_with_args_needs_test_commit_only() {
  # jest is in TC list (via "jest "*) but only with trailing args. The bash-rules
  # list does NOT include jest (the original hooks.json had pytest/npm/yarn/pnpm
  # but not jest in bash-rules). We preserve that asymmetry.
  local result
  result=$(_classify "jest --watchAll")
  assert_eq "1 0" "$result" "jest --watchAll should only need TC, not BR (current parity)"
}

# ============================================================
# Suite 2: dispatcher integration tests
# ============================================================
#
# The dispatcher invokes downstream helpers via subprocess. We seed stubbed
# helpers that log their invocation to a file, then verify which stubs ran
# based on classification.

# Seed a stub helper at $SANDBOX/.claude/hooks/<name> that records its
# invocation to $SANDBOX/invocations.log and returns the requested exit code.
_seed_stub_hook() {
  local hook_name="$1"
  local exit_code="${2:-0}"
  local stub_path="$SANDBOX/.claude/hooks/$hook_name"
  cat > "$stub_path" <<STUB
#!/bin/bash
# Test stub — records invocation, returns exit $exit_code.
echo "$hook_name" >> "$SANDBOX/invocations.log"
cat >/dev/null  # drain stdin (real helpers consume it)
exit $exit_code
STUB
  chmod +x "$stub_path"
}

# Read $SANDBOX/invocations.log into a space-joined string for assertion.
_invocations_line() {
  if [ -f "$SANDBOX/invocations.log" ]; then
    tr '\n' ' ' < "$SANDBOX/invocations.log" | sed 's/[[:space:]]*$//'
  fi
}

# Copy dispatcher + classifier into the sandbox layout the harness uses
# (.claude/hooks/...).
_seed_dispatcher() {
  cp "$PROJECT_ROOT/plugins/rein-core/hooks/pre-bash-dispatcher.sh" \
     "$SANDBOX/.claude/hooks/pre-bash-dispatcher.sh"
  chmod +x "$SANDBOX/.claude/hooks/pre-bash-dispatcher.sh"
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$CLASSIFIER_LIB" "$SANDBOX/.claude/hooks/lib/bash-classifier.sh"
  # GMF-1: classifier + dispatcher both source the canonical git subcommand
  # model. Without it the fail-closed default keeps the commit gate ON.
  cp "$GIT_MODEL_LIB" "$SANDBOX/.claude/hooks/lib/git-subcommand-model.sh" 2>/dev/null || true
}

# _run_dispatcher <command-json>
#   Invokes the dispatcher with CLAUDE_PLUGIN_ROOT pointing at the sandbox
#   (so it finds the stubbed helpers + classifier). Sets HOOK_EXIT.
_run_dispatcher() {
  local stdin_json="$1"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "$stdin_json" \
    | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-bash-dispatcher.sh" \
      > "$tmp_stdout" 2> "$tmp_stderr"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_stdout")
  HOOK_STDERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr"
}

test_dispatcher_safe_command_invokes_only_always_run() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "SAFE command should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "SAFE: only bootstrap + safety should fire"
}

test_dispatcher_git_commit_invokes_tc_gate() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 0 "git commit (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "git commit: bootstrap + safety + test-commit should fire (no rule injection)"
}

test_dispatcher_pytest_invokes_both_conditional_gates() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 0 "pytest (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh pre-tool-use-bash-rules.sh" "$got" \
    "pytest: all four helpers should fire in order"
}

test_dispatcher_bootstrap_failure_short_circuits() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 2
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest"}}'

  assert_exit 2 "bootstrap exit 2 should propagate"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh" "$got" \
    "bootstrap failure: chain stops after bootstrap"
}

test_dispatcher_safety_failure_short_circuits() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 2
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit"}}'

  assert_exit 2 "safety exit 2 should propagate"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "safety failure: chain stops after safety, test-commit not invoked"
}

test_dispatcher_test_commit_failure_skips_bash_rules() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 2
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest"}}'

  assert_exit 2 "test-commit exit 2 should propagate"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "test-commit failure: bash-rules not invoked"
}

test_dispatcher_cargo_build_invokes_only_bash_rules() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"cargo build --release"}}'

  assert_exit 0 "cargo build (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-tool-use-bash-rules.sh" "$got" \
    "cargo build: bootstrap + safety + bash-rules (no test-commit)"
}

test_dispatcher_missing_classifier_runs_conservative_gates() {
  # Cycle X2 codex review High 1.2: missing classifier MUST fail closed for
  # test-commit-gate (default CLASS_NEEDS_TC=1). bash-rules remains advisory.
  _seed_dispatcher
  rm -f "$SANDBOX/.claude/hooks/lib/bash-classifier.sh"
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 0 "missing classifier (conservative) should still pass when helpers ok"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "missing classifier: must conservatively invoke test-commit-gate (TC=1 default), bash-rules stays off"
}

test_dispatcher_missing_safety_guard_fails_closed() {
  # Codex review High 1.1: a missing critical helper must not silently disable
  # its block points. safety-guard enforces P1/P8/P9/P10/P11 — refuse the call.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  # No safety-guard stub seeded — simulate missing file.
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 2 "missing safety-guard must fail closed (exit 2)"
  echo "$HOOK_STDERR" | grep -qF "[rein]" \
    || fail "expected '[rein]' diagnostic on stderr, got: $HOOK_STDERR"
  echo "$HOOK_STDERR" | grep -qF "safety guard" \
    || fail "expected 'safety guard' in stderr, got: $HOOK_STDERR"
}

test_dispatcher_missing_test_commit_gate_fails_closed_on_git_commit() {
  # Codex review High 1.1: missing test-commit-gate on a classified
  # commit/test command must fail closed — silently allowing the commit would
  # bypass P3/P4/P5/P6/P7 stamp + format checks.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  # No test-commit-gate stub seeded — simulate missing file.
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 2 "missing test-commit-gate on git commit must fail closed"
  echo "$HOOK_STDERR" | grep -qF "test/commit gate" \
    || fail "expected 'test/commit gate' in stderr, got: $HOOK_STDERR"
}

test_dispatcher_missing_test_commit_gate_silent_pass_on_safe_command() {
  # When classifier correctly says SAFE (NEEDS_TC=0), missing test-commit-gate
  # is irrelevant — dispatcher never tries to invoke it.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  # No test-commit-gate stub seeded.
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "SAFE command must not trip on missing (unneeded) test-commit-gate"
}

test_dispatcher_missing_bash_rules_best_effort_pass() {
  # bash-rules is advisory rule injection. A missing file should NOT fail
  # closed — it would block every test command on a degraded install while
  # carrying no actual security value.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  # No bash-rules stub seeded.

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 0 "missing bash-rules (advisory only) must pass through"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "missing bash-rules: other three helpers still fire normally"
}

test_dispatcher_missing_bootstrap_gate_fails_closed() {
  # bootstrap gate is required — its absence cannot be silently masked.
  _seed_dispatcher
  # No bootstrap stub seeded.
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 2 "missing bootstrap gate must fail closed"
  echo "$HOOK_STDERR" | grep -qF "bootstrap gate" \
    || fail "expected 'bootstrap gate' in stderr, got: $HOOK_STDERR"
}

test_dispatcher_partial_classifier_source_failure_runs_conservative_gates() {
  # Codex review Round 2 Medium 2.1: partial source failure must not be
  # masked by declare -F (which would pass for a function defined before the
  # erroring line). Source rc capture (SOURCE_OK) closes that hole.
  _seed_dispatcher
  # Overwrite classifier with broken content: defines the function early,
  # then errors. `if . file; then` sees the non-zero rc → SOURCE_OK=0 →
  # classifier call skipped → TC stays at conservative default 1.
  cat > "$SANDBOX/.claude/hooks/lib/bash-classifier.sh" <<'BROKEN'
#!/bin/bash
classify_bash_command() {
  CLASS_NEEDS_TC=0  # would be the unsafe bypass if dispatcher trusted us
  CLASS_NEEDS_BR=0
}
# Force the source to end with a non-zero rc.
false
BROKEN
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "partial classifier source failure (stubs pass) should not block"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "partial source failure: test-commit-gate must fire (TC=1 default, classifier ignored)"
}

test_dispatcher_absent_command_field_runs_conservative_gates() {
  # Codex review Round 3 Medium 3.1: tool_input present but command field
  # absent (e.g. {"tool_input":{}}). With --default '' the extractor used to
  # exit 0 + empty COMMAND → classifier reset TC=0 → commit-gate bypass.
  # Dispatcher now omits --default so extractor exits non-zero on missing
  # field → COMMAND_EXTRACTED stays 0 → TC=1 default preserved.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{}}'

  assert_exit 0 "absent command field (stubs pass) should not block"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "absent command field: test-commit-gate must fire (TC=1 default, extractor rc!=0)"
}

test_dispatcher_command_extraction_failure_runs_conservative_gates() {
  # Codex review Round 2 Medium 2.2: command extraction failure must not
  # collapse to "safe / no gates". COMMAND_EXTRACTED=0 → classifier skipped →
  # TC stays at conservative default 1.
  _seed_dispatcher
  # Remove the JSON extractor to force extraction failure even though the
  # classifier lib is fine. python-runner is still present; resolve_python
  # succeeds; but the missing extract-hook-json.py makes the python call
  # rc != 0, leaving COMMAND_EXTRACTED=0.
  rm -f "$SANDBOX/.claude/hooks/lib/extract-hook-json.py"
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "extraction failure (stubs pass) should not block"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "extraction failure: test-commit-gate must fire (TC=1 default, classifier never called)"
}

test_dispatcher_git_dash_C_commit_invokes_tc_gate() {
  # GMF-1: git -C . commit (global option) must drive the test-commit gate via
  # the canonical model — the old classifier/_SM_CLASS pattern missed it.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git -C . commit -m foo"}}'

  assert_exit 0 "git -C . commit (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "git -C . commit: test-commit-gate must fire (canonical model)"
}

test_dispatcher_git_config_commit_arg_does_not_invoke_tc_gate() {
  # GMF-1 over-match 0: `git config commit.gpgsign` is a config subcommand;
  # the test-commit gate must NOT fire (no false positive).
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git config commit.gpgsign true"}}'

  assert_exit 0 "git config commit.gpgsign should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "git config commit.gpgsign: test-commit-gate must NOT fire (over-match 0)"
}

test_dispatcher_missing_git_model_lib_fails_closed_on_git_commit() {
  # GMF-1 / Task 1.6 (codex R2 HIGH): if the canonical git-subcommand-model
  # lib is absent, classifier + dispatcher must fail CLOSED — a command holding
  # a `commit` token conservatively drives the test-commit gate rather than
  # silently leaking. Verifies neither the classifier (_GIT_MODEL_OK=0 path)
  # nor _SM_CLASS drops the commit gate.
  _seed_dispatcher
  rm -f "$SANDBOX/.claude/hooks/lib/git-subcommand-model.sh"
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git -C . commit -m foo"}}'

  assert_exit 0 "missing git model lib (stubs pass) should still pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "missing git model lib: test-commit-gate must fire (fail-closed, commit token present)"
}

test_dispatcher_broken_git_model_lib_fails_closed_on_git_commit() {
  # GMF-1 / Task 1.6: a corrupt model lib (source rc!=0 / matcher undefined)
  # must also fail closed. Overwrite with a stub that omits git_clause_invokes
  # and errors at the end so _GIT_MODEL_OK stays 0.
  _seed_dispatcher
  cat > "$SANDBOX/.claude/hooks/lib/git-subcommand-model.sh" <<'BROKEN'
#!/bin/bash
# Broken model lib: no git_clause_invokes, ends with non-zero rc.
GIT_COMMIT_ERE=""
false
BROKEN
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 0 "broken git model lib (stubs pass) should still pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh" "$got" \
    "broken git model lib: test-commit-gate must fire (fail-closed)"
}

test_dispatcher_special_char_command_safely_passed_through() {
  # Codex review note: printf '%s' "$INPUT" | bash hook does not evaluate
  # backticks/$()/$VAR inside INPUT. Verify by sending a JSON command field
  # containing those metachars and confirming downstream stub sees stdin as
  # bytes (we just check the dispatcher does not crash and returns 0).
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-test-commit-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  # Command contains backtick + $() + $VAR; classifier classifies as SAFE
  # (does not match any test/commit/build prefix), so only always-run helpers
  # should fire. The point is that dispatcher must not eval these metachars.
  _run_dispatcher '{"tool_input":{"command":"echo `id` $(whoami) $HOME"}}'

  assert_exit 0 "special-char command must pass through dispatcher unchanged"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "special-char command classifies as SAFE (no shell expansion in dispatcher)"
}

# ============================================================
# Main
# ============================================================

# Suite 1 — classifier units (no sandbox needed, but harness sets test count)
run_test test_classifier_safe_command_needs_no_gates
run_test test_classifier_empty_command_needs_no_gates
run_test test_classifier_git_commit_needs_test_commit_gate
run_test test_classifier_git_commit_bare_needs_test_commit_gate
run_test test_classifier_pytest_needs_both_gates
run_test test_classifier_pytest_bare_needs_both_gates
run_test test_classifier_npm_test_needs_both_gates
run_test test_classifier_npm_run_test_needs_both_gates
run_test test_classifier_yarn_test_needs_both_gates
run_test test_classifier_cargo_build_needs_only_rules
run_test test_classifier_docker_build_needs_only_rules
run_test test_classifier_make_needs_only_rules
run_test test_classifier_tsc_bare_needs_only_rules
run_test test_classifier_bash_tests_needs_test_commit_only
run_test test_classifier_leading_whitespace_handled
run_test test_classifier_substring_false_positive_avoided
run_test test_classifier_jest_with_args_needs_test_commit_only
# GMF-1 canonical commit detection (classifier unit)
run_test test_classifier_git_commit_dash_C_needs_test_commit_gate
run_test test_classifier_git_commit_double_space_needs_test_commit_gate
run_test test_classifier_git_commit_dash_c_kv_needs_test_commit_gate
run_test test_classifier_git_commit_gitdir_needs_test_commit_gate
run_test test_classifier_git_config_commit_arg_not_gated
run_test test_classifier_echo_git_commit_mention_not_gated
run_test test_classifier_grep_git_commit_mention_not_gated
run_test test_classifier_git_commit_graph_not_gated
run_test test_classifier_git_committer_foo_not_gated
run_test test_classifier_git_bogus_option_commit_not_gated
run_test test_classifier_git_dash_Z_commit_not_gated

# Suite 2 — dispatcher integration (uses sandbox)
run_test test_dispatcher_safe_command_invokes_only_always_run
run_test test_dispatcher_git_commit_invokes_tc_gate
run_test test_dispatcher_pytest_invokes_both_conditional_gates
run_test test_dispatcher_bootstrap_failure_short_circuits
run_test test_dispatcher_safety_failure_short_circuits
run_test test_dispatcher_test_commit_failure_skips_bash_rules
run_test test_dispatcher_cargo_build_invokes_only_bash_rules
run_test test_dispatcher_missing_classifier_runs_conservative_gates
run_test test_dispatcher_missing_safety_guard_fails_closed
run_test test_dispatcher_missing_test_commit_gate_fails_closed_on_git_commit
run_test test_dispatcher_missing_test_commit_gate_silent_pass_on_safe_command
run_test test_dispatcher_missing_bash_rules_best_effort_pass
run_test test_dispatcher_missing_bootstrap_gate_fails_closed
run_test test_dispatcher_partial_classifier_source_failure_runs_conservative_gates
run_test test_dispatcher_absent_command_field_runs_conservative_gates
run_test test_dispatcher_command_extraction_failure_runs_conservative_gates
# GMF-1 canonical commit detection (dispatcher integration + fail-closed)
run_test test_dispatcher_git_dash_C_commit_invokes_tc_gate
run_test test_dispatcher_git_config_commit_arg_does_not_invoke_tc_gate
run_test test_dispatcher_missing_git_model_lib_fails_closed_on_git_commit
run_test test_dispatcher_broken_git_model_lib_fails_closed_on_git_commit
run_test test_dispatcher_special_char_command_safely_passed_through

summary
