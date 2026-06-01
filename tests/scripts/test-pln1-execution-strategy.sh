#!/usr/bin/env bash
# tests/scripts/test-pln1-execution-strategy.sh
#
# Execution-strategy v2 validator regression. The `## 실행 전략` section is now
# a per-task `tasks[]` shape (each `id` + optional `depends_on: [id...]` +
# `mode: edit_only|mutating` + `scope: [literal path...]`). The validator
# fail-closes (exit 2) on any of conditions (a)-(h); absent section → exit 0.
#
# Cases:
#   (absent)  `## 실행 전략` 부재 → exit 0 (backward-compat)
#   (valid)   2 edit_only (disjoint scope) + 1 mutating (depends_on) → exit 0
#   (a)  id missing → exit 2
#   (a') id duplicate → exit 2
#   (b)  depends_on references nonexistent id → exit 2
#   (c)  cycle A→B→A → exit 2
#   (d)  mode not in {edit_only, mutating} → exit 2
#   (e1) scope key missing → exit 2
#   (e2) scope empty list → exit 2
#   (e3) scope inline non-list → exit 2
#   (f1) scope element glob meta-char → exit 2
#   (f2) scope element directory (trailing /) → exit 2
#   (f3) scope element non-path token (numeric-only) → exit 2
#   (g)  two CONCURRENT edit_only tasks (no depends_on path) with overlapping scope → exit 2
#   (g') two tasks ordered by depends_on sharing the same scope file → exit 0 (allowed)
#   (h)  legacy parallelizable:/workers: shape → exit 2 + stderr migration message
#
# Scope ID: VALIDATOR-V2-TOPO-CYCLE-CONCURRENT-DISJOINT-FAILCLOSED
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

VALIDATOR="scripts/rein-validate-coverage-matrix.py"
TMPDIR_PLN1=$(mktemp -d -t pln1-validator.XXXXXX)
trap 'rm -rf "$TMPDIR_PLN1"' EXIT

# Minimal design fixture (shared across all cases — same Scope ID).
DESIGN_FIXTURE="$TMPDIR_PLN1/design.md"
cat > "$DESIGN_FIXTURE" << 'EOF'
---
scope-id-version: v2
---

# Fixture Design

## Scope Items

| ID | 설명 |
|----|------|
| FX1-fixture-scope-id-for-execstrategy-v2-test | fixture scope used by all cases |
EOF

PASS=0
FAIL=0

run_case() {
  local label="$1"
  local expected_exit="$2"
  local plan_file="$3"

  local actual_exit
  python3 "$VALIDATOR" plan "$plan_file" > /dev/null 2>&1
  actual_exit=$?

  if [ "$actual_exit" = "$expected_exit" ]; then
    echo "  PASS: $label (exit=$actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit=$expected_exit, got=$actual_exit)" >&2
    python3 "$VALIDATOR" plan "$plan_file" 2>&1 | sed 's/^/    /' >&2
    FAIL=$((FAIL + 1))
  fi
}

# run_case_stderr_match: assert exit code AND a stderr substring.
run_case_stderr_match() {
  local label="$1"
  local expected_exit="$2"
  local plan_file="$3"
  local needle="$4"

  local actual_exit out
  out=$(python3 "$VALIDATOR" plan "$plan_file" 2>&1)
  actual_exit=$?

  if [ "$actual_exit" = "$expected_exit" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "  PASS: $label (exit=$actual_exit, stderr matched)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit=$expected_exit + stderr ~ '$needle', got exit=$actual_exit)" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    FAIL=$((FAIL + 1))
  fi
}

# write_plan: wrap a `## 실행 전략` block (or none) in a coverage-valid plan.
write_plan() {
  local out="$1"
  local exec_strategy_block="$2"
  cat > "$out" << PLAN
# Fixture Plan

## Design 범위 커버리지 매트릭스

> design ref: $DESIGN_FIXTURE

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| FX1-fixture-scope-id-for-execstrategy-v2-test | implemented | Phase 1 |

$exec_strategy_block

## Phase 1
covers: [FX1-fixture-scope-id-for-execstrategy-v2-test]

### Task 1.1
covers: [FX1-fixture-scope-id-for-execstrategy-v2-test]
PLAN
}

echo "=== test-pln1-execution-strategy (v2) ==="

# (absent) Section absent → backward-compat = exit 0
PLAN_ABSENT="$TMPDIR_PLN1/absent.md"
write_plan "$PLAN_ABSENT" ""
run_case "(absent) section absent → exit 0" 0 "$PLAN_ABSENT"

# (valid) 2 edit_only (disjoint) + 1 mutating (depends_on) → exit 0
PLAN_VALID="$TMPDIR_PLN1/valid.md"
write_plan "$PLAN_VALID" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/foo.md
  - id: b
    mode: edit_only
    scope:
      - plugins/rein-core/rules/bar.md
  - id: c
    depends_on: [a, b]
    mode: mutating
    scope:
      - scripts/gen.py"
run_case "(valid) 2 edit_only disjoint + 1 mutating depends_on → exit 0" 0 "$PLAN_VALID"

# (a) id missing → exit 2
PLAN_A="$TMPDIR_PLN1/a.md"
write_plan "$PLAN_A" "## 실행 전략

tasks:
  - mode: edit_only
    scope:
      - plugins/rein-core/rules/foo.md"
run_case "(a) id missing → exit 2" 2 "$PLAN_A"

# (a') id duplicate → exit 2
PLAN_AP="$TMPDIR_PLN1/ap.md"
write_plan "$PLAN_AP" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/foo.md
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/bar.md"
run_case "(a') id duplicate → exit 2" 2 "$PLAN_AP"

# (b) depends_on references nonexistent id → exit 2
PLAN_B="$TMPDIR_PLN1/b.md"
write_plan "$PLAN_B" "## 실행 전략

tasks:
  - id: a
    depends_on: [ghost]
    mode: edit_only
    scope:
      - plugins/rein-core/rules/foo.md"
run_case "(b) depends_on unknown id → exit 2" 2 "$PLAN_B"

# (c) cycle A→B→A → exit 2
PLAN_C="$TMPDIR_PLN1/c.md"
write_plan "$PLAN_C" "## 실행 전략

tasks:
  - id: a
    depends_on: [b]
    mode: edit_only
    scope:
      - plugins/rein-core/rules/foo.md
  - id: b
    depends_on: [a]
    mode: edit_only
    scope:
      - plugins/rein-core/rules/bar.md"
run_case "(c) cycle A→B→A → exit 2" 2 "$PLAN_C"

# (d) mode invalid → exit 2
PLAN_D="$TMPDIR_PLN1/d.md"
write_plan "$PLAN_D" "## 실행 전략

tasks:
  - id: a
    mode: readonly
    scope:
      - plugins/rein-core/rules/foo.md"
run_case "(d) mode not edit_only|mutating → exit 2" 2 "$PLAN_D"

# (e1) scope key missing → exit 2
PLAN_E1="$TMPDIR_PLN1/e1.md"
write_plan "$PLAN_E1" "## 실행 전략

tasks:
  - id: a
    mode: edit_only"
run_case "(e1) scope key missing → exit 2" 2 "$PLAN_E1"

# (e2) scope empty list → exit 2
PLAN_E2="$TMPDIR_PLN1/e2.md"
write_plan "$PLAN_E2" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope: []"
run_case "(e2) scope empty list → exit 2" 2 "$PLAN_E2"

# (e3) scope inline non-list → exit 2
PLAN_E3="$TMPDIR_PLN1/e3.md"
write_plan "$PLAN_E3" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope: plugins/rein-core/rules/foo.md"
run_case "(e3) scope inline non-list → exit 2" 2 "$PLAN_E3"

# (f1) scope element glob → exit 2
PLAN_F1="$TMPDIR_PLN1/f1.md"
write_plan "$PLAN_F1" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/*.md"
run_case "(f1) scope glob meta-char → exit 2" 2 "$PLAN_F1"

# (f2) scope element directory → exit 2
PLAN_F2="$TMPDIR_PLN1/f2.md"
write_plan "$PLAN_F2" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/"
run_case "(f2) scope directory (trailing /) → exit 2" 2 "$PLAN_F2"

# (f3) scope element non-path token (numeric-only) → exit 2
PLAN_F3="$TMPDIR_PLN1/f3.md"
write_plan "$PLAN_F3" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - 123"
run_case "(f3) scope non-path token (123) → exit 2" 2 "$PLAN_F3"

# (g) two CONCURRENT edit_only (no depends_on) with overlapping scope → exit 2
PLAN_G="$TMPDIR_PLN1/g.md"
write_plan "$PLAN_G" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/shared.md
  - id: b
    mode: edit_only
    scope:
      - plugins/rein-core/rules/shared.md"
run_case "(g) concurrent edit_only overlapping scope → exit 2" 2 "$PLAN_G"

# (g') two tasks ordered by depends_on sharing the same scope file → exit 0
PLAN_GP="$TMPDIR_PLN1/gp.md"
write_plan "$PLAN_GP" "## 실행 전략

tasks:
  - id: a
    mode: edit_only
    scope:
      - plugins/rein-core/rules/shared.md
  - id: b
    depends_on: [a]
    mode: edit_only
    scope:
      - plugins/rein-core/rules/shared.md"
run_case "(g') depends_on-ordered shared scope → exit 0" 0 "$PLAN_GP"

# (h) legacy parallelizable:/workers: shape → exit 2 + migration message
PLAN_H="$TMPDIR_PLN1/h.md"
write_plan "$PLAN_H" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope:
      - plugins/rein-core/rules/foo.md
merge_gate: N/A"
run_case_stderr_match "(h) legacy parallelizable/workers shape → exit 2 + migration msg" 2 "$PLAN_H" "legacy parallelizable/workers shape"

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
