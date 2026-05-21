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

# classify_bash_command <command-string>
#
# Pure (no I/O, no subprocess) other than the command-string argument. Safe to
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
  case "$cmd" in
    "git commit" | "git commit "*) CLASS_NEEDS_TC=1 ;;
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
