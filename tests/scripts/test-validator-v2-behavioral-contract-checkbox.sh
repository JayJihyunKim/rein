#!/bin/bash
# tests/scripts/test-validator-v2-behavioral-contract-checkbox.sh
# Plan B Phase 4 Task 4.2 — behavioral-contract checkbox enforcement
# (applicability 기준 = plan work unit covers, NOT DoD's own covers).
#
# Scope IDs covered:
#   - TO-behavioral-contract-applicability-mechanical

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$PROJECT_DIR/scripts/rein-validate-coverage-matrix.py"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-validator-v2-behavioral-contract-checkbox.sh"
echo ""

# ---- Fixture builder --------------------------------------------------

make_v2_design_with_kind() {
  # $1 = path. Creates design with scope-id-version v2 + kind column,
  # one bc ID, one unit ID.
  cat > "$1" <<'EOF'
---
scope-id-version: v2
---

# design

## Scope Items

| ID | kind | 설명 |
|----|------|------|
| caution-nav-drawdown | behavioral-contract | caution drawdown < attack |
| unit-level-id | unit | simple unit |
EOF
}

make_v1_design_no_kind() {
  # $1 = path. v1 design (no frontmatter, no kind column).
  cat > "$1" <<'EOF'
# design (v1)

## Scope Items

| ID | 설명 |
|----|------|
| caution-nav-drawdown | caution drawdown |
| unit-level-id | simple unit |
EOF
}

make_plan_with_work_units() {
  # $1 = path, $2 = design ref.
  cat > "$1" <<EOF
# plan

## Design 범위 커버리지 매트릭스

> design ref: $2

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| caution-nav-drawdown | implemented | Phase 2 / Task 2.3 |
| unit-level-id | implemented | Phase 3 / Task 3.1 |

## Phase 2 / Task 2.3
covers: [caution-nav-drawdown]

## Phase 3 / Task 3.1
covers: [unit-level-id]
EOF
}

make_dod() {
  # $1 = path, $2 = plan ref, $3 = work unit, $4 = covers IDs (comma sep),
  # $5 = include_checkbox (yes/no)
  local path="$1"
  local planref="$2"
  local work="$3"
  local covers="$4"
  local cb="$5"
  {
    echo "# dod"
    echo ""
    echo "## 범위 연결"
    echo ""
    echo "plan ref: $planref"
    echo "work unit: $work"
    echo "covers: [$covers]"
    echo ""
    echo "## 완료 기준"
    echo ""
    if [ "$cb" = "yes" ]; then
      echo "- [x] 최소 1개 behavioral-contract test 가 작성됐고 CI 에서 통과"
    else
      echo "- (no checkbox)"
    fi
  } > "$path"
}

# ---- Test A: v2 + bc ID in plan work unit + DoD has no checkbox + warn-only
SANDBOX=$(mktemp -d)
make_v2_design_with_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
make_dod "$SANDBOX/dod-A.md" "plan.md" "Phase 2 / Task 2.3" "caution-nav-drawdown" "no"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-A.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "A: warn-only (default, no state file) → exit 0 for missing checkbox"
else
  _fail "A: expected 0 (warn-only), got $rc (stderr: $(cat $stderr_file))"
fi
if grep -qi 'warn\|WARN' "$stderr_file"; then
  _pass "A: stderr has WARN message"
else
  _fail "A: stderr missing WARN (got: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test A (hard): severity_hard=true → exit 2
SANDBOX=$(mktemp -d)
make_v2_design_with_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
make_dod "$SANDBOX/dod-A.md" "plan.md" "Phase 2 / Task 2.3" "caution-nav-drawdown" "no"
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{"severity_hard": true}' > "$SANDBOX/.claude/.rein-state/test-oracle.json"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-A.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "A (hard): severity_hard=true + missing checkbox → exit 2"
else
  _fail "A (hard): expected 2 got $rc (stderr: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test B: checkbox present → exit 0
SANDBOX=$(mktemp -d)
make_v2_design_with_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
make_dod "$SANDBOX/dod-B.md" "plan.md" "Phase 2 / Task 2.3" "caution-nav-drawdown" "yes"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-B.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "B: checkbox present → exit 0"
else
  _fail "B: expected 0 got $rc (stderr: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test C: work unit has NO bc ID → checkbox not required, exit 0
SANDBOX=$(mktemp -d)
make_v2_design_with_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
make_dod "$SANDBOX/dod-C.md" "plan.md" "Phase 3 / Task 3.1" "unit-level-id" "no"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-C.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "C: plan work unit has no bc ID → no checkbox required, exit 0"
else
  _fail "C: expected 0 got $rc (stderr: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test D (DRIFT attempt): bc ID in plan work unit but DoD omits bc from
# its own covers. Per Plan B v3: applicability is from plan work unit covers,
# NOT DoD's own covers. Loophole must be blocked.
# Use only unit-level-id in DoD covers (to bypass subset check) but work_unit
# refers to Phase 2 / Task 2.3 which in plan has bc ID. DoD covers must be
# subset of matrix implemented, so use unit-level-id only.
SANDBOX=$(mktemp -d)
make_v2_design_with_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
# DoD claims to implement Phase 2 / Task 2.3 but only covers unit-level-id
# (drift — omits bc ID). No checkbox. warn-only.
make_dod "$SANDBOX/dod-D.md" "plan.md" "Phase 2 / Task 2.3" "unit-level-id" "no"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-D.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "D (drift warn-only): exit 0 but WARN expected"
else
  _fail "D (drift warn-only): expected 0 got $rc (stderr: $(cat $stderr_file))"
fi
if grep -qi 'warn\|WARN' "$stderr_file"; then
  _pass "D: stderr has WARN (applicability from plan work unit, NOT DoD covers — loophole blocked)"
else
  _fail "D: stderr missing WARN (got: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test D (hard): same as above with severity_hard=true → exit 2
SANDBOX=$(mktemp -d)
make_v2_design_with_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
make_dod "$SANDBOX/dod-D.md" "plan.md" "Phase 2 / Task 2.3" "unit-level-id" "no"
mkdir -p "$SANDBOX/.claude/.rein-state"
echo '{"severity_hard": true}' > "$SANDBOX/.claude/.rein-state/test-oracle.json"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-D.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "D (drift hard): loophole blocked — exit 2 even though DoD covers omits bc"
else
  _fail "D (drift hard): expected 2 got $rc (stderr: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test E: v1 design (no kind column) → no enforcement, exit 0
SANDBOX=$(mktemp -d)
make_v1_design_no_kind "$SANDBOX/design.md"
make_plan_with_work_units "$SANDBOX/plan.md" "design.md"
make_dod "$SANDBOX/dod-E.md" "plan.md" "Phase 2 / Task 2.3" "caution-nav-drawdown" "no"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod-E.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "E: v1 design (no kind column) → no bc enforcement, exit 0"
else
  _fail "E: expected 0 got $rc (stderr: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
