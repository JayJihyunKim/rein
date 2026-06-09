#!/usr/bin/env bash
# Plugin SessionStart hook — emit prompt-only rules to additionalContext.
#
# Reads 4 rule body files from
#   ${CLAUDE_PLUGIN_ROOT}/rules/{code-style,security,testing,operating-sequence}.md
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
# OR if the rules dir doesn't exist (partial install / layout regression),
# exit 0 silently — Claude Code treats empty stdout as a no-op SessionStart
# so the rest of session bootstrap still proceeds.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
RULES_DIR="${CLAUDE_PLUGIN_ROOT}/rules"
LOADER="${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py"
if [ ! -d "$RULES_DIR" ]; then
  exit 0
fi

# ONBOARD-1: first-session onboarding. This hook is the LAST SessionStart hook
# (bootstrap → load-trail → rules), so it is the SOLE marker writer
# (SCOPE-SINGLE-WRITER): bootstrap (earlier) only reads the marker for its
# stdout emit, this hook prepends the primer to additionalContext AND writes
# the marker afterward. Because rules runs last, bootstrap always observes the
# marker-absent snapshot in the same session → the two channels stay
# synchronized without a lock.
ONBOARDED_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/onboarded-check.sh"
ONBOARDED_HELPER_LOADED=0
if [ -f "$ONBOARDED_HELPER" ]; then
  # shellcheck disable=SC1091
  source "$ONBOARDED_HELPER"
  ONBOARDED_HELPER_LOADED=1
fi

# Resolve PROJECT_DIR (user git root) the same way the bootstrap hook does, so
# the marker is read/written under the user's project, not the plugin root.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Snapshot marker presence BEFORE building/emitting content. We must capture
# the first-session decision once: prepend the primer iff the helper loaded and
# the marker is absent, then write the marker only after the envelope is emitted.
ONBOARD_FIRST_SESSION=0
if [ "$ONBOARDED_HELPER_LOADED" = "1" ] && ! rein_is_onboarded "$PROJECT_DIR"; then
  ONBOARD_FIRST_SESSION=1
fi

CONTENT=""
for RULE in code-style security testing operating-sequence routing-map response-tone; do
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

# persona injection (PP-9, PP-10): active preset only — O(1), no full scan.
# The loader (--persona) prints the VALIDATED active preset name when
# enabled, nothing when disabled. Injection position is AFTER response-tone
# ("tone applied last"); note this is ORDER ONLY — precedence authority lives
# in the preset body text (PP-10), not in injection position.
# graceful degrade: loader absent / empty output (disabled) / file absent ->
# silent skip, SessionStart envelope stays intact.
PERSONA=""
if [ -f "$LOADER" ]; then
  PERSONA=$(python3 "$LOADER" --persona || true)
fi
if [ -n "$PERSONA" ]; then
  PERSONA_FILE="$RULES_DIR/persona/${PERSONA}.md"
  [ -f "$PERSONA_FILE" ] && CONTENT+="$(cat "$PERSONA_FILE")"$'\n\n'
fi

# Empty CONTENT (no defaults available, no overrides) — exit silently.
if [ -z "$CONTENT" ]; then
  exit 0
fi

# ONBOARD-1: on the first session prepend the primer to the front of the 6-rule
# additionalContext (same envelope's content extended — NOT a second envelope,
# preserving the one-envelope-per-SessionStart contract). The primer body comes
# from the shared single definition (rein_primer_body) so it is byte-identical
# to the user-stdout channel emitted by the bootstrap hook.
if [ "$ONBOARD_FIRST_SESSION" = "1" ]; then
  CONTENT="$(rein_primer_body)"$'\n\n'"$CONTENT"
fi

# JSON-encode CONTENT via python3 (handles all escaping including newlines,
# quotes, control chars). Print envelope to stdout.
ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"

# ONBOARD-1 (sole marker writer): only after the envelope is emitted, and only
# if this was the first session, write the onboarded marker so subsequent
# sessions stay silent on both channels. Marker write failure is non-blocking
# (assumption B): worst case is one duplicate primer next session — harmless.
if [ "$ONBOARD_FIRST_SESSION" = "1" ]; then
  version=$(python3 -c "import json;print(json.load(open('${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "")
  rein_mark_onboarded "$PROJECT_DIR" "$version" || true
fi
