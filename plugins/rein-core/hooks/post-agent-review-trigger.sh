#!/bin/bash
# Hook: PostToolUse(Agent) — feature-builder 완료 후 codex-review 넛지
#
# feature-builder 계열 subagent 가 완료되고 trail/dod/.review-pending 이 존재하면
# Claude 에게 /codex-review 실행을 지시하는 PostToolUse "block" 피드백을 반환한다.
#
# Fail-open, silent: PostToolUse 는 best-effort nudge 이므로 python3 부재·JSON
# 파싱 실패 시 exit 0 으로 조용히 종료 (pre-hook 의 fail-closed 정책과 다름).
# 잘못된 envelope 는 절대 emit 하지 않는다.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"

PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"

# --- Python resolver (post-hook: silent/fail-open on failure) -----------------
resolve_python 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  exit 0
fi

# --- Read stdin JSON and extract tool_input.subagent_type ---------------------
INPUT=$(cat)

SUBAGENT_TYPE=$(printf '%s' "$INPUT" \
  | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_input.subagent_type --default '' 2>/dev/null) || SUBAGENT_TYPE=""

# --- Normalize: strip leading namespace (e.g. "rein:feature-builder" → "feature-builder") ---
# Remove everything up to and including the first colon if present.
SUBAGENT_TYPE_NORM="${SUBAGENT_TYPE#*:}"
# If there was no colon, the above is a no-op; if the whole string was "rein:foo", we get "foo".
# Guard: if original had no colon, #*: strips nothing (bash keeps the original). This is correct.
# But if input is "feature-builder" (no colon), ${var#*:} = "feature-builder" (unchanged). Good.

# --- Allowlist check ----------------------------------------------------------
case "$SUBAGENT_TYPE_NORM" in
  feature-builder|feature-builder-fix|feature-builder-refactor)
    : # in allowlist, continue
    ;;
  *)
    exit 0
    ;;
esac

# --- Guard: .review-pending must exist ----------------------------------------
if [ ! -f "$REVIEW_PENDING" ]; then
  exit 0
fi

# --- Emit PostToolUse block feedback via python3 json.dumps -------------------
# Build JSON safely — never hand-rolled string concat.
"${PYTHON_RUNNER[@]}" - <<'PYEOF'
import json
import sys

reason = (
    "A feature-builder-family subagent just finished, and the source-code "
    "changes are now waiting for code review. "
    "(A pending-review marker file `trail/dod/.review-pending` was created.) "
    "Run `/codex-review` on the changed files next. "
    "Do not commit or make further edits until the code-review-complete "
    "marker file (`trail/dod/.codex-reviewed`) is in place. "
    "When you relay this state to the user in chat, translate the marker "
    "file names into plain language (\"a review-pending marker\" / "
    "\"the code-review-complete marker\") and avoid raw internal "
    "identifiers like `stamp` or `.review-pending` — see "
    "`plugins/rein-core/rules/response-tone.md`."
)

envelope = {
    "decision": "block",
    "reason": reason,
}

sys.stdout.write(json.dumps(envelope))
sys.stdout.write("\n")
PYEOF
rc=$?
if [ "$rc" -ne 0 ]; then
  # Python failed to emit — fail open, no malformed output.
  exit 0
fi

exit 0
