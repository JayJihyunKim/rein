#!/usr/bin/env bash
# Plugin SessionStart hook — emit the active persona preset in its OWN envelope.
#
# Persona was previously appended to session-start-rules.sh's single envelope
# and got truncated when that envelope overflowed the per-hook cap (the
# persona-not-activating bug). Splitting it into a dedicated hook gives the
# persona its own per-hook size budget (~1.6KB << 10,000-char cap), so it
# survives regardless of how the rules block grows. hooks.json runs this hook
# AFTER session-start-rules.sh ("tone applied last" ordering — note this is
# ORDER ONLY; precedence authority lives in the preset body text, not here).
#
# Emits a single SessionStart envelope to stdout when a persona is active:
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":<body>}}
#
# Conditional / fail-open (opt-out aware): the loader's --persona prints the
# VALIDATED active preset name when enabled, nothing when disabled. When the
# persona is disabled, the loader is absent, CLAUDE_PLUGIN_ROOT is unset, or
# the preset body file is missing, this hook exits 0 with empty stdout — Claude
# Code treats empty stdout as a no-op SessionStart.
#
# Scope ID: PT-3 (persona-isolated-into-own-session-start-hook)
set -euo pipefail

# Graceful degrade: not in plugin runtime, or rules dir missing.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
RULES_DIR="${CLAUDE_PLUGIN_ROOT}/rules"
LOADER="${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py"
if [ ! -d "$RULES_DIR" ] || [ ! -f "$LOADER" ]; then
  exit 0
fi

# Resolve the active preset. The loader validates the name (format allowlist
# ^[a-z0-9-]+$ AND membership in KNOWN_PERSONA_PRESETS) and prints nothing when
# the persona is disabled. The hook therefore only ever composes a path from a
# loader-validated name — preserving the single trust boundary (PT-3 reuses the
# existing PP-3 validation). `|| true` keeps the hook alive on any loader error.
PERSONA=$(python3 "$LOADER" --persona || true)
[ -n "$PERSONA" ] || exit 0

PERSONA_FILE="$RULES_DIR/persona/${PERSONA}.md"
[ -f "$PERSONA_FILE" ] || exit 0

# Sentinel idiom — command substitution strips trailing newlines; append a
# sentinel byte and strip it so the body passes through byte-exact.
CONTENT=$(cat "$PERSONA_FILE"; printf x)
CONTENT="${CONTENT%x}"
[ -n "$CONTENT" ] || exit 0

# JSON-encode via python3 (handles all escaping) and print the envelope.
ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
