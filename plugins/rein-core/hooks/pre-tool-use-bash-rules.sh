#!/usr/bin/env bash
# Plugin PreToolUse(Bash) hook — tool-brief delivery for background-jobs rule.
#
# This is a SEPARATE hook from the policy Bash guards:
#   - pre-bash-{safety-guard,test-commit-gate}.sh: block on review-stamp / DoD / safety violations
#   - this hook: advisory reminder only (no blocking)
#
# Claude Code accumulates additionalContext from multiple hooks under the
# same matcher, so this can coexist with the guard.
#
# Scope ID: pre-tool-use-bash-hook-emits-background-jobs-action-mandate-plus-body-as-advisory-additional-context-after-bash-tool-selection-for-next-reasoning-step
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# Sentinel idiom — preserve trailing newlines (see rule-inject.sh for
# rationale). The if-then-else inside the subshell makes the subshell rc
# reflect rule_inject_body's rc instead of printf's success.
if ! BODY=$(if rule_inject_body background-jobs; then printf x; else exit 1; fi); then
  exit 0
fi
BODY="${BODY%x}"
[ -n "$BODY" ] || exit 0

ESCAPED=$(printf '%s' "$BODY" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$ESCAPED"
