#!/usr/bin/env bash
# tests/hooks/test-post-agent-review-trigger.sh
#
# Test suite for plugins/rein-core/hooks/post-agent-review-trigger.sh (HK-3).
#
# PostToolUse(Agent) hook that nudges Claude to run codex-review after a
# feature-builder-family subagent finishes with .review-pending present.
#
# Scenarios:
#   (a) subagent_type "feature-builder" + .review-pending present
#       → stdout contains "decision" and "block"
#   (b) subagent_type "rein:feature-builder" (namespaced) + .review-pending
#       → same output as (a)
#   (c) subagent_type "researcher" + .review-pending present
#       → no output (exit 0, allowlist filter)
#   (d) subagent_type "feature-builder" but .review-pending absent
#       → no output (exit 0, guard filter)
#   (e) subagent_type "feature-builder-fix" + .review-pending → triggers
#   (f) subagent_type "feature-builder-refactor" + .review-pending → triggers

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-agent-review-trigger.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }

FAIL=0
note_fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# run_hook <subagent_type> <project_dir>
# Sets OUT, RC.
run_hook() {
  local subagent_type="$1"
  local project_dir="$2"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'tool_input':{'subagent_type': sys.argv[1]},'tool_result':{}}))" "$subagent_type")
  local out_file
  out_file=$(mktemp)
  printf '%s' "$payload" | REIN_PROJECT_DIR_OVERRIDE="$project_dir" bash "$HOOK" >"$out_file" 2>/dev/null
  RC=$?
  OUT=$(cat "$out_file")
  rm -f "$out_file"
}

# ---- (a) feature-builder + .review-pending present → block --------------------
TMPDIR_A=$(mktemp -d)
mkdir -p "$TMPDIR_A/trail/dod"
touch "$TMPDIR_A/trail/dod/.review-pending"

run_hook "feature-builder" "$TMPDIR_A"

if [ "$RC" -ne 0 ]; then
  note_fail "(a) exit code should be 0, got $RC"
fi
if [ -z "$OUT" ]; then
  note_fail "(a) feature-builder + .review-pending: expected output, got none"
else
  if ! echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'decision' in d" 2>/dev/null; then
    note_fail "(a) output is not valid JSON or missing 'decision' key"
  fi
  if ! echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('decision')=='block'" 2>/dev/null; then
    note_fail "(a) output decision != 'block'"
  fi
  echo "  ok: (a) feature-builder + .review-pending → {decision:block} JSON"
fi
rm -rf "$TMPDIR_A"

# ---- (b) rein:feature-builder namespaced → same behavior ----------------------
TMPDIR_B=$(mktemp -d)
mkdir -p "$TMPDIR_B/trail/dod"
touch "$TMPDIR_B/trail/dod/.review-pending"

run_hook "rein:feature-builder" "$TMPDIR_B"

if [ "$RC" -ne 0 ]; then
  note_fail "(b) exit code should be 0, got $RC"
fi
if [ -z "$OUT" ]; then
  note_fail "(b) rein:feature-builder + .review-pending: expected output, got none"
else
  if ! echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('decision')=='block'" 2>/dev/null; then
    note_fail "(b) rein:feature-builder namespaced: output decision != 'block'"
  fi
  echo "  ok: (b) rein:feature-builder (namespaced) → strips prefix, triggers"
fi
rm -rf "$TMPDIR_B"

# ---- (c) researcher → no output (not in allowlist) ----------------------------
TMPDIR_C=$(mktemp -d)
mkdir -p "$TMPDIR_C/trail/dod"
touch "$TMPDIR_C/trail/dod/.review-pending"

run_hook "researcher" "$TMPDIR_C"

if [ "$RC" -ne 0 ]; then
  note_fail "(c) exit code should be 0, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(c) researcher should produce no output, got: $OUT"
else
  echo "  ok: (c) researcher → no output (allowlist filter)"
fi
rm -rf "$TMPDIR_C"

# ---- (d) feature-builder + no .review-pending → no output --------------------
TMPDIR_D=$(mktemp -d)
mkdir -p "$TMPDIR_D/trail/dod"
# Do NOT create .review-pending

run_hook "feature-builder" "$TMPDIR_D"

if [ "$RC" -ne 0 ]; then
  note_fail "(d) exit code should be 0, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(d) feature-builder without .review-pending should produce no output, got: $OUT"
else
  echo "  ok: (d) feature-builder + no .review-pending → no output"
fi
rm -rf "$TMPDIR_D"

# ---- (e) feature-builder-fix → triggers ---------------------------------------
TMPDIR_E=$(mktemp -d)
mkdir -p "$TMPDIR_E/trail/dod"
touch "$TMPDIR_E/trail/dod/.review-pending"

run_hook "feature-builder-fix" "$TMPDIR_E"

if [ "$RC" -ne 0 ]; then
  note_fail "(e) exit code should be 0, got $RC"
fi
if [ -z "$OUT" ]; then
  note_fail "(e) feature-builder-fix + .review-pending: expected output, got none"
else
  if ! echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('decision')=='block'" 2>/dev/null; then
    note_fail "(e) feature-builder-fix: output decision != 'block'"
  fi
  echo "  ok: (e) feature-builder-fix → triggers"
fi
rm -rf "$TMPDIR_E"

# ---- (f) feature-builder-refactor → triggers ----------------------------------
TMPDIR_F=$(mktemp -d)
mkdir -p "$TMPDIR_F/trail/dod"
touch "$TMPDIR_F/trail/dod/.review-pending"

run_hook "feature-builder-refactor" "$TMPDIR_F"

if [ "$RC" -ne 0 ]; then
  note_fail "(f) exit code should be 0, got $RC"
fi
if [ -z "$OUT" ]; then
  note_fail "(f) feature-builder-refactor + .review-pending: expected output, got none"
else
  if ! echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('decision')=='block'" 2>/dev/null; then
    note_fail "(f) feature-builder-refactor: output decision != 'block'"
  fi
  echo "  ok: (f) feature-builder-refactor → triggers"
fi
rm -rf "$TMPDIR_F"

# ---- summary ------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-post-agent-review-trigger: OK (6 scenarios)"
  exit 0
else
  echo "test-post-agent-review-trigger: $FAIL scenario(s) FAILED"
  exit 1
fi
