#!/bin/bash
# tests/hooks/test-stop-incident-gate.sh
# Stop hook incident gate 단위 테스트

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
EMIT_PY="$REAL_PROJECT_DIR/scripts/rein-stop-emit-block.py"

# ---------------------------------------------------------------------------
# Helper: append a block entry to sandbox's blocks.jsonl
# ---------------------------------------------------------------------------
append_jsonl() {
  local hook="$1" reason="$2" target="$3"
  mkdir -p "$SANDBOX/trail/incidents"
  python3 -c "
import json, sys
from datetime import datetime, timezone
print(json.dumps({
  'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S'),
  'hook': sys.argv[1],
  'reason': sys.argv[2],
  'target': sys.argv[3],
}, ensure_ascii=False))
" "$hook" "$reason" "$target" >> "$SANDBOX/trail/incidents/blocks.jsonl"
}

# ---------------------------------------------------------------------------
# Helper: seed valid session state so existing gates (inbox + index.md) pass
# ---------------------------------------------------------------------------
seed_valid_state() {
  local today
  today=$(date +%Y-%m-%d)
  mkdir -p "$SANDBOX/.rein" "$SANDBOX/trail/inbox" "$SANDBOX/trail/dod"
  printf '# session note\n' > "$SANDBOX/trail/inbox/${today}-session.md"
  printf '{"version":1}\n' > "$SANDBOX/.rein/project.json"
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: incident gate
- next: verify
- note: fixture
EOF
  touch "$SANDBOX/trail/index.md"
  # QA 세션 감지 우회: 소스 편집이 있었던 것으로 마킹
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
}

# ---------------------------------------------------------------------------
# Helper: run stop-session-gate.sh inside sandbox (stdin /dev/null)
# ---------------------------------------------------------------------------
run_stop_hook() {
  mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/scripts" "$SANDBOX/trail/dod"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/stop-session-gate.sh" "$SANDBOX/.claude/hooks/"
  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/"
  cp "$REAL_PROJECT_DIR/scripts/rein-stop-emit-block.py" "$SANDBOX/scripts/"
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null)
}

test_emit_block_valid_json() {
  local out
  out=$(python3 "$EMIT_PY" 3 2>&1)
  local decision
  decision=$(echo "$out" | python3 -c "import json, sys; print(json.load(sys.stdin)['decision'])")
  assert_eq "block" "$decision" "decision is block"

  local reason
  reason=$(echo "$out" | python3 -c "import json, sys; print(json.load(sys.stdin)['reason'])")
  echo "$reason" | grep -q '3건' || fail "reason contains pending count"
}

test_emit_block_escapes_safely() {
  python3 "$EMIT_PY" "1'; rm -rf /" > /dev/null 2>&1
  local exit_code=$?
  assert_eq "1" "$exit_code" "bad input exits with 1"
}

test_emit_block_no_args() {
  python3 "$EMIT_PY" > /dev/null 2>&1
  local exit_code=$?
  assert_eq "1" "$exit_code" "missing arg exits with 1"
}

test_emit_block_zero() {
  python3 "$EMIT_PY" 0 > /dev/null 2>&1
  local exit_code=$?
  assert_eq "1" "$exit_code" "zero pending exits with 1"
}

test_emit_block_negative() {
  python3 "$EMIT_PY" -1 > /dev/null 2>&1
  local exit_code=$?
  assert_eq "1" "$exit_code" "negative pending exits with 1"
}

# ---------------------------------------------------------------------------
# Stop hook integration tests
# ---------------------------------------------------------------------------

extract_decision() {
  # Extract 'decision' field from the first valid JSON line in output.
  # The stop hook may emit NOTICE lines (from aggregate 2>&1) before the JSON.
  local input="$1"
  echo "$input" | while IFS= read -r line; do
    local d
    d=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['decision'])" 2>/dev/null) && echo "$d" && return
  done
}

test_stop_blocks_when_pending() {
  seed_valid_state
  append_jsonl "pre-bash-safety-guard" "test-block-pattern" "d1"
  append_jsonl "pre-bash-safety-guard" "test-block-pattern" "d2"

  local out decision
  out=$(run_stop_hook 2>/dev/null)
  decision=$(extract_decision "$out")
  assert_eq "block" "$decision" "Stop hook blocks when pending > 0"
}

test_stop_passes_when_no_pending() {
  seed_valid_state

  local out decision
  out=$(run_stop_hook 2>/dev/null)
  decision=$(extract_decision "$out")
  if [ -z "$decision" ] || [ "$decision" = "none" ]; then
    pass "Stop does not block when pending=0"
  else
    [ "$decision" != "block" ] && pass "Stop does not block when pending=0" || \
      fail "Stop should not block when pending=0"
  fi
}

test_stop_passes_when_deferred() {
  seed_valid_state
  append_jsonl "pre-bash-safety-guard" "test-defer-pattern" "d1"
  append_jsonl "pre-bash-safety-guard" "test-defer-pattern" "d2"
  touch "$SANDBOX/trail/dod/.incident-decision-deferred"

  local out decision
  out=$(run_stop_hook 2>/dev/null)
  decision=$(extract_decision "$out")
  if [ -z "$decision" ] || [ "$decision" = "none" ]; then
    pass "deferred stamp allows pass"
  else
    [ "$decision" != "block" ] && pass "deferred stamp allows pass" || \
      fail "deferred should skip block"
  fi
}

pass() {
  echo "  PASS: $1"
}

# ---------------------------------------------------------------------------
# Helper: alias for seed_valid_state (used by new Stage 2 tests)
# ---------------------------------------------------------------------------
setup_sandbox() {
  seed_valid_state
}

# ---------------------------------------------------------------------------
# Helper: copy stop-hook infra into sandbox
# ---------------------------------------------------------------------------
copy_infra_stop() {
  mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/scripts" "$SANDBOX/trail/dod" "$SANDBOX/trail/incidents"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/stop-session-gate.sh" "$SANDBOX/.claude/hooks/"
  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/"
  cp "$REAL_PROJECT_DIR/scripts/rein-stop-emit-block.py" "$SANDBOX/scripts/"
  cp "$REAL_PROJECT_DIR/scripts/rein-mark-incident-processed.py" "$SANDBOX/scripts/"
}

# ---------------------------------------------------------------------------
# Stage 2 tests: block counter + hash change reset + 3-block meta incident
# ---------------------------------------------------------------------------

test_block_counter_resets_on_hash_change() {
  setup_sandbox
  copy_infra_stop
  append_jsonl "pre-bash-safety-guard" "hash-pattern-A" "d1"
  append_jsonl "pre-bash-safety-guard" "hash-pattern-A" "d2"

  run_stop_hook >/dev/null
  local counter1
  counter1=$(cat "$SANDBOX/trail/dod/.incident-stop-blocks" 2>/dev/null || echo 0)
  assert_eq "1" "$counter1" "counter=1 after first block"

  local auto_a
  auto_a=$(ls "$SANDBOX/trail/incidents/auto-"*.md 2>/dev/null | head -1)
  if [ -n "$auto_a" ]; then
    python3 "$SANDBOX/scripts/rein-mark-incident-processed.py" \
      "$auto_a" declined --reason "test" >/dev/null 2>&1 || true
  fi
  append_jsonl "pre-bash-safety-guard" "hash-pattern-B" "d1"
  append_jsonl "pre-bash-safety-guard" "hash-pattern-B" "d2"

  run_stop_hook >/dev/null
  local counter2
  counter2=$(cat "$SANDBOX/trail/dod/.incident-stop-blocks" 2>/dev/null || echo 0)
  assert_eq "1" "$counter2" "counter resets when pending hashes change"
}

test_three_blocks_require_bypass() {
  setup_sandbox
  copy_infra_stop
  append_jsonl "pre-bash-safety-guard" "stuck-pattern" "d1"
  append_jsonl "pre-bash-safety-guard" "stuck-pattern" "d2"

  run_stop_hook >/dev/null
  run_stop_hook >/dev/null
  run_stop_hook >/dev/null
  local out
  out=$(run_stop_hook 2>&1)
  assert_true "[ -f \"$SANDBOX/trail/incidents/auto-stop-gate-loop.md\" ] || ls \"$SANDBOX/trail/incidents/auto-stop-gate-loop\"*.md >/dev/null 2>&1" \
    "meta incident created on loop"

  touch "$SANDBOX/trail/dod/.skip-stop-gate"
  local out2
  out2=$(run_stop_hook 2>/dev/null)
  [ -z "$out2" ] && pass "bypass consumed" || {
    local d
    d=$(echo "$out2" | python3 -c "import json, sys; print(json.load(sys.stdin).get('decision','none'))" 2>/dev/null)
    [ "$d" != "block" ] && pass "bypass consumed" || fail "bypass did not work"
  }
}

test_meta_incident_does_not_reset_counter() {
  setup_sandbox
  copy_infra_stop
  append_jsonl "pre-bash-safety-guard" "persistent-pattern" "d1"
  append_jsonl "pre-bash-safety-guard" "persistent-pattern" "d2"

  # 4번 연속 block → meta incident 생성 이후에도 counter 는 계속 유지
  run_stop_hook >/dev/null
  run_stop_hook >/dev/null
  run_stop_hook >/dev/null
  run_stop_hook >/dev/null
  run_stop_hook >/dev/null  # 5번째 호출

  local counter
  counter=$(cat "$SANDBOX/trail/dod/.incident-stop-blocks" 2>/dev/null || echo 0)
  # auto-stop-gate-loop.md 가 hash 수집에 포함되지 않아야 하므로 counter 는 5 이상
  assert_true "[ \"$counter\" -ge 4 ]" "counter continues past meta incident creation (got $counter)"
}

run_session_start() {
  mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/scripts" "$SANDBOX/trail/dod" "$SANDBOX/trail/incidents"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh" "$SANDBOX/.claude/hooks/"
  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/"
  (cd "$SANDBOX" && bash .claude/hooks/session-start-load-trail.sh </dev/null 2>/dev/null)
}

test_session_start_clears_session_scope_stamps() {
  setup_sandbox
  run_session_start >/dev/null
  touch "$SANDBOX/trail/dod/.incident-decision-deferred"
  echo "3" > "$SANDBOX/trail/dod/.incident-stop-blocks"
  echo "somehash" > "$SANDBOX/trail/dod/.incident-stop-hashes"

  run_session_start >/dev/null

  assert_true "[ ! -f \"$SANDBOX/trail/dod/.incident-decision-deferred\" ]" "deferred stamp removed"
  assert_true "[ ! -f \"$SANDBOX/trail/dod/.incident-stop-blocks\" ]" "block counter removed"
  assert_true "[ ! -f \"$SANDBOX/trail/dod/.incident-stop-hashes\" ]" "hashes file removed"
}

test_session_start_detects_abnormal_termination() {
  setup_sandbox
  run_session_start >/dev/null

  cat > "$SANDBOX/trail/incidents/.last-aggregate-state.json" <<SNAP
{"watermark":1,"pending_hashes":[],"timestamp":"2026-04-18T00:00:00","session_end":false}
SNAP

  local out
  out=$(run_session_start 2>&1)
  echo "$out" | grep -q "직전 세션 종료가 확인되지 않았습니다" || fail "warning output contains 직전 세션 종료가 확인되지 않았습니다"
}

main() {
  run_test test_emit_block_valid_json
  run_test test_emit_block_escapes_safely
  run_test test_emit_block_no_args
  run_test test_emit_block_zero
  run_test test_emit_block_negative
  run_test test_stop_blocks_when_pending \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py
  run_test test_stop_passes_when_no_pending \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py
  run_test test_stop_passes_when_deferred \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py
  run_test test_block_counter_resets_on_hash_change \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_three_blocks_require_bypass \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_meta_incident_does_not_reset_counter \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_session_start_clears_session_scope_stamps
  run_test test_session_start_detects_abnormal_termination
  summary
}

main "$@"
