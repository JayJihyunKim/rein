#!/usr/bin/env bash
# test-legacy-pending-heal-registered.sh — Plugin-First Restructure Phase 2 Task 2.4
# (Option C Phase 4 Task 4.2 갱신 — plugin docs/rules mirror 폐기 후 healer 동작 검증만 유지).
#
# Verifies the legacy-shipped-pending rule is registered in the rein-core plugin:
#   (a) session-start-load-trail.sh hook script exists in the plugin.
#   (b) rein-heal-legacy-pending.py exists in plugins/rein-core/scripts/.
#   (c) session-start-load-trail.sh references the healer script (literal string
#       'rein-heal-legacy-pending' must appear in the hook body).
#   (d) hooks.json contains a SessionStart registration whose command basename
#       is session-start-load-trail.sh.
#
# Note: Option C Phase 3 + Phase 4 가 plugin docs/rules mirror 를 폐기하면서
# 기존 check (e) 의 source/plugin sha256 parity 검증은 제거됨. legacy-shipped-pending
# rule 본문은 .claude/rules/ (dev-only) 와 plugins/rein-core/rules/ (plugin SSOT)
# 한 곳에만 있고 docs/rules/ mirror 는 없음. healer 동작 (hook + script + token +
# hooks.json 등록) 만 본 테스트의 invariant.
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_DIR="plugins/rein-core"
HOOK_SCRIPT="$PLUGIN_DIR/hooks/session-start-load-trail.sh"
HEAL_SCRIPT="$PLUGIN_DIR/scripts/rein-heal-legacy-pending.py"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

EXPECTED_EVENT="SessionStart"
EXPECTED_BASENAME="session-start-load-trail.sh"
HEALER_TOKEN="rein-heal-legacy-pending"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# (a) Hook script presence in plugin.
[ -f "$HOOK_SCRIPT" ] || fail "hook script missing: $HOOK_SCRIPT"

# (b) Healer python script presence in plugin scripts dir.
[ -f "$HEAL_SCRIPT" ] || fail "healer script missing: $HEAL_SCRIPT"

# (c) Hook body must reference the healer (any path prefix is acceptable; we
#     only confirm the connection between the hook and the healer is present).
if ! grep -q "$HEALER_TOKEN" "$HOOK_SCRIPT"; then
  fail "hook '$HOOK_SCRIPT' does not reference healer token '$HEALER_TOKEN'"
fi

# (d) hooks.json registration check via Python (SessionStart has no matcher).
[ -f "$HOOKS_JSON" ] || fail "hooks.json missing: $HOOKS_JSON"

python3 - "$HOOKS_JSON" "$EXPECTED_EVENT" "$EXPECTED_BASENAME" <<'PY'
import json
import os
import sys

hooks_json_path, expected_event, expected_basename = sys.argv[1:4]

with open(hooks_json_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

# Claude Code hooks.json schema:
#   {"hooks": {"<Event>": [{"matcher": "...", "hooks": [{"command": "..."}, ...]}, ...]}}
hooks_by_event = data.get("hooks", {})
for matcher_group in hooks_by_event.get(expected_event, []):
    for hook in matcher_group.get("hooks", []):
        cmd = hook.get("command", "")
        if os.path.basename(cmd) == expected_basename:
            sys.exit(0)

print(
    "FAIL: no hooks.json entry matched event="
    f"{expected_event} basename={expected_basename}",
    file=sys.stderr,
)
sys.exit(1)
PY

echo "test-legacy-pending-heal-registered: OK (hook + healer + reference + hooks.json)"
