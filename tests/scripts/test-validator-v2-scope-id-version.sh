#!/bin/bash
# tests/scripts/test-validator-v2-scope-id-version.sh
# Plan B Phase 4 Task 4.1 — scope-id-version frontmatter parser.
#
# Scope IDs covered:
#   - TO-behavioral-contract-applicability-mechanical (version detection portion)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$PROJECT_DIR/scripts/rein-validate-coverage-matrix.py"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-validator-v2-scope-id-version.sh"
echo ""

# ---- Fixture builder helpers -----------------------------------------

make_design() {
  # $1 = path, $2 = frontmatter (empty string to skip)
  local path="$1"
  local fm="$2"
  if [ -n "$fm" ]; then
    cat > "$path" <<EOF
---
$fm
---

# design

## Scope Items

| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  else
    cat > "$path" <<'EOF'
# design (no frontmatter)

## Scope Items

| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  fi
}

make_plan() {
  # $1 = path, $2 = design ref (relative)
  cat > "$1" <<EOF
# plan

## Design 범위 커버리지 매트릭스

> design ref: $2

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
}

# ---- Test 1: v2 design → validator passes + stderr log 'scope-id-version=v2'
SANDBOX=$(mktemp -d)
make_design "$SANDBOX/design-v2.md" "scope-id-version: v2"
make_plan "$SANDBOX/plan-v2.md" "design-v2.md"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" plan plan-v2.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "v2 plan validator → exit 0"
else
  _fail "v2 plan validator → expected 0 got $rc (stderr: $(head -5 $stderr_file))"
fi
if grep -q "scope-id-version=v2" "$stderr_file"; then
  _pass "v2 design → stderr 로그 scope-id-version=v2"
else
  _fail "v2 design → stderr 로그 missing (got: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test 2: v1 design (no frontmatter) → exit 0 + log 'scope-id-version=v1'
SANDBOX=$(mktemp -d)
make_design "$SANDBOX/design-v1.md" ""
make_plan "$SANDBOX/plan-v1.md" "design-v1.md"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" plan plan-v1.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "v1 (legacy, no frontmatter) → exit 0"
else
  _fail "v1 → expected 0 got $rc (stderr: $(head -5 $stderr_file))"
fi
if grep -q "scope-id-version=v1" "$stderr_file"; then
  _pass "v1 legacy → stderr 로그 scope-id-version=v1"
else
  _fail "v1 legacy → stderr 로그 missing (got: $(cat $stderr_file))"
fi
rm -rf "$SANDBOX" "$stderr_file"

# ---- Test 3: unknown scope-id-version → exit 2 fail-closed
SANDBOX=$(mktemp -d)
make_design "$SANDBOX/design-unknown.md" "scope-id-version: v99"
make_plan "$SANDBOX/plan-unknown.md" "design-unknown.md"
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" plan plan-unknown.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "unknown scope-id-version → exit 2 (fail-closed)"
else
  _fail "unknown → expected 2 got $rc"
fi
rm -rf "$SANDBOX" "$stderr_file"

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
