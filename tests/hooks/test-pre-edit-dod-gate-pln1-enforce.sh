#!/bin/bash
# tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh
# GATE-REMOVAL-PARALLELIZABLE-ENFORCEMENT-OTHERS-INTACT
# (Phase 3 / Task 3.2 — docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md)
#
# The obsolete PLN-1 "parallelizable enforcement" block (parallelizable: true
# plan + worker-marker.json worktree bypass) is DISCARDED. The new wave-parallel
# model (depends_on/mode/scope v2, owned by the parallel-execute skill) replaces
# it. This test was previously the BLOCKING assertion for that gate; it is now
# flipped to assert the block is ABSENT while every OTHER gate branch
# (DoD-gate, routing-gate, spec-review) remains intact.
#
# Assertions:
#   (a) `PLN-1: parallelizable enforcement` comment marker is ABSENT
#   (b) `parallelizable plan without AG-2 worker` BLOCKED/log_block string ABSENT
#   (c) the only worktree/worker-marker references in the file are gone
#   (d) `bash -n pre-edit-dod-gate.sh` → syntax OK (exit 0)
#   (e) OTHER branches still PRESENT: DoD-gate / routing-gate / spec-review

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/plugins/rein-core/hooks/pre-edit-dod-gate.sh"

TEST_COUNT=0
FAIL_COUNT=0

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "  OK: $1"
}

fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  FAIL: $1" >&2
}

# Guard: hook file must exist.
if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found: $HOOK" >&2
  exit 1
fi

# --- (a) PLN-1 enforcement comment marker must be ABSENT ---------------------
if grep -q 'PLN-1: parallelizable enforcement' "$HOOK"; then
  fail "(a) 'PLN-1: parallelizable enforcement' marker must be absent (block removed)"
else
  pass "(a) PLN-1 parallelizable enforcement marker absent"
fi

# --- (b) BLOCKED/log_block enforcement string must be ABSENT -----------------
if grep -q 'parallelizable plan without AG-2 worker' "$HOOK"; then
  fail "(b) 'parallelizable plan without AG-2 worker' message must be absent"
else
  pass "(b) AG-2 worker BLOCKED/log_block message absent"
fi

# --- (c) the only worktree/worker-marker refs lived in the PLN-1 block -------
if grep -qE 'worker-marker|worktree|PLN1-GATE-ENFORCEMENT' "$HOOK"; then
  fail "(c) worktree/worker-marker/PLN1-GATE references must be gone with the block"
else
  pass "(c) no residual worktree/worker-marker/PLN1-GATE references"
fi

# --- (d) syntax must still be valid ------------------------------------------
if bash -n "$HOOK" 2>/dev/null; then
  pass "(d) bash -n syntax OK"
else
  fail "(d) bash -n syntax check failed"
fi

# --- (e) OTHER gate branches must remain INTACT ------------------------------
# DoD-gate branch (the block immediately after the removed PLN-1 block).
if grep -q 'if \[ "\$DOD_FOUND" = true \]; then' "$HOOK"; then
  pass "(e1) DoD-gate branch present (DOD_FOUND validator block)"
else
  fail "(e1) DoD-gate branch missing — must be preserved"
fi

# routing-gate branch.
if grep -q '# END routing-gate' "$HOOK"; then
  pass "(e2) routing-gate branch present"
else
  fail "(e2) routing-gate branch missing — must be preserved"
fi

# spec-review branch (unreviewed-spec block).
if grep -q 'SPEC_REVIEWS_DIR=' "$HOOK" && grep -q 'rein-mark-spec-reviewed.sh' "$HOOK"; then
  pass "(e3) spec-review branch present"
else
  fail "(e3) spec-review branch missing — must be preserved"
fi

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
