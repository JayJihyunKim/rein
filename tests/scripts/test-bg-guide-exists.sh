#!/usr/bin/env bash
# test-bg-guide-exists.sh — Plan C Phase 9 Task 9.1.
#
# Guards the Claude Code integration guide as a shipped artifact (plugin SSOT,
# Option C Phase 3 thin-overlay):
#   - File exists at plugins/rein-core/rules/background-jobs.md
#   - Documents `rein job start` as the recommended pattern
#   - References BashOutput (the mistake to avoid) in the anti-pattern section
#   - Is surfaced via the plugin's UserPromptSubmit/PreToolUse rules hook
#     (no longer @import'd from .claude/CLAUDE.md — that overlay was retired
#     when the plugin became single SSOT)
#
# Scope ID: BG-claude-code-integration-guide.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

GUIDE="plugins/rein-core/rules/background-jobs.md"

[ -f "$GUIDE" ] || {
  echo "FAIL: $GUIDE missing" >&2; exit 1
}

grep -q 'rein job start' "$GUIDE" || {
  echo "FAIL: guide does not mention 'rein job start'" >&2; exit 1
}

grep -q 'BashOutput' "$GUIDE" || {
  echo "FAIL: guide does not mention 'BashOutput' anti-pattern" >&2; exit 1
}

grep -q 'background-jobs' plugins/rein-core/hooks/pre-tool-use-bash-rules.sh || {
  echo "FAIL: pre-tool-use-bash-rules.sh does not surface background-jobs guide" >&2; exit 1
}

echo "test-bg-guide-exists: OK"
