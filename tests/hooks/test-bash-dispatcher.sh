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

# Seed a stub helper at $SANDBOX/.claude/hooks/<name> that records its
# invocation, writes $2 verbatim to stdout, then exits 0 (exit 0 + non-empty
# stdout is the JSON-deny relay convention — see pre-bash-dispatcher.sh Step 3
# header). Writes the payload to a sibling file first (rather than inlining it
# into the heredoc) so quote/backslash content inside the JSON string cannot
# break the generated stub script.
_seed_stub_hook_json_deny() {
  local hook_name="$1"
  local json="$2"
  local stub_path="$SANDBOX/.claude/hooks/$hook_name"
  local payload_path="$SANDBOX/.claude/hooks/${hook_name}.stdout-payload.json"
  printf '%s' "$json" > "$payload_path"
  cat > "$stub_path" <<STUB
#!/bin/bash
# Test stub — records invocation, relays a fixed JSON payload on stdout, exit 0.
echo "$hook_name" >> "$SANDBOX/invocations.log"
cat >/dev/null  # drain stdin (real helpers consume it)
cat "$payload_path"
exit 0
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
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "SAFE command should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "SAFE: only bootstrap + safety should fire"
}

test_dispatcher_git_commit_invokes_tc_gate() {
  # Phase 7 웨이브 3 ③-c: the TC step is now two sequential children —
  # discipline-gate then review-gate (dispatcher header Step 3).
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 0 "git commit (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "git commit: bootstrap + safety + discipline + review should fire in order (no rule injection)"
}

# ------------------------------------------------------------
# ③-c 신설 계약 case (d) — 두 TC 자식 모두 통과 → Step 4(bash-rules) 도달.
# pytest 는 CLASS_NEEDS_BR=1 이라 이 케이스가 discipline→review→bash-rules
# 전 구간이 순서대로 실행됨을 증명한다.
# ------------------------------------------------------------
test_dispatcher_pytest_invokes_both_conditional_gates() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 0 "pytest (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh pre-tool-use-bash-rules.sh" "$got" \
    "pytest: all five helpers should fire in order (both TC children pass → Step 4 reached)"
}

test_dispatcher_bootstrap_failure_short_circuits() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 2
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
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
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit"}}'

  assert_exit 2 "safety exit 2 should propagate"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "safety failure: chain stops after safety, TC children not invoked"
}

# ------------------------------------------------------------
# ③-c 신설 계약 case (b) — 첫 자식(discipline-gate) rc=2 → 즉시 중단, 두
# 번째 자식(review-gate) 및 Step 4(bash-rules) 미실행.
# ------------------------------------------------------------
test_dispatcher_discipline_rc2_stops_chain_review_and_rules_skipped() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 2
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 2 "discipline-gate exit 2 should propagate immediately"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh" "$got" \
    "discipline-gate rc=2: review-gate and bash-rules must not run"
}

# 대칭 케이스 — 두 번째 자식(review-gate) rc=2 → discipline-gate 는 이미
# 통과했으므로 실행 흔적이 남고, 그 뒤 review-gate 에서 중단 → bash-rules
# 미실행.
test_dispatcher_review_rc2_stops_chain_rules_skipped() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 2
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 2 "review-gate exit 2 should propagate immediately"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "review-gate rc=2: discipline-gate already ran + passed; bash-rules must not run"
}

# ------------------------------------------------------------
# ③-c 신설 계약 case (a) — 첫 자식(discipline-gate) JSON deny (exit 0 +
# stdout) → 디스패처 stdout 에 JSON 정확히 1개 relay + 즉시 종료 (두 번째
# 자식 review-gate 미실행 + Step 4 미실행). pytest 사용 — CLASS_NEEDS_BR=1
# 이라 "그렇지 않았다면 Step 4 가 돌았을 것"임을 증명한다.
# ------------------------------------------------------------
test_dispatcher_discipline_json_deny_relays_single_object_and_stops_chain() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook_json_deny "pre-bash-commit-discipline-gate.sh" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub discipline deny"}}'
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 0 "JSON deny relay uses exit 0 convention"
  local json_count
  json_count=$(printf '%s' "$HOOK_STDOUT" | grep -c '"permissionDecision"')
  [ "$json_count" -eq 1 ] || fail "디스패처 stdout 에 JSON 오브젝트가 정확히 1개 있어야 함 — got count=$json_count : $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"stub discipline deny"*) ;;
    *) fail "relay 된 JSON 이 discipline-gate 고유 문구를 포함하지 않음: $HOOK_STDOUT" ;;
  esac
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh" "$got" \
    "discipline-gate JSON deny 이후 review-gate 및 bash-rules 는 미실행"
}

# ------------------------------------------------------------
# ③-c 신설 계약 case (c) — 자식 비정상 rc(예: 1)→fail-closed exit 2. 두
# 위치(discipline / review) 모두 검증.
# ------------------------------------------------------------
test_dispatcher_discipline_abnormal_exit_fails_closed() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 1
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 2 "discipline-gate abnormal exit (rc=1) must fail closed"
  echo "$HOOK_STDERR" | grep -qF "exited abnormally" \
    || fail "expected 'exited abnormally' in stderr, got: $HOOK_STDERR"
  echo "$HOOK_STDERR" | grep -qF "pre-bash-commit-discipline-gate.sh" \
    || fail "expected hook filename in stderr, got: $HOOK_STDERR"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh" "$got" \
    "abnormal exit: review-gate must not run"
}

test_dispatcher_review_abnormal_exit_fails_closed() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 1
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 2 "review-gate abnormal exit (rc=1) must fail closed"
  echo "$HOOK_STDERR" | grep -qF "exited abnormally" \
    || fail "expected 'exited abnormally' in stderr, got: $HOOK_STDERR"
  echo "$HOOK_STDERR" | grep -qF "pre-bash-commit-review-gate.sh" \
    || fail "expected hook filename in stderr, got: $HOOK_STDERR"
}

test_dispatcher_cargo_build_invokes_only_bash_rules() {
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"cargo build --release"}}'

  assert_exit 0 "cargo build (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-tool-use-bash-rules.sh" "$got" \
    "cargo build: bootstrap + safety + bash-rules (no TC children)"
}

test_dispatcher_missing_classifier_runs_conservative_gates() {
  # Cycle X2 codex review High 1.2: missing classifier MUST fail closed for
  # the TC step (default CLASS_NEEDS_TC=1). bash-rules remains advisory.
  # ③-c: CLASS_NEEDS_TC=1 now drives BOTH TC children in sequence.
  _seed_dispatcher
  rm -f "$SANDBOX/.claude/hooks/lib/bash-classifier.sh"
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 0 "missing classifier (conservative) should still pass when helpers ok"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "missing classifier: must conservatively invoke both TC children (TC=1 default), bash-rules stays off"
}

test_dispatcher_missing_safety_guard_fails_closed() {
  # Codex review High 1.1: a missing critical helper must not silently disable
  # its block points. safety-guard enforces P1/P8/P9/P10/P11 — refuse the call.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  # No safety-guard stub seeded — simulate missing file.
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 2 "missing safety-guard must fail closed (exit 2)"
  echo "$HOOK_STDERR" | grep -qF "[rein]" \
    || fail "expected '[rein]' diagnostic on stderr, got: $HOOK_STDERR"
  echo "$HOOK_STDERR" | grep -qF "safety guard" \
    || fail "expected 'safety guard' in stderr, got: $HOOK_STDERR"
}

# ------------------------------------------------------------
# ③-c 신설 계약 case (e) — 자식 파일 부재→fail-closed exit 2. 두 위치
# (discipline / review) 모두 검증 — invoke_bash_child 는 자식 경로가 없으면
# 실행 자체를 시도하지 않고 즉시 _BC_RC=2.
# ------------------------------------------------------------
test_dispatcher_missing_discipline_gate_fails_closed_on_git_commit() {
  # (was: test_dispatcher_missing_test_commit_gate_fails_closed_on_git_commit)
  # Codex review High 1.1 lineage — missing the FIRST TC-step child on a
  # classified commit/test command must fail closed — silently allowing the
  # commit would bypass P2/P7 discipline checks.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  # No discipline-gate stub seeded — simulate missing file.
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 2 "missing discipline-gate on git commit must fail closed"
  echo "$HOOK_STDERR" | grep -qF "commit discipline gate" \
    || fail "expected 'commit discipline gate' in stderr, got: $HOOK_STDERR"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "missing discipline-gate: bootstrap+safety ran, discipline-gate itself never invoked (file absent), review-gate not reached"
}

test_dispatcher_missing_review_gate_fails_closed_on_git_commit() {
  # SECOND TC-step child missing (discipline-gate ran + passed) must also
  # fail closed — silently allowing the commit would bypass the code_review/
  # security_review v2 delegation axes entirely.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  # No review-gate stub seeded — simulate missing file.
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 2 "missing review-gate on git commit must fail closed"
  echo "$HOOK_STDERR" | grep -qF "commit review gate" \
    || fail "expected 'commit review gate' in stderr, got: $HOOK_STDERR"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh" "$got" \
    "missing review-gate: discipline-gate should have run + passed before failure"
}

test_dispatcher_missing_tc_children_silent_pass_on_safe_command() {
  # (was: test_dispatcher_missing_test_commit_gate_silent_pass_on_safe_command)
  # When classifier correctly says SAFE (NEEDS_TC=0), missing TC children is
  # irrelevant — dispatcher never tries to invoke either of them.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  # No TC-step stubs seeded (neither discipline-gate nor review-gate).
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "SAFE command must not trip on missing (unneeded) TC children"
}

test_dispatcher_missing_bash_rules_best_effort_pass() {
  # bash-rules is advisory rule injection. A missing file should NOT fail
  # closed — it would block every test command on a degraded install while
  # carrying no actual security value.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  # No bash-rules stub seeded.

  _run_dispatcher '{"tool_input":{"command":"pytest tests/"}}'

  assert_exit 0 "missing bash-rules (advisory only) must pass through"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "missing bash-rules: other four helpers still fire normally"
}

test_dispatcher_missing_bootstrap_gate_fails_closed() {
  # bootstrap gate is required — its absence cannot be silently masked.
  _seed_dispatcher
  # No bootstrap stub seeded.
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
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
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "partial classifier source failure (stubs pass) should not block"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "partial source failure: both TC children must fire (TC=1 default, classifier ignored)"
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
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{}}'

  assert_exit 0 "absent command field (stubs pass) should not block"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "absent command field: both TC children must fire (TC=1 default, extractor rc!=0)"
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
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"ls -la"}}'

  assert_exit 0 "extraction failure (stubs pass) should not block"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "extraction failure: both TC children must fire (TC=1 default, classifier never called)"
}

test_dispatcher_git_dash_C_commit_invokes_tc_gate() {
  # GMF-1: git -C . commit (global option) must drive the TC step via the
  # canonical model — the old classifier/_SM_CLASS pattern missed it.
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git -C . commit -m foo"}}'

  assert_exit 0 "git -C . commit (stubs pass) should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "git -C . commit: both TC children must fire (canonical model)"
}

test_dispatcher_git_config_commit_arg_does_not_invoke_tc_gate() {
  # GMF-1 over-match 0: `git config commit.gpgsign` is a config subcommand;
  # the TC step must NOT fire (no false positive).
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git config commit.gpgsign true"}}'

  assert_exit 0 "git config commit.gpgsign should pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh" "$got" \
    "git config commit.gpgsign: TC children must NOT fire (over-match 0)"
}

test_dispatcher_missing_git_model_lib_fails_closed_on_git_commit() {
  # GMF-1 / Task 1.6 (codex R2 HIGH): if the canonical git-subcommand-model
  # lib is absent, classifier + dispatcher must fail CLOSED — a command holding
  # a `commit` token conservatively drives the TC step rather than silently
  # leaking. Verifies neither the classifier (_GIT_MODEL_OK=0 path) nor
  # _SM_CLASS drops the TC step.
  _seed_dispatcher
  rm -f "$SANDBOX/.claude/hooks/lib/git-subcommand-model.sh"
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git -C . commit -m foo"}}'

  assert_exit 0 "missing git model lib (stubs pass) should still pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "missing git model lib: both TC children must fire (fail-closed, commit token present)"
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
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
  _seed_stub_hook "pre-tool-use-bash-rules.sh" 0

  _run_dispatcher '{"tool_input":{"command":"git commit -m foo"}}'

  assert_exit 0 "broken git model lib (stubs pass) should still pass"
  local got
  got=$(_invocations_line)
  assert_eq "pre-tool-use-bash-bootstrap-gate.sh pre-bash-safety-guard.sh pre-bash-commit-discipline-gate.sh pre-bash-commit-review-gate.sh" "$got" \
    "broken git model lib: both TC children must fire (fail-closed)"
}

test_dispatcher_special_char_command_safely_passed_through() {
  # Codex review note: printf '%s' "$INPUT" | bash hook does not evaluate
  # backticks/$()/$VAR inside INPUT. Verify by sending a JSON command field
  # containing those metachars and confirming downstream stub sees stdin as
  # bytes (we just check the dispatcher does not crash and returns 0).
  _seed_dispatcher
  _seed_stub_hook "pre-tool-use-bash-bootstrap-gate.sh" 0
  _seed_stub_hook "pre-bash-safety-guard.sh" 0
  _seed_stub_hook "pre-bash-commit-discipline-gate.sh" 0
  _seed_stub_hook "pre-bash-commit-review-gate.sh" 0
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
# ③-c 신설 계약 cases (a)-(e) — pre-bash-dispatcher.sh Step 3 두-자식 순차
# 호출(discipline → review)의 캡처-릴레이-중단 계약.
run_test test_dispatcher_discipline_rc2_stops_chain_review_and_rules_skipped
run_test test_dispatcher_review_rc2_stops_chain_rules_skipped
run_test test_dispatcher_discipline_json_deny_relays_single_object_and_stops_chain
run_test test_dispatcher_discipline_abnormal_exit_fails_closed
run_test test_dispatcher_review_abnormal_exit_fails_closed
run_test test_dispatcher_cargo_build_invokes_only_bash_rules
run_test test_dispatcher_missing_classifier_runs_conservative_gates
run_test test_dispatcher_missing_safety_guard_fails_closed
run_test test_dispatcher_missing_discipline_gate_fails_closed_on_git_commit
run_test test_dispatcher_missing_review_gate_fails_closed_on_git_commit
run_test test_dispatcher_missing_tc_children_silent_pass_on_safe_command
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
