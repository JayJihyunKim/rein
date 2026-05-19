#!/bin/bash
# tests/hooks/test-coverage-matrix.sh
# Test suite for design→plan coverage matrix validator + hooks.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-harness.sh"

VALIDATOR_ABS="$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py"

# --- fixtures -------------------------------------------------------

seed_design() {
  # $1 = path relative to SANDBOX, $2 = IDs (space-separated)
  local path="$SANDBOX/$1"
  mkdir -p "$(dirname "$path")"
  {
    echo "# Design"
    echo ""
    echo "## Scope Items"
    echo ""
    echo "| ID | 설명 |"
    echo "|----|------|"
    for id in $2; do
      echo "| $id | desc of $id |"
    done
  } > "$path"
}

seed_plan_clean() {
  # Plan with matrix + covers for design IDs "A1 A2" only.
  local path="$SANDBOX/$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1]

## Phase 2
covers: [A2]
MD
}

run_validator_in_sandbox() {
  # $1 = plan path relative to SANDBOX. Sets HOOK_EXIT manually.
  local plan_rel="$1"
  ( cd "$SANDBOX" && python3 "$VALIDATOR_ABS" "$plan_rel" ) \
    > /tmp/cov-stdout.$$ 2> /tmp/cov-stderr.$$
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat /tmp/cov-stdout.$$)
  HOOK_STDERR=$(cat /tmp/cov-stderr.$$)
  rm -f /tmp/cov-stdout.$$ /tmp/cov-stderr.$$
}

# --- tests ----------------------------------------------------------

test_validator_passes_clean_plan() {
  seed_design "docs/specs/foo.md" "A1 A2"
  seed_plan_clean "docs/plans/bar.md"

  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 0 "clean plan should pass"
}

test_validator_detects_missing_design_id() {
  seed_design "docs/specs/foo.md" "A1 A2 A3"
  seed_plan_clean "docs/plans/bar.md"
  # plan_clean 은 A1/A2 만 매핑 → A3 누락

  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 2 "missing design ID should fail"
}

test_validator_detects_unknown_covers_id() {
  seed_design "docs/specs/foo.md" "A1 A2"
  local path="$SANDBOX/docs/plans/bar.md"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1, A99]

## Phase 2
covers: [A2]
MD

  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 2 "unknown covers ID should fail"
}

test_validator_detects_duplicate_matrix_id() {
  seed_design "docs/specs/foo.md" "A1"
  local path="$SANDBOX/docs/plans/bar.md"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A1 | implemented | Phase 2 |

## Phase 1
covers: [A1]
MD

  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 2 "duplicate matrix ID should fail"
}

test_validator_detects_uncovered_implemented_id() {
  seed_design "docs/specs/foo.md" "A1 A2"
  local path="$SANDBOX/docs/plans/bar.md"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1]
MD

  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 2 "implemented without covers should fail"
}

test_validator_skips_legacy_plan() {
  local path="$SANDBOX/docs/plans/legacy.md"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Legacy Plan

No coverage matrix here.

## Phase 1
Do things.
MD

  run_validator_in_sandbox "docs/plans/legacy.md"
  assert_exit 0 "legacy plan (no matrix) should pass with warning"
}

test_validator_allows_deferred_without_covers() {
  seed_design "docs/specs/foo.md" "A1 A2"
  local path="$SANDBOX/docs/plans/bar.md"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | deferred | Stage 2.5 로 연기 — 추후 |

## Phase 1
covers: [A1]
MD

  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 0 "deferred ID without covers should pass"
}

_seed_plan_with_abs_ref() {
  # Write a plan whose design ref is the absolute path to the design file.
  # This ensures the validator can resolve it regardless of cwd.
  local plan_path="$SANDBOX/$1"
  local design_abs="$SANDBOX/$2"  # e.g. docs/specs/foo.md
  mkdir -p "$(dirname "$plan_path")"
  cat > "$plan_path" <<MD
# Plan

## Design 범위 커버리지 매트릭스

> design ref: $design_abs

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1]

## Phase 2
covers: [A2]
MD
}

test_hook_creates_marker_on_invalid_plan() {
  seed_design "docs/specs/foo.md" "A1 A2 A3"
  # Plan only covers A1 A2 — A3 is missing from matrix.
  # Use absolute design ref so validator can find the file from any cwd.
  _seed_plan_with_abs_ref "docs/plans/bar.md" "docs/specs/foo.md"
  # Overwrite to add A3-missing situation (plan matrix is missing A3).
  # _seed_plan_with_abs_ref already produces a valid A1+A2 plan.
  # We need to add A3 to design but keep plan covering only A1+A2 → mismatch.
  # (seed_design with A1 A2 A3 was already called; plan has A1+A2 only in matrix.)

  local input="{\"tool_input\":{\"file_path\":\"$SANDBOX/docs/plans/bar.md\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$input"
  assert_exit 0 "hook returns 0 (marker creation, not block)"
  assert_file_exists "trail/dod/.coverage-mismatch"
}

test_hook_clears_marker_on_valid_plan() {
  seed_design "docs/specs/foo.md" "A1 A2"
  _seed_plan_with_abs_ref "docs/plans/bar.md" "docs/specs/foo.md"
  # Seed marker with the plan's abs path so marker_has_plan detects it.
  echo "$SANDBOX/docs/plans/bar.md" > "$SANDBOX/trail/dod/.coverage-mismatch"

  local input="{\"tool_input\":{\"file_path\":\"$SANDBOX/docs/plans/bar.md\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$input"
  assert_exit 0 "hook returns 0"
  assert_file_missing "trail/dod/.coverage-mismatch"
}

test_test_commit_gate_blocks_commit_on_marker() {
  # 리뷰 stamp + DoD + inbox 까지 전부 생성해 coverage gate 가 **유일한 실패 원인**이 되도록 격리.
  # pre-bash-test-commit-gate 는 commit-msg helper 를 호출하므로 lib 파일도 복사한다.
  # Wave 3: coverage gate now uses JSON deny (exit 0, stdout JSON) when the
  # validator can revalidate the plan (rc=1 path), or falls back to exit 2 +
  # [rein] stderr when the marker target is unidentifiable (rc=2/infra path).
  # A touch-only marker is empty → rc=2 path → exit 2 + [rein] stderr.
  # Both paths block the command; test asserts exit non-zero and coverage text present.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-19-stamp-test.md"
  seed_inbox "2026-04-19-stamp-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
  touch "$SANDBOX/trail/dod/.coverage-mismatch"

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-test-commit-gate.sh" "$input"
  # Empty marker → rc=2 path [I3]: exactly exit 2 + [rein] on stderr.
  assert_exit 2 "test-commit gate should exit 2 (I3 infra path) for empty coverage-mismatch marker"
  assert_stderr_contains "[rein]" "I3 infra block must emit [rein] prefix on stderr"
}

test_test_commit_gate_allows_commit_without_marker() {
  # Negative control — 마커가 없으면 coverage gate 가 통과해야 한다 (review stamp gate 는 별개).
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-19-stamp-test.md"
  seed_inbox "2026-04-19-stamp-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
  # NO .coverage-mismatch

  local input='{"tool_input":{"command":"git commit -m \"feat: test\""},"tool_result":{}}'
  run_hook "pre-bash-test-commit-gate.sh" "$input"
  # stderr 에 coverage 문구가 **없어야** 한다 (다른 gate 에서 exit 돼도 coverage 는 무관)
  echo "$HOOK_STDERR" | grep -qF "coverage matrix 검증 실패" \
    && fail "coverage gate should not fire without marker" || true
}

test_hook_marker_is_plan_specific() {
  # Plan A is broken (A3 missing), plan B is clean.
  # Editing plan B should NOT clear marker created by plan A.
  seed_design "docs/specs/fooA.md" "A1 A2 A3"
  seed_design "docs/specs/fooB.md" "B1 B2"

  # Plan A: matrix covers A1+A2, missing A3 → validator fails
  local planA="$SANDBOX/docs/plans/a.md"
  mkdir -p "$(dirname "$planA")"
  cat > "$planA" <<MD
# Plan A

## Design 범위 커버리지 매트릭스

> design ref: $SANDBOX/docs/specs/fooA.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1]

## Phase 2
covers: [A2]
MD

  # Plan B: complete and valid
  local planB="$SANDBOX/docs/plans/b.md"
  cat > "$planB" <<MD
# Plan B

## Design 범위 커버리지 매트릭스

> design ref: $SANDBOX/docs/specs/fooB.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| B1 | implemented | Phase 1 |
| B2 | implemented | Phase 2 |

## Phase 1
covers: [B1]

## Phase 2
covers: [B2]
MD

  # Edit A first → marker created with A in it
  local inputA="{\"tool_input\":{\"file_path\":\"$planA\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$inputA"
  assert_exit 0 "hook exit 0 after A"
  assert_file_exists "trail/dod/.coverage-mismatch"
  assert_file_contains "trail/dod/.coverage-mismatch" "$planA"

  # Edit B (valid) → marker should STILL exist because A is still broken
  local inputB="{\"tool_input\":{\"file_path\":\"$planB\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$inputB"
  assert_exit 0 "hook exit 0 after B"
  assert_file_exists "trail/dod/.coverage-mismatch"
  assert_file_contains "trail/dod/.coverage-mismatch" "$planA"
}

test_hook_removes_fixed_plan_keeps_others() {
  # Seed marker with 2 failed plans (A and C), fix A, verify A removed but C stays.
  seed_design "docs/specs/fooA.md" "A1 A2"
  seed_design "docs/specs/fooC.md" "C1 C2"

  # Plan A: currently valid (we'll simulate it was previously broken)
  local planA="$SANDBOX/docs/plans/a.md"
  local planC="$SANDBOX/docs/plans/c.md"
  mkdir -p "$(dirname "$planA")"

  # Valid plan A — will be the edit target
  cat > "$planA" <<MD
# Plan A

## Design 범위 커버리지 매트릭스

> design ref: $SANDBOX/docs/specs/fooA.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1]

## Phase 2
covers: [A2]
MD

  # Pre-seed marker with both A and C paths (simulating prior failures).
  mkdir -p "$SANDBOX/trail/dod"
  {
    echo "$planA"
    echo "$planC"
  } > "$SANDBOX/trail/dod/.coverage-mismatch"

  # Edit A (now valid) → hook removes A from marker, C stays
  local inputA="{\"tool_input\":{\"file_path\":\"$planA\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$inputA"
  assert_exit 0 "hook exit 0 after fixing A"
  assert_file_exists "trail/dod/.coverage-mismatch"
  assert_file_not_contains "trail/dod/.coverage-mismatch" "$planA"
  assert_file_contains "trail/dod/.coverage-mismatch" "$planC"
}

test_test_commit_gate_blocks_pytest_on_marker() {
  # Mirror of commit-blocking test, for pytest command path.
  # Same Wave 3 behavior: empty marker → infra-integrity exit 2 + [rein] stderr.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-commit-msg.py" \
     "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  seed_dod "dod-2026-04-19-stamp-test.md"
  seed_inbox "2026-04-19-stamp-test.md"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
  touch "$SANDBOX/trail/dod/.coverage-mismatch"

  local input='{"tool_input":{"command":"pytest tests/unit/"},"tool_result":{}}'
  run_hook "pre-bash-test-commit-gate.sh" "$input"
  # Empty marker → rc=2 path [I3]: exactly exit 2 + [rein] on stderr.
  assert_exit 2 "test-commit gate should exit 2 (I3 infra path) for empty coverage-mismatch marker"
  assert_stderr_contains "[rein]" "I3 infra block must emit [rein] prefix on stderr"
}

# --- main -----------------------------------------------------------
# validator 만 쓰는 테스트는 훅 복사 없이 run_test 로 감쌈.
# run_test 는 hook-name 인자가 없으면 sandbox 만 세팅하고 끝난다.
run_test test_validator_passes_clean_plan
run_test test_validator_detects_missing_design_id
run_test test_validator_detects_unknown_covers_id
run_test test_validator_detects_duplicate_matrix_id
run_test test_validator_detects_uncovered_implemented_id
run_test test_validator_skips_legacy_plan
run_test test_validator_allows_deferred_without_covers

run_test test_hook_creates_marker_on_invalid_plan \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_hook_clears_marker_on_valid_plan \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_test_commit_gate_blocks_commit_on_marker \
  pre-bash-test-commit-gate.sh
run_test test_test_commit_gate_allows_commit_without_marker \
  pre-bash-test-commit-gate.sh
run_test test_hook_marker_is_plan_specific \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_hook_removes_fixed_plan_keeps_others \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_test_commit_gate_blocks_pytest_on_marker \
  pre-bash-test-commit-gate.sh

summary
