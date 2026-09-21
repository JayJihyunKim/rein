#!/usr/bin/env bash
# tests/hooks/test-orchestrator-first-emit.sh — OFD-INJECT-1
#
# session-start-rules.sh injects the orchestrator-first summary ONLY when the
# project opts in via `.rein/policy/rules.yaml` (`orchestrator-first: {enabled: true}`).
#   OFF (no yaml / malformed yaml): marker absent — fail-closed.
#   OFF (policy says enabled, but the loader misbehaves): marker absent — the
#        hook turns ON only on loader exit 0 AND stdout byte-for-byte `true`,
#        so a loader that prints "true" and then dies, answers "True",
#        "true\n" or "tr\0ue" (both of which `$(...)` would normalise to
#        "true"), answers nothing (older loader), or is missing must all
#        stay OFF.
#   ON : marker sits between operating-sequence and routing-map, the summary
#        file is <= 1000B, and the emitted JSON line is < 10000 chars (the only
#        size pass condition — summary-file byte sums are not measured).
# Fixtures are fresh temp dirs, so every run is a first session (onboarding
# primer prepended) — the largest envelope this hook produces.
# pipefail: check() pipes the hook into the asserting python, so without it a
# non-zero hook exit would be masked by the python's success.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
HOOK="$PLUGIN_ROOT/hooks/session-start-rules.sh"
SUMMARY="$PLUGIN_ROOT/rules/short/orchestrator-first-summary.md"
MARKER="# Orchestrator First — quick rule"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK missing or not executable" >&2; exit 1; }
[ -f "$SUMMARY" ] || { echo "FAIL: $SUMMARY missing" >&2; exit 1; }
SUMMARY_BYTES=$(wc -c < "$SUMMARY")
[ "$SUMMARY_BYTES" -le 1000 ] || { echo "FAIL: summary ${SUMMARY_BYTES}B > 1000B" >&2; exit 1; }

TMP_ROOT="$(mktemp -d "/tmp/test-orchestrator-first-emit-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/off-no-yaml" "$TMP_ROOT/off-malformed/.rein/policy" "$TMP_ROOT/on/.rein/policy"
printf ':::\nnot yaml: at all: extra: colons:\n  : invalid\n' > "$TMP_ROOT/off-malformed/.rein/policy/rules.yaml"
printf 'orchestrator-first:\n  enabled: true\n' > "$TMP_ROOT/on/.rein/policy/rules.yaml"

# check <case-dir> <on|off> [plugin-root] — run the hook from the fixture dir,
# decode the envelope (the marker's em dash is \u-escaped in the raw line) and
# assert. The optional plugin root swaps in a stub loader (see stub_root).
check() {
  ( cd "$TMP_ROOT/$1" && CLAUDE_PLUGIN_ROOT="${3:-$PLUGIN_ROOT}" bash "$HOOK" </dev/null 2>/dev/null ) \
    | python3 -c '
import json, sys
case, mode, marker = sys.argv[1], sys.argv[2], sys.argv[3]
line = sys.stdin.read().rstrip("\n")
if not line:
    sys.exit(f"FAIL: {case}: hook produced no envelope")
ctx = json.loads(line)["hookSpecificOutput"]["additionalContext"]
if mode == "off":
    if marker in ctx:
        sys.exit(f"FAIL: {case}: marker present while opt-in is OFF (fail-closed violated)")
    print(f"  ok: {case} → marker absent")
    sys.exit(0)
idx = ctx.find(marker)
before = ctx.find("# Operating Sequence — quick rule")
after = ctx.find("# Routing Map — quick rule")
if not (0 <= before < idx < after):
    sys.exit(f"FAIL: {case}: slot order operating-sequence({before}) < orchestrator-first({idx}) < routing-map({after}) violated")
if len(line) >= 10000:
    sys.exit(f"FAIL: {case}: emitted JSON line {len(line)} chars >= 10000 (platform per-hook cap)")
print(f"  ok: {case} → marker in slot, JSON line {len(line)} chars < 10000")
' "$1" "$2" "$MARKER" || exit 1
}

check off-no-yaml off
check off-malformed off
check on on

# stub_root <name> [loader-body] — a plugin root whose rules/ and hooks/ are the
# real ones but whose loader is a stub (omitted body = no loader at all). The
# fixture dir gets the same enabled policy as `on`, so only the loader differs.
stub_root() {
  local root="$TMP_ROOT/root-$1"
  mkdir -p "$root/scripts" "$TMP_ROOT/$1/.rein/policy"
  ln -s "$PLUGIN_ROOT/rules" "$root/rules"
  ln -s "$PLUGIN_ROOT/hooks" "$root/hooks"
  cp "$TMP_ROOT/on/.rein/policy/rules.yaml" "$TMP_ROOT/$1/.rein/policy/rules.yaml"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" > "$root/scripts/rein-policy-loader.py"
  fi
  check "$1" off "$root"
}
ENABLED_ONLY='import sys
if sys.argv[1:2] != ["--rule-enabled"]: sys.exit(0)'
stub_root off-true-then-nonzero-exit "$ENABLED_ONLY"'
sys.stdout.write("true"); sys.exit(23)'
stub_root off-inexact-answer          "$ENABLED_ONLY"'
sys.stdout.write("True")'
stub_root off-trailing-newline        "$ENABLED_ONLY"'
sys.stdout.write("true\n")'
stub_root off-embedded-nul            "$ENABLED_ONLY"'
sys.stdout.buffer.write(b"tr\x00ue")'
stub_root off-empty-answer            "$ENABLED_ONLY"
stub_root off-loader-missing
echo "test-orchestrator-first-emit: OK (summary ${SUMMARY_BYTES}B <= 1000B)"
