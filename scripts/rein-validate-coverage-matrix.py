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


def _heading_matches(line: str, heading: str) -> bool:
    """True if ``line`` is ``heading``, tolerating an optional ``N. `` numeric
    prefix after the ``##`` marker. spec-writer naturally numbers section
    headings (``## 3. Scope Items``); accepting the numbered form removes the
    recurring need to hand-normalize specs before validation (2026-06-16 session
    follow-up). The strict unnumbered form still matches.
    """
    stripped = line.strip()
    if stripped == heading:
        return True
    m = re.match(r"^(#+)\s+(.*\S)\s*$", heading)
    if not m:
        return False
    hashes, title = m.group(1), m.group(2)
    return (
        re.match(rf"^{re.escape(hashes)}\s+\d+\.\s+{re.escape(title)}\s*$", stripped)
        is not None
    )

# Plan's design_ref appears in either the blockquote form `> design ref:` or
# the top-level form `Design Reference:` per docs/specs/2026-04-21-governance-
# integrity-design.md §5. Both must resolve identically (H1 parity — wrapper
# now also recognises both; the drift flagged by codex 2026-04-22 Round 1).
DESIGN_REF_RE = re.compile(
    r"^(?:>\s*design\s*ref|design\s*reference)\s*:\s*(.+?)\s*$",
    re.IGNORECASE,
)
MATRIX_ROW_RE = re.compile(
    r"^\|\s*`?(?P<id>[A-Za-z0-9_\-]+)`?\s*\|\s*(?P<status>implemented|deferred)\s*\|\s*(?P<loc>.+?)\s*\|\s*$"
)
SCOPE_ROW_RE = re.compile(r"^\|\s*`?(?P<id>[A-Za-z0-9_\-]+)`?\s*\|\s*.+?\s*\|\s*$")
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
# rule: plugins/rein-core/rules/design-plan-coverage.md §1.3
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
    r"^\|\s*`?(?P<id>[A-Za-z0-9_\-]+)`?\s*\|\s*`?(?P<kind>[A-Za-z0-9_\-]+)`?\s*\|\s*.+?\s*\|\s*$"
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
        if _heading_matches(line, SCOPE_ITEMS_HEADING):
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


# ---------- Execution strategy parser v2 (wave parallel, 2026-05-30) -------
#
# Plan 의 `## 실행 전략` 섹션을 태스크별 v2 스키마로 파싱 + fail-closed 검증.
# 섹션 부재 plan 은 순차 실행으로 처리 (backward-compat — legacy plan 회귀 없음).
#
# rule:  plugins/rein-core/rules/design-plan-coverage.md §2A
# schema: plugins/rein-core/docs/exec-strategy-schema.md
#
#   ## 실행 전략
#   tasks:
#     - id: <task-id>
#       depends_on: [<id>, ...]      # optional, default []
#       mode: edit_only | mutating
#       scope:
#         - <literal-file-path>
#
# Fail-closed 조건 (present 일 때 검증; 하나라도 위반 → validate_plan exit 2):
#   (a) id 누락 또는 중복
#   (b) depends_on 원소가 존재하지 않는 id 참조
#   (c) 의존 사이클 (Kahn 위상정렬로 모든 노드 소진 못 함)
#   (d) mode 가 {edit_only, mutating} 아님
#   (e) scope 누락 / 빈 list / non-list (inline) shape
#   (f) scope 원소가 glob 메타문자 / 디렉토리 / non-path token
#   (g) 동시 실행 가능한 두 edit_only 태스크 (서로 depends_on 경로 없음) 의
#       scope 가 겹침 — depends_on 으로 순서 강제된 쌍은 겹쳐도 OK
#   (h) 구 parallelizable:/workers: shape 감지 → 마이그레이션 메시지

EXEC_STRATEGY_HEADING = "## 실행 전략"
# Legacy v1 shape detection (condition h).
LEGACY_PARALLELIZABLE_RE = re.compile(r"^\s*parallelizable\s*:", re.IGNORECASE)
LEGACY_WORKERS_RE = re.compile(r"^\s*workers\s*:", re.IGNORECASE)
LEGACY_MIGRATION_MSG = (
    "legacy parallelizable/workers shape — migrate to "
    "tasks[]/depends_on/mode/scope v2; see "
    "plugins/rein-core/docs/exec-strategy-schema.md"
)

TASKS_HEADER_RE = re.compile(r"^\s*tasks\s*:\s*$", re.IGNORECASE)
TASK_ID_RE = re.compile(r"^\s*-\s+id\s*:\s*(?P<id>.+?)\s*$", re.IGNORECASE)
# A new task list item begins with `- <key>:` (e.g. `- id:`, `- mode:`). Used to
# detect a task element whose first key is NOT `id` → fail-closed (a) id missing.
TASK_ITEM_START_RE = re.compile(r"^\s*-\s+(?P<key>[A-Za-z_]+)\s*:", re.IGNORECASE)
DEPENDS_ON_RE = re.compile(r"^\s*depends_on\s*:\s*\[(?P<ids>.*)\]\s*$", re.IGNORECASE)
MODE_RE = re.compile(r"^\s*mode\s*:\s*(?P<mode>\S+)\s*$", re.IGNORECASE)
SCOPE_HEADER_RE = re.compile(r"^\s+scope\s*:\s*$", re.IGNORECASE)
SCOPE_INLINE_RE = re.compile(r"^\s+scope\s*:\s*(?P<value>.+?)\s*$", re.IGNORECASE)
SCOPE_ITEM_RE = re.compile(r"^\s+-\s+(?P<value>.+?)\s*$")

VALID_MODES = {"edit_only", "mutating"}

# Glob meta-chars (subset of POSIX glob — first-cycle conservative).
GLOB_META_RE = re.compile(r"[\*\?\[\]]")


def parse_execution_strategy(plan_path: Path) -> dict:
    """Return execution-strategy v2 dict for a plan.

    Shape: ``{"tasks": [{"id","depends_on":[...],"mode","scope":[...]}],
              "errors": list[str], "present": bool}``.

    Absent section → ``{"tasks": [], "errors": [], "present": False}``
    (backward-compat — sequential execution, no regression).

    Legacy ``parallelizable:``/``workers:`` shape → single migration error
    (condition h) returned immediately.
    """
    out: dict = {"tasks": [], "errors": [], "present": False}
    if not plan_path.exists():
        return out
    try:
        text = plan_path.read_text(encoding="utf-8")
    except Exception:
        return out
    lines = text.splitlines()

    # Locate section. A real `## 실행 전략` heading is a column-0 H2; the schema
    # is also shown as an INDENTED example inside ```fenced``` code blocks in
    # plan prose (e.g. this plan's Task 1.1) — those must NOT be treated as the
    # live section. So: skip fenced code blocks AND require the heading at
    # column 0 (no leading indentation).
    sec_start = None
    in_fence = False
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if line.rstrip() == EXEC_STRATEGY_HEADING:
            sec_start = i
            break
    if sec_start is None:
        return out  # backward-compat: absent section = sequential

    out["present"] = True

    # Gather the section body (until next top-level "## " heading; ignore
    # headings inside fenced code blocks within the section body).
    body: list[str] = []
    body_in_fence = False
    for raw in lines[sec_start + 1 :]:
        stripped = raw.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            body_in_fence = not body_in_fence
            body.append(raw)
            continue
        if not body_in_fence and raw.startswith("## "):
            break
        body.append(raw)

    # (h) Legacy shape detection — short-circuit before v2 parsing.
    for raw in body:
        if LEGACY_PARALLELIZABLE_RE.match(raw) or LEGACY_WORKERS_RE.match(raw):
            out["errors"].append(LEGACY_MIGRATION_MSG)
            return out

    # v2 parse: tasks[] with id / depends_on / mode / scope.
    in_tasks = False
    current: dict | None = None
    in_scope = False
    for raw in body:
        if not in_tasks:
            if TASKS_HEADER_RE.match(raw):
                in_tasks = True
            continue

        # A new task list element begins with `- <key>:`. If the first key is
        # `id`, capture the id; otherwise the task is missing its id (the YAML
        # element exists but `id` is not its leading key) → fail-closed (a). We
        # still fall through so the leading key (e.g. `- mode: ...`) is parsed
        # as a field of this task rather than dropped.
        m_item = TASK_ITEM_START_RE.match(raw)
        if m_item:
            m = TASK_ID_RE.match(raw)
            current = {
                "id": m.group("id").strip() if m else None,
                "depends_on": [],
                "mode": None,
                "scope": [],
                "_has_scope_key": False,
                "_inline_scope": None,
            }
            out["tasks"].append(current)
            in_scope = False
            if m:
                continue  # `- id:` fully consumed
            # Non-id leading key (e.g. `- mode:`): strip the dash so the field
            # regexes below see a plain `key: value` line, then re-process.
            raw = re.sub(r"^(\s*)-\s+", r"\1  ", raw, count=1)

        if current is None:
            continue

        # depends_on: [a, b]
        m = DEPENDS_ON_RE.match(raw)
        if m and not in_scope:
            ids_raw = m.group("ids")
            current["depends_on"] = [x.strip() for x in ids_raw.split(",") if x.strip()]
            continue

        # mode: edit_only|mutating
        m = MODE_RE.match(raw)
        if m and not in_scope:
            current["mode"] = m.group("mode").strip().lower()
            continue

        # scope: (inline) — `scope: foo` non-list, or `scope: []` empty.
        m = SCOPE_INLINE_RE.match(raw)
        if m:
            current["_has_scope_key"] = True
            inline_val = m.group("value").strip()
            if inline_val != "[]":
                current["_inline_scope"] = inline_val
            in_scope = False
            continue

        # scope:  (block form)
        if SCOPE_HEADER_RE.match(raw):
            current["_has_scope_key"] = True
            in_scope = True
            continue

        # - <scope item>
        if in_scope:
            m = SCOPE_ITEM_RE.match(raw)
            if m:
                current["scope"].append(m.group("value").strip())

    return out


def _reachable_pairs(tasks: list[dict]) -> tuple[dict[str, set[str]], list[str]]:
    """Transitive reachability over depends_on.

    Returns ``(reach, cycle_errors)`` where ``reach[x]`` is the set of task ids
    reachable from ``x`` following ``depends_on`` edges (i.e. ``x`` transitively
    depends on every id in ``reach[x]``). ``cycle_errors`` is non-empty when a
    dependency cycle is detected via Kahn topological sort (condition c).
    """
    ids = [t["id"] for t in tasks]
    id_set = set(ids)
    # edges: x depends_on y  (x -> y). For Kahn, count in-degree of x = len(deps).
    deps = {t["id"]: [d for d in t["depends_on"] if d in id_set] for t in tasks}

    # Kahn topological sort over the dependency graph.
    indeg = {i: len(deps[i]) for i in ids}
    dependents: dict[str, list[str]] = {i: [] for i in ids}
    for x in ids:
        for y in deps[x]:
            dependents[y].append(x)
    queue = [i for i in ids if indeg[i] == 0]
    drained = 0
    qi = 0
    while qi < len(queue):
        node = queue[qi]
        qi += 1
        drained += 1
        for child in dependents[node]:
            indeg[child] -= 1
            if indeg[child] == 0:
                queue.append(child)

    cycle_errors: list[str] = []
    if drained != len(ids):
        cycle_errors.append("exec-strategy: dependency cycle detected in depends_on (fail-closed c)")

    # Transitive closure of depends_on (DFS per node; safe even with a cycle).
    reach: dict[str, set[str]] = {i: set() for i in ids}
    for start in ids:
        stack = list(deps[start])
        seen: set[str] = set()
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            stack.extend(deps.get(cur, []))
        reach[start] = seen
    return reach, cycle_errors


def _validate_exec_strategy_tasks(tasks: list[dict]) -> list[str]:
    """Enforce v2 fail-closed conditions (a)-(g). Returns error strings."""
    errors: list[str] = []

    # (a) id missing / duplicate.
    seen_ids: set[str] = set()
    for t in tasks:
        tid = t.get("id")
        if not tid:
            errors.append("exec-strategy: task with missing id (fail-closed a)")
            continue
        if tid in seen_ids:
            errors.append(f"exec-strategy: duplicate task id '{tid}' (fail-closed a)")
        seen_ids.add(tid)

    # (b) depends_on references nonexistent id.
    for t in tasks:
        for dep in t.get("depends_on", []):
            if dep not in seen_ids:
                errors.append(
                    f"exec-strategy: task '{t.get('id')}' depends_on unknown id '{dep}' (fail-closed b)"
                )

    # (d) mode invalid.
    for t in tasks:
        mode = t.get("mode")
        if mode not in VALID_MODES:
            errors.append(
                f"exec-strategy: task '{t.get('id')}' mode '{mode}' not in {{edit_only, mutating}} (fail-closed d)"
            )

    # (e) scope missing / empty / non-list.
    for t in tasks:
        tid = t.get("id")
        if not t.get("_has_scope_key"):
            errors.append(f"exec-strategy: task '{tid}' scope key missing (fail-closed e)")
            continue
        if t.get("_inline_scope") is not None:
            errors.append(
                f"exec-strategy: task '{tid}' scope is not a list — inline value "
                f"'{t['_inline_scope']}' (fail-closed e)"
            )
            continue
        if not t.get("scope"):
            errors.append(f"exec-strategy: task '{tid}' scope is empty list (fail-closed e)")
            continue
        # (f) scope item: glob meta-char / directory / non-path token.
        for item in t["scope"]:
            if not re.search(r"[A-Za-z/]", item):
                errors.append(
                    f"exec-strategy: task '{tid}' scope item '{item}' is not a valid file path "
                    f"token — needs alpha char or '/' (fail-closed f)"
                )
                continue
            if GLOB_META_RE.search(item):
                errors.append(
                    f"exec-strategy: task '{tid}' scope contains glob meta-char in '{item}' (fail-closed f)"
                )
                continue
            if item.endswith("/"):
                errors.append(
                    f"exec-strategy: task '{tid}' scope contains directory path '{item}' — "
                    f"literal file path required (fail-closed f)"
                )
                continue

    # (c) cycle + (g) concurrent edit_only disjoint scope.
    reach, cycle_errors = _reachable_pairs(tasks)
    errors.extend(cycle_errors)
    if not cycle_errors:
        edit_only = [t for t in tasks if t.get("mode") == "edit_only" and t.get("id")]
        for i in range(len(edit_only)):
            for j in range(i + 1, len(edit_only)):
                a, b = edit_only[i], edit_only[j]
                aid, bid = a["id"], b["id"]
                # Concurrent = neither reachable from the other (no depends_on path).
                if bid in reach.get(aid, set()) or aid in reach.get(bid, set()):
                    continue  # ordered by depends_on → may share scope (g')
                overlap = set(a.get("scope", [])) & set(b.get("scope", []))
                if overlap:
                    errors.append(
                        f"exec-strategy: concurrent edit_only tasks '{aid}' and '{bid}' have "
                        f"overlapping scope {sorted(overlap)} (fail-closed g)"
                    )

    return errors


def compute_wave_schedule(tasks: list[dict]) -> list[list[str]]:
    """Deterministic wave schedule (schedule emitter — scheduling SSOT).

    Each step computes the ready set (tasks whose depends_on are all completed).
    If any ready task is ``mutating``, run ONLY the earliest-in-plan-order
    mutating task as its own step, then recompute. Otherwise emit all ready
    ``edit_only`` tasks as one step (wave). Ids within a step keep plan order.

    Assumes acyclic input (validator guarantees it). Returns ``[]`` for empty
    or absent tasks.
    """
    order = {t["id"]: idx for idx, t in enumerate(tasks) if t.get("id")}
    by_id = {t["id"]: t for t in tasks if t.get("id")}
    completed: set[str] = set()
    schedule: list[list[str]] = []

    remaining = [t["id"] for t in tasks if t.get("id")]
    while len(completed) < len(remaining):
        ready = [
            tid
            for tid in remaining
            if tid not in completed
            and all(dep in completed for dep in by_id[tid].get("depends_on", []))
        ]
        if not ready:
            break  # safety: should not happen on acyclic input
        ready.sort(key=lambda x: order[x])
        mutating = [tid for tid in ready if by_id[tid].get("mode") == "mutating"]
        if mutating:
            schedule.append([mutating[0]])
            completed.add(mutating[0])
            continue
        schedule.append(ready)
        completed.update(ready)
    return schedule


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
        if _heading_matches(line, SCOPE_ITEMS_HEADING):
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
        if _heading_matches(line, MATRIX_HEADING):
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

    # Execution-strategy v2 (2026-05-30): wave-parallel fail-closed validation.
    # Absent section → present=False → no errors (backward-compat, sequential).
    exec_strategy = parse_execution_strategy(plan_path)
    for e in exec_strategy.get("errors", []):
        failures.append(e)
    if exec_strategy.get("present") and not exec_strategy.get("errors"):
        for e in _validate_exec_strategy_tasks(exec_strategy["tasks"]):
            failures.append(e)

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
    "  rein-validate-coverage-matrix.py plan     <plan-file>\n"
    "  rein-validate-coverage-matrix.py dod      <dod-file>\n"
    "  rein-validate-coverage-matrix.py schedule <plan-file>\n"
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


def emit_schedule_cli(argv: list[str]) -> int:
    """`schedule <plan>` — print the deterministic wave schedule.

    Output: one ``step <n>: <id> [<id> ...]`` line per wave (ids in plan order).
    Absent ``## 실행 전략`` section → empty output + exit 0. The schedule is
    only emitted when the strategy section is present AND structurally valid;
    a validation failure (or legacy shape) exits 2 so callers never dispatch
    against an unsound schedule.
    """
    if len(argv) < 2:
        return _usage_error("schedule subcommand requires <plan-file>")
    plan_path = Path(argv[1])
    if not plan_path.exists():
        err(f"plan file not found: {plan_path}")
        return 2
    exec_strategy = parse_execution_strategy(plan_path)
    if not exec_strategy.get("present"):
        return 0  # absent section → empty output, sequential
    errors = list(exec_strategy.get("errors", []))
    if not errors:
        errors = _validate_exec_strategy_tasks(exec_strategy["tasks"])
    if errors:
        err(f"schedule: execution strategy invalid for {plan_path}:")
        for e in errors:
            err(f"  - {e}")
        return 2
    schedule = compute_wave_schedule(exec_strategy["tasks"])
    for n, step in enumerate(schedule, start=1):
        print(f"step {n}: {' '.join(step)}")
    return 0


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
    if first == "schedule":
        return emit_schedule_cli(argv[1:])

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
