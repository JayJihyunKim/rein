#!/usr/bin/env python3
"""State path resolver — mode + env aware.

Plugin-First Restructure Phase 3 Task 3.2 (Plan §704-760, Spec §5.5).

Returns the absolute / repo-relative path of a single rein runtime state file
based on:

  * ``.rein/project.json`` ``mode`` field (``plugin`` vs ``scaffold``).
  * ``CLAUDE_PLUGIN_DATA`` env var (set by Anthropic plugin host on install).

Plugin-mode contract is **fail-closed** when ``CLAUDE_PLUGIN_DATA`` is unset:
silent fallback to ``.rein/cache/`` would contradict spec §5.5 plugin-mode
scope IDs and create deterministic-resolution drift across machines.

Usage:
    python3 rein-state-paths.py <state-name>

Where <state-name> is one of:
    governance | jobs | inventory | active-dod-choice-log

Plugin mode roots state files under::

    ${CLAUDE_PLUGIN_DATA}/runtime/...

Scaffold mode (default / no ``.rein/project.json``) roots them under::

    .rein/cache/...

The single ``trail/`` directory does NOT participate in this mapping —
``trail/`` stays at repo root in both modes (Phase 3 Task 3.10 invariant).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# (state-name) -> (scaffold-relative, plugin-relative)
# scaffold-relative is appended to ``.rein/cache/``.
# plugin-relative is appended to ``${CLAUDE_PLUGIN_DATA}/``.
STATE_FILES: dict[str, tuple[str, str]] = {
    "governance": ("governance.json", "runtime/governance.json"),
    "jobs": ("jobs/", "runtime/jobs/"),
    "inventory": ("inventory/", "runtime/inventory/"),
    "active-dod-choice-log": (
        "active-dod-choice.log",
        "runtime/active-dod-choice.log",
    ),
}


def _read_mode() -> str:
    """Read ``mode`` from ``.rein/project.json``; fall back to ``scaffold``."""
    project_json = Path(".rein/project.json")
    if not project_json.exists():
        return "scaffold"
    try:
        data = json.loads(project_json.read_text(encoding="utf-8"))
        return data.get("mode", "scaffold")
    except Exception:
        return "scaffold"


def resolve(state_name: str) -> Path:
    """Resolve a state file path. Raises ``SystemExit`` on unknown state name
    or on plugin-mode without ``CLAUDE_PLUGIN_DATA``.
    """
    if state_name not in STATE_FILES:
        raise SystemExit(
            f"unknown state: {state_name!r} (known: "
            f"{', '.join(sorted(STATE_FILES))})"
        )
    scaffold_rel, plugin_rel = STATE_FILES[state_name]
    mode = _read_mode()
    if mode == "plugin":
        plugin_data = os.environ.get("CLAUDE_PLUGIN_DATA")
        if not plugin_data:
            # Round 6 fix — fail-closed (silent fallback contradicts spec §5.5
            # plugin-mode IDs).
            sys.exit(
                "error: mode=plugin but CLAUDE_PLUGIN_DATA env var unset. "
                "Plugin runtime path resolution requires this var (Anthropic "
                "plugin spec sets it on install). "
                "If you intend repo-local cache, run with mode=scaffold or "
                "set the env var explicitly."
            )
        return Path(plugin_data) / plugin_rel
    return Path(".rein/cache") / scaffold_rel


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write(
            "usage: rein-state-paths.py <governance|jobs|inventory|"
            "active-dod-choice-log>\n"
        )
        return 2
    print(resolve(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
