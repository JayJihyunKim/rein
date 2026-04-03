#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_INIT="$SCRIPT_DIR/scripts/claude-init.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local description="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected to contain: $needle"
    echo "        actual output:       $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local description="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        file not found: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_exists() {
  local description="$1"
  local path="$2"
  if [[ -d "$path" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        directory not found: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_missing() {
  local description="$1"
  local path="$2"
  if [[ ! -e "$path" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected to be absent but found: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local description="$1"
  local expected_code="$2"
  local actual_code="$3"
  if [[ "$expected_code" == "$actual_code" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected exit code: $expected_code"
    echo "        actual exit code:   $actual_code"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test: --help
# ---------------------------------------------------------------------------
echo ""
echo "Test: --help"
help_output="$("$CLAUDE_INIT" --help 2>&1 || true)"
assert_contains "--help output contains 'Usage'" "Usage" "$help_output"

# ---------------------------------------------------------------------------
# Test: --version
# ---------------------------------------------------------------------------
echo ""
echo "Test: --version"
version_output="$("$CLAUDE_INIT" --version 2>&1 || true)"
assert_contains "--version output contains 'claude-init'" "claude-init" "$version_output"

# ---------------------------------------------------------------------------
# Test: new command
# ---------------------------------------------------------------------------
echo ""
echo "Test: new command"
new_dir="$TEST_DIR/new-command-test"
mkdir -p "$new_dir"
# Run inside the temp dir so the project is created there
(
  cd "$new_dir"
  "$CLAUDE_INIT" new test-project > /dev/null 2>&1
)
project_dir="$new_dir/test-project"
assert_file_exists  ".claude/CLAUDE.md exists"                          "$project_dir/.claude/CLAUDE.md"
assert_file_exists  "AGENTS.md exists"                                  "$project_dir/AGENTS.md"
assert_file_exists  ".claude/hooks/pre-edit-dod-gate.sh exists"        "$project_dir/.claude/hooks/pre-edit-dod-gate.sh"
assert_dir_exists   ".claude/skills/ directory exists"                  "$project_dir/.claude/skills"
assert_dir_exists   "SOT/inbox/ directory exists"                       "$project_dir/SOT/inbox"
assert_file_exists  "SOT/inbox/.gitkeep exists"                         "$project_dir/SOT/inbox/.gitkeep"
assert_file_missing ".claude/settings.local.json should not exist"      "$project_dir/.claude/settings.local.json"
assert_file_missing ".claude/plans/ should not exist"                   "$project_dir/.claude/plans"

# ---------------------------------------------------------------------------
# Test: new fails if dir exists
# ---------------------------------------------------------------------------
echo ""
echo "Test: new fails if dir exists"
collision_dir="$TEST_DIR/collision-test"
mkdir -p "$collision_dir"
mkdir -p "$collision_dir/existing-project"
set +e
( cd "$collision_dir" && "$CLAUDE_INIT" new existing-project > /dev/null 2>&1 )
collision_exit=$?
set -e
assert_exit_code "exit code is 1 when target dir already exists" 1 "$collision_exit"

# ---------------------------------------------------------------------------
# Test: merge command
# ---------------------------------------------------------------------------
echo ""
echo "Test: merge command"
merge_dir="$TEST_DIR/merge-test"
mkdir -p "$merge_dir"
(
  cd "$merge_dir"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  "$CLAUDE_INIT" merge > /dev/null 2>&1
)
assert_file_exists ".claude/CLAUDE.md exists after merge"               "$merge_dir/.claude/CLAUDE.md"
assert_file_exists ".claude/hooks/pre-edit-dod-gate.sh exists"         "$merge_dir/.claude/hooks/pre-edit-dod-gate.sh"
assert_dir_exists  "SOT/inbox/ directory exists after merge"            "$merge_dir/SOT/inbox"

# ---------------------------------------------------------------------------
# Test: merge fails outside git repo
# ---------------------------------------------------------------------------
echo ""
echo "Test: merge fails outside git repo"
no_git_dir="$TEST_DIR/no-git-test"
mkdir -p "$no_git_dir"
set +e
( cd "$no_git_dir" && "$CLAUDE_INIT" merge > /dev/null 2>&1 )
merge_exit=$?
set -e
assert_exit_code "merge exits with code 1 outside a git repo" 1 "$merge_exit"

# ---------------------------------------------------------------------------
# Test: update is alias for merge
# ---------------------------------------------------------------------------
echo ""
echo "Test: update is alias for merge"
update_dir="$TEST_DIR/update-test"
mkdir -p "$update_dir"
(
  cd "$update_dir"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  "$CLAUDE_INIT" update > /dev/null 2>&1
)
assert_file_exists ".claude/CLAUDE.md exists after update" "$update_dir/.claude/CLAUDE.md"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
