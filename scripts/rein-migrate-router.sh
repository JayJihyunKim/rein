#!/usr/bin/env bash
# scripts/rein-migrate-router.sh — Phase 4 Task 4.4.
#
# Relocates router data files (.claude/router/*.yaml) to .rein/policy/router/.
# Uses ``git mv`` first (preserves blob history with ``git log --follow``),
# falls back to plain ``mv`` for non-git contexts (test sandboxes, fresh
# clones, --force re-runs).
#
# Spec IDs:
#   * router-feedback-log-relocates-to-rein-policy-router-on-migration
#   * router-overrides-and-registry-relocate-to-rein-policy-router-on-migration

set -euo pipefail

OLD_DIR=".claude/router"
NEW_DIR=".rein/policy/router"

if [ ! -d "$OLD_DIR" ]; then
  echo "no .claude/router/ — skipping router relocation" >&2
  exit 0
fi

mkdir -p "$NEW_DIR"

# Detect if cwd is inside a git work tree; controls git mv vs plain mv.
in_git_repo=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  in_git_repo=1
fi

# Whitelist exact filenames so we never sweep an attacker-planted file.
for f in feedback-log.yaml overrides.yaml registry.yaml; do
  src="$OLD_DIR/$f"
  dst="$NEW_DIR/$f"
  if [ ! -f "$src" ]; then
    continue
  fi
  if [ "$in_git_repo" = "1" ]; then
    # Try git mv (preserves history). Fall back to mv if the file isn't
    # tracked (e.g. user added it but never committed).
    if ! git mv "$src" "$dst" 2>/dev/null; then
      mv "$src" "$dst"
    fi
  else
    mv "$src" "$dst"
  fi
done

# Sweep .gitkeep + remove now-empty directory.
if [ -f "$OLD_DIR/.gitkeep" ]; then
  if [ "$in_git_repo" = "1" ]; then
    git rm -f "$OLD_DIR/.gitkeep" >/dev/null 2>&1 || rm -f "$OLD_DIR/.gitkeep"
  else
    rm -f "$OLD_DIR/.gitkeep"
  fi
fi

# rmdir only if dir is empty — never -rf.
rmdir "$OLD_DIR" 2>/dev/null || true
