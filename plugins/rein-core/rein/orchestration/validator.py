"""Orchestration validator — v1 parallel-execute scope 검증 계승 (spec §5.3,
plan Task 5.2).

이 모듈은 WorkUnit(spec §4.3 필드 계약, 2026-08-11 정정판 — 8필드: `id`/
`objective`/`scope`/`dependencies`/`assigned_agent`/`status`/
`expected_output`/`mode`)과 Worker 결과를 **순수 dict/문자열 매핑**으로
받는다 — `work_unit.py`/`work_graph.py`
(Task 5.1, 병렬 이식 대상)를 import 하지 않는다. spec §4.1: "Python 은
Agent 를 spawn 하지 않는다 — `orchestration/` 은 ... 4개 모듈. Agent 는
판단·실행 / Runtime 은 구조화·관찰." 이 원칙 아래, validator 는 형제
모듈에 의존하지 않고 단독으로 검증 가능해야 한다(웨이브 병렬 편집
계약이기도 하다).

v1 계승 대상 (spec §5.3 계승 표, `plugins/rein-core/skills/
parallel-execute/SKILL.md` + `scripts/rein-validate-coverage-matrix.py` 의
`_validate_exec_strategy_tasks`/`_reachable_pairs` 알고리즘을 참조 이식):

1. **Dependency validation** — `dependencies` 가 존재하지 않는 unit id 를
   참조(v1 조건 b)하거나 사이클을 이룸(v1 조건 c, Kahn 위상정렬로 판정).
2. **Scope conflict validation** — 의존 사슬로 순서가 강제되지 않은(=
   동시 실행 가능한) 두 unit 의 선언 `scope` 가 겹치면 위반(v1 조건 g).
   `mode` 는 WorkUnit 의 8번째 공식 계약 필드다(spec §4.3, 2026-08-11
   정정판 — 이전 초안은 "7필드 밖의 선택적 확장"으로 서술했으나 spec 이
   정정되어 계약의 일부다) — 부재 시 "edit_only" 로 보수적 기본값
   처리하고, "mutating" 은 스케줄러(`work_graph.py`, Task 5.1)가 항상
   단독 웨이브로 격리하므로 이 정적 검증에서 제외한다(v1 은 애초에
   "동시 실행 가능한 두 edit_only" 로 조건 g 를 한정했다).
3. **scope 경로 안전화** — 절대경로·`..`/`..\\`·NUL·드라이브문자 거부 +
   `workspace_root` 파라미터 기준 realpath containment(보안 필수 승계,
   전역 cwd 가정 금지 — plan Task 5.2 명시 요구).
4. **델타 ⊆ scope 부분집합 검증** — 웨이브 barrier 이후 관측된 변경 경로가
   선언 scope 밖이면 위반. scope·델타 양쪽은 `normalize_scope_path` 로
   **동일 정규형**을 거쳐 비교한다(v1: "검증기 미필터 — 이 단계가 유일
   방어선").
5. **Worker 결과 스키마 파싱** — `task_id`/`status`/`changed_files`/
   `blocked_reason`/`recommendation`/`summary`. 결과 누락(worker 응답
   없음 — timeout/truncation)은 "missing" 으로 명시 구분하되, completed
   가 아닌 모든 상태(blocked 포함)는 호출자 관점에서 동일하게 "미완"
   (incomplete)이다 — missing 이 조용히 성공으로 격상되지 않는다(plan
   Task 5.2 요구 원문).

이 모듈은 예외를 던지는 계층과 위반 목록을 반환하는 계층을 구분한다:
경로 안전화·워커 결과 파싱은 **단일 입력의 형식 계약**이라 위반 즉시
예외(early, fail-closed)를 던지지만, dependency/scope-conflict validation
은 **여러 unit 사이의 관계** 판정이라 v1(`errors: list[str]` 누적)과
동일하게 위반들을 모아 반환한다 — 호출자가 한 번에 전부를 보고할 수
있게 한다.

## Import 경계 (Phase 5 Wave 1 codex 리뷰 NEEDS-FIX 수리 후 갱신)

이 모듈 자신은 여전히 `work_unit.py`/`work_graph.py` 를 import 하지
않는다(위 원칙 그대로 — validator 는 형제 모듈 없이 단독으로 검증
가능해야 한다). 다만 최초 빌드 단계의 "cross-module import 전면 금지"
는 이후 해제되었다 — **단방향(work_graph.py → validator.py)** 은 허용된다.
`work_graph.py` 의 스케줄러가 `canonicalize_scope_path_lexical` (아래
1b 절)을 이 모듈에서 import 해 scope 겹침 판정에 쓴다. 사이클은
생기지 않는다: validator 는 여전히 아무 형제 모듈도 import 하지 않으므로
`validator → work_graph` 역방향 간선이 존재할 수 없다.
"""
import os
import posixpath
import re
from dataclasses import dataclass


# ---------------------------------------------------------------------------
# 공통 예외 계층
# ---------------------------------------------------------------------------


class OrchestrationValidationError(Exception):
    """이 모듈이 던지는 모든 fail-closed 거부의 공통 상위 (spec §5.3 계승)."""


class PathSafetyViolation(OrchestrationValidationError):
    """scope/델타 경로 안전화 거부 (v1 barrier step 4 — 보안 필수 승계).

    `reason` 은 아래 `PATH_REJECT_*` 상수 중 하나 — 테스트/관찰이 메시지
    문자열이 아니라 속성으로 거부 종류를 구분할 수 있게 한다.
    """

    def __init__(self, reason, path):
        self.reason = reason
        self.path = path
        super().__init__(
            "scope path {!r} rejected: {}".format(path, reason)
        )


class MalformedWorkerResult(OrchestrationValidationError):
    """worker 결과가 공통 결과 스키마를 어김(v1 §워커 dispatch 계약).

    `raw is None`(결과 누락)은 이 예외가 **아니다** — `parse_worker_result`
    가 명시적으로 인정하는 별도 상태(`STATUS_MISSING`)로 처리된다. 이
    예외는 "응답은 도달했지만 계약을 어겼다" 는 뜻이다.
    """


# ---------------------------------------------------------------------------
# 1. scope 경로 안전화 (v1 barrier step 4 — 보안 필수 승계)
# ---------------------------------------------------------------------------

PATH_REJECT_EMPTY = "empty_path"
PATH_REJECT_NUL_BYTE = "nul_byte"
PATH_REJECT_DRIVE_LETTER = "drive_letter"
PATH_REJECT_ABSOLUTE = "absolute_path"
PATH_REJECT_TRAVERSAL = "parent_traversal"
PATH_REJECT_OUTSIDE_WORKSPACE = "outside_workspace_containment"

# 드라이브 문자(`C:` 류) — 백슬래시 유무와 무관하게 원본 경로 선두에서
# 검사한다(정규화 이전 — 명백한 공격 패턴을 실 파일시스템 호출 전에 끊는다).
_DRIVE_LETTER_RE = re.compile(r"^[A-Za-z]:")


def normalize_scope_path(path, workspace_root):
    """단일 경로를 안전화 정규화한다 (v1 barrier step 4, 보안 필수 승계).

    거부 순서(먼저 걸리는 조건이 `reason` 이 된다) — 문자열 검사가
    realpath 호출보다 항상 먼저다: 실 파일시스템에 접근하기 전에 명백한
    공격 패턴을 문자열만으로 끊는다(symlink 존재 여부에 기대지 않는
    1차 방어선).

    1. 빈 문자열/비문자열 → `PATH_REJECT_EMPTY`
    2. NUL 바이트 포함 → `PATH_REJECT_NUL_BYTE` (경로 위조 프레이밍 차단)
    3. 드라이브 문자(`C:` 류, 백슬래시 유무 무관) → `PATH_REJECT_DRIVE_LETTER`
    4. POSIX/Windows 절대경로(`/x`, `\\x`) → `PATH_REJECT_ABSOLUTE`
    5. `..`/`..\\` 세그먼트 포함(선두·중간 무관) → `PATH_REJECT_TRAVERSAL`
    6. `workspace_root` 기준 realpath(symlink resolve) 후 containment
       실패(workspace_root 실 경로 밖으로 벗어남) →
       `PATH_REJECT_OUTSIDE_WORKSPACE`

    통과 시 `workspace_root` 상대의 POSIX 구분자 정규화 경로(`str`)를
    반환한다. `workspace_root` 는 **호출자가 명시 전달**해야 한다 —
    전역 cwd 를 가정하지 않는다(plan Task 5.2 필수 요구; `TypeError` 로
    호출자 계약 위반을 즉시 드러낸다).
    """
    if not isinstance(path, str) or not path:
        raise PathSafetyViolation(PATH_REJECT_EMPTY, path)
    if "\x00" in path:
        raise PathSafetyViolation(PATH_REJECT_NUL_BYTE, path)
    if _DRIVE_LETTER_RE.match(path):
        raise PathSafetyViolation(PATH_REJECT_DRIVE_LETTER, path)

    normalized_slashes = path.replace("\\", "/")
    if normalized_slashes.startswith("/"):
        raise PathSafetyViolation(PATH_REJECT_ABSOLUTE, path)
    if ".." in normalized_slashes.split("/"):
        raise PathSafetyViolation(PATH_REJECT_TRAVERSAL, path)

    if not isinstance(workspace_root, str) or not workspace_root:
        raise TypeError(
            "workspace_root must be a non-empty string path — no global "
            "cwd assumption is allowed (plan Task 5.2), got "
            "{!r}".format(workspace_root)
        )
    workspace_real = os.path.realpath(workspace_root)
    candidate_real = os.path.realpath(
        os.path.join(workspace_real, normalized_slashes)
    )
    if candidate_real != workspace_real and not candidate_real.startswith(
        workspace_real + os.sep
    ):
        raise PathSafetyViolation(PATH_REJECT_OUTSIDE_WORKSPACE, path)

    relative = os.path.relpath(candidate_real, workspace_real)
    return relative.replace(os.sep, "/")


# ---------------------------------------------------------------------------
# 1b. 순수 어휘적 scope 경로 canonicalization (codex review HIGH finding —
#     scope conflict 판정이 raw 문자열을 비교해 표기 변형을 놓치던 문제)
# ---------------------------------------------------------------------------


def canonicalize_scope_path_lexical(path):
    """scope conflict 판정용 순수 어휘적 경로 정규화 — 파일시스템 접근 없음.

    `normalize_scope_path`(위 1절)와는 목적이 다르다: 그쪽은 `workspace_root`
    기준 realpath containment 로 **보안**(경로 탈출 차단)을 담당하고, 예외를
    던져 안전하지 않은 경로를 거부한다. 이 함수는 **동시 실행 가능한 두
    WorkUnit 의 scope 가 표기만 다르고 의미상 같은 경로를 가리키는지**만
    판정하는 용도다(스케줄러의 웨이브 배치 + 본 모듈의
    `validate_scope_conflicts` 양쪽에서 공유) — 실패하지 않고, 예외를
    던지지 않는다.

    정규화 규칙(전부 문자열 연산, 실 파일시스템 조회 없음):
      1. 백슬래시를 슬래시로 치환한다(`a\\b` → `a/b`).
      2. `posixpath.normpath` 로 `.`/`..` 세그먼트를 문자열 수준에서
         collapse 하고 선행 `./` 를 제거한다(`./x` → `x`,
         `dir/../dir/x` → `dir/x`).

    한계(중요, symlink aliasing): 이 함수는 실 파일시스템을 전혀 보지
    않으므로, symlink 로 인해 서로 다른 표기의 두 경로가 실제로는 같은
    파일을 가리키는 경우(예: `link/x` 가 symlink `link -> real` 을 통해
    `real/x` 와 동일 파일을 가리킴)를 검출할 수 **없다** — 어휘적으로
    다른 문자열이면 다른 경로로 취급한다. 이 케이스의 방어는 이 함수의
    책임이 아니라 `normalize_scope_path` 가 델타 검증 시점
    (`validate_delta_subset`)에 수행하는 realpath containment 의 몫이다
    — 스케줄 시점(plan-time, 아직 워커가 파일을 건드리기 전)에는
    workspace 의 실제 symlink 배치를 신뢰 있게 관찰할 수 없거나 아직
    존재하지 않을 수 있으므로, 이 함수는 애초에 그 문제를 풀려 하지
    않는다.

    비문자열 입력은 그대로 반환한다(shape 검증은 호출자 책임 —
    `validate_scope_conflicts` 의 `REASON_INVALID_SCOPE_SHAPE` 가 이미
    scope 자체가 list 인지를 별도로 검증한다).
    """
    if not isinstance(path, str):
        return path
    return posixpath.normpath(path.replace("\\", "/"))


# ---------------------------------------------------------------------------
# 2. Dependency validation (v1 조건 b·c 계승)
# ---------------------------------------------------------------------------

REASON_MISSING_ID = "missing_id"
REASON_DUPLICATE_ID = "duplicate_id"
REASON_UNKNOWN_DEPENDENCY = "unknown_dependency"
REASON_INVALID_DEPENDENCIES_SHAPE = "invalid_dependencies_shape"
REASON_CYCLE = "cycle"


@dataclass(frozen=True)
class DependencyViolation:
    """dependency validation 위반 1건 (v1 조건 b/c 계승).

    `unit_id` 는 위반의 귀속 unit id — `REASON_CYCLE` 은 사이클을 이루는
    모든 id 를 정렬해 콤마로 이은 문자열이다(단일 소유자가 없는 관계형
    위반이므로).
    """

    unit_id: object
    reason: str
    detail: str


def _extract_unit_id(unit):
    """unit dict 에서 유효한 id 를 뽑는다 — 없으면 None."""
    if not isinstance(unit, dict):
        return None
    unit_id = unit.get("id")
    if not isinstance(unit_id, str) or not unit_id:
        return None
    return unit_id


def _extract_dependency_ids(deps):
    """dependencies 필드가 유효한 shape(문자열 리스트)인지 판정.

    반환 `(ids, shape_error)` — shape_error 가 있으면 ids 는 빈 list.
    문자열 단일값은 문자 단위 분해 오인정 위험으로 명시 거부(kernel
    `policy_version_valid` 규율과 동일 방향). 개별 원소도 비어 있지 않은
    문자열이어야 한다(codex review round 2 MEDIUM finding) — dict/list
    같은 unhashable 값이 조용히 통과하면 이후 `dep not in id_set`(set
    멤버십 판정)에서 예측 불가능한 TypeError 로 터진다. 여기서
    shape_error 로 접어(fold) fail-closed 하게 처리한다 — 이 함수는
    이미 shape 위반을 raise 가 아니라 반환값으로 알리는 established
    style 이므로 그 방식을 그대로 확장한다.
    """
    if isinstance(deps, (str, bytes)) or not isinstance(deps, (list, tuple)):
        return [], "'dependencies' must be a list of unit ids, got {!r}".format(
            deps
        )
    for item in deps:
        if not isinstance(item, str) or not item:
            return [], (
                "'dependencies' entries must be non-empty strings, got "
                "{!r}".format(item)
            )
    return list(deps), None


def validate_dependencies(units):
    """Dependency validation — 미존재 참조(v1 b) + 사이클(v1 c, Kahn).

    `units` 는 `{"id": str, "dependencies": [id, ...], ...}` 매핑의
    iterable(WorkUnit 계약 필드 중 `id`/`dependencies` 만 사용 — 나머지
    필드는 이 함수 관심사 밖). 위반이 없으면 빈 tuple, 있으면
    `DependencyViolation` 의 tuple 을 반환한다(예외를 던지지 않는다 —
    v1 이 `errors: list[str]` 로 여러 위반을 한 번에 누적·보고하는 것과
    같은 방향 — 호출자가 한 번의 호출로 전부를 관찰할 수 있다).
    """
    units = list(units)
    violations = []
    ids = []
    seen = set()
    deps_by_id = {}

    for unit in units:
        unit_id = _extract_unit_id(unit)
        if unit_id is None:
            violations.append(
                DependencyViolation(
                    unit_id=None,
                    reason=REASON_MISSING_ID,
                    detail=(
                        "unit is missing a non-empty string 'id' "
                        "(spec §4.3): {!r}".format(unit)
                    ),
                )
            )
            continue
        if unit_id in seen:
            violations.append(
                DependencyViolation(
                    unit_id=unit_id,
                    reason=REASON_DUPLICATE_ID,
                    detail="duplicate unit id {!r}".format(unit_id),
                )
            )
            continue
        seen.add(unit_id)
        ids.append(unit_id)

        raw_deps = unit.get("dependencies", []) if isinstance(unit, dict) else []
        dep_ids, shape_error = _extract_dependency_ids(raw_deps)
        if shape_error:
            violations.append(
                DependencyViolation(
                    unit_id=unit_id,
                    reason=REASON_INVALID_DEPENDENCIES_SHAPE,
                    detail=shape_error,
                )
            )
        deps_by_id[unit_id] = dep_ids

    id_set = set(ids)
    for unit_id in ids:
        for dep in deps_by_id.get(unit_id, []):
            if dep not in id_set:
                violations.append(
                    DependencyViolation(
                        unit_id=unit_id,
                        reason=REASON_UNKNOWN_DEPENDENCY,
                        detail="depends on unknown unit id {!r}".format(dep),
                    )
                )

    # Kahn 위상정렬 — 사이클 판정(v1 조건 c 계승). 미존재 참조는 이미 위에서
    # 보고했으므로 여기서는 존재하는 id 로 만든 간선만 카운트한다.
    indeg = {
        uid: len([d for d in deps_by_id.get(uid, []) if d in id_set])
        for uid in ids
    }
    dependents = {uid: [] for uid in ids}
    for uid in ids:
        for dep in deps_by_id.get(uid, []):
            if dep in id_set:
                dependents[dep].append(uid)
    queue = [uid for uid in ids if indeg[uid] == 0]
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

    if ids and drained != len(ids):
        cyclic_ids = tuple(sorted(uid for uid in ids if indeg[uid] > 0))
        violations.append(
            DependencyViolation(
                unit_id=",".join(cyclic_ids),
                reason=REASON_CYCLE,
                detail="dependency cycle detected among {!r}".format(
                    cyclic_ids
                ),
            )
        )

    return tuple(violations)


# ---------------------------------------------------------------------------
# 2b. Scope conflict validation (v1 조건 g 계승)
# ---------------------------------------------------------------------------

MODE_EDIT_ONLY = "edit_only"
MODE_MUTATING = "mutating"
_VALID_MODES = (MODE_EDIT_ONLY, MODE_MUTATING)

REASON_SCOPE_OVERLAP = "scope_overlap"
REASON_INVALID_SCOPE_SHAPE = "invalid_scope_shape"
REASON_INVALID_MODE = "invalid_mode"
REASON_EMPTY_SCOPE = "empty_scope"
REASON_SCOPE_GLOB_PATTERN = "scope_glob_pattern"
REASON_SCOPE_DIRECTORY_FORM = "scope_directory_form"
REASON_SCOPE_NON_PATH_TOKEN = "scope_non_path_token"

# v1 계약 그대로 이식(신규 발명 금지, codex review round 5 HIGH finding) —
# `scripts/rein-validate-coverage-matrix.py` 의 `GLOB_META_RE = re.compile(
# r"[\*\?\[\]]")` 를 문자 그대로 재사용한다. `docs/exec-strategy-schema.md`
# §scope: "**glob/디렉토리 미지원** — `*`, `?`, `[`, `]` 메타문자 또는 `/`
# 로 끝나는 디렉토리 경로는 validator fail-closed".
_SCOPE_GLOB_META_RE = re.compile(r"[\*\?\[\]]")

# v1 조건 f 의 세 번째 sub-check 이식(codex review round 6, 신규 발명
# 금지) — `scripts/rein-validate-coverage-matrix.py` 의
# `if not re.search(r"[A-Za-z/]", item):` 를 문자 그대로 재사용한다. alpha
# 문자도 `/` 도 없는 원소(예: v1 예시 `"123"`)는 literal file path 로
# 볼 수 없다.
_SCOPE_PATH_TOKEN_RE = re.compile(r"[A-Za-z/]")


@dataclass(frozen=True)
class ScopeConflict:
    """scope conflict validation 위반 1건 (v1 조건 g 계승).

    `REASON_INVALID_SCOPE_SHAPE`/`REASON_INVALID_MODE`/`REASON_EMPTY_SCOPE`
    는 단항(unit_b=None, overlap=()) — 각각 `unit_a` 의 `scope`/`mode`
    필드 자체가 구조 결함(scope 가 list 아님 / mode 가 present 인데
    edit_only·mutating 밖 / scope 가 빈 list). `REASON_SCOPE_NON_PATH_
    TOKEN`/`REASON_SCOPE_GLOB_PATTERN`/`REASON_SCOPE_DIRECTORY_FORM` 도
    단항이다 — `unit_a` 의 `scope` 원소 하나가 alpha 문자도 `/` 도 없는
    non-path token 이거나(v1 조건 f), glob 메타문자를 포함하거나(v1
    조건 f), 디렉토리 형태(trailing `/`, v1 조건 f)라는 뜻이며, `detail`
    에 어떤 원소인지 담는다(원소별 1건씩, v1 스크립트와 동일하게 원소당
    첫 매치만 — non-path-token → glob → directory 순서 — 보고한다).
    `REASON_SCOPE_OVERLAP` 은 두 unit 사이의 관계형 위반이다.
    """

    unit_a: object
    unit_b: object
    reason: str
    detail: str
    overlap: tuple = ()


def _transitive_reach(ids, deps_by_id):
    """`dependencies` 간선의 전이적 도달 집합(DFS) — 순서 판정 재료.

    사이클이 있어도 `seen` 가드로 종료한다(무한 루프 없음) — 사이클
    판정 자체는 `validate_dependencies` 소관이고, 여기는 "이 쌍이
    의존으로 순서가 강제되는가" 만 안다.
    """
    id_set = set(ids)
    reach = {uid: set() for uid in ids}
    for start in ids:
        stack = [d for d in deps_by_id.get(start, []) if d in id_set]
        seen = set()
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            stack.extend(d for d in deps_by_id.get(cur, []) if d in id_set)
        reach[start] = seen
    return reach


def validate_scope_conflicts(units):
    """Scope conflict validation — 동시 실행 가능한 unit 쌍의 scope 겹침
    (v1 조건 g 계승).

    "동시 실행 가능" = 어느 쪽도 `dependencies` 를 통해 (직접·전이적으로)
    다른 쪽에 도달하지 못함 — 순서가 강제되지 않았다는 뜻. 이런 쌍의
    선언 `scope` 가 겹치면 `REASON_SCOPE_OVERLAP` 위반이다. 의존으로
    순서가 강제된 쌍은 겹쳐도 무방하다(v1 조건 g': "depends_on 으로 순서
    강제된 쌍은 겹쳐도 OK").

    `mode` 필드(WorkUnit 의 8번째 공식 계약 필드, 모듈 docstring 참조)가
    `"mutating"` 인 unit 은 이 정적 검사에서 제외한다 — 스케줄러가
    항상 단독 웨이브로 격리하므로 겹침 여부가 실행 시 문제되지 않는다.
    부재 시 `"edit_only"` 로 보수적 기본 처리(검사 대상에 포함).

    `mode` 가 **present 인데** `"edit_only"`/`"mutating"` 밖의 값이면
    (codex review MEDIUM finding) `REASON_INVALID_MODE` 위반을 보고한다
    — `WorkUnit` 이 알 수 없는 mode 를 생성 시점에 fail-closed 거부하는
    것과 동형이다. 예전 동작(별다른 신호 없이 조용히 edit_only 로
    취급)은 typo(`"mutatng"` 등)를 parallel-eligible 로 조용히 격하시켜
    위험했다 — 이제는 위반으로 명시 보고하되, downstream 겹침 검사에서는
    여전히 edit_only 로 취급한다(더 보수적인 방향 — 면제가 아니라 검사
    대상에 남겨둔다).

    scope 는 `canonicalize_scope_path_lexical` 로 정규화한 뒤 겹침을
    비교한다(codex review HIGH finding — `work_graph.py` 스케줄러와
    동일한 정규형을 공유해야 두 곳의 판정이 어긋나지 않는다). symlink
    aliasing 은 이 정적 검사로 잡을 수 없다 — 그 방어는 델타 검증
    시점의 `validate_delta_subset`(realpath containment) 몫이다.

    `scope` 는 v1 계약(codex review round 5/6 HIGH finding, `docs/
    exec-strategy-schema.md` §scope + `scripts/rein-validate-coverage-
    matrix.py` fail-closed 조건 (e)/(f) 그대로 이식 — 신규 발명 아님)
    을 따른다: 빈 list 는 `REASON_EMPTY_SCOPE` 위반이다. 원소별로는
    v1 과 동일한 순서(첫 매치만 보고, `continue` 의미)로 검사한다 — (1)
    alpha 문자도 `/` 도 없으면(예: `"123"`) `REASON_SCOPE_NON_PATH_
    TOKEN`, (2) glob 메타문자(`*`/`?`/`[`/`]`)를 포함하면
    `REASON_SCOPE_GLOB_PATTERN`, (3) `/` 로 끝나는 디렉토리 형태면
    `REASON_SCOPE_DIRECTORY_FORM` — literal file path 만 허용한다.
    형태 위반이 있는 scope 는(round 2/3 의 `REASON_INVALID_SCOPE_SHAPE`
    와 동일하게) 겹침 판정에서 전체를 신뢰하지 않는다(`scope_by_id` 를
    빈 집합으로 취급).

    구조 결함이 있는 unit(누락/중복 id — `validate_dependencies` 소관)은
    이 함수에서는 조용히 건너뛴다(중복 보고 방지). `scope` shape 결함
    (list 아님)만 여기서 자체 위반으로 보고한다.
    """
    units = list(units)
    ids = []
    seen = set()
    deps_by_id = {}
    scope_by_id = {}
    mode_by_id = {}
    conflicts = []

    for unit in units:
        unit_id = _extract_unit_id(unit)
        if unit_id is None or unit_id in seen:
            continue
        seen.add(unit_id)
        ids.append(unit_id)

        raw_deps = unit.get("dependencies", [])
        dep_ids, _shape_error = _extract_dependency_ids(raw_deps)
        deps_by_id[unit_id] = dep_ids

        scope = unit.get("scope", [])
        if isinstance(scope, (str, bytes)) or not isinstance(
            scope, (list, tuple)
        ):
            conflicts.append(
                ScopeConflict(
                    unit_a=unit_id,
                    unit_b=None,
                    reason=REASON_INVALID_SCOPE_SHAPE,
                    detail="'scope' must be a list of paths, got "
                    "{!r}".format(scope),
                )
            )
            scope = []
        elif any(not isinstance(p, str) or not p for p in scope):
            # 컨테이너 shape 은 맞지만(list/tuple) 개별 원소가 비어 있지
            # 않은 문자열이 아님(codex review round 2 MEDIUM finding) —
            # dict/list 같은 unhashable 값이 조용히 통과하면 아래
            # `canonicalize_scope_path_lexical` 통과 후 set comprehension
            # 에서 TypeError(unhashable type)로 터진다. 같은
            # REASON_INVALID_SCOPE_SHAPE 로 접어(fold) fail-closed 처리.
            conflicts.append(
                ScopeConflict(
                    unit_a=unit_id,
                    unit_b=None,
                    reason=REASON_INVALID_SCOPE_SHAPE,
                    detail="'scope' entries must be non-empty strings, "
                    "got {!r}".format(scope),
                )
            )
            scope = []
        elif not scope:
            # v1 fail-closed (e) 이식 — scope 누락/빈 list (codex review
            # round 5 HIGH finding). 빈 scope 는 "write-set 미상"(unknown
            # write-set)을 뜻하며, 이를 "다른 무엇과도 안 겹침"으로
            # 오판하면 위험하다.
            conflicts.append(
                ScopeConflict(
                    unit_a=unit_id,
                    unit_b=None,
                    reason=REASON_EMPTY_SCOPE,
                    detail="'scope' must be a non-empty list of literal "
                    "file paths (v1 fail-closed e — exec-strategy-"
                    "schema.md §scope)",
                )
            )
        else:
            # v1 fail-closed (f) 이식 — non-path token / glob 메타문자 /
            # 디렉토리 형태 (codex review round 5/6 HIGH finding). 원소별로
            # v1 과 동일한 순서·first-match-wins 로 개별 위반을 보고한다.
            # 어느 하나라도 위반이면(round 2/3 의 REASON_INVALID_SCOPE_
            # SHAPE 와 동일한 정책) scope 전체를 겹침 판정에서 신뢰하지
            # 않는다.
            has_form_violation = False
            for item in scope:
                if not _SCOPE_PATH_TOKEN_RE.search(item):
                    conflicts.append(
                        ScopeConflict(
                            unit_a=unit_id,
                            unit_b=None,
                            reason=REASON_SCOPE_NON_PATH_TOKEN,
                            detail="'scope' entry {!r} is not a valid "
                            "file path token — needs an alpha char or "
                            "'/' (v1 fail-closed f)".format(item),
                        )
                    )
                    has_form_violation = True
                elif _SCOPE_GLOB_META_RE.search(item):
                    conflicts.append(
                        ScopeConflict(
                            unit_a=unit_id,
                            unit_b=None,
                            reason=REASON_SCOPE_GLOB_PATTERN,
                            detail="'scope' entry {!r} contains a glob "
                            "meta-character ('*'/'?'/'['/']') — literal "
                            "file paths only (v1 fail-closed f)".format(
                                item
                            ),
                        )
                    )
                    has_form_violation = True
                elif item.endswith("/"):
                    conflicts.append(
                        ScopeConflict(
                            unit_a=unit_id,
                            unit_b=None,
                            reason=REASON_SCOPE_DIRECTORY_FORM,
                            detail="'scope' entry {!r} is a directory "
                            "path (trailing '/') — literal file path "
                            "required (v1 fail-closed f)".format(item),
                        )
                    )
                    has_form_violation = True
            if has_form_violation:
                scope = []
        scope_by_id[unit_id] = {
            canonicalize_scope_path_lexical(path) for path in scope
        }

        raw_mode = unit.get("mode", MODE_EDIT_ONLY)
        if raw_mode not in _VALID_MODES:
            conflicts.append(
                ScopeConflict(
                    unit_a=unit_id,
                    unit_b=None,
                    reason=REASON_INVALID_MODE,
                    detail="'mode' must be one of {!r} when present "
                    "(fail-closed — WorkUnit rejects unknown modes at "
                    "construction time and this validator must not "
                    "silently downgrade an unrecognized value to "
                    "edit_only), got {!r}".format(_VALID_MODES, raw_mode),
                )
            )
            raw_mode = MODE_EDIT_ONLY
        mode_by_id[unit_id] = raw_mode

    reach = _transitive_reach(ids, deps_by_id)
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            a, b = ids[i], ids[j]
            if mode_by_id[a] == MODE_MUTATING or mode_by_id[b] == MODE_MUTATING:
                continue
            if b in reach.get(a, set()) or a in reach.get(b, set()):
                continue  # ordered by dependency → may share scope (v1 g')
            overlap = scope_by_id[a] & scope_by_id[b]
            if overlap:
                conflicts.append(
                    ScopeConflict(
                        unit_a=a,
                        unit_b=b,
                        reason=REASON_SCOPE_OVERLAP,
                        detail="concurrent units share scope",
                        overlap=tuple(sorted(overlap)),
                    )
                )

    return tuple(conflicts)


# ---------------------------------------------------------------------------
# 3. 델타 ⊆ scope 부분집합 검증 (v1 barrier step 3~4 계승)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DeltaSubsetResult:
    """델타 ⊆ scope 부분집합 판정 결과.

    `violations` 가 비어 있으면 델타가 scope 부분집합이라는 뜻이다.
    `safe_scope`/`safe_delta` 는 안전화를 통과한 정규형 경로 집합
    (관찰·디버깅용 — 판정 자체는 `violations` 만으로 충분하다).
    """

    violations: tuple
    safe_scope: frozenset
    safe_delta: frozenset


def validate_delta_subset(delta_paths, scope_paths, workspace_root):
    """델타 ⊆ scope 부분집합 검증 (v1 barrier step 3~4 계승).

    scope·델타 양쪽 경로를 `normalize_scope_path` 로 **동일 정규형**으로
    정규화한 뒤 집합 비교한다(v1: "scope·델타 양쪽을 동일 정규형으로
    비교(검증기 미필터 — 이 단계가 유일 방어선)"). 정규화 자체가 실패하는
    경로(절대경로·traversal·NUL·드라이브문자·containment 실패)는:

    - scope 쪽 → **합집합에서 제외**한다(v1 원문: "정규화 실패 경로는
      합집합에서 제외") — 선언 자체가 안전하지 않으면 그 항목은 애초에
      허용 범위로 인정되지 않는다.
    - delta 쪽 → 안전하지 않은 경로가 실제로 변경됐다는 관측 자체가 즉시
      위반이다(어떤 scope 선언으로도 정당화될 수 없다) — `violations`
      에 원본 문자열 그대로 포함한다. 단, 원소 자체가 문자열이 아니면
      (dict/list 등, codex review round 3 MEDIUM finding) 원본 값을
      그대로 넣지 않는다 — `set(violations)` 로 중복 제거하는 단계에서
      unhashable 값이 TypeError 로 터지기 때문에, `normalize_scope_path`
      에 넘기기 전에 미리 걸러 `repr()` 로 안전하게(항상 hashable
      문자열) 표현해 접는다(fold).

    `delta_paths`/`scope_paths` 자체가 bare string 이면(리스트가 아니라)
    Python 이 문자 단위로 조용히 분해해 반복한다 — 예:
    `"src/a.py"` 가 8개의 1글자 "경로" 로 오판정된다. 각 글자는 그
    자체로 유효한 단일문자 경로 문자열이라 `normalize_scope_path` 도
    이를 개별적으로는 잡지 못한다(codex review round 2 MEDIUM finding).
    이 함수는 그 자체로는 format 위반에 대해 raise 하는 established
    style 이 없었지만(내부에서 `PathSafetyViolation` 을 항상 잡아
    `violations` 로 접기만 했다), 컨테이너 자체의 타입 오용은 개별 경로
    콘텐츠 문제가 아니라 **호출자 계약 위반**이다 — 이 모듈의
    `normalize_scope_path` 가 `workspace_root` 타입 오류에 대해 이미
    `TypeError` 를 던지는 것과 동일한 부류이므로, 그 확립된 방식을
    그대로 따른다(사일런트 오판정을 허용하지 않고 즉시 fail-closed).
    """
    if isinstance(delta_paths, (str, bytes)):
        raise TypeError(
            "delta_paths must be a non-string iterable of path strings — "
            "a bare string would be iterated character-by-character "
            "(codex review round 2 MEDIUM finding), got {!r}".format(
                delta_paths
            )
        )
    if isinstance(scope_paths, (str, bytes)):
        raise TypeError(
            "scope_paths must be a non-string iterable of path strings — "
            "a bare string would be iterated character-by-character "
            "(codex review round 2 MEDIUM finding), got {!r}".format(
                scope_paths
            )
        )

    safe_scope = set()
    for path in scope_paths:
        try:
            safe_scope.add(normalize_scope_path(path, workspace_root))
        except PathSafetyViolation:
            continue

    safe_delta = set()
    violations = []
    for path in delta_paths:
        if not isinstance(path, str):
            # codex review round 3 MEDIUM finding — non-str 원소(dict/
            # list 등)를 그대로 `normalize_scope_path` 에 넘기면 그
            # 함수는 `PathSafetyViolation` 을 던져 아래 except 에 잡히긴
            # 하지만, 원본 unhashable 값이 그대로 `violations` 에
            # append 되어 함수 끝의 `set(violations)` 에서 TypeError 로
            # 터진다. set() 구성 이전에(before any set() construction)
            # 여기서 미리 걸러 항상 hashable 한 문자열로 접는다(fold,
            # not raise — content violation 은 이 함수의 기존 방식과
            # 동일하게 violations 로 흘려보낸다).
            violations.append(
                "<invalid delta path element: {!r}>".format(path)
            )
            continue
        try:
            normalized = normalize_scope_path(path, workspace_root)
        except PathSafetyViolation:
            violations.append(path)
            continue
        safe_delta.add(normalized)
        if normalized not in safe_scope:
            violations.append(path)

    return DeltaSubsetResult(
        violations=tuple(sorted(set(violations))),
        safe_scope=frozenset(safe_scope),
        safe_delta=frozenset(safe_delta),
    )


# ---------------------------------------------------------------------------
# 4. Worker 결과 스키마 파싱 (v1 §워커 dispatch 계약)
# ---------------------------------------------------------------------------

STATUS_COMPLETED = "completed"
STATUS_BLOCKED = "blocked"
STATUS_MISSING = "missing"
_VALID_RAW_STATUSES = (STATUS_COMPLETED, STATUS_BLOCKED)

RECOMMENDATION_PARENT_FALLBACK = "parent_fallback"
RECOMMENDATION_SPLIT = "split"
RECOMMENDATION_SCOPE_EXPAND = "scope_expand"
_VALID_RECOMMENDATIONS = (
    RECOMMENDATION_PARENT_FALLBACK,
    RECOMMENDATION_SPLIT,
    RECOMMENDATION_SCOPE_EXPAND,
)


@dataclass(frozen=True)
class WorkerResult:
    """공통 워커 결과 스키마 (v1 §워커 dispatch 계약 그대로).

    `task_id`/`status`/`changed_files`/`summary` 는 항상 채워진다
    (missing 케이스는 `task_id=None`, `changed_files=()`,
    `summary=None`). `blocked_reason`/`recommendation` 은 `status ==
    "blocked"` 일 때만 값을 갖고, 그 외에는 `None` 이다.
    """

    task_id: object
    status: str
    changed_files: tuple
    blocked_reason: object
    recommendation: object
    summary: object

    @property
    def is_incomplete(self):
        """completed 가 아니면 전부 미완(v1: "미완 처리 → 의존 후속 진입
        불가"). blocked 과 missing(응답 없음)은 서로 다른 관찰이지만
        후속 처리 관점에서는 동일하게 "진행 불가" 다 — completed 만
        성공이다.
        """
        return self.status != STATUS_COMPLETED


def parse_worker_result(raw):
    """워커 결과를 공통 결과 스키마로 파싱한다 (v1 §워커 dispatch 계약).

    `raw is None` 은 **명시적으로 인정된 상태**다 — 타임아웃/출력
    truncation 으로 결과 자체가 도달하지 않은 경우. 이 경우 예외를
    던지지 않고 `status=STATUS_MISSING` 인 `WorkerResult` 를 반환한다
    (missing 은 스키마 위반이 아니라 운영 중 발생 가능한 정상 관찰
    값이다). missing 은 반드시 미완으로 처리되고 **성공으로 격상되지
    않는다**(plan Task 5.2 요구 원문).

    `raw` 가 dict 이지만 스키마를 어기면(예: `status` 필드 자체가 없거나
    completed/blocked 밖의 값, `task_id`/`changed_files`/`summary` 결손
    또는 잘못된 형태, blocked 인데 `blocked_reason`/`recommendation` 결손
    또는 `recommendation` 이 3종 열거 밖) `MalformedWorkerResult` — 이건
    missing 과 다른 부류다(응답은 도달했지만 계약을 어겼다).
    """
    if raw is None:
        return WorkerResult(
            task_id=None,
            status=STATUS_MISSING,
            changed_files=(),
            blocked_reason=None,
            recommendation=None,
            summary=None,
        )
    if not isinstance(raw, dict):
        raise MalformedWorkerResult(
            "worker result must be a mapping or None (missing), got "
            "{!r}".format(type(raw).__name__)
        )

    task_id = raw.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        raise MalformedWorkerResult(
            "worker result field 'task_id' must be a non-empty string, "
            "got {!r}".format(task_id)
        )

    status = raw.get("status")
    if status not in _VALID_RAW_STATUSES:
        raise MalformedWorkerResult(
            "worker result field 'status' must be one of {!r}, got "
            "{!r}".format(_VALID_RAW_STATUSES, status)
        )

    raw_changed_files = raw.get("changed_files")
    if isinstance(raw_changed_files, (str, bytes)) or not isinstance(
        raw_changed_files, (list, tuple)
    ):
        raise MalformedWorkerResult(
            "worker result field 'changed_files' must be a list of "
            "repo-relative path strings (advisory), got {!r}".format(
                raw_changed_files
            )
        )
    for item in raw_changed_files:
        if not isinstance(item, str) or not item:
            raise MalformedWorkerResult(
                "worker result field 'changed_files' entries must be "
                "non-empty strings, got {!r}".format(item)
            )
    changed_files = tuple(raw_changed_files)

    summary = raw.get("summary")
    if not isinstance(summary, str) or not summary:
        raise MalformedWorkerResult(
            "worker result field 'summary' must be a non-empty string, "
            "got {!r}".format(summary)
        )

    blocked_reason = raw.get("blocked_reason")
    recommendation = raw.get("recommendation")

    if status == STATUS_BLOCKED:
        if not isinstance(blocked_reason, str) or not blocked_reason:
            raise MalformedWorkerResult(
                "worker result field 'blocked_reason' is required and "
                "must be a non-empty string when status='blocked'"
            )
        if recommendation not in _VALID_RECOMMENDATIONS:
            raise MalformedWorkerResult(
                "worker result field 'recommendation' must be one of "
                "{!r} when status='blocked', got {!r}".format(
                    _VALID_RECOMMENDATIONS, recommendation
                )
            )
    else:
        blocked_reason = None
        recommendation = None

    return WorkerResult(
        task_id=task_id,
        status=status,
        changed_files=changed_files,
        blocked_reason=blocked_reason,
        recommendation=recommendation,
        summary=summary,
    )
