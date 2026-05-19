#!/bin/bash
# tests/hooks/test-session-end-stamp.sh
# session_end "퇴근 도장" redefinition (Stop hook trap + aggregate locked
# subcommand + SessionStart reset) 단위 테스트.
#
# 검증 대상:
# - rein-aggregate-incidents.py 의 set-session-end subcommand (locked write)
# - rein-aggregate-incidents.py 의 aggregate snapshot 작성 시 session_end 보존
# - stop-session-gate.sh 의 trap EXIT 이 모든 exit 경로에서 session_end=true 마킹
# - session-start-load-trail.sh 의 reset 이 session_end=false 로 갱신

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AGG_PY="$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py"

# Helper: read snapshot.session_end as literal string ("true"/"false"/"missing")
read_snapshot_session_end() {
  local snap="$1"
  if [ ! -f "$snap" ]; then
    echo "missing"
    return
  fi
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get('session_end')
    print('true' if v is True else 'false' if v is False else repr(v))
except Exception as e:
    print('error:' + str(e))
" "$snap"
}

# Helper: copy hook + script into sandbox and run with PROJECT_DIR=$SANDBOX
copy_hooks_into_sandbox() {
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" "$SANDBOX/trail/incidents" "$SANDBOX/trail/dod"
  cp "$REAL_PROJECT_DIR/.claude/hooks/stop-session-gate.sh" "$SANDBOX/.claude/hooks/"
  cp "$REAL_PROJECT_DIR/.claude/hooks/session-start-load-trail.sh" "$SANDBOX/.claude/hooks/"
  cp -R "$REAL_PROJECT_DIR/.claude/hooks/lib/." "$SANDBOX/.claude/hooks/lib/"
  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/"
  cp "$REAL_PROJECT_DIR/scripts/rein-stop-emit-block.py" "$SANDBOX/scripts/" 2>/dev/null || true
  cp "$REAL_PROJECT_DIR/scripts/rein-heal-legacy-pending.py" "$SANDBOX/scripts/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Subcommand: set-session-end true|false
# ---------------------------------------------------------------------------

test_set_session_end_true_creates_snapshot_when_absent() {
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" "snapshot session_end=true"
}

test_set_session_end_false_overwrites_existing_true() {
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true >/dev/null
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end false
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "false" "$(read_snapshot_session_end "$snap")" "session_end toggled true → false"
}

test_set_session_end_preserves_other_fields() {
  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/.last-aggregate-state.json" <<SNAP
{"watermark":42,"pending_hashes":["abc123"],"timestamp":"2026-04-29T00:00:00","session_end":false}
SNAP
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  local watermark
  watermark=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['watermark'])" "$snap")
  assert_eq "42" "$watermark" "watermark preserved"
  local hashes
  hashes=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['pending_hashes'][0])" "$snap")
  assert_eq "abc123" "$hashes" "pending_hashes preserved"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" "session_end updated"
}

test_set_session_end_warns_on_corrupt_snapshot() {
  mkdir -p "$SANDBOX/trail/incidents"
  echo "{not valid json" > "$SANDBOX/trail/incidents/.last-aggregate-state.json"
  local stderr
  stderr=$(python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true 2>&1 >/dev/null)
  echo "$stderr" | grep -qi "WARNING.*unreadable" || fail "stderr should contain WARNING line (got: $stderr)"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "snapshot rewritten with session_end=true after corrupt input"
}

test_set_session_end_invalid_value_rejected() {
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end maybe >/dev/null 2>&1
  local rc=$?
  # argparse choices=["true","false"] 에서 reject → non-zero
  [ "$rc" -ne 0 ] || fail "invalid value should be rejected (got rc=$rc)"
}

# ---------------------------------------------------------------------------
# Aggregate snapshot 작성 시 session_end 보존
# ---------------------------------------------------------------------------

test_aggregate_preserves_existing_session_end_true() {
  mkdir -p "$SANDBOX/trail/incidents"
  # 먼저 session_end=true 로 만들기
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true >/dev/null
  # blocks.jsonl 한 줄 추가 → aggregate 가 새 라인 처리해 snapshot rewrite
  echo '{"ts":"2026-04-29T00:00:00","hook":"pre-bash-safety-guard","reason":"r","target":"t"}' \
    > "$SANDBOX/trail/incidents/blocks.jsonl"
  python3 "$AGG_PY" --project-dir "$SANDBOX" >/dev/null
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" "aggregate preserves session_end=true"
}

test_aggregate_warns_and_defaults_false_on_non_dict_snapshot() {
  mkdir -p "$SANDBOX/trail/incidents"
  # JSON-valid but non-dict (list) — must not crash, must warn
  echo "[]" > "$SANDBOX/trail/incidents/.last-aggregate-state.json"
  echo '{"ts":"2026-04-29T00:00:00","hook":"pre-bash-safety-guard","reason":"r","target":"t"}' \
    > "$SANDBOX/trail/incidents/blocks.jsonl"
  local stderr
  stderr=$(python3 "$AGG_PY" --project-dir "$SANDBOX" 2>&1 >/dev/null)
  echo "$stderr" | grep -qi "WARNING.*not a dict" \
    || fail "stderr should warn 'not a dict' (got: $stderr)"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "false" "$(read_snapshot_session_end "$snap")" \
    "aggregate defaults session_end=false on non-dict snapshot"
}

test_aggregate_warns_and_defaults_false_on_undecodable_bytes_snapshot() {
  mkdir -p "$SANDBOX/trail/incidents"
  # binary 바이트 (UTF-8 디코드 불가) — UnicodeDecodeError 가 except 에 잡혀야 함
  printf '\xff\xfe\x00\x00' > "$SANDBOX/trail/incidents/.last-aggregate-state.json"
  echo '{"ts":"2026-04-29T00:00:00","hook":"pre-bash-safety-guard","reason":"r","target":"t"}' \
    > "$SANDBOX/trail/incidents/blocks.jsonl"
  local stderr
  stderr=$(python3 "$AGG_PY" --project-dir "$SANDBOX" 2>&1 >/dev/null)
  echo "$stderr" | grep -qi "WARNING.*unreadable" \
    || fail "stderr should warn 'unreadable' on binary snapshot (got: $stderr)"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "false" "$(read_snapshot_session_end "$snap")" \
    "aggregate defaults session_end=false on undecodable bytes"
}

test_set_session_end_warns_on_undecodable_bytes_snapshot() {
  mkdir -p "$SANDBOX/trail/incidents"
  printf '\xff\xfe\x00\x00' > "$SANDBOX/trail/incidents/.last-aggregate-state.json"
  local stderr
  stderr=$(python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true 2>&1 >/dev/null)
  echo "$stderr" | grep -qi "WARNING.*unreadable" \
    || fail "set-session-end stderr should warn (got: $stderr)"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "set-session-end rewrites snapshot after undecodable bytes"
}

test_aggregate_warns_and_defaults_false_on_corrupt_json_snapshot() {
  mkdir -p "$SANDBOX/trail/incidents"
  echo "{not valid json" > "$SANDBOX/trail/incidents/.last-aggregate-state.json"
  echo '{"ts":"2026-04-29T00:00:00","hook":"pre-bash-safety-guard","reason":"r","target":"t"}' \
    > "$SANDBOX/trail/incidents/blocks.jsonl"
  local stderr
  stderr=$(python3 "$AGG_PY" --project-dir "$SANDBOX" 2>&1 >/dev/null)
  echo "$stderr" | grep -qi "WARNING.*unreadable" \
    || fail "stderr should warn 'unreadable' (got: $stderr)"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "false" "$(read_snapshot_session_end "$snap")" \
    "aggregate defaults session_end=false on corrupt JSON snapshot"
}

test_aggregate_session_end_defaults_false_when_no_prior_snapshot() {
  mkdir -p "$SANDBOX/trail/incidents"
  echo '{"ts":"2026-04-29T00:00:00","hook":"pre-bash-safety-guard","reason":"r","target":"t"}' \
    > "$SANDBOX/trail/incidents/blocks.jsonl"
  python3 "$AGG_PY" --project-dir "$SANDBOX" >/dev/null
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "false" "$(read_snapshot_session_end "$snap")" "session_end defaults false"
}

# ---------------------------------------------------------------------------
# Stop hook trap EXIT marking
# ---------------------------------------------------------------------------

test_stop_hook_trap_marks_session_end_true_on_no_src_edit_exit() {
  copy_hooks_into_sandbox
  # .session-has-src-edit 마커 없음 → line 92-94 early exit 경로
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null) >/dev/null 2>&1
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "trap marks session_end=true on no-src-edit exit"
}

test_stop_hook_trap_marks_session_end_true_on_normal_completion() {
  copy_hooks_into_sandbox
  # 정상 종료 경로: src-edit 마커 + inbox 오늘자 파일 + index 갱신
  local today
  today=$(date +%Y-%m-%d)
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
  mkdir -p "$SANDBOX/trail/inbox"
  echo "# note" > "$SANDBOX/trail/inbox/${today}-test.md"
  printf '%s\n' "# index" "" "line2" "line3" "line4" "line5" > "$SANDBOX/trail/index.md"
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null) >/dev/null 2>&1
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "trap marks session_end=true on normal completion"
}

test_stop_hook_trap_marks_session_end_true_on_bypass_env() {
  copy_hooks_into_sandbox
  # BYPASS env exit 경로 — src-edit 마커 무관
  (cd "$SANDBOX" && REIN_BYPASS_STOP_GATE=1 bash .claude/hooks/stop-session-gate.sh </dev/null) >/dev/null 2>&1
  local rc=$?
  assert_eq "0" "$rc" "bypass exits 0"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "trap marks session_end=true on BYPASS env exit"
}

test_stop_hook_trap_marks_session_end_true_on_pending_incident_block() {
  copy_hooks_into_sandbox
  # pending-incident block 경로 — src-edit + 정상 inbox/index + pending incident 1건
  local today
  today=$(date +%Y-%m-%d)
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
  mkdir -p "$SANDBOX/trail/inbox"
  echo "# note" > "$SANDBOX/trail/inbox/${today}-test.md"
  printf '%s\n' "# index" "" "line2" "line3" "line4" "line5" > "$SANDBOX/trail/index.md"
  cat > "$SANDBOX/trail/incidents/auto-pre-bash-safety-guard-deadbeef12345678.md" <<INC
---
status: "pending"
pattern_hash: "deadbeef12345678"
hook: "pre-bash-safety-guard"
reason: "test-fixture"
count: "2"
first_seen: "2026-04-29T00:00:00"
last_seen_at: "2026-04-29T00:00:00"
---
INC
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null) >/dev/null 2>&1
  local rc=$?
  assert_eq "0" "$rc" "pending block exits 0 (block JSON via stdout)"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "trap marks session_end=true on pending-incident block exit"
}

test_stop_hook_trap_marks_session_end_true_on_loop_3x_block() {
  copy_hooks_into_sandbox
  # loop-3x block 경로 — pending + counter > 3 + hashes 일치
  local today
  today=$(date +%Y-%m-%d)
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
  mkdir -p "$SANDBOX/trail/inbox"
  echo "# note" > "$SANDBOX/trail/inbox/${today}-test.md"
  printf '%s\n' "# index" "" "line2" "line3" "line4" "line5" > "$SANDBOX/trail/index.md"
  cat > "$SANDBOX/trail/incidents/auto-pre-bash-safety-guard-deadbeef12345678.md" <<INC
---
status: "pending"
pattern_hash: "deadbeef12345678"
hook: "pre-bash-safety-guard"
reason: "test-fixture"
count: "2"
first_seen: "2026-04-29T00:00:00"
last_seen_at: "2026-04-29T00:00:00"
---
INC
  # 카운터 4 + hashes 가 현재 pending 과 일치 → COUNT++ 후 5 (>3 trigger)
  echo "4" > "$SANDBOX/trail/dod/.incident-stop-blocks"
  echo "deadbeef12345678" > "$SANDBOX/trail/dod/.incident-stop-hashes"
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null) >/dev/null 2>&1
  local rc=$?
  assert_eq "0" "$rc" "loop-3x block exits 0"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "trap marks session_end=true on loop-3x block exit"
}

test_stop_hook_trap_marks_session_end_true_on_missing_inbox_index_block() {
  copy_hooks_into_sandbox
  # MISSING block (exit 2) 경로 — src-edit + inbox/index 둘 다 없음, pending 도 없음
  # /tmp 는 git repo 아니라 git 활동 완화도 적용 안 됨
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null) >/dev/null 2>&1
  local rc=$?
  assert_eq "2" "$rc" "MISSING block exits 2"
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" \
    "trap marks session_end=true on MISSING (exit 2) block"
}

# ---------------------------------------------------------------------------
# SessionStart reset
# ---------------------------------------------------------------------------

test_session_start_resets_session_end_to_false() {
  copy_hooks_into_sandbox
  mkdir -p "$SANDBOX/.rein"
  printf '{"version":1}\n' > "$SANDBOX/.rein/project.json"
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: session end
- next: verify
- note: fixture
EOF
  # 직전 stop hook 이 도장 찍은 상태 simulate
  python3 "$AGG_PY" --project-dir "$SANDBOX" set-session-end true >/dev/null
  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_eq "true" "$(read_snapshot_session_end "$snap")" "precondition: true"
  (cd "$SANDBOX" && bash .claude/hooks/session-start-load-trail.sh </dev/null) >/dev/null 2>&1
  assert_eq "false" "$(read_snapshot_session_end "$snap")" \
    "SessionStart reset session_end true → false"
}

main() {
  run_test test_set_session_end_true_creates_snapshot_when_absent
  run_test test_set_session_end_false_overwrites_existing_true
  run_test test_set_session_end_preserves_other_fields
  run_test test_set_session_end_warns_on_corrupt_snapshot
  run_test test_set_session_end_invalid_value_rejected
  run_test test_aggregate_preserves_existing_session_end_true
  run_test test_aggregate_warns_and_defaults_false_on_non_dict_snapshot
  run_test test_aggregate_warns_and_defaults_false_on_corrupt_json_snapshot
  run_test test_aggregate_warns_and_defaults_false_on_undecodable_bytes_snapshot
  run_test test_set_session_end_warns_on_undecodable_bytes_snapshot
  run_test test_aggregate_session_end_defaults_false_when_no_prior_snapshot
  run_test test_stop_hook_trap_marks_session_end_true_on_no_src_edit_exit
  run_test test_stop_hook_trap_marks_session_end_true_on_normal_completion
  run_test test_stop_hook_trap_marks_session_end_true_on_bypass_env
  run_test test_stop_hook_trap_marks_session_end_true_on_pending_incident_block
  run_test test_stop_hook_trap_marks_session_end_true_on_loop_3x_block
  run_test test_stop_hook_trap_marks_session_end_true_on_missing_inbox_index_block
  run_test test_session_start_resets_session_end_to_false
  summary
}

main "$@"
