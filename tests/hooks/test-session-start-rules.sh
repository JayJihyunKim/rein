#!/usr/bin/env bash
# tests/hooks/test-session-start-rules.sh — Plugin-First Restructure Phase 2 Task 2.1
#
# Functional test for plugins/rein-core/hooks/session-start-rules.sh.
#
# The hook reads 3 rule body files from
# ${CLAUDE_PLUGIN_ROOT}/rules/{code-style,security,testing}.md,
# concatenates their contents (separated by `\n\n`), JSON-encodes the
# concatenation, and prints a single SessionStart envelope to stdout:
#
#   {
#     "hookSpecificOutput": {
#       "hookEventName": "SessionStart",
#       "additionalContext": "<concatenated rule bodies>"
#     }
#   }
#
# Assertions:
#   (a) Happy path — script exits 0, stdout parses as JSON, hookEventName
#       is "SessionStart", additionalContext is a non-empty string and
#       contains a recognisable substring from each of the 3 rule files.
#   (b) Graceful degrade — when CLAUDE_PLUGIN_ROOT points at a path that
#       has no rules/ directory, the hook exits 0 silently
#       (zero stdout bytes).
#
# Scope ID: prompt-only-rules-inject-via-session-start-hook-on-session-begin
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="plugins/rein-core/hooks/session-start-rules.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

[ -f "$HOOK" ] || {
  echo "FAIL: $HOOK missing" >&2
  exit 1
}
[ -x "$HOOK" ] || {
  echo "FAIL: $HOOK is not executable (chmod +x missing)" >&2
  exit 1
}

# ---------- (a) Happy path ----------------------------------------------------
HAPPY_OUT=$(mktemp)
HAPPY_ERR=$(mktemp)
trap 'rm -f "$HAPPY_OUT" "$HAPPY_ERR" "$DEGRADE_OUT" "$DEGRADE_ERR" 2>/dev/null || true' EXIT

CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$HAPPY_OUT" 2>"$HAPPY_ERR"
HAPPY_RC=$?

if [ "$HAPPY_RC" -ne 0 ]; then
  echo "FAIL: happy-path hook exited with rc=$HAPPY_RC" >&2
  echo "----- stderr -----" >&2
  cat "$HAPPY_ERR" >&2
  exit 1
fi

# Parse stdout as JSON and assert envelope contents.
python3 - "$HAPPY_OUT" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    raw = fh.read()

if not raw.strip():
    print("FAIL: happy-path stdout is empty (expected JSON envelope)", file=sys.stderr)
    sys.exit(1)

try:
    payload = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"FAIL: happy-path stdout is not valid JSON: {e}", file=sys.stderr)
    print(f"----- stdout -----\n{raw}", file=sys.stderr)
    sys.exit(1)

hso = payload.get("hookSpecificOutput")
if not isinstance(hso, dict):
    print(f"FAIL: missing object 'hookSpecificOutput' (got {type(hso).__name__})", file=sys.stderr)
    sys.exit(1)

ev = hso.get("hookEventName")
if ev != "SessionStart":
    print(f"FAIL: hookEventName expected 'SessionStart', got {ev!r}", file=sys.stderr)
    sys.exit(1)

ctx = hso.get("additionalContext")
if not isinstance(ctx, str) or not ctx:
    print(f"FAIL: additionalContext expected non-empty string (got {type(ctx).__name__} len={len(ctx) if isinstance(ctx, str) else 0})", file=sys.stderr)
    sys.exit(1)

# Each of the 6 rules contributes its SHORT summary (PT-2: session-start injects
# `rules/short/<rule>-summary.md`, not the full body). Markers are the summary
# headers — unique to the summaries, absent from the full bodies.
required_substrings = [
    ("code-style-summary.md",          "# Code Style — quick rule"),
    ("security-summary.md",            "# Security — quick rule"),
    ("testing-summary.md",             "# Testing — quick rule"),
    ("operating-sequence-summary.md",  "# Operating Sequence — quick rule"),
    ("routing-map-summary.md",         "# Routing Map — quick rule"),
    ("response-tone-summary.md",       "# Response Tone — per-turn quick rule"),
]
missing = [name for name, frag in required_substrings if frag not in ctx]
if missing:
    print(f"FAIL: additionalContext missing substrings from: {missing}", file=sys.stderr)
    print(f"----- additionalContext (first 500 chars) -----\n{ctx[:500]}", file=sys.stderr)
    sys.exit(1)

print("test-session-start-rules: happy-path OK")
PY

# ---------- (b) Graceful degrade ---------------------------------------------
# CLAUDE_PLUGIN_ROOT pointing at a path that has no rules/
# directory must yield exit 0 + zero stdout bytes.
DEGRADE_ROOT=$(mktemp -d "/tmp/session-start-rules-degrade-XXXXXX")
DEGRADE_OUT=$(mktemp)
DEGRADE_ERR=$(mktemp)

CLAUDE_PLUGIN_ROOT="$DEGRADE_ROOT" bash "$HOOK" </dev/null >"$DEGRADE_OUT" 2>"$DEGRADE_ERR"
DEGRADE_RC=$?

if [ "$DEGRADE_RC" -ne 0 ]; then
  echo "FAIL: graceful-degrade hook expected rc=0, got rc=$DEGRADE_RC" >&2
  echo "----- stderr -----" >&2
  cat "$DEGRADE_ERR" >&2
  rm -rf "$DEGRADE_ROOT"
  exit 1
fi

if [ -s "$DEGRADE_OUT" ]; then
  echo "FAIL: graceful-degrade hook expected empty stdout, got:" >&2
  cat "$DEGRADE_OUT" >&2
  rm -rf "$DEGRADE_ROOT"
  exit 1
fi

rm -rf "$DEGRADE_ROOT"

echo "test-session-start-rules: OK (happy-path envelope + graceful-degrade)"
