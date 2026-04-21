#!/bin/bash
# .claude/hooks/lib/path-policy.sh
# Shared path-classification library for rein hooks.
#
# Scope IDs:
#   - GI-path-policy-lib (single source of truth — no inline regex in hooks)
#   - GI-path-policy-input-contract (relative path input only)
#   - GI-path-policy-matches-legacy-dated (docs/YYYY-MM-DD/*-plan.md / -design.md)
#
# Usage:
#   source "$(dirname "$0")/lib/path-policy.sh"
#   rel="${abs_path#$PROJECT_DIR/}"   # caller normalizes absolute → relative
#   if is_plan_path "$rel"; then
#     ...
#   fi
#
# Input contract (Spec A §2):
#   * Input MUST be a *repo-relative* path (no leading "/").
#   * Absolute paths are undefined behavior — caller must strip the project
#     prefix before calling. We deliberately do not re-normalize inside the
#     function; doing so in two places is what caused the drift that led to
#     this library (Round 1 codex review, 2 inline matchers).
#
# Functions:
#   is_plan_path  "<rel>"  — 0 iff path is a plan (canonical or legacy dated)
#   is_spec_path  "<rel>"  — 0 iff path is a design spec (canonical or legacy)
#
# Missing this library → fail-closed per consumer hook (see
# post-edit-plan-coverage.sh / post-write-spec-review-gate.sh for the
# "library missing" handler).

# Guard against double-sourcing (harmless but avoids re-defining functions).
if [ -n "${__REIN_PATH_POLICY_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_PATH_POLICY_LOADED=1

# is_plan_path: return 0 iff the given repo-relative path is a plan.
#
# Matches:
#   docs/plans/*.md           (canonical, including nested docs/<sub>/plans/*.md)
#   plans/*.md                (top-level plans directory)
#   docs/YYYY-MM-DD/*-plan.md (legacy dated plan — GI-path-policy-matches-legacy-dated)
#
# Does NOT match: specs, reports, brainstorms, arbitrary markdown.
is_plan_path() {
  local rel="$1"
  [[ "$rel" =~ ^(docs(/[^/]+)*/plans/.+\.md|plans/.+\.md|docs/[0-9]{4}-[0-9]{2}-[0-9]{2}/[^/]+-plan\.md)$ ]]
}

# is_spec_path: return 0 iff the given repo-relative path is a design spec.
#
# Matches (symmetric to is_plan_path):
#   docs/specs/*.md           (canonical, including nested docs/<sub>/specs/*.md)
#   specs/*.md                (top-level specs directory)
#   docs/YYYY-MM-DD/*-design.md (legacy dated design — GI-path-policy-matches-legacy-dated)
is_spec_path() {
  local rel="$1"
  [[ "$rel" =~ ^(docs(/[^/]+)*/specs/.+\.md|specs/.+\.md|docs/[0-9]{4}-[0-9]{2}-[0-9]{2}/[^/]+-design\.md)$ ]]
}
