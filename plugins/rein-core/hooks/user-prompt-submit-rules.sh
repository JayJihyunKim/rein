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
#
# Wave 3 extension (Task 2.1): when `lib/bootstrap-check.sh` reports the
# resolved project_dir lacks `trail/` (exit 10), prepend the helper's bilingual
# guidance to the rule body in a single additionalContext envelope. Helper
# exit 0 (already bootstrapped) or 11 (unsafe project_dir — plugin cache,
# $HOME, etc.) silently passes through, preserving the v1.1.0 behaviour.
set -uo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# ---- Bootstrap advisory (Wave 3) -------------------------------------------
# Source bootstrap-check helper and capture stdout via sentinel idiom (same
# trailing-newline-preservation pattern as the rule body load below). The
# helper writes guidance text on exit 10 and nothing on exit 0 / 11.
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

# ---- Rule body load (v1.1.0 unchanged) -------------------------------------
# Sentinel idiom — command substitution strips trailing newlines, so the
# helper's pass-through body would lose its final `\n` (violating the
# no-truncation contract). Append `x` inside a guarded subshell so the
# subshell's exit code reflects rule_inject_body's rc, not printf's.
if ! BODY=$(if rule_inject_body short/answer-only-summary; then printf x; else exit 1; fi); then
  exit 0
fi
BODY="${BODY%x}"
[ -n "$BODY" ] || exit 0

# ---- Response-tone rule (TONE-1, 2026-05-27; communication-improve, 2026-05-28)
# Inject the SHORT response-tone summary every turn so assistant chat output
# stays plain-language (rein internal IDs/paths translated, 3-step reporting
# structure, trail/MEMORY verbatim quotes avoided). The full body lives in
# `rules/response-tone.md` and is delivered by `session-start-rules.sh`
# at session boundary; per-turn we ship the compact reminder to keep token
# cost flat (~80 tokens vs ~250 for full).
# Fail-open: body resolution failure leaves TONE_BODY empty and the hook
# emits the existing answer-only summary unchanged.
TONE_BODY=$(if rule_inject_body short/response-tone-summary; then printf x; else exit 1; fi) || TONE_BODY=""
TONE_BODY="${TONE_BODY%x}"

# ---- Combine + emit --------------------------------------------------------
if [ -n "$BOOTSTRAP_GUIDANCE" ]; then
  COMBINED="${BOOTSTRAP_GUIDANCE}
---

${BODY}"
else
  COMBINED="$BODY"
fi

if [ -n "$TONE_BODY" ]; then
  COMBINED="${COMBINED}

---

${TONE_BODY}"
fi

ESCAPED=$(printf '%s' "$COMBINED" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
