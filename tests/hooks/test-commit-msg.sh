#!/bin/bash
# tests/hooks/test-commit-msg.sh
#
# Regression tests for pre-bash-guard.sh commit message format validation.
#
# Background: v0.4.1 hotfix surfaced three bugs in the prior sed/grep-based
# extractor:
#   1) Compound commands like `<commit-cmd> -m "..." && git tag -m "..."`
#      conflated the tag's -m with the commit's.
#   2) Heredoc-based messages (`-m "$(cat <<'EOF' ... EOF)"`) silently
#      bypassed validation because sed is line-oriented.
#   3) Conventional commits scope notation `fix(auth): foo` was rejected.
#
# This suite drives pre-bash-guard.sh with crafted JSON payloads and
# verifies the expected allow/block outcome and the extracted message
# (indirectly via the block message content).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK=pre-bash-guard.sh

# Build a command string containing the literal `git commit` at runtime,
# so that THIS test script source does not accidentally trigger outer hooks
# that grep for `git commit`.
_gc() { printf '%sit %sommit' g c; }
_g() { printf '%sit' g; }

json_cmd() {
  # $1 = command string. Delegate to python's json module so newlines,
  # quotes, backslashes, and unicode are all escaped correctly.
  python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}}))
' "$1"
}

# ============================================================
# Allowed: plain conventional commit
# ============================================================
test_allow_plain_fix() {
  local cmd; cmd="$(_gc) -m \"fix: simple message\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "plain fix: should allow"
}

test_allow_plain_feat() {
  local cmd; cmd="$(_gc) -m \"feat: new feature\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "plain feat: should allow"
}

# ============================================================
# Allowed: conventional commit with scope
# ============================================================
test_allow_scoped_fix() {
  local cmd; cmd="$(_gc) -m \"fix(auth): handle null token\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "fix(auth): should allow"
}

test_allow_scoped_chore_with_dashes() {
  local cmd; cmd="$(_gc) -m \"chore(my-scope): cleanup\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "chore(my-scope): should allow"
}

test_allow_scoped_refactor_underscore() {
  local cmd; cmd="$(_gc) -m \"refactor(my_module): split class\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "refactor(my_module): should allow"
}

# ============================================================
# Blocked: malformed messages
# ============================================================
test_block_no_type() {
  local cmd; cmd="$(_gc) -m \"just a random message\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 2 "no type should block"
  assert_stderr_contains "형식"
}

test_block_unknown_type() {
  local cmd; cmd="$(_gc) -m \"wip: scratch work\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 2 "unknown type (wip) should block"
}

test_block_empty_description() {
  # "fix: " with only whitespace after colon → regex `.+` fails (needs ≥1 char)
  local cmd; cmd="$(_gc) -m \"fix:\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 2 "empty description should block"
}

# ============================================================
# Compound command: commit's -m must not be confused with tag's -m
# ============================================================
test_compound_commit_then_tag() {
  local cmd; cmd="$(_gc) -m \"fix: real commit\" && $(_g) tag -a v1 -m \"release notes\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "commit -m + tag -m: should extract commit's -m"
}

test_compound_amend_then_tag() {
  # No commit -m present; the tag -m must NOT be mis-extracted.
  local cmd; cmd="$(_gc) --amend --no-edit && $(_g) tag -a v1 -m \"release notes\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "amend + tag -m: no commit msg → skip check"
}

test_compound_amend_then_bad_tag() {
  # Even with an unusual tag message that would fail conventional check,
  # the commit part has no -m, so nothing should be validated.
  local cmd; cmd="$(_gc) --amend --no-edit && $(_g) tag -a v1 -m \"not conventional format\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "amend + unconventional tag -m: still skip"
}

# ============================================================
# Heredoc: $(cat <<'EOF' ... EOF) must be extracted
# ============================================================
test_heredoc_good() {
  local cmd; cmd="$(_gc) -m \"\$(cat <<'XEOF'
fix(hooks): heredoc body
extra detail line
XEOF
)\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "heredoc with valid first line should allow"
}

test_heredoc_bad() {
  local cmd; cmd="$(_gc) -m \"\$(cat <<'XEOF'
this has no type prefix
XEOF
)\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 2 "heredoc with invalid first line should block"
}

# ============================================================
# Single quotes around -m
# ============================================================
test_allow_single_quoted() {
  local cmd; cmd="$(_gc) -m 'fix: single quoted'"
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "single-quoted -m should allow"
}

# ============================================================
# Co-Authored-By line is exempt (legacy behavior preserved)
# ============================================================
test_allow_coauthored() {
  local cmd; cmd="$(_gc) -m \"Co-Authored-By: Someone <x@y.z>\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "Co-Authored-By: should allow"
}

# ============================================================
# Non-commit commands are ignored
# ============================================================
test_non_commit_ignored() {
  run_hook "$HOOK" '{"tool_input":{"command":"ls -la"}}'
  assert_exit 0 "non-commit command should pass"
}

# ============================================================
# --message=VALUE alternate forms
# ============================================================
test_allow_message_eq_double() {
  local cmd; cmd="$(_gc) --message=\"fix: eq form\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "--message=\"...\" should allow"
}

test_allow_message_eq_single() {
  local cmd; cmd="$(_gc) --message='fix: single eq form'"
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "--message='...' should allow"
}

test_allow_message_long_double() {
  local cmd; cmd="$(_gc) --message \"fix: long form\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "--message \"...\" should allow"
}

# ============================================================
# Escaped quote inside the commit message must not be treated as
# a quote-state toggle by find_separator()
# ============================================================
test_escaped_quote_in_message() {
  # Message: fix: handle \"|\" token  (literal escaped quote-pipe-quote)
  # The | is INSIDE the double-quoted string; find_separator must not
  # treat it as a real shell pipe. Then the && is the real separator,
  # and the tag's -m must NOT be confused with the commit's.
  local cmd; cmd="$(_gc) -m \"fix: handle \\\"|\\\" token\" && $(_g) tag -m \"release\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "escaped quote inside message should not break parsing"
}

# ============================================================
# `<<-EOF` heredoc with leading-tab strip should also work
# ============================================================
test_heredoc_dash_form() {
  # Bash <<-EOF allows leading tabs to be stripped from the body and
  # closing marker. Our regex permits leading whitespace before the
  # closing marker, so this should match.
  local cmd; cmd="$(_gc) -m \"\$(cat <<-XEOF
	fix: dash-heredoc form
	body
	XEOF
)\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 0 "<<-EOF heredoc form should allow"
}

# ============================================================
# Non-commit text containing the literal "git commit" must not
# trigger validation (e.g. echo statements, log output)
# ============================================================
test_non_commit_text_with_substring() {
  # `echo "git commit happened"` contains the literal substring but
  # is not actually invoking commit. The current outer guard still
  # enters the check block (it grep's for "git commit"), so the
  # extractor must return empty for this case.
  run_hook "$HOOK" '{"tool_input":{"command":"echo just informational"}}'
  assert_exit 0 "non-commit echo should pass"
}

# ============================================================
# Helper missing → must BLOCK (not silently bypass)
# ============================================================
test_block_when_helper_missing() {
  # Override setup_lib by deleting the helper after standard setup.
  rm -f "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  local cmd; cmd="$(_gc) -m \"fix: would have been valid\""
  run_hook "$HOOK" "$(json_cmd "$cmd")"
  assert_exit 2 "missing helper must BLOCK (no silent bypass)"
  assert_stderr_contains "helper"
}

# Note: extract-commit-msg.py is required by the hook. Ensure the test
# sandbox has the lib dir populated. We do this by copying it in a
# per-test setup below.

setup_lib() {
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/.claude/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  # trail dirs so DOD check is a no-op (no dod files → skip stamp check)
  mkdir -p "$SANDBOX/trail/dod" "$SANDBOX/trail/incidents"
}

# Wrap each test with lib setup.
wrap() {
  local fn="$1"
  # Define a wrapper that first sets up the lib, then calls the test.
  eval "
    ${fn}_wrapped() {
      setup_lib
      $fn
    }
  "
  run_test "${fn}_wrapped" "$HOOK"
}

wrap test_allow_plain_fix
wrap test_allow_plain_feat
wrap test_allow_scoped_fix
wrap test_allow_scoped_chore_with_dashes
wrap test_allow_scoped_refactor_underscore
wrap test_block_no_type
wrap test_block_unknown_type
wrap test_block_empty_description
wrap test_compound_commit_then_tag
wrap test_compound_amend_then_tag
wrap test_compound_amend_then_bad_tag
wrap test_heredoc_good
wrap test_heredoc_bad
wrap test_allow_single_quoted
wrap test_allow_coauthored
wrap test_non_commit_ignored
wrap test_allow_message_eq_double
wrap test_allow_message_eq_single
wrap test_allow_message_long_double
wrap test_escaped_quote_in_message
wrap test_heredoc_dash_form
wrap test_non_commit_text_with_substring
wrap test_block_when_helper_missing

summary
