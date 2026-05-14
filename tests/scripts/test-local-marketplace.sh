#!/usr/bin/env bash
# test-local-marketplace.sh
#
# Verifies the local Claude Code marketplace exposes only the public Rein
# plugin name while still sourcing the existing plugin package directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MARKETPLACE="$PROJECT_DIR/.claude-plugin/marketplace.json"
PLUGIN_JSON="$PROJECT_DIR/plugins/rein-core/.claude-plugin/plugin.json"

[ -f "$MARKETPLACE" ] || { echo "FAIL: missing $MARKETPLACE" >&2; exit 1; }
[ -f "$PLUGIN_JSON" ] || { echo "FAIL: missing $PLUGIN_JSON" >&2; exit 1; }

python3 - "$MARKETPLACE" "$PLUGIN_JSON" <<'PY'
import json
import sys

marketplace_path, plugin_path = sys.argv[1], sys.argv[2]

with open(marketplace_path, "r", encoding="utf-8") as fh:
    marketplace = json.load(fh)
with open(plugin_path, "r", encoding="utf-8") as fh:
    plugin = json.load(fh)

if marketplace.get("name") != "rein":
    raise SystemExit(f"FAIL: marketplace top-level name is {marketplace.get('name')!r}, want 'rein'")

plugins = marketplace.get("plugins")
if not isinstance(plugins, list):
    raise SystemExit("FAIL: marketplace plugins must be a list")
if len(plugins) != 1:
    raise SystemExit(f"FAIL: marketplace exposes {len(plugins)} plugins, want 1")

entry = plugins[0]
if entry.get("name") != "rein":
    raise SystemExit(f"FAIL: marketplace plugin name is {entry.get('name')!r}, want 'rein'")
if entry.get("source") != "./plugins/rein-core":
    raise SystemExit(f"FAIL: marketplace source is {entry.get('source')!r}, want './plugins/rein-core'")

hidden = {"rein-core"}
names = {p.get("name") for p in plugins if isinstance(p, dict)}
leaked = sorted(hidden & names)
if leaked:
    raise SystemExit(f"FAIL: hidden plugin names leaked into marketplace: {leaked}")

if plugin.get("name") != "rein":
    raise SystemExit(f"FAIL: plugin.json name is {plugin.get('name')!r}, want 'rein'")

print("test-local-marketplace: OK")
PY
