#!/usr/bin/env python3
"""Process manifest-v2 tracked files during ``rein migrate``.

Plugin-First Restructure Phase 4 Tasks 4.2 + 4.3 + 4.7 (Plan §943-1010, §1088-1100).

Behavior:

* Read ``.claude/.rein-manifest.json`` (created by ``rein init`` /
  ``rein update`` to track every scaffold-installed file with its sha256).
* For each ``tracked[]`` entry:
    * If the file is **absent**, skip silently (user removed it manually).
    * If sha256 matches the manifest, ``unlink`` (Task 4.2).
    * If sha256 differs, **move** the file to
      ``.rein/migration-backup/<ISO-ts>/<repo-relative-path>.bak``
      (Task 4.3) — preserves user customizations as a recoverable snapshot.
* CLAUDE.md untouched-guard (Task 4.7):
    * Snapshot sha256 of ``CLAUDE.md`` and ``.claude/CLAUDE.md`` (when present)
      **before** any mutation.
    * If those files are NOT in ``tracked[]`` (= user-authored), they must
      stay byte-identical after this script returns. We assert this by
      comparing snapshots and aborting (exit 2) if they were touched.
    * Manifest-tracked CLAUDE.md is allowed to follow the normal sha256
      branch (remove on match, backup on mismatch) per spec §5.6.
* On success, delete the manifest file itself — its purpose was to mark the
  scaffold layer; once removed, the repo is no longer in scaffold mode.
* Backup root is computed once per migrate run (single ISO timestamp),
  resolved before the manifest loop so all mismatched files share the same
  directory.

Symlink hardening:

* ``shutil.move`` follows symlinks for files. We refuse to back up a
  ``tracked`` entry whose path resolves outside the current working tree
  (``Path.resolve()`` outside ``cwd``) — symlink traversal attempts abort the
  migration with exit 3 instead of corrupting paths under
  ``.rein/migration-backup/``.

Output: a single JSON line on stdout summarizing what happened, e.g.::

    {"removed": ["...", ...], "backed_up": ["..."], "backup_root": ".rein/migration-backup/2026-04-28T15-30-00Z"}
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path

MANIFEST_PATH = Path(".claude/.rein-manifest.json")
BACKUP_BASE = Path(".rein/migration-backup")
USER_CLAUDE_FILES = (Path("CLAUDE.md"), Path(".claude/CLAUDE.md"))


def sha256_of(p: Path) -> str:
    """Return hex sha256 of a file's bytes. Caller must verify ``p.is_file()``."""
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _safe_resolve_within_cwd(p: Path) -> Path:
    """Resolve ``p`` and assert it stays under the current working directory.

    Raises ``SystemExit(3)`` on traversal escape — protects backup_root from
    symlink attacks where a manifest-tracked path points outside the repo.
    """
    cwd = Path.cwd().resolve()
    resolved = (cwd / p).resolve()
    try:
        resolved.relative_to(cwd)
    except ValueError as exc:
        raise SystemExit(
            f"refusing to process tracked path outside cwd: {p} -> {resolved}"
        ) from exc
    return resolved


def _snapshot_user_claude() -> dict[Path, str | None]:
    """Snapshot sha256 of user CLAUDE.md files for Task 4.7 untouched guard."""
    snap: dict[Path, str | None] = {}
    for p in USER_CLAUDE_FILES:
        if p.is_file():
            snap[p] = sha256_of(p)
        else:
            snap[p] = None
    return snap


def _verify_user_claude_untouched(
    snapshot: dict[Path, str | None],
    tracked_paths: set[Path],
) -> None:
    """Abort if a non-tracked user CLAUDE.md was modified.

    Manifest-tracked CLAUDE.md is exempt — we own those.
    """
    for p, before in snapshot.items():
        if p in tracked_paths:
            continue
        after = sha256_of(p) if p.is_file() else None
        if before != after:
            raise SystemExit(
                f"refusing to continue: user-authored {p} was modified during "
                "migration. Lock retained for retry."
            )


def main() -> int:
    if not MANIFEST_PATH.exists():
        sys.stderr.write(
            "no manifest — already migrated or scaffold-only repo; skipping.\n"
        )
        # Still emit empty summary for consumers piping our stdout.
        print(json.dumps({"removed": [], "backed_up": [], "backup_root": None}))
        return 0

    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"manifest is not valid JSON: {exc}\n")
        return 4

    tracked = manifest.get("tracked", [])
    if not isinstance(tracked, list):
        sys.stderr.write("manifest.tracked must be a list\n")
        return 4

    tracked_paths: set[Path] = {Path(e["path"]) for e in tracked if "path" in e}

    # Task 4.7 — snapshot user CLAUDE.md before mutation.
    claude_snapshot = _snapshot_user_claude()

    # Reject pre-existing symlink at .rein/migration-backup or BACKUP_BASE
    # parents — codex review surfaced an escape path where an attacker pre-
    # plants ``.rein/migration-backup -> /tmp/somewhere`` so backed-up files
    # leave the repo. We refuse to use any path component that is already a
    # symlink, and resolve BACKUP_BASE to confirm it would land inside cwd.
    cwd_resolved = Path.cwd().resolve()
    parent = BACKUP_BASE
    while True:
        if parent.is_symlink():
            raise SystemExit(
                f"refusing to use {parent} — symlink in backup path "
                "(possible directory traversal)"
            )
        if parent == parent.parent:  # filesystem root
            break
        parent = parent.parent
    if BACKUP_BASE.exists():
        try:
            BACKUP_BASE.resolve().relative_to(cwd_resolved)
        except ValueError as exc:
            raise SystemExit(
                f"refusing to use {BACKUP_BASE} — resolves outside cwd"
            ) from exc

    backup_root = BACKUP_BASE / time.strftime(
        "%Y-%m-%dT%H-%M-%SZ", time.gmtime()
    )

    removed: list[str] = []
    backed_up: list[str] = []

    for entry in tracked:
        rel = entry.get("path")
        want_sha = entry.get("sha256")
        if not rel or not want_sha:
            continue
        rel_path = Path(rel)
        if not rel_path.is_file():
            continue
        # Symlink/escape protection.
        _safe_resolve_within_cwd(rel_path)

        actual_sha = sha256_of(rel_path)
        if actual_sha == want_sha:
            rel_path.unlink()
            removed.append(str(rel_path))
            continue

        # sha256 mismatch — backup with `.bak` suffix.
        backup_root.mkdir(parents=True, exist_ok=True)
        dest = backup_root / rel_path
        dest = dest.with_name(dest.name + ".bak")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(rel_path), str(dest))
        backed_up.append(str(rel_path))

    # Task 4.7 final guard — assert user CLAUDE.md untouched.
    _verify_user_claude_untouched(claude_snapshot, tracked_paths)

    # Manifest done — delete to mark scaffold layer cleared.
    MANIFEST_PATH.unlink()

    print(
        json.dumps(
            {
                "removed": removed,
                "backed_up": backed_up,
                "backup_root": str(backup_root) if backed_up else None,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
