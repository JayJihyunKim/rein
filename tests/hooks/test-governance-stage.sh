#!/bin/bash
# tests/hooks/test-governance-stage.sh
# Unit tests for .claude/hooks/lib/governance-stage.sh (Plan A Phase 7a Task 7.2/7.3).
#
# Scope IDs covered:
#   - GI-governance-stage-config
#
# Scenarios:
#   1. No config file → "1"
#   2. {"stage": 1} → "1"
#   3. {"stage": 2} → "2"
#   4. {"stage": 3} → "3"
#   5. {"stage": 99} → "INVALID"
#   6. malformed JSON → "INVALID"
#   7. {} (no stage key) → "INVALID"

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_DIR/.claude/hooks/lib/governance-stage.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-governance-stage.sh"
echo ""

if [ ! -f "$LIB" ]; then
  _fail "governance-stage lib not found: $LIB"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Helper that sources the lib inside a given project dir and calls
# read_governance_stage. It prints the result to stdout.
_call_stage() {
  local projdir="$1"
  (
    cd "$projdir"
    # The lib uses relative path '.claude/.rein-state/governance.json'
    # so cwd matters. Source the lib and call the function.
    # shellcheck disable=SC1090
    . "$LIB"
    read_governance_stage
  )
}

# Test 1: no config file → "1"
echo "### Test 1: 파일없음_stage1"
SANDBOX=$(mktemp -d)
got=$(_call_stage "$SANDBOX")
if [ "$got" = "1" ]; then
  _pass "no file → $got"
else
  _fail "no file → expected 1, got $got"
fi
rm -rf "$SANDBOX"

# Test 2: stage 1
echo "### Test 2: stage1_명시"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{"stage": 1}' > "$SANDBOX/.claude/.rein-state/governance.json"
got=$(_call_stage "$SANDBOX")
if [ "$got" = "1" ]; then
  _pass "stage:1 → $got"
else
  _fail "stage:1 → expected 1, got $got"
fi
rm -rf "$SANDBOX"

# Test 3: stage 2
echo "### Test 3: stage2_명시"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{"stage": 2}' > "$SANDBOX/.claude/.rein-state/governance.json"
got=$(_call_stage "$SANDBOX")
if [ "$got" = "2" ]; then
  _pass "stage:2 → $got"
else
  _fail "stage:2 → expected 2, got $got"
fi
rm -rf "$SANDBOX"

# Test 4: stage 3
echo "### Test 4: stage3_명시"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{"stage": 3}' > "$SANDBOX/.claude/.rein-state/governance.json"
got=$(_call_stage "$SANDBOX")
if [ "$got" = "3" ]; then
  _pass "stage:3 → $got"
else
  _fail "stage:3 → expected 3, got $got"
fi
rm -rf "$SANDBOX"

# Test 5: stage 99 → INVALID
echo "### Test 5: stage99_invalid"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{"stage": 99}' > "$SANDBOX/.claude/.rein-state/governance.json"
got=$(_call_stage "$SANDBOX")
if [ "$got" = "INVALID" ]; then
  _pass "stage:99 → $got"
else
  _fail "stage:99 → expected INVALID, got $got"
fi
rm -rf "$SANDBOX"

# Test 6: malformed JSON → INVALID
echo "### Test 6: 잘못된JSON_invalid"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/.rein-state"
echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"
got=$(_call_stage "$SANDBOX")
if [ "$got" = "INVALID" ]; then
  _pass "malformed JSON → $got"
else
  _fail "malformed JSON → expected INVALID, got $got"
fi
rm -rf "$SANDBOX"

# Test 7: empty object → INVALID (no stage key)
echo "### Test 7: stage키없음_invalid"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{}' > "$SANDBOX/.claude/.rein-state/governance.json"
got=$(_call_stage "$SANDBOX")
if [ "$got" = "INVALID" ]; then
  _pass "no stage key → $got"
else
  _fail "no stage key → expected INVALID, got $got"
fi
rm -rf "$SANDBOX"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
