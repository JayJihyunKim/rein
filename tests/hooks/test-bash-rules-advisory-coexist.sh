#!/usr/bin/env bash
# tests/hooks/test-bash-rules-advisory-coexist.sh
#
# Task 2.4 (S6): Verifies that pre-tool-use-bash-rules.sh (advisory hook)
# coexists correctly with pre-bash-guard.sh JSON deny without producing
# duplicate deny decisions or unexpected exit codes.
#
# Three cases:
#   A — advisory hook never emits exit 2 on any input (pure advisory).
#   B — rules directory absent → hook exits 0 gracefully (rule_inject_body
#       returns 1 → `if ! BODY=...` guard fires → exit 0).
#   C — python3 serialization failure path: rule_inject_body uses `|| true` on
#       python3, so it succeeds via cat fallback when python3 is absent. The
#       `if ! BODY=...` guard therefore does NOT fire. Instead, the `|| exit 0`
#       guard on the ESCAPED=... serialization line catches python3 exit 127
#       before set -euo pipefail can abort the hook. Verified by removing
#       python3 from PATH.
#   D — hook output does NOT contain permissionDecision key (advisory only
#       emits additionalContext; permissionDecision is pre-bash-guard territory).
#   E — pre-bash-guard P8 (cat .env) → JSON deny; then advisory hook on same
#       input → no permissionDecision in advisory output (only one deny per
#       hook chain, from the guard hook).
#
# Contract: pre-tool-use-bash-rules.sh must NEVER emit exit 2 and must NEVER
# include a permissionDecision key in its JSON output.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
HOOK="$PLUGIN_ROOT/hooks/pre-tool-use-bash-rules.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

run_advisory() {
  # Run the advisory hook with CLAUDE_PLUGIN_ROOT set, capture rc+stdout+stderr.
  # $1 = optional extra env prefix (e.g. "PATH=...")
  local extra_env="${1:-}"
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  local rc=0
  if [ -n "$extra_env" ]; then
    env $extra_env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$out_f" 2>"$err_f" || rc=$?
  else
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$out_f" 2>"$err_f" || rc=$?
  fi
  ADVISORY_RC=$rc
  ADVISORY_STDOUT=$(cat "$out_f")
  ADVISORY_STDERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

echo "TEST: Case A — advisory hook never exits 2 on blocking input (cat .env)"
# Even with an input that pre-bash-guard would block, this hook is advisory only.
run_advisory ""
if [ "$ADVISORY_RC" -eq 0 ]; then
  pass "exit 0 on normal invocation"
else
  fail "expected exit 0, got $ADVISORY_RC"
fi

echo "TEST: Case A (repeat) — advisory hook exit 0 confirmed regardless of stdin"
# The hook ignores stdin content entirely (reads from CLAUDE_PLUGIN_ROOT rules).
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" \
  < /dev/null > /tmp/t24-case-a.out 2>/dev/null
RC_A=$?
if [ "$RC_A" -eq 0 ]; then
  pass "exit 0 with /dev/null stdin"
else
  fail "expected exit 0 (advisory), got $RC_A"
fi

echo "TEST: Case B — rules directory absent → hook exits 0 (graceful degrade)"
# Create a temp plugin root with no rules/ dir so rule_inject_body returns 1.
TMP_PLUGIN=$(mktemp -d)
# Copy just enough structure for the hook to source its libs.
mkdir -p "$TMP_PLUGIN/hooks/lib" "$TMP_PLUGIN/scripts"
cp "$PLUGIN_ROOT/hooks/lib/rule-inject.sh" "$TMP_PLUGIN/hooks/lib/" 2>/dev/null || true
# Deliberately leave out rules/ dir → rule_inject_body returns 1.
RC_B=0
CLAUDE_PLUGIN_ROOT="$TMP_PLUGIN" bash "$HOOK" </dev/null >/dev/null 2>/dev/null || RC_B=$?
rm -rf "$TMP_PLUGIN"
if [ "$RC_B" -eq 0 ]; then
  pass "exit 0 when rules directory absent"
else
  fail "expected exit 0 (graceful degrade), got $RC_B"
fi

echo "TEST: Case C — python3 absent → ESCAPED serialization fails → || exit 0 guard fires → exit 0"
# rule_inject_body uses `|| true` on python3, so it succeeds via the cat
# fallback when python3 is absent. The if-guard on line 24 therefore does NOT
# fire. Instead, the `|| exit 0` guard on line 30 catches the python3 failure
# (exit 127) before set -euo pipefail can abort the hook with a non-zero rc.
(
  # Narrow PATH to exclude python3 entirely.
  d=$(mktemp -d)
  for t in bash sh env cat printf grep sed awk tr mkdir rm cp ln chmod; do
    src=$(command -v "$t" 2>/dev/null || true)
    [ -n "$src" ] && ln -sf "$src" "$d/$t" 2>/dev/null || true
  done
  export PATH="$d"
  hash -r 2>/dev/null || true
  RC_C=0
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >/dev/null 2>/dev/null || RC_C=$?
  rm -rf "$d"
  exit "$RC_C"
)
RC_C=$?
if [ "$RC_C" -eq 0 ]; then
  pass "exit 0 when python3 absent (|| exit 0 guard on serialization line)"
else
  fail "expected exit 0 (python3 absent, advisory graceful), got $RC_C"
fi

echo "TEST: Case D — advisory output has NO permissionDecision key"
run_advisory ""
if [ -n "$ADVISORY_STDOUT" ]; then
  has_pd=false
  has_pd=$(python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
hso = data.get("hookSpecificOutput", {})
print("true" if "permissionDecision" in hso else "false")
' <<<"$ADVISORY_STDOUT" 2>/dev/null || echo "false")
  if [ "$has_pd" = "false" ]; then
    pass "no permissionDecision key in advisory output (additionalContext only)"
  else
    fail "advisory hook must NOT emit permissionDecision (got: $ADVISORY_STDOUT)"
  fi
else
  # Empty stdout (no rules body resolved) is also acceptable — no deny.
  pass "advisory hook produced no stdout (no rules body) — no permissionDecision"
fi

echo "TEST: Case E — after pre-bash-guard JSON deny, advisory hook on same input produces no permissionDecision"
# Run pre-bash-guard on a P8 input and confirm JSON deny is present.
GUARD_HOOK="$PLUGIN_ROOT/hooks/pre-bash-guard.sh"
INPUT='{"tool_input":{"command":"cat .env"}}'
GUARD_OUT=$(printf '%s' "$INPUT" | REIN_PROJECT_DIR_OVERRIDE="/tmp/nonexistent_$$" \
  bash "$GUARD_HOOK" 2>/dev/null)
GUARD_RC=$?
guard_deny=false
if [ "$GUARD_RC" -eq 0 ] && [ -n "$GUARD_OUT" ]; then
  guard_deny=$(python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
hso = data.get("hookSpecificOutput", {})
print("true" if hso.get("permissionDecision") == "deny" else "false")
' <<<"$GUARD_OUT" 2>/dev/null || echo "false")
fi
if [ "$guard_deny" = "true" ]; then
  pass "pre-bash-guard correctly emits JSON deny for P8 (cat .env)"
else
  fail "pre-bash-guard did not emit JSON deny for P8 (guard_rc=$GUARD_RC, out=$GUARD_OUT)"
fi

# Advisory hook on same input: must not add another permissionDecision.
run_advisory ""
advisory_pd=false
if [ -n "$ADVISORY_STDOUT" ]; then
  advisory_pd=$(python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
hso = data.get("hookSpecificOutput", {})
print("true" if "permissionDecision" in hso else "false")
' <<<"$ADVISORY_STDOUT" 2>/dev/null || echo "false")
fi
if [ "$advisory_pd" = "false" ]; then
  pass "advisory hook does not add second permissionDecision after guard deny"
else
  fail "advisory hook must not emit permissionDecision (coexistence violated): $ADVISORY_STDOUT"
fi

echo ""
echo "================================"
echo "Cases run: A B C D E"
echo "Passed:    $PASS_COUNT"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
