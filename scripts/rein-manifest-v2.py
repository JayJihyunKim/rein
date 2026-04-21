#!/usr/bin/env python3
"""Manifest v2 helper — Plan C Task 2.2 (RU-*).

Supports the manifest schema-version transition v1 → v2 introduced by
Spec C (rein update hygiene). A v2 manifest tracks per-file sha256 plus
optional `added_in` / `last_updated_in` version stamps and carries a
`schema_version: "2"` marker so `rein update` can switch between the
legacy 2-way merge path (v1) and the new 3-way path (v2 + base
snapshot).

All writes go through a temp-file + os.replace rename so concurrent
readers never observe a partial JSON payload (RU-update-manifest-atomic-only).

Subcommands
-----------
  schema <manifest>
      Print the schema_version field ("1", "2", or empty if unreadable).

  read <manifest> <rel>
      Print the sha256 recorded for <rel>, or empty if absent.

  init <manifest> [rein_version]
      Create an empty v2 manifest (schema_version=2, files={}).
      No-op if the file already exists and parses as v2.

  add <manifest> <rel> <sha256> [rein_version]
      Upsert a file entry, stamping last_updated_in with rein_version if
      supplied. Creates the manifest lazily if missing.

  remove <manifest> <rel>
      Delete a file entry. Silent no-op if absent.

  migrate <manifest> [rein_version]
      Rewrite a v1 manifest as v2 in place. Preserves `rein_version`,
      `installed_at`, `updated_at`, and every per-file sha256 + added_in
      metadata. Idempotent — already-v2 manifests are left untouched.

  list <manifest>
      Print one relpath per line, sorted. Used by cmd_merge to enumerate
      tracked files for prune/remove operations.

Design notes
------------
- We intentionally reimplement the read/write logic here rather than
  reusing cmd_merge's embedded Python. The bash side shells out to this
  helper whenever it needs to touch manifest JSON atomically, and
  callers are expected to treat non-zero exit as an error (stderr
  carries a human-readable message).
- External dependencies: stdlib only (json, os, sys, pathlib, hashlib
  for the optional sha256-of helper).
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys
from typing import Any


def sha256_of(path: str) -> str:
    """Portable sha256 — mirrors scripts/rein.sh manifest_sha256 output."""
    p = pathlib.Path(path)
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _load(manifest: str) -> dict[str, Any]:
    if not os.path.exists(manifest):
        return {}
    try:
        with open(manifest, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"rein-manifest-v2: cannot read {manifest}: {exc}\n")
        sys.exit(2)
    if not isinstance(data, dict):
        sys.stderr.write(f"rein-manifest-v2: {manifest} is not a JSON object\n")
        sys.exit(2)
    return data


def _atomic_write(manifest: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(manifest) or ".", exist_ok=True)
    tmp = f"{manifest}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, manifest)


def _reject_unknown_schema(data: dict[str, Any], manifest: str, op: str) -> None:
    """Fail closed when encountering a schema we cannot safely coerce.

    Callers that need to handle v1 must call 'migrate' explicitly before any
    mutating op. Anything outside {"", "1", "2"} is treated as future or
    corrupt and must not be silently overwritten.
    """
    schema = data.get("schema_version", "")
    if schema in ("", "1", "2"):
        return
    sys.stderr.write(
        f"rein-manifest-v2: refusing to {op} {manifest}: "
        f"unsupported schema_version {schema!r} (expected '1' or '2')\n"
    )
    sys.exit(2)


def _ensure_v2(manifest: str, rein_version: str | None = None) -> dict[str, Any]:
    data = _load(manifest)
    if not data:
        data = {
            "schema_version": "2",
            "files": {},
        }
        if rein_version:
            data["rein_version"] = rein_version
        return data
    _reject_unknown_schema(data, manifest, "mutate")
    # v1 callers must migrate explicitly; add/remove should not silently
    # rewrite a v1 payload's schema marker because the same manifest may
    # still be read by older rein.sh paths mid-transition.
    if data.get("schema_version") != "2":
        sys.stderr.write(
            f"rein-manifest-v2: refusing to mutate {manifest}: "
            f"schema_version is {data.get('schema_version')!r}, run 'migrate' first\n"
        )
        sys.exit(2)
    data.setdefault("files", {})
    return data


# --- commands --------------------------------------------------------------


def cmd_schema(manifest: str) -> int:
    data = _load(manifest)
    print(data.get("schema_version", ""))
    return 0


def cmd_read(manifest: str, rel: str) -> int:
    data = _load(manifest)
    entry = (data.get("files") or {}).get(rel) or {}
    print(entry.get("sha256", ""))
    return 0


def cmd_init(manifest: str, rein_version: str | None = None) -> int:
    data = _load(manifest)
    if data:
        # File exists. Don't silently clobber tracked state.
        if data.get("schema_version") == "2":
            return 0  # already v2 — no-op
        sys.stderr.write(
            f"rein-manifest-v2: refusing to init {manifest}: "
            f"schema_version is {data.get('schema_version')!r}, "
            f"run 'migrate' (for v1) or remove the file manually\n"
        )
        return 2
    fresh: dict[str, Any] = {"schema_version": "2", "files": {}}
    if rein_version:
        fresh["rein_version"] = rein_version
    _atomic_write(manifest, fresh)
    return 0


def cmd_add(manifest: str, rel: str, sha: str, rein_version: str | None = None) -> int:
    data = _ensure_v2(manifest, rein_version)
    files = data["files"]
    entry = files.get(rel, {})
    entry["sha256"] = sha
    if rein_version:
        entry.setdefault("added_in", rein_version)
        entry["last_updated_in"] = rein_version
    files[rel] = entry
    _atomic_write(manifest, data)
    return 0


def cmd_remove(manifest: str, rel: str) -> int:
    data = _load(manifest)
    if not data:
        return 0
    _reject_unknown_schema(data, manifest, "mutate")
    # Same policy as cmd_add: legacy v1 must migrate explicitly before any
    # mutating op, otherwise the manifest would be read back under two
    # schemas mid-transition.
    if data.get("schema_version") != "2":
        sys.stderr.write(
            f"rein-manifest-v2: refusing to remove from {manifest}: "
            f"schema_version is {data.get('schema_version')!r}, run 'migrate' first\n"
        )
        return 2
    files = data.get("files") or {}
    if rel in files:
        del files[rel]
        data["files"] = files
        _atomic_write(manifest, data)
    return 0


def cmd_migrate(manifest: str, rein_version: str | None = None) -> int:
    data = _load(manifest)
    if not data:
        sys.stderr.write(f"rein-manifest-v2: nothing to migrate (no {manifest})\n")
        return 2
    if data.get("schema_version") == "2":
        return 0  # idempotent
    if data.get("schema_version") != "1":
        sys.stderr.write(
            f"rein-manifest-v2: unsupported schema_version "
            f"{data.get('schema_version')!r} in {manifest}\n"
        )
        return 2
    # v1 → v2: preserve all metadata; just bump the schema marker.
    data["schema_version"] = "2"
    if rein_version:
        data.setdefault("rein_version", rein_version)
    _atomic_write(manifest, data)
    return 0


def cmd_list(manifest: str) -> int:
    data = _load(manifest)
    files = data.get("files") or {}
    for rel in sorted(files.keys()):
        print(rel)
    return 0


def _usage() -> None:
    sys.stderr.write(__doc__ or "")
    sys.stderr.write("\n")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        _usage()
        return 2
    cmd = argv[1]
    args = argv[2:]
    try:
        if cmd == "schema":
            return cmd_schema(args[0])
        if cmd == "read":
            return cmd_read(args[0], args[1])
        if cmd == "init":
            return cmd_init(args[0], args[1] if len(args) > 1 else None)
        if cmd == "add":
            return cmd_add(
                args[0],
                args[1],
                args[2],
                args[3] if len(args) > 3 else None,
            )
        if cmd == "remove":
            return cmd_remove(args[0], args[1])
        if cmd == "migrate":
            return cmd_migrate(args[0], args[1] if len(args) > 1 else None)
        if cmd == "list":
            return cmd_list(args[0])
    except IndexError:
        sys.stderr.write(f"rein-manifest-v2: missing argument for '{cmd}'\n")
        return 2
    sys.stderr.write(f"rein-manifest-v2: unknown subcommand '{cmd}'\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
