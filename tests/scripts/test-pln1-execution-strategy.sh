#!/usr/bin/env bash
# tests/scripts/test-pln1-execution-strategy.sh
#
# PLN-1 validator regression: `## 실행 전략` 섹션의 parallelizable + workers[].scope
# 파싱 + literal-path-only fail-closed 조건 검증.
#
# 10 cases:
#   (1) 섹션 부재 legacy plan = exit 0 (backward-compat)
#   (2) parallelizable: false 명시 plan = exit 0
#   (3) parallelizable: true + workers + literal scope = exit 0
#   (4) [fail-closed a] parallelizable: true + workers 없음 = exit 2
#   (5) [fail-closed b1] parallelizable: true + worker scope 누락 = exit 2
#   (6) [fail-closed b2] parallelizable: true + worker scope = [] 빈 list = exit 2
#   (7) [fail-closed b3] parallelizable: true + worker scope = inline string = exit 2
#   (8) [c-NOTE] number-only token — DOCUMENTED PARSER GAP: spec lists fail-closed
#        condition (c) "scope element is non-string", but markdown parser reads
#        all list items as strings (e.g. `- 123` becomes the string "123"),
#        so this type-check is not reachable from markdown. Test asserts the
#        documented behavior: a numeric-looking token PASSES (exit 0) because
#        it lacks glob meta-chars and trailing slash. Adding a YAML parser
#        would change semantics, deferred to v2. **Expected exit: 0**.
#   (9) [fail-closed d] parallelizable: true + scope element 에 glob = exit 2
#   (10) [fail-closed e] parallelizable: true + scope element 가 디렉토리 = exit 2
#
# Scope ID: PLN1-VALIDATOR-PARALLELIZABLE-FIELD-PARSING-BACKWARD-COMPAT
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

VALIDATOR="scripts/rein-validate-coverage-matrix.py"
TMPDIR_PLN1=$(mktemp -d -t pln1-validator.XXXXXX)
trap 'rm -rf "$TMPDIR_PLN1"' EXIT

# Minimal design fixture (shared across all cases — same Scope ID)
DESIGN_FIXTURE="$TMPDIR_PLN1/design.md"
cat > "$DESIGN_FIXTURE" << 'EOF'
---
scope-id-version: v2
---

# Fixture Design

## Scope Items

| ID | 설명 |
|----|------|
| FX1-fixture-scope-id-for-pln1-validator-test | fixture scope used by all 10 cases |
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

# Helper: write a plan with a given execution-strategy block (or none).
write_plan() {
  local out="$1"
  local exec_strategy_block="$2"
  cat > "$out" << PLAN
# Fixture Plan

## Design 범위 커버리지 매트릭스

> design ref: $DESIGN_FIXTURE

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| FX1-fixture-scope-id-for-pln1-validator-test | implemented | Phase 1 |

$exec_strategy_block

## Phase 1
covers: [FX1-fixture-scope-id-for-pln1-validator-test]

### Task 1.1
covers: [FX1-fixture-scope-id-for-pln1-validator-test]
PLAN
}

echo "=== test-pln1-execution-strategy ==="

# (1) Section absent → backward-compat = exit 0
PLAN_C1="$TMPDIR_PLN1/c1.md"
write_plan "$PLAN_C1" ""
run_case "(1) absent section → exit 0 backward-compat" 0 "$PLAN_C1"

# (2) parallelizable: false explicit → exit 0
PLAN_C2="$TMPDIR_PLN1/c2.md"
write_plan "$PLAN_C2" "## 실행 전략

parallelizable: false
workers: []
merge_gate: N/A"
run_case "(2) parallelizable: false explicit → exit 0" 0 "$PLAN_C2"

# (3) parallelizable: true + workers + literal scope → exit 0
PLAN_C3="$TMPDIR_PLN1/c3.md"
write_plan "$PLAN_C3" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope:
      - plugins/rein-core/rules/foo.md
      - plugins/rein-core/rules/bar.md
  - name: w2
    scope:
      - plugins/rein-core/agents/baz.md
merge_gate: per-worker review PASS"
run_case "(3) parallelizable: true + valid workers → exit 0" 0 "$PLAN_C3"

# (4) [fail-closed a] parallelizable: true + workers 없음 → exit 2
PLAN_C4="$TMPDIR_PLN1/c4.md"
write_plan "$PLAN_C4" "## 실행 전략

parallelizable: true
workers: []
merge_gate: N/A"
run_case "(4) [a] parallelizable: true + workers empty → exit 2" 2 "$PLAN_C4"

# (5) [b1] parallelizable: true + worker scope key missing → exit 2
PLAN_C5="$TMPDIR_PLN1/c5.md"
write_plan "$PLAN_C5" "## 실행 전략

parallelizable: true
workers:
  - name: w1
merge_gate: N/A"
run_case "(5) [b1] worker scope key missing → exit 2" 2 "$PLAN_C5"

# (6) [b2] parallelizable: true + scope: [] (empty list) → exit 2
PLAN_C6="$TMPDIR_PLN1/c6.md"
write_plan "$PLAN_C6" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope: []
merge_gate: N/A"
run_case "(6) [b2] worker scope empty list → exit 2" 2 "$PLAN_C6"

# (7) [b3] parallelizable: true + scope: inline-string (non-list) → exit 2
PLAN_C7="$TMPDIR_PLN1/c7.md"
write_plan "$PLAN_C7" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope: plugins/rein-core/rules/foo.md
merge_gate: N/A"
run_case "(7) [b3] worker scope non-list (inline string) → exit 2" 2 "$PLAN_C7"

# (8) [c] non-path-like scope token (numeric-only) — design Scope Item requires
#     fail-closed for any element that cannot denote a literal file path. The
#     markdown parser layer yields every list item as a string, so the bare
#     isinstance check (c1) is unreachable; the validator therefore extends (c)
#     with an alpha-or-slash heuristic so number-only tokens like `- 123`
#     also exit 2. This closes the gap that codex Round 1 review identified
#     (5/5 fail-closed conditions actually enforced).
PLAN_C8="$TMPDIR_PLN1/c8.md"
write_plan "$PLAN_C8" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope:
      - 123
merge_gate: N/A"
run_case "(8) [c] number-only token (no alpha / no slash) → exit 2" 2 "$PLAN_C8"

# (9) [d] parallelizable: true + glob meta-char → exit 2
PLAN_C9="$TMPDIR_PLN1/c9.md"
write_plan "$PLAN_C9" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope:
      - plugins/rein-core/rules/*.md
merge_gate: N/A"
run_case "(9) [d] worker scope contains glob (*.md) → exit 2" 2 "$PLAN_C9"

# (10) [e] parallelizable: true + directory path → exit 2
PLAN_C10="$TMPDIR_PLN1/c10.md"
write_plan "$PLAN_C10" "## 실행 전략

parallelizable: true
workers:
  - name: w1
    scope:
      - plugins/rein-core/rules/
merge_gate: N/A"
run_case "(10) [e] worker scope contains directory (trailing /) → exit 2" 2 "$PLAN_C10"

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
