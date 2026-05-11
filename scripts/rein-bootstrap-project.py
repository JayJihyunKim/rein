#!/usr/bin/env python3
"""Compatibility entry point for the plugin bootstrap helper.

The implementation lives in ``plugins/rein-core/scripts`` because bootstrap is
primarily a plugin-install path. Keep this root wrapper so repo-local hook and
governance scans can resolve the documented ``scripts/`` helper path.
"""

from __future__ import annotations

import runpy
import sys
from pathlib import Path


def main() -> int:
    target = (
        Path(__file__).resolve().parents[1]
        / "plugins"
        / "rein-core"
        / "scripts"
        / "rein-bootstrap-project.py"
    )
    if not target.is_file():
        print(f"error: bootstrap helper not found: {target}", file=sys.stderr)
        return 2
    runpy.run_path(str(target), run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main())
