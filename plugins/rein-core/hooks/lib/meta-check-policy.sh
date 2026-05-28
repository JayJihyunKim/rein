#!/usr/bin/env bash
# meta-check-policy.sh — shell port of rein-policy-loader.py::get_meta_check_policy
# Scope ID: PERF-SHELL-POLICY-LOADER (G3-perf-NFR cycle).
#
# Replaces the cold-start Python invocation (~43ms with PyYAML import) with a
# pure shell + awk implementation (~5ms). Returns the effective meta-check
# policy on stdout: `true` | `false` | `auto`. Always exits 0 (fail-open).
#
# Supported schema (PERF-YAML-SUBSET-CONTRACT):
#   - Single top-level `enabled:` key
#   - Value: unquoted YAML bool (`true`/`false`) or unquoted string (`auto`)
#   - Case-insensitive
#
# Unsupported inputs (all return `auto` from this helper — see
# `plugins/rein-core/docs/policy-meta-check.md` for the full deviation matrix):
#   - quoted strings (e.g. `enabled: "true"`)
#   - YAML bool aliases yes/no/on/off
#   - nested mappings (e.g. `meta:\n  enabled: true`)
#   - anchor/alias (e.g. `enabled: &x true`)
#   - multi-doc YAML — NOTE: shell awk matches the first `enabled:` line and
#     ignores the `---` separator, so multi-doc effectively returns whatever
#     the first `enabled:` line says (which Python parses as fail-open `auto`).
#     This is an intentional deviation documented in PERF-PARITY-FIXTURE.
#
# Fail-open paths (all return `auto`):
#   - file absent
#   - file not readable (permissions)
#   - `enabled:` key absent
#   - value not in {true,false,auto} (case-insensitive)

meta_check_policy_shell() {
  local policy_file=".rein/policy/meta-check.yaml"
  local val=""
  # (i) file absent or not readable -> auto
  [ -r "$policy_file" ] || { printf 'auto'; return 0; }
  # (ii) enabled: key extract via awk
  #   - skip comment-only lines
  #   - match `^[[:space:]]*enabled:` (top-level key)
  #   - strip leading "enabled: " + leading whitespace
  #   - strip trailing whitespace
  #   - strip trailing inline comment
  #   - lowercase the result
  #   - first match wins (exit)
  # Match top-level `enabled:` ONLY (no leading whitespace) — a nested mapping
  # like `meta:\n  enabled: true` would have leading spaces and must NOT match.
  # PERF-FAIL-OPEN-PARITY (ix): nested mapping -> auto.
  val=$(awk '
    /^[[:space:]]*#/ {next}
    /^enabled:/ {
      sub(/^enabled:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]*$/, "")
      print tolower($0)
      exit
    }
  ' "$policy_file" 2>/dev/null)
  # (iii) value normalize: only literal true|false|auto pass through
  case "$val" in
    true|false|auto) printf '%s' "$val"; return 0 ;;
    *) printf 'auto'; return 0 ;;
  esac
}
