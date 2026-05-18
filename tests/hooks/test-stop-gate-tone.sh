#!/bin/bash
# tests/hooks/test-stop-gate-tone.sh
#
# Task 3.2 tone assertions for stop-session-gate.sh (S7).
#
# Verifies that when stop-session-gate emits a block JSON decision
# (via the EMIT_PY-absent fallback path), the `reason` field is in
# assistant tone: a natural English sentence, NOT an imperative "BLOCKED:" prefix.
#
# Strategy: seed a sandbox with a stub rein-aggregate-incidents.py that
# reports PENDING_COUNT=1, omit rein-stop-emit-block.py so the fallback
# echo path fires, and assert tone on the resulting JSON reason string.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# ============================================================
# Fixture helpers
# ============================================================

# _seed_stop_gate_tone_fixtures
#   - seeds a valid session state (inbox today + index.md)
#   - seeds .rein/project.json (BG-1 contract)
#   - places a stub aggregate script that returns PENDING_COUNT=1
#   - marks .session-has-src-edit so the incident gate is reached
#   - does NOT place rein-stop-emit-block.py → fallback JSON path runs
_seed_stop_gate_tone_fixtures() {
  local today
  today=$(date +%Y-%m-%d)

  # Valid session state (inbox + index.md)
  seed_inbox "${today}-session-marker.md" "# session marker"
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: stop gate tone
- next: verify
- note: fixture
EOF
  touch "$SANDBOX/trail/index.md"

  # BG-1 bootstrap contract: .rein/project.json must exist
  mkdir -p "$SANDBOX/.rein"
  printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' \
    > "$SANDBOX/.rein/project.json"

  # Mark that source edits happened this session (gate not skipped)
  touch "$SANDBOX/trail/dod/.session-has-src-edit"

  # Stub aggregate script: --count-pending returns 1 (one pending incident).
  # All other subcommands (default invocation, set-session-end, advisory-summary)
  # return success with empty output so they don't interfere.
  mkdir -p "$SANDBOX/scripts"
  cat > "$SANDBOX/scripts/rein-aggregate-incidents.py" <<'PY'
#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if "--count-pending" in args:
    print("1")
    sys.exit(0)
if "set-session-end" in args:
    sys.exit(0)
if "advisory-summary" in args:
    print("[]")
    sys.exit(0)
# Default invocation (aggregate run): silent success
sys.exit(0)
PY
  chmod +x "$SANDBOX/scripts/rein-aggregate-incidents.py"

  # Seed one auto-*.md incident file with status: pending so the
  # CURRENT_HASHES logic proceeds normally (non-empty hash list).
  cat > "$SANDBOX/trail/incidents/auto-tone-test.md" <<'INCIDENT'
---
status: "pending"
pattern_hash: "tone-test-hash-001"
hook: "test-hook"
reason: "tone test fixture"
first_seen: "2026-05-18T00:00:00"
last_seen_at: "2026-05-18T00:00:00"
---
# Incident: tone test fixture
INCIDENT

  # No rein-stop-emit-block.py → EMIT_PY will be empty → fallback JSON fires.
}

# ============================================================
# Suite: stop-gate block JSON reason tone assertion
# ============================================================

test_stop_gate_block_json_reason_is_assistant_tone() {
  _seed_stop_gate_tone_fixtures

  run_hook "stop-session-gate.sh"

  # The hook must exit 0 (Claude Code Stop hook blocks via JSON decision,
  # never via exit 2).
  assert_exit 0 "stop-session-gate block must exit 0 (JSON decision path)"

  # Stdout must contain valid JSON with decision=block.
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get("decision","missing"))
except Exception as e:
    print("parse-error: " + str(e))
' 2>/dev/null)
  [ "$decision" = "block" ] \
    || fail "stop-gate tone: expected decision=block in stdout JSON, got: '$decision' (stdout: $HOOK_STDOUT)"

  # Extract the reason field.
  local reason
  reason=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get("reason",""))
except Exception:
    print("")
' 2>/dev/null)

  # Reason must contain natural-sentence tokens (assistant tone indicators).
  printf '%s' "$reason" | grep -qiE 'incidents|resolve|run|session' \
    || fail "stop-gate tone: reason missing natural-sentence tokens (incidents/resolve/run/session): '$reason'"

  # Reason must NOT start with uppercase imperative "BLOCKED:" prefix.
  printf '%s' "$reason" | grep -qE '^BLOCKED:' \
    && fail "stop-gate tone: reason starts with 'BLOCKED:' imperative prefix: '$reason'"

  return 0
}

main() {
  run_test test_stop_gate_block_json_reason_is_assistant_tone  stop-session-gate.sh
  summary
}

main "$@"
