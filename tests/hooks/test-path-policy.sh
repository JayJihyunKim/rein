#!/bin/bash
# tests/hooks/test-path-policy.sh
# Unit tests for .claude/hooks/lib/path-policy.sh (Plan A Phase 2 Task 2.1/2.3)
#
# Scope IDs covered:
#   - GI-path-policy-lib
#   - GI-path-policy-input-contract
#   - GI-path-policy-matches-legacy-dated
#
# Scenarios:
#   7 path fixtures × 2 functions = 14 assertions (per plan's matching table)
#   + 1 integration test checking both consumer hooks agree on the same path.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_DIR/.claude/hooks/lib/path-policy.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-path-policy.sh"
echo ""

if [ ! -f "$LIB" ]; then
  _fail "path-policy lib not found: $LIB"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# shellcheck source=../../.claude/hooks/lib/path-policy.sh
. "$LIB"

# _expect <fn> <path> <expected-bool>
# expected: 0 (true / match) or 1 (false / no match)
_expect() {
  local fn="$1"
  local rel="$2"
  local want="$3"
  local label="$4"
  "$fn" "$rel"
  local got=$?
  # is_plan_path / is_spec_path return 0 for true, non-zero for false
  local got_norm=1
  [ "$got" -eq 0 ] && got_norm=0
  if [ "$got_norm" -eq "$want" ]; then
    _pass "$label"
  else
    _fail "$label (want=$want got=$got_norm raw=$got)"
  fi
}

# 매칭 테이블 (Spec A §2 의 예시) — 7 경로 × 2 함수 = 14 assertion
echo "### Matching table (14 assertions)"

# docs/plans/2026-04-20-x.md → plan=true, spec=false
_expect is_plan_path "docs/plans/2026-04-20-x.md" 0 "plan: docs/plans/2026-04-20-x.md → true"
_expect is_spec_path "docs/plans/2026-04-20-x.md" 1 "spec: docs/plans/2026-04-20-x.md → false"

# plans/foo.md → plan=true, spec=false
_expect is_plan_path "plans/foo.md" 0 "plan: plans/foo.md → true"
_expect is_spec_path "plans/foo.md" 1 "spec: plans/foo.md → false"

# docs/2026-04-01/strategy2-backtest-plan.md → plan=true (legacy dated), spec=false
_expect is_plan_path "docs/2026-04-01/strategy2-backtest-plan.md" 0 "plan: legacy dated → true"
_expect is_spec_path "docs/2026-04-01/strategy2-backtest-plan.md" 1 "spec: legacy dated plan → false"

# docs/specs/foo-design.md → plan=false, spec=true
_expect is_plan_path "docs/specs/foo-design.md" 1 "plan: docs/specs/foo-design.md → false"
_expect is_spec_path "docs/specs/foo-design.md" 0 "spec: docs/specs/foo-design.md → true"

# docs/2026-04-01/strategy2-design.md → plan=false, spec=true (legacy dated design)
_expect is_plan_path "docs/2026-04-01/strategy2-design.md" 1 "plan: legacy dated design → false"
_expect is_spec_path "docs/2026-04-01/strategy2-design.md" 0 "spec: legacy dated design → true"

# docs/reports/x.md → plan=false, spec=false
_expect is_plan_path "docs/reports/x.md" 1 "plan: docs/reports/x.md → false"
_expect is_spec_path "docs/reports/x.md" 1 "spec: docs/reports/x.md → false"

# docs/brainstorms/x.md → plan=false, spec=false
_expect is_plan_path "docs/brainstorms/x.md" 1 "plan: docs/brainstorms/x.md → false"
_expect is_spec_path "docs/brainstorms/x.md" 1 "spec: docs/brainstorms/x.md → false"

# Integration (GI-path-policy-lib contract (b)): both consumer hooks must agree
# on the same repo-relative path. We simulate by calling the library from a
# fresh subshell twice with different $PWD — results must match.
echo ""
echo "### Integration: two consumers agree on same path"
(
  cd /tmp
  . "$LIB"
  is_plan_path "docs/plans/sample.md"
  echo "$?" > /tmp/.path-policy-check-1
)
(
  cd "$PROJECT_DIR"
  . "$LIB"
  is_plan_path "docs/plans/sample.md"
  echo "$?" > /tmp/.path-policy-check-2
)
r1=$(cat /tmp/.path-policy-check-1)
r2=$(cat /tmp/.path-policy-check-2)
rm -f /tmp/.path-policy-check-1 /tmp/.path-policy-check-2
if [ "$r1" = "$r2" ]; then
  _pass "consumer A == consumer B on docs/plans/sample.md ($r1)"
else
  _fail "consumer A=$r1 ≠ B=$r2 for docs/plans/sample.md"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
