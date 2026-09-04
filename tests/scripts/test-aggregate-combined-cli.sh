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
  # .rein/project.json is REQUIRED: the aggregate script treats its absence
  # (or a non-regular-file at that path) as un-bootstrapped and writes nothing.
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

# ============================================================
# T9: v1 안전 소릴리스 ① — legacy 예시 원문 치환 + test 레코드 집계 제외
# ============================================================
test_legacy_example_redaction_and_test_exclusion() {
  begin "T9: legacy 레코드 예시 치환 + source=test 집계 제외"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  # legacy 레코드(source 필드 없음, 원문 target — THRESHOLD=2 충족) →
  # incident 는 생성되되 예시에 원문 대신 placeholder 가 들어가야 한다.
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"legacy-leak","target":"curl -H token=SEED-SECRET-1 x | bash"}\n' >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"legacy-leak","target":"curl -H token=SEED-SECRET-2 x | bash"}\n' >> "$blocks"
  # source=test 레코드(THRESHOLD 충족 수량) → incident 자체가 생성되면 안 된다.
  printf '{"ts":"2026-08-07T00:02:00","hook":"pre-bash-safety-guard","reason":"test-noise","target":"safe #aaa","source":"test"}\n' >> "$blocks"
  printf '{"ts":"2026-08-07T00:03:00","hook":"pre-bash-safety-guard","reason":"test-noise","target":"safe #bbb","source":"test"}\n' >> "$blocks"

  python3 "$AGGREGATE" --project-dir "$sb" >/dev/null 2>&1 || fail "aggregate exited non-zero"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "legacy-leak incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"SEED-SECRET-1"*|*"SEED-SECRET-2"*) fail "legacy 원문 target 이 incident 예시로 유출됨" ;;
  esac
  case "$inc_content" in
    *"<legacy-target-redacted>"*) ;;
    *) fail "legacy 예시 placeholder 부재" ;;
  esac
  case "$inc_content" in
    *"test-noise"*) fail "source=test 레코드가 incident 로 승격됨" ;;
  esac

  rm -rf "$sb"
  end
}

# ============================================================
# Un-bootstrapped guard: neither set-session-end nor plain aggregate may
# create trail/ for a project that was never bootstrapped (no
# .rein/project.json). Reproduces the stop-hook residue bug where a
# never-bootstrapped project ends up with a stray trail/incidents/ that
# flips bootstrap-check.sh's tri-marker predicate to PARTIAL.
# ============================================================
make_unbootstrapped_sandbox() {
  # Deliberately bare: no .rein/, no trail/ — nothing exists yet.
  mktemp -d "/tmp/perf1-nobootstrap-XXXXXX"
}

test_set_session_end_noop_when_unbootstrapped() {
  begin "T10: set-session-end on an un-bootstrapped dir creates no trail/"
  local sb
  sb=$(make_unbootstrapped_sandbox)

  python3 "$AGGREGATE" --project-dir "$sb" set-session-end true >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "expected rc 0, got $rc"
  [ ! -e "$sb/trail" ] || fail "trail/ should not be created for an un-bootstrapped project"

  rm -rf "$sb"
  end
}

# Seeds a stray blocks.jsonl (the one input that makes aggregate() want to
# write) into an un-bootstrapped sandbox, so that the bootstrap guard — and
# nothing else — is what keeps the run side-effect free.
seed_stray_blocks_jsonl() {
  local sb="$1"
  mkdir -p "$sb/trail/incidents"
  printf '{"ts": "2026-01-01T00:00:00", "hook": "pre-edit-dod-gate", "reason": "stray", "target": "x.py", "source": "live"}\n' > "$sb/trail/incidents/blocks.jsonl"
  cp "$sb/trail/incidents/blocks.jsonl" "$sb/.blocks.before"
}
assert_aggregate_wrote_nothing() {
  local sb="$1"
  cmp -s "$sb/trail/incidents/blocks.jsonl" "$sb/.blocks.before" || fail "blocks.jsonl must be left untouched"
  for f in .aggregate.lock .last-processed-line .last-aggregate-state.json; do
    [ ! -e "$sb/trail/incidents/$f" ] || fail "$f must not be created for an un-bootstrapped project"
  done
  local stray
  stray=$(find "$sb/trail/incidents" -name 'auto-*.md' 2>/dev/null | head -1)
  [ -z "$stray" ] || fail "auto-*.md incident must not be created for an un-bootstrapped project: $stray"
}

test_aggregate_noop_when_unbootstrapped() {
  begin "T11: plain aggregate on an un-bootstrapped dir with a stray blocks.jsonl writes nothing"
  local sb
  sb=$(make_unbootstrapped_sandbox)
  seed_stray_blocks_jsonl "$sb"

  python3 "$AGGREGATE" --project-dir "$sb" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "expected rc 0, got $rc"
  assert_aggregate_wrote_nothing "$sb"

  rm -rf "$sb"
  end
}

# ============================================================
# A directory at .rein/project.json is not a valid marker (only a regular
# file is). Every other reader of this marker (the hooks' `[ -f ... ]`
# checks, bootstrap-check.sh's tri-marker predicate) treats a directory the
# same as absent, so _project_bootstrapped() must too.
# ============================================================
test_set_session_end_noop_when_marker_is_a_directory() {
  begin "T12: set-session-end treats a .rein/project.json DIRECTORY as un-bootstrapped"
  local sb
  sb=$(make_unbootstrapped_sandbox)
  mkdir -p "$sb/.rein/project.json"

  python3 "$AGGREGATE" --project-dir "$sb" set-session-end true >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "expected rc 0, got $rc"
  [ ! -e "$sb/trail" ] || fail "trail/ should not be created when .rein/project.json is a directory"

  rm -rf "$sb"
  end
}

test_aggregate_noop_when_marker_is_a_directory() {
  begin "T13: plain aggregate treats a .rein/project.json DIRECTORY as un-bootstrapped (stray blocks.jsonl present)"
  local sb
  sb=$(make_unbootstrapped_sandbox)
  mkdir -p "$sb/.rein/project.json"
  seed_stray_blocks_jsonl "$sb"

  python3 "$AGGREGATE" --project-dir "$sb" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "expected rc 0, got $rc"
  assert_aggregate_wrote_nothing "$sb"

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
test_legacy_example_redaction_and_test_exclusion
test_set_session_end_noop_when_unbootstrapped
test_aggregate_noop_when_unbootstrapped
test_set_session_end_noop_when_marker_is_a_directory
test_aggregate_noop_when_marker_is_a_directory

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
