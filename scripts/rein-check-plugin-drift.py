#!/usr/bin/env python3
"""rein-check-plugin-drift — detect SSOT drift between rein-core plugin and .claude/ tree.

Phase 9 Task 9.2 (plugin-first restructure). The rein-core plugin is the
SSOT for hooks/skills/agents. The repo also keeps a `.claude/` tree that
serves the maintainer-side scaffold export (rein init --mode=scaffold).
The two trees must stay sha256-identical for every shared first-class file:
if a maintainer edits .claude/hooks/<x>.sh without mirroring it to
plugins/rein-core/hooks/<x>.sh (or vice versa), users on plugin mode and
users on scaffold mode will see different code, producing silent SSOT drift.

This checker walks both trees and reports any file whose content hash
differs between the two locations, or that exists in only one of them
when the other is expected to mirror it.

Categories checked:
  - hooks/      plugins/rein-core/hooks/   ↔ .claude/hooks/
  - skills/     plugins/rein-core/skills/  ↔ .claude/skills/
  - agents/     plugins/rein-core/agents/  ↔ .claude/agents/

Exit codes:
  0  no drift detected
  1  drift detected — list printed to stderr
  2  internal error (plugin tree missing, etc.)

Maintainer-only excludes (path-suffix match, not full path):
  - `.claude/hooks/*.example` files (e.g., post-edit-lint.sh.example)
  - `.claude/skills/{stitch-design,stitch-loop,taste-design,design-md,
       enhance-prompt,react-components,remotion,shadcn-ui}/`
       (domain skills shipped by separate plugins, per branch-strategy.md)
  - `.claude/skills/__pycache__/` artifacts
  - Any file whose name starts with `.` (hidden file, e.g., `.gitkeep`)

The exclusions are deliberately narrow. Adding a new exclusion requires
documenting it in branch-strategy.md and writing a test that proves the
file is genuinely maintainer-only or domain-only.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

PREFIX = "rein-check-plugin-drift:"

# Domain-skill subtrees (shipped by separate plugins; not part of rein-core
# SSOT contract — see branch-strategy.md ❌ 제외 table).
DOMAIN_SKILL_DIRS = frozenset({
    "stitch-design",
    "stitch-loop",
    "taste-design",
    "design-md",
    "enhance-prompt",
    "react-components",
    "remotion",
    "shadcn-ui",
})

# Filename suffixes ignored ONLY on the .claude/ (scaffold) side. We must
# not silently ignore stray .example files inside the plugin tree — those
# would actually be drift (plugin-only without an allowlist entry).
SCAFFOLD_IGNORE_SUFFIXES = (".example",)

# Filenames ignored anywhere in the walk.
IGNORE_NAMES = frozenset({
    ".DS_Store",
    ".gitkeep",
    "__pycache__",
})

# Plugin-native artifacts that intentionally have no .claude/ mirror.
# These are produced by Phase 2 (rules-prompt skill + session-start-rules
# hook synthesized from .claude/rules/*.md content) or are plugin metadata
# only meaningful inside plugins/rein-core/ (hooks.json registers the hooks
# in Claude Code's plugin format).
#
# Rationale: rules-prompt/{code-style,security,testing}.md are sha256
# mirrors of .claude/rules/{code-style,security,testing}.md by content but
# live under plugins/rein-core/skills/rules-prompt/ for plugin packaging.
# The actual content drift is checked separately via Phase 2 acceptance
# tests (tests/scripts/test-rules-prompt-bundle-drift.sh); duplicating
# that check here would force every rule edit to also bump the
# rules-prompt mirror in the same commit, which the Phase 2 design
# intentionally separates.
#
# Path-prefix relative to plugins/rein-core/ — exact match in either tree
# allowlist.
PLUGIN_ONLY_PATHS = frozenset({
    Path("hooks/hooks.json"),
    Path("hooks/session-start-rules.sh"),
    Path("skills/rules-prompt/SKILL.md"),
    Path("skills/rules-prompt/code-style.md"),
    Path("skills/rules-prompt/security.md"),
    Path("skills/rules-prompt/testing.md"),
})


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_ignored(rel_path: Path, *, side: str) -> bool:
    """True iff (side, rel_path) falls under an exclusion rule.

    side: "plugin" or "scaffold". Some rules apply to only one side
    (e.g., .example suffix is scaffold-only — a plugin/.example file is
    real drift and must be reported).
    """
    parts = rel_path.parts
    if not parts:
        return True
    # Hidden files / cache dirs (both sides — e.g., .gitkeep, .DS_Store).
    if any(p.startswith(".") for p in parts):
        return True
    if any(p in IGNORE_NAMES for p in parts):
        return True
    # skills/<domain>/... applies to both sides — domain skills are owned
    # by separate plugins.
    if len(parts) >= 1 and parts[0] in DOMAIN_SKILL_DIRS:
        return True
    # Side-specific suffix rules.
    if side == "scaffold":
        if rel_path.name.endswith(SCAFFOLD_IGNORE_SUFFIXES):
            return True
    return False


def _walk_files(root: Path, *, side: str) -> Dict[Path, str]:
    """Return {relative_path: sha256} for all files under root, applying ignores."""
    out: Dict[Path, str] = {}
    if not root.exists():
        return out
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        if _is_ignored(rel, side=side):
            continue
        out[rel] = _sha256(p)
    return out


def _is_plugin_only_allowed(category: str, rel: Path) -> bool:
    """True iff (category/rel) is on the plugin-only allowlist."""
    return Path(category) / rel in PLUGIN_ONLY_PATHS


def _diff_trees(plugin_files: Dict[Path, str],
                scaffold_files: Dict[Path, str],
                category: str) -> List[str]:
    """Return list of human-readable drift lines, empty list if in sync."""
    drift: List[str] = []
    plugin_keys = set(plugin_files)
    scaffold_keys = set(scaffold_files)

    for rel in sorted(plugin_keys & scaffold_keys):
        if plugin_files[rel] != scaffold_files[rel]:
            drift.append(
                f"  HASH-MISMATCH {category}/{rel}\n"
                f"    plugin   sha256={plugin_files[rel]}\n"
                f"    scaffold sha256={scaffold_files[rel]}"
            )
    for rel in sorted(plugin_keys - scaffold_keys):
        if _is_plugin_only_allowed(category, rel):
            continue
        drift.append(f"  PLUGIN-ONLY    {category}/{rel}")
    for rel in sorted(scaffold_keys - plugin_keys):
        drift.append(f"  SCAFFOLD-ONLY  {category}/{rel}")
    return drift


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(prog="rein-check-plugin-drift")
    ap.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repo root (defaults to script's parent dir).",
    )
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress success message; drift list still goes to stderr.",
    )
    args = ap.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    plugin_root = repo_root / "plugins" / "rein-core"
    claude_root = repo_root / ".claude"

    if not plugin_root.exists():
        print(f"{PREFIX} plugin root missing: {plugin_root}", file=sys.stderr)
        return 2

    categories: Iterable[Tuple[str, Path, Path]] = (
        ("hooks",  plugin_root / "hooks",  claude_root / "hooks"),
        ("skills", plugin_root / "skills", claude_root / "skills"),
        ("agents", plugin_root / "agents", claude_root / "agents"),
    )

    all_drift: List[str] = []
    for cat, p_root, s_root in categories:
        p_files = _walk_files(p_root, side="plugin")
        s_files = _walk_files(s_root, side="scaffold")
        drift = _diff_trees(p_files, s_files, cat)
        if drift:
            all_drift.append(f"\n{cat} ({len(drift)} drift entries):")
            all_drift.extend(drift)

    if all_drift:
        print(f"{PREFIX} SSOT drift detected between plugins/rein-core/ and .claude/:",
              file=sys.stderr)
        for line in all_drift:
            print(line, file=sys.stderr)
        print(f"\n{PREFIX} fix: ensure both trees stay sha256-identical for "
              "every shared first-class file. See branch-strategy.md for "
              "rationale and `.claude/rules/design-plan-coverage.md` for "
              "drift policy.", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"{PREFIX} OK — plugins/rein-core/ ↔ .claude/ in sync (hooks + skills + agents)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
