#!/bin/bash
# tests/scripts/test-test-oracle-promotion-check.sh
# Plan B Phase 5 Task 5.3 — promotion check metric CLI.
#
# Scope IDs covered:
#   - TO-rollout-promotion-metric-quality

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$PROJECT_DIR/scripts/rein-test-oracle-promotion-check.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-test-oracle-promotion-check.sh"
echo ""

# ---- Fixture builder -------------------------------------------------

make_log_satisfying() {
  # 8 entries within last 4 weeks. 5 confirmed=true, 3 confirmed=false.
  # ratio = 5/8 = 0.625 >= 0.5, count = 5 >= 3 → should pass.
  local log="$1"
  local now=$(date -u +%s)
  local iso day
  {
    echo "# header"
    for i in 1 2 3 4 5; do
      # Use a date a few days ago (within last 4 weeks).
      day=$((now - i * 86400))
      iso=$(python3 -c "
import time
print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime($day)))
")
      echo "$iso | pr=10$i | would-be-high | test=test_$i | CONTRADICTS | corroboration=design | confirmed=true"
    done
    for i in 6 7 8; do
      day=$((now - i * 86400))
      iso=$(python3 -c "
import time
print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime($day)))
")
      echo "$iso | pr=10$i | would-be-high | test=test_$i | CONTRADICTS | corroboration=design | confirmed=false"
    done
  } > "$log"
}

make_log_unsatisfying() {
  # 0 confirmed=true → fail promotion criteria.
  local log="$1"
  local now=$(date -u +%s)
  local iso
  {
    echo "# header"
    for i in 1 2 3; do
      iso=$(python3 -c "
import time
print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime($now - $i * 86400)))
")
      echo "$iso | pr=20$i | would-be-high | test=test_fail | CONTRADICTS | corroboration=none | confirmed=false"
    done
  } > "$log"
}

# ---- Test 1: satisfying fixture → exit 0 ------------------------------
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/trail/incidents"
make_log_satisfying "$SANDBOX/trail/incidents/bad-test-candidates.log"
out=$( (cd "$SANDBOX" && bash "$CHECK" --weeks 4) 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "satisfying fixture → exit 0"
else
  _fail "satisfying fixture → expected 0 got $rc (out: $out)"
fi
if printf '%s' "$out" | grep -q "confirmed_true_count=5"; then
  _pass "stdout has confirmed_true_count=5"
else
  _fail "stdout missing true count (got: $out)"
fi
if printf '%s' "$out" | grep -qE "confirmed_true_ratio=0\.625"; then
  _pass "stdout has correct ratio 0.625"
else
  _fail "stdout missing/wrong ratio (got: $out)"
fi
rm -rf "$SANDBOX"

# ---- Test 2: unsatisfying fixture → exit 1 ----------------------------
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/trail/incidents"
make_log_unsatisfying "$SANDBOX/trail/incidents/bad-test-candidates.log"
out=$( (cd "$SANDBOX" && bash "$CHECK" --weeks 4) 2>&1 )
rc=$?
if [ "$rc" -eq 1 ]; then
  _pass "unsatisfying fixture → exit 1"
else
  _fail "unsatisfying fixture → expected 1 got $rc (out: $out)"
fi
rm -rf "$SANDBOX"

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
