#!/usr/bin/env bash
# Plugin SessionStart hook — emit the active persona preset in its OWN envelope.
#
# Persona was previously appended to session-start-rules.sh's single envelope
# and got truncated when that envelope overflowed the per-hook cap (the
# persona-not-activating bug). Splitting it into a dedicated hook gives the
# persona its own per-hook size budget, so it survives regardless of how the
# rules block grows. hooks.json runs this hook AFTER session-start-rules.sh
# ("tone applied last" ordering — note this is ORDER ONLY; precedence authority
# lives in the invariant layer text, not here).
#
# Single trust boundary (spec §10): the preset path comes ONLY from the
# loader's `--persona-file` — the loader resolves builtin-vs-custom, validates
# the name, and prints the one absolute path (or nothing when disabled/absent).
# This hook never composes preset paths itself.
#
# Invariant-first injection: the envelope body is ALWAYS the invariant layer
# (`rules/persona/_invariant.md`) first, then `---`, then the frontmatter-
# stripped preset body. No invariant file -> no injection at all (double
# defense: character text never ships without the precedence/discipline layer).
#
# Emits a single SessionStart envelope to stdout when a persona is active:
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":<body>}}
#
# Graceful degrade / fail-open (all exit 0, empty stdout — Claude Code treats
# empty stdout as a no-op SessionStart): CLAUDE_PLUGIN_ROOT unset, rules dir or
# loader missing, loader prints nothing (persona disabled / neutral default),
# resolved preset file missing, invariant file missing, empty preset body.
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

# Resolve the active preset FILE via the loader (single trust boundary).
# `--persona-file` prints the validated absolute path (builtin wins over a
# same-named custom; unknown names downgrade fail-safe) and prints nothing when
# the persona is disabled or unconfigured. `|| true` keeps the hook alive on
# any loader error.
PERSONA_FILE=$(python3 "$LOADER" --persona-file || true)
[ -n "$PERSONA_FILE" ] || exit 0
[ -f "$PERSONA_FILE" ] || exit 0

# Invariant layer is mandatory — no injection without it (double defense).
INVARIANT_FILE="$RULES_DIR/persona/_invariant.md"
[ -f "$INVARIANT_FILE" ] || exit 0

# Preset body: strip a leading `---` frontmatter block, keep the rest verbatim.
PRESET_BODY=$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm {print}' "$PERSONA_FILE")
[ -n "$PRESET_BODY" ] || exit 0

# Sentinel idiom — command substitution strips trailing newlines; append a
# sentinel byte and strip it so the invariant body passes through byte-exact.
INVARIANT_BODY=$(cat "$INVARIANT_FILE"; printf x)
INVARIANT_BODY="${INVARIANT_BODY%x}"

# Assemble: invariant layer first, divider, then the stripped preset body.
CONTENT="${INVARIANT_BODY}"$'\n\n---\n\n'"${PRESET_BODY}"

# JSON-encode via python3 (handles all escaping) and print the envelope.
ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
