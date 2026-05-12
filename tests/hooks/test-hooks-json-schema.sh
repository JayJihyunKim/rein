#!/usr/bin/env bash
# tests/hooks/test-hooks-json-schema.sh
#
# Verify plugins/rein-core/hooks/hooks.json structure for v1.1.0:
#   - 5 event slots (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop)
#   - PreToolUse contains 3 matchers exactly: Edit|Write|MultiEdit, Bash, Agent
#   - Every command resolves to an existing executable plugin file
#
# This test guards against accidental drift in the v1.1.0 hooks.json final
# manifest (Phase 2 Task 2.5).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

python3 - <<'PY' || exit 1
import json
import stat
import sys
from pathlib import Path

root = Path("plugins/rein-core")
hooks_dir = root / "hooks"
manifest_path = hooks_dir / "hooks.json"

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"FAIL: cannot parse {manifest_path}: {e}", file=sys.stderr)
    sys.exit(1)

events = manifest.get("hooks", {})
expected_events = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
got_events = set(events.keys())
if got_events != expected_events:
    missing = expected_events - got_events
    extra = got_events - expected_events
    print(
        f"FAIL: event slots mismatch — got {sorted(got_events)} "
        f"expected {sorted(expected_events)} (missing={sorted(missing)}, extra={sorted(extra)})",
        file=sys.stderr,
    )
    sys.exit(1)

# PreToolUse must contain 3 matchers exactly: Edit|Write|MultiEdit, Bash, Agent
pre_matchers = [slot.get("matcher", "") for slot in events["PreToolUse"]]
expected_pre = ["Edit|Write|MultiEdit", "Bash", "Agent"]
if sorted(pre_matchers) != sorted(expected_pre):
    print(
        f"FAIL: PreToolUse matchers mismatch — got {pre_matchers} "
        f"expected {expected_pre}",
        file=sys.stderr,
    )
    sys.exit(1)

# Every command must point to ${CLAUDE_PLUGIN_ROOT}/hooks/<file> and that file
# must exist and be executable for the owner.
bad = []
marker = "${CLAUDE_PLUGIN_ROOT}/hooks/"
total_cmds = 0
for ev, slots in events.items():
    for slot in slots:
        for hook in slot.get("hooks", []):
            cmd = hook.get("command", "")
            total_cmds += 1
            if marker not in cmd:
                bad.append(f"{ev}: command does not use plugin root marker: {cmd}")
                continue
            rel = cmd.split(marker, 1)[1]
            target = hooks_dir / rel
            if not target.exists():
                bad.append(f"{ev}: hook file missing: {rel}")
                continue
            mode = target.stat().st_mode
            if not (mode & stat.S_IXUSR):
                bad.append(f"{ev}: hook not executable: {rel}")

if bad:
    for b in bad:
        print(f"FAIL: {b}", file=sys.stderr)
    sys.exit(1)

print(
    f"test-hooks-json-schema: OK "
    f"({len(events)} slots, {total_cmds} commands, all resolve to executable plugin files)"
)
PY
