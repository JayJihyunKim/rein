#!/bin/bash
# tests/hooks/test-state-machine.sh — Cycle X4.C.1
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md
#   §8.2 (X4.C.1 산출물 검증 a~e):
#     T1 (a) state 부재 → read_state default + state 파일 미생성
#     T2 (b) parse 실패 → stderr NOTICE + default 반환
#     T3 (c) write_state 동시 100회 → mtime 갱신 + .tmp 잔존 0 (atomic rename)
#     T4 (d) append_journal 동시 100회 → entry count == 100 (flock 직렬화)
#     T5 (e) state.mode == answer + edit journal entry → read_effective_mode == source_edit

set -u

REAL_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/state-machine.sh"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
CURRENT_FAILS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && return 0
  echo "  FAIL [$label]: expected='$expected' actual='$actual'" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

assert_file_exists() {
  local label="$1" path="$2"
  [ -f "$path" ] && return 0
  echo "  FAIL [$label]: missing $path" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

assert_file_missing() {
  local label="$1" path="$2"
  [ ! -e "$path" ] && return 0
  echo "  FAIL [$label]: should not exist: $path" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}

start_test() { CURRENT_TEST="$1"; CURRENT_FAILS=0; echo "TEST: $CURRENT_TEST"; }
end_test() {
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

mk_sandbox() {
  SANDBOX=$(mktemp -d "/tmp/state-machine-XXXXXX")
  export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
}

rm_sandbox() {
  unset REIN_PROJECT_DIR_OVERRIDE
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# T1 — state absent → default. state file must NOT be auto-created by read_state.
t1_state_absent_returns_default() {
  start_test "T1: state absent → read_state default + state.json not created"
  mk_sandbox
  (
    source "$LIB"
    out=$(read_state)
    # default mode is "answer"
    mode=$(printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("mode",""))')
    if [ "$mode" != "answer" ]; then
      echo "  FAIL [default_mode]: expected answer got '$mode'" >&2
      exit 1
    fi
    # state.json should not have been created.
    if [ -f "$SANDBOX/.rein/state.json" ]; then
      echo "  FAIL [no_autocreate]: read_state should not create state.json" >&2
      exit 1
    fi
    exit 0
  )
  [ $? -eq 0 ] || CURRENT_FAILS=$((CURRENT_FAILS + 1))
  end_test
  rm_sandbox
}

# T2 — malformed JSON → stderr NOTICE + default.
t2_malformed_json_stderr_and_default() {
  start_test "T2: malformed state.json → stderr NOTICE + default mode=answer"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  echo 'NOT JSON {{{' > "$SANDBOX/.rein/state.json"
  out_file=$(mktemp); err_file=$(mktemp)
  (
    source "$LIB"
    read_state
  ) > "$out_file" 2> "$err_file"
  mode=$(python3 -c 'import json,sys;
try:
  d=json.load(open(sys.argv[1]));print(d.get("mode",""))
except Exception:
  print("PARSE_ERR")' "$out_file")
  assert_eq "default_on_malformed" "answer" "$mode"
  if ! grep -q "state-machine:" "$err_file"; then
    echo "  FAIL [notice]: stderr missing state-machine NOTICE" >&2
    cat "$err_file" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  rm -f "$out_file" "$err_file"
  end_test
  rm_sandbox
}

# T3 — concurrent write_state 50x (down from 100 to keep wall time small).
#      All writes must succeed; no .tmp leftover; final state.json valid JSON.
t3_write_state_atomic_under_concurrency() {
  start_test "T3: 100x concurrent write_state → all succeed + no .tmp leftover + valid final"
  mk_sandbox
  # codex Round 1 Medium fix: capture per-PID exit status to detect tmp-name collisions.
  fail_log=$(mktemp)
  (
    source "$LIB"
    pids=""
    for i in $(seq 1 100); do
      (
        write_state "{\"schema_version\":1,\"mode\":\"answer\",\"updated_at\":\"\",\"dirty_files\":[],\"command_class_cache\":{},\"risk_score\":0,\"last_drain_seq\":$i}" \
          >/dev/null 2>&1 || echo "fail:$i" >>"$fail_log"
      ) &
      pids="$pids $!"
    done
    for p in $pids; do wait "$p"; done
  )
  fail_count=$(wc -l < "$fail_log" | tr -d ' ')
  assert_eq "all_writes_succeeded" "0" "$fail_count"
  rm -f "$fail_log"
  leftover=$(find "$SANDBOX/.rein" -maxdepth 1 -name 'state.json.tmp*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "no_tmp_leftover" "0" "$leftover"
  if ! python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SANDBOX/.rein/state.json" 2>/dev/null; then
    echo "  FAIL [valid_final_json]: final state.json not valid JSON" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# T4 — concurrent append_journal 50x → entry count == 50 (flock serializes).
t4_journal_append_no_lost_updates() {
  start_test "T4: 100x concurrent append_journal → entry count == 100 (race-free)"
  mk_sandbox
  (
    source "$LIB"
    pids=""
    for i in $(seq 1 100); do
      ( append_journal edits "edit	/tmp/file-$i.py	source" >/dev/null 2>&1 ) &
      pids="$pids $!"
    done
    for p in $pids; do wait "$p"; done
  )
  if [ ! -f "$SANDBOX/.rein/state-pending-edits.log" ]; then
    echo "  FAIL [journal_exists]: state-pending-edits.log not created" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
    end_test
    rm_sandbox
    return
  fi
  count=$(wc -l < "$SANDBOX/.rein/state-pending-edits.log" | tr -d ' ')
  assert_eq "entry_count_100" "100" "$count"
  uniq_seqs=$(awk -F '\t' '{print $1}' "$SANDBOX/.rein/state-pending-edits.log" | sort -u | wc -l | tr -d ' ')
  assert_eq "all_seqs_distinct" "100" "$uniq_seqs"
  end_test
  rm_sandbox
}

# T5 — effective_mode merges state + journal. state.mode=answer + edit entry → source_edit.
t5_effective_mode_merges_state_and_journal() {
  start_test "T5: state.mode=answer + edit journal entry → effective_mode=source_edit"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"answer","updated_at":"","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":0}
JSON
  printf '1\t2026-05-21T10:00:00Z\tedit\t/tmp/a.py\tsource\n' > "$SANDBOX/.rein/state-pending-edits.log"
  result=$(
    source "$LIB"
    read_effective_mode
  )
  assert_eq "effective_mode" "source_edit" "$result"
  end_test
  rm_sandbox
}

# T6 — codex Round 1 HIGH regression: seq ordering must apply across journal
#      kinds. stop(seq=1) + edit(seq=2) must end as source_edit. Fixed-file-order
#      concatenation would incorrectly return "answer".
t6_effective_mode_applies_strict_seq_order() {
  start_test "T6: stop(seq=1) + edit(seq=2) → effective_mode=source_edit (strict seq order)"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"source_edit","updated_at":"","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":0}
JSON
  printf '1\t2026-05-21T10:00:00Z\tturn-end\n' > "$SANDBOX/.rein/state-pending-stop.log"
  printf '2\t2026-05-21T10:00:01Z\tedit\t/tmp/a.py\tsource\n' > "$SANDBOX/.rein/state-pending-edits.log"
  result=$(
    source "$LIB"
    read_effective_mode
  )
  assert_eq "seq_ordered_mode" "source_edit" "$result"
  end_test
  rm_sandbox
}

# --- X4.C.5 read_fast_path_state behavioral-contract tests ---
# The combined function must return the SAME (valid, effective-mode, dirty-match)
# decisions the X4.C.3 fast-path computed across separate state_is_valid +
# read_effective_mode + read_state-based-match calls. These tests assert the
# combined output's exact values (not just != legacy), per Testing rules.

# Helper: parse "valid<TAB>mode<TAB>match" from read_fast_path_state.
# Sets FP_VALID / FP_MODE / FP_MATCH globals in the caller's shell.
_fp_run() {
  local line
  line=$(source "$LIB"; read_fast_path_state "$@")
  IFS=$'\t' read -r FP_VALID FP_MODE FP_MATCH <<<"$line"
}

# T7 — valid source_edit + dirty hit → (1, source_edit, 1).
t7_fast_path_source_edit_dirty_hit() {
  start_test "T7: read_fast_path_state source_edit + dirty hit → valid=1 mode=source_edit match=1"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"source_edit","updated_at":"2026-05-21T00:00:00Z","dirty_files":[{"path":"/x/foo.py","kind":"source"}],"last_drain_seq":0}
JSON
  _fp_run "/x/foo.py"
  assert_eq "valid" "1" "$FP_VALID"
  assert_eq "mode" "source_edit" "$FP_MODE"
  assert_eq "dirty_match_hit" "1" "$FP_MATCH"
  end_test
  rm_sandbox
}

# T8 — valid source_edit + dirty MISS → match=0 (mode/valid still report state).
t8_fast_path_dirty_miss() {
  start_test "T8: read_fast_path_state source_edit + dirty MISS → valid=1 mode=source_edit match=0"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"source_edit","updated_at":"2026-05-21T00:00:00Z","dirty_files":[{"path":"/x/foo.py","kind":"source"}],"last_drain_seq":0}
JSON
  _fp_run "/x/other.py"
  assert_eq "valid" "1" "$FP_VALID"
  assert_eq "mode" "source_edit" "$FP_MODE"
  assert_eq "dirty_match_miss" "0" "$FP_MATCH"
  end_test
  rm_sandbox
}

# T9 — effective-mode equivalence: state.mode=answer + edit journal → source_edit
#      (same merge read_effective_mode performs). No match_path → match=0.
t9_fast_path_effective_mode_journal_merge() {
  start_test "T9: read_fast_path_state answer + edit journal → valid=1 mode=source_edit match=0"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"answer","updated_at":"2026-05-21T00:00:00Z","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":0}
JSON
  printf '1\t2026-05-21T10:00:00Z\tedit\t/x/a.py\tsource\n' > "$SANDBOX/.rein/state-pending-edits.log"
  _fp_run
  assert_eq "valid" "1" "$FP_VALID"
  assert_eq "merged_mode" "source_edit" "$FP_MODE"
  assert_eq "no_match_path" "0" "$FP_MATCH"
  end_test
  rm_sandbox
}

# T10 — strict seq order parity with read_effective_mode T6: stop(1)+edit(2) →
#       source_edit (fixed-file-order concat would wrongly yield answer).
t10_fast_path_strict_seq_order() {
  start_test "T10: read_fast_path_state stop(seq=1)+edit(seq=2) → mode=source_edit (strict seq order)"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"source_edit","updated_at":"2026-05-21T00:00:00Z","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":0}
JSON
  printf '1\t2026-05-21T10:00:00Z\tturn-end\n' > "$SANDBOX/.rein/state-pending-stop.log"
  printf '2\t2026-05-21T10:00:01Z\tedit\t/x/a.py\tsource\n' > "$SANDBOX/.rein/state-pending-edits.log"
  _fp_run
  assert_eq "seq_ordered_mode" "source_edit" "$FP_MODE"
  assert_eq "valid" "1" "$FP_VALID"
  end_test
  rm_sandbox
}

# T11 — last_drain_seq skip: an entry already drained (seq <= lds) must NOT be
#       re-applied. state.mode=answer + lds=5 + edit(seq=3) → still answer.
t11_fast_path_skips_drained_entries() {
  start_test "T11: read_fast_path_state edit(seq=3) with last_drain_seq=5 → mode stays answer"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"answer","updated_at":"2026-05-21T00:00:00Z","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":5}
JSON
  printf '3\t2026-05-21T10:00:00Z\tedit\t/x/a.py\tsource\n' > "$SANDBOX/.rein/state-pending-edits.log"
  _fp_run
  assert_eq "drained_entry_ignored" "answer" "$FP_MODE"
  assert_eq "valid" "1" "$FP_VALID"
  end_test
  rm_sandbox
}

# T12 — malformed JSON → legacy fallback (valid=0, mode=answer, match=0) with
#       rc=0 (query ran, reports "not valid"), identical to state_is_valid
#       returning false. The verdict rides in the valid field, not the rc.
t12_fast_path_malformed_fallback() {
  start_test "T12: read_fast_path_state malformed JSON → valid=0 mode=answer match=0 + rc=0"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  echo 'NOT JSON {{{' > "$SANDBOX/.rein/state.json"
  local line rc
  line=$(source "$LIB"; read_fast_path_state "/x/foo.py"); rc=$?
  IFS=$'\t' read -r FP_VALID FP_MODE FP_MATCH <<<"$line"
  assert_eq "valid_zero" "0" "$FP_VALID"
  assert_eq "mode_answer_fallback" "answer" "$FP_MODE"
  assert_eq "match_zero" "0" "$FP_MATCH"
  # malformed parses successfully as "not valid" → rc=0 with valid=0 (gate via
  # the valid field, mirroring state_is_valid returning 1/false not a hard error).
  assert_eq "rc_success_with_valid_zero" "0" "$rc"
  end_test
  rm_sandbox
}

# T13 — unknown schema_version → valid=0 (legacy fallback), parity with
#       state_is_valid rejecting non-v1 documents.
t13_fast_path_unknown_schema_fallback() {
  start_test "T13: read_fast_path_state schema_version=2 → valid=0 mode=answer"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":2,"mode":"source_edit","updated_at":"2026-05-21T00:00:00Z","dirty_files":[{"path":"/x/foo.py","kind":"source"}],"last_drain_seq":0}
JSON
  _fp_run "/x/foo.py"
  assert_eq "valid_zero_unknown_schema" "0" "$FP_VALID"
  assert_eq "mode_answer_fallback" "answer" "$FP_MODE"
  assert_eq "match_suppressed" "0" "$FP_MATCH"
  end_test
  rm_sandbox
}

# T14 — corrupt schema-v1 field (mode not in enum) → valid=0, mirroring
#       state_is_valid's R5 enum check. Guards against "answer bogus" leaking.
t14_fast_path_corrupt_field_fallback() {
  start_test "T14: read_fast_path_state schema-v1 with non-enum mode → valid=0"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"answer bogus","updated_at":"","dirty_files":[],"last_drain_seq":0}
JSON
  _fp_run
  assert_eq "valid_zero_corrupt_mode" "0" "$FP_VALID"
  assert_eq "mode_answer_fallback" "answer" "$FP_MODE"
  end_test
  rm_sandbox
}

# T15 — absent state.json → valid=0 fallback (greenfield), parity with the
#       state_is_valid `[ -f "$STATE_FILE" ] || return 1` gate.
t15_fast_path_absent_state_fallback() {
  start_test "T15: read_fast_path_state absent state.json → valid=0 mode=answer match=0"
  mk_sandbox
  _fp_run "/x/foo.py"
  assert_eq "valid_zero_absent" "0" "$FP_VALID"
  assert_eq "mode_answer_fallback" "answer" "$FP_MODE"
  assert_eq "match_zero" "0" "$FP_MATCH"
  end_test
  rm_sandbox
}

# T16 — direct equivalence vs the legacy 3-call sequence (state_is_valid +
#       read_effective_mode + read_state match). Asserts the combined output
#       equals the EXACT values the legacy callers would have computed, for a
#       representative valid source_edit + dirty-hit state.
t16_fast_path_equivalent_to_legacy_calls() {
  start_test "T16: read_fast_path_state == legacy (state_is_valid + read_effective_mode + match)"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/state.json" <<'JSON'
{"schema_version":1,"mode":"source_edit","updated_at":"2026-05-21T00:00:00Z","dirty_files":[{"path":"/x/foo.py","kind":"source"}],"last_drain_seq":0}
JSON
  local target="/x/foo.py"
  # Legacy 3-call results.
  local legacy_valid legacy_mode legacy_state legacy_match
  legacy_valid=$(source "$LIB"; if state_is_valid; then echo 1; else echo 0; fi)
  legacy_mode=$(source "$LIB"; read_effective_mode 2>/dev/null)
  legacy_state=$(source "$LIB"; read_state 2>/dev/null)
  legacy_match=$(python3 -c '
import json, sys
try:
    s = json.loads(sys.argv[1])
except Exception:
    print("0"); sys.exit(0)
t = sys.argv[2]
for d in s.get("dirty_files", []) or []:
    if isinstance(d, dict) and d.get("path") == t:
        print("1"); sys.exit(0)
print("0")' "$legacy_state" "$target")
  # Combined.
  _fp_run "$target"
  assert_eq "valid_equiv" "$legacy_valid" "$FP_VALID"
  assert_eq "mode_equiv" "$legacy_mode" "$FP_MODE"
  assert_eq "match_equiv" "$legacy_match" "$FP_MATCH"
  # Anchor the expected concrete values too (not just self-consistency).
  assert_eq "valid_concrete" "1" "$FP_VALID"
  assert_eq "mode_concrete" "source_edit" "$FP_MODE"
  assert_eq "match_concrete" "1" "$FP_MATCH"
  end_test
  rm_sandbox
}

run_all() {
  t1_state_absent_returns_default
  t2_malformed_json_stderr_and_default
  t3_write_state_atomic_under_concurrency
  t4_journal_append_no_lost_updates
  t5_effective_mode_merges_state_and_journal
  t6_effective_mode_applies_strict_seq_order
  t7_fast_path_source_edit_dirty_hit
  t8_fast_path_dirty_miss
  t9_fast_path_effective_mode_journal_merge
  t10_fast_path_strict_seq_order
  t11_fast_path_skips_drained_entries
  t12_fast_path_malformed_fallback
  t13_fast_path_unknown_schema_fallback
  t14_fast_path_corrupt_field_fallback
  t15_fast_path_absent_state_fallback
  t16_fast_path_equivalent_to_legacy_calls
}

run_all

echo ""
echo "================================"
echo "Tests run: $((PASS_COUNT + FAIL_COUNT))"
echo "Passed:    $PASS_COUNT"
echo "Failed:    $FAIL_COUNT"
echo "================================"
