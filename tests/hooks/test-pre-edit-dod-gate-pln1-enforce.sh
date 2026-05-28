#!/bin/bash
# tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh
# PLN1-GATE-ENFORCEMENT-ACTIVE (2026-05-28-worker-contract-plus-pln1-enforce)
#
# Active DoD 의 plan 이 `parallelizable: true` 인데 본 hook 호출이 worker
# worktree 안 (`.rein/worker-marker.json` 존재) 이 아니면 source 편집 차단.
# worker 안에서 호출되거나 legacy plan (`parallelizable: false` 또는 섹션
# 부재) 이면 통과.
#
# Truth table:
#   parallelizable=true  + worker-marker absent  → exit 2  (block)
#   parallelizable=true  + worker-marker present → exit 0  (worker bypass)
#   parallelizable=false + (any worker-marker)   → exit 0  (legacy compat)
#   no `## 실행 전략` section                    → exit 0  (legacy compat)
#   no plan ref in DoD                          → exit 0  (skip branch)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-harness.sh"

# Seed an active DoD that points to a plan file. Caller supplies the plan
# body (with or without parallelizable: true).
_seed_pln1_dod() {
  local dod_name="$1"
  local plan_rel_path="$2"
  cat > "$SANDBOX/trail/dod/$dod_name" <<EOF
# DoD — pln1 test fixture

## 범위 연결

plan ref: $plan_rel_path
covers: [FIX-X]
EOF
}

_seed_pln1_plan() {
  local plan_rel_path="$1"
  local parallel_value="$2"  # "true" / "false" / "" (no section)
  local plan_path="$SANDBOX/$plan_rel_path"
  mkdir -p "$(dirname "$plan_path")"
  if [ -z "$parallel_value" ]; then
    cat > "$plan_path" <<'EOF'
# Plan
## Goal
fixture without 실행 전략 section.
EOF
  else
    cat > "$plan_path" <<EOF
# Plan
## Goal
fixture.

## 실행 전략

parallelizable: $parallel_value
EOF
  fi
}

_seed_worker_marker() {
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/worker-marker.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "marker_type": "rein-feature-builder-worker",
  "agent_name": "feature-builder-worker",
  "worker_scope": ["src/x.ts"]
}
EOF
}

_run_edit() {
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/x.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2> "$SANDBOX/.last-stderr"
  HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$SANDBOX/.last-stderr" 2>/dev/null || echo "")
}

# F1: parallelizable: true + worker-marker absent → block (exit 2)
test_parallelizable_true_no_worker_marker_blocks() {
  _seed_pln1_dod "dod-2026-05-28-pln1-block.md" "docs/plans/p.md"
  _seed_pln1_plan "docs/plans/p.md" "true"
  _run_edit
  assert_exit 2 "F1: parallelizable=true without worker-marker must block"
  echo "$HOOK_STDERR" | grep -q "parallelizable plan without AG-2" \
    || fail "F1: log_block message expected in stderr"
}

# F2: parallelizable: true + worker-marker present → bypass (exit 0 + NOTICE)
test_parallelizable_true_with_worker_marker_bypasses() {
  _seed_pln1_dod "dod-2026-05-28-pln1-bypass.md" "docs/plans/p.md"
  _seed_pln1_plan "docs/plans/p.md" "true"
  _seed_worker_marker
  _run_edit
  assert_exit 0 "F2: worker-marker present must bypass enforcement"
  echo "$HOOK_STDERR" | grep -q "worker-marker present — enforcement skip" \
    || fail "F2: NOTICE expected in stderr"
}

# F3: parallelizable: false → legacy backward-compat (exit 0)
test_parallelizable_false_passes() {
  _seed_pln1_dod "dod-2026-05-28-pln1-false.md" "docs/plans/p.md"
  _seed_pln1_plan "docs/plans/p.md" "false"
  _run_edit
  assert_exit 0 "F3: parallelizable=false must pass (legacy backward-compat)"
}

# F4: no `## 실행 전략` section → legacy backward-compat (exit 0)
test_no_strategy_section_passes() {
  _seed_pln1_dod "dod-2026-05-28-pln1-noseg.md" "docs/plans/p.md"
  _seed_pln1_plan "docs/plans/p.md" ""
  _run_edit
  assert_exit 0 "F4: plan without 실행 전략 section must pass"
}

# F5: DoD without plan ref → skip PLN1 branch entirely (exit 0)
test_no_plan_ref_passes() {
  cat > "$SANDBOX/trail/dod/dod-2026-05-28-pln1-noref.md" <<'EOF'
# DoD — no plan ref fixture

## 범위
- placeholder
EOF
  _run_edit
  assert_exit 0 "F5: DoD without plan ref must skip PLN1 branch"
}

# F6: DoD lacks `## 범위 연결` section entirely (legacy / operational DoD).
# The PLN1 branch's plan-ref extraction uses awk over `## 범위 연결` → never
# matches, so plan_ref is empty and the branch is skipped. This is the shape
# the worker-contract-plus-pln1-enforce DoD itself was committed as initially
# (codex R1 finding "missing `## 범위 연결`"). Must pass — operational DoDs
# may legitimately omit the section.
test_no_range_section_passes() {
  cat > "$SANDBOX/trail/dod/dod-2026-05-28-pln1-norange.md" <<'EOF'
# DoD — no 범위 연결 section

## 범위
- placeholder

## 검증 기준
- [ ] placeholder
EOF
  _run_edit
  assert_exit 0 "F6: DoD without 범위 연결 section must skip PLN1 branch"
}

# Each run_test creates a fresh sandbox (sandbox_setup) and tears it down on
# return, so SANDBOX is re-created per test. Tests must seed src/x.ts before
# calling _run_edit.
_setup_src() {
  mkdir -p "$SANDBOX/src"
  echo "x" > "$SANDBOX/src/x.ts"
}

# Wrap each test to seed src/x.ts inside the per-test sandbox.
test_F1() { _setup_src; test_parallelizable_true_no_worker_marker_blocks; }
test_F2() { _setup_src; test_parallelizable_true_with_worker_marker_bypasses; }
test_F3() { _setup_src; test_parallelizable_false_passes; }
test_F4() { _setup_src; test_no_strategy_section_passes; }
test_F5() { _setup_src; test_no_plan_ref_passes; }
test_F6() { _setup_src; test_no_range_section_passes; }

run_test test_F1 pre-edit-dod-gate.sh rein-validate-coverage-matrix.py
run_test test_F2 pre-edit-dod-gate.sh rein-validate-coverage-matrix.py
run_test test_F3 pre-edit-dod-gate.sh rein-validate-coverage-matrix.py
run_test test_F4 pre-edit-dod-gate.sh rein-validate-coverage-matrix.py
run_test test_F5 pre-edit-dod-gate.sh rein-validate-coverage-matrix.py
run_test test_F6 pre-edit-dod-gate.sh rein-validate-coverage-matrix.py

summary
