#!/usr/bin/env bash
# Verify dev-only rules are NOT shipped in the plugin tarball.
# These 4 rules are rein-dev maintainer-only and must stay in `.claude/rules/`.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

DEV_ONLY=(branch-strategy readme-style versioning legacy-shipped-pending)
PLUGIN_RULES_DIR="plugins/rein-core/rules"
FAIL=0

[ -d "$PLUGIN_RULES_DIR" ] || { echo "FAIL: $PLUGIN_RULES_DIR not found (Task 1.1 should have created it)" >&2; exit 1; }

for name in "${DEV_ONLY[@]}"; do
  forbidden="$PLUGIN_RULES_DIR/${name}.md"
  if [ -f "$forbidden" ]; then
    echo "FAIL: dev-only rule shipped in plugin: $forbidden" >&2
    FAIL=1
  fi
done

[ "$FAIL" = "0" ] || { echo "test-dev-only-rules-not-in-plugin: FAIL" >&2; exit 1; }
echo "test-dev-only-rules-not-in-plugin: OK"
