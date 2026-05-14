#!/bin/bash
# tests/scripts/test-rein-govcheck.sh
# Unit tests for scripts/rein-govcheck.py (Plan A Phase 1 Task 1.1)
#
# Scope IDs covered: GI-govcheck-existence, GI-govcheck-language-aware
#
# Test scenarios:
#   1. Current repo state clean → exit 0
#   2. Missing .sh reference in AGENTS.md (sandbox) → exit 2
#   3. Missing .py reference in sandbox AGENTS.md → exit 2
#   4. Syntax error in temp .py file (sandboxed AGENTS.md points to it) → exit 2
#   5. Syntax error in temp .sh file → exit 2
#   6. Valid .py without exec bit → exit 0 (no false-fail, GI-govcheck-language-aware)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOVCHECK="$PROJECT_DIR/scripts/rein-govcheck.py"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-rein-govcheck.sh"
echo ""

# Ensure script exists before running tests
if [ ! -f "$GOVCHECK" ]; then
  _fail "govcheck script not found: $GOVCHECK"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Test 1: Clean repo state → exit 0
echo "### Test 1: 정상_repo상태_exit0"
( cd "$PROJECT_DIR" && python3 "$GOVCHECK" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "clean repo → exit 0"
else
  _fail "clean repo → expected exit 0, got $rc"
fi

# Helper: build a minimal sandbox with AGENTS.md + CLAUDE.md + orchestrator.md
# then invoke govcheck from inside it.
_build_sandbox() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/.claude/hooks" "$dir/.claude"
  cp "$GOVCHECK" "$dir/scripts/rein-govcheck.py"
  : > "$dir/.claude/CLAUDE.md"
  : > "$dir/.claude/orchestrator.md"
}

# Test 2: Sandbox with fake missing .sh reference in AGENTS.md
echo "### Test 2: 누락된_shref_exit2"
SANDBOX=$(mktemp -d)
_build_sandbox "$SANDBOX"
cat > "$SANDBOX/AGENTS.md" <<'EOF'
# AGENTS
This project references `scripts/rein-nonexistent.sh` in its workflow.
EOF
( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "missing .sh → exit 2"
else
  _fail "missing .sh → expected exit 2, got $rc"
fi
rm -rf "$SANDBOX"

# Test 3: Sandbox with missing .py reference
echo "### Test 3: 누락된_pyref_exit2"
SANDBOX=$(mktemp -d)
_build_sandbox "$SANDBOX"
cat > "$SANDBOX/AGENTS.md" <<'EOF'
# AGENTS
Uses `scripts/rein-missing.py` for processing.
EOF
( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "missing .py → exit 2"
else
  _fail "missing .py → expected exit 2, got $rc"
fi
rm -rf "$SANDBOX"

# Test 4: Syntax error in .py file
echo "### Test 4: py구문오류_exit2"
SANDBOX=$(mktemp -d)
_build_sandbox "$SANDBOX"
# Create a broken python file
cat > "$SANDBOX/scripts/rein-broken.py" <<'EOF'
def foo(:  # deliberate syntax error
    pass
EOF
cat > "$SANDBOX/AGENTS.md" <<'EOF'
# AGENTS
Uses `scripts/rein-broken.py`.
EOF
( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "py syntax error → exit 2"
else
  _fail "py syntax error → expected exit 2, got $rc"
fi
rm -rf "$SANDBOX"

# Test 5: Syntax error in .sh file
echo "### Test 5: sh구문오류_exit2"
SANDBOX=$(mktemp -d)
_build_sandbox "$SANDBOX"
# Create a broken bash file (unterminated `if ... then`)
cat > "$SANDBOX/scripts/rein-broken.sh" <<'EOF'
#!/bin/bash
if [ "$x" = "y" ]; then
  echo "broken"
EOF
cat > "$SANDBOX/AGENTS.md" <<'EOF'
# AGENTS
Uses `scripts/rein-broken.sh`.
EOF
( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "sh syntax error → exit 2"
else
  _fail "sh syntax error → expected exit 2, got $rc"
fi
rm -rf "$SANDBOX"

# Test 6: Valid .py file without exec bit → should still pass (Windows Git Bash compat)
echo "### Test 6: execbit없는py_exit0"
SANDBOX=$(mktemp -d)
_build_sandbox "$SANDBOX"
cat > "$SANDBOX/scripts/rein-valid.py" <<'EOF'
#!/usr/bin/env python3
"""Valid script with no exec bit."""


def hello():
    return "world"


if __name__ == "__main__":
    print(hello())
EOF
chmod 0644 "$SANDBOX/scripts/rein-valid.py"  # no exec bit, read-only
cat > "$SANDBOX/AGENTS.md" <<'EOF'
# AGENTS
Uses `scripts/rein-valid.py`.
EOF
( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "valid .py without exec bit → exit 0"
else
  _fail "valid .py without exec bit → expected exit 0, got $rc"
fi
rm -rf "$SANDBOX"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
