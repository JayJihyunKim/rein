#!/bin/bash
# Hook: SessionStart
# Detect a project directory where the Rein plugin is enabled but repo-local
# state has not been initialized yet. SessionStart cannot ask interactively
# itself, so it injects concise context instructing Claude to ask before
# bootstrapping.
#
# Implementation: delegates the actual safety + presence predicate to the
# shared helper `hooks/lib/bootstrap-check.sh` (Wave 1 source of truth).
# This hook owns only the SessionStart-specific stdout emit shape and the
# CLAUDE_PLUGIN_ROOT guard. The helper handles project_dir resolution,
# unsafe-path detection (plugin cache / sensitive paths / unwritable), and
# the trail/ presence check.

set -uo pipefail

# Without CLAUDE_PLUGIN_ROOT we cannot locate the helper or the bootstrap
# script the guidance text references. Silently exit so SessionStart does
# not block.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"
if [ ! -f "$HELPER" ]; then
  exit 0
fi

# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"

# Capture helper stdout (the bilingual guidance text on rc=10) without
# letting `set -e` short-circuit on rc=10/11. The `set -uo pipefail` above
# does not include `errexit`, so this $() will not abort on non-zero rc.
#
# Sentinel idiom — plain command substitution `$(bootstrap_check)` strips
# the helper's trailing newline, breaking byte-level parity with direct
# helper invocation (and with the pre-refactor hook which used a here-doc
# emit that retained the newline). Wrap the call so the subshell appends a
# sentinel `x` AFTER the helper's stdout, then strip the sentinel; this
# preserves any trailing `\n` the helper wrote while keeping the subshell's
# exit code equal to bootstrap_check's rc (same pattern as
# user-prompt-submit-rules.sh:39 and the rule-inject body capture).
HELPER_RC=0
HELPER_OUT=$(if bootstrap_check; then printf x; else rc=$?; printf x; exit "$rc"; fi) || HELPER_RC=$?
HELPER_OUT="${HELPER_OUT%x}"

if [ "$HELPER_RC" = "10" ]; then
  # trail/ missing on a safe project_dir: emit the helper's guidance text
  # directly to SessionStart stdout. The pre-refactor hook used a plain
  # stdout emit (no JSON envelope), so we preserve that shape.
  printf '%s' "$HELPER_OUT"
fi

# rc=0  (trail present)         → silent
# rc=11 (unsafe project_dir)    → silent (helper already logged stderr)
# rc=10 (guidance emitted)      → already printed above
exit 0
