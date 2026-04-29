#!/usr/bin/env python3
"""Validate design→plan→DoD coverage (Plan A Phase 3 — validator v2).

Usage:
    rein-validate-coverage-matrix.py plan <plan-file>
    rein-validate-coverage-matrix.py dod  <dod-file>
    rein-validate-coverage-matrix.py <plan-file>   # legacy shim (deprecated)

Exit codes:
    0 — valid (or legacy plan with no coverage matrix; or DoD with no
        '## 범위 연결' section — advisory-only per v1 compat).
    2 — validation failure, or usage error. Details on stderr.
    3 — (retained only for some legacy paths; new callers should treat
        anything non-zero as failure.)

Timeouts:
    The validator itself does not enforce a timeout — callers (e.g.
    pre-edit-dod-gate.sh) are responsible for wrapping invocations in
    ``timeout 30 python3 …`` and promoting a 124 exit to a
    ``.dod-coverage-mismatch`` marker (GI-validator-v2-timeout-fail-closed).
    This file intentionally documents the contract so the hook can point at
    a single source of truth.

Design references:
    docs/specs/2026-04-21-governance-integrity-design.md §3
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------- Shared regex / headings ----------

MATRIX_HEADING = "## Design 범위 커버리지 매트릭스"
SCOPE_ITEMS_HEADING = "## Scope Items"
RANGE_LINK_HEADING = "## 범위 연결"

# Plan's design_ref appears in either the blockquote form `> design ref:` or
# the top-level form `Design Reference:` per docs/specs/2026-04-21-governance-
# integrity-design.md §5. Both must resolve identically (H1 parity — wrapper
# now also recognises both; the drift flagged by codex 2026-04-22 Round 1).
DESIGN_REF_RE = re.compile(
    r"^(?:>\s*design\s*ref|design\s*reference)\s*:\s*(.+?)\s*$",
    re.IGNORECASE,
)
MATRIX_ROW_RE = re.compile(
    r"^\|\s*(?P<id>[A-Za-z0-9_\-]+)\s*\|\s*(?P<status>implemented|deferred)\s*\|\s*(?P<loc>.+?)\s*\|\s*$"
)
SCOPE_ROW_RE = re.compile(r"^\|\s*(?P<id>[A-Za-z0-9_\-]+)\s*\|\s*.+?\s*\|\s*$")
COVERS_RE = re.compile(r"^covers:\s*\[(?P<ids>.*?)\]\s*$", re.MULTILINE)

# DoD-specific: exact line shapes inside the '## 범위 연결' section.
#
# Annotation strip (H2, 2026-04-22 retro-review-sweep): the ``plan ref:``
# value may carry an optional team/label annotation suffix such as
# ``(Team A)`` or ``(governance)``. Those are stripped by the regex below so
# downstream consumers treat the path the same regardless of annotation.
# A broader ``\(.*\)`` strip was considered but rejected — legitimate paths
# may themselves contain parentheses, and a greedy pattern would truncate
# them. Only bare identifiers and ``Team <LETTER>`` forms are recognised.
DOD_PLAN_REF_RE = re.compile(
    r"^plan\s*ref:\s*(?P<path>.+?)"
    r"(?:\s+\((?:Team\s+[A-Z]|[A-Za-z0-9_\-]+)\))?"
    r"\s*$",
    re.IGNORECASE,
)
DOD_WORK_UNIT_RE = re.compile(r"^work\s*unit:\s*(.+?)\s*$", re.IGNORECASE)
DOD_COVERS_RE = re.compile(r"^covers:\s*\[(?P<ids>.*?)\]\s*$")


# ---------- Phase 2 grandfather list (H2, 2026-04-22) -----------------
#
# DoDs shipped prior to the Phase 2 "integration DoD" schema may carry
# multiple ``plan ref:`` lines inside their ``## 범위 연결`` section. The
# Phase 1 fix fails closed on this shape for any new DoD, but legacy
# artefacts need a retro path so the codebase itself can be reviewed and
# migrated. Paths here are repo-relative.
#
# When/how entries leave this list:
#   * Phase 2 (integration DoD schema) lands in a separate spec+plan.
#   * Each grandfathered DoD is migrated to the ``dod_type: integration``
#     form, which uses a single consolidated block per plan.
#   * Upon migration, the entry is removed from this set in the same
#     commit. The test suite enforces that the set is non-empty only
#     while Phase 2 is outstanding.
PHASE_2_GRANDFATHER_DODS: frozenset[str] = frozenset({
    "trail/dod/dod-2026-04-21-drift-prevention-implementation.md",
})


def err(msg: str) -> None:
    print(f"coverage-matrix: {msg}", file=sys.stderr)


# ---------- Scope-ID version parser (Plan B Task 4.1) ------------------
#
# design 의 frontmatter 상단에서 ``scope-id-version`` 메타를 읽는다.
# rule: .claude/rules/design-plan-coverage.md §1.3
#   - frontmatter 없음 → "v1" (legacy 호환)
#   - scope-id-version: v1 → "v1"
#   - scope-id-version: v2 → "v2"
#   - 그 외 값 → "unknown" (호출자가 fail-closed 처리)

SCOPE_ID_VERSION_RE = re.compile(
    r"^\s*scope-id-version\s*:\s*(?P<value>\S+)\s*$", re.IGNORECASE
)


def parse_scope_id_version(design_path: Path) -> str:
    """Return ``"v1"`` / ``"v2"`` / ``"unknown"``.

    ``v1`` is returned when the frontmatter block is absent entirely (legacy
    compat). ``unknown`` signals that a frontmatter was present but carried
    an unrecognised version token — caller must fail-closed.
    """
    if not design_path.exists():
        return "v1"
    try:
        lines = design_path.read_text(encoding="utf-8").splitlines()[:40]
    except Exception:
        return "v1"
    # Frontmatter block: starts at very first line with '---' and ends at
    # next '---' line. Anything outside is ignored.
    if not lines or lines[0].strip() != "---":
        return "v1"
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = SCOPE_ID_VERSION_RE.match(line)
        if m:
            val = m.group("value").lower()
            if val in {"v1", "v2"}:
                return val
            return "unknown"
    return "v1"


# ---------- kind column parser (Plan B Task 4.2) -----------------------
#
# v2 design 의 ``## Scope Items`` 표는 ``| ID | kind | 설명 |`` 3 열 포맷을
# 허용한다. 기존 2 열 포맷 (``| ID | 설명 |``) 도 호환.
# ``kind: behavioral-contract`` 로 태그된 ID 는 plan work unit covers 에
# 포함될 때 해당 DoD 체크박스를 필수화한다.

SCOPE_KIND_ROW_RE = re.compile(
    r"^\|\s*(?P<id>[A-Za-z0-9_\-]+)\s*\|\s*(?P<kind>[A-Za-z0-9_\-]+)\s*\|\s*.+?\s*\|\s*$"
)


def parse_kind_from_scope_items(design_path: Path) -> dict[str, str]:
    """Return {id: kind} mapping.

    Returns empty dict when the design lacks a ``## Scope Items`` table or
    when the table has no ``kind`` column (i.e. 2-column legacy format).
    """
    if not design_path.exists():
        return {}
    lines = design_path.read_text(encoding="utf-8").splitlines()
    in_section = False
    result: dict[str, str] = {}
    for line in lines:
        if line.strip() == SCOPE_ITEMS_HEADING:
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if not in_section:
            continue
        m = SCOPE_KIND_ROW_RE.match(line)
        if not m:
            continue
        rid = m.group("id")
        kind = m.group("kind")
        # Skip the header row and the markdown separator rows.
        if rid.lower() in {"id", "scope id", "-"} or re.fullmatch(r"-+", rid):
            continue
        if kind.lower() in {"kind", "-"} or re.fullmatch(r"-+", kind):
            continue
        result[rid] = kind.lower()
    return result


# ---------- plan work unit covers parser (Plan B Task 4.2) -------------
#
# Applicability 판정 기준 = DoD 의 ``work unit:`` 필드가 가리키는 plan 의
# heading 바로 다음 줄의 ``covers: [...]``. DoD 자체의 covers 는 적용 판정
# 에 사용하지 않는다 (Round 2 HIGH subset loophole 차단).

# Accept markdown headings at any level (##, ###, ####) with flexible
# surrounding whitespace. The heading text is normalised via ``_normalise``
# before comparison.
HEADING_RE = re.compile(r"^#{2,6}\s+(?P<text>.+?)\s*$")


def _normalise_heading(text: str) -> str:
    """Lower-case + collapse consecutive whitespace to single space.

    This is what the exact-match rule should compare to avoid brittle
    literal matching (trailing whitespace, tabs, etc.).
    """
    return re.sub(r"\s+", " ", text.strip().lower())


def parse_plan_work_unit_covers(plan_path: Path, work_unit: str) -> set[str] | None:
    """Return the covers set of the plan work unit matching ``work_unit``.

    ``None`` is returned when the work unit heading is not found in the plan
    — callers decide whether to treat this as a warning or error. The
    search is heading-agnostic (Gate/Phase/Task/Step names are all OK) and
    normalises whitespace for matching.
    """
    if not plan_path.exists() or not work_unit:
        return None
    lines = plan_path.read_text(encoding="utf-8").splitlines()
    target = _normalise_heading(work_unit)

    for i, line in enumerate(lines):
        m = HEADING_RE.match(line)
        if not m:
            continue
        if _normalise_heading(m.group("text")) != target:
            continue
        # Found the heading — scan forward for the first ``covers:`` line
        # until the next heading (any level) is hit.
        for nxt in lines[i + 1 :]:
            if HEADING_RE.match(nxt):
                break
            cv = COVERS_RE.match(nxt)
            if cv:
                ids_raw = cv.group("ids")
                return {x.strip() for x in ids_raw.split(",") if x.strip()}
        # Heading matched but no covers: line before the next heading.
        return set()
    return None


# ---------- Plan parser (v1 behavior preserved) ----------


def parse_scope_ids_from_design(design_path: Path) -> set[str] | None:
    """Return set of IDs in design's '## Scope Items' table. None if no table."""
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
                if rid.lower() in {"id", "scope id", "-"} or re.fullmatch(r"-+", rid):
                    continue
                ids.add(rid)
    if not ids:
        return None
    return ids


def parse_plan(plan_path: Path) -> dict:
    """Extract matrix rows, design ref, and covers: entries from a plan."""
    text = plan_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    matrix_start = None
    for i, line in enumerate(lines):
        if line.strip() == MATRIX_HEADING:
            matrix_start = i
            break
    if matrix_start is None:
        return {"has_matrix": False}

    design_ref = None
    matrix: dict[str, tuple[str, str]] = {}
    duplicates: list[str] = []
    # Whole-file pre-scan for top-level `Design Reference:` (spec §5 requires
    # both forms to be accepted; wrapper scans the whole plan and validator
    # must match that breadth for parity — drift flagged by codex 2026-04-22).
    for line in lines:
        m = DESIGN_REF_RE.match(line)
        if m:
            design_ref = m.group(1).strip()
            break
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


def validate_plan(plan_path: Path) -> int:
    """Return 0 on success, 2 on validation failure.

    Emits structured errors to stderr prefixed with ``coverage-matrix:``.
    """
    parsed = parse_plan(plan_path)
    if not parsed["has_matrix"]:
        err(f"WARN: no coverage matrix in {plan_path} — skipped (legacy plan)")
        return 0

    failures: list[str] = []

    ref = parsed.get("design_ref")
    if not ref:
        failures.append("missing '> design ref: <path>' in matrix section")
    else:
        candidates = [plan_path.parent / ref, Path.cwd() / ref, Path(ref)]
        design_path = next((p for p in candidates if p.exists()), None)
        if design_path is None:
            failures.append(f"design ref path not found: {ref}")
        else:
            # Plan B Task 4.1 — emit scope-id-version (v1 legacy / v2 / unknown).
            sid_version = parse_scope_id_version(design_path)
            err(f"scope-id-version={sid_version}")
            if sid_version == "unknown":
                failures.append(
                    f"design {design_path} has an unrecognised "
                    f"scope-id-version (fail-closed)"
                )
            design_ids = parse_scope_ids_from_design(design_path)
            if design_ids is None:
                failures.append(f"design {design_path} has no '## Scope Items' table")
            else:
                matrix_ids = set(parsed["matrix"].keys())
                missing = design_ids - matrix_ids
                extra = matrix_ids - design_ids
                if missing:
                    failures.append(f"design IDs missing from matrix: {sorted(missing)}")
                if extra:
                    failures.append(f"matrix contains IDs not in design: {sorted(extra)}")

    if parsed["duplicates"]:
        failures.append(
            f"duplicate IDs in matrix: {sorted(set(parsed['duplicates']))}"
        )

    implemented = {
        rid for rid, (status, _) in parsed["matrix"].items() if status == "implemented"
    }
    deferred = {
        rid for rid, (status, _) in parsed["matrix"].items() if status == "deferred"
    }
    all_covered: set[str] = set()
    for cov in parsed["covers"]:
        unknown = cov - set(parsed["matrix"].keys())
        if unknown:
            failures.append(
                f"covers: references IDs not in matrix: {sorted(unknown)}"
            )
        deferred_ref = cov & deferred
        if deferred_ref:
            failures.append(
                f"covers: references deferred IDs (must be implemented): {sorted(deferred_ref)}"
            )
        all_covered |= cov
    uncovered = implemented - all_covered
    if uncovered:
        failures.append(
            f"matrix rows marked 'implemented' but no covers: references them: "
            f"{sorted(uncovered)}"
        )

    if failures:
        err(f"validation failed for {plan_path}:")
        for f in failures:
            err(f"  - {f}")
        return 2
    return 0


# ---------- DoD parser (new in v2) ----------


@dataclass
class DodContext:
    path: Path
    plan_ref: str | None = None            # first plan_ref (single-plan contract)
    all_plan_refs: list[str] = field(default_factory=list)  # all, for grandfather
    work_unit: str | None = None
    covers: list[str] = field(default_factory=list)
    has_range_link: bool = False


def parse_dod(dod_path: Path) -> DodContext:
    """Extract the ``## 범위 연결`` block from a DoD file.

    Returns an empty-ish ``DodContext`` if no such section exists (legacy
    DoD files are valid per v1 compat; callers decide whether to warn).

    H2 (2026-04-22): collects every ``plan ref:`` line into
    ``ctx.all_plan_refs`` (preserving order) so callers can detect
    multi-plan DoDs and invoke the grandfather path when applicable.
    ``ctx.plan_ref`` stays as the first matching ref (single-plan
    contract), keeping existing call sites unchanged.
    """
    ctx = DodContext(path=dod_path)
    if not dod_path.exists():
        return ctx
    text = dod_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    section_start = None
    for i, line in enumerate(lines):
        if line.strip() == RANGE_LINK_HEADING:
            section_start = i
            break
    if section_start is None:
        return ctx

    ctx.has_range_link = True
    for line in lines[section_start + 1 :]:
        if line.startswith("## "):
            break
        m = DOD_PLAN_REF_RE.match(line)
        if m:
            path = m.group("path").strip()
            ctx.all_plan_refs.append(path)
            if ctx.plan_ref is None:
                ctx.plan_ref = path
            continue
        if ctx.work_unit is None:
            m = DOD_WORK_UNIT_RE.match(line)
            if m:
                ctx.work_unit = m.group(1).strip()
                continue
        m = DOD_COVERS_RE.match(line)
        if m:
            ids_raw = m.group("ids")
            ids = [x.strip() for x in ids_raw.split(",") if x.strip()]
            # Per spec: collect the union across any covers: lines inside
            # the section (there should usually be at most one).
            ctx.covers.extend(ids)

    return ctx


def _resolve_plan_ref(dod_path: Path, plan_ref: str) -> Path | None:
    """Resolve a DoD's plan_ref to an existing file path inside the project.

    Containment check (그룹 6 P1, 2026-04-25): each candidate must resolve
    inside ``Path.cwd()``. ``../../../etc/passwd`` style refs are rejected
    so the validator never reads PROJECT_DIR-external files smuggled in
    via DoD ``plan ref:`` lines.
    """
    project_root = Path.cwd().resolve()
    candidates = [dod_path.parent / plan_ref, Path.cwd() / plan_ref, Path(plan_ref)]
    for cand in candidates:
        if not cand.exists():
            continue
        try:
            cand.resolve().relative_to(project_root)
        except ValueError:
            # Outside project root — reject this candidate.
            continue
        return cand
    return None


def _dod_is_grandfathered(dod_path: Path) -> bool:
    """Return True if ``dod_path`` is on the Phase-2 grandfather list.

    Compares using the repo-relative path form (relative to CWD) which is
    the canonical form used in the grandfather set and in spec references.

    Hardening (그룹 6 P3, 2026-04-25):
      - ``ValueError`` (resolved outside project root) → ``False``
        (raw ``as_posix()`` fall-back removed; same-basename symlink could
        otherwise spoof grandfather membership).
      - Component-wise ``is_symlink()`` check — any symlink in the path
        rejects grandfather (defense-in-depth against symlink redirection).
    """
    project_root = Path.cwd().resolve()
    try:
        rel = dod_path.resolve().relative_to(project_root).as_posix()
    except ValueError:
        return False
    cur = project_root
    for part in Path(rel).parts:
        cur = cur / part
        if cur.is_symlink():
            return False
    return rel in PHASE_2_GRANDFATHER_DODS


def validate_dod(dod_path: Path) -> int:
    """Return 0 on success, 2 on validation failure.

    Behavior:
      * No ``## 범위 연결`` section → WARN + exit 0 (v1 compat / legacy DoD).
      * Section present but ``plan ref:`` missing → exit 2.
      * Section present with **more than one** ``plan ref:`` line → fail
        closed (exit 2), unless ``dod_path`` is on
        :data:`PHASE_2_GRANDFATHER_DODS`, in which case the validator falls
        back to matrix-union validation across all referenced plans and
        emits a WARN. (H2, 2026-04-22 retro-review-sweep.)
      * Section present, single plan_ref resolves, ``covers:`` IDs must all
        be ``implemented`` in the plan's matrix
        (GI-validator-v2-dod-covers-subset). Unknown IDs, deferred IDs, or
        broken plan_ref → exit 2.
    """
    ctx = parse_dod(dod_path)
    if not ctx.has_range_link:
        err(f"WARN: no '## 범위 연결' in {dod_path} — skipped (legacy DoD)")
        return 0

    failures: list[str] = []

    if not ctx.plan_ref:
        failures.append("missing 'plan ref: <path>' under '## 범위 연결'")
    if not ctx.covers:
        failures.append("missing 'covers: [ID, ...]' under '## 범위 연결'")

    if failures:
        err(f"validation failed for {dod_path}:")
        for f in failures:
            err(f"  - {f}")
        return 2

    # H2 — multi plan_ref handling (2026-04-22).
    is_grandfathered = _dod_is_grandfathered(dod_path)
    if len(ctx.all_plan_refs) > 1 and not is_grandfathered:
        err(f"validation failed for {dod_path}:")
        err(
            f"  - DoD declares {len(ctx.all_plan_refs)} 'plan ref:' lines "
            f"under '## 범위 연결'. Integration DoD (multi-plan) support is "
            f"Phase 2 of the retro-review-sweep rollout. For now, either "
            f"split this DoD into one per plan, or consolidate the plans "
            f"into a single umbrella plan. If this DoD predates Phase 1, "
            f"add it to PHASE_2_GRANDFATHER_DODS in "
            f"scripts/rein-validate-coverage-matrix.py."
        )
        return 2
    if len(ctx.all_plan_refs) > 1 and is_grandfathered:
        err(
            f"WARN: {dod_path} has {len(ctx.all_plan_refs)} plan refs "
            f"(grandfathered for Phase 2; covers validated as matrix union)"
        )

    # Matrix union collection across plan_refs (single entry for the common
    # single-plan case; multi-plan only for grandfather).
    plans_resolved: list[tuple[str, Path]] = []
    for ref in ctx.all_plan_refs:
        resolved = _resolve_plan_ref(dod_path, ref)
        if resolved is None:
            err(f"validation failed for {dod_path}:")
            err(f"  - plan ref path not found: {ref}")
            return 2
        plans_resolved.append((ref, resolved))

    # Load each plan's matrix.
    union_matrix: dict[str, tuple[str, str]] = {}
    primary_plan_path: Path | None = None
    for ref, plan_path in plans_resolved:
        parsed = parse_plan(plan_path)
        if not parsed.get("has_matrix"):
            err(f"validation failed for {dod_path}:")
            err(
                f"  - plan {plan_path} has no '## Design 범위 커버리지 매트릭스' — "
                f"cannot validate covers"
            )
            return 2
        if primary_plan_path is None:
            primary_plan_path = plan_path
        # Union; later entries win on duplicate IDs (unlikely in practice).
        union_matrix.update(parsed["matrix"])

    matrix = union_matrix
    implemented = {rid for rid, (st, _) in matrix.items() if st == "implemented"}
    deferred = {rid for rid, (st, _) in matrix.items() if st == "deferred"}
    covers_set = set(ctx.covers)

    unknown = covers_set - set(matrix.keys())
    deferred_ref = covers_set & deferred
    not_implemented = covers_set - implemented - unknown - deferred_ref

    if unknown or deferred_ref or not_implemented:
        err(f"validation failed for {dod_path}:")
        if unknown:
            err(f"  - DoD covers references unknown IDs: {sorted(unknown)}")
        if deferred_ref:
            err(
                f"  - DoD covers references deferred IDs "
                f"(must be implemented): {sorted(deferred_ref)}"
            )
        if not_implemented:
            err(
                f"  - DoD covers references non-implemented IDs: "
                f"{sorted(not_implemented)}"
            )
        return 2

    # Plan B Task 4.2 — behavioral-contract checkbox enforcement.
    #
    # Applicability rule: kind-tagged bc IDs must intersect the **plan work
    # unit covers** (NOT the DoD's own covers). DoD covers can omit the bc
    # ID as a drift attempt — the plan work unit is the load-bearing
    # source of truth.
    #
    # For multi-plan (grandfather) DoDs we pick the first plan as the
    # reference point; migration to Phase 2 integration DoD schema will
    # define per-plan work_unit mapping explicitly.
    if primary_plan_path is not None:
        _enforce_behavioral_contract_checkbox(dod_path, ctx, primary_plan_path)

    return 0


def _read_test_oracle_severity_hard() -> bool:
    """Return the ``severity_hard`` flag from ``.claude/.rein-state/test-oracle.json``.

    Default when the file is absent or malformed: ``False`` (warn-only).
    This differs from Spec A ``governance.json`` which fails closed on
    malformed config — test-oracle is observation-first per Spec B §7.
    """
    path = Path.cwd() / ".claude" / ".rein-state" / "test-oracle.json"
    if not path.exists():
        return False
    try:
        import json

        data = json.loads(path.read_text(encoding="utf-8"))
        return bool(data.get("severity_hard", False))
    except Exception:
        return False


# Matches ``- [ ] ...behavioral-contract test...`` or ``- [x] ...`` variants.
BC_CHECKBOX_RE = re.compile(
    r"^[-*]\s*\[[ xX]\]\s+.*behavioral-contract\s+test", re.MULTILINE
)


def _enforce_behavioral_contract_checkbox(
    dod_path: Path, ctx: DodContext, plan_path: Path
) -> int:
    """Emit WARN (warn-only) or raise exit 2 (severity_hard=true).

    Returns 0 on pass / warn-only, 2 on hard failure. Callers that want
    exit-code propagation should check the return value — the main
    validate_dod caller exits immediately on 2 via sys.exit in the wrapper.
    """
    # Resolve the design for this plan to read scope-id-version + kinds.
    parsed = parse_plan(plan_path)
    ref = parsed.get("design_ref")
    if not ref:
        return 0
    candidates = [plan_path.parent / ref, Path.cwd() / ref, Path(ref)]
    design_path = next((p for p in candidates if p.exists()), None)
    if design_path is None:
        return 0
    if parse_scope_id_version(design_path) != "v2":
        return 0  # v1 or unknown — no bc enforcement here

    kinds = parse_kind_from_scope_items(design_path)
    bc_ids = {rid for rid, k in kinds.items() if k == "behavioral-contract"}
    if not bc_ids:
        return 0  # design has no kind column or no behavioral-contract tag

    # Applicability: intersect with **plan work unit covers** (NOT DoD covers).
    if not ctx.work_unit:
        err(
            f"WARN: {dod_path} has no 'work unit:' under '## 범위 연결' — "
            f"behavioral-contract applicability skipped (Stage 1 compat)"
        )
        return 0
    wu_covers = parse_plan_work_unit_covers(plan_path, ctx.work_unit)
    if wu_covers is None:
        err(
            f"WARN: {dod_path} work unit '{ctx.work_unit}' not found in "
            f"plan {plan_path} — behavioral-contract applicability skipped"
        )
        return 0
    triggered = bc_ids & wu_covers
    if not triggered:
        return 0  # no bc ID under this work unit — no checkbox required

    # Check the DoD body for the behavioral-contract test checkbox.
    try:
        text = dod_path.read_text(encoding="utf-8")
    except Exception:
        text = ""
    if BC_CHECKBOX_RE.search(text):
        return 0  # checkbox present (regardless of [ ] vs [x])

    # Missing checkbox: observation-first rollout.
    hard = _read_test_oracle_severity_hard()
    if hard:
        err(
            f"validation failed for {dod_path}:"
        )
        err(
            f"  - behavioral-contract test 체크박스가 필요합니다 (plan work "
            f"unit '{ctx.work_unit}' covers: {sorted(triggered)}). "
            f"severity_hard=true"
        )
        # Raise exit 2 by re-entering sys.exit — simpler than threading.
        sys.exit(2)
    err(
        f"WARN: {dod_path} — behavioral-contract test 체크박스 누락 "
        f"(plan work unit '{ctx.work_unit}' covers bc IDs: {sorted(triggered)}). "
        f"severity_hard=false (warn-only)"
    )
    return 0


# ---------- CLI dispatcher ----------


USAGE = (
    "usage:\n"
    "  rein-validate-coverage-matrix.py plan <plan-file>\n"
    "  rein-validate-coverage-matrix.py dod  <dod-file>\n"
    "  rein-validate-coverage-matrix.py <plan-file>   # deprecated legacy shim"
)


def _usage_error(msg: str = "") -> int:
    if msg:
        err(msg)
    err(USAGE)
    return 2


def validate_plan_cli(argv: list[str]) -> int:
    # argv is the subcommand-stripped argv (i.e. [script, file] or [file]).
    if len(argv) < 2:
        return _usage_error("plan subcommand requires <plan-file>")
    plan_path = Path(argv[1])
    if not plan_path.exists():
        err(f"plan file not found: {plan_path}")
        return 2
    return validate_plan(plan_path)


def validate_dod_cli(argv: list[str]) -> int:
    if len(argv) < 2:
        return _usage_error("dod subcommand requires <dod-file>")
    dod_path = Path(argv[1])
    if not dod_path.exists():
        err(f"dod file not found: {dod_path}")
        return 2
    return validate_dod(dod_path)


def main(argv: list[str]) -> int:
    # argv layout: [script, ...]
    if len(argv) < 2:
        return _usage_error()

    first = argv[1]
    # New-style: explicit 'plan' / 'dod' subcommand.
    if first == "plan":
        # Forward the subcommand-stripped tail.
        return validate_plan_cli(argv[1:])
    if first == "dod":
        return validate_dod_cli(argv[1:])

    # Legacy shim: if the first arg is an existing file, treat as the old
    # CLI and emit a deprecation warning on stderr (so the caller/user
    # notices and migrates), then forward to the plan subcommand.
    candidate = Path(first)
    if candidate.is_file():
        print(
            "coverage-matrix: deprecated — use 'plan <file>' subcommand. "
            "Forwarding as plan.",
            file=sys.stderr,
        )
        return validate_plan_cli(["plan", first])

    return _usage_error(f"unknown subcommand or missing file: {first}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
