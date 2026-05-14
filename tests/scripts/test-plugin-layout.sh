#!/usr/bin/env bash
# test-plugin-layout.sh — Plugin-First Restructure Task 1.1
#
# Asserts the foundational plugins/rein-core/ layout exists and that the
# plugin manifest declares the rein package. Subsequent Phase 1 tasks
# (1.2 - 1.6) populate the
# directories this layout creates.
#
# Assertions (4):
#   (a) plugins/rein-core/.claude-plugin/plugin.json exists
#   (b) plugin.json declares "name": "rein"
#   (c) plugin.json has a version string
#   (d) plugins/rein-core/hooks/hooks.json exists with a Claude Code
#       compatible hooks object. Parity / target-existence /
#       sha256-identical-mirror are enforced by the dedicated hook tests.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLUGIN_JSON="$PROJECT_DIR/plugins/rein-core/.claude-plugin/plugin.json"
HOOKS_JSON="$PROJECT_DIR/plugins/rein-core/hooks/hooks.json"

# (a) plugin.json file presence
[ -f "$PLUGIN_JSON" ] || {
  echo "FAIL: plugin.json missing at $PLUGIN_JSON" >&2
  exit 1
}

# (b) plugin.json declares "name": "rein"
# Tolerant to whitespace; strict on the literal value.
if ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"rein"' "$PLUGIN_JSON"; then
  echo "FAIL: plugin.json does not declare \"name\": \"rein\"" >&2
  exit 1
fi

# (c) plugin.json has a version string.
# Use python for structural check rather than fragile grep — manifest is JSON.
python3 - "$PLUGIN_JSON" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

version = manifest.get("version")
if not isinstance(version, str) or not version:
    print("FAIL: plugin.json missing non-empty string 'version'", file=sys.stderr)
    sys.exit(1)
PY

# (d) hooks/hooks.json exists with a hooks object.
[ -f "$HOOKS_JSON" ] || {
  echo "FAIL: hooks.json missing at $HOOKS_JSON" >&2
  exit 1
}

python3 - "$HOOKS_JSON" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    hooks = json.load(fh)

registered = hooks.get("hooks")
if not isinstance(registered, dict) or not registered:
    print(f"FAIL: hooks.json missing non-empty object 'hooks' (got {type(registered).__name__})", file=sys.stderr)
    sys.exit(1)
PY

echo "test-plugin-layout: OK"
