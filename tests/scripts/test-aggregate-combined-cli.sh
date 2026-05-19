#!/bin/bash
# tests/scripts/test-aggregate-combined-cli.sh
#
# PERF-1: rein-aggregate-incidents.py combined-execution mode
#
# Verifies acceptance scenario 8 (spec: docs/specs/2026-05-19-cc-feature-adoption.md):
#   --set-session-end false --run-aggregate --count-pending --output-json
#   returns valid JSON with a correct pending_count in a SINGLE subprocess call.
#
# Internal order guarantee: set-session-end → aggregate → count-pending must
# execute inside one process (tested by inspecting the JSON result).
#
# Backward-compat: existing separate flags continue to work (tested in T5–T7).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGGREGATE="$PROJECT_DIR/plugins/rein-core/scripts/rein-aggregate-incidents.py"

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

# Build a minimal project sandbox with trail/incidents structure.
make_sandbox() {
  local sb
  sb=$(mktemp -d "/tmp/perf1-test-XXXXXX")
  mkdir -p "$sb/trail/incidents"
  # .rein/project.json makes bootstrap-check happy (not needed for script but good practice)
  mkdir -p "$sb/.rein"
  printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$sb/.rein/project.json"
  echo "$sb"
}

# Seed N pending incident files in sandbox.
seed_pending_incidents() {
  local sb="$1"
  local n="${2:-1}"
  for i in $(seq 1 "$n"); do
    local hash
    hash=$(printf "deadbeef%04d" "$i" | cut -c1-16)
    local path="$sb/trail/incidents/auto-pre-bash-safety-guard-${hash}.md"
    printf -- '---\nstatus: "pending"\npattern_hash: "%s"\nhook: "pre-bash-safety-guard"\nreason: "test-reason-%d"\ncount: "2"\nfirst_seen: "2026-01-01T00:00:00"\nlast_seen_at: "2026-01-01T00:00:00"\n---\n\n# Incident\n' \
      "$hash" "$i" > "$path"
  done
}

# Seed blocks.jsonl with two lines so aggregate() has something to process.
seed_blocks() {
  local sb="$1"
  local blocks="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-05-19T00:00:00Z","hook":"pre-bash-safety-guard","reason":"dod-missing","target":"foo.py"}\n' >> "$blocks"
  printf '{"ts":"2026-05-19T00:01:00Z","hook":"pre-bash-safety-guard","reason":"dod-missing","target":"bar.py"}\n' >> "$blocks"
}

# ============================================================
# T1: --output-json flag produces valid JSON output
# ============================================================
test_output_json_is_valid_json() {
  begin "T1: --output-json produces valid JSON"
  local sb
  sb=$(make_sandbox)
  seed_pending_incidents "$sb" 2

  local out
  out=$(python3 "$AGGREGATE" \
    --project-dir "$sb" \
    --set-session-end false \
    --run-aggregate \
    --count-pending \
    --output-json 2>/dev/null) || fail "script exited non-zero"

  python3 -c "import json,sys; json.loads(sys.argv[1])" "$out" 2>/dev/null \
    || fail "output is not valid JSON: $out"

  rm -rf "$sb"
  end
}

# ============================================================
# T2: pending_count in JSON matches actual pending files
# ============================================================
test_pending_count_accurate() {
  begin "T2: pending_count in JSON is accurate"
  local sb
  sb=$(make_sandbox)
  seed_pending_incidents "$sb" 3

  local out
  out=$(python3 "$AGGREGATE" \
    --project-dir "$sb" \
    --set-session-end false \
    --run-aggregate \
    --count-pending \
    --output-json 2>/dev/null) || fail "script exited non-zero"

  local count
  count=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['pending_count'])" "$out" 2>/dev/null)

  [ "$count" = "3" ] || fail "expected pending_count=3, got '$count' (raw: $out)"

  rm -rf "$sb"
  end
}

# ============================================================
# T3: JSON schema has required keys
# ============================================================
test_json_schema_keys() {
  begin "T3: JSON output has required keys (pending_count, session_end_set, aggregate_ran)"
  local sb
  sb=$(make_sandbox)

  local out
  out=$(python3 "$AGGREGATE" \
    --project-dir "$sb" \
    --set-session-end false \
    --run-aggregate \
    --count-pending \
    --output-json 2>/dev/null) || fail "script exited non-zero"

  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
required = ['pending_count', 'session_end_set', 'aggregate_ran']
missing = [k for k in required if k not in d]
if missing:
    print('missing keys:', missing, file=sys.stderr)
    sys.exit(1)
" "$out" 2>/dev/null || fail "JSON missing required keys in: $out"

  rm -rf "$sb"
  end
}

# ============================================================
# T4: aggregate_ran=true when --run-aggregate is passed
# ============================================================
test_aggregate_ran_flag() {
  begin "T4: aggregate_ran=true in JSON when --run-aggregate passed"
  local sb
  sb=$(make_sandbox)
  seed_blocks "$sb"

  local out
  out=$(python3 "$AGGREGATE" \
    --project-dir "$sb" \
    --set-session-end false \
    --run-aggregate \
    --count-pending \
    --output-json 2>/dev/null) || fail "script exited non-zero"

  local ran
  ran=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(str(d.get('aggregate_ran',False)).lower())" "$out" 2>/dev/null)
  [ "$ran" = "true" ] || fail "expected aggregate_ran=true, got '$ran'"

  rm -rf "$sb"
  end
}

# ============================================================
# T5: backward-compat — --count-pending alone still prints integer
# ============================================================
test_backward_count_pending() {
  begin "T5: backward-compat — --count-pending alone prints integer"
  local sb
  sb=$(make_sandbox)
  seed_pending_incidents "$sb" 2

  local out
  out=$(python3 "$AGGREGATE" \
    --project-dir "$sb" \
    --count-pending 2>/dev/null) || fail "script exited non-zero"

  # Must be a plain integer, not JSON
  echo "$out" | grep -qE '^[0-9]+$' || fail "expected plain integer, got: $out"
  [ "$out" = "2" ] || fail "expected 2, got $out"

  rm -rf "$sb"
  end
}

# ============================================================
# T6: backward-compat — set-session-end subcommand still works
# ============================================================
test_backward_set_session_end_subcommand() {
  begin "T6: backward-compat — set-session-end subcommand works"
  local sb
  sb=$(make_sandbox)

  python3 "$AGGREGATE" \
    --project-dir "$sb" set-session-end true >/dev/null 2>&1 \
    || fail "set-session-end true failed"

  # Check snapshot file was written
  local snap="$sb/trail/incidents/.last-aggregate-state.json"
  [ -f "$snap" ] || fail "snapshot file not created"

  local val
  val=$(python3 -c "import json; d=json.load(open('$snap')); print(str(d.get('session_end',False)).lower())")
  [ "$val" = "true" ] || fail "session_end should be true, got: $val"

  rm -rf "$sb"
  end
}

# ============================================================
# T7: backward-compat — plain aggregate (no flags) still runs
# ============================================================
test_backward_plain_aggregate() {
  begin "T7: backward-compat — plain invocation still aggregates"
  local sb
  sb=$(make_sandbox)
  seed_blocks "$sb"

  python3 "$AGGREGATE" --project-dir "$sb" >/dev/null 2>&1 \
    || fail "plain aggregate invocation failed"

  # Watermark file should be written
  local wm="$sb/trail/incidents/.last-processed-line"
  [ -f "$wm" ] || fail ".last-processed-line watermark not created"

  rm -rf "$sb"
  end
}

# ============================================================
# T8: session_end_set reflects the value passed to --set-session-end
# ============================================================
test_session_end_set_value_in_json() {
  begin "T8: session_end_set=false in JSON when --set-session-end false"
  local sb
  sb=$(make_sandbox)

  local out
  out=$(python3 "$AGGREGATE" \
    --project-dir "$sb" \
    --set-session-end false \
    --run-aggregate \
    --count-pending \
    --output-json 2>/dev/null) || fail "script exited non-zero"

  local val
  val=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(str(d.get('session_end_set')).lower())" "$out" 2>/dev/null)
  [ "$val" = "false" ] || fail "expected session_end_set=false, got '$val'"

  rm -rf "$sb"
  end
}

# Run all tests
test_output_json_is_valid_json
test_pending_count_accurate
test_json_schema_keys
test_aggregate_ran_flag
test_backward_count_pending
test_backward_set_session_end_subcommand
test_backward_plain_aggregate
test_session_end_set_value_in_json

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
