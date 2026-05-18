#!/bin/bash
# tests/hooks/test-incidents-semi-automation-full.sh
# End-to-end: pending -> Stop block -> mark helper -> Stop pass

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

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

copy_infra() {
  mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/scripts" "$SANDBOX/trail/dod" "$SANDBOX/trail/incidents"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/stop-session-gate.sh" "$SANDBOX/.claude/hooks/"
  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/"
  cp "$REAL_PROJECT_DIR/scripts/rein-stop-emit-block.py" "$SANDBOX/scripts/"
  cp "$REAL_PROJECT_DIR/scripts/rein-mark-incident-processed.py" "$SANDBOX/scripts/"
}

# Seed valid state so stop-session-gate.sh does not exit early or block on
# inbox/index checks — we only want to exercise the incident gate path.
seed_valid_state() {
  local today
  today=$(date +%Y-%m-%d)
  mkdir -p "$SANDBOX/.rein" "$SANDBOX/trail/inbox" "$SANDBOX/trail/dod"
  printf '# session note\n' > "$SANDBOX/trail/inbox/${today}-session.md"
  printf '{"version":1}\n' > "$SANDBOX/.rein/project.json"
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: incident full
- next: verify
- note: fixture
EOF
  touch "$SANDBOX/trail/index.md"
  # QA session detection bypass: mark that source edits occurred
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
}

setup_sandbox() {
  : # sandbox is set up by run_test/sandbox_setup; this is a no-op reset marker
}

run_stop() {
  (cd "$SANDBOX" && bash .claude/hooks/stop-session-gate.sh </dev/null 2>/dev/null)
}

extract_decision() {
  # Grab the last non-empty line of output (Stop hook may emit multiple lines,
  # but the JSON decision is the last).
  echo "$1" | grep -v '^$' | tail -1 | \
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('decision', 'none'))
except Exception:
    print('none')
"
}

pass() {
  echo "  PASS: $1"
}

test_happy_path_pending_processed_then_pass() {
  setup_sandbox
  copy_infra
  seed_valid_state
  append_jsonl "pre-bash-guard" "happy-pattern" "d1"
  append_jsonl "pre-bash-guard" "happy-pattern" "d2"

  # First Stop: should block
  local out1
  out1=$(run_stop)
  local d1
  d1=$(extract_decision "$out1")
  assert_eq "block" "$d1" "first Stop blocks"

  # Simulate user processing via helper
  local auto_file
  auto_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md 2>/dev/null | head -1)
  python3 "$SANDBOX/scripts/rein-mark-incident-processed.py" \
    "$auto_file" declined --reason "test" >/dev/null

  # Second Stop: should pass (no block JSON)
  local out2
  out2=$(run_stop)
  if [ -z "$out2" ]; then
    pass "second Stop passes"
    return
  fi
  local d2
  d2=$(extract_decision "$out2")
  [ "$d2" != "block" ] && pass "second Stop does not block" || fail "second Stop still blocks"
}

test_defer_path() {
  setup_sandbox
  copy_infra
  seed_valid_state
  append_jsonl "pre-bash-guard" "defer-pattern" "d1"
  append_jsonl "pre-bash-guard" "defer-pattern" "d2"

  # First Stop: block
  run_stop >/dev/null

  # Simulate "보류": create deferred stamp
  touch "$SANDBOX/trail/dod/.incident-decision-deferred"

  # Second Stop: should pass (pending still exists but deferred)
  local out
  out=$(run_stop)
  if [ -z "$out" ]; then
    pass "defer allows pass"
    return
  fi
  local d
  d=$(extract_decision "$out")
  [ "$d" != "block" ] && pass "defer allows pass" || fail "defer did not skip block"
}

test_infinite_loop_guard() {
  setup_sandbox
  copy_infra
  seed_valid_state
  append_jsonl "pre-bash-guard" "stuck" "d1"
  append_jsonl "pre-bash-guard" "stuck" "d2"

  for i in 1 2 3 4; do
    run_stop >/dev/null
  done

  # Meta incident exists
  assert_true "[ -f \"$SANDBOX/trail/incidents/auto-stop-gate-loop.md\" ]" \
    "meta incident created on loop"

  # Bypass allows pass
  touch "$SANDBOX/trail/dod/.skip-stop-gate"
  local out
  out=$(run_stop)
  if [ -z "$out" ]; then
    pass "bypass works after loop"
    return
  fi
  local d
  d=$(extract_decision "$out")
  [ "$d" != "block" ] && pass "bypass works after loop" || fail "bypass did not consume"
}

test_abnormal_termination_recovery() {
  setup_sandbox
  copy_infra
  seed_valid_state
  # Also copy session-start hook
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh" "$SANDBOX/.claude/hooks/"

  append_jsonl "pre-bash-guard" "abnormal" "d1"
  append_jsonl "pre-bash-guard" "abnormal" "d2"

  # aggregate 실행 (session_end=false 로 snapshot 기록됨)
  python3 "$SANDBOX/scripts/rein-aggregate-incidents.py" --project-dir "$SANDBOX" >/dev/null 2>&1

  # New session starts — should detect abnormal termination
  local out
  out=$(cd "$SANDBOX" && bash .claude/hooks/session-start-load-trail.sh </dev/null 2>&1)
  echo "$out" | grep -q "직전 세션 종료가 확인되지 않았습니다" || fail "warning emitted on new session"

  # Session scope stamps should be clean (removed by SessionStart)
  assert_true "[ ! -f \"$SANDBOX/trail/dod/.incident-decision-deferred\" ]" "deferred cleared"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  echo "=== Incidents Semi-Automation Full Integration Tests ==="
  echo

  run_test test_happy_path_pending_processed_then_pass \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_defer_path \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py
  run_test test_infinite_loop_guard \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py
  run_test test_abnormal_termination_recovery \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py

  summary
}

main "$@"
