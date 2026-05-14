#!/bin/bash
# tests/hooks/test-incidents-automation.sh
# Incidents Automation 테스트 스위트
# 커버: aggregate / count_pending / migration / session-start stamp / gate

# NOTE: no set -e here — test functions must handle failures via assert_*

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PY="$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py"
MIGRATE_PY="$REAL_PROJECT_DIR/scripts/rein-migrate-blocks-log.py"

# ---------------------------------------------------------------------------
# Helper: run aggregate script against sandbox
# ---------------------------------------------------------------------------
run_aggregate() {
  python3 "$PY" --project-dir "$SANDBOX" 2>&1
}

run_count() {
  python3 "$PY" --project-dir "$SANDBOX" --count-pending 2>/dev/null
}

run_migrate() {
  python3 "$MIGRATE_PY" "$SANDBOX" 2>&1
}

append_jsonl() {
  # $1=hook, $2=reason, $3=target
  # Use python3 -c to avoid heredoc which can confuse bash in some environments
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

count_incident_files() {
  # count auto-*.md files in incidents dir — returns 0 if none
  local files
  files=$(ls "$SANDBOX/trail/incidents/auto-"*.md 2>/dev/null) || true
  if [ -z "$files" ]; then
    echo 0
  else
    echo "$files" | wc -l | tr -d ' '
  fi
}

make_pending_incident() {
  # $1=filename (without path), $2=hook, $3=reason, $4=hash
  local fname="$1" hook="$2" reason="$3" hash="$4"
  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/$fname" <<EOF
---
status: "pending"
pattern_hash: "${hash}"
hook: "${hook}"
reason: "${reason}"
count: "2"
first_seen: "2026-01-01T00:00:00"
last_seen_at: "2026-01-02T00:00:00"
---

# Incident: ${hook} / ${reason}

## 예시 (최근 최대 5건)

\`\`\`
(no examples)
\`\`\`

## 분석 메모

(incidents-to-rule 스킬이 분석 결과를 여기에 기록)

## 승격 이력

(사용자 결정 기록)
EOF
}

make_incident() {
  # $1=filename, $2=status, $3=hook, $4=reason, $5=hash
  local fname="$1" status="$2" hook="$3" reason="$4" hash="$5"
  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/$fname" <<EOF
---
status: "${status}"
pattern_hash: "${hash}"
hook: "${hook}"
reason: "${reason}"
count: "3"
first_seen: "2026-01-01T00:00:00"
last_seen_at: "2026-01-10T00:00:00"
---

# Incident: ${hook} / ${reason}
EOF
}

compute_hash() {
  # $1=hook, $2=reason
  python3 -c "import hashlib,sys; print(hashlib.sha1(f'{sys.argv[1]}|{sys.argv[2]}'.encode()).hexdigest()[:16])" "$1" "$2"
}

# ---------------------------------------------------------------------------
# 집계 정확성
# ---------------------------------------------------------------------------

test_aggregate_below_threshold() {
  # single occurrence → no incident file (threshold=2)
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "echo x"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 0 ] || fail "expected 0 incident files, got $n"
}

test_aggregate_at_threshold() {
  # 2 occurrences with THRESHOLD=2 → 1 incident file created
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd1"
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 1 ] || fail "expected 1 incident file, got $n"
  # check status=pending in frontmatter
  local inc_file
  inc_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md 2>/dev/null | head -1)
  grep -q '"pending"' "$inc_file" || fail "status should be pending"
  grep -q '^count:' "$inc_file" || fail "count field missing"
}

test_aggregate_multiple_patterns() {
  # 2 different patterns, each 2 occurrences → 2 incident files
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd1"
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd2"
  append_jsonl "pre-edit-dod-gate" "미완료 DoD 없음" "/foo.py"
  append_jsonl "pre-edit-dod-gate" "미완료 DoD 없음" "/bar.py"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 2 ] || fail "expected 2 incident files, got $n"
}

test_reason_with_pipe() {
  # reason contains a pipe character — JSON handles safely
  append_jsonl "pre-bash-guard" "pipe|in|reason" "target"
  append_jsonl "pre-bash-guard" "pipe|in|reason" "target2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 1 ] || fail "expected 1 incident file for pipe-reason, got $n"
  local inc_file
  inc_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md 2>/dev/null | head -1)
  grep -q "pipe|in|reason" "$inc_file" || fail "reason with pipe not preserved"
}

test_reason_with_quote() {
  # reason contains double quotes
  append_jsonl "pre-bash-guard" 'say "hello"' "target"
  append_jsonl "pre-bash-guard" 'say "hello"' "target2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 1 ] || fail "expected 1 incident file for quoted reason, got $n"
}

test_target_with_newline() {
  # target contains newline — JSON handles safely (encoded as \n)
  mkdir -p "$SANDBOX/trail/incidents"
  python3 -c "
import json
from datetime import datetime, timezone
for _ in range(2):
    print(json.dumps({
        'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S'),
        'hook': 'pre-bash-guard',
        'reason': 'newline target',
        'target': 'line1\nline2',
    }, ensure_ascii=False))
" >> "$SANDBOX/trail/incidents/blocks.jsonl"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 1 ] || fail "expected 1 incident file for newline-target, got $n"
}

# ---------------------------------------------------------------------------
# 상태 분기
# ---------------------------------------------------------------------------

test_pending_update() {
  # first aggregate creates pending file; second aggregate updates count
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd1"
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local inc_file
  inc_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md 2>/dev/null | head -1)
  # count line looks like: count: "2"
  local count_before
  count_before=$(grep '^count:' "$inc_file" | grep -oE '[0-9]+' | head -1)

  # add 2 more — second aggregate should update existing pending
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd3"
  append_jsonl "pre-bash-guard" "파이프 쉘 실행" "cmd4"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1

  local count_after
  count_after=$(grep '^count:' "$inc_file" | grep -oE '[0-9]+' | head -1)
  [ "$count_after" -gt "$count_before" ] || fail "count should increase on update (before=$count_before, after=$count_after)"
  # still only 1 file
  local n
  n=$(count_incident_files)
  [ "$n" -eq 1 ] || fail "expected still 1 incident file after update, got $n"
}

test_declined_skip() {
  # If existing file status=declined, new occurrences should create new suffix file
  local hash
  hash=$(compute_hash "pre-bash-guard" "reason-x")
  make_incident "auto-pre-bash-guard-${hash}.md" "declined" "pre-bash-guard" "reason-x" "$hash"

  # Now add 2 new occurrences
  append_jsonl "pre-bash-guard" "reason-x" "target1"
  append_jsonl "pre-bash-guard" "reason-x" "target2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  # Should create a new suffix file (auto-...-2.md or similar)
  local n
  n=$(count_incident_files)
  [ "$n" -eq 2 ] || fail "expected 2 incident files (declined + new), got $n"
}

test_processed_new_suffix() {
  # If existing file status=processed, new occurrences create a new suffix file
  local hash
  hash=$(compute_hash "pre-bash-guard" "reason-y")
  make_incident "auto-pre-bash-guard-${hash}.md" "processed" "pre-bash-guard" "reason-y" "$hash"

  append_jsonl "pre-bash-guard" "reason-y" "target1"
  append_jsonl "pre-bash-guard" "reason-y" "target2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n
  n=$(count_incident_files)
  [ "$n" -eq 2 ] || fail "expected 2 files (processed + new suffix), got $n"
}

# ---------------------------------------------------------------------------
# count_pending
# ---------------------------------------------------------------------------

test_count_pending_empty() {
  local cnt
  cnt=$(run_count)
  [ "$cnt" -eq 0 ] || fail "expected 0 pending, got $cnt"
}

test_count_one_auto_pending() {
  make_pending_incident "auto-pre-bash-guard-abc123.md" "pre-bash-guard" "test reason" "abc123"
  local cnt
  cnt=$(run_count)
  [ "$cnt" -eq 1 ] || fail "expected 1 pending, got $cnt"
}

test_count_one_declined() {
  make_incident "auto-pre-bash-guard-def456.md" "declined" "pre-bash-guard" "declined reason" "def456"
  local cnt
  cnt=$(run_count)
  [ "$cnt" -eq 0 ] || fail "expected 0 pending (declined should not count), got $cnt"
}

test_count_mixed() {
  # 1 pending + 1 declined + 1 processed → only 1 pending counted
  make_pending_incident "auto-hook-aaa111.md" "hook" "r1" "aaa111"
  make_incident "auto-hook-bbb222.md" "declined" "hook" "r2" "bbb222"
  make_incident "auto-hook-ccc333.md" "processed" "hook" "r3" "ccc333"
  local cnt
  cnt=$(run_count)
  [ "$cnt" -eq 1 ] || fail "expected 1 pending in mixed set, got $cnt"
}

test_count_excludes_non_auto_pending() {
  # 루트 trail/incidents/ 의 frontmatter 있는 non-auto 파일은 무시되어야 함 (SKILL.md:51 정책)
  make_pending_incident "auto-hook-xyz999.md" "hook" "r1" "xyz999"
  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/INC-042.md" <<'FM'
---
status: "pending"
title: "legacy manual"
---
# INC-042
FM
  local cnt
  cnt=$(run_count)
  # auto-*.md 1건만 카운트 — INC-042 는 제외
  [ "$cnt" -eq 1 ] || fail "non-auto pending file should be excluded, got $cnt"
}

# ---------------------------------------------------------------------------
# SessionStart stamp management (via session-start-load-trail.sh)
# ---------------------------------------------------------------------------

run_session_start_hook() {
  mkdir -p "$SANDBOX/.rein"
  printf '{"version":1}\n' > "$SANDBOX/.rein/project.json"
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
    bash "$SANDBOX/.claude/hooks/session-start-load-trail.sh" > /dev/null 2>&1 || true
}

test_session_start_creates_stamp() {
  # Setup: 1 pending incident
  make_pending_incident "auto-hook-stamp111.md" "hook" "r" "stamp111"
  echo "# trail Index" > "$SANDBOX/trail/index.md"
  run_session_start_hook
  assert_file_exists "trail/dod/.incident-review-pending"
}

test_session_start_removes_when_zero() {
  # stamp exists but no pending incidents → should be removed
  touch "$SANDBOX/trail/dod/.incident-review-pending"
  echo "# trail Index" > "$SANDBOX/trail/index.md"
  # no incident files → count_pending = 0
  run_session_start_hook
  assert_file_missing "trail/dod/.incident-review-pending"
}

# ---------------------------------------------------------------------------
# pre-edit-dod-gate incident gate
# ---------------------------------------------------------------------------

setup_gate_in_sandbox() {
  # Copy the gate hook into sandbox (already done by run_test)
  # Set up a valid DoD so the DoD gate passes
  mkdir -p "$SANDBOX/trail/dod"
  touch "$SANDBOX/trail/dod/dod-2026-04-15-test.md"
  mkdir -p "$SANDBOX/trail/inbox"
  # Copy aggregate script to sandbox scripts dir
  cp "$PY" "$SANDBOX/scripts/rein-aggregate-incidents.py"
  chmod +x "$SANDBOX/scripts/rein-aggregate-incidents.py"
}

run_gate() {
  # $1 = file path to simulate editing
  local file_path="${1:-/fake/scripts/foo.py}"
  local json_input
  json_input=$(python3 -c "import json,sys; print(json.dumps({'tool_input':{'file_path':sys.argv[1]}}))" "$file_path")
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "$json_input" | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
    bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" \
    > "$tmp_stdout" 2> "$tmp_stderr"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_stdout")
  HOOK_STDERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr"
}

test_gate_blocks_when_pending() {
  setup_gate_in_sandbox
  # Create pending incident + stamp
  make_pending_incident "auto-hook-gate111.md" "hook" "r" "gate111"
  touch "$SANDBOX/trail/dod/.incident-review-pending"
  run_gate "/fake/scripts/test.py"
  assert_exit 2 "gate should block when pending"
  echo "$HOOK_STDERR" | grep -q "BLOCKED" || fail "stderr should contain BLOCKED"
}

test_gate_self_heal_when_zero() {
  setup_gate_in_sandbox
  # stamp exists but no pending incidents
  touch "$SANDBOX/trail/dod/.incident-review-pending"
  # no auto-*.md files → count=0 → self-heal
  run_gate "/fake/scripts/test.py"
  assert_exit 0 "gate should pass when pending=0 (self-heal)"
  assert_file_missing "trail/dod/.incident-review-pending"
}

test_gate_bypass_consumes() {
  setup_gate_in_sandbox
  # Create pending incident + stamp
  make_pending_incident "auto-hook-gate222.md" "hook" "r" "gate222"
  touch "$SANDBOX/trail/dod/.incident-review-pending"
  # Create bypass file
  printf 'reason=테스트 바이패스\n' > "$SANDBOX/trail/dod/.skip-incident-gate"
  run_gate "/fake/scripts/test.py"
  # bypass consumed + gate passes (warning only, no block)
  assert_exit 0 "gate should pass when bypass stamp present"
  assert_file_missing "trail/dod/.skip-incident-gate"
}

# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------

test_migration_empty_log() {
  # blocks.log doesn't exist → migration prints message, no dst created
  local out
  out=$(run_migrate 2>&1) || true
  echo "$out" | grep -q "no blocks.log" || fail "should note missing blocks.log"
  assert_file_missing "trail/incidents/blocks.jsonl"
}

test_migration_valid_lines() {
  mkdir -p "$SANDBOX/trail/incidents"
  printf '2026-01-01T10:00:00|pre-bash-guard|파이프 쉘 실행|echo x\n' \
    > "$SANDBOX/trail/incidents/blocks.log"
  printf '2026-01-02T11:00:00|pre-edit-dod-gate|미완료 DoD 없음|/foo.py\n' \
    >> "$SANDBOX/trail/incidents/blocks.log"
  run_migrate >/dev/null 2>&1
  assert_file_exists "trail/incidents/blocks.jsonl"
  assert_file_exists "trail/incidents/blocks.log.legacy"
  assert_file_missing "trail/incidents/blocks.log"
  # check line count
  local lines
  lines=$(wc -l < "$SANDBOX/trail/incidents/blocks.jsonl" | tr -d ' ')
  [ "$lines" -eq 2 ] || fail "expected 2 JSONL lines, got $lines"
  # validate JSON on first line
  python3 -c "
import json
with open('$SANDBOX/trail/incidents/blocks.jsonl') as f:
    json.loads(f.readline())
print('valid')
" 2>&1 | grep -q "valid" || fail "first line is not valid JSON"
}

test_migration_malformed_skipped() {
  mkdir -p "$SANDBOX/trail/incidents"
  printf 'not-enough-fields\n' > "$SANDBOX/trail/incidents/blocks.log"
  printf '2026-01-01T10:00:00|hook|reason|target\n' >> "$SANDBOX/trail/incidents/blocks.log"
  local out
  out=$(run_migrate 2>&1) || true
  # should mention migration outcome
  echo "$out" | grep -qiE "malformed|skipping|migrated|skipped" \
    || fail "should mention malformed or migration stats"
  assert_file_exists "trail/incidents/blocks.jsonl"
  # only 1 valid line should be in jsonl
  local lines
  lines=$(wc -l < "$SANDBOX/trail/incidents/blocks.jsonl" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "expected 1 valid JSONL line, got $lines"
}

test_migration_dst_exists() {
  mkdir -p "$SANDBOX/trail/incidents"
  printf '2026-01-01T10:00:00|hook|reason|target\n' > "$SANDBOX/trail/incidents/blocks.log"
  # pre-create dst
  printf '{}\n' > "$SANDBOX/trail/incidents/blocks.jsonl"
  local out
  out=$(run_migrate 2>&1) || true
  echo "$out" | grep -q "WARN" || fail "should warn about existing dst"
  # src should be archived
  assert_file_exists "trail/incidents/blocks.log.legacy"
  assert_file_missing "trail/incidents/blocks.log"
  # dst should still be original content (not overwritten)
  grep -q '{}' "$SANDBOX/trail/incidents/blocks.jsonl" || fail "dst should be preserved"
}

# ---------------------------------------------------------------------------
# Watermark / idempotency
# ---------------------------------------------------------------------------

test_watermark_prevents_double_processing() {
  # Run aggregate twice with same data → second run should not create extra files
  append_jsonl "pre-bash-guard" "double-test" "t1"
  append_jsonl "pre-bash-guard" "double-test" "t2"
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n1
  n1=$(count_incident_files)
  # Run again (no new lines added)
  REIN_INCIDENT_THRESHOLD=2 run_aggregate >/dev/null 2>&1
  local n2
  n2=$(count_incident_files)
  [ "$n1" -eq "$n2" ] || fail "second aggregate should not create new files (n1=$n1, n2=$n2)"
}

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

test_aggregate_writes_snapshot() {
  append_jsonl "pre-bash-guard" "test-pattern-snap" "dummy-1"
  append_jsonl "pre-bash-guard" "test-pattern-snap" "dummy-2"
  run_aggregate >/dev/null

  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_true "[ -f \"$snap\" ]" "snapshot file exists"

  local watermark
  watermark=$(python3 -c "import json; print(json.load(open('$snap'))['watermark'])")
  assert_eq "2" "$watermark" "watermark matches blocks.jsonl line count"

  local session_end
  session_end=$(python3 -c "import json; print(json.load(open('$snap'))['session_end'])")
  assert_eq "False" "$session_end" "session_end starts false"

  local hashes_len
  hashes_len=$(python3 -c "import json; print(len(json.load(open('$snap'))['pending_hashes']))")
  assert_eq "1" "$hashes_len" "pending_hashes has one entry"

  local ts
  ts=$(python3 -c "import json; print(json.load(open('$snap')).get('timestamp','MISSING'))")
  assert_true "[ \"$ts\" != 'MISSING' ]" "timestamp field present"
  # Also verify it looks like ISO 8601 (YYYY-MM-DDTHH:MM:SS, 19 chars)
  assert_true "[ ${#ts} -ge 19 ]" "timestamp is ISO 8601 format"
}

test_aggregate_snapshot_empty_pending() {
  # Single block — below THRESHOLD=2, no pending should be created.
  append_jsonl "pre-bash-guard" "below-threshold-pattern" "d1"
  run_aggregate >/dev/null

  local snap="$SANDBOX/trail/incidents/.last-aggregate-state.json"
  assert_true "[ -f \"$snap\" ]" "snapshot written even with no pending"

  local hashes_len
  hashes_len=$(python3 -c "import json; print(len(json.load(open('$snap'))['pending_hashes']))")
  assert_eq "0" "$hashes_len" "empty pending_hashes when nothing reaches threshold"
}

# ---------------------------------------------------------------------------
# rein-mark-incident-processed.py tests
# ---------------------------------------------------------------------------

# Helper: create a pending incident via jsonl + aggregate (2-arg version)
make_jsonl_pending_incident() {
  local hook="$1" reason="$2"
  append_jsonl "$hook" "$reason" "d1"
  append_jsonl "$hook" "$reason" "d2"
  run_aggregate >/dev/null
}

# Helper: call sandbox_setup without hook args (sandbox already created by run_test)
setup_sandbox() {
  : # sandbox is set up by run_test/sandbox_setup; this is a no-op reset marker
}

test_helper_allows_error_status() {
  setup_sandbox
  make_jsonl_pending_incident "pre-bash-guard" "err-test-pattern"
  local auto_file
  auto_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md | head -1)

  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-incident-processed.py" \
    "$auto_file" error --reason "disk full" >/dev/null
  local status
  status=$(grep '^status:' "$auto_file" | sed 's/.*: *//' | tr -d '"')
  assert_eq "error" "$status" "status set to error"
}

test_error_excluded_from_pending() {
  setup_sandbox
  make_jsonl_pending_incident "pre-bash-guard" "err-exclude-pattern"
  local auto_file
  auto_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md | head -1)

  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-incident-processed.py" \
    "$auto_file" error --reason "test" >/dev/null
  local count
  count=$(run_count)
  assert_eq "0" "$count" "error status not counted as pending"
}

test_trace_log_written() {
  setup_sandbox
  make_jsonl_pending_incident "pre-bash-guard" "trace-test-pattern"
  local auto_file
  auto_file=$(ls "$SANDBOX/trail/incidents/auto-"*.md | head -1)

  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-incident-processed.py" \
    "$auto_file" declined --reason "test" >/dev/null
  local trace="$SANDBOX/trail/dod/.incident-skill-trace.log"
  assert_true "[ -f \"$trace\" ]" "trace log created"
  grep -q "rein-mark-incident-processed" "$trace" || fail "trace log contains helper entry"
}

# ---------------------------------------------------------------------------
# rein-mark-agent-candidate.py tests
# ---------------------------------------------------------------------------

test_agent_candidate_create() {
  setup_sandbox
  mkdir -p "$SANDBOX/trail/agent-candidates"
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" create \
    --hash abc123 \
    --source-incident "auto-test-abc123.md" \
    --role-one-liner "테스트 전문" \
    --project-dir "$SANDBOX" >/dev/null
  assert_true "[ -f \"$SANDBOX/trail/agent-candidates/abc123.md\" ]" "candidate file created"
  local decision
  decision=$(grep '^decision:' "$SANDBOX/trail/agent-candidates/abc123.md" | sed 's/.*: *//' | tr -d '"')
  assert_eq "pending" "$decision" "decision starts pending"
}

test_agent_candidate_set_decision() {
  setup_sandbox
  mkdir -p "$SANDBOX/trail/agent-candidates"
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" create \
    --hash xyz789 --source-incident "auto-t.md" --role-one-liner "r" \
    --project-dir "$SANDBOX" >/dev/null
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" decide \
    --hash xyz789 --decision declined --reason "not useful" \
    --project-dir "$SANDBOX" >/dev/null
  local decision
  decision=$(grep '^decision:' "$SANDBOX/trail/agent-candidates/xyz789.md" | sed 's/.*: *//' | tr -d '"')
  assert_eq "declined" "$decision" "decision updated"
}

test_agent_candidate_decide_missing_decision_key() {
  setup_sandbox
  mkdir -p "$SANDBOX/trail/agent-candidates"
  # Create file without decision key
  cat > "$SANDBOX/trail/agent-candidates/nokey.md" <<FRONTEND
---
pattern_hash: "nokey"
source_incident: "x"
evaluated_at: "2026-04-18T00:00:00"
role_one_liner: "role"
---
FRONTEND
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" decide \
    --hash nokey --decision approved \
    --project-dir "$SANDBOX" 2>&1 | grep -q "ERROR" || fail "should error when decision key missing"
}

test_agent_candidate_create_pending_overwrite() {
  setup_sandbox
  mkdir -p "$SANDBOX/trail/agent-candidates"
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" create \
    --hash dup --source-incident "first.md" --role-one-liner "first" \
    --project-dir "$SANDBOX" >/dev/null
  # Same hash, different role — should overwrite (decision=pending)
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" create \
    --hash dup --source-incident "second.md" --role-one-liner "second" \
    --project-dir "$SANDBOX" >/dev/null
  local role
  role=$(grep '^role_one_liner:' "$SANDBOX/trail/agent-candidates/dup.md" | sed 's/.*: *//' | tr -d '"')
  assert_eq "second" "$role" "pending candidate overwritten"
}

test_agent_candidate_skip_when_decided() {
  setup_sandbox
  mkdir -p "$SANDBOX/trail/agent-candidates"
  cat > "$SANDBOX/trail/agent-candidates/done123.md" <<FRONTEND
---
pattern_hash: "done123"
source_incident: "auto-t.md"
decision: "declined"
evaluated_at: "2026-04-18T00:00:00"
role_one_liner: "role"
---
FRONTEND
  python3 "$REAL_PROJECT_DIR/scripts/rein-mark-agent-candidate.py" create \
    --hash done123 --source-incident "auto-t.md" --role-one-liner "r" \
    --project-dir "$SANDBOX" 2>&1 | grep -q "SKIP" || fail "skip when already decided"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  echo "=== Incidents Automation Tests ==="
  echo

  # Aggregate accuracy
  run_test test_aggregate_below_threshold "rein-aggregate-incidents.py"
  run_test test_aggregate_at_threshold "rein-aggregate-incidents.py"
  run_test test_aggregate_multiple_patterns "rein-aggregate-incidents.py"
  run_test test_reason_with_pipe "rein-aggregate-incidents.py"
  run_test test_reason_with_quote "rein-aggregate-incidents.py"
  run_test test_target_with_newline "rein-aggregate-incidents.py"

  # Status branching
  run_test test_pending_update "rein-aggregate-incidents.py"
  run_test test_declined_skip "rein-aggregate-incidents.py"
  run_test test_processed_new_suffix "rein-aggregate-incidents.py"

  # count_pending
  run_test test_count_pending_empty "rein-aggregate-incidents.py"
  run_test test_count_one_auto_pending "rein-aggregate-incidents.py"
  run_test test_count_one_declined "rein-aggregate-incidents.py"
  run_test test_count_mixed "rein-aggregate-incidents.py"
  run_test test_count_excludes_non_auto_pending "rein-aggregate-incidents.py"

  # SessionStart stamp
  run_test test_session_start_creates_stamp \
    "session-start-load-trail.sh" "rein-aggregate-incidents.py"
  run_test test_session_start_removes_when_zero \
    "session-start-load-trail.sh" "rein-aggregate-incidents.py"

  # Gate tests
  run_test test_gate_blocks_when_pending \
    "pre-edit-dod-gate.sh" "rein-aggregate-incidents.py"
  run_test test_gate_self_heal_when_zero \
    "pre-edit-dod-gate.sh" "rein-aggregate-incidents.py"
  run_test test_gate_bypass_consumes \
    "pre-edit-dod-gate.sh" "rein-aggregate-incidents.py"

  # Migration
  run_test test_migration_empty_log "rein-migrate-blocks-log.py"
  run_test test_migration_valid_lines "rein-migrate-blocks-log.py"
  run_test test_migration_malformed_skipped "rein-migrate-blocks-log.py"
  run_test test_migration_dst_exists "rein-migrate-blocks-log.py"

  # Watermark
  run_test test_watermark_prevents_double_processing "rein-aggregate-incidents.py"

  # Snapshot
  run_test test_aggregate_writes_snapshot "rein-aggregate-incidents.py"
  run_test test_aggregate_snapshot_empty_pending "rein-aggregate-incidents.py"

  # rein-mark-incident-processed.py
  run_test test_helper_allows_error_status "rein-aggregate-incidents.py"
  run_test test_error_excluded_from_pending "rein-aggregate-incidents.py"
  run_test test_trace_log_written "rein-aggregate-incidents.py"

  # rein-mark-agent-candidate.py
  run_test test_agent_candidate_create "rein-mark-agent-candidate.py"
  run_test test_agent_candidate_set_decision "rein-mark-agent-candidate.py"
  run_test test_agent_candidate_skip_when_decided "rein-mark-agent-candidate.py"
  run_test test_agent_candidate_decide_missing_decision_key "rein-mark-agent-candidate.py"
  run_test test_agent_candidate_create_pending_overwrite "rein-mark-agent-candidate.py"

  summary
}

main "$@"
