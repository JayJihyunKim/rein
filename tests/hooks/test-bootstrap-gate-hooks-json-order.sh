#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

python3 - <<'PY'
import json, sys
path = "plugins/rein-core/hooks/hooks.json"
m = json.loads(open(path).read())
pre = m["hooks"]["PreToolUse"]

# Locate Edit|Write|MultiEdit group
edit_group = next((g for g in pre if g.get("matcher") == "Edit|Write|MultiEdit"), None)
bash_group = next((g for g in pre if g.get("matcher") == "Bash"), None)
assert edit_group is not None, "FAIL: PreToolUse Edit|Write|MultiEdit matcher group missing"
assert bash_group is not None, "FAIL: PreToolUse Bash matcher group missing"

edit_hooks = [h["command"] for h in edit_group.get("hooks", [])]
bash_hooks = [h["command"] for h in bash_group.get("hooks", [])]

# Edit group: first hook must be bootstrap gate
assert edit_hooks[0].endswith("pre-edit-trail-bootstrap-gate.sh"), \
    f"FAIL: Edit group first hook expected pre-edit-trail-bootstrap-gate.sh, got: {edit_hooks[0]}"

# Edit group: second hook must be trail-rotate (preserved)
assert edit_hooks[1].endswith("trail-rotate.sh"), \
    f"FAIL: Edit group second hook expected trail-rotate.sh, got: {edit_hooks[1]}"

# Edit group: pre-edit-dod-gate.sh is RETIRED (Phase 7 웨이브 3 ③-b, edit-gate
# rotation, 2026-08-21). It was briefly replaced by two individually
# registered hooks (pre-edit-discipline-gate.sh + pre-edit-task-gate.sh)
# running under Claude Code's parallel, non-deterministic PreToolUse
# scheduling, plus pre-edit-coverage-gate.sh as a third individually
# registered hook. 2026-08-23 (code review round 6, High): that parallel
# model enabled a reachable race in pre-edit-coverage-gate.sh's
# precondition-awareness peek, so the three are now collapsed into a single
# registered entry, pre-edit-dispatcher.sh, which runs the three hook FILES
# internally in guaranteed sequential order with first-block-wins semantics
# (see that hook's own header). The three files themselves are NOT deleted
# — they remain on disk as the dispatcher's children and as direct-
# invocation targets for their own unit test suites — they are simply no
# longer individually registered in hooks.json.
assert not any(h.endswith("pre-edit-dod-gate.sh") for h in edit_hooks), \
    f"FAIL: pre-edit-dod-gate.sh should be retired (rotated into the dispatcher's children). Got: {edit_hooks}"
assert not any(h.endswith("pre-edit-discipline-gate.sh") for h in edit_hooks), \
    f"FAIL: pre-edit-discipline-gate.sh should no longer be individually registered — it runs as pre-edit-dispatcher.sh's first child now. Got: {edit_hooks}"
assert not any(h.endswith("pre-edit-task-gate.sh") for h in edit_hooks), \
    f"FAIL: pre-edit-task-gate.sh should no longer be individually registered — it runs as pre-edit-dispatcher.sh's second child now. Got: {edit_hooks}"
assert not any(h.endswith("pre-edit-coverage-gate.sh") for h in edit_hooks), \
    f"FAIL: pre-edit-coverage-gate.sh should no longer be individually registered — it runs as pre-edit-dispatcher.sh's third child now. Got: {edit_hooks}"
assert any(h.endswith("pre-edit-dispatcher.sh") for h in edit_hooks[2:]), \
    f"FAIL: Edit group missing pre-edit-dispatcher.sh after bootstrap gate/trail-rotate/index-lines. Got: {edit_hooks}"
# Exactly 4 entries expected: bootstrap gate, trail-rotate, index-lines,
# dispatcher. A 5th entry would mean either a child gate got re-registered
# individually (defeating the sequential guarantee the dispatcher exists
# for) or an unrelated new hook was added without updating this test.
assert len(edit_hooks) == 4, \
    f"FAIL: Edit group expected exactly 4 hooks (bootstrap gate, trail-rotate, index-lines, dispatcher), got {len(edit_hooks)}: {edit_hooks}"

# Bash group: single dispatcher entry (Cycle X2, 영역 A, 2026-05-20).
# Previously this group held bootstrap-gate + safety-guard + ~30 `if`-gated
# entries for test-commit / bash-rules. Cycle X2 collapsed all of them into
# pre-bash-dispatcher.sh which invokes the same helpers internally — the
# bootstrap-first ordering is now enforced inside the dispatcher (verified
# by test-bash-dispatcher.sh suite 2).
assert len(bash_hooks) == 1, \
    f"FAIL: Bash group expected single dispatcher entry, got {len(bash_hooks)} hooks: {bash_hooks}"
assert bash_hooks[0].endswith("pre-bash-dispatcher.sh"), \
    f"FAIL: Bash group sole hook expected pre-bash-dispatcher.sh, got: {bash_hooks[0]}"

# All commands must use plugin root marker
marker = "${CLAUDE_PLUGIN_ROOT}/hooks/"
all_pre_commands = [h["command"] for g in pre for h in g.get("hooks", [])]
for cmd in all_pre_commands:
    assert marker in cmd, f"FAIL: command missing plugin marker: {cmd}"

# Sanity: other slots unchanged — must contain Agent matcher (v1.1.0 신설) intact
agent_group = next((g for g in pre if g.get("matcher") == "Agent"), None)
assert agent_group is not None, "FAIL: Agent matcher group lost"

# Stop / PostToolUse / SessionStart / UserPromptSubmit 변경 없음 — 존재만 확인
for ev in ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"):
    assert ev in m["hooks"], f"FAIL: event slot {ev} missing"

print("test-bootstrap-gate-hooks-json-order: OK (Edit + Bash groups prepended with bootstrap gates, other slots intact)")
PY
