#!/usr/bin/env python3
"""Bootstrap Rein repo-local state without mutating plugin settings.

This helper is intended for plugin installs where the plugin is already
enabled but the current git repository has not been initialized for Rein yet.
It creates only repo-local state: ``.rein/``, ``.rein/policy/``, and
``trail/``. It deliberately refuses Claude plugin cache/marketplace paths so a
mis-resolved cwd cannot pollute the plugin installation cache.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


TRAIL_SUBDIRS = (
    "inbox",
    "daily",
    "weekly",
    "decisions",
    "dod",
    "incidents",
    "agent-candidates",
)

POLICY_HOOKS_TEMPLATE = """# .rein/policy/hooks.yaml
#
# Operational profile (Phase 4):
#   profile: lean       # exploratory work — disables plan-coverage, spec-review-gate, dod-routing-check
#   profile: standard   # (default) all gates enabled
#   profile: strict     # release / security-sensitive — reserved for stricter future defaults
#
# Per-hook toggles (override the profile):
#   <hook-name>: false                # disable
#   <hook-name>: { enabled: false }   # equivalent structured form
#
# Resolution: per-hook entry > profile default > built-in default (enabled).
# Empty file = use plugin defaults (everything enabled).
"""

POLICY_RULES_TEMPLATE = """# .rein/policy/rules.yaml
# Add <rule-name>: | followed by replacement rule text to override bundled
# prompt rules for this repo. Empty file = use plugin defaults.
"""

INDEX_TEMPLATE = """# trail/index.md

> Rein 프로젝트 상태 — 매 세션 종료 시 갱신.
"""


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def is_plugin_storage(path: Path) -> bool:
    normalized = str(path.resolve())
    return normalized.endswith("/.claude/plugins") or "/.claude/plugins/" in normalized


def _refuse_sensitive_or_unsafe(project_dir: Path) -> None:
    """Mirror bootstrap-check.sh helper's safety net.

    Reject sensitive paths (filesystem root, $HOME) and plugin cache paths so a
    mis-resolved or copy-pasted --project-dir cannot pollute system locations.
    Plugin storage prefix (~/.claude/plugins/...) remains covered by the existing
    ``is_plugin_storage`` check; this helper extends coverage to (1) "/" and
    (2) ``$HOME`` and (3) ``~/.claude/plugins/cache/...`` explicitly.
    """
    resolved = project_dir.resolve()

    # (1) sensitive path: filesystem root
    if str(resolved) == "/":
        fail(f"refusing to bootstrap filesystem root: {resolved}")

    # (2) sensitive path: $HOME
    home = Path.home().resolve()
    if resolved == home:
        fail(f"refusing to bootstrap home directory: {resolved}")

    # (3) plugin cache path: ~/.claude/plugins/cache/* prefix
    plugin_cache = (home / ".claude" / "plugins" / "cache").resolve()
    try:
        resolved.relative_to(plugin_cache)
        fail(f"refusing to bootstrap inside plugin cache: {resolved}")
    except ValueError:
        pass  # not under plugin cache — OK


def git_root_for(path: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    root = result.stdout.strip()
    return Path(root).resolve() if root else None


def write_text_if_missing(path: Path, content: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def bootstrap(project_dir: Path, scope: str, version: str) -> tuple[Path, bool]:
    project_dir = project_dir.resolve()
    _refuse_sensitive_or_unsafe(project_dir)
    if is_plugin_storage(project_dir):
        fail(f"refusing to bootstrap inside Claude plugin storage: {project_dir}")

    git_root = git_root_for(project_dir)
    non_git = False
    if git_root is None:
        # Task 2.3 (v1.1.1): non-git fallback — use project_dir itself as the
        # bootstrap root. We never invoke `git init` or any mutating git
        # command. trail/ + .rein/ are created in-place so the user can adopt
        # Rein without first turning the directory into a git repo.
        non_git = True
        root = project_dir
    else:
        if git_root != project_dir:
            fail(
                f"project-dir must be the git root: got {project_dir}, root is {git_root}"
            )
        if is_plugin_storage(git_root):
            fail(f"refusing to bootstrap plugin cache repository: {git_root}")
        root = git_root

    rein_dir = root / ".rein"
    policy_dir = rein_dir / "policy"
    trail_dir = root / "trail"

    policy_dir.mkdir(parents=True, exist_ok=True)
    project_json = rein_dir / "project.json"
    if not project_json.exists():
        payload = {
            "mode": "plugin",
            "scope": scope,
            "version": version,
        }
        project_json.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    write_text_if_missing(policy_dir / "hooks.yaml", POLICY_HOOKS_TEMPLATE)
    write_text_if_missing(policy_dir / "rules.yaml", POLICY_RULES_TEMPLATE)

    for subdir in TRAIL_SUBDIRS:
        target = trail_dir / subdir
        target.mkdir(parents=True, exist_ok=True)
        (target / ".gitkeep").touch(exist_ok=True)
    write_text_if_missing(trail_dir / "index.md", INDEX_TEMPLATE)

    return root, non_git


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Bootstrap Rein repo-local state for an already-enabled plugin."
    )
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--scope", default="plugin")
    parser.add_argument("--version", default="1.0.0")
    args = parser.parse_args(argv)

    root, non_git = bootstrap(Path(args.project_dir), args.scope, args.version)
    if non_git:
        print(f"Non-git project — initialized trail/ at {root}.")
    else:
        print(f"Rein repo state bootstrapped at {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
