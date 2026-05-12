#!/usr/bin/env bash
# Plugin PostToolUse(Edit|Write|MultiEdit) sub-hook — event-brief delivery
# for the design-plan-coverage rule.
#
# Triggers when an Edit/Write/MultiEdit targets a design/plan/DoD document:
#   - docs/specs/**
#   - docs/plans/**
#   - trail/dod/dod-*.md
#
# Emits a PostToolUse envelope so the design-plan-coverage 행동 강령
# (coverage matrix mandate) is visible in the next model request — companion
# to (not replacement for) post-edit-plan-coverage.sh's validator gate.
#
# Silent exit 0 when:
#   - CLAUDE_PLUGIN_ROOT unset (scaffold mode — rule body lives elsewhere)
#   - stdin empty / malformed JSON
#   - file path does not match the watched globs
#   - rule body unresolvable
#
# This hook never blocks (no exit 2). Path classification is glob-based
# (cheap), not file-existence based — the model gets the brief regardless
# of whether the validator finds a matrix on disk.
#
# Scope ID: post-tool-use-injects-design-plan-coverage-action-mandate-plus-body-when-edit-write-targets-docs-specs-or-docs-plans-or-trail-dod-dod
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# Hook input on stdin (Claude Code JSON envelope). Extract file_path with
# the same fallback chain used by post-edit-plan-coverage.sh so both hooks
# agree on the path they care about:
#   tool_input.file_path  (primary)
#   tool_response.filePath (secondary — Claude Code response field)
#   tool_result.file_path  (legacy tertiary — older payload shape)
INPUT=$(cat || true)
[ -n "$INPUT" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("")
    sys.exit(0)
if not isinstance(data, dict):
    print("")
    sys.exit(0)
ti = data.get("tool_input") or {}
tr = data.get("tool_response") or {}
tl = data.get("tool_result") or {}
p = ""
if isinstance(ti, dict):
    p = ti.get("file_path") or ""
if not p and isinstance(tr, dict):
    p = tr.get("filePath") or ""
if not p and isinstance(tl, dict):
    p = tl.get("file_path") or ""
print(p or "")
' 2>/dev/null || true)

[ -n "$FILE_PATH" ] || exit 0

# Glob match — accept absolute or repo-relative paths. Order matters: the
# trail/dod pattern requires a `dod-` prefix on the filename, while the
# docs/specs and docs/plans patterns match any descendant.
case "$FILE_PATH" in
  */docs/specs/*|docs/specs/*) ;;
  */docs/plans/*|docs/plans/*) ;;
  */trail/dod/dod-*.md|trail/dod/dod-*.md) ;;
  *) exit 0 ;;
esac

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# Sentinel idiom — preserve trailing newlines (see rule-inject.sh for
# rationale). The if-then-else inside the subshell makes the subshell rc
# reflect rule_inject_body's rc instead of printf's success.
if ! BODY=$(if rule_inject_body design-plan-coverage; then printf x; else exit 1; fi); then
  exit 0
fi
BODY="${BODY%x}"
[ -n "$BODY" ] || exit 0

ESCAPED=$(printf '%s' "$BODY" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$ESCAPED"
