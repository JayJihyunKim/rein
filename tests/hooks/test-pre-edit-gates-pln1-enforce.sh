#!/bin/bash
# tests/hooks/test-pre-edit-gates-pln1-enforce.sh
# GATE-REMOVAL-PARALLELIZABLE-ENFORCEMENT-OTHERS-INTACT
# (Phase 3 / Task 3.2 — docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md)
#
# Renamed from tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh (Phase 7
# 웨이브 3 ③-b, 편집 게이트 교대, 2026-08-21): pre-edit-dod-gate.sh is
# deleted and replaced by pre-edit-discipline-gate.sh (governance/incident-
# review/spec-review/routing, everything this file's checks (a)-(d) and
# (e2)/(e3) used to assert against) + pre-edit-task-gate.sh (the
# active-task axis, (e1) now targets this hook instead).
#
# The obsolete PLN-1 "parallelizable enforcement" block (parallelizable: true
# plan + worker-marker.json worktree bypass) is DISCARDED. The new wave-parallel
# model (depends_on/mode/scope v2, owned by the parallel-execute skill) replaces
# it. This test was previously the BLOCKING assertion for that gate; it is now
# flipped to assert the block is ABSENT while every OTHER gate branch
# (active-task-gate wiring, routing-gate, spec-review) remains intact.
#
# Assertions:
#   (a) `PLN-1: parallelizable enforcement` comment marker is ABSENT in BOTH
#       new hooks
#   (b) `parallelizable plan without AG-2 worker` BLOCKED/log_block string
#       ABSENT in BOTH new hooks
#   (c) the only worktree/worker-marker references in either file are gone
#   (d) `bash -n` on both hooks → syntax OK
#   (e) OTHER branches still PRESENT: active-task axis (now pre-edit-task-
#       gate.sh) / routing-gate / spec-review (still pre-edit-discipline-
#       gate.sh)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISCIPLINE_HOOK="$REPO_ROOT/plugins/rein-core/hooks/pre-edit-discipline-gate.sh"
TASK_HOOK="$REPO_ROOT/plugins/rein-core/hooks/pre-edit-task-gate.sh"

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

# Guard: both hook files must exist.
for h in "$DISCIPLINE_HOOK" "$TASK_HOOK"; do
  if [ ! -f "$h" ]; then
    echo "FATAL: hook not found: $h" >&2
    exit 1
  fi
done

# --- (a) PLN-1 enforcement comment marker must be ABSENT in both hooks -------
for h in "$DISCIPLINE_HOOK" "$TASK_HOOK"; do
  name="$(basename "$h")"
  if grep -q 'PLN-1: parallelizable enforcement' "$h"; then
    fail "(a) '$name': 'PLN-1: parallelizable enforcement' marker must be absent (block removed)"
  else
    pass "(a) $name: PLN-1 parallelizable enforcement marker absent"
  fi
done

# --- (b) BLOCKED/log_block enforcement string must be ABSENT in both hooks --
for h in "$DISCIPLINE_HOOK" "$TASK_HOOK"; do
  name="$(basename "$h")"
  if grep -q 'parallelizable plan without AG-2 worker' "$h"; then
    fail "(b) '$name': 'parallelizable plan without AG-2 worker' message must be absent"
  else
    pass "(b) $name: AG-2 worker BLOCKED/log_block message absent"
  fi
done

# --- (c) the only worktree/worker-marker refs lived in the PLN-1 block -----
for h in "$DISCIPLINE_HOOK" "$TASK_HOOK"; do
  name="$(basename "$h")"
  if grep -qE 'worker-marker|worktree|PLN1-GATE-ENFORCEMENT' "$h"; then
    fail "(c) '$name': worktree/worker-marker/PLN1-GATE references must be gone with the block"
  else
    pass "(c) $name: no residual worktree/worker-marker/PLN1-GATE references"
  fi
done

# --- (d) syntax must still be valid in both hooks ---------------------------
for h in "$DISCIPLINE_HOOK" "$TASK_HOOK"; do
  name="$(basename "$h")"
  if bash -n "$h" 2>/dev/null; then
    pass "(d) $name: bash -n syntax OK"
  else
    fail "(d) $name: bash -n syntax check failed"
  fi
done

# --- (e) OTHER gate branches must remain INTACT ------------------------------

# (e1) Active-task axis branch — moved from pre-edit-dod-gate.sh (wired to
# lib/active-task-gate.sh's rein_check_active_task) to pre-edit-task-gate.sh
# (Phase 7 웨이브 3 ③-b: wired to that SAME lib's two sub-functions,
# rein_active_task_authority_switched + rein_active_task_delegate — NOT
# rein_check_active_task, which the new hook deliberately does not call, see
# that lib's header "왜 이 축만 다르게" section). "present" means (i) the
# call sites are wired up in pre-edit-task-gate.sh AND (ii) the lib actually
# carries the real function bodies (the switch-check + delegate logic, not
# just a comment mentioning them).
ACTIVE_TASK_GATE_LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/active-task-gate.sh"
if grep -q 'rein_active_task_authority_switched' "$TASK_HOOK" \
   && grep -q 'rein_active_task_delegate' "$TASK_HOOK" \
   && [ -f "$ACTIVE_TASK_GATE_LIB" ] \
   && grep -q 'rein_active_task_authority_switched()' "$ACTIVE_TASK_GATE_LIB" \
   && grep -q 'rein_active_task_delegate()' "$ACTIVE_TASK_GATE_LIB"; then
  pass "(e1) active-task axis branch present (pre-edit-task-gate.sh wired to lib/active-task-gate.sh's switch-check + delegate)"
else
  fail "(e1) active-task axis branch missing — must be preserved"
fi

# routing-gate branch. feature-builder-refactor (dod-gate fix cycle,
# 2026-08-14) moved this block verbatim into hooks/lib/routing-gate.sh (same
# swappable-boundary pattern as the spec-review extraction below) — the hook
# itself now only sources the lib and calls rein_check_routing_gate. So
# "present" means (i) the call site is wired up here AND (ii) the lib
# actually carries the real judgment body (the routing-section /
# approved_by_user enforcement, not just a comment mentioning it), not that
# the literal "# END routing-gate" text is still inline in this file.
ROUTING_GATE_LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/routing-gate.sh"
if grep -q 'rein_check_routing_gate' "$DISCIPLINE_HOOK" \
   && [ -f "$ROUTING_GATE_LIB" ] \
   && grep -q 'rein_check_routing_gate()' "$ROUTING_GATE_LIB" \
   && grep -q 'ROUTING_BYPASS=' "$ROUTING_GATE_LIB" \
   && grep -q 'approved_by_user' "$ROUTING_GATE_LIB"; then
  pass "(e2) routing-gate branch present (pre-edit-discipline-gate.sh wired to lib/routing-gate.sh)"
else
  fail "(e2) routing-gate branch missing — must be preserved"
fi

# spec-review branch (unreviewed-spec block). feature-builder-refactor task
# step 2 moved this block verbatim into hooks/lib/spec-review-gate.sh (a
# swappable boundary for v2 governance handoff) — the hook itself now only
# sources the lib and calls rein_check_spec_review_gate. So "present" means
# (i) the call site is wired up here AND (ii) the lib carries the real body,
# not that the literal SPEC_REVIEWS_DIR=/rein-mark-spec-reviewed.sh text is
# still inline in this file.
SPEC_REVIEW_LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/spec-review-gate.sh"
if grep -q 'rein_check_spec_review_gate' "$DISCIPLINE_HOOK" \
   && [ -f "$SPEC_REVIEW_LIB" ] \
   && grep -q 'SPEC_REVIEWS_DIR=' "$SPEC_REVIEW_LIB" \
   && grep -q 'rein-mark-spec-reviewed.sh' "$SPEC_REVIEW_LIB"; then
  pass "(e3) spec-review branch present (pre-edit-discipline-gate.sh wired to lib/spec-review-gate.sh)"
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
