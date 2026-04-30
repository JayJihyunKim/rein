#!/usr/bin/env python3
"""Atomic write-last for ``.rein/project.json`` — Phase 4 Task 4.10.

This is the **single source of truth** that ``rein migrate`` finished. The
file is intentionally written last (after every other mutation in
``scripts/rein-migrate.sh``), and atomically (temp + fsync + ``os.replace``),
so that:

* Mid-migration SIGKILL leaves the workspace either in the **incomplete**
  state (lock file present, ``project.json`` absent) — which Task 4.6 detects
  and asks the user to ``rein migrate --resume`` — or in the **completed**
  state (lock released, ``project.json`` present).
* Partial / torn writes never appear: the temp file may exist briefly, the
  final file appears in one atomic ``os.replace`` step, and no third "half
  written" file is observable to readers.

CLI contract:

    rein-write-project-json.py \\
        --mode plugin \\
        --scope project \\
        --version 1.0.0

Output: writes ``.rein/project.json`` with the canonical schema::

    {
      "mode": "plugin" | "scaffold",
      "scope": "user" | "project" | "local" | "managed",
      "version": "<semver>"
    }
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

VALID_MODES = ("plugin", "scaffold")
VALID_SCOPES = ("user", "project", "local", "managed")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")

PROJECT_JSON = Path(".rein/project.json")


def _atomic_write_json(target: Path, payload: dict) -> None:
    """Write JSON atomically. Temp file goes in the same directory as target.

    Uses a per-process unique temp name (PID + nonce + ``O_EXCL``) so two
    concurrent migrate runs (which the lock should prevent, but defense-
    in-depth) cannot clobber each other's temp file before ``os.replace``.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    nonce = f"{os.getpid()}-{os.urandom(8).hex()}"
    tmp = target.with_suffix(target.suffix + f".tmp.{nonce}")
    serialized = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    fd = os.open(
        str(tmp),
        os.O_CREAT | os.O_EXCL | os.O_WRONLY,
        0o644,
    )
    try:
        try:
            os.write(fd, serialized.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, target)
    except Exception:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise
    # fsync the parent dir so the rename is durable on POSIX. No-op on
    # Windows MINGW which doesn't expose dir fsync, but os.replace on those
    # platforms is already crash-safe via the filesystem journal.
    try:
        dir_fd = os.open(str(target.parent), os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except (OSError, AttributeError):
        # Some FS / platforms (Windows) don't allow O_RDONLY on dirs.
        pass


def write_project_json(mode: str, scope: str, version: str) -> Path:
    if mode not in VALID_MODES:
        raise SystemExit(
            f"invalid mode {mode!r}; valid: {', '.join(VALID_MODES)}"
        )
    if scope not in VALID_SCOPES:
        raise SystemExit(
            f"invalid scope {scope!r}; valid: {', '.join(VALID_SCOPES)}"
        )
    if not SEMVER_RE.match(version):
        raise SystemExit(
            f"invalid version {version!r}; expected semver (e.g. 1.0.0)"
        )

    payload = {
        "mode": mode,
        "scope": scope,
        "version": version,
    }
    _atomic_write_json(PROJECT_JSON, payload)
    return PROJECT_JSON.resolve()


def _cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Atomic write-last for .rein/project.json"
    )
    parser.add_argument("--mode", required=True, choices=VALID_MODES)
    parser.add_argument("--scope", required=True, choices=VALID_SCOPES)
    parser.add_argument("--version", required=True)
    args = parser.parse_args(argv)
    target = write_project_json(args.mode, args.scope, args.version)
    print(str(target))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
