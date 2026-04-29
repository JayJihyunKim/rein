#!/usr/bin/env python3
"""rein-build-scaffold — combine plugin first-class + scaffoldOverlay + scaffoldExtras + scaffoldHelperScripts into a single scaffold output.

Source-of-truth combinator for spec §2.3's 21-target COPY layout. Produces a directory
tree under --out that mirrors what `rein init` would lay down on a user repo.

Sources (in order):
  1. Plugin first-class hooks/skills/agents → <out>/.claude/{hooks,skills,agents}/
  2. Plugin first-class scripts             → <out>/scripts/  (NOT .claude/scripts/)
  3. scaffoldOverlay paths from plugin.json → <out>/<path>     (rein-dev `.claude/` SSOT)
  4. scaffoldExtras paths from plugin.json  → <out>/<path>     (rein-dev root SSOT)
  5. scaffoldHelperScripts                  → <out>/<path>     (rein-dev root scripts/)

For every file copy, source ↔ destination sha256 must match (drift-detection).

Exit codes:
  0  success
  1  file IO error / json parse error / unknown error
  2  sha256 mismatch (drift detected)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

PREFIX = "rein-build-scaffold:"

# Maintainer-only rules — must NEVER be exported into the plugin scaffold even
# if a future plugin.json scaffoldOverlay accidentally lists them. These docs
# describe rein-dev maintainer workflow (branch strategy, README rewrite cycle,
# release versioning rules) and are not relevant to user projects. See
# .claude/rules/branch-strategy.md "❌ 제외" table for the rationale.
MAINTAINER_ONLY_RULES = frozenset({
    "branch-strategy.md",
    "readme-style.md",
    "versioning.md",
})


def _eprint(msg: str) -> None:
    print(f"{PREFIX} {msg}", file=sys.stderr)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    src_hash = _sha256(src)
    dst_hash = _sha256(dst)
    if src_hash != dst_hash:
        raise RuntimeError(
            f"sha256 mismatch after copy: src={src} ({src_hash}) "
            f"dst={dst} ({dst_hash})"
        )


def _copy_recursive(src: Path, dst: Path) -> int:
    """Recursively copy src → dst with sha256 verification.

    Returns number of files copied. Empty source dirs result in dst dir created
    but 0 files. Missing src returns -1 (caller decides whether to warn/skip).
    """
    if not src.exists():
        return -1
    if src.is_file():
        _copy_file(src, dst)
        return 1
    # Directory case
    dst.mkdir(parents=True, exist_ok=True)
    count = 0
    for entry in sorted(src.rglob("*")):
        rel = entry.relative_to(src)
        target = dst / rel
        if entry.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif entry.is_file():
            _copy_file(entry, target)
            count += 1
        # symlinks / other special files: skip silently
    return count


def _copy_plugin_first_class(source: Path, out: Path) -> None:
    """Step 1+2: copy plugin first-class hooks/skills/agents/scripts.

    - hooks/skills/agents → <out>/.claude/{name}/
    - scripts → <out>/scripts/  (root, NOT .claude/scripts/)
    Always create the destination dir (even if source missing/empty), so 21-target
    contract tests see the destination directory.
    """
    # hooks, skills, agents → .claude/<name>/
    for name in ("hooks", "skills", "agents"):
        src = source / name
        dst = out / ".claude" / name
        dst.mkdir(parents=True, exist_ok=True)
        if src.exists() and src.is_dir():
            n = _copy_recursive(src, dst)
            if n > 0:
                print(f"plugin first-class: copied {n} file(s) {src} → {dst}")
        # missing source dir: silently skip — Task 1.3-1.6 will populate later

    # scripts → root scripts/ (NOT .claude/scripts/)
    src_scripts = source / "scripts"
    dst_scripts = out / "scripts"
    dst_scripts.mkdir(parents=True, exist_ok=True)
    if src_scripts.exists() and src_scripts.is_dir():
        n = _copy_recursive(src_scripts, dst_scripts)
        if n > 0:
            print(
                f"plugin first-class: copied {n} script(s) {src_scripts} → {dst_scripts}"
            )


def _copy_listed_paths(
    rein_home: Path, out: Path, paths: list, label: str
) -> None:
    """Step 3/4/5: copy each path entry from rein_home → out.

    Trailing-slash convention: paths ending with '/' are treated as directories
    (recursive). Paths not ending with '/' may still be directories (probe at
    runtime). Missing source paths emit stderr WARNING and continue (graceful).
    """
    for path_entry in paths:
        if not isinstance(path_entry, str) or not path_entry:
            _eprint(f"WARNING: {label} entry is not a non-empty string: {path_entry!r}")
            continue
        rel = path_entry.rstrip("/")
        # Defense-in-depth: even if a future plugin.json mistakenly lists a
        # maintainer-only rule under scaffoldOverlay/Extras, refuse to export
        # it. The basename (last path component) is matched against the
        # maintainer-only set so any path placement is caught.
        if Path(rel).name in MAINTAINER_ONLY_RULES:
            _eprint(
                f"WARNING: maintainer-only rule excluded: {path_entry} "
                f"(rules in MAINTAINER_ONLY_RULES are never shipped to user projects)"
            )
            continue
        src = rein_home / rel
        dst = out / rel
        if not src.exists():
            _eprint(f"WARNING: {label} path missing: {path_entry}")
            continue
        if src.is_dir():
            dst.mkdir(parents=True, exist_ok=True)
            n = _copy_recursive(src, dst)
            print(f"{label}: copied dir {n} file(s) {src} → {dst}")
        elif src.is_file():
            _copy_file(src, dst)
            print(f"{label}: copied file {src} → {dst}")
        else:
            _eprint(
                f"WARNING: {label} path is neither file nor dir, skipping: {path_entry}"
            )


def _merge_settings_hooks(out: Path, source: Path) -> None:
    """Step 7: if <out>/.claude/settings.json exists AND source/hooks/hooks.json
    has non-empty events, merge events into settings.json's hooks section.

    For Task 1.2 hooks.json events is empty → no-op (safe early return).

    Schema translation (per Codex Round 1, Finding 1):
      Plugin hooks.json entry shape:
        {"event": "<name>", "matcher": "<pat>", "command": "<cmd>"}
      settings.json `hooks.<event>` array entry shape:
        {"matcher": "<pat>", "hooks": [{"type": "command", "command": "<cmd>"}]}

      - Multiple plugin entries with same (event, matcher) → consolidate into
        a single bucket, append commands to its `hooks` list.
      - Different matchers under same event → multiple bucket entries.
      - Missing matcher (e.g., SessionStart) → omit the matcher key (matches
        existing settings.json convention for SessionStart entries).
    """
    settings_path = out / ".claude" / "settings.json"
    hooks_json_path = source / "hooks" / "hooks.json"
    if not settings_path.exists() or not hooks_json_path.exists():
        return
    try:
        with hooks_json_path.open("r", encoding="utf-8") as f:
            hooks_data = json.load(f)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"plugin hooks.json invalid JSON: {hooks_json_path}: {e}")
    events = hooks_data.get("events") or []
    if not events:
        return  # no-op for Task 1.2
    try:
        with settings_path.open("r", encoding="utf-8") as f:
            settings = json.load(f)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"<out> settings.json invalid JSON: {settings_path}: {e}")
    hooks_section = settings.setdefault("hooks", {})
    merged_count = 0
    for event in events:
        if not isinstance(event, dict):
            _eprint(f"WARNING: hooks.json event entry not a dict, skipping: {event!r}")
            continue
        ev_name = event.get("event")
        cmd = event.get("command")
        if not ev_name or not cmd:
            _eprint(
                f"WARNING: hooks.json event missing event/command, skipping: {event!r}"
            )
            continue
        matcher = event.get("matcher")  # may be absent (SessionStart) or string
        bucket_list = hooks_section.setdefault(ev_name, [])
        # Find existing bucket with same matcher (None == no matcher key)
        target_bucket = None
        for b in bucket_list:
            if not isinstance(b, dict):
                continue
            existing_matcher = b.get("matcher")  # may be absent
            if existing_matcher == matcher:
                target_bucket = b
                break
        if target_bucket is None:
            target_bucket = {}
            if matcher is not None:
                target_bucket["matcher"] = matcher
            target_bucket["hooks"] = []
            bucket_list.append(target_bucket)
        # Ensure target_bucket has a 'hooks' list (defensive — pre-existing
        # buckets from settings.json template already include this key)
        target_bucket.setdefault("hooks", [])
        target_bucket["hooks"].append({"type": "command", "command": cmd})
        merged_count += 1
    with settings_path.open("w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"merged {merged_count} hook event(s) into {settings_path}")


def _load_plugin_json(plugin_dir: Path) -> dict:
    pj = plugin_dir / ".claude-plugin" / "plugin.json"
    if not pj.exists():
        raise FileNotFoundError(f"plugin.json not found: {pj}")
    try:
        with pj.open("r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"plugin.json invalid JSON: {pj}: {e}")


def _load_scaffold_config(plugin_dir: Path) -> dict:
    """Load rein-internal scaffold metadata.

    Located at plugin_dir/scaffold-config.json (NOT inside .claude-plugin/) so
    Claude Code's plugin schema validator does not see rein-internal keys.
    """
    sc = plugin_dir / "scaffold-config.json"
    if not sc.exists():
        return {}
    try:
        with sc.open("r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"scaffold-config.json invalid JSON: {sc}: {e}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="rein-build-scaffold",
        description=(
            "Combine plugin first-class + scaffoldOverlay + scaffoldExtras + "
            "scaffoldHelperScripts into a single scaffold output."
        ),
    )
    parser.add_argument(
        "--out", required=True, help="output directory (created if absent)"
    )
    parser.add_argument(
        "--source",
        default=None,
        help=(
            "plugin source dir (default: <REIN_HOME>/plugins/rein-core). "
            "<REIN_HOME> is derived from this script's location."
        ),
    )
    parser.add_argument(
        "--include-domain",
        action="store_true",
        help="reserved for Phase 7 — currently prints a warning and continues",
    )
    args = parser.parse_args(argv)

    # REIN_HOME = parent of scripts/ (i.e., the rein-dev repo root)
    rein_home = Path(__file__).resolve().parent.parent

    source = Path(args.source).resolve() if args.source else rein_home / "plugins" / "rein-core"
    out = Path(args.out).resolve()

    if not source.exists():
        _eprint(f"plugin source dir does not exist: {source}")
        return 1

    if args.include_domain:
        _eprint("WARNING: --include-domain: domain plugins not yet bundled (Phase 7)")

    try:
        plugin_meta = _load_plugin_json(source)
        scaffold_meta = _load_scaffold_config(source)
    except (FileNotFoundError, RuntimeError) as e:
        _eprint(str(e))
        return 1

    out.mkdir(parents=True, exist_ok=True)

    try:
        # 1+2. plugin first-class
        _copy_plugin_first_class(source, out)
        # 3. scaffoldOverlay
        overlay = scaffold_meta.get("scaffoldOverlay") or []
        _copy_listed_paths(rein_home, out, overlay, "scaffoldOverlay")
        # 4. scaffoldExtras
        extras = scaffold_meta.get("scaffoldExtras") or []
        _copy_listed_paths(rein_home, out, extras, "scaffoldExtras")
        # 5. scaffoldHelperScripts
        helpers = scaffold_meta.get("scaffoldHelperScripts") or []
        _copy_listed_paths(rein_home, out, helpers, "scaffoldHelperScripts")
        # 7. settings template merge (no-op when hooks.json events empty)
        _merge_settings_hooks(out, source)
    except RuntimeError as e:
        # Sha256 mismatch path raises RuntimeError with "sha256 mismatch" prefix
        msg = str(e)
        _eprint(msg)
        if "sha256 mismatch" in msg:
            return 2
        return 1
    except (OSError, IOError) as e:
        _eprint(f"file IO error: {e}")
        return 1

    print(f"scaffold built: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
