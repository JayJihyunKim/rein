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

# ---- Test 3: BC-INFO1-siblings — poisoned git env must NOT redirect the -----
# ---- PROJECT_DIR git fallback onto a decoy repo ----------------------------
# When PROJECT_DIR is unset/empty, bad_test_log_append falls back to
# `git rev-parse --show-toplevel`. A caller exporting GIT_DIR/GIT_WORK_TREE at an
# attacker-controlled decoy could redirect that discovery and write the incident
# log into the decoy's trail/. The fix wraps the git invocation with
# `env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE`. With
# sanitation, discovery from a non-git cwd finds nothing → falls back to `pwd`
# (the non-git work dir) → NO log is written into the decoy.
if command -v git >/dev/null 2>&1; then
  POISON_BASE=$(mktemp -d)
  WORK="$POISON_BASE/work"      # non-git cwd
  DECOY="$POISON_BASE/decoy"    # poisoned-env target
  mkdir -p "$WORK" "$DECOY"
  ( cd "$DECOY" && git init -q )
  DECOY_REAL="$(cd "$DECOY" && pwd -P)"
  (
    cd "$WORK"
    unset PROJECT_DIR
    export GIT_DIR="$DECOY_REAL/.git" GIT_WORK_TREE="$DECOY_REAL"
    export GIT_CEILING_DIRECTORIES="$POISON_BASE"
    source "$WRITER_LIB"
    bad_test_log_append "pr=999" "test=test_poison" "status=CONTRADICTS" \
      "would_be_high=true" "confirmed=unknown"
  )
  decoy_log="$DECOY_REAL/trail/incidents/bad-test-candidates.log"
  if [ -f "$decoy_log" ]; then
    _fail "BC-INFO1: poisoned GIT env latched decoy — log written into $decoy_log"
  else
    _pass "BC-INFO1: poisoned GIT_DIR/GIT_WORK_TREE did not write log into decoy"
  fi
  rm -rf "$POISON_BASE"
else
  echo "  SKIP: Test 3 (BC-INFO1 env hygiene) — git not installed"
fi

echo ""
echo "## Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 2
exit 0
