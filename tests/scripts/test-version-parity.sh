#!/usr/bin/env bash
# test-version-parity.sh — VER-1 (v1.2.0 cycle, scaffold→plugin migration gap fix).
#
# Asserts that the plugin SSOT version (plugins/rein-core/.claude-plugin/
# plugin.json `version`) and the user-installable CLI shim version
# (scripts/rein.sh `VERSION=`) are in lockstep.
#
# Drift between these two surfaces produces a marketplace tarball whose
# `plugin.json` claims one version while the installed `rein` shim reports
# another, which silently breaks `rein --version` parity after
# `/plugin install rein@rein` and confuses release tag bookkeeping.
#
# Mirrors the same parity check that scripts/rein-publish.sh enforces
# pre-publish (VER-1) — keeping it as a standalone test means CI can detect
# the drift even on PRs that never invoke the publish path.
#
# PASS: exit 0, prints "version-parity OK: <version>".
# FAIL: exit 1, prints both observed values + which file claims which.
#
# Scope ID: VER-1-plugin-json-version-field-bumped-to-1-2-0-and-rein-publish-script-aborts-on-pre-publish-mismatch-between-plugin-json-and-rein-sh-version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_JSON="plugins/rein-core/.claude-plugin/plugin.json"
REIN_SH="scripts/rein.sh"

[ -f "$PLUGIN_JSON" ] || {
  echo "FAIL: $PLUGIN_JSON missing" >&2
  exit 1
}
[ -f "$REIN_SH" ] || {
  echo "FAIL: $REIN_SH missing" >&2
  exit 1
}

# Prefer jq when available (fast, well-defined JSON parse); otherwise fall
# back to python3 so the test still runs on minimal CI runners that don't
# bundle jq.
if command -v jq >/dev/null 2>&1; then
  PLUGIN_JSON_VERSION="$(jq -r .version "$PLUGIN_JSON")"
else
  PLUGIN_JSON_VERSION="$(python3 -c "import json,sys; print(json.load(open('$PLUGIN_JSON'))['version'])")"
fi

REIN_SH_VERSION="$(grep '^VERSION=' "$REIN_SH" | head -1 | cut -d'"' -f2)"

if [ -z "$PLUGIN_JSON_VERSION" ] || [ "$PLUGIN_JSON_VERSION" = "null" ]; then
  echo "FAIL: could not parse version from $PLUGIN_JSON" >&2
  exit 1
fi
if [ -z "$REIN_SH_VERSION" ]; then
  echo "FAIL: could not parse VERSION= from $REIN_SH" >&2
  exit 1
fi

if [ "$PLUGIN_JSON_VERSION" != "$REIN_SH_VERSION" ]; then
  echo "FAIL: version mismatch" >&2
  echo "  $PLUGIN_JSON  version = $PLUGIN_JSON_VERSION" >&2
  echo "  $REIN_SH      VERSION = $REIN_SH_VERSION" >&2
  echo "  diff: update both files to the same value" >&2
  exit 1
fi

echo "version-parity OK: $PLUGIN_JSON_VERSION"
