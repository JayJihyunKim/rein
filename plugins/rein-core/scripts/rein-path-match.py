#!/usr/bin/env python3
"""Anchored segment matcher — Plan C Task 5.2 (RU-path-glob-anchored-segment-matcher).

Implements rein's own glob matching for `rein remove --path <glob>`. The
matcher anchors every pattern to the project root and treats the path as
a list of segments: each segment between '/' is matched against the
corresponding pattern segment via fnmatch. The special segment `**` is
the only form that spans multiple segments (0 or more).

Rationale
---------
Stock shell globs anchor at both ends and treat `*` as "any non-separator
within a segment", but they only match a fixed depth. fnmatch alone
anchors nothing. Rein needs segment-anchored matching because:

- `.claude/skills/*` must match files directly under .claude/skills/ but
  NOT `.claude/skills/foo/bar.md` (nested).
- `.claude/skills/**` must match anywhere under .claude/skills/.
- `AGENTS.md` anchored at root must NOT match `foo/AGENTS.md`.
- `**/AGENTS.md` must match both `AGENTS.md` (0 leading segments) and
  `docs/AGENTS.md` (1+ leading segments).

Usage
-----
  python3 rein-path-match.py <pattern> <relpath>

Prints `true` or `false`. Exit 0 on a decisive result, 2 on usage error.
"""
from __future__ import annotations

import sys
from fnmatch import fnmatchcase


def _split(path: str) -> list[str]:
    """Normalize and split a path into segments.

    - Strips a leading './' if present.
    - Collapses repeated '/'.
    - Empty input → empty list.
    """
    s = path.strip()
    if s.startswith("./"):
        s = s[2:]
    return [seg for seg in s.split("/") if seg]


def _match_segs(pat: list[str], rel: list[str]) -> bool:
    """Recursive matcher. `**` in pattern consumes 0+ rel segments."""
    if not pat:
        return not rel
    if pat[0] == "**":
        # Try consuming 0, 1, 2, ... segments of rel.
        for i in range(len(rel) + 1):
            if _match_segs(pat[1:], rel[i:]):
                return True
        return False
    if not rel:
        return False
    if fnmatchcase(rel[0], pat[0]):
        return _match_segs(pat[1:], rel[1:])
    return False


def path_match(pattern: str, relpath: str) -> bool:
    return _match_segs(_split(pattern), _split(relpath))


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: rein-path-match.py <pattern> <relpath>\n")
        return 2
    print("true" if path_match(argv[1], argv[2]) else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
