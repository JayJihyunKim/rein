#!/usr/bin/env bash
# Plugin SessionStart hook — emit prompt-only rules to additionalContext.
#
# Reads 3 rule body files from
#   ${CLAUDE_PLUGIN_ROOT}/skills/rules-prompt/{code-style,security,testing}.md
# concatenates them (separated by `\n\n`), JSON-encodes the result, and prints
# a single SessionStart envelope to stdout:
#
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":<concatenated>}}
#
# Per-rule policy override (Phase 2 Task 2.8):
#   For each rule, if `.rein/policy/rules.yaml` defines
#   `<rule>: { override: <body> }`, the override BODY REPLACES the default
#   rule body in the concatenation. Replace, not append. Per-rule, not
#   all-or-nothing. Fail-open on every error: missing yaml, malformed
#   yaml, missing PyYAML, or any unexpected shape falls back to the
#   default body for that rule (Plan Tasks 2.9 + 2.10).
#
# Graceful degrade: when the rules dir does not exist (e.g. plugin layout
# regression or a partial install), exit 0 silently with no envelope —
# Claude Code hooks treat empty stdout as a no-op SessionStart.
#
# Scope ID: prompt-only-rules-inject-via-session-start-hook-on-session-begin
#           policy-rules-yaml-overrides-rule-text-when-present
set -euo pipefail

# Graceful degrade: if CLAUDE_PLUGIN_ROOT is unset (not in plugin runtime)
# OR if the rules-prompt dir doesn't exist (partial install / layout
# regression), exit 0 silently — Claude Code treats empty stdout as a
# no-op SessionStart so the rest of session bootstrap still proceeds.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
RULES_DIR="${CLAUDE_PLUGIN_ROOT}/skills/rules-prompt"
LOADER="${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py"
if [ ! -d "$RULES_DIR" ]; then
  exit 0
fi

CONTENT=""
for RULE in code-style security testing; do
  # Per-rule override probe (Task 2.8). The loader prints the override body
  # if `.rein/policy/rules.yaml` defines one for this rule, else nothing.
  # We deliberately do NOT silence loader stderr — when the user's
  # `.rein/policy/rules.yaml` is malformed, the loader emits a one-line
  # `warning:` to stderr (Plan Task 2.10 fail-open). Passing it through
  # gives the user a single, visible diagnostic instead of swallowing it.
  # `|| true` keeps the loop alive on any non-zero exit (defence-in-depth
  # — the loader's own contract is exit 0 on every path).
  OVERRIDE=""
  if [ -f "$LOADER" ]; then
    OVERRIDE=$(python3 "$LOADER" --rule-override "$RULE" || true)
  fi

  if [ -n "$OVERRIDE" ]; then
    # Override body replaces the default for this rule.
    CONTENT+="$OVERRIDE"$'\n\n'
  else
    # No override → fall back to bundled default body.
    RULE_FILE="$RULES_DIR/${RULE}.md"
    [ -f "$RULE_FILE" ] || continue
    CONTENT+="$(cat "$RULE_FILE")"$'\n\n'
  fi
done

# Empty CONTENT (no defaults available, no overrides) — exit silently.
if [ -z "$CONTENT" ]; then
  exit 0
fi

# JSON-encode CONTENT via python3 (handles all escaping including newlines,
# quotes, control chars). Print envelope to stdout.
ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
