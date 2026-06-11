#!/usr/bin/env bash
# Plugin UserPromptSubmit hook — per-turn brief delivery (single spawn).
#
# Emits a single UserPromptSubmit envelope to stdout:
#
#   {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<body>"}}
#
# The body = answer-only summary + response-tone summary + persona summary
# (when the persona layer is enabled). The whole composition AND its JSON
# envelope are produced by ONE python process (`rein-policy-loader.py
# --turn-brief`), down from the previous three per-turn spawns (two
# rule_inject_body override probes + a final json.dumps). The bootstrap
# advisory below is the only dynamic, bash-computed piece; it is handed to the
# loader via env REIN_TURN_BRIEF_PREPEND so no second python spawn is needed
# (PT-8 perf contract: hot path stays at one spawn while adding persona).
#
# Graceful degrade: empty CLAUDE_PLUGIN_ROOT, missing loader, or an empty
# turn-brief (answer-only summary absent) → exit 0 with empty stdout (Claude
# Code treats empty stdout as no-op).
#
# Scope ID: PT-8 (user-prompt-submit-single-spawn-turn-brief-with-persona)
#
# Wave 3 extension (Task 2.1): when `lib/bootstrap-check.sh` reports the
# resolved project_dir lacks `trail/` (exit 10), prepend the helper's bilingual
# guidance to the body. Helper exit 0 (already bootstrapped) or 11 (unsafe
# project_dir — plugin cache, $HOME, etc.) silently passes through.
set -uo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

LOADER="${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py"
[ -f "$LOADER" ] || exit 0

# ---- Bootstrap advisory (Wave 3, bash — no python) -------------------------
# Source bootstrap-check helper and capture stdout via sentinel idiom (preserve
# trailing newlines). The helper writes guidance text on exit 10 and nothing on
# exit 0 / 11.
BOOTSTRAP_GUIDANCE=""
BOOTSTRAP_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"
if [ -f "$BOOTSTRAP_HELPER" ]; then
  # shellcheck disable=SC1090
  . "$BOOTSTRAP_HELPER"
  BOOTSTRAP_RC=0
  GUIDANCE_RAW=$(if bootstrap_check; then printf x; else rc=$?; printf x; exit "$rc"; fi) || BOOTSTRAP_RC=$?
  GUIDANCE_RAW="${GUIDANCE_RAW%x}"
  if [ "$BOOTSTRAP_RC" = "10" ]; then
    BOOTSTRAP_GUIDANCE="$GUIDANCE_RAW"
  fi
fi

# ---- Single-spawn turn-brief -----------------------------------------------
# The loader composes the body + json-encodes the full envelope in one process.
# Pass the dynamic bootstrap guidance via env so the loader prepends it without
# a second spawn. Empty output (answer-only summary absent) → no-op.
#
# REIN_TURN_BRIEF_PREPEND is set EXPLICITLY on the loader invocation (empty when
# no guidance fired) so an inherited/stale value from the environment cannot
# leak into the per-turn envelope — the hook is the sole legitimate source of
# the prepend (trust boundary).
REIN_TURN_BRIEF_PREPEND="$BOOTSTRAP_GUIDANCE" python3 "$LOADER" --turn-brief || true
