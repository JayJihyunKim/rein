#!/usr/bin/env python3
"""Migration transaction lock — atomic create/delete + race-safe.

Plugin-First Restructure Phase 4 Task 4.1 (Plan §891-941, Spec §3.3).

The lock file ``.rein/.migration-in-progress`` is the **outer boundary** of the
``rein migrate`` transaction. Acquire is the first mutation of every migration
run; release is the last. While the lock exists, ``rein migrate`` (Task 4.6)
treats the workspace as ``incomplete`` and refuses to proceed.

Invariants:

* Acquire is atomic via ``os.O_CREAT | os.O_EXCL`` — race-safe across two
  concurrent ``rein migrate`` invocations. Second invocation fails fast with
  ``exit 1`` and a stderr hint pointing at ``rein migrate --resume``.
* Release is idempotent — ``unlink`` only when the file exists, no error if
  already cleared by a previous resume.
* Lock content (``started=<ISO>\\npid=<pid>\\nhead=<git rev>\\n``) is fsynced
  before close so a SIGKILL between acquire and the next step still leaves a
  recoverable marker on disk.
* ``git rev-parse HEAD`` may fail in detached / fresh repos — we fall back to
  the literal string ``unknown`` rather than aborting acquire.

Usage::

    python3 rein-migrate-lock.py acquire
    python3 rein-migrate-lock.py release

Exit codes:

* 0 — success (or already-released for ``release``)
* 1 — lock already exists (acquire) / unknown subcommand
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

LOCK_PATH = Path(".rein/.migration-in-progress")


def _git_head() -> str:
    """Return current ``HEAD`` SHA or ``"unknown"`` if outside a git repo."""
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def acquire() -> int:
    """Create the lock atomically. Exit 1 if already exists."""
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(
            str(LOCK_PATH),
            os.O_CREAT | os.O_EXCL | os.O_WRONLY,
            0o644,
        )
    except FileExistsError:
        sys.stderr.write(
            f"error: lock file exists at {LOCK_PATH}. "
            "Run 'rein migrate --resume' to recover incomplete state.\n"
        )
        return 1
    try:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        pid = os.getpid()
        head = _git_head()
        content = f"started={ts}\npid={pid}\nhead={head}\n"
        os.write(fd, content.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    return 0


def release() -> int:
    """Delete the lock if present. Idempotent."""
    try:
        LOCK_PATH.unlink()
    except FileNotFoundError:
        # Already released — caller may have resumed and re-released.
        pass
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write(
            f"usage: {argv[0]} <acquire|release>\n"
        )
        return 1
    cmd = argv[1]
    if cmd == "acquire":
        return acquire()
    if cmd == "release":
        return release()
    sys.stderr.write(f"unknown command: {cmd!r}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
