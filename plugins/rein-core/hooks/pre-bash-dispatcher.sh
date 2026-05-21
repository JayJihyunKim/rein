#!/usr/bin/env bash
# Plugin PreToolUse(Bash) — single-entry dispatcher.
#
# Cycle X2 (영역 A, plan §4.1). Replaces the multi-entry Bash matcher in
# hooks.json (bootstrap-gate + safety-guard always + ~30 `if`-gated entries for
# test-commit-gate + bash-rules) with a single hook invocation. The dispatcher
# inlines the always-run check ordering, classifies the command via
# lib/bash-classifier.sh, then invokes the conditional helpers as needed.
#
# Why this collapse exists:
#   - hooks.json shrinks from ~36 Bash matcher entries to 1, removing the
#     "forgot to add pattern X to both `if` lists" foot-gun
#   - INPUT JSON is parsed exactly once per Bash invocation in the dispatcher,
#     and re-fed to downstream helpers via stdin so they see the same envelope
#   - Classification is centralized in lib/bash-classifier.sh — single source
#     of truth that both the dispatcher and adversarial tests share
#
# Why this is NOT (yet) a full inline:
#   - The downstream helper bodies (bootstrap, safety, test-commit, rules)
#     each pull in several `lib/*` sources and have their own policy-toggle
#     logic. Inlining them would require a larger refactor of those libs into
#     pure functions — deferred to a follow-up cycle (X2.5 / X3 bundle).
#   - This cycle prioritizes the hooks.json simplification + classification
#     SSOT; latency measurement (SPIKE-1 style) is a separate cycle.
#
# Exit codes propagate from the first failing downstream helper. Order:
#   1. pre-tool-use-bash-bootstrap-gate.sh  (always)
#   2. pre-bash-safety-guard.sh             (always)
#   3. pre-bash-test-commit-gate.sh         (if classified as test/commit)
#   4. pre-tool-use-bash-rules.sh           (if classified as test/build)
#
# Plugin runtime guard — outside the plugin runtime (ad-hoc shell invocation),
# pass through silently. Same posture as the individual gates.
[ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && exit 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Read INPUT once, feed downstream via stdin ---
#
# Each downstream helper independently re-reads stdin to extract tool_input.
# We hold the captured INPUT in this dispatcher and pipe it back so every
# helper sees the same envelope. The captured INPUT also feeds the classifier
# below, so a single python3 invocation does the JSON extraction.
#
# Fail-closed posture (Cycle X2, codex review Rounds 1-3): if the classifier
# or its preconditions are unavailable, CLASS_NEEDS_TC defaults to 1 so the
# test-commit gate still fires conservatively. Only the bash-rules advisory
# helper is allowed to silently no-op when absent. See invoke_hook_required
# vs invoke_hook_advisory below for the missing-helper policy.
INPUT=$(cat)

# --- Extract command for classification ---
#
# COMMAND_EXTRACTED tracks whether tool_input.command was *positively*
# extracted from INPUT. python3 missing, extractor missing, or any rc != 0
# leaves COMMAND_EXTRACTED=0, which keeps the conservative default
# CLASS_NEEDS_TC=1 (no classifier call). An EMPTY-string command on rc=0 is
# treated as successfully extracted and intentionally empty — classifier
# correctly classifies it as no-gates-needed.
#
# Codex review Round 2 Medium 2.2: previously, extraction failure produced
# COMMAND="" and the classifier reset CLASS_NEEDS_TC=0, silently bypassing
# the commit gate on malformed envelopes. Separating extraction success
# from "command is empty" closes that hole.
COMMAND=""
COMMAND_EXTRACTED=0
if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
  # shellcheck source=./lib/python-runner.sh
  . "$SCRIPT_DIR/lib/python-runner.sh"
  if resolve_python 2>/dev/null; then
    # No --default flag: an absent tool_input.command field MUST surface as a
    # non-zero rc (extractor returns 21 for missing field) so the
    # COMMAND_EXTRACTED tracking can distinguish "field absent" from "field is
    # an explicitly empty string". With --default '' the extractor would
    # collapse both into rc 0 + empty COMMAND, which the classifier resets to
    # CLASS_NEEDS_TC=0 — the commit-gate bypass Round 3 Medium 3.1 caught.
    if COMMAND=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" \
        "$SCRIPT_DIR/lib/extract-hook-json.py" \
        --field tool_input.command 2>/dev/null); then
      COMMAND_EXTRACTED=1
    fi
  fi
fi

# --- Source classifier (fail-closed when source rc != 0) ---
#
# Defaults: CLASS_NEEDS_TC=1 (conservative), CLASS_NEEDS_BR=0 (advisory).
#
# The classifier is invoked only when ALL three preconditions hold:
#   (1) the lib file exists
#   (2) sourcing it succeeded (rc=0) — partial source failure (Round 2
#       Medium 2.1) is detected via the explicit rc capture below, not via
#       declare -F alone which would still pass for a partial load
#   (3) classify_bash_command function ended up defined after source
#   (4) the tool_input.command extraction above succeeded
# If any precondition fails, CLASS_NEEDS_TC stays at 1 (conservative) and
# CLASS_NEEDS_BR stays at 0 (advisory off), preserving the commit gate.
CLASS_NEEDS_TC=1
CLASS_NEEDS_BR=0
SOURCE_OK=0
if [ -f "$SCRIPT_DIR/lib/bash-classifier.sh" ]; then
  # shellcheck source=./lib/bash-classifier.sh
  if . "$SCRIPT_DIR/lib/bash-classifier.sh" 2>/dev/null; then
    SOURCE_OK=1
  fi
fi
if [ "$SOURCE_OK" = "1" ] \
   && declare -F classify_bash_command >/dev/null 2>&1 \
   && [ "$COMMAND_EXTRACTED" = "1" ]; then
  classify_bash_command "$COMMAND"
fi

# --- Cycle X4.C.2: state machine drain (영역 C) ---
#
# Fail-soft for state machine — drain errors do NOT change dispatcher exit code.
# The state.json + journal layer is advisory: if absent or broken, the legacy
# hook chain runs unchanged (design memo Scope ID 4: "state-json-absence-...
# zero-test-regression"). Drain is invoked BEFORE the downstream gates so that
# they see a fresh state.json if they ever start to read it (X4.C.3).
#
# Pass current Bash class so drain_state applies the about-to-execute
# transition (design memo §4.3 step 6 — codex Round 1 X4.C.2 HIGH fix).
if [ -f "$SCRIPT_DIR/lib/state-machine.sh" ]; then
  # shellcheck source=./lib/state-machine.sh
  if . "$SCRIPT_DIR/lib/state-machine.sh" 2>/dev/null \
     && declare -F drain_state >/dev/null 2>&1; then
    # Independent classification for state machine (codex Round 2 HIGH fix —
    # bash-classifier.sh misses `git  commit` repeated-whitespace; relying on
    # CLASS_NEEDS_TC would inherit that defect).
    _SM_CLASS=""
    if [ -n "$COMMAND" ]; then
      if echo "$COMMAND" | grep -qE '(^|[^a-zA-Z_])git[[:space:]]+commit\b'; then
        _SM_CLASS="commit"
      elif echo "$COMMAND" | grep -qE '(^|[^a-zA-Z_])(pytest|jest|vitest|mocha)\b' \
           || echo "$COMMAND" | grep -qE 'npm[[:space:]]+(run[[:space:]]+)?test\b' \
           || echo "$COMMAND" | grep -qE 'yarn[[:space:]]+test\b' \
           || echo "$COMMAND" | grep -qE 'pnpm[[:space:]]+test\b' \
           || echo "$COMMAND" | grep -qE 'python[[:space:]]+-m[[:space:]]+pytest\b'; then
        _SM_CLASS="test"
      fi
    fi
    drain_state "$_SM_CLASS" 2>/dev/null || true
  fi
fi

# --- invoke_hook_required: call a critical helper, fail-closed if missing ---
#
# For bootstrap / safety / (conditional) test-commit. A missing file here
# indicates plugin corruption — refusing the Bash call is safer than silently
# disabling the block points the helper enforces.
#
# Returns the helper's exit code. Helpers write their JSON deny payload to
# stdout (policy blocks) or `[rein] ...` lines to stderr (infra-integrity);
# both are forwarded as-is because we do not capture either stream.
invoke_hook_required() {
  local hook="$1"
  local label="$2"
  if [ ! -f "$hook" ]; then
    echo "[rein] Critical Bash gate helper missing: $label. The plugin install may be corrupted — run /plugin update rein to repair." >&2
    return 2
  fi
  printf '%s' "$INPUT" | bash "$hook"
  return $?
}

# --- invoke_hook_advisory: best-effort, skip if missing ---
#
# For bash-rules (rule injection only — no block enforcement). A missing file
# here only drops advisory context, which is acceptable as a degraded mode.
invoke_hook_advisory() {
  local hook="$1"
  [ -f "$hook" ] || return 0
  printf '%s' "$INPUT" | bash "$hook"
  return $?
}

# --- Step 1: bootstrap gate (always, required) ---
invoke_hook_required "$SCRIPT_DIR/pre-tool-use-bash-bootstrap-gate.sh" "bootstrap gate"
RC=$?
[ "$RC" -ne 0 ] && exit "$RC"

# --- Step 2: safety guard (always, required) ---
invoke_hook_required "$SCRIPT_DIR/pre-bash-safety-guard.sh" "safety guard"
RC=$?
[ "$RC" -ne 0 ] && exit "$RC"

# --- Step 3: test-commit gate (conditional, required when triggered) ---
if [ "$CLASS_NEEDS_TC" = "1" ]; then
  invoke_hook_required "$SCRIPT_DIR/pre-bash-test-commit-gate.sh" "test/commit gate"
  RC=$?
  [ "$RC" -ne 0 ] && exit "$RC"
fi

# --- Step 4: bash-rules rule injection (conditional, advisory) ---
if [ "$CLASS_NEEDS_BR" = "1" ]; then
  invoke_hook_advisory "$SCRIPT_DIR/pre-tool-use-bash-rules.sh"
  RC=$?
  [ "$RC" -ne 0 ] && exit "$RC"
fi

exit 0
