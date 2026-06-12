#!/bin/bash
# lib/bash-classifier.sh — Bash command classifier for pre-bash-dispatcher.sh
#
# Sourced (not executed). Defines classify_bash_command() that inspects a Bash
# command string and sets two globals:
#
#   CLASS_NEEDS_TC=0|1   — needs pre-bash-test-commit-gate.sh
#   CLASS_NEEDS_BR=0|1   — needs pre-tool-use-bash-rules.sh (rule injection)
#
# Classification mirrors the `if`-field patterns previously listed in hooks.json
# for the Bash matcher. Source of truth: the patterns enumerated in
# pre-bash-test-commit-gate.sh §command_invokes and the hooks.json Bash entries
# pre v1.4.0.
#
# Why globals (not stdout): bash subprocesses and pipes erase trailing newlines
# and complicate rc capture. Globals keep the call site to one assignment-free
# invocation that any caller can read.

# --- canonical git subcommand token model SSOT (GMF-1) ---
#
# Source the shared lib/git-subcommand-model.sh so the git-commit classifier
# uses the SAME matcher as the dispatcher + the gate-internal command_invokes
# (no mirrored literal — drift is structurally impossible). Tests source this
# classifier standalone (`. "$CLASSIFIER_LIB"`, no SCRIPT_DIR), so the lib dir
# is derived from ${BASH_SOURCE[0]}.
#
# fail-closed (codex R2 HIGH): if the lib is missing/corrupt or the matcher
# ends up undefined, _GIT_MODEL_OK=0 and the classifier conservatively gates
# any command carrying a `commit` token (over-trigger = safe direction; never
# a silent skip — the very false-negative this spec fixes).
_GIT_MODEL_OK=0
_bc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_bc_dir/git-subcommand-model.sh" ] && . "$_bc_dir/git-subcommand-model.sh" 2>/dev/null \
   && declare -F git_clause_invokes >/dev/null 2>&1; then
  _GIT_MODEL_OK=1
fi

# classify_bash_command <command-string>
#
# Mostly pure: the git-commit classification calls the SSOT shared matcher
# (git_clause_invokes, 1 grep subprocess); when the model lib fails to load it
# degrades fail-closed (commit token present → gate ON). Every other branch is
# pure (no I/O, no subprocess) other than the command-string argument. Safe to
# call repeatedly. Leading whitespace is stripped; comment-only commands and
# empty inputs classify as "no gates needed".
classify_bash_command() {
  CLASS_NEEDS_TC=0
  CLASS_NEEDS_BR=0
  local cmd="$1"

  # Strip leading whitespace.
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"

  [ -z "$cmd" ] && return 0

  # --- test-commit-gate triggers ---
  #
  # Source: hooks.json pre v1.4.0 + pre-bash-test-commit-gate.sh inner
  # command_invokes pattern. We match BOTH the bare token (e.g. "pytest") and
  # the trailing-arg form (e.g. "pytest tests/"), because the inner gate uses
  # a substring matcher and would have caught both even when hooks.json's
  # `if` field only listed the trailing-arg form.
  # git commit — canonical SSOT matcher (skips git global options, multi-space,
  # shell-token boundary, clause-start anchor so mentions are non-matched). The
  # case glob below cannot cover global-option forms (`git -C . commit`), so
  # git-commit is handled here, separately from the literal-prefix test runners.
  if [ "$_GIT_MODEL_OK" = 1 ]; then
    if git_clause_invokes "$GIT_COMMIT_ERE" "$cmd"; then
      CLASS_NEEDS_TC=1
    fi
  else
    # Model load failed = fail-closed. A `commit` token present → gate ON so the
    # commit gate does not silently leak (the false-negative this spec fixes).
    # over-trigger (mild false-positive) is the safe direction, not anti-trust.
    case "$cmd" in *commit*) CLASS_NEEDS_TC=1 ;; esac
  fi

  case "$cmd" in
    pytest | "pytest "*) CLASS_NEEDS_TC=1 ;;
    jest | "jest "*) CLASS_NEEDS_TC=1 ;;
    vitest | "vitest "*) CLASS_NEEDS_TC=1 ;;
    mocha | "mocha "*) CLASS_NEEDS_TC=1 ;;
    "npm test" | "npm test "*) CLASS_NEEDS_TC=1 ;;
    "npm run test" | "npm run test "*) CLASS_NEEDS_TC=1 ;;
    "yarn test" | "yarn test "*) CLASS_NEEDS_TC=1 ;;
    "pnpm test" | "pnpm test "*) CLASS_NEEDS_TC=1 ;;
    "python -m pytest" | "python -m pytest "*) CLASS_NEEDS_TC=1 ;;
    "npx jest" | "npx jest "*) CLASS_NEEDS_TC=1 ;;
    "npx vitest" | "npx vitest "*) CLASS_NEEDS_TC=1 ;;
    "bash tests/"*) CLASS_NEEDS_TC=1 ;;
  esac

  # --- bash-rules (rule injection) triggers ---
  #
  # Advisory hook — emits additionalContext to remind background-jobs rule for
  # long-running / test commands. NOT gated on commit (`git commit` does not
  # need rule injection — only the commit-format gate).
  case "$cmd" in
    pytest | "pytest "*) CLASS_NEEDS_BR=1 ;;
    "npm test" | "npm test "*) CLASS_NEEDS_BR=1 ;;
    "npm run test" | "npm run test "*) CLASS_NEEDS_BR=1 ;;
    "yarn test" | "yarn test "*) CLASS_NEEDS_BR=1 ;;
    "pnpm test" | "pnpm test "*) CLASS_NEEDS_BR=1 ;;
    "python -m pytest" | "python -m pytest "*) CLASS_NEEDS_BR=1 ;;
    "npx jest" | "npx jest "*) CLASS_NEEDS_BR=1 ;;
    "npx vitest" | "npx vitest "*) CLASS_NEEDS_BR=1 ;;
    "cargo build" | "cargo build "*) CLASS_NEEDS_BR=1 ;;
    "docker build" | "docker build "*) CLASS_NEEDS_BR=1 ;;
    playwright | "playwright "*) CLASS_NEEDS_BR=1 ;;
    make | "make "*) CLASS_NEEDS_BR=1 ;;
    tsc | "tsc "*) CLASS_NEEDS_BR=1 ;;
  esac

  return 0
}
