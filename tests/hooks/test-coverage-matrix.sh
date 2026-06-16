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

# --- 2026-06-16 session follow-up: numbered headings + backtick Scope ID cells.
# spec-writer naturally writes `## 3. Scope Items` and backtick-wrapped IDs;
# the validator must accept both rather than silently treating the doc as a
# legacy no-matrix plan (which skipped validation entirely).
_seed_numbered_backtick_design() {
  local path="$SANDBOX/$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
# Design

## 3. Scope Items

| ID | 설명 |
|----|------|
| `B1-foo` | desc of B1 |
| `B2-bar` | desc of B2 |
MD
}

test_validator_accepts_numbered_heading_and_backtick_ids() {
  _seed_numbered_backtick_design "docs/specs/foo.md"
  mkdir -p "$SANDBOX/docs/plans"
  cat > "$SANDBOX/docs/plans/bar.md" <<'MD'
# Plan

## 2. Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| `B1-foo` | implemented | Phase 1 |
| `B2-bar` | implemented | Phase 2 |

## Phase 1
covers: [B1-foo]

## Phase 2
covers: [B2-bar]
MD
  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 0 "numbered heading + backtick IDs (valid coverage) should pass"
}

test_validator_engages_on_numbered_heading_uncovered_id() {
  # Reproduction: before the leniency, a numbered matrix heading was not matched,
  # so the validator treated the plan as legacy (no matrix) and SKIPPED → exit 0,
  # silently passing an uncovered implemented ID. Now the matrix is found and the
  # uncovered ID is caught → exit 2 (validation actually engaged).
  _seed_numbered_backtick_design "docs/specs/foo.md"
  mkdir -p "$SANDBOX/docs/plans"
  cat > "$SANDBOX/docs/plans/bar.md" <<'MD'
# Plan

## 2. Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| `B1-foo` | implemented | Phase 1 |
| `B2-bar` | implemented | Phase 2 |

## Phase 1
covers: [B1-foo]
MD
  run_validator_in_sandbox "docs/plans/bar.md"
  assert_exit 2 "numbered heading: uncovered implemented ID must still be caught (not skipped)"
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

test_hook_appends_dirty_on_invalid_plan_no_validator_call() {
  # X3.B.1 (Area B deferral): post-edit no longer calls the validator. It
  # only appends the dirty plan abs path to .plan-coverage-dirty. The actual
  # validator + .coverage-mismatch management lives in commit-gate flush
  # (test-plan-coverage-deferral.sh covers the flush path end-to-end).
  seed_design "docs/specs/foo.md" "A1 A2 A3"
  _seed_plan_with_abs_ref "docs/plans/bar.md" "docs/specs/foo.md"

  local input="{\"tool_input\":{\"file_path\":\"$SANDBOX/docs/plans/bar.md\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$input"
  assert_exit 0 "hook returns 0 (deferral, not block)"
  assert_file_exists "trail/dod/.plan-coverage-dirty"
  assert_file_contains "trail/dod/.plan-coverage-dirty" "$SANDBOX/docs/plans/bar.md"
  # Critically: post-edit must NOT create .coverage-mismatch — that is the
  # commit-gate-flush's job now.
  assert_file_missing "trail/dod/.coverage-mismatch"
}

test_hook_does_not_clear_marker_on_valid_plan() {
  # X3.B.1 (Area B deferral): post-edit no longer manages the legacy
  # .coverage-mismatch marker. Even a valid plan edit just appends a dirty
  # entry; marker removal is the flush's responsibility. The legacy "post-
  # edit clears marker on fix" behavior is now exercised via commit-gate
  # flush in test-plan-coverage-deferral.sh (T6/T9).
  seed_design "docs/specs/foo.md" "A1 A2"
  _seed_plan_with_abs_ref "docs/plans/bar.md" "docs/specs/foo.md"
  echo "$SANDBOX/docs/plans/bar.md" > "$SANDBOX/trail/dod/.coverage-mismatch"

  local input="{\"tool_input\":{\"file_path\":\"$SANDBOX/docs/plans/bar.md\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$input"
  assert_exit 0 "hook returns 0"
  # post-edit must not touch the legacy marker — it remains as-is.
  assert_file_exists "trail/dod/.coverage-mismatch"
  # And the dirty list now also has this plan recorded for the next flush.
  assert_file_exists "trail/dod/.plan-coverage-dirty"
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

test_hook_appends_multiple_distinct_plans() {
  # X3.B.1 (Area B deferral): post-edit appends each plan path to
  # .plan-coverage-dirty. With multiple distinct plan edits we expect
  # multiple lines (dedup is the flush's responsibility, not the
  # append's — design memo §7 ID 2 set-equality contract).
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

  # Edit A first → dirty list has A
  local inputA="{\"tool_input\":{\"file_path\":\"$planA\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$inputA"
  assert_exit 0 "hook exit 0 after A"
  assert_file_exists "trail/dod/.plan-coverage-dirty"
  assert_file_contains "trail/dod/.plan-coverage-dirty" "$planA"

  # Edit B → dirty list also has B (no validation triggered).
  local inputB="{\"tool_input\":{\"file_path\":\"$planB\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$inputB"
  assert_exit 0 "hook exit 0 after B"
  assert_file_contains "trail/dod/.plan-coverage-dirty" "$planA"
  assert_file_contains "trail/dod/.plan-coverage-dirty" "$planB"
  # No commit-gate-flush has run yet → no .coverage-mismatch marker.
  assert_file_missing "trail/dod/.coverage-mismatch"
}

test_hook_does_not_mutate_existing_marker() {
  # X3.B.1 (Area B deferral): post-edit no longer mutates the legacy
  # .coverage-mismatch list. Even when a plan is re-edited to a now-valid
  # state, the marker file remains untouched (commit-gate flush is the
  # only authority that adds/removes marker entries — covered by
  # test-plan-coverage-deferral.sh T7/T9).
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

  # Edit A (now valid) → hook appends A to dirty list, marker UNTOUCHED.
  local inputA="{\"tool_input\":{\"file_path\":\"$planA\"},\"tool_result\":{}}"
  run_hook "post-edit-plan-coverage.sh" "$inputA"
  assert_exit 0 "hook exit 0 after fixing A"
  # Marker remains exactly as seeded — post-edit must not mutate it.
  assert_file_exists "trail/dod/.coverage-mismatch"
  assert_file_contains "trail/dod/.coverage-mismatch" "$planA"
  assert_file_contains "trail/dod/.coverage-mismatch" "$planC"
  # Dirty list now has the fixed plan recorded for the next flush.
  assert_file_exists "trail/dod/.plan-coverage-dirty"
  assert_file_contains "trail/dod/.plan-coverage-dirty" "$planA"
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
run_test test_validator_accepts_numbered_heading_and_backtick_ids
run_test test_validator_engages_on_numbered_heading_uncovered_id
run_test test_validator_detects_missing_design_id
run_test test_validator_detects_unknown_covers_id
run_test test_validator_detects_duplicate_matrix_id
run_test test_validator_detects_uncovered_implemented_id
run_test test_validator_skips_legacy_plan
run_test test_validator_allows_deferred_without_covers

run_test test_hook_appends_dirty_on_invalid_plan_no_validator_call \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_hook_does_not_clear_marker_on_valid_plan \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_test_commit_gate_blocks_commit_on_marker \
  pre-bash-test-commit-gate.sh
run_test test_test_commit_gate_allows_commit_without_marker \
  pre-bash-test-commit-gate.sh
run_test test_hook_appends_multiple_distinct_plans \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_hook_does_not_mutate_existing_marker \
  post-edit-plan-coverage.sh rein-validate-coverage-matrix.py
run_test test_test_commit_gate_blocks_pytest_on_marker \
  pre-bash-test-commit-gate.sh

summary
