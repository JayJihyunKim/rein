#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/pre-bash-guard.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_exit_code() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected exit code: $expected"
    echo "        actual exit code:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Setup: fake project structure
setup_project() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks"
  mkdir -p "$dir/SOT/dod"
  mkdir -p "$dir/SOT/incidents"
  cp "$HOOK" "$dir/.claude/hooks/pre-bash-guard.sh"
  chmod +x "$dir/.claude/hooks/pre-bash-guard.sh"
}

# Run hook with a given command, from a given project dir
run_hook() {
  local project_dir="$1"
  local command="$2"
  local input
  input=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'$command'}}))")
  echo "$input" | (cd "$project_dir" && bash ".claude/hooks/pre-bash-guard.sh") 2>/dev/null
}

# ---------------------------------------------------------------------------
# Test: pytest blocked when DoD exists but no security stamp
# ---------------------------------------------------------------------------
echo ""
echo "Test: pytest blocked without security-reviewed stamp"
proj1="$TEST_DIR/proj1"
setup_project "$proj1"
touch "$proj1/SOT/dod/dod-test-task.md"
touch "$proj1/SOT/dod/.codex-reviewed"
# NO .security-reviewed stamp

set +e
run_hook "$proj1" "pytest tests/ -v"
exit1=$?
set -e
assert_exit_code "pytest blocked without security stamp" 2 "$exit1"

# ---------------------------------------------------------------------------
# Test: pytest allowed when both stamps exist
# ---------------------------------------------------------------------------
echo ""
echo "Test: pytest allowed with both stamps"
proj2="$TEST_DIR/proj2"
setup_project "$proj2"
touch "$proj2/SOT/dod/dod-test-task.md"
touch "$proj2/SOT/dod/.codex-reviewed"
touch "$proj2/SOT/dod/.security-reviewed"

set +e
run_hook "$proj2" "pytest tests/ -v"
exit2=$?
set -e
assert_exit_code "pytest allowed with both stamps" 0 "$exit2"

# ---------------------------------------------------------------------------
# Test: git commit blocked without security stamp
# ---------------------------------------------------------------------------
echo ""
echo "Test: git commit blocked without security stamp"
proj3="$TEST_DIR/proj3"
setup_project "$proj3"
touch "$proj3/SOT/dod/dod-test-task.md"
touch "$proj3/SOT/dod/.codex-reviewed"
# NO .security-reviewed stamp

set +e
run_hook "$proj3" "git commit -m feat-test-commit"
exit3=$?
set -e
assert_exit_code "git commit blocked without security stamp" 2 "$exit3"

# ---------------------------------------------------------------------------
# Test: no DoD = no stamp check (bypass)
# ---------------------------------------------------------------------------
echo ""
echo "Test: no DoD file = stamps not checked"
proj4="$TEST_DIR/proj4"
setup_project "$proj4"
# NO DoD file, NO stamps

set +e
run_hook "$proj4" "pytest tests/ -v"
exit4=$?
set -e
assert_exit_code "pytest allowed when no DoD exists" 0 "$exit4"

# ---------------------------------------------------------------------------
# Test: expired security stamp blocked
# ---------------------------------------------------------------------------
echo ""
echo "Test: expired security stamp blocked"
proj5="$TEST_DIR/proj5"
setup_project "$proj5"
touch "$proj5/SOT/dod/dod-test-task.md"
touch "$proj5/SOT/dod/.codex-reviewed"
touch "$proj5/SOT/dod/.security-reviewed"
# Make stamp 2 hours old (7200 seconds)
touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$proj5/SOT/dod/.security-reviewed"

set +e
run_hook "$proj5" "pytest tests/ -v"
exit5=$?
set -e
assert_exit_code "pytest blocked with expired security stamp" 2 "$exit5"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
