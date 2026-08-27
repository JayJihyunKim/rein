#!/usr/bin/env bash
# Verify pre-edit-discipline-gate.sh / pre-edit-task-gate.sh stderr messages
# never reference orchestrator.md / .claude/CLAUDE.md.
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대): pre-edit-dod-gate.sh 는 삭제되고
# pre-edit-discipline-gate.sh + pre-edit-task-gate.sh 두 훅으로 교대된다. Task
# 3.1 (rein v1.1.0 plugin-prompt-level operating model) 의 규약 — plugin
# 사용자 repo 에는 orchestrator.md / .claude/CLAUDE.md 가 없으므로 stderr
# 메시지는 inline 절차문을 써야 한다 — 는 두 신설 훅에도 그대로 적용된다.
# 이전엔 pre-edit-dod-gate.sh 하나만 검사했으나, 교대 후에는 그 책임을 이어받는
# 두 훅 모두를 검사해야 회귀를 놓치지 않는다.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/plugins/rein-core/hooks"

FAILED=0

check_hook() {
  local hook="$1"
  local name
  name="$(basename "$hook")"
  [ -f "$hook" ] || { echo "FAIL: $hook missing" >&2; FAILED=1; return; }

  # 주석 / case-pattern 라인 (path match) 은 제외하고, stderr 출력 메시지만 검사.
  # 패턴: echo "... orchestrator.md ..." >&2 또는 echo "... .claude/CLAUDE.md ..." >&2
  if grep -nE '^\s*echo[^#]*"[^"]*orchestrator\.md[^"]*"[^#]*>&2' "$hook"; then
    echo "FAIL: $name still emits orchestrator.md in stderr message" >&2
    FAILED=1
  fi
  if grep -nE '^\s*echo[^#]*"[^"]*\.claude/CLAUDE\.md[^"]*"[^#]*>&2' "$hook"; then
    echo "FAIL: $name still emits .claude/CLAUDE.md in stderr message" >&2
    FAILED=1
  fi
}

check_hook "$HOOKS_DIR/pre-edit-discipline-gate.sh"
check_hook "$HOOKS_DIR/pre-edit-task-gate.sh"

[ "$FAILED" -eq 0 ] || exit 1
echo "test-pre-edit-discipline-gate-no-orchestrator-ref: OK (discipline-gate + task-gate)"
