#!/usr/bin/env bash
# tests/agents/test-plan-writer-exec-strategy-v2.sh
#
# Phase 3 Task 3.1 regression: plan-writer.md 의 `## 실행 전략 결정` 섹션이
# v2 (depends_on + edit_only/mutating + expected-write-set scope) 로 재작성됐고
# v1 (3-axis parallelizable boolean + workers[].scope + worktree-cleanup +
# manual dispatch) 잔재가 제거됐는지 검증한다.
#
# Scope ID: PLANWRITER-V2-DEPENDS-ON-EDIT-ONLY-MUTATING-JUDGMENT
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

AGENT="plugins/rein-core/agents/plan-writer.md"

PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

echo "=== test-plan-writer-exec-strategy-v2 ==="

# -----------------------------------------------------------------------
# (0) agent file presence
# -----------------------------------------------------------------------
echo ""
echo "[0] plan-writer.md presence"

if [ -f "$AGENT" ]; then
  pass "$AGENT exists"
else
  fail "$AGENT MISSING"
  echo ""
  echo "======================================"
  echo "PASS: $PASS  FAIL: $FAIL"
  echo "SOME CHECKS FAILED"
  exit 1
fi

# -----------------------------------------------------------------------
# (1) v2 vocabulary PRESENCE
# -----------------------------------------------------------------------
echo ""
echo "[1] v2 vocabulary PRESENCE"

PRESENT_TOKENS=(
  "depends_on"
  "edit_only"
  "mutating"
  "동시 실행"
  "disjoint"
)

for tok in "${PRESENT_TOKENS[@]}"; do
  if grep -qF "$tok" "$AGENT"; then
    pass "contains v2 token: '$tok'"
  else
    fail "MISSING v2 token: '$tok'"
  fi
done

# -----------------------------------------------------------------------
# (2) v1 vocabulary ABSENCE
# -----------------------------------------------------------------------
echo ""
echo "[2] v1 vocabulary ABSENCE"

ABSENT_TOKENS=(
  "parallelizable"
  "3 axis"
  "3-axis"
  "worktree-cleanup"
  "workers[]"
)

for tok in "${ABSENT_TOKENS[@]}"; do
  if grep -qF "$tok" "$AGENT"; then
    fail "v1 residue still present: '$tok'"
  else
    pass "v1 residue absent: '$tok'"
  fi
done

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "======================================"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
