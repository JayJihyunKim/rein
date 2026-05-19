#!/bin/bash
# tests/scripts/test-incident-agent-eligible.sh
#
# Regression tests for the agent_eligible / root_cause classification fields
# added to `scripts/rein-mark-incident-processed.py`.
#
# Verifies:
#   1. Existing incident files without the new fields still round-trip through
#      status updates unchanged (backward compat).
#   2. --set-agent-eligible / --set-root-cause append new frontmatter keys.
#   3. The fields can be updated later without duplicating entries.
#   4. Combined status + classification updates work.
#   5. Invalid values are rejected by argparse.
#   6. Calling with only classification flags (no status arg) updates
#      frontmatter but leaves status unchanged.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$PROJECT_DIR/scripts/rein-mark-incident-processed.py"

TEST_COUNT=0
FAIL_COUNT=0
CURRENT_FAILS=0

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

begin() {
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $1"
}

end() {
  [ "$CURRENT_FAILS" -eq 0 ] && echo "  OK"
}

make_sandbox() {
  local sandbox
  sandbox=$(mktemp -d "/tmp/incident-ae-test-XXXXXX")
  mkdir -p "$sandbox/trail/incidents" "$sandbox/trail/dod" "$sandbox/scripts"
  cp "$TOOL" "$sandbox/scripts/rein-mark-incident-processed.py"
  chmod +x "$sandbox/scripts/rein-mark-incident-processed.py"
  echo "$sandbox"
}

seed_incident() {
  # $1 = sandbox path, $2 = filename (auto-*.md), $3 = extra_frontmatter (optional, multi-line)
  local sb="$1"
  local fname="$2"
  local extra="${3:-}"
  local path="$sb/trail/incidents/$fname"
  {
    echo "---"
    echo 'status: "pending"'
    echo 'pattern_hash: "abc123"'
    echo 'hook: "pre-bash-safety-guard"'
    echo 'reason: "test pattern"'
    echo 'count: "5"'
    [ -n "$extra" ] && echo "$extra"
    echo "---"
    echo ""
    echo "# Incident test"
  } > "$path"
  echo "$path"
}

# ============================================================
# Test 1: backward compat — existing incident (no new fields)
# can still be marked processed without errors
# ============================================================
test_backward_compat_status_only() {
  begin "test_backward_compat_status_only"
  local sb path
  sb=$(make_sandbox)
  path=$(seed_incident "$sb" "auto-pre-bash-safety-guard-abc123.md")

  if ! python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" processed --reason "test" >/dev/null 2>&1; then
    fail "command failed for baseline processed update"
  fi
  if ! grep -q 'status: "processed"' "$path"; then
    fail "status not updated to processed"
  fi
  if grep -q 'agent_eligible' "$path"; then
    fail "agent_eligible unexpectedly appeared"
  fi
  rm -rf "$sb"
  end
}

# ============================================================
# Test 2: --set-agent-eligible appends the field on an existing file
# ============================================================
test_set_agent_eligible_appends_field() {
  begin "test_set_agent_eligible_appends_field"
  local sb path
  sb=$(make_sandbox)
  path=$(seed_incident "$sb" "auto-pre-bash-safety-guard-abc123.md")

  python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" \
    --set-agent-eligible false \
    --set-root-cause bug \
    --reason "regex false positive" >/dev/null 2>&1 \
    || fail "classify-only command failed"

  if ! grep -q '^agent_eligible: false' "$path"; then
    fail "agent_eligible: false missing"
  fi
  if ! grep -q '^root_cause: bug' "$path"; then
    fail "root_cause: bug missing"
  fi
  # Status must NOT change
  if ! grep -q 'status: "pending"' "$path"; then
    fail "status should remain pending"
  fi
  rm -rf "$sb"
  end
}

# ============================================================
# Test 3: updating agent_eligible twice does not duplicate entries
# ============================================================
test_update_field_in_place_no_duplicate() {
  begin "test_update_field_in_place_no_duplicate"
  local sb path
  sb=$(make_sandbox)
  path=$(seed_incident "$sb" "auto-pre-bash-safety-guard-abc123.md")

  python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" \
    --set-agent-eligible unknown --reason "initial" >/dev/null 2>&1
  python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" \
    --set-agent-eligible true --reason "reclassify" >/dev/null 2>&1

  local count
  count=$(grep -c '^agent_eligible:' "$path")
  if [ "$count" -ne 1 ]; then
    fail "expected single agent_eligible line, got $count"
  fi
  if ! grep -q '^agent_eligible: true' "$path"; then
    fail "latest value (true) not applied"
  fi
  rm -rf "$sb"
  end
}

# ============================================================
# Test 4: combined status + classification update in one call
# ============================================================
test_combined_status_and_classification() {
  begin "test_combined_status_and_classification"
  local sb path
  sb=$(make_sandbox)
  path=$(seed_incident "$sb" "auto-pre-bash-safety-guard-abc123.md")

  python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" declined \
    --set-agent-eligible false \
    --set-root-cause bug \
    --reason "hook fix landed" >/dev/null 2>&1 \
    || fail "combined update failed"

  grep -q 'status: "declined"' "$path" || fail "status not declined"
  grep -q '^agent_eligible: false' "$path" || fail "agent_eligible not set"
  grep -q '^root_cause: bug' "$path" || fail "root_cause not set"
  # history entry should be the status transition line
  grep -q 'pending → declined' "$path" || fail "status history entry missing"
  rm -rf "$sb"
  end
}

# ============================================================
# Test 5: invalid agent_eligible value rejected
# ============================================================
test_invalid_agent_eligible_rejected() {
  begin "test_invalid_agent_eligible_rejected"
  local sb path
  sb=$(make_sandbox)
  path=$(seed_incident "$sb" "auto-pre-bash-safety-guard-abc123.md")

  if python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" \
       --set-agent-eligible maybe --reason "invalid" >/dev/null 2>&1; then
    fail "invalid value 'maybe' should have been rejected"
  fi
  rm -rf "$sb"
  end
}

# ============================================================
# Test 6: no args at all → error (must have status or classify flag)
# ============================================================
test_no_args_rejected() {
  begin "test_no_args_rejected"
  local sb path
  sb=$(make_sandbox)
  path=$(seed_incident "$sb" "auto-pre-bash-safety-guard-abc123.md")

  if python3 "$sb/scripts/rein-mark-incident-processed.py" "$path" \
       --reason "nothing" >/dev/null 2>&1; then
    fail "call with no status and no classify flags should fail"
  fi
  rm -rf "$sb"
  end
}

test_backward_compat_status_only
test_set_agent_eligible_appends_field
test_update_field_in_place_no_duplicate
test_combined_status_and_classification
test_invalid_agent_eligible_rejected
test_no_args_rejected

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
