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
# Regression guard: the normal (bootstrapped) path must keep stamping
# session_end=true. Only un-bootstrapped projects are exempt from stamping —
# degraded and no-src-edit sessions in a bootstrapped project still stamp.
# ---------------------------------------------------------------------------
test_session_end_stamped_on_normal_path() {
  seed_valid_state

  run_stop_hook >/dev/null 2>&1

  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  if [ ! -f "$snap" ]; then
    fail "session_end snapshot not created on the normal (bootstrapped) path"
    return
  fi

  local val
  val=$(python3 -c "import json; d=json.load(open('$snap')); print(str(d.get('session_end', False)).lower())" 2>/dev/null)
  [ "$val" = "true" ] || fail "expected session_end=true on the normal path, got '$val'"
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


# ---------------------------------------------------------------------------
# Raw-sandbox fixtures — bypass sandbox_setup/run_test. That harness always
# pre-creates trail/dod, trail/inbox, trail/incidents (see lib/test-harness.sh
# sandbox_setup), which defeats an "un-bootstrapped, trail/ absent from the
# start" fixture. These invoke the real plugin-SSOT hook file directly with
# CLAUDE_PLUGIN_ROOT pinned, exactly like the BG-I fixtures in
# test-stop-gate-deadlock.sh.
# ---------------------------------------------------------------------------
STOPGATE_PLUGIN_ROOT="$REAL_PROJECT_DIR/plugins/rein-core"
STOPGATE_HOOK="$STOPGATE_PLUGIN_ROOT/hooks/stop-session-gate.sh"

_raw_record_pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $1"
  echo "  OK"
}
_raw_record_fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "RUN $1"
  echo "  FAIL: $2" >&2
}

# Fixture: a project that was never bootstrapped (no .rein/project.json, no
# trail/ at all) must come out of the Stop hook with trail/ still absent and
# exit 0. Reproduces the stop-hook residue bug: the trap used to fire on
# every early exit and unconditionally mkdir trail/incidents/, which flips
# bootstrap-check.sh's tri-marker predicate to a false PARTIAL diagnosis on
# the next prompt.
fixture_unbootstrapped_no_trail_residue() {
  local label="fixture_unbootstrapped_no_trail_residue"
  local dir
  dir="$(mktemp -d "/tmp/stopgate-nobootstrap-XXXXXX")"
  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$dir" \
       CLAUDE_PLUGIN_ROOT="$STOPGATE_PLUGIN_ROOT" \
       bash "$STOPGATE_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"
  if [ "$rc" -ne 0 ]; then
    _raw_record_fail "$label" "expected exit 0, got $rc; stderr: $err"
    rm -rf "$dir"
    return
  fi
  if [ -e "$dir/trail" ]; then
    _raw_record_fail "$label" "trail/ was created for an un-bootstrapped project (residue bug): $(find "$dir/trail" -type f 2>/dev/null | tr '\n' ' ')"
    rm -rf "$dir"
    return
  fi
  rm -rf "$dir"
  _raw_record_pass "$label"
}

# Fixture: the advisory-summary call must read PROJECT_DIR, not the shell's
# cwd. rein-aggregate-incidents.py falls back to "." when --project-dir is
# omitted, so a stray shell cwd with its own noisy trail/incidents/
# blocks.jsonl must never leak into the advisory shown for a different
# project_dir.
fixture_advisory_summary_respects_project_dir_not_cwd() {
  local label="fixture_advisory_summary_respects_project_dir_not_cwd"
  local proj today
  proj="$(mktemp -d "/tmp/stopgate-advisory-proj-XXXXXX")"
  today=$(date +%Y-%m-%d)
  mkdir -p "$proj/trail/dod" "$proj/trail/inbox" "$proj/trail/incidents" "$proj/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.0.0"}' > "$proj/.rein/project.json"
  printf '# session note\n' > "$proj/trail/inbox/${today}-session.md"
  cat > "$proj/trail/index.md" <<'EOF'
# index
- status: test
- current: advisory cwd isolation
- next: verify
- note: fixture
EOF
  touch "$proj/trail/index.md"
  touch "$proj/trail/dod/.session-has-src-edit"

  # PROJECT_DIR's own blocks.jsonl, the same reason repeated >= 2 times (the
  # incidents-to-rule advisory threshold) — this pattern MUST surface, to
  # prove the isolation is real (not just "nothing gets through").
  local j
  for j in 1 2; do
    printf '{"ts":"2026-01-01T00:01:0%dZ","hook":"pre-bash-safety-guard","reason":"project-side-pattern","target":"p%d"}\n' "$j" "$j" \
      >> "$proj/trail/incidents/blocks.jsonl"
  done

  # A DIFFERENT directory standing in for the shell's cwd, with its own
  # noisy blocks.jsonl. A leak surfaces as an [advisory] line quoting this
  # pattern's count.
  local cwd_dir i
  cwd_dir="$(mktemp -d "/tmp/stopgate-advisory-cwd-XXXXXX")"
  mkdir -p "$cwd_dir/trail/incidents"
  for i in 1 2 3 4 5; do
    printf '{"ts":"2026-01-01T00:00:0%dZ","hook":"pre-bash-safety-guard","reason":"cwd-leak-pattern","target":"d%d"}\n' "$i" "$i" \
      >> "$cwd_dir/trail/incidents/blocks.jsonl"
  done

  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$cwd_dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$proj" \
       CLAUDE_PLUGIN_ROOT="$STOPGATE_PLUGIN_ROOT" \
       bash "$STOPGATE_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"
  rm -rf "$proj" "$cwd_dir"

  if printf '%s' "$err" | grep -q "cwd-leak-pattern"; then
    _raw_record_fail "$label" "advisory leaked the shell cwd's incidents into the sandbox project (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "project-side-pattern"; then
    _raw_record_fail "$label" "advisory did not surface PROJECT_DIR's own repeated pattern (stderr: $err)"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    _raw_record_fail "$label" "expected exit 0 on the normal bootstrapped path, got $rc; stderr: $err"
    return
  fi
  _raw_record_pass "$label"
}

# Fixture: a docs-only / read-only session (no source edit, SRC_EDIT_MARKER
# absent) in a bootstrapped, non-degraded project is a NORMAL termination —
# it just had nothing for the incident gate to check. It must still stamp
# session_end=true, or the next SessionStart's abnormal-termination detector
# (session-start-load-trail.sh, reads .last-aggregate-state.json) fires a
# false "직전 세션 종료가 확인되지 않았습니다" notice on every no-edit session.
fixture_docs_only_session_still_stamps_session_end() {
  local label="fixture_docs_only_session_still_stamps_session_end"
  local dir
  dir="$(mktemp -d "/tmp/stopgate-docsonly-XXXXXX")"
  mkdir -p "$dir/trail/incidents" "$dir/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.0.0"}' > "$dir/.rein/project.json"
  # Deliberately do NOT touch trail/dod/.session-has-src-edit.

  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$dir" \
       CLAUDE_PLUGIN_ROOT="$STOPGATE_PLUGIN_ROOT" \
       bash "$STOPGATE_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"

  if [ "$rc" -ne 0 ]; then
    _raw_record_fail "$label" "expected exit 0 (no-src-edit early exit), got $rc; stderr: $err"
    rm -rf "$dir"
    return
  fi

  local snap="$dir/trail/incidents/.last-aggregate-state.json"
  if [ ! -f "$snap" ]; then
    _raw_record_fail "$label" "session_end snapshot not created for a docs-only (no src-edit) session in a bootstrapped project"
    rm -rf "$dir"
    return
  fi
  local val
  val=$(python3 -c "import json; d=json.load(open('$snap')); print(str(d.get('session_end', False)).lower())" 2>/dev/null)
  rm -rf "$dir"
  if [ "$val" != "true" ]; then
    _raw_record_fail "$label" "expected session_end=true for a docs-only session, got '$val'"
    return
  fi
  _raw_record_pass "$label"
}

# Fixture: degraded mode does NOT skip the stamp. The project is still
# bootstrapped, so "the hook ran to completion" is a fact independent of
# degraded status. Skipping the stamp here would leave session_end=false,
# and the next SessionStart's abnormal-termination detector would misreport
# a normal, intentional degraded-mode exit as a crashed session (codex
# round 1 finding — this was a DoD wording mistake, not a runtime need).
fixture_degraded_but_bootstrapped_still_stamped() {
  local label="fixture_degraded_but_bootstrapped_still_stamped"
  local dir
  dir="$(mktemp -d "/tmp/stopgate-degraded-XXXXXX")"
  mkdir -p "$dir/trail/incidents" "$dir/trail/dod" "$dir/.rein" "$dir/.claude/cache"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.0.0"}' > "$dir/.rein/project.json"
  printf 'non-git-dir\n' > "$dir/.claude/cache/.rein-session-degraded"
  touch "$dir/trail/dod/.session-has-src-edit"

  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$dir" \
       CLAUDE_PLUGIN_ROOT="$STOPGATE_PLUGIN_ROOT" \
       bash "$STOPGATE_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"

  if [ "$rc" -ne 0 ]; then
    _raw_record_fail "$label" "expected exit 0 (degraded escape), got $rc; stderr: $err"
    rm -rf "$dir"
    return
  fi
  if ! printf '%s' "$err" | grep -q "degraded mode"; then
    _raw_record_fail "$label" "stderr missing 'degraded mode' (got: $err)"
    rm -rf "$dir"
    return
  fi
  local snap="$dir/trail/incidents/.last-aggregate-state.json"
  if [ ! -f "$snap" ]; then
    _raw_record_fail "$label" "session_end snapshot should exist for a degraded-but-bootstrapped session (still stamped)"
    rm -rf "$dir"
    return
  fi
  local val
  val=$(python3 -c "import json; d=json.load(open('$snap')); print(str(d.get('session_end', False)).lower())" 2>/dev/null)
  rm -rf "$dir"
  if [ "$val" != "true" ]; then
    _raw_record_fail "$label" "expected session_end=true for a degraded-but-bootstrapped session, got '$val'"
    return
  fi
  _raw_record_pass "$label"
}

# Fixture: REIN_BYPASS_STOP_GATE=1 in an un-bootstrapped project must not
# create trail/ residue either. The bypass path writes its own audit line
# directly (not through the aggregate script's set-session-end subcommand),
# so it needs its own bootstrap guard, independent of the trap's.
fixture_bypass_env_unbootstrapped_no_trail_residue() {
  local label="fixture_bypass_env_unbootstrapped_no_trail_residue"
  local dir
  dir="$(mktemp -d "/tmp/stopgate-bypass-nobootstrap-XXXXXX")"
  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$dir" \
       CLAUDE_PLUGIN_ROOT="$STOPGATE_PLUGIN_ROOT" \
       REIN_BYPASS_STOP_GATE=1 \
       bash "$STOPGATE_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"
  if [ "$rc" -ne 0 ]; then
    _raw_record_fail "$label" "expected exit 0, got $rc; stderr: $err"
    rm -rf "$dir"
    return
  fi
  if [ -e "$dir/trail" ]; then
    _raw_record_fail "$label" "trail/ was created by the bypass path for an un-bootstrapped project: $(find "$dir/trail" -type f 2>/dev/null | tr '\n' ' ')"
    rm -rf "$dir"
    return
  fi
  if ! printf '%s' "$err" | grep -q "BYPASS_ENV"; then
    _raw_record_fail "$label" "audit line missing from stderr when un-bootstrapped (got: $err)"
    rm -rf "$dir"
    return
  fi
  rm -rf "$dir"
  _raw_record_pass "$label"
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
  run_test test_session_end_stamped_on_normal_path \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py
  run_test test_block_counter_resets_on_hash_change \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_three_blocks_require_bypass \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_meta_incident_does_not_reset_counter \
    stop-session-gate.sh rein-aggregate-incidents.py rein-stop-emit-block.py rein-mark-incident-processed.py
  run_test test_session_start_clears_session_scope_stamps
  run_test test_session_start_detects_abnormal_termination
  fixture_unbootstrapped_no_trail_residue
  fixture_advisory_summary_respects_project_dir_not_cwd
  fixture_docs_only_session_still_stamps_session_end
  fixture_degraded_but_bootstrapped_still_stamped
  fixture_bypass_env_unbootstrapped_no_trail_residue
  summary
}

main "$@"
