#!/bin/bash
# hooks/lib/security-axis-policy-resolve.sh
#
# Single-source resolver for the security_review axis's commit policy
# location. Mirrors the two-tier resolution the active_task axis uses
# (hooks/lib/active-task-gate.sh's rein_active_task_delegate() "정책 위치
# 2단 해소" section) — a bundled default that a project with no override
# can rely on, and a project override that takes precedence when present.
#
# Three call sites share this function so they can never disagree about
# which directory backs this axis: hooks/pre-bash-commit-review-gate.sh
# (pre-check before the switched-check), hooks/lib/security-review-gate.sh
# (the delegate that injects REIN_POLICY_DIR), and scripts/rein-mark-
# security-reviewed.sh (the evidence-issuance CLI wrapper, which must see
# the exact same directory the commit gate will check against).
#
# Contract:
#   rein_security_axis_policy_resolve PROJECT_DIR PLUGIN_ROOT
#   sets two globals:
#     rein_security_axis_policy_dir  — resolved directory, or "" when none
#     rein_security_axis_policy_kind — one of:
#       PROJECT          — PROJECT_DIR/.rein/policy/security-axis has a
#                           commit-security.yaml file. Project override
#                           wins over the bundled default.
#       PROJECT_DAMAGED  — that path exists but is not a usable policy
#                           folder: the file is missing inside it, or the
#                           path is not a directory at all (a regular file
#                           or a dangling symbolic link), or any parent
#                           component (.rein, .rein/policy) exists but is
#                           not a searchable directory, so the path cannot
#                           be judged at all. This NEVER falls
#                           through to the bundle — a damaged project
#                           override must not be silently masked by the
#                           distribution default, or the misconfiguration
#                           goes unnoticed (and a strict override would be
#                           quietly weakened to the default profile).
#       BUNDLE           — no project folder at all, and
#                           PLUGIN_ROOT/policies/security-axis/commit-
#                           security.yaml exists — the distribution
#                           default a project with no override relies on.
#       NONE             — neither resolves (damaged install, or
#                           PLUGIN_ROOT could not be determined). This is
#                           not a declared opt-out — the only documented
#                           opt-out path for this axis is `.rein/policy/
#                           authority.yaml` taking security_review out of
#                           the switched set, which callers check
#                           separately and earlier/later in their own
#                           judgment trees.
#
# Safe under `set -u` (both parameters default to empty). Uses only
# test/[ ] — no external commands, no subshells.

if [ -n "${__REIN_SECURITY_AXIS_POLICY_RESOLVE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_SECURITY_AXIS_POLICY_RESOLVE_LOADED=1

rein_security_axis_policy_resolve() {
  local _sapr_project_dir="${1:-}"
  local _sapr_plugin_root="${2:-}"

  rein_security_axis_policy_dir=""
  rein_security_axis_policy_kind="NONE"

  local _sapr_project_axis_dir=""
  if [ -n "$_sapr_project_dir" ]; then
    _sapr_project_axis_dir="$_sapr_project_dir/.rein/policy/security-axis"
  fi

  # Walk every path component from .rein down to the axis folder. A
  # component that exists in ANY form (directory, regular file, symbolic
  # link — dangling included) must be a searchable directory; anything
  # else is a damaged override and NEVER falls through to the bundle. Only
  # a component that is genuinely absent ends the walk as "no override"
  # (nothing below it can exist), which is the one state that resolves to
  # the distribution default. This is a whitelist ("must be a searchable
  # directory"), not a list of known-bad shapes.
  if [ -n "$_sapr_project_dir" ]; then
    local _sapr_comp _sapr_present=1
    for _sapr_comp in "$_sapr_project_dir/.rein" "$_sapr_project_dir/.rein/policy" "$_sapr_project_axis_dir"; do
      if [ -e "$_sapr_comp" ] || [ -L "$_sapr_comp" ]; then
        if ! { [ -d "$_sapr_comp" ] && [ -x "$_sapr_comp" ]; }; then
          rein_security_axis_policy_dir="$_sapr_project_axis_dir"
          rein_security_axis_policy_kind="PROJECT_DAMAGED"
          return 0
        fi
      else
        _sapr_present=0
        break
      fi
    done
    if [ "$_sapr_present" = 1 ]; then
      # The axis folder itself is a searchable directory — it must carry
      # the policy file to count as a usable override.
      if [ -f "$_sapr_project_axis_dir/commit-security.yaml" ]; then
        rein_security_axis_policy_dir="$_sapr_project_axis_dir"
        rein_security_axis_policy_kind="PROJECT"
      else
        rein_security_axis_policy_dir="$_sapr_project_axis_dir"
        rein_security_axis_policy_kind="PROJECT_DAMAGED"
      fi
      return 0
    fi
  fi

  # No project folder at all — try the bundled default. Never reached when
  # the project folder exists but is damaged (the branch above already
  # returned).
  if [ -n "$_sapr_plugin_root" ]; then
    local _sapr_bundle_axis_dir="$_sapr_plugin_root/policies/security-axis"
    if [ -f "$_sapr_bundle_axis_dir/commit-security.yaml" ]; then
      rein_security_axis_policy_dir="$_sapr_bundle_axis_dir"
      rein_security_axis_policy_kind="BUNDLE"
      return 0
    fi
  fi

  rein_security_axis_policy_dir=""
  rein_security_axis_policy_kind="NONE"
  return 0
}
