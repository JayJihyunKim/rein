#!/usr/bin/env python3
"""Install / merge a plugin entry into a Claude Code ``settings.json`` scope.

Plugin-First Restructure Phase 4 Task 4.8 (Plan §1102-1122).

This module is **shared** between Phase 4 (``rein migrate`` step 3) and
Phase 5 (``rein init`` / ``rein update`` Tasks 5.1, 5.3, 5.4). It must work
both as a CLI (argv) and as an import (call ``install_plugin_to_settings``
directly).

Scopes (per Anthropic plugin docs):

    project  — ``.claude/settings.json`` (default for ``rein migrate``)
    user     — ``~/.claude/settings.json``
    local    — ``.claude/settings.local.json``
    managed  — ``.claude/managed-settings.json``

Behavior:

* Atomic merge — load existing JSON, ensure the ``plugins`` key is a dict,
  set ``plugins[<plugin_name>] = <version>``, write to a temp file, fsync,
  ``os.replace()`` (POSIX + Windows MINGW both treat ``rename(temp, target)``
  as atomic when on the same filesystem).
* Schema preservation — never strips unknown keys from the existing settings
  JSON; only mutates ``plugins[<name>]``.
* Missing settings file — create with ``{"plugins": {<name>: <version>}}``.
* Existing ``plugins`` value that is not a dict — refuse to corrupt the file
  and exit non-zero with a diagnostic.

Caller contract (CLI):

    rein-install-plugin-to-settings.py \\
        --scope project \\
        --plugin rein=^2.0.0 \\
        [--plugin foo=1.0.0 ...]

Caller contract (module API):

    from rein_install_plugin_to_settings import install_plugin_to_settings

    install_plugin_to_settings(
        scope="project",
        plugin_name="rein",
        version="^2.0.0",
    )
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Iterable

VALID_SCOPES = ("user", "project", "local", "managed")


def settings_path_for_scope(scope: str) -> Path:
    """Return the ``settings.json`` path for the requested scope.

    Resolves ``~`` for user scope. Caller's cwd matters for the project / local
    / managed scopes — they are repo-relative.
    """
    if scope == "user":
        return Path.home() / ".claude" / "settings.json"
    if scope == "project":
        return Path(".claude/settings.json")
    if scope == "local":
        return Path(".claude/settings.local.json")
    if scope == "managed":
        return Path(".claude/managed-settings.json")
    raise ValueError(
        f"unknown scope: {scope!r} (valid: {', '.join(VALID_SCOPES)})"
    )


def _atomic_write_json(target: Path, payload: dict) -> None:
    """Write JSON atomically: per-process temp file in the same dir, fsync,
    ``os.replace``.

    ``os.replace`` is atomic on POSIX and Windows when temp and target are on
    the same filesystem. Phase 5 reuses this helper across user / project /
    local / managed scopes, so two concurrent callers may race on the same
    settings.json. We avoid a fixed ``.tmp`` suffix collision by suffixing
    the temp name with the current PID + a 64-bit random nonce; ``O_CREAT |
    O_EXCL`` makes acquisition fail-fast if a same-PID nonce ever repeats.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    nonce = f"{os.getpid()}-{os.urandom(8).hex()}"
    tmp = target.with_suffix(target.suffix + f".tmp.{nonce}")
    serialized = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    # O_EXCL guarantees we never overwrite a peer's temp file.
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
        # Best-effort cleanup if the rename failed.
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def install_plugin_to_settings(
    scope: str,
    plugin_name: str,
    version: str,
) -> Path:
    """Merge ``{plugin_name: version}`` into ``settings.json[plugins]``.

    Returns the absolute path of the settings file that was mutated.

    Raises ``SystemExit`` on schema corruption (existing ``plugins`` is not
    a dict) — caller should treat this as a hard failure.
    """
    if scope not in VALID_SCOPES:
        raise SystemExit(
            f"invalid scope {scope!r} — choose from {', '.join(VALID_SCOPES)}"
        )
    target = settings_path_for_scope(scope)

    if target.exists():
        try:
            existing = json.loads(target.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise SystemExit(
                f"existing settings file at {target} is not valid JSON: {exc}"
            ) from exc
        if not isinstance(existing, dict):
            raise SystemExit(
                f"existing settings file at {target} is not a JSON object"
            )
    else:
        existing = {}

    plugins = existing.get("plugins", {})
    if not isinstance(plugins, dict):
        raise SystemExit(
            f"settings.json at {target} has plugins value of type "
            f"{type(plugins).__name__}; refusing to overwrite"
        )

    plugins[plugin_name] = version
    existing["plugins"] = plugins

    _atomic_write_json(target, existing)
    return target.resolve()


def _parse_plugin_spec(spec: str) -> tuple[str, str]:
    """Parse ``name=version`` from a single ``--plugin`` argv."""
    if "=" not in spec:
        raise SystemExit(
            f"--plugin must be 'name=version' (got: {spec!r})"
        )
    name, _, version = spec.partition("=")
    name = name.strip()
    version = version.strip()
    if not name or not version:
        raise SystemExit(
            f"--plugin name and version cannot be empty (got: {spec!r})"
        )
    return name, version


def _cli(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Install a plugin entry into a Claude Code settings.json"
    )
    parser.add_argument(
        "--scope",
        required=True,
        choices=VALID_SCOPES,
        help="Settings scope to mutate.",
    )
    parser.add_argument(
        "--plugin",
        required=True,
        action="append",
        metavar="NAME=VERSION",
        help="Plugin spec; may be repeated.",
    )
    args = parser.parse_args(argv)

    target = None
    for spec in args.plugin:
        name, version = _parse_plugin_spec(spec)
        target = install_plugin_to_settings(args.scope, name, version)

    if target is not None:
        print(str(target))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
