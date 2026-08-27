"""WorkGraph — 웨이브 유도 결정적 스케줄러 (spec §4.3, brainstorm §39, §5.3 계승).

v1 `plugins/rein-core/skills/parallel-execute/SKILL.md` 의 웨이브 유도
규칙(ready 집합 → mutating 단독 웨이브 → edit_only 병렬 → 위상정렬·사이클
검증)을 WorkUnit 모델 위에 이식한다. 스케줄 유도 알고리즘 자체는
`scripts/rein-validate-coverage-matrix.py::compute_wave_schedule` (v1
schedule emitter SSOT) 의 동작을 그대로 계승 — spec §5.3 계승 표 "웨이브
유도 결정적 스케줄러" 행. 신규 발명 금지 원칙에 따라 규칙을 새로 만들지
않고 그대로 옮긴다.

Python 은 Agent 를 spawn 하지 않는다(spec §4.1) — 이 모듈은 웨이브 순서를
구조화할 뿐 실행 주체(Orchestrator subagent·워커)를 가정하지 않는다.

웨이브 유도 규칙(v1 `compute_wave_schedule` 과 동일):
  1. **ready 집합** = dependencies 가 모두 이전 웨이브에서 이미 스케줄된
     WorkUnit (아직 스케줄되지 않은 것 중).
  2. ready 에 mutating 이 하나라도 있으면 → 선언 순서(리스트 순서) 가장
     앞선 mutating 1개만 **단독 웨이브**로 스케줄하고 ready 를 재계산한다.
     mutating 은 어떤 WorkUnit 과도 동시 실행 금지.
  3. ready 가 전부 edit_only 면 → 선언 순서를 유지한 채 **한 웨이브로
     병렬** 스케줄한다.
  4. 위 3 과 별개로, 이 스케줄러는 v1 검증기의 fail-closed (g) 조건(동시
     실행 가능한 edit_only 쌍의 scope 겹침 reject)을 **방어적으로 보존**
     한다 — `validator.py`(Task 5.2)의 사전 검증 여부와 무관하게, scope 가
     겹치는 두 unit 은 이 모듈이 같은 웨이브에 절대 함께 배치하지 않는다.
     겹치는 unit 은 그리디 배치 순서상 나중 것을 다음 웨이브로 미룬다
     (reject 하지 않고 웨이브를 나눠 스케줄을 계속 진행 — validator.py 의
     "잘못된 입력을 거부" 책임과, 이 모듈의 "주어진 입력에 대해 항상 안전한
     스케줄을 낸다" 책임을 분리한다). scope 비교는 raw 문자열이 아니라
     `validator.canonicalize_scope_path_lexical` 을 거친 정규형으로 한다
     (codex review HIGH finding — `./x` vs `x`, `a\\b` vs `a/b`,
     `dir/../dir/x` vs `dir/x` 같은 순수 표기 변형을 겹침 누락으로 흘리지
     않는다). 이 모듈은 그 정규화 헬퍼를 `validator.py`(Task 5.2) 에서
     import 한다 — 단방향(work_graph → validator)이며 validator 는 이
     모듈을 import 하지 않으므로 사이클이 없다(빌드 단계의 cross-module
     import 전면 금지는 이후 해제됨). symlink aliasing 은 이 어휘적
     비교로는 잡을 수 없다 — 그 방어는 `validator.py` 의
     `normalize_scope_path` 가 델타 검증 시점에 realpath containment 로
     담당한다.
  5. dependencies 가 그래프에 없는 id 를 참조하거나(v1 fail-closed b) 사이클이
     있으면(v1 fail-closed c) `WorkGraph` 생성 시점에 즉시 거부한다.

``schedule()`` 은 WorkUnit.status 를 참조하지 않는다 — v1 의 정적 plan-time
스케줄 계산과 동일하게, 그래프 전체를 "아직 실행되지 않은 상태"로 간주해
결정적으로 웨이브를 유도하는 순수 함수다. 실행 관찰(planned vs actual 대조)
은 별도 모듈(Task 5.3 tracker.py)의 책임이다.
"""
from dataclasses import dataclass

from .validator import canonicalize_scope_path_lexical
from .work_unit import WORK_UNIT_MODE_MUTATING, WorkUnit


class WorkGraphError(ValueError):
    """WorkGraph 구조 위반 — 중복 id, 미지 dependency 참조, 사이클
    (v1 fail-closed a/b/c 계승)."""


def _normalize_units_sequence(value):
    """WorkGraph.units 필드를 tuple 로 정규화한다 (codex review round 4
    MEDIUM finding).

    round 3 에서 `work_unit.py` 의 `_normalize_optional_sequence` 로
    제거한 것과 동일한 함정이 `WorkGraph.units` 에도 남아 있었다:
    ``tuple(self.units or ())`` 트릭은 `False`/`0`/빈 dict 같은
    falsy-지만-not-None 값을 예외 없이 조용히 빈 그래프로 격하시켰다
    (silent data loss). 여기서는 그 함수를 그대로 import 해 재사용하지
    않는다 — 그 함수는 `WorkUnitError` 를 던지도록 고정돼 있어
    WorkGraph 의 확립된 오류 타입(`WorkGraphError`)과 맞지 않기 때문에,
    같은 판정 로직을 이 모듈의 오류 타입으로 미러링한다.

    계약: `None` 또는 non-string sequence(list/tuple)만 허용한다.
    `None` 은 "필드 생략" 으로 인정해 빈 tuple 로 취급한다. 그 외 모든
    타입(bare string/bytes, bool/int/float/dict/set 등)은 명시적으로
    `WorkGraphError` 를 던진다. 컨테이너 타입이 통과해도 각 원소가
    `WorkUnit` 인스턴스가 아니면 마찬가지로 거부한다 — duck typing 을
    믿고 넘어가면 `[u.id for u in units]` 같은 다운스트림 접근이 통제
    안 된 `AttributeError` 로 터진다(예: dict 를 truthy 값으로 넘기면
    예전엔 `tuple({...})` 가 키만 원소로 오인정했다).
    """
    if value is None:
        return ()
    if isinstance(value, (str, bytes)):
        raise WorkGraphError(
            "WorkGraph.units 는 WorkUnit 목록이어야 한다 (단일 문자열 "
            "금지): {!r}".format(value)
        )
    if not isinstance(value, (list, tuple)):
        raise WorkGraphError(
            "WorkGraph.units 는 None 이거나 list/tuple 이어야 한다 "
            "(falsy 값(False/0/빈 dict 등)도 예외 없이 거부한다 — "
            "silent data loss 방지): {!r}".format(value)
        )
    for item in value:
        if not isinstance(item, WorkUnit):
            raise WorkGraphError(
                "WorkGraph.units 의 각 원소는 WorkUnit 인스턴스여야 "
                "한다: {!r}".format(item)
            )
    return tuple(value)


@dataclass(frozen=True)
class WorkGraph:
    """WorkUnit 집합 + dependencies 로 이루어진 의존 그래프.

    생성 시점에 구조 검증(중복 id·미지 dependency·사이클)을 즉시 수행한다
    (fail-closed — v1 검증기와 동일하게 잘못된 그래프로 스케줄을 계산하지
    않는다).
    """

    units: tuple = ()

    def __post_init__(self):
        units = _normalize_units_sequence(self.units)
        object.__setattr__(self, "units", units)

        ids = [u.id for u in units]
        seen = set()
        dupes = set()
        for uid in ids:
            if uid in seen:
                dupes.add(uid)
            seen.add(uid)
        if dupes:
            raise WorkGraphError(
                "WorkGraph 에 중복 id 가 있다 (v1 fail-closed a 계승): "
                "{}".format(sorted(dupes))
            )

        id_set = set(ids)
        for u in units:
            for dep in u.dependencies:
                if dep not in id_set:
                    raise WorkGraphError(
                        "WorkUnit '{}' 의 dependency '{}' 가 그래프에 "
                        "존재하지 않는다 (v1 fail-closed b 계승)".format(
                            u.id, dep
                        )
                    )

        self._assert_acyclic()

    def _assert_acyclic(self):
        """Kahn 위상정렬로 사이클을 검출한다 (v1 `_reachable_pairs` 계승)."""
        ids = [u.id for u in self.units]
        by_id = {u.id: u for u in self.units}
        indeg = {i: len(by_id[i].dependencies) for i in ids}
        dependents = {i: [] for i in ids}
        for i in ids:
            for dep in by_id[i].dependencies:
                dependents[dep].append(i)

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

        if drained != len(ids):
            raise WorkGraphError(
                "WorkGraph 에 dependencies 사이클이 있다 (v1 fail-closed c "
                "계승)"
            )

    def schedule(self):
        """결정적 웨이브 스케줄을 계산한다.

        Returns:
            ``tuple[tuple[str, ...], ...]`` — 웨이브별 WorkUnit id 튜플.
            각 웨이브 내부 순서 및 웨이브 순서는 ``units`` 선언 순서로
            결정되며, 동일 입력에 대해 항상 동일한 결과를 낸다(spec §4.3
            결정성 요건).
        """
        order = {u.id: idx for idx, u in enumerate(self.units)}
        by_id = {u.id: u for u in self.units}
        all_ids = [u.id for u in self.units]
        completed = set()
        waves = []

        while len(completed) < len(all_ids):
            ready = [
                uid
                for uid in all_ids
                if uid not in completed
                and all(dep in completed for dep in by_id[uid].dependencies)
            ]
            if not ready:
                # 생성 시점에 사이클/미지 참조를 이미 거부했으므로 acyclic
                # 그래프에서는 도달 불가능한 상태다 — 방어적 안전장치.
                raise WorkGraphError(
                    "스케줄 계산 중 ready 집합이 비었다 (구조 검증을 우회한 "
                    "그래프로 의심됨)"
                )
            ready.sort(key=lambda uid: order[uid])

            mutating = [
                uid for uid in ready if by_id[uid].mode == WORK_UNIT_MODE_MUTATING
            ]
            if mutating:
                chosen = mutating[0]
                waves.append((chosen,))
                completed.add(chosen)
                continue

            # 전부 edit_only. scope 겹침을 절대 같은 웨이브에 두지 않도록
            # 그리디 배치한다 — 선언 순서대로 훑으며, 이미 이 웨이브에 배치된
            # unit 들의 scope 합집합과 겹치면 다음 웨이브로 미룬다.
            wave = []
            claimed_scope = set()
            for uid in ready:
                # 순수 어휘적 정규화(모듈 docstring 점 4) — raw 문자열
                # 비교는 './x' vs 'x' 같은 표기 변형을 서로 다른 경로로
                # 오판해 실제로 겹치는 scope 를 같은 웨이브에 co-schedule
                # 할 위험이 있다.
                unit_scope = {
                    canonicalize_scope_path_lexical(p)
                    for p in by_id[uid].scope
                }
                if unit_scope & claimed_scope:
                    continue  # 다음 반복(다음 웨이브)에서 다시 ready 로 평가됨
                wave.append(uid)
                claimed_scope |= unit_scope
            waves.append(tuple(wave))
            completed.update(wave)

        return tuple(waves)

    def to_planned_units(self):
        """WorkGraph 를 Tracker 소비용 순수 dict 튜플로 직렬화한다.

        plan Task 5.3 Tracker 브릿지 — sibling fix worker(Tracker 소비측 +
        통합 테스트)와 합의된 **정확한** shape 이다. 벗어나면 안 된다:
        ``{"id": str, "objective": str, "scope": [str, ...],
        "dependencies": [str, ...], "assigned_agent": str, "status": str,
        "expected_output": str, "mode": str}`` — 8개 키, 그 이상도 이하도
        아니다.

        ``units`` 선언 순서(삽입 순서)를 그대로 보존한다 — `schedule()` 이
        계산하는 웨이브 순서와는 무관하다(Tracker 는 웨이브 배치가 아니라
        "계획된 전체 unit 목록"을 필요로 한다). ``scope``/``dependencies``
        는 WorkUnit 내부에서 tuple 로 저장되지만 JSON 직렬화 안전성을 위해
        여기서 list 로 변환한다.
        """
        return tuple(
            {
                "id": u.id,
                "objective": u.objective,
                "scope": list(u.scope),
                "dependencies": list(u.dependencies),
                "assigned_agent": u.assigned_agent,
                "status": u.status,
                "expected_output": u.expected_output,
                "mode": u.mode,
            }
            for u in self.units
        )
