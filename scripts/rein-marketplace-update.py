#!/usr/bin/env python3
"""rein-marketplace-update.py — atomic update of marketplace/marketplace.json.

Adds (or upgrades) one (plugin_name, version) entry pointing at the tarball.
Writes via temp file + os.replace to avoid readers ever seeing a partial JSON
(this matters because CI may be reading the manifest concurrently while a tag
push triggers a publish run).

Usage:
    rein-marketplace-update.py <plugin_name> <version> <tarball_path> \
        [--manifest <path>]

`<tarball_path>` is the path to the produced tarball *relative to the repo
root*. We hash its bytes (sha256) and embed the digest so the manifest entry
is self-describing.

Idempotency: if (plugin_name, version) already exists, the tarball path and
sha256 are refreshed in place — no duplicate version rows. The tarball path
is whitelisted to `marketplace/plugins/<plugin>/<version>/...` to avoid
arbitrary on-disk references being written into the published manifest.

Phase 6 / Task 6.1 — `plugin-first-restructure` plan.
Spec ref: docs/specs/2026-04-27-plugin-first-restructure.md
"""

# stdlib (per code-style.md import order: stdlib first).
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

# Constant marketplace manifest schema version embedded in writes.
MANIFEST_SCHEMA_VERSION = "1.0.0"
MANIFEST_NAME = "rein-marketplace"

# Allow only repo-relative paths under marketplace/plugins/<plugin>/<version>/.
# Keeps absolute paths and `..` traversal out of the manifest. The version
# segment must match VERSION_PATTERN (incl. `+`) — any drift between this
# regex and VERSION_PATTERN below would let a version pass `validateInputs`
# only to fail when the path is rebuilt downstream, so we keep the charsets
# strictly consistent.
PLUGIN_NAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+-]{1,64}$")
TARBALL_PATH_PATTERN = re.compile(
    r"^marketplace/plugins/[A-Za-z0-9._-]+/[A-Za-z0-9._+-]+/[A-Za-z0-9._+-]+\.tar\.gz$"
)


def parseArgs() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("plugin_name")
    parser.add_argument("version")
    parser.add_argument("tarball_path")
    parser.add_argument(
        "--manifest",
        default="marketplace/marketplace.json",
        help="path to marketplace.json (default: marketplace/marketplace.json)",
    )
    return parser.parse_args()


def computeSha256(filePath: Path) -> str:
    """Read tarball in 1 MiB chunks; avoids slurping huge tarballs into RAM."""
    h = hashlib.sha256()
    with filePath.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def loadManifest(manifestPath: Path) -> dict:
    if not manifestPath.exists():
        return {"name": MANIFEST_NAME, "version": MANIFEST_SCHEMA_VERSION, "plugins": []}
    with manifestPath.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict) or "plugins" not in data:
        raise ValueError(f"malformed manifest at {manifestPath}: missing 'plugins'")
    if not isinstance(data["plugins"], list):
        raise ValueError(f"malformed manifest at {manifestPath}: 'plugins' must be a list")
    return data


def upsertEntry(manifest: dict, pluginName: str, version: str, tarballPath: str, sha256Hex: str) -> dict:
    """Insert or refresh the (plugin, version) entry in-place. Returns manifest."""
    plugins = manifest["plugins"]
    pluginEntry = next((p for p in plugins if p.get("name") == pluginName), None)
    if pluginEntry is None:
        pluginEntry = {"name": pluginName, "versions": []}
        plugins.append(pluginEntry)
    # Preserve prior history: if `versions` exists but is malformed, refuse to
    # publish rather than silently resetting (which would erase past releases
    # and let a single corrupted manifest entry destroy provenance).
    if "versions" not in pluginEntry:
        pluginEntry["versions"] = []
    elif not isinstance(pluginEntry["versions"], list):
        raise ValueError(
            f"manifest entry for plugin {pluginName!r} has malformed 'versions' "
            f"({type(pluginEntry['versions']).__name__}); refusing to overwrite"
        )
    versionRow = {
        "version": version,
        "source": {
            "type": "self-hosted",
            "path": tarballPath,
            "sha256": sha256Hex,
        },
    }
    existingIndex = next(
        (i for i, v in enumerate(pluginEntry["versions"]) if v.get("version") == version),
        None,
    )
    if existingIndex is None:
        pluginEntry["versions"].append(versionRow)
    else:
        pluginEntry["versions"][existingIndex] = versionRow
    return manifest


def writeAtomic(manifestPath: Path, manifest: dict) -> None:
    """Write manifest via NamedTemporaryFile + os.replace.

    `os.replace` is atomic on POSIX and on Windows >= Vista (rename-replace).
    Putting the temp file in the same directory ensures the rename is on the
    same filesystem (otherwise os.replace can degrade to copy + unlink).
    """
    manifestPath.parent.mkdir(parents=True, exist_ok=True)
    fd, tmpName = tempfile.mkstemp(
        prefix=".marketplace.json.tmp.",
        dir=str(manifestPath.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmpName, manifestPath)
    except Exception:
        # Best-effort cleanup; do not mask the original exception.
        try:
            os.unlink(tmpName)
        except OSError:
            pass
        raise


def validateInputs(pluginName: str, version: str, tarballPath: str) -> None:
    if not PLUGIN_NAME_PATTERN.fullmatch(pluginName):
        raise ValueError(f"plugin name not allowed: {pluginName!r}")
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"version not allowed: {version!r}")
    if not TARBALL_PATH_PATTERN.fullmatch(tarballPath):
        raise ValueError(
            f"tarball path must match marketplace/plugins/<name>/<version>/<file>.tar.gz: {tarballPath!r}"
        )


def main() -> int:
    args = parseArgs()
    # Wrap the whole pipeline in a controlled handler: every expected error
    # (validation, malformed prior manifest, missing tarball) becomes a
    # single-line `error: ...` on stderr with rc=2. Without this, a stray
    # ValueError from upsertEntry / loadManifest would surface as a Python
    # traceback to the publish.sh caller — ugly, hard to grep in CI logs,
    # and easy to mistake for an internal crash.
    try:
        validateInputs(args.plugin_name, args.version, args.tarball_path)
        tarballFs = Path(args.tarball_path)
        if not tarballFs.is_file():
            print(f"error: tarball not found: {tarballFs}", file=sys.stderr)
            return 2
        manifestPath = Path(args.manifest)
        sha256Hex = computeSha256(tarballFs)
        manifest = loadManifest(manifestPath)
        upsertEntry(manifest, args.plugin_name, args.version, args.tarball_path, sha256Hex)
        writeAtomic(manifestPath, manifest)
        return 0
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"error: I/O failure during manifest update: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
