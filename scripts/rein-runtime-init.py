#!/usr/bin/env python3
"""Initialize ``${CLAUDE_PLUGIN_DATA}/runtime/`` for plugin mode.

Plugin-First Restructure Phase 4 Task 4.9 (Plan §1124-1143).

Creates the runtime directory tree that Phase 3's ``rein-state-paths.py``
expects in plugin mode:

    ${CLAUDE_PLUGIN_DATA}/runtime/governance.json    -> {"stage": 1}
    ${CLAUDE_PLUGIN_DATA}/runtime/jobs/              -> empty dir
    ${CLAUDE_PLUGIN_DATA}/runtime/inventory/         -> empty dir

Idempotent — pre-existing files / directories are left as-is. Only the
``governance.json`` file is created when absent (default ``stage`` value is
``1`` per ``.claude/rules/design-plan-coverage.md`` §3.3).

The script must be invoked with ``CLAUDE_PLUGIN_DATA`` set; missing env var
exits non-zero (Round 6 fail-closed contract).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

DEFAULT_GOVERNANCE = {"stage": 1}


def _atomic_write_json(target: Path, payload: dict) -> None:
    """temp + fsync + os.replace — same contract as rein-write-project-json.py.

    Uses a per-process unique temp name (PID + nonce) so concurrent runtime-
    init invocations never overwrite each other's temp file.
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


def init_runtime(plugin_data_root: Path) -> dict[str, str]:
    """Create runtime/ tree under ``plugin_data_root``.

    Returns a dict summary of created paths.
    """
    runtime = plugin_data_root / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)

    governance_path = runtime / "governance.json"
    if not governance_path.exists():
        _atomic_write_json(governance_path, DEFAULT_GOVERNANCE)
        gov_status = "created"
    else:
        gov_status = "preserved"

    jobs_dir = runtime / "jobs"
    jobs_dir.mkdir(parents=True, exist_ok=True)
    inventory_dir = runtime / "inventory"
    inventory_dir.mkdir(parents=True, exist_ok=True)

    return {
        "runtime_root": str(runtime),
        "governance": gov_status,
        "jobs": "ready",
        "inventory": "ready",
    }


def main() -> int:
    plugin_data = os.environ.get("CLAUDE_PLUGIN_DATA")
    if not plugin_data:
        sys.stderr.write(
            "CLAUDE_PLUGIN_DATA is unset — runtime init requires plugin "
            "data root. Refusing silent fallback (Phase 3 Round 6 contract).\n"
        )
        return 2
    summary = init_runtime(Path(plugin_data))
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
