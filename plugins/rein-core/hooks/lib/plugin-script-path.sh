#!/bin/bash
# plugin-script-path.sh — plugin-aware helper script resolver (RES-1).
#
# Purpose
#   Hooks must work in two environments:
#     (a) plugin install — `${CLAUDE_PLUGIN_ROOT}/scripts/<name>` is the
#         shipped helper bundle.
#     (b) maintainer dogfood (rein-dev repo) — `${PROJECT_DIR}/scripts/<name>`
#         is the source tree fallback.
#
#   Hardcoding `${PROJECT_DIR}/scripts/...` breaks fresh plugin installs
#   because no `scripts/` dir exists in user repos. This resolver picks
#   the right one with a deterministic priority.
#
# API
#   resolve_helper_script <script-name>
#     - exit 0 + stdout = absolute path
#     - exit 1 + stderr "not found" + the locations searched
#     - exit 1 + stderr "empty argument" if <script-name> is empty
#
# Priority
#   1. ${CLAUDE_PLUGIN_ROOT}/scripts/<script-name>  (plugin install)
#   2. ${PROJECT_DIR}/scripts/<script-name>          (repo fallback)
#   3. fail (exit 1)
#
# Caller pattern (R1 mitigation — uniform across all 5 hooks)
#   . "${SCRIPT_DIR}/lib/plugin-script-path.sh"
#   out=$(resolve_helper_script foo) || { echo "BLOCKED: foo helper not found" >&2; exit 1; }
#
# Tracing (REIN_RESOLVER_TRACE)
#   Set REIN_RESOLVER_TRACE=1 to append one line per call to
#   ${TMPDIR:-/tmp}/rein-resolver-trace.log. Format (TAB-separated):
#     <ISO 8601 timestamp>\t<caller-hook>\t<script-name>\t<resolved-path-or-NOT_FOUND>
#   caller-hook is derived from ${BASH_SOURCE[1]##*/}. Trace block uses
#   O_APPEND atomic write (`>>`) to survive multi-hook race. Trace off
#   (env unset/0) is zero overhead — single arithmetic check, no path work.

# Guard against double-source.
if [ -n "${_REIN_PLUGIN_SCRIPT_PATH_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_REIN_PLUGIN_SCRIPT_PATH_SH_LOADED=1

resolve_helper_script() {
  local name="$1"
  local caller_hook resolved="" trace_log

  if [ -z "$name" ]; then
    echo "resolve_helper_script: empty argument" >&2
    return 1
  fi

  # Priority 1: plugin install
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/${name}" ]; then
    resolved="${CLAUDE_PLUGIN_ROOT}/scripts/${name}"
  # Priority 2: repo fallback (maintainer dogfood)
  elif [ -n "${PROJECT_DIR:-}" ] && [ -f "${PROJECT_DIR}/scripts/${name}" ]; then
    resolved="${PROJECT_DIR}/scripts/${name}"
  fi

  # Trace block — only enter when explicitly enabled. Trace off path is a
  # single conditional and has no observable cost vs. the non-traced version.
  if [ "${REIN_RESOLVER_TRACE:-0}" = "1" ]; then
    trace_log="${TMPDIR:-/tmp}/rein-resolver-trace.log"
    # ${BASH_SOURCE[1]} = the file that sourced+called us (the hook).
    # Fall back to "unknown" if BASH_SOURCE is unavailable (non-bash shell,
    # direct exec, etc.).
    if [ "${#BASH_SOURCE[@]}" -ge 2 ]; then
      caller_hook="${BASH_SOURCE[1]##*/}"
    else
      caller_hook="unknown"
    fi
    [ -z "$caller_hook" ] && caller_hook="unknown"
    # `>>` opens with O_APPEND on POSIX — concurrent writes from sibling
    # hook processes are atomic at the line level for short writes.
    printf '%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S)" \
      "$caller_hook" \
      "$name" \
      "${resolved:-NOT_FOUND}" \
      >> "$trace_log" 2>/dev/null || true
  fi

  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  echo "resolve_helper_script: '${name}' not found in:" >&2
  echo "  - \${CLAUDE_PLUGIN_ROOT}/scripts/  (CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-<unset>})" >&2
  echo "  - \${PROJECT_DIR}/scripts/         (PROJECT_DIR=${PROJECT_DIR:-<unset>})" >&2
  return 1
}
