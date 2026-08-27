#!/usr/bin/env bash
# tests/hooks/test-hooks-routing-contract.sh
#
# Guards plugins/rein-core/hooks/hooks.json against unintended ROUTING drift
# (moving a hook to a different event/matcher, deleting a hook, or adding one
# without anyone noticing). Existing hooks.json tests do NOT cover this:
#   - test-hooks-json-schema.sh          — event slots + matcher-set shape +
#                                           target file existence/exec bit only
#   - test-bootstrap-gate-hooks-json-order.sh — order within 2 specific groups
#     only (Edit group head, Bash group)
#   - tests/scripts/test-plugin-hooks-json-targets-exist.sh — command prefix +
#     target existence only
#
# None of the above notice if a hook is silently moved to a different event,
# dropped, or added under a new matcher — they'd all still pass. This test
# closes that gap with an explicit (event, matcher, type, command) routing
# table that is diffed bidirectionally against the live hooks.json, plus a
# within-group order check. `type` is tracked (not just command) so a hook
# entry silently changing its "type" field (e.g. "command" -> "prompt")
# without moving/renaming also fails this test instead of passing unnoticed.
#
# ---------------------------------------------------------------------------
# UPDATE CONTRACT (read before touching hooks.json)
# ---------------------------------------------------------------------------
# When you intentionally change hook routing — move a hook to a different
# event, add or remove a hook, reorder hooks within a matcher group — you
# MUST update EXPECTED_ROUTING (below, inside the python block) in the SAME
# commit as the hooks.json change. If you edit hooks.json without updating
# this table, this test fails and blocks the commit gate. That is the
# intended behavior: this test does not assert the current routing is
# "correct" — it asserts routing changes are never silent.
#
# Behavioral test (per repo convention, e.g. test-hook-hotpath-perf... class
# tests): this script parses hooks.json as data, it never `source`s a hook
# script.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Override point for the destructive/sandbox verification described in the
# task: point this at a scratch copy of hooks.json to prove the test can
# actually fail. Defaults to the real plugin manifest.
HOOKS_JSON="${REIN_ROUTING_CONTRACT_HOOKS_JSON:-$PROJECT_DIR/plugins/rein-core/hooks/hooks.json}"

PASS_COUNT=0
FAIL_COUNT=0

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "ok $((PASS_COUNT + FAIL_COUNT)) - $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "not ok $((PASS_COUNT + FAIL_COUNT)) - $1" >&2
}

[ -f "$HOOKS_JSON" ] || {
  echo "FAIL: hooks.json missing: $HOOKS_JSON" >&2
  exit 1
}

# Single python pass: parses hooks.json, flattens it into the same
# (event, matcher, command) shape as EXPECTED_ROUTING, then runs the three
# checks the task requires:
#   1) missing  — in EXPECTED_ROUTING but absent from hooks.json
#   2) extra    — in hooks.json but absent from EXPECTED_ROUTING
#   3) order    — same (event, matcher) group, different relative order
#
# Emits one block per check to stdout (human-readable expected-vs-actual
# detail) terminated by a machine-parseable "CHECK_RESULT <name> PASS|FAIL"
# trailer line the bash side greps for.
PY_OUT="$(python3 - "$HOOKS_JSON" <<'PY'
import json
import sys
from collections import Counter, OrderedDict

path = sys.argv[1]

# ---------------------------------------------------------------------------
# EXPECTED_ROUTING — the routing contract.
#
# Each row is a (event, matcher, type, command) 4-tuple, listed in the EXACT
# order the entry appears in hooks.json (top-to-bottom through the JSON hook
# arrays). This is a CONFIGURATION-array ordering only — a config-hygiene /
# diff-readability contract this test enforces on the hooks.json file itself
# — NOT a guarantee about real hook execution order. Claude Code runs every
# hook matched to the same event IN PARALLEL and the order is
# non-deterministic (hooks guide: a hook must never assume a sibling hook
# has already run, or that a sibling deny already suppressed a side
# effect). The order hooks.json lists is never read by Claude Code as an
# execution schedule (SPIKE-1 HK-4 실측). Check 3 below (order) exists to
# catch someone silently reordering entries in the JSON file (config
# drift), not to assert or enforce that hooks run in that sequence.
# STYLE NOTE for future edits to this block: it lives inside a quoted
# heredoc feeding a $(...) command substitution. bash 3.2 (macOS default
# bash) mis-locates the closing paren of that substitution when the
# heredoc body contains an odd total count of single-quote characters
# (apostrophes) across all its lines — reproduced while drafting this
# paragraph. Prefer writing without contractions/possessives in this
# section, and if a quote character is unavoidable, keep the total count
# even. Events with no matcher (SessionStart, UserPromptSubmit,
# Stop) use "" for matcher. `type` is the hooks.json hook-entry "type" field
# (every hook in this repo is currently "command" — added so a silent
# type flip, e.g. "command" -> "prompt", is caught instead of passing
# unnoticed; see review fix history for this file).
#
# UPDATE THIS TABLE IN THE SAME COMMIT as any intentional hooks.json routing
# change. See the UPDATE CONTRACT comment at the top of this file for why.
# ---------------------------------------------------------------------------
EXPECTED_ROUTING = [
    ("SessionStart", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-bootstrap.sh"),
    ("SessionStart", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-load-trail.sh"),
    ("SessionStart", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-rules.sh"),
    ("SessionStart", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-persona.sh"),

    ("UserPromptSubmit", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/user-prompt-submit-rules.sh"),

    ("PreToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-trail-bootstrap-gate.sh"),
    ("PreToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/trail-rotate.sh"),
    ("PreToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-index-lines.sh"),
    # pre-edit-dod-gate.sh retired (Phase 7 웨이브 3 ③-b, edit-gate rotation,
    # 2026-08-21) — briefly replaced by three individually-registered hooks
    # (pre-edit-discipline-gate.sh, pre-edit-task-gate.sh,
    # pre-edit-coverage-gate.sh) running under Claude Code parallel,
    # non-deterministic PreToolUse scheduling. That parallel model enabled a
    # reachable race (code review round 6, High — a same-process
    # precondition-awareness peek inside pre-edit-coverage-gate.sh could
    # observe a sibling one-shot bypass marker in an inconsistent state).
    # 2026-08-23: collapsed into the single sequential dispatcher below,
    # which runs the three retained hook FILES internally in guaranteed
    # order with first-block-wins semantics (see pre-edit-dispatcher.sh own
    # header for the full rationale). Those three files still exist on disk
    # (as the dispatcher children, and as direct-invocation targets for
    # their own unit test suites) — they are simply no longer individually
    # registered in this matcher group.
    ("PreToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-dispatcher.sh"),
    ("PreToolUse", "Bash", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash-dispatcher.sh"),
    ("PreToolUse", "Agent", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use-agent-rules.sh"),

    # Phase 7 웨이브 3 ③-d (2026-08-24): post-edit-review-gate.sh 삭제됨 —
    # legacy 리뷰 표식(trail/dod/.review-pending)의 유일한 생산자였고, 그
    # 표식의 write/read 경로가 이번 웨이브로 전면 제거됐다. UPDATE CONTRACT
    # 대로 이 삭제를 표에 명시 반영한다(무언 drift 방지).
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-hygiene.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-index-sync-inbox.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-spec-review-gate.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-plan-coverage.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-dod-routing-check.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-design-plan-coverage-rule.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-routing-procedure-rule.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-meta-check.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-state-journal.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-src-touch-marker.sh"),
    ("PostToolUse", "Edit|Write|MultiEdit", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-aggregator.sh"),
    ("PostToolUse", "Bash", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-state-journal.sh"),
    ("PostToolUse", "Agent", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/post-agent-review-trigger.sh"),

    ("Stop", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/stop-session-gate.sh"),
    ("Stop", "", "command", "${CLAUDE_PLUGIN_ROOT}/hooks/stop-state-journal.sh"),
]
# --- end EXPECTED_ROUTING --------------------------------------------------

try:
    manifest = json.loads(open(path, encoding="utf-8").read())
except Exception as e:
    print(f"PARSE_FAIL {e}")
    print("CHECK_RESULT parse FAIL")
    sys.exit(0)

events = manifest.get("hooks", {})
actual = []
for event_name, slots in events.items():
    if not isinstance(slots, list):
        continue
    for slot in slots:
        matcher = slot.get("matcher", "")
        for hook in slot.get("hooks", []):
            actual.append((event_name, matcher, hook.get("type", ""), hook.get("command", "")))

expected = EXPECTED_ROUTING

def _matcher_display(mt):
    # Distinguish "no matcher key at all" ("") from an explicit
    # "matcher": null in hooks.json (None) — both used to render as the
    # same "(none)" string, which made it impossible to tell from the
    # printed diff which mutation actually happened (review fix).
    if mt is None:
        return "<null>"
    if mt == "":
        return "<empty>"
    return mt

def fmt(t):
    ev, mt, tp, cmd = t
    return f"event={ev} matcher={_matcher_display(mt)} type={tp!r} command={cmd}"

print(f"TOTAL_EXPECTED {len(expected)}")
print(f"TOTAL_ACTUAL {len(actual)}")

# --- Check 1: missing (expected but not in hooks.json) ---------------------
expected_counter = Counter(expected)
actual_counter = Counter(actual)

missing = list((expected_counter - actual_counter).elements())
if missing:
    print("== missing: in EXPECTED_ROUTING but not in hooks.json ==")
    for m in missing:
        print(f"  MISSING  {fmt(m)}")
    print("CHECK_RESULT missing FAIL")
else:
    print("CHECK_RESULT missing PASS")

# --- Check 2: extra (in hooks.json but not expected — unauthorized add) ---
extra = list((actual_counter - expected_counter).elements())
if extra:
    print("== extra: in hooks.json but not in EXPECTED_ROUTING ==")
    for e in extra:
        print(f"  EXTRA    {fmt(e)}")
    print("CHECK_RESULT extra FAIL")
else:
    print("CHECK_RESULT extra PASS")

# --- Check 3: relative order within each (event, matcher) group -----------
def group_by_key(tuples):
    groups = OrderedDict()
    for ev, mt, tp, cmd in tuples:
        groups.setdefault((ev, mt), []).append(cmd)
    return groups

expected_groups = group_by_key(expected)
actual_groups = group_by_key(actual)

# Only meaningful for groups present on both sides — missing/extra already
# reported the ones that are not.
common_keys = [k for k in expected_groups if k in actual_groups]
order_bad = []
for key in common_keys:
    exp_seq = expected_groups[key]
    act_seq = actual_groups[key]
    if exp_seq != act_seq:
        order_bad.append((key, exp_seq, act_seq))

if order_bad:
    print("== order: same (event, matcher) group, different relative order ==")
    for (ev, mt), exp_seq, act_seq in order_bad:
        print(f"  GROUP event={ev} matcher={_matcher_display(mt)}")
        print("    expected: " + " -> ".join(exp_seq))
        print("    actual:   " + " -> ".join(act_seq))
    print("CHECK_RESULT order FAIL")
else:
    print("CHECK_RESULT order PASS")
PY
)"

echo "$PY_OUT"

EXPECTED_TOTAL="$(printf '%s\n' "$PY_OUT" | awk '/^TOTAL_EXPECTED /{print $2}')"

if printf '%s\n' "$PY_OUT" | grep -q '^CHECK_RESULT parse FAIL$'; then
  fail "hooks.json parses as JSON ($HOOKS_JSON)"
  echo ""
  echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
  exit 1
fi

if printf '%s\n' "$PY_OUT" | grep -q '^CHECK_RESULT missing PASS$'; then
  ok "no expected routing entries are missing from hooks.json ($EXPECTED_TOTAL entries in table)"
else
  fail "expected routing entries missing from hooks.json (see MISSING lines above)"
fi

if printf '%s\n' "$PY_OUT" | grep -q '^CHECK_RESULT extra PASS$'; then
  ok "no unauthorized routing entries present in hooks.json"
else
  fail "unauthorized routing entries found in hooks.json (see EXTRA lines above)"
fi

if printf '%s\n' "$PY_OUT" | grep -q '^CHECK_RESULT order PASS$'; then
  ok "relative order within each (event, matcher) group matches EXPECTED_ROUTING"
else
  fail "relative order within a (event, matcher) group diverged from EXPECTED_ROUTING (see GROUP lines above)"
fi

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
