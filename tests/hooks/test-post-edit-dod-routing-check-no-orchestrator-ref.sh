#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-dod-routing-check.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
if grep -nE '^\s*echo[^#]*"[^"]*orchestrator\.md[^"]*"[^#]*>&2' "$HOOK"; then
  echo "FAIL: post-edit-dod-routing-check.sh still emits orchestrator.md in stderr message" >&2
  exit 1
fi
echo "test-post-edit-dod-routing-check-no-orchestrator-ref: OK"
