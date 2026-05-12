#!/usr/bin/env bash
# Plugin helper — rule-inject body loader.
#
# Resolves the body for a named rule, applying per-rule override from
# `.rein/policy/rules.yaml` first (via rein-policy-loader.py), falling back
# to the bundled default at `${CLAUDE_PLUGIN_ROOT}/rules/<name>.md`.
#
# Fail-open: missing yaml, missing PyYAML, malformed yaml, or any
# unexpected shape returns the bundled default. Only when BOTH override
# probe is empty AND the default file is missing does the function return 1.
#
# Usage (source):
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"
#   BODY=$(rule_inject_body answer-only-mode)
#
# Usage (direct):
#   bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh" answer-only-mode
#
# Stdout: rule body (no trailing newline normalization — pass-through).
# Exit:   0 on success; 1 if no body could be resolved.

set -uo pipefail

rule_inject_body() {
  local rule_name="${1:-}"
  local plugin_root="${2:-${CLAUDE_PLUGIN_ROOT:-}}"
  if [ -z "$rule_name" ] || [ -z "$plugin_root" ]; then
    return 1
  fi
  local rules_dir="${plugin_root}/rules"
  local loader="${plugin_root}/scripts/rein-policy-loader.py"
  local override=""
  if [ -f "$loader" ]; then
    # Loader contract: exit 0 on every path; stdout is the override body
    # or empty. Stderr surfaces user-visible diagnostics (malformed yaml).
    # `|| true` is defence-in-depth.
    #
    # Sentinel idiom: `$(...)` strips trailing newlines from command output.
    # Override bodies (and bundled defaults) end with `\n` and the no-trunc
    # contract requires byte-exact pass-through. Append a sentinel `x` byte
    # inside the subshell, then strip it after capture so any trailing
    # newlines from the loader output are preserved verbatim.
    override=$(python3 "$loader" --rule-override "$rule_name"; printf x) || true
    override="${override%x}"
  fi
  local body=""
  if [ -n "$override" ]; then
    body="$override"
  else
    local rule_file="${rules_dir}/${rule_name}.md"
    if [ ! -f "$rule_file" ]; then
      return 1
    fi
    # Sentinel idiom (see override capture above) — preserve trailing
    # newlines so `body_size` matches `wc -c` of the source file exactly.
    body=$(cat "$rule_file"; printf x)
    body="${body%x}"
  fi
  # Size diagnostic — Task 2.7 / overflow handoff policy.
  # No truncation here: Claude Code's 10,000-char cap is handled by the
  # platform via overflow-file handoff. rein passes the full body through
  # and lets the platform decide. The log line aids debugging when a rule
  # body exceeds the cap (operator can spot it in plugin runtime stderr).
  # See: plugins/rein-core/docs/overflow-handoff.md
  #
  # Size is reported in BYTES (UTF-8). Bash `${#body}` returns a character
  # count under non-C locales, which under-counts multi-byte UTF-8 (Korean
  # rule bodies hit this); pipe through `wc -c` for a byte-accurate value.
  local body_size
  body_size=$(printf '%s' "$body" | wc -c | tr -d ' ')
  echo "rein-rule-inject: rule=$rule_name size=$body_size bytes" >&2
  printf '%s' "$body"
}

# If executed directly (not sourced), call the function with $1.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  rule_inject_body "${1:-}"
fi
