#!/usr/bin/env bash
# test-plugin-hooks-json-targets-exist.sh — Plugin-First Restructure Phase 1 Task 1.4.
#
# Validates plugins/rein-core/hooks/hooks.json:
#   - Parses as JSON via python3 (no brittle regex/awk on JSON).
#   - "hooks" is a non-empty object in Claude Code plugin hook schema.
#   - For each command hook, "command" begins with "${CLAUDE_PLUGIN_ROOT}/"
#     and the resolved path (relative to plugins/rein-core/) exists.
#
# Plan §4 path-normalization clarification: command paths use
# ${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh form so they relocate cleanly when
# the plugin is installed under a user's plugin root.
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_DIR="plugins/rein-core"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

[ -f "$HOOKS_JSON" ] || {
  echo "FAIL: $HOOKS_JSON missing" >&2
  exit 1
}

# python3 does:
#   - JSON.load (fails loudly on syntax errors)
#   - asserts hooks is a non-empty object
#   - prints each command field on its own line
#
# Output is whitespace-free per line so we can read it back into bash safely.
COMMANDS=$(python3 - "$HOOKS_JSON" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
events = data.get("hooks")
if not isinstance(events, dict) or not events:
    print("FAIL: hooks.json 'hooks' is not a non-empty object", file=sys.stderr)
    sys.exit(1)
for event_name, entries in events.items():
    if not isinstance(event_name, str) or not event_name:
        print("FAIL: hook event name must be a non-empty string", file=sys.stderr)
        sys.exit(1)
    if not isinstance(entries, list) or not entries:
        print(f"FAIL: hooks[{event_name!r}] is not a non-empty list", file=sys.stderr)
        sys.exit(1)
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            print(f"FAIL: hooks[{event_name!r}][{i}] is not an object", file=sys.stderr)
            sys.exit(1)
        hook_items = entry.get("hooks")
        if not isinstance(hook_items, list) or not hook_items:
            print(f"FAIL: hooks[{event_name!r}][{i}].hooks is not a non-empty list", file=sys.stderr)
            sys.exit(1)
        for j, hook in enumerate(hook_items):
            if not isinstance(hook, dict):
                print(f"FAIL: hooks[{event_name!r}][{i}].hooks[{j}] is not an object", file=sys.stderr)
                sys.exit(1)
            if hook.get("type") != "command":
                print(f"FAIL: hook type must be command: {hook!r}", file=sys.stderr)
                sys.exit(1)
            cmd = hook.get("command")
            if not isinstance(cmd, str) or not cmd:
                print(f"FAIL: command hook missing command: {hook!r}", file=sys.stderr)
                sys.exit(1)
            print(cmd)
PY
)

PREFIX='${CLAUDE_PLUGIN_ROOT}/'
count=0

while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  count=$((count + 1))

  case "$cmd" in
    "$PREFIX"*)
      ;;
    *)
      echo "FAIL: command '$cmd' does not start with '$PREFIX'" >&2
      exit 1
      ;;
  esac

  # Strip the literal "${CLAUDE_PLUGIN_ROOT}/" prefix.
  rel="${cmd#$PREFIX}"

  target="$PLUGIN_DIR/$rel"
  if [ ! -f "$target" ]; then
    echo "FAIL: command target does not exist: $target (from '$cmd')" >&2
    exit 1
  fi
done <<< "$COMMANDS"

if [ "$count" -eq 0 ]; then
  echo "FAIL: hooks.json yielded zero commands" >&2
  exit 1
fi

echo "test-plugin-hooks-json-targets-exist: OK ($count hook commands resolved)"
