#!/usr/bin/env python3
"""Validate design→plan coverage matrix.

Usage:
    rein-validate-coverage-matrix.py <plan-file>

Exit codes:
    0 — plan is valid, or plan has no coverage matrix section (legacy)
    2 — validation failure; details on stderr
    3 — usage error (bad args, file not found)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


MATRIX_HEADING = "## Design 범위 커버리지 매트릭스"
DESIGN_REF_RE = re.compile(r"^>\s*design\s*ref:\s*(.+?)\s*$", re.IGNORECASE)
MATRIX_ROW_RE = re.compile(
    r"^\|\s*(?P<id>[A-Za-z0-9_\-]+)\s*\|\s*(?P<status>implemented|deferred)\s*\|\s*(?P<loc>.+?)\s*\|\s*$"
)
SCOPE_ITEMS_HEADING = "## Scope Items"
SCOPE_ROW_RE = re.compile(r"^\|\s*(?P<id>[A-Za-z0-9_\-]+)\s*\|\s*.+?\s*\|\s*$")
COVERS_RE = re.compile(r"^covers:\s*\[(?P<ids>.*?)\]\s*$", re.MULTILINE)


def err(msg: str) -> None:
    print(f"coverage-matrix: {msg}", file=sys.stderr)


def parse_scope_ids_from_design(design_path: Path) -> set[str] | None:
    """Return set of IDs in design's '## Scope Items' table. None if no section."""
    if not design_path.exists():
        err(f"design file not found: {design_path}")
        return None
    lines = design_path.read_text(encoding="utf-8").splitlines()
    ids: set[str] = set()
    in_section = False
    for line in lines:
        if line.strip() == SCOPE_ITEMS_HEADING:
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if in_section:
            m = SCOPE_ROW_RE.match(line)
            if m:
                rid = m.group("id")
                if rid.lower() in {"id", "scope id", "-"} or re.fullmatch(r"-+", rid):  # header/separator
                    continue
                ids.add(rid)
    if not ids:
        return None
    return ids


def parse_plan(plan_path: Path) -> dict:
    """Extract matrix rows, design ref, and covers: entries from plan."""
    text = plan_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    # Locate matrix section
    matrix_start = None
    for i, line in enumerate(lines):
        if line.strip() == MATRIX_HEADING:
            matrix_start = i
            break
    if matrix_start is None:
        return {"has_matrix": False}

    # Parse matrix content until next "## "
    design_ref = None
    matrix: dict[str, tuple[str, str]] = {}  # id -> (status, loc)
    duplicates: list[str] = []
    for line in lines[matrix_start + 1 :]:
        if line.startswith("## "):
            break
        if design_ref is None:
            m = DESIGN_REF_RE.match(line)
            if m:
                design_ref = m.group(1).strip()
                continue
        m = MATRIX_ROW_RE.match(line)
        if m:
            rid = m.group("id")
            if rid.lower() in {"id", "scope id", "-"}:
                continue
            if rid in matrix:
                duplicates.append(rid)
            matrix[rid] = (m.group("status"), m.group("loc"))

    # Parse covers: lines
    covers: list[set[str]] = []
    for m in COVERS_RE.finditer(text):
        ids_raw = m.group("ids")
        ids = {x.strip() for x in ids_raw.split(",") if x.strip()}
        if ids:
            covers.append(ids)

    return {
        "has_matrix": True,
        "design_ref": design_ref,
        "matrix": matrix,
        "duplicates": duplicates,
        "covers": covers,
    }


def validate(plan_path: Path) -> int:
    parsed = parse_plan(plan_path)
    if not parsed["has_matrix"]:
        err(f"WARN: no coverage matrix in {plan_path} — skipped (legacy plan)")
        return 0

    failures: list[str] = []

    # design ref required
    ref = parsed.get("design_ref")
    if not ref:
        failures.append("missing '> design ref: <path>' in matrix section")
    else:
        # Resolve design path relative to plan file or repo root
        candidates = [plan_path.parent / ref, Path.cwd() / ref, Path(ref)]
        design_path = next((p for p in candidates if p.exists()), None)
        if design_path is None:
            failures.append(f"design ref path not found: {ref}")
        else:
            design_ids = parse_scope_ids_from_design(design_path)
            if design_ids is None:
                failures.append(f"design {design_path} has no '## Scope Items' table")
            else:
                matrix_ids = set(parsed["matrix"].keys())
                missing = design_ids - matrix_ids
                extra = matrix_ids - design_ids
                if missing:
                    failures.append(
                        f"design IDs missing from matrix: {sorted(missing)}"
                    )
                if extra:
                    failures.append(
                        f"matrix contains IDs not in design: {sorted(extra)}"
                    )

    # Duplicates
    if parsed["duplicates"]:
        failures.append(f"duplicate IDs in matrix: {sorted(set(parsed['duplicates']))}")

    # covers: consistency
    implemented = {
        rid for rid, (status, _) in parsed["matrix"].items() if status == "implemented"
    }
    all_covered: set[str] = set()
    for cov in parsed["covers"]:
        unknown = cov - set(parsed["matrix"].keys())
        if unknown:
            failures.append(
                f"covers: references IDs not in matrix: {sorted(unknown)}"
            )
        deferred_ref = cov & {
            rid for rid, (status, _) in parsed["matrix"].items() if status == "deferred"
        }
        if deferred_ref:
            failures.append(
                f"covers: references deferred IDs (must be implemented): {sorted(deferred_ref)}"
            )
        all_covered |= cov
    uncovered = implemented - all_covered
    if uncovered:
        failures.append(
            f"matrix rows marked 'implemented' but no covers: references them: {sorted(uncovered)}"
        )

    if failures:
        err(f"validation failed for {plan_path}:")
        for f in failures:
            err(f"  - {f}")
        return 2
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        err("usage: rein-validate-coverage-matrix.py <plan-file>")
        return 3
    plan_path = Path(argv[1])
    if not plan_path.exists():
        err(f"plan file not found: {plan_path}")
        return 3
    return validate(plan_path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
