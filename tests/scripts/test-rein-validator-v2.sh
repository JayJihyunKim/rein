#!/bin/bash
# tests/scripts/test-rein-validator-v2.sh
# Unit tests for scripts/rein-validate-coverage-matrix.py v2
# (Plan A Phase 3 Tasks 3.1 / 3.2 / 3.3 / 3.4).
#
# Scope IDs covered:
#   - GI-validator-v2-subcommands
#   - GI-validator-v2-cli-backcompat
#   - GI-validator-v2-dod-covers-subset
#   - GI-validator-v2-parser-single-source (documented; verified by hooks test)
#   - GI-validator-v2-timeout-fail-closed (documented; hook is responsible)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$PROJECT_DIR/scripts/rein-validate-coverage-matrix.py"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-rein-validator-v2.sh"
echo ""

# ---- Test 1: legacy CLI (no subcommand) should still work + emit deprecation warning.
echo "### Test 1: 레거시CLI_하위호환_deprecation경고"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/valid-plan.md" <<'EOF'
# test plan

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
# design

## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" valid-plan.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "legacy CLI valid plan → exit 0"
else
  _fail "legacy CLI valid plan → expected 0, got $rc"
fi
if grep -q 'deprecated' "$stderr_file"; then
  _pass "legacy CLI prints deprecation warning"
else
  _fail "legacy CLI should print deprecation (stderr: $(head -1 "$stderr_file"))"
fi
rm -f "$stderr_file"
rm -rf "$SANDBOX"

# ---- Test 2: `plan <file>` subcommand works.
echo "### Test 2: plan서브커맨드_유효plan_exit0"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan.md" <<'EOF'
# plan

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" plan plan.md >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "plan subcommand valid plan → exit 0"
else
  _fail "plan subcommand valid plan → expected 0, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 3: `dod <file>` with valid covers → exit 0.
echo "### Test 3: dod서브커맨드_유효covers_exit0"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan.md" <<'EOF'
# plan

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | implemented | Phase 2 |

## Phase 1
covers: [A1]

## Phase 2
covers: [A2]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
| A2 | second |
EOF
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD

## 범위 연결

plan ref: plan.md
work unit: Phase 1
covers: [A1]
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "dod valid covers → exit 0"
else
  _fail "dod valid covers → expected 0, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 4: `dod <file>` with unknown covers ID → exit 2.
echo "### Test 4: dod서브커맨드_미지covers_exit2"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan.md" <<'EOF'
# plan

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD

## 범위 연결

plan ref: plan.md
covers: [A1, B99]
EOF
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "dod unknown covers → exit 2"
else
  _fail "dod unknown covers → expected 2, got $rc (stderr: $(head -1 "$stderr_file"))"
fi
rm -f "$stderr_file"
rm -rf "$SANDBOX"

# ---- Test 5: dod covers references deferred ID → exit 2.
echo "### Test 5: dod서브커맨드_deferredcovers_exit2"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan.md" <<'EOF'
# plan

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |
| A2 | deferred | Phase 2 / v2 에서 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
| A2 | second |
EOF
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD

## 범위 연결

plan ref: plan.md
covers: [A2]
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md 2>/dev/null )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "dod deferred covers → exit 2"
else
  _fail "dod deferred covers → expected 2, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 6: dod with no 범위 연결 section → legacy warn, exit 0.
echo "### Test 6: dod서브커맨드_범위연결없음_warn_exit0"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD
- 날짜: 2026-04-21
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "dod no 범위 연결 → exit 0 (legacy)"
else
  _fail "dod no 범위 연결 → expected 0, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 7: Usage error exit code (no args).
echo "### Test 7: usage_에러_exit2"
stderr_file=$(mktemp)
python3 "$VALIDATOR" 2> "$stderr_file"
rc=$?
# Legacy v1 used exit 3 for usage errors; v2 switches to exit 2 (per Spec A
# §3 pseudocode: `print_usage_and_exit(2)`). Accept 2 or 3 during transition.
if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
  _pass "no-args → exit $rc (usage error)"
else
  _fail "no-args → expected 2 or 3, got $rc"
fi
rm -f "$stderr_file"

# ---- Test 8: Unknown subcommand → exit 2 (or 3 legacy).
echo "### Test 8: 미지서브커맨드_exit2"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/junk.md" <<'EOF'
# junk
EOF
python3 "$VALIDATOR" bogus "$SANDBOX/junk.md" 2>/dev/null
rc=$?
if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
  _pass "bogus subcommand → exit $rc"
else
  _fail "bogus subcommand → expected 2 or 3, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 9: Existing plan (governance-integrity) still validates via v2.
echo "### Test 9: 기존plan_플랜커맨드_exit0"
python3 "$VALIDATOR" plan "$PROJECT_DIR/docs/plans/2026-04-21-governance-integrity-plan.md" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "existing governance plan via 'plan' subcommand → exit 0"
else
  _fail "existing governance plan via 'plan' subcommand → expected 0, got $rc"
fi

# ---- Test 10 (H2, 2026-04-22 retro-review-sweep):
# plan ref 의 `(Team A)` annotation suffix 가 strip 되어야 한다.
echo "### Test 10: H2_annotation_Team_A_strip"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan.md" <<'EOF'
# plan

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD

## 범위 연결

plan ref: plan.md (Team A)
covers: [A1]
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "(Team A) annotation stripped → plan_ref resolves → exit 0"
else
  _fail "(Team A) strip failed → expected 0, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 11 (H2): path with parens must be PRESERVED.
echo "### Test 11: H2_path_with_parens_preserved"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan(v2).md" <<'EOF'
# plan v2

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD

## 범위 연결

plan ref: plan(v2).md
covers: [A1]
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "plan(v2).md parens preserved → exit 0"
else
  _fail "plan(v2).md parens stripped → expected 0, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 12 (H2): duplicate plan ref in non-grandfather DoD → exit 2 with
# explicit Phase 2 message.
echo "### Test 12: H2_duplicate_plan_ref_fail_closed"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan-a.md" <<'EOF'
# plan a

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/plan-b.md" <<'EOF'
# plan b

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
cat > "$SANDBOX/dod.md" <<'EOF'
# DoD

## 범위 연결

plan ref: plan-a.md (Team A)
plan ref: plan-b.md (Team B)
covers: [A1]
EOF
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod dod.md 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 2 ]; then
  _pass "duplicate plan ref (non-grandfather) → exit 2"
else
  _fail "duplicate plan ref → expected 2, got $rc"
fi
if grep -q "Phase 2" "$stderr_file"; then
  _pass "error message references 'Phase 2' (integration DoD)"
else
  _fail "error message missing 'Phase 2' reference (stderr: $(head -3 "$stderr_file"))"
fi
rm -f "$stderr_file"
rm -rf "$SANDBOX"

# ---- Test 13b (Round 2, 2026-04-22): `Design Reference:` top-level form
# must be accepted by the validator identically to `> design ref:` per spec
# §5. Parity gap was flagged by codex Round 1.
echo "### Test 13b: H1_Design_Reference_top_level_accepted"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/plan.md" <<'EOF'
# plan

Design Reference: design.md

## Design 범위 커버리지 매트릭스

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
EOF
( cd "$SANDBOX" && python3 "$VALIDATOR" plan plan.md >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "top-level 'Design Reference:' accepted → exit 0"
else
  _fail "top-level 'Design Reference:' rejected → expected 0, got $rc"
fi
rm -rf "$SANDBOX"

# ---- Test 13 (H2): grandfather DoD with duplicate plan refs → WARN + exit 0
# (covers validated as matrix union). The file path must match the explicit
# grandfather list, but the fixture is local to this test so archived trail
# rotation does not make the test depend on a historical active DoD file.
echo "### Test 13: H2_grandfather_warn_exit0"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/trail/dod" "$SANDBOX/docs/plans"
cat > "$SANDBOX/docs/plans/grandfather-a.md" <<'EOF'
# plan a

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
cat > "$SANDBOX/docs/plans/grandfather-b.md" <<'EOF'
# plan b

## Design 범위 커버리지 매트릭스

> design ref: design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| B1 | implemented | Phase 1 |

## Phase 1
covers: [B1]
EOF
cat > "$SANDBOX/docs/plans/design.md" <<'EOF'
## Scope Items

| ID | 설명 |
|----|------|
| A1 | first |
| B1 | second |
EOF
cat > "$SANDBOX/trail/dod/dod-2026-04-21-drift-prevention-implementation.md" <<'EOF'
# DoD

## 범위 연결

plan ref: docs/plans/grandfather-a.md
plan ref: docs/plans/grandfather-b.md
covers: [A1, B1]
EOF
stderr_file=$(mktemp)
( cd "$SANDBOX" && python3 "$VALIDATOR" dod "trail/dod/dod-2026-04-21-drift-prevention-implementation.md" 2> "$stderr_file" )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "grandfather DoD → exit 0 (union of plan matrices)"
else
  _fail "grandfather DoD → expected 0, got $rc (stderr: $(head -3 "$stderr_file"))"
fi
if grep -q "grandfathered" "$stderr_file"; then
  _pass "grandfather path emits WARN with 'grandfathered' marker"
else
  _fail "grandfather WARN missing 'grandfathered' (stderr: $(head -3 "$stderr_file"))"
fi
rm -f "$stderr_file"
rm -rf "$SANDBOX"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
