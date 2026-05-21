#!/usr/bin/env bash
# Hook: PostToolUse(Edit|Write|MultiEdit) — Cycle X4.C.2 (영역 C).
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md §3.2 + §4.2
# Responsibility: append "edit\t<abs-path>\t<kind>" to .rein/state-pending-edits.log.
# Mode transitions are applied later by the dispatcher drain (not here).
#
# Fail-soft: if state-machine.sh is unavailable for any reason (missing file,
# source error), the hook exits 0 — the legacy hook chain continues unaffected.
# This preserves the design memo Scope ID 4 contract: "state-json-absence-causes-
# all-hooks-to-fall-back-to-legacy-envelope-only-decision-paths-with-zero-test-
# regression".

[ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -z "${REIN_PROJECT_DIR_OVERRIDE:-}" ] && exit 0

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib/state-machine.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=./lib/state-machine.sh
. "$LIB" 2>/dev/null || exit 0

# Resolve python for envelope parse.
PYTHON=""
if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
  # shellcheck source=./lib/python-runner.sh
  . "$SCRIPT_DIR/lib/python-runner.sh"
  resolve_python 2>/dev/null && PYTHON="${PYTHON_RUNNER[0]:-}"
fi
[ -z "$PYTHON" ] && exit 0

INPUT=$(cat)

# Extract file_path(s). Same semantics as post-edit-review-gate (Edit/Write +
# MultiEdit edits[]).
EXTRACTOR="$SCRIPT_DIR/lib/extract-hook-json.py"
[ -f "$EXTRACTOR" ] || exit 0

FILE_PATHS=$(printf '%s' "$INPUT" | "$PYTHON" "$EXTRACTOR" \
  --field tool_input.file_path \
  --array-of tool_input.edits --subfield file_path \
  --array-of tool_result.edits --subfield file_path \
  --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
if [ -z "$FILE_PATHS" ]; then
  FILE_PATHS=$(printf '%s' "$INPUT" | "$PYTHON" "$EXTRACTOR" \
    --field tool_result.file_path --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
fi
[ -z "$FILE_PATHS" ] && exit 0

# Classify path into kind. Source extensions inherit from post-edit-review-gate.
classify_kind() {
  local p="$1" base
  base=$(basename "$p")
  # Order matters: more specific patterns first (codex Round 2 X4.C.2 Medium
  # fix — trail/dod/* was previously shadowed by trail/*).
  case "$p" in
    */trail/dod/*|trail/dod/*|*/dod-*.md|dod-*.md) echo "dod"; return ;;
    */trail/*|trail/*) echo "trail"; return ;;
    */docs/specs/*|docs/specs/*) echo "spec"; return ;;
    */docs/plans/*|docs/plans/*) echo "plan"; return ;;
  esac
  case "$base" in
    Dockerfile|Dockerfile.*) echo "source"; return ;;
  esac
  if echo "$p" | grep -qE '\.(ts|tsx|js|jsx|py|sh|yml|yaml|json|toml|css|scss|html|sql|go|rs|java|kt|rb)$'; then
    echo "source"; return
  fi
  echo "other"
}

# Append journal entry for each file. Single lock acquisition wrapping all
# appends in one batch (avoids N lock acquire/release cycles for MultiEdit).
acquire_state_lock x || exit 0
while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  kind=$(classify_kind "$FILE_PATH")
  # Skip trail/ — internal bookkeeping, not user source intent.
  [ "$kind" = "trail" ] && continue
  append_journal edits "edit	$FILE_PATH	$kind" >/dev/null 2>&1 || true
done <<< "$FILE_PATHS"
release_state_lock

exit 0
