#!/usr/bin/env bash
# Plugin UserPromptSubmit hook — turn-brief delivery for answer-only-mode rule.
#
# Reads the rule body via the shared rule-inject helper (applying any
# `.rein/policy/rules.yaml` per-rule override), then emits a single
# UserPromptSubmit envelope to stdout:
#
#   {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<body>"}}
#
# Graceful degrade: empty CLAUDE_PLUGIN_ROOT or body resolution failure →
# exit 0 silently (Claude Code treats empty stdout as no-op).
#
# Scope ID: user-prompt-submit-hook-injects-answer-only-mode-action-mandate-plus-body-every-user-turn
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# Sentinel idiom — command substitution strips trailing newlines, so the
# helper's pass-through body would lose its final `\n` (violating the
# no-truncation contract). Append `x` inside a guarded subshell so the
# subshell's exit code reflects rule_inject_body's rc, not printf's.
if ! BODY=$(if rule_inject_body answer-only-mode; then printf x; else exit 1; fi); then
  exit 0
fi
BODY="${BODY%x}"
[ -n "$BODY" ] || exit 0

ESCAPED=$(printf '%s' "$BODY" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
