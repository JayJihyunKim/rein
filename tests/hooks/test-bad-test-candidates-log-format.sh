#!/bin/bash
# tests/hooks/test-bad-test-candidates-log-format.sh
# Plan B Phase 5 Task 5.2 — bad-test-candidates log writer helper.
#
# Scope IDs covered:
#   - TO-rollout-detection-log-high-only

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRITER_LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/test-oracle-log.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-bad-test-candidates-log-format.sh"
echo ""

# Sandbox with PROJECT_DIR override — the lib writes to
# $PROJECT_DIR/trail/incidents/bad-test-candidates.log. We run the function
# in a subshell with the env var set.

SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/trail/incidents"

# ---- Test 1: High-severity (would_be_high=true) → appended ------------
(
  export PROJECT_DIR="$SANDBOX"
  source "$WRITER_LIB"
  bad_test_log_append "pr=142" "test=test_caution_x" "status=CONTRADICTS" \
    "corroboration=design+scope-id" "would_be_high=true" "confirmed=unknown"
)
log="$SANDBOX/trail/incidents/bad-test-candidates.log"
if [ -s "$log" ] && grep -q "pr=142" "$log" && grep -q "test=test_caution_x" "$log"; then
  _pass "High entry appended to log"
else
  _fail "High entry not appended (log: $(cat $log 2>/dev/null))"
fi
# ISO8601 timestamp check (YYYY-MM-DDTHH:MM:SSZ at line start)
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$log"; then
  _pass "ISO8601 timestamp prefix"
else
  _fail "ISO8601 timestamp missing"
fi

# ---- Test 2: non-High (would_be_high=false) → NOT appended -----------
before_size=$(wc -c < "$log")
(
  export PROJECT_DIR="$SANDBOX"
  source "$WRITER_LIB"
  bad_test_log_append "pr=200" "test=test_low_signal" "status=MATCH" \
    "corroboration=none" "would_be_high=false" "confirmed=unknown"
)
after_size=$(wc -c < "$log")
if [ "$before_size" = "$after_size" ]; then
  _pass "non-High (would_be_high=false) NOT appended"
else
  _fail "non-High appended unexpectedly (before=$before_size, after=$after_size)"
fi

rm -rf "$SANDBOX"

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
