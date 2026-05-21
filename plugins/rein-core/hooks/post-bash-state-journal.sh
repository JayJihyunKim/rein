#!/usr/bin/env bash
# Hook: PostToolUse(Bash) — Cycle X4.C.2 (영역 C).
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md §3.2 + §4.2
# Responsibility: append "bash-result\t<exit>\t<class>" to .rein/state-pending-bash.log.
# Mode transitions are applied later by the dispatcher drain (not here).
#
# Fail-soft on missing lib/python/extractor. envelope 의 exit_code 부재 시
# stderr NOTICE + journal skip (design memo R-12).

[ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -z "${REIN_PROJECT_DIR_OVERRIDE:-}" ] && exit 0

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib/state-machine.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=./lib/state-machine.sh
. "$LIB" 2>/dev/null || exit 0

# codex Round 3 X4.C.2 HIGH fix: independent regex below makes bash-classifier.sh
# unnecessary. Do not source it — if the classifier ever fails to source, the
# hook would otherwise exit before journaling, missing the after-commit
# transition. Classification is duplicated locally for robustness.

PYTHON=""
if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
  # shellcheck source=./lib/python-runner.sh
  . "$SCRIPT_DIR/lib/python-runner.sh"
  resolve_python 2>/dev/null && PYTHON="${PYTHON_RUNNER[0]:-}"
fi
[ -z "$PYTHON" ] && exit 0

EXTRACTOR="$SCRIPT_DIR/lib/extract-hook-json.py"
[ -f "$EXTRACTOR" ] || exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | "$PYTHON" "$EXTRACTOR" \
  --field tool_input.command --default '' 2>/dev/null)
EXIT_CODE=$(printf '%s' "$INPUT" | "$PYTHON" "$EXTRACTOR" \
  --field tool_response.exit_code --default '' 2>/dev/null)
# Some envelopes use tool_result.exit_code (older schema).
if [ -z "$EXIT_CODE" ]; then
  EXIT_CODE=$(printf '%s' "$INPUT" | "$PYTHON" "$EXTRACTOR" \
    --field tool_result.exit_code --default '' 2>/dev/null)
fi
if [ -z "$EXIT_CODE" ] || ! echo "$EXIT_CODE" | grep -qE '^-?[0-9]+$'; then
  # design memo R-12: exit_code 부재 → vocal skip, no journal entry.
  echo "[rein] post-bash-state-journal: envelope missing tool_response.exit_code — skipping (mode transition deferred)" >&2
  exit 0
fi

# Independent classification (codex Round 2 X4.C.2 HIGH fix — do not rely on
# bash-classifier.sh which misses repeated-whitespace `git  commit`).
CLASS="safe"
if [ -n "$COMMAND" ]; then
  if echo "$COMMAND" | grep -qE '(^|[^a-zA-Z_])git[[:space:]]+commit\b'; then
    CLASS="commit"
  elif echo "$COMMAND" | grep -qE '(^|[^a-zA-Z_])(pytest|jest|vitest|mocha)\b' \
       || echo "$COMMAND" | grep -qE 'npm[[:space:]]+(run[[:space:]]+)?test\b' \
       || echo "$COMMAND" | grep -qE 'yarn[[:space:]]+test\b' \
       || echo "$COMMAND" | grep -qE 'pnpm[[:space:]]+test\b' \
       || echo "$COMMAND" | grep -qE 'python[[:space:]]+-m[[:space:]]+pytest\b'; then
    CLASS="test"
  fi
fi

append_journal bash "bash-result	$EXIT_CODE	$CLASS" >/dev/null 2>&1 || true

exit 0
