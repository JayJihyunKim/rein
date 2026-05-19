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

# Edit group: third hook must be pre-edit-dod-gate (preserved)
assert any(h.endswith("pre-edit-dod-gate.sh") for h in edit_hooks[2:]), \
    f"FAIL: Edit group missing pre-edit-dod-gate.sh after bootstrap gate. Got: {edit_hooks}"

# Bash group: first hook must be bootstrap gate
assert bash_hooks[0].endswith("pre-tool-use-bash-bootstrap-gate.sh"), \
    f"FAIL: Bash group first hook expected pre-tool-use-bash-bootstrap-gate.sh, got: {bash_hooks[0]}"

# Bash group: second hook must be the safety guard (HK-2 split — the always-on
# successor to the former single Bash guard, preserved right after bootstrap)
assert bash_hooks[1].endswith("pre-bash-safety-guard.sh"), \
    f"FAIL: Bash group second hook expected pre-bash-safety-guard.sh, got: {bash_hooks[1]}"

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
