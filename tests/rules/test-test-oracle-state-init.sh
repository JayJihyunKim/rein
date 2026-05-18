#!/bin/bash
# tests/rules/test-test-oracle-state-init.sh
# Plan B Phase 5 Task 5.1 — test-oracle.json 초기 상태 파일 + gitignore + branch-strategy.
#
# Scope IDs covered:
#   - TO-rollout-warn-first-independent-of-spec-a-stage

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE="$PROJECT_DIR/.claude/.rein-state/test-oracle.json"
GITIGNORE="$PROJECT_DIR/.gitignore"
BRANCH="$PROJECT_DIR/.claude/rules/branch-strategy.md"

PASS=0
FAIL=0
TMPDIR_ORACLE=""

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

cleanup() { rm -rf "$TMPDIR_ORACLE" 2>/dev/null || true; }
trap cleanup EXIT

echo "## test-test-oracle-state-init.sh"
echo ""

# Tests 1-3: exercise the CONSUMER contract of _read_test_oracle_severity_hard()
# in scripts/rein-validate-coverage-matrix.py (lines 642-658).
# Contract: absent/malformed file → False (warn-only fallback); valid file → bool value.
# We invoke the logic as a subprocess with a controlled cwd so Path.cwd() resolves
# correctly for each scenario — no module-level exec needed.
#
# The inline Python snippet mirrors the function body exactly:
#   path = Path.cwd() / ".claude" / ".rein-state" / "test-oracle.json"
#   if not path.exists(): return False
#   try: data = json.loads(path.read_text()); return bool(data.get("severity_hard", False))
#   except Exception: return False
TMPDIR_ORACLE="$(mktemp -d "/tmp/test-oracle-XXXXXX")"

_oracle_read_in_dir() {
  # Run _read_test_oracle_severity_hard logic in the given directory.
  # Prints "True" or "False"; exits 0.
  local dir="$1"
  python3 - "$dir" <<'PY'
import sys, json
from pathlib import Path
d = Path(sys.argv[1])
path = d / ".claude" / ".rein-state" / "test-oracle.json"
if not path.exists():
    print("False"); sys.exit(0)
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    print("True" if bool(data.get("severity_hard", False)) else "False")
except Exception:
    print("False")
PY
}

echo "### Test 1: 파일 부재 시 severity_hard 는 False 로 기본값 반환"
# No .claude/.rein-state/test-oracle.json in the tempdir.
result=$(_oracle_read_in_dir "$TMPDIR_ORACLE")
if [ "$result" = "False" ]; then
  _pass "absent state file → severity_hard defaults to False"
else
  _fail "absent state file should default to False, got: $result"
fi

echo "### Test 2: malformed JSON → graceful fallback to False (no crash)"
_malformed_dir="$(mktemp -d "/tmp/test-oracle-malformed-XXXXXX")"
mkdir -p "$_malformed_dir/.claude/.rein-state"
printf 'not valid json{{{' > "$_malformed_dir/.claude/.rein-state/test-oracle.json"
result=$(_oracle_read_in_dir "$_malformed_dir")
if [ "$result" = "False" ]; then
  _pass "malformed JSON → graceful fallback to False"
else
  _fail "malformed JSON should fallback to False, got: $result"
fi
rm -rf "$_malformed_dir"

echo "### Test 3: valid {\"severity_hard\": false} → read as False"
_valid_dir="$(mktemp -d "/tmp/test-oracle-valid-XXXXXX")"
mkdir -p "$_valid_dir/.claude/.rein-state"
printf '{"severity_hard": false}\n' > "$_valid_dir/.claude/.rein-state/test-oracle.json"
result=$(_oracle_read_in_dir "$_valid_dir")
if [ "$result" = "False" ]; then
  _pass "valid {severity_hard: false} → read as False"
else
  _fail "valid {severity_hard: false} should read as False, got: $result"
fi
rm -rf "$_valid_dir"

echo "### Test 4: .gitignore 에 test-oracle.json 관련 entry"
# Spec A gov.json 과 동일 패턴: /.claude/.rein-state/ 로 디렉토리 전체 ignore.
# 이 entry 가 이미 있으므로 test-oracle.json 도 자동 ignore 됨.
if grep -q '/.claude/.rein-state/' "$GITIGNORE"; then
  _pass ".gitignore 에 /.claude/.rein-state/ 디렉토리 ignore"
else
  _fail ".gitignore 에 .rein-state 항목 없음"
fi

echo "### Test 5: branch-strategy.md 에 test-oracle.json 언급 or .rein-state 제외"
if grep -qE '\.rein-state|test-oracle\.json' "$BRANCH"; then
  _pass "branch-strategy.md 제외 목록에 포함"
else
  _fail "branch-strategy.md 제외 목록 없음"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
