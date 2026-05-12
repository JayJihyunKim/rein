#!/usr/bin/env bash
# Plugin PreToolUse(Agent) hook — tool-brief delivery for subagent-review rule.
#
# Advisory reminder: not a block. Emits a single PreToolUse envelope so the
# subagent-review action mandate is visible alongside the Agent tool result
# in the next model reasoning step.
#
# Graceful degrade: empty CLAUDE_PLUGIN_ROOT or body resolution failure →
# exit 0 silently.
#
# Scope ID: pre-tool-use-agent-hook-emits-subagent-review-action-mandate-plus-body-as-advisory-additional-context-after-agent-tool-selection-for-next-reasoning-step
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# Sentinel idiom — preserve trailing newlines (see rule-inject.sh for
# rationale). The if-then-else inside the subshell makes the subshell rc
# reflect rule_inject_body's rc instead of printf's success.
if ! BODY=$(if rule_inject_body subagent-review; then printf x; else exit 1; fi); then
  exit 0
fi
BODY="${BODY%x}"
[ -n "$BODY" ] || exit 0

ESCAPED=$(printf '%s' "$BODY" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$ESCAPED"
