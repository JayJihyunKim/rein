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

# ------------------------------------------------------------
# [P10] regex over-match fix (BUG-P10-REGEX, 2026-05-29).
#
# Root cause: the original `git commit.*-[a-z]*a[a-z]*m` regex
#   (1) matched `--amend` (second dash → `-am` inside `--amend`), and
#   (2) used raw `echo "$COMMAND" | grep` so an echo/grep that merely
#       MENTIONS `git commit -am` as text was treated as an invocation.
# Fix: switch to command_invokes (clause-anchored, text-mention exempt),
# anchor the combined-flag token to a single dash + token terminator
# (exempts `--amend`), and add split/order variants (`-a -m`, `-m -a`,
# `--all -m`, `-m --all`).
#
# NOTE on the .env precondition: P10 is a TWO-stage gate — the command
# must look like `git commit` with auto-add semantics AND a .env file
# must exist in the repo root. These tests seed `.env` so the SECOND
# gate is open; that isolates the FIRST gate (the regex) as the variable
# under test. A separate test confirms that with NO .env present nothing
# fires regardless of command shape.
# ------------------------------------------------------------

# --- Exempt cases: must PASS even with .env present (regex must not match). ---

test_p10_amend_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit --amend"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git commit --amend with .env present must NOT block"
}

test_p10_amend_no_edit_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit --amend --no-edit"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git commit --amend --no-edit with .env present must NOT block"
}

test_p10_echo_text_mention_not_blocked() {
  # echo that merely mentions the flag as text — not an invocation.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"echo \"git commit -am\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 echo text-mention of git commit -am must NOT block"
}

test_p10_grep_text_mention_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"grep \"git commit -am\" file"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 grep text-mention of git commit -am must NOT block"
}

test_p10_plain_message_commit_not_blocked() {
  # A normal `-m` commit (no auto-add) must pass even with .env present.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 plain git commit -m with .env present must NOT block"
}

# --- Block cases: must still BLOCK with .env present (auto-add variants). ---

test_p10_split_a_m_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -a -m \"x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -a -m must block"
}

test_p10_split_m_a_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -m \"x\" -a"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -m ... -a must block"
}

test_p10_long_all_m_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit --all -m \"x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit --all -m must block"
}

test_p10_long_m_all_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -m \"x\" --all"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -m ... --all must block"
}

test_p10_combined_ma_order_blocks() {
  # `-ma` is the same combined flag with the message/all letters swapped.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -ma \"x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -ma must block"
}

# --- BUG-P10-ATTACHED-QUOTE (security review MEDIUM, 2026-05-29) ---
# Regression introduced by SIMPLIFY: arm1's alpha-run terminator was only
# `([[:space:]]|$)`, so a quoted message attached with no space to the
# combined bundle (`-am"msg"`, `-am'msg'`, `-ma"msg"`) broke the match at the
# quote char and slipped past — even though the ORIGINAL simple regex
# (`git commit.*-[a-z]*a[a-z]*m`) blocked these. `-am"msg"` is the most common
# inline-message auto-add finger-habit, dead center of P10's threat surface.
# Fix: add the quote chars (" ') as accepted alpha-run terminators so the
# attached-message bundle is recognized. NOT one of the documented non-goals.

test_p10_combined_am_attached_dquote_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -am\"msg\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -am\"msg\" (attached dquote) must block"
}

test_p10_combined_am_attached_squote_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -am'"'"'msg'"'"'"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -am'msg' (attached squote) must block"
}

test_p10_combined_ma_attached_dquote_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -ma\"msg\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -ma\"msg\" (attached dquote) must block"
}

test_p10_combined_am_attached_quote_inner_a_blocks() {
  # The combined bundle itself triggers the block; an inner `-a` inside the
  # quoted message is irrelevant (the bundle alone is sufficient).
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -am\"msg with -a\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -am\"msg with -a\" must block"
}

test_p10_attached_dquote_message_only_not_blocked() {
  # Attached-quote message with NO `a` letter — arm1 needs both a+m in the
  # alpha-run, so `-m"msg"` must NOT match arm1 and must PASS (a plain message).
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -m\"msg\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git commit -m\"msg\" (message only, no -a) must NOT block"
}

# --- BUG-P10-GLOBAL-OPTS (integrated codex review, High, 2026-05-29) ---
# The three P10 regexes required `git commit` to be adjacent. A git global
# option wedged between `git` and `commit` (`-C`, `-c`, `--git-dir`,
# `--work-tree`) slipped past the gate even with a .env present. The fix adds a
# prefix that absorbs zero-or-more global options between `git` and `commit`.
# (`env GIT_DIR=... git commit -am` was already caught by command_invokes's
# VAR= prefix; these are the git-native option forms.)

test_p10_global_opt_C_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C . commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git -C . commit -am must block"
}

test_p10_global_opt_c_config_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -c user.name=x commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git -c user.name=x commit -am must block"
}

test_p10_global_opt_gitdir_worktree_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git --git-dir=.git --work-tree=. commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git --git-dir --work-tree commit -am must block"
}

test_p10_sudo_global_opt_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"sudo git -C . commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 sudo git -C . commit -am must block"
}

test_p10_multiple_global_opts_blocks() {
  # Two consecutive global options must still be absorbed by the ( ... )* group.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C . -c x.y=z commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git -C . -c x.y=z commit -am must block"
}

test_p10_global_opt_amend_not_blocked() {
  # Global options must not turn an --amend (no auto-add) into a block.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C . commit --amend"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git -C . commit --amend must NOT block"
}

# --- BUG-P10-GLOBAL-OPTS R2: false-positive guards ---
# `git config commit.gpgsign true` (commit as arg value) and
# `git -C . log commit` (commit as a pathspec/arg, no auto-add flag after)
# must PASS.
# NOTE (SIMPLIFY 2026-05-29): the former R2/R4 BLOCK cases for global options
# whose VALUE contains a quoted/escaped space (`-c "user.name=J K"`,
# `-c user.name=J\ Kim`, `-C "/my path"`, inner/single-quote variants) were
# REMOVED. They are an accepted non-goal: P10 is a mistake-prevention guard,
# not a barrier against deliberate quote-nesting evasion. The simplified bare
# value matcher (`[^;&|[:space:]]+`) intentionally stops at the space and does
# not block these.

test_p10_config_commit_dot_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git config commit.gpgsign true"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git config commit.gpgsign must NOT block"
}

test_p10_global_opt_log_commit_arg_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C . log commit"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git -C . log commit (commit as arg, no auto-add) must NOT block"
}

# codex R3 finding: the broadened tail used in an earlier draft made
# `git -C . log commit -am` match (subcommand is `log`, `commit` is an arg,
# but a later `-am` token completed the auto-add pattern) — a NEW false
# positive. The proper `( global-opt )*` group (which only consumes options
# and their values, never an unescaped subcommand token) must let this PASS.
test_p10_global_opt_log_commit_am_arg_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C . log commit -am"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git -C . log commit -am (subcommand is log, not commit) must NOT block"
}

test_p10_global_opt_show_commit_am_arg_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C . show commit -am"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git -C . show commit -am (subcommand is show) must NOT block"
}

# Single-quoted global-opt value WITHOUT a space must not let the ( opt )* group
# swallow a following `log` subcommand. (R4 false-positive guard, retained — the
# simplified bare value matcher absorbs `'/tmp'` since it contains no space.)
test_p10_single_quote_log_commit_am_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -C '"'"'/tmp'"'"' log commit -am"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git -C '/tmp' log commit -am (subcommand log) must NOT block"
}

# --- SIMPLIFY 2026-05-29: attached-value message forms (-mfoo, --message=foo) ---
# The simplified MSG alternative recognizes a message flag with an ATTACHED
# value. Combined with -a/--all (auto-add), these must BLOCK. A standalone
# attached-value message (no -a) is just a message — it must PASS (same as
# `git commit -m x`).

test_p10_split_a_attached_mfoo_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -a -mfoo"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -a -mfoo (attached msg) must block"
}

test_p10_attached_message_eq_then_all_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit --message=foo -a"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit --message=foo -a must block"
}

test_p10_standalone_attached_mfoo_not_blocked() {
  # Attached-value message with NO -a is a plain message commit — must PASS.
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -mfoo"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git commit -mfoo (message only, no -a) must NOT block"
}

# Accepted-limit guard (codex SIMPLIFY review, 2026-05-29 — non-goal #2):
# command_invokes is NOT quote-aware, so a quoted message that contains a
# standalone `-a` token (`git commit -m "use -a flag"`) is over-blocked: arm3
# scans into the message and treats the message's ` -a ` as the ALL token. This
# is a NEW false positive vs the original `git commit.*-[a-z]*a[a-z]*m` (which
# needed an `m` after the `-a`), but it is an ACCEPTED non-goal: for a
# mistake-prevention guard, a conservative over-block is tolerable and the user
# can fall back to `git add` + a separate `-m`. This test pins the documented
# behavior so a future change does not silently flip it.
test_p10_quoted_message_with_a_flag_over_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git commit -m \"use -a flag\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git commit -m \"use -a flag\" (quoted -a) over-blocks (accepted non-goal #2)"
}

# --- BUG-P10-GLOBAL-OPTS R5 (codex review High, value-LESS global options) ---
# Enumerating only the value-taking opts (-C/-c/--git-dir/--work-tree) missed
# value-less git global flags that also precede `commit`: --no-pager,
# --paginate, --bare, --literal-pathspecs, --no-optional-locks, -p,
# --config-env=X. The grammar model now accepts any dash-led self-contained
# flag in the option region, so these block; but a value-less flag must NOT
# consume a following bare token (only the 4 value-taking opts may), so a
# subcommand after a value-less flag still keeps `commit` out of reach.

test_p10_no_pager_commit_am_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git --no-pager commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git --no-pager commit -am must block"
}

test_p10_short_p_commit_am_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git -p commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git -p commit -am must block"
}

test_p10_config_env_commit_am_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git --config-env=X commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git --config-env=X commit -am must block"
}

test_p10_value_less_then_value_taking_opt_blocks() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git --no-pager -C . commit -am x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "P10 git --no-pager -C . commit -am must block"
}

# R5 false-positive guard: a value-less global flag must not absorb a following
# subcommand token — `git --no-pager log commit -am` (subcommand is log).
test_p10_no_pager_log_commit_am_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git --no-pager log commit -am"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git --no-pager log commit -am (subcommand log) must NOT block"
}

# A value-less global flag before a normal (non-auto-add) commit must PASS.
test_p10_no_pager_plain_commit_not_blocked() {
  touch "$SANDBOX/.env"
  local input='{"tool_input":{"command":"git --no-pager commit -m \"x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git --no-pager commit -m (no auto-add) must NOT block"
}

# --- Precondition: with NO .env present, nothing fires regardless of shape. ---

test_p10_no_env_present_commit_am_passes() {
  # No .env seeded → second gate closed → even a real -am must pass.
  local input='{"tool_input":{"command":"git commit -am \"x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "P10 git commit -am with NO .env present must pass"
}

# ============================================================
# GMF-4 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4): policy-toggle
# fail-open seal. Same fix as the test/commit gate — the old top block
# hard-coded `python3` and `if ! python3 <loader>; then exit 0`, so an absent
# interpreter (127) or Windows stub (49) silently turned the always-on safety
# guard OFF. The fix moves the policy check after bg_resolve_python_or_die and
# calls the loader via "${PYTHON_RUNNER[@]}", distinguishing loader rc==1
# (user disable → exit 0) from rc∉{0,1} / absence (fail-closed → gate active).
# Gate-active here is proven via P10 (.env present + git commit -am).
# ============================================================

_seed_policy_loader() {
  local rc="$1"
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<PY
import sys
sys.exit($rc)
PY
}

_run_hook_missing_python() {
  local stdin_json="$1"
  local out
  out=$(
    with_missing_python
    printf '%s' "$stdin_json" \
      | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
        REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$HOOK" 2>&1
    printf '_RC=%s\n' "$?"
    cleanup_fakes
  )
  HOOK_EXIT=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)
  HOOK_STDERR=$(printf '%s' "$out" | grep -v '^_RC=' || true)
}

_run_hook_real_python() {
  local stdin_json="$1"
  local tmp_out tmp_err
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  printf '%s' "$stdin_json" \
    | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/$HOOK" >"$tmp_out" 2>"$tmp_err"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_out")
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"
}

# RED → GREEN: python3 absent must not disable the always-on safety guard.
test_gmf4_python_absent_does_not_disable_gate() {
  touch "$SANDBOX/.env"
  _seed_policy_loader 0
  _run_hook_missing_python '{"tool_input":{"command":"git commit -am \"feat: x\""}}'
  [ "$HOOK_EXIT" != "0" ] \
    || fail "GMF-4 python absent must NOT disable the safety guard (got exit 0 = fail-open)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 python absent should fail closed via resolver (expected exit 2, got: $HOOK_EXIT)"
}

# GREEN: python present + policy DISABLE (loader rc 1) → guard OFF (exit 0),
# even with .env + git commit -am that would otherwise P10-block.
test_gmf4_policy_disable_exits_zero() {
  touch "$SANDBOX/.env"
  _seed_policy_loader 1
  _run_hook_real_python '{"tool_input":{"command":"git commit -am \"feat: x\""}}'
  [ "$HOOK_EXIT" = "0" ] \
    || fail "GMF-4 policy disable (loader rc1) should exit 0 (got: $HOOK_EXIT; stderr: $HOOK_STDERR)"
  [ -z "$HOOK_STDOUT" ] \
    || fail "GMF-4 policy disable should emit no JSON deny (stdout: $HOOK_STDOUT)"
}

# GREEN: python present + policy ENABLE (loader rc 0) → guard body runs and
# P10-blocks the .env auto-add commit (proves the guard entered).
test_gmf4_policy_enable_enters_body() {
  touch "$SANDBOX/.env"
  _seed_policy_loader 0
  _run_hook_real_python '{"tool_input":{"command":"git commit -am \"feat: x\""}}'
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "GMF-4 policy enable should enter the guard body (P10)"
}

# GREEN: loader CRASH (rc 3) with python present → fail-closed, guard active.
test_gmf4_loader_crash_fails_closed() {
  touch "$SANDBOX/.env"
  _seed_policy_loader 3
  _run_hook_real_python '{"tool_input":{"command":"git commit -am \"feat: x\""}}'
  assert_json_deny "ENV_COMMIT_AM_BLOCKED" "GMF-4 loader crash should fall through to the guard body (P10)"
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
  # P10 regex over-match fix (BUG-P10-REGEX, 2026-05-29)
  run_test test_p10_amend_not_blocked                     "$HOOK"
  run_test test_p10_amend_no_edit_not_blocked             "$HOOK"
  run_test test_p10_echo_text_mention_not_blocked         "$HOOK"
  run_test test_p10_grep_text_mention_not_blocked         "$HOOK"
  run_test test_p10_plain_message_commit_not_blocked      "$HOOK"
  run_test test_p10_split_a_m_blocks                      "$HOOK"
  run_test test_p10_split_m_a_blocks                      "$HOOK"
  run_test test_p10_long_all_m_blocks                     "$HOOK"
  run_test test_p10_long_m_all_blocks                     "$HOOK"
  run_test test_p10_combined_ma_order_blocks              "$HOOK"
  run_test test_p10_combined_am_attached_dquote_blocks    "$HOOK"
  run_test test_p10_combined_am_attached_squote_blocks    "$HOOK"
  run_test test_p10_combined_ma_attached_dquote_blocks    "$HOOK"
  run_test test_p10_combined_am_attached_quote_inner_a_blocks "$HOOK"
  run_test test_p10_attached_dquote_message_only_not_blocked  "$HOOK"
  run_test test_p10_global_opt_C_blocks                   "$HOOK"
  run_test test_p10_global_opt_c_config_blocks            "$HOOK"
  run_test test_p10_global_opt_gitdir_worktree_blocks     "$HOOK"
  run_test test_p10_sudo_global_opt_blocks                "$HOOK"
  run_test test_p10_multiple_global_opts_blocks           "$HOOK"
  run_test test_p10_global_opt_amend_not_blocked          "$HOOK"
  run_test test_p10_config_commit_dot_not_blocked         "$HOOK"
  run_test test_p10_global_opt_log_commit_arg_not_blocked "$HOOK"
  run_test test_p10_global_opt_log_commit_am_arg_not_blocked "$HOOK"
  run_test test_p10_global_opt_show_commit_am_arg_not_blocked "$HOOK"
  run_test test_p10_single_quote_log_commit_am_not_blocked "$HOOK"
  # SIMPLIFY 2026-05-29: attached-value message forms
  run_test test_p10_split_a_attached_mfoo_blocks          "$HOOK"
  run_test test_p10_attached_message_eq_then_all_blocks    "$HOOK"
  run_test test_p10_standalone_attached_mfoo_not_blocked  "$HOOK"
  run_test test_p10_quoted_message_with_a_flag_over_blocks "$HOOK"
  run_test test_p10_no_pager_commit_am_blocks             "$HOOK"
  run_test test_p10_short_p_commit_am_blocks              "$HOOK"
  run_test test_p10_config_env_commit_am_blocks           "$HOOK"
  run_test test_p10_value_less_then_value_taking_opt_blocks "$HOOK"
  run_test test_p10_no_pager_log_commit_am_not_blocked    "$HOOK"
  run_test test_p10_no_pager_plain_commit_not_blocked     "$HOOK"
  run_test test_p10_no_env_present_commit_am_passes       "$HOOK"
  run_test test_p11_destructive_git_blocks                "$HOOK"
  run_test test_plain_ls_passes                           "$HOOK"
  # GMF-4 policy-toggle fail-open seal
  run_test test_gmf4_python_absent_does_not_disable_gate  "$HOOK"
  run_test test_gmf4_policy_disable_exits_zero            "$HOOK"
  run_test test_gmf4_policy_enable_enters_body            "$HOOK"
  run_test test_gmf4_loader_crash_fails_closed            "$HOOK"
  # Allocation boundary — safety guard must NOT enforce the test/commit gate
  run_test test_safety_guard_does_not_enforce_commit_gate "$HOOK"
  # Common infra (I1·I2·I6)
  run_test test_i1_python_resolver_failure_fails_closed   "$HOOK"
  run_test test_i2_json_parse_failure_fails_closed        "$HOOK"
  run_test test_i6_emitter_unavailable_fails_closed       "$HOOK"
  summary
}

main
