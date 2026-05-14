#!/usr/bin/env bash
# test-helpers-smoke.sh — Plan C Task 1.4
# Ensures helpers.sh exposes sandbox_repo / rein_exec / rein_source without
# side effects at source time.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/helpers.sh"

[ -n "$REIN_PROJECT_ROOT" ] || { echo "FAIL: REIN_PROJECT_ROOT unset" >&2; exit 1; }
[ -f "$REIN_SCRIPT" ]       || { echo "FAIL: REIN_SCRIPT not a file: $REIN_SCRIPT" >&2; exit 1; }

# sandbox_repo creates a dir with .claude/ and git repo seeded with fixture.
sandbox=$(sandbox_repo)
trap 'rm -rf "$sandbox"' EXIT

[ -d "$sandbox/.claude/rules" ]   || { echo "FAIL: sandbox missing .claude/rules" >&2; exit 1; }
[ -d "$sandbox/.git" ]            || { echo "FAIL: sandbox missing .git" >&2; exit 1; }
[ -f "$sandbox/.claude/CLAUDE.md" ] || { echo "FAIL: fixture .claude/CLAUDE.md not copied" >&2; exit 1; }
[ -f "$sandbox/AGENTS.md" ]       || { echo "FAIL: fixture AGENTS.md not copied" >&2; exit 1; }

# rein_exec runs rein.sh with --version (cheap smoke).
version=$(rein_exec --version)
echo "$version" | grep -q "^rein " || { echo "FAIL: rein_exec --version: $version" >&2; exit 1; }

# rein_source exposes functions into the caller.
rein_source
type detect_platform >/dev/null 2>&1 || { echo "FAIL: rein_source did not expose detect_platform" >&2; exit 1; }

echo "test-helpers-smoke: OK"
