#!/usr/bin/env bash
# Plugin helper — single shell-quoting rule shared by every rendered
# rein-bootstrap-project.py command: hooks/lib/git-required-guidance.sh,
# lib/bootstrap-check.sh's fresh/partial templates, and the
# PreToolUse(Bash) bootstrap gate's exact-match allow-list.
#
# Usage (source from a hook or lib):
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/shell-quote.sh"
#   rein_shell_quote <str>
#
# Rule: single-quote the value ('<str>') unless it contains a literal single
# quote, in which case fall back to `printf %q`. No other transform.
#
# Known limit: a value containing a single quote round-trips through `%q`
# (backslash-escaped), which the PreToolUse(Bash) gate's regex allow-list
# cannot parse — such a command only passes through the gate's exact-match
# allow-list, never the regex.
#
# Safe under `set -u` (positional argument read with a `${1:-}` default).
# Callers that cannot source this file (install regression) fall back to
# `printf %q` directly — never hard-fail on a missing lib.

rein_shell_quote() {
  local s="${1:-}"
  case "$s" in
    *"'"*)
      printf '%q' "$s"
      ;;
    *)
      printf "'%s'" "$s"
      ;;
  esac
}
