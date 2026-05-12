#!/usr/bin/env bash
# Verify pre-edit-dod-gate.sh stderr messages no longer reference orchestrator.md / .claude/CLAUDE.md.
# Task 3.1 of rein v1.1.0 plugin-prompt-level operating model: plugin users
# do not have orchestrator.md / .claude/CLAUDE.md in their repos, so stderr
# messages must use inline procedure text instead.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/pre-edit-dod-gate.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }

# 주석 / case-pattern 라인 (path match) 은 제외하고, stderr 출력 메시지만 검사.
# 패턴: echo "... orchestrator.md ..." >&2 또는 echo "... .claude/CLAUDE.md ..." >&2
if grep -nE '^\s*echo[^#]*"[^"]*orchestrator\.md[^"]*"[^#]*>&2' "$HOOK"; then
  echo "FAIL: pre-edit-dod-gate.sh still emits orchestrator.md in stderr message" >&2
  exit 1
fi
if grep -nE '^\s*echo[^#]*"[^"]*\.claude/CLAUDE\.md[^"]*"[^#]*>&2' "$HOOK"; then
  echo "FAIL: pre-edit-dod-gate.sh still emits .claude/CLAUDE.md in stderr message" >&2
  exit 1
fi
echo "test-pre-edit-dod-gate-no-orchestrator-ref: OK"
