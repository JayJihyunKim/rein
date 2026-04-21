#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rein-govcheck — governance plumbing self-test.

Scope IDs:
  - GI-govcheck-existence
  - GI-govcheck-language-aware

Purpose:
  Collect every ``scripts/rein-*.{sh,py}`` reference from the governance
  surface (``AGENTS.md``, ``.claude/CLAUDE.md``, ``.claude/orchestrator.md``,
  and every ``.claude/hooks/*.sh``), then verify that each referenced file
  (a) exists on disk and (b) parses in its own language:

  * ``.py`` → ``ast.parse(open(path).read())`` must succeed.
  * ``.sh`` → ``bash -n <path>`` must succeed (return code 0).
  * anything else → existence check only (no exec-bit requirement, since
    Windows Git Bash cannot be trusted to preserve the exec bit).

Exit codes:
  0 — all references valid.
  2 — one or more references missing or broken. Details on stderr.

Usage:
  python3 scripts/rein-govcheck.py
"""
from __future__ import annotations

import ast
import glob
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable

# We deliberately use a restricted character set for the referenced names so
# that matches such as ``scripts/rein-foo.py`` are reliable without pulling
# in surrounding punctuation (backticks, quotes, paren characters).  The path
# policy library (`is_plan_path`) is not consulted here because this scanner
# targets *script references*, not markdown paths.
SCRIPT_REF_RE = re.compile(r"scripts/rein-[a-zA-Z0-9._-]+\.(?:sh|py)")

# Entry points into the governance surface.
ROOT_DOCS = (
    "AGENTS.md",
    ".claude/CLAUDE.md",
    ".claude/orchestrator.md",
)

# Hook files contain executable shell code; parse for references similarly.
HOOK_GLOB = ".claude/hooks/*.sh"

BASH_SYNTAX_TIMEOUT_S = 10


def collect_script_refs(root: Path) -> set[str]:
    """Return every ``scripts/rein-*`` reference found under *root*.

    References are returned as *repo-relative* strings (no leading slash).
    """
    refs: set[str] = set()
    sources: list[Path] = []
    for rel in ROOT_DOCS:
        p = root / rel
        if p.is_file():
            sources.append(p)
    # Hook files — walk the glob once.
    for hook_path in sorted(glob.glob(str(root / HOOK_GLOB))):
        hp = Path(hook_path)
        if hp.is_file():
            sources.append(hp)

    for src in sources:
        try:
            text = src.read_text(encoding="utf-8", errors="replace")
        except OSError:
            # Unreadable governance file is itself a govcheck failure signal,
            # but we do not promote read errors to ref-failures — they'll
            # surface via the validate() pass on the file itself if any other
            # ref points at it.  Here we simply skip and keep scanning.
            continue
        for m in SCRIPT_REF_RE.finditer(text):
            refs.add(m.group(0))
    return refs


def _validate_py(ref_path: Path) -> tuple[bool, str]:
    """Parse a Python file; return (ok, detail)."""
    try:
        source = ref_path.read_text(encoding="utf-8")
    except OSError as exc:
        return False, f"unreadable: {exc}"
    try:
        ast.parse(source, filename=str(ref_path))
    except SyntaxError as exc:
        line = exc.lineno if exc.lineno is not None else 0
        return False, f"SyntaxError at line {line}: {exc.msg}"
    return True, ""


def _validate_sh(ref_path: Path) -> tuple[bool, str]:
    """Invoke ``bash -n`` on a shell file; return (ok, detail)."""
    try:
        proc = subprocess.run(
            ["bash", "-n", str(ref_path)],
            capture_output=True,
            text=True,
            timeout=BASH_SYNTAX_TIMEOUT_S,
        )
    except FileNotFoundError:
        return False, "bash not available on PATH"
    except subprocess.TimeoutExpired:
        return False, f"bash -n timed out after {BASH_SYNTAX_TIMEOUT_S}s"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        first = detail[0] if detail else f"bash -n exit {proc.returncode}"
        return False, first
    return True, ""


def validate_ref(ref: str, root: Path) -> tuple[bool, str]:
    """Validate a single script reference; return (ok, detail)."""
    ref_path = root / ref
    if not ref_path.is_file():
        return False, "file not found"
    suffix = ref_path.suffix.lower()
    if suffix == ".py":
        return _validate_py(ref_path)
    if suffix == ".sh":
        return _validate_sh(ref_path)
    # Any other suffix: existence is enough. Intentionally do not require the
    # exec bit (GI-govcheck-language-aware) — Windows Git Bash cannot be
    # trusted to preserve it, and actual invocation is via `python3 …` or
    # `bash …` which does not consult the exec bit.
    return True, ""


def main(argv: Iterable[str]) -> int:
    argv = list(argv)
    # Allow ``--root <path>`` override for tests / tooling; default is CWD.
    root = Path.cwd()
    i = 1
    while i < len(argv):
        token = argv[i]
        if token == "--root":
            if i + 1 >= len(argv):
                print("rein-govcheck: --root requires an argument", file=sys.stderr)
                return 2
            root = Path(argv[i + 1]).resolve()
            i += 2
            continue
        if token in ("-h", "--help"):
            print(__doc__ or "")
            return 0
        print(f"rein-govcheck: unknown argument: {token}", file=sys.stderr)
        return 2

    refs = collect_script_refs(root)
    failures: list[tuple[str, str]] = []
    for ref in sorted(refs):
        ok, detail = validate_ref(ref, root)
        if not ok:
            failures.append((ref, detail))

    if failures:
        print(
            f"rein-govcheck: {len(failures)} reference(s) failed validation:",
            file=sys.stderr,
        )
        for ref, detail in failures:
            print(f"  - {ref}: {detail}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
