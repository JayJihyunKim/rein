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
# Set <hook-name>: false to disable a plugin-shipped hook for this repo.
# Empty file = use plugin defaults.
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


def bootstrap(project_dir: Path, scope: str, version: str) -> Path:
    project_dir = project_dir.resolve()
    if is_plugin_storage(project_dir):
        fail(f"refusing to bootstrap inside Claude plugin storage: {project_dir}")

    git_root = git_root_for(project_dir)
    if git_root is None:
        fail(f"not a git repository: {project_dir}")
    if git_root != project_dir:
        fail(f"project-dir must be the git root: got {project_dir}, root is {git_root}")

    if is_plugin_storage(git_root):
        fail(f"refusing to bootstrap plugin cache repository: {git_root}")

    rein_dir = git_root / ".rein"
    policy_dir = rein_dir / "policy"
    trail_dir = git_root / "trail"

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

    return git_root


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Bootstrap Rein repo-local state for an already-enabled plugin."
    )
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--scope", default="plugin")
    parser.add_argument("--version", default="2.0.0")
    args = parser.parse_args(argv)

    root = bootstrap(Path(args.project_dir), args.scope, args.version)
    print(f"Rein repo state bootstrapped at {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
