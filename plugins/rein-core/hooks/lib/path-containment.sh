#!/bin/bash
# plugins/rein-core/hooks/lib/path-containment.sh
# Shared path-containment validator (GE-1).
#
# Extracted from the session-start `.active-dod` cleanup inline 4-check so both
# the cleanup hook (session-start-load-trail.sh) and the DoD selector
# (select-active-dod.sh Tier 1) use ONE copy — a single security check that
# cannot drift between callers (the lesson SR-1 reinforced).
#
# Design source: docs/specs/2026-04-26-wrapper-context-lifecycle-hardening-design.md
#   OQ-9 (3-layer path defense) + Non-functional Requirements (selector hardening
#   was the registered follow-up; this is GE-1).
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/path-containment.sh"
#   if ! reason=$(validate_repo_relative_path "$PROJECT_DIR" "$path"); then
#     # $reason holds a human description; handle the violation
#   fi

if [ -n "${__REIN_PATH_CONTAINMENT_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_PATH_CONTAINMENT_LOADED=1

# validate_repo_relative_path <project_dir> <path>
#   Return 0 (no output) iff <path> is safe to consume relative to <project_dir>:
#     (1) non-empty
#     (2) only [a-zA-Z0-9_./-] characters (rejects shell metachars, spaces)
#     (3) no `..` path segment
#     (4) realpath(join(project_dir, path)) stays inside realpath(project_dir)
#   On violation: echo a stable human reason to stdout + return 1.
#   Reason substrings (callers grep these — keep stable):
#     "empty path" | "metachars" | ".. segment" | "outside PROJECT_DIR"
#
#   <path> may be repo-relative or absolute: os.path.join() absorbs an absolute
#   target, so an absolute path outside the project is caught by the commonpath
#   check (4), not (2). Missing python3 → fail-closed (treated as a violation),
#   matching the prior inline behavior.
validate_repo_relative_path() {
  local project_dir="$1"
  local path="$2"

  if [ -z "$path" ]; then
    echo "empty path"
    return 1
  fi
  if ! printf '%s' "$path" | grep -qE '^[a-zA-Z0-9_./-]+$'; then
    echo "path contains disallowed metachars"
    return 1
  fi
  if printf '%s' "$path" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "path contains .. segment"
    return 1
  fi
  if ! python3 -c '
import os,sys
project=os.path.realpath(sys.argv[1])
target=os.path.realpath(os.path.join(project, sys.argv[2]))
sys.exit(0 if os.path.commonpath([project, target]) == project else 1)
' "$project_dir" "$path" 2>/dev/null; then
    echo "path resolves outside PROJECT_DIR"
    return 1
  fi
  return 0
}
