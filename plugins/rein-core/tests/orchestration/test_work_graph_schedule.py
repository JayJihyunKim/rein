"""plan Task 5.1 — WorkUnit / WorkGraph 웨이브 스케줄 계승 계약 테스트.

고정하는 계약:
- spec §4.3(WorkUnit 필드 계약): id / objective / scope / dependencies /
  assigned_agent / status / expected_output. mode(edit_only|mutating) 는 v1
  자산 계승 필드 — spec §5.3 계승 표 "edit_only / mutating 모드 구분" 항목을
  스케줄러 동작에 필요한 최소 형태로 WorkUnit 에 이식한다(신규 발명 아님).
- spec §5.3 계승 표 "웨이브 유도 결정적 스케줄러" 행: ready 집합 → mutating
  단독 웨이브 → edit_only 병렬 → 위상정렬·사이클 검증. v1 SSOT
  (`scripts/rein-validate-coverage-matrix.py::compute_wave_schedule`) 와
  동등 판정을 v1 대표 케이스 이식으로 검증한다 — 이식 원본:
  `tests/scripts/test-wave-scheduler-and-parent-delta.sh` case 1 / case 2.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.orchestration.work_graph import WorkGraph, WorkGraphError  # noqa: E402
from rein.orchestration.work_unit import (  # noqa: E402
    WORK_UNIT_MODE_EDIT_ONLY,
    WORK_UNIT_MODE_MUTATING,
    WorkUnit,
    WorkUnitError,
)


def _unit(id_, deps=(), mode=WORK_UNIT_MODE_EDIT_ONLY, scope=None):
    """테스트 fixture 헬퍼 — spec §4.3 8필드 중 objective/expected_output 은
    스케줄링과 무관하므로 고정 placeholder 로 채운다."""
    return WorkUnit(
        id=id_,
        objective="objective for {}".format(id_),
        scope=scope if scope is not None else ["path/{}.py".format(id_)],
        dependencies=deps,
        mode=mode,
        expected_output="n/a",
    )


class IndependentUnitsParallelTest(unittest.TestCase):
    """독립 WorkUnit(선행 의존 없음 + scope 분리) → 같은 웨이브(병렬).

    spec §40 병렬 우선 조건: 업무 독립 + scope 실질 분리 + 선행 의존 없음.
    """

    def test_independent_edit_only_units_share_one_wave(self):
        a = _unit("A")
        b = _unit("B")
        graph = WorkGraph(units=[a, b])
        self.assertEqual(graph.schedule(), (("A", "B"),))

    def test_three_independent_units_share_one_wave(self):
        units = [_unit("A"), _unit("B"), _unit("C")]
        graph = WorkGraph(units=units)
        self.assertEqual(graph.schedule(), (("A", "B", "C"),))


class DependentUnitsSequentialTest(unittest.TestCase):
    """dependencies 존재 → 선행 완료 후 실행 (spec §39)."""

    def test_dependent_unit_scheduled_in_later_wave(self):
        a = _unit("A")
        b = _unit("B", deps=("A",))
        graph = WorkGraph(units=[a, b])
        self.assertEqual(graph.schedule(), (("A",), ("B",)))

    def test_diamond_dependency_resolves_in_three_waves(self):
        # A -> {B, C} -> D  (B, C 는 서로 독립, 둘 다 A 에 의존)
        a = _unit("A")
        b = _unit("B", deps=("A",), scope=["path/B.py"])
        c = _unit("C", deps=("A",), scope=["path/C.py"])
        d = _unit("D", deps=("B", "C"), scope=["path/D.py"])
        graph = WorkGraph(units=[a, b, c, d])
        self.assertEqual(graph.schedule(), (("A",), ("B", "C"), ("D",)))


class ScopeConflictAndMutatingSoloTest(unittest.TestCase):
    """conflict → 병렬화 금지 판정: mutating 단독 웨이브 + scope 겹침 분리."""

    def test_mutating_never_shares_a_wave_with_anything(self):
        # v1 SSOT 이식 (test-wave-scheduler-and-parent-delta.sh case 1):
        # A, B edit_only 무의존 → 같은 웨이브. C mutating, depends_on [A,B] →
        # 단독 웨이브.
        a = _unit("A", scope=["plugins/rein-core/rules/a.md"])
        b = _unit("B", scope=["plugins/rein-core/rules/b.md"])
        c = _unit(
            "C",
            deps=("A", "B"),
            mode=WORK_UNIT_MODE_MUTATING,
            scope=["scripts/gen.py"],
        )
        graph = WorkGraph(units=[a, b, c])
        self.assertEqual(graph.schedule(), (("A", "B"), ("C",)))

    def test_mutating_runs_solo_even_with_ready_edit_only_sibling(self):
        # v1 SSOT 이식 (case 2): M(mutating, 무의존) + E(edit_only, 무의존) 모두
        # ready → M 단독 웨이브가 먼저, E 는 다음 웨이브(동시 실행 금지).
        m = _unit("M", mode=WORK_UNIT_MODE_MUTATING, scope=["scripts/gen.py"])
        e = _unit("E", scope=["plugins/rein-core/rules/e.md"])
        graph = WorkGraph(units=[m, e])
        self.assertEqual(graph.schedule(), (("M",), ("E",)))

    def test_two_ready_mutating_units_each_get_their_own_solo_wave(self):
        # 둘 다 mutating, 서로 무의존 → 동시 실행 금지이므로 plan 순서대로
        # 각자 단독 웨이브.
        m1 = _unit("M1", mode=WORK_UNIT_MODE_MUTATING, scope=["scripts/gen1.py"])
        m2 = _unit("M2", mode=WORK_UNIT_MODE_MUTATING, scope=["scripts/gen2.py"])
        graph = WorkGraph(units=[m1, m2])
        self.assertEqual(graph.schedule(), (("M1",), ("M2",)))

    def test_overlapping_scope_edit_only_units_never_share_a_wave(self):
        a = _unit("A", scope=["shared/conflict.py"])
        b = _unit("B", scope=["shared/conflict.py"])
        graph = WorkGraph(units=[a, b])
        waves = graph.schedule()
        self.assertEqual(len(waves), 2)
        self.assertEqual(set(waves[0]) | set(waves[1]), {"A", "B"})
        for wave in waves:
            self.assertEqual(len(wave), 1)

    def test_partial_scope_overlap_defers_only_the_conflicting_pair(self):
        # A, B 는 scope 겹침. C 는 어느 쪽과도 안 겹침.
        # plan 순서 A,B,C 로 그리디 배치: A 먼저 claim → B 는 겹쳐서 다음
        # 웨이브로 연기, C 는 A 와 안 겹치므로 같은 웨이브 합류.
        a = _unit("A", scope=["shared/conflict.py"])
        b = _unit("B", scope=["shared/conflict.py"])
        c = _unit("C", scope=["path/C.py"])
        graph = WorkGraph(units=[a, b, c])
        waves = graph.schedule()
        self.assertEqual(waves[0], ("A", "C"))
        self.assertEqual(waves[1], ("B",))

    def test_non_overlapping_scope_units_share_a_wave(self):
        a = _unit("A", scope=["path/A.py", "path/shared_dir/x.py"])
        b = _unit("B", scope=["path/B.py"])
        graph = WorkGraph(units=[a, b])
        self.assertEqual(graph.schedule(), (("A", "B"),))


class ScopePathLexicalCanonicalizationTest(unittest.TestCase):
    """scope conflict 판정은 순수 어휘적 표기 변형(backslash/slash, 선행
    './', 내부 '..' 세그먼트)을 동일 경로로 본다 — codex review HIGH
    finding. 실제 파일이 아니라 두 WorkUnit 이 같은 웨이브에 함께
    배치되는지로 판정한다(겹치면 다른 웨이브로 분리되어야 한다)."""

    def test_leading_dot_slash_vs_bare_path_conflict(self):
        a = _unit("A", scope=["./x"])
        b = _unit("B", scope=["x"])
        graph = WorkGraph(units=[a, b])
        waves = graph.schedule()
        self.assertEqual(len(waves), 2)
        for wave in waves:
            self.assertEqual(len(wave), 1)

    def test_backslash_vs_forward_slash_conflict(self):
        a = _unit("A", scope=["a\\b"])
        b = _unit("B", scope=["a/b"])
        graph = WorkGraph(units=[a, b])
        waves = graph.schedule()
        self.assertEqual(len(waves), 2)
        for wave in waves:
            self.assertEqual(len(wave), 1)

    def test_internal_dotdot_segment_collapse_conflict(self):
        a = _unit("A", scope=["dir/../dir/x"])
        b = _unit("B", scope=["dir/x"])
        graph = WorkGraph(units=[a, b])
        waves = graph.schedule()
        self.assertEqual(len(waves), 2)
        for wave in waves:
            self.assertEqual(len(wave), 1)

    def test_genuinely_different_paths_still_share_a_wave(self):
        # canonicalization 이 과잉적용되어 서로 다른 경로를 같은 것으로
        # 오판하지 않는지 확인하는 음성 대조군.
        a = _unit("A", scope=["dir/x"])
        b = _unit("B", scope=["dir/y"])
        graph = WorkGraph(units=[a, b])
        self.assertEqual(graph.schedule(), (("A", "B"),))


class ToPlannedUnitsTest(unittest.TestCase):
    """WorkGraph.to_planned_units() — Tracker 브릿지 직렬화 계약. sibling
    fix worker(Tracker 소비측 + 통합 테스트)와 합의된 정확한 8-key shape:
    id/objective/scope/dependencies/assigned_agent/status/expected_output/
    mode. 여기서 벗어나면 안 된다 (plan Task 5.1 재검토 요구:
    serialization-8-fields-all-present)."""

    _EXPECTED_KEYS = {
        "id",
        "objective",
        "scope",
        "dependencies",
        "assigned_agent",
        "status",
        "expected_output",
        "mode",
    }

    def test_returns_tuple_of_dicts_with_exact_eight_keys(self):
        a = WorkUnit(
            id="A",
            objective="do A",
            scope=["path/a.py"],
            dependencies=(),
            assigned_agent="feature-builder",
            status="pending",
            expected_output="A done",
            mode=WORK_UNIT_MODE_EDIT_ONLY,
        )
        b = WorkUnit(
            id="B",
            objective="do B",
            scope=["path/b.py"],
            dependencies=("A",),
            expected_output="B done",
        )
        graph = WorkGraph(units=[a, b])
        planned = graph.to_planned_units()
        self.assertIsInstance(planned, tuple)
        self.assertEqual(len(planned), 2)
        for unit_dict in planned:
            self.assertIsInstance(unit_dict, dict)
            self.assertEqual(set(unit_dict.keys()), self._EXPECTED_KEYS)
            # 8-fields-all-present: 매 필드가 키만 있는게 아니라 실제로
            # 채워져 있어야 한다 (assigned_agent 는 None 허용, 나머지는
            # falsy 값이면 안 됨 — WorkUnit 계약 자체가 이미 빈 id/
            # objective 를 거부하므로 여기서는 키 존재만 재확인).
            for field_name in self._EXPECTED_KEYS:
                self.assertIn(field_name, unit_dict)

    def test_preserves_declaration_order_not_wave_order(self):
        # B 는 A 에 의존하므로 스케줄 상 나중 웨이브지만, to_planned_units
        # 는 선언(units 리스트) 순서를 그대로 유지해야 한다.
        b = _unit("B", deps=("A",))
        a = _unit("A")
        graph = WorkGraph(units=[b, a])
        planned = graph.to_planned_units()
        self.assertEqual([u["id"] for u in planned], ["B", "A"])

    def test_scope_and_dependencies_are_json_safe_lists(self):
        a = _unit("A", scope=["x.py", "y.py"])
        b = _unit("B", deps=("A",), scope=["z.py"])
        graph = WorkGraph(units=[a, b])
        for unit_dict in graph.to_planned_units():
            self.assertIsInstance(unit_dict["scope"], list)
            self.assertIsInstance(unit_dict["dependencies"], list)

    def test_round_trip_values_match_source_work_unit(self):
        a = WorkUnit(
            id="A",
            objective="Objective A",
            scope=["x.py", "y.py"],
            dependencies=(),
            assigned_agent="agent-x",
            status="pending",
            expected_output="output A",
            mode=WORK_UNIT_MODE_MUTATING,
        )
        graph = WorkGraph(units=[a])
        planned = graph.to_planned_units()
        self.assertEqual(
            planned[0],
            {
                "id": "A",
                "objective": "Objective A",
                "scope": ["x.py", "y.py"],
                "dependencies": [],
                "assigned_agent": "agent-x",
                "status": "pending",
                "expected_output": "output A",
                "mode": "mutating",
            },
        )

    def test_empty_graph_returns_empty_tuple(self):
        graph = WorkGraph(units=[])
        self.assertEqual(graph.to_planned_units(), ())


class DeterminismTest(unittest.TestCase):
    """동일 입력 WorkGraph → 동일 웨이브 순서 (반복 호출 간 + 재구성 간)."""

    @staticmethod
    def _build_graph():
        a = _unit("A")
        b = _unit("B", deps=("A",))
        c = _unit("C", deps=("A",), scope=["path/C.py"])
        return WorkGraph(units=[a, b, c])

    def test_repeated_calls_on_same_graph_are_identical(self):
        graph = self._build_graph()
        first = graph.schedule()
        for _ in range(5):
            self.assertEqual(graph.schedule(), first)

    def test_independently_constructed_equivalent_graphs_match(self):
        self.assertEqual(
            self._build_graph().schedule(), self._build_graph().schedule()
        )

    def test_scope_conflict_scheduling_is_deterministic_across_calls(self):
        a = _unit("A", scope=["shared/conflict.py"])
        b = _unit("B", scope=["shared/conflict.py"])
        c = _unit("C", scope=["path/C.py"])
        graph = WorkGraph(units=[a, b, c])
        first = graph.schedule()
        for _ in range(5):
            self.assertEqual(graph.schedule(), first)


class CycleDetectionTest(unittest.TestCase):
    """위상정렬 실패(사이클) → WorkGraph 구성 시점 검증 에러 (v1 fail-closed c 계승)."""

    def test_direct_cycle_is_rejected(self):
        a = WorkUnit(
            id="A",
            objective="o",
            scope=["p1"],
            dependencies=("B",),
            expected_output="n/a",
        )
        b = WorkUnit(
            id="B",
            objective="o",
            scope=["p2"],
            dependencies=("A",),
            expected_output="n/a",
        )
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=[a, b])

    def test_longer_cycle_is_rejected(self):
        # A -> B -> C -> A
        a = WorkUnit(
            id="A", objective="o", scope=["p1"], dependencies=("C",),
            expected_output="n/a",
        )
        b = WorkUnit(
            id="B", objective="o", scope=["p2"], dependencies=("A",),
            expected_output="n/a",
        )
        c = WorkUnit(
            id="C", objective="o", scope=["p3"], dependencies=("B",),
            expected_output="n/a",
        )
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=[a, b, c])

    def test_self_dependency_is_rejected(self):
        with self.assertRaises((WorkUnitError, WorkGraphError)):
            a = WorkUnit(
                id="A", objective="o", scope=["p1"], dependencies=("A",),
                expected_output="n/a",
            )
            WorkGraph(units=[a])

    def test_unknown_dependency_reference_is_rejected(self):
        # v1 fail-closed (b) 계승: 존재하지 않는 id 참조.
        a = WorkUnit(
            id="A", objective="o", scope=["p1"], dependencies=("ghost",),
            expected_output="n/a",
        )
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=[a])

    def test_duplicate_ids_are_rejected(self):
        a = WorkUnit(id="A", objective="o1", scope=["p1"], expected_output="n/a")
        a_dup = WorkUnit(id="A", objective="o2", scope=["p2"], expected_output="n/a")
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=[a, a_dup])


class WorkGraphUnitsContainerTypeValidationTest(unittest.TestCase):
    """codex review round 4 MEDIUM finding — `tuple(self.units or ())`
    트릭은 round 3 에서 WorkUnit.scope/dependencies 에서 제거한 것과
    동일한 함정을 WorkGraph.units 에도 남겨뒀다: `False`/`0`/dict 같은
    falsy-지만-not-None 값을 조용히 빈 그래프로 격하시켰다(예외 없이
    입력을 버리고 성공 처리). 계약: units 는 None 또는 non-string
    sequence(list/tuple)만 허용하고, 원소는 반드시 WorkUnit 인스턴스여야
    한다 — 그 외는 전부 WorkGraphError."""

    def test_units_false_is_rejected(self):
        # 재현: WorkGraph(units=False) — 예전엔 `False or ()` → `()` 로
        # 조용히 격하되어 아무 예외도 없이 성공했다.
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=False)

    def test_units_zero_is_rejected(self):
        # 재현: WorkGraph(units=0) — 예전엔 `0 or ()` → `()` 로 조용히
        # 격하되어 아무 예외도 없이 성공했다.
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=0)

    def test_units_empty_dict_is_rejected(self):
        # 재현: WorkGraph(units={}) — 빈 dict 는 falsy 라 예전엔 `{} or
        # ()` → `()` 로 조용히 격하됐다.
        with self.assertRaises(WorkGraphError):
            WorkGraph(units={})

    def test_units_dict_with_content_is_rejected(self):
        # 재현: WorkGraph(units={"a": <WorkUnit>}) — truthy dict 는
        # 예전엔 `tuple({...})` 가 키만 조용히 원소로 오인정해서(문자열
        # "a") 이후 `[u.id for u in units]` 에서 AttributeError 로
        # 통제되지 않은 방식으로 터졌다. 이제는 컨테이너 타입 자체를
        # 거부한다.
        a = _unit("A")
        with self.assertRaises(WorkGraphError):
            WorkGraph(units={"a": a})

    def test_units_set_is_rejected(self):
        a = _unit("A")
        with self.assertRaises(WorkGraphError):
            WorkGraph(units={a})

    def test_units_bare_string_is_still_rejected(self):
        # 회귀 방지 — 기존에도 있던 bare-string 거부가 새 정규화 경로에서
        # 계속 동작해야 한다.
        with self.assertRaises(WorkGraphError):
            WorkGraph(units="not-a-list")

    def test_non_workunit_element_is_rejected(self):
        # 원소가 WorkUnit 인스턴스가 아니면(예: 평범한 dict/문자열) 거부
        # — duck typing 을 믿고 넘어가지 않는다.
        with self.assertRaises(WorkGraphError):
            WorkGraph(units=[{"id": "A", "objective": "o"}])

    def test_units_none_is_still_accepted_as_empty(self):
        # 음성 대조군 — None 은 계약상 유일하게 허용되는 "생략" 표현이다.
        graph = WorkGraph(units=None)
        self.assertEqual(graph.units, ())

    def test_units_default_omitted_still_works(self):
        # 음성 대조군 — 기본값 `()` 은 여전히 정상 동작해야 한다.
        graph = WorkGraph()
        self.assertEqual(graph.units, ())

    def test_valid_workunit_list_still_accepted(self):
        # 음성 대조군 — 정상 WorkUnit 리스트는 여전히 통과해야 한다.
        a = _unit("A")
        b = _unit("B")
        graph = WorkGraph(units=[a, b])
        self.assertEqual(graph.units, (a, b))


class WorkUnitNonEmptyScopeTest(unittest.TestCase):
    """codex review round 5 HIGH finding — v1 계약 이식
    (`docs/exec-strategy-schema.md` §scope, `scripts/rein-validate-
    coverage-matrix.py` fail-closed 조건 (e)): scope 는 반드시 non-empty
    literal file path list 여야 한다. 빈/생략된 scope 는 "아무 것도 안
    건드림" 이 아니라 "write-set 을 선언하지 않음"(unknown write-set) 을
    의미한다 — work_graph.py 의 scheduler 가 이런 유닛을 다른 어떤
    유닛과도 scope 가 안 겹치는 것으로 오판해 병렬 co-schedule 하면
    실제로는 알 수 없는 파일을 건드릴 수 있는 유닛이 안전하다고 낙인
    찍히는 위험한 결과가 된다.

    `dependencies` 는 이 계약 대상이 아니다 — v1 `depends_on` 은 optional
    (기본 `[]`) 이므로 비대칭이 맞다(WorkUnitSequenceContainerTypeValidationTest
    의 dependencies=None 관련 음성 대조군 참조)."""

    def test_empty_tuple_scope_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=(), expected_output="n/a")

    def test_empty_list_scope_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=[], expected_output="n/a")

    def test_omitted_scope_default_is_rejected(self):
        # scope 를 아예 생략(기본값 `()`)해도 마찬가지로 거부된다 —
        # "empty/omitted scope raises WorkUnitError" 원문.
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", expected_output="n/a")

    def test_none_scope_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=None, expected_output="n/a")

    def test_non_empty_scope_still_accepted(self):
        # 음성 대조군.
        unit = WorkUnit(
            id="A", objective="o", scope=["a.py"], expected_output="n/a",
        )
        self.assertEqual(unit.scope, ("a.py",))

    def test_dependencies_may_remain_empty_while_scope_must_not(self):
        # 음성 대조군 — dependencies 는 여전히 optional. scope 만
        # non-empty 계약을 갖는 비대칭을 직접 고정한다.
        unit = WorkUnit(
            id="A", objective="o", scope=["a.py"], dependencies=(),
            expected_output="n/a",
        )
        self.assertEqual(unit.dependencies, ())


class WorkGraphCannotSeeEmptyScopeUnitsTest(unittest.TestCase):
    """codex review round 5 HIGH finding, item 3 — work_graph.py 자체는
    소스 변경이 필요 없다(WorkUnit 이 이제 빈 scope 를 구성 시점에
    거부하므로, WorkGraph/schedule() 는 애초에 빈 scope 를 가진 유닛을
    볼 수조차 없다) — 이 불변식을 방어적으로 직접 고정한다: 두 유닛이
    모두 "검증 통과 + 병렬 co-schedule" 상태에 이르는 동안 한쪽이라도
    write-set(scope) 을 알 수 없는(unknown/empty) 경로는 원천 차단된다."""

    def test_empty_scope_workunit_cannot_be_constructed_for_scheduling(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=(), expected_output="n/a")

    def test_two_units_cannot_both_pass_validation_and_coschedule_with_an_unknown_write_set(
        self,
    ):
        # 빈 scope 로 "다른 무엇과도 안 겹친다" 는 오판을 유도하려는
        # 시도는 WorkUnit 생성 시점에 이미 막혀서 WorkGraph 조립까지
        # 도달하지 못한다 — 두 유닛이 모두 "검증 통과 + 병렬 스케줄"
        # 상태에 이르는 경로가 원천 차단된다.
        with self.assertRaises(WorkUnitError):
            a = WorkUnit(id="A", objective="o", scope=(), expected_output="n/a")
            b = WorkUnit(
                id="B", objective="o", scope=["x.py"], expected_output="n/a",
            )
            WorkGraph(units=[a, b])  # pragma: no cover - never reached

    def test_all_units_in_a_valid_workgraph_have_non_empty_scope(self):
        # 불변식 고정 — 정상적으로 조립된 WorkGraph 의 모든 유닛은 반드시
        # scope 가 비어있지 않다(빈 scope 로는 WorkGraph 에 들어올 수조차
        # 없으므로, schedule() 은 unknown write-set 유닛을 절대 보지
        # 못한다).
        graph = WorkGraph(units=[_unit("A"), _unit("B")])
        for unit in graph.units:
            self.assertGreater(len(unit.scope), 0)


class WorkUnitFieldContractTest(unittest.TestCase):
    """spec §4.3 WorkUnit 필드 계약 — 8필드 존재(2026-08-11 spec 정정: mode
    가 7필드 밖 확장이 아니라 8번째 공식 필드로 승격) + 최소 방어적 타입
    검증."""

    def test_all_eight_spec_fields_are_present(self):
        unit = WorkUnit(
            id="work-01",
            objective="Login API",
            scope=["backend/auth/**"],
            dependencies=(),
            assigned_agent="feature-builder",
            status="pending",
            expected_output="API endpoint implemented",
            mode="edit_only",
        )
        for field_name in (
            "id",
            "objective",
            "scope",
            "dependencies",
            "assigned_agent",
            "status",
            "expected_output",
            "mode",
        ):
            self.assertTrue(hasattr(unit, field_name), field_name)

    def test_blank_id_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="", objective="o", scope=["p"], expected_output="n/a")

    def test_unknown_status_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"], status="running",
                expected_output="n/a",
            )

    def test_unknown_mode_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"], mode="destroy",
                expected_output="n/a",
            )

    def test_scope_as_single_string_is_rejected(self):
        # tuple("abc") 문자 단위 분해 방지 (kernel Decision 계약과 동일 원칙).
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope="backend/auth.py",
                expected_output="n/a",
            )


class WorkUnitElementTypeValidationTest(unittest.TestCase):
    """codex review round 2 MEDIUM finding — scope/dependencies 의 개별
    원소가 비어 있지 않은 문자열이 아니면(dict/list/object() 등) 조용히
    통과했다가 다운스트림(WorkGraph 의 set 멤버십 판정, work_graph.py
    schedule() 의 set comprehension, to_planned_units() 의 json 직렬화)
    에서 예측 불가능한 TypeError(unhashable type)로 터지던 문제.
    WorkUnit 생성 시점(가장 이른 경계)에 fail-closed 로 거부한다.

    재현 4종 고정:
      - WorkUnit(dependencies=[[]]) → 예전엔 WorkGraph 구성 시점
        `dep not in id_set` 에서 TypeError: unhashable type: 'list'.
      - WorkUnit(scope=[{}]) → 예전엔 work_graph.schedule() 의 set
        comprehension 에서 TypeError: unhashable type: 'dict'.
      - WorkUnit(scope=[object()]) → 예전엔 to_planned_units() 의 결과가
        json.dumps 에 실패(object() 는 JSON 직렬화 불가).
    """

    def test_dependencies_element_list_is_rejected(self):
        # 재현: WorkUnit(dependencies=[[]]) — WorkGraph 구성 시점의
        # `dep not in id_set` 에서 unhashable list TypeError 로 터지던 것.
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"], dependencies=[[]],
                expected_output="n/a",
            )

    def test_scope_element_dict_is_rejected(self):
        # 재현: WorkUnit(scope=[{}]) — work_graph.schedule() 의 set
        # comprehension 에서 unhashable dict TypeError 로 터지던 것.
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=[{}], expected_output="n/a")

    def test_scope_element_arbitrary_object_is_rejected(self):
        # 재현: WorkUnit(scope=[object()]) — to_planned_units() 출력이
        # json.dumps 에 실패하던 것.
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=[object()],
                expected_output="n/a",
            )

    def test_dependencies_element_empty_string_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"], dependencies=[""],
                expected_output="n/a",
            )

    def test_scope_element_empty_string_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=[""], expected_output="n/a")

    def test_scope_element_non_string_number_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=[123], expected_output="n/a")

    def test_valid_string_elements_are_still_accepted(self):
        # 음성 대조군 — 정상 문자열 원소는 여전히 통과해야 한다.
        unit = WorkUnit(
            id="A", objective="o", scope=["a.py", "b.py"],
            dependencies=(), expected_output="n/a",
        )
        self.assertEqual(unit.scope, ("a.py", "b.py"))

    def test_bad_scope_element_never_reaches_workgraph_construction(self):
        # 경계에서 막히므로 WorkGraph 자체가 만들어지지 않는다 — 이전엔
        # WorkUnit 생성은 성공하고 WorkGraph 구성 시점에야 터졌다.
        with self.assertRaises(WorkUnitError):
            bad = WorkUnit(
                id="A", objective="o", scope=[{}], expected_output="n/a",
            )
            WorkGraph(units=[bad])  # pragma: no cover - never reached


class WorkUnitSequenceContainerTypeValidationTest(unittest.TestCase):
    """codex review round 3 MEDIUM finding — `tuple(self.scope or ())`
    트릭은 `False`/`0` 같은 falsy-지만-not-None 값을 조용히 빈 tuple 로
    격하시켰다(입력을 무시하고 성공 처리 — silent data loss, 예외조차
    없었다). 계약: scope/dependencies 는 None 또는 non-string
    sequence(list/tuple)만 허용한다 — 그 외 모든 타입(bool/int/dict/set
    등)은 명시적으로 WorkUnitError 를 던진다."""

    def test_scope_false_is_rejected(self):
        # 재현: WorkUnit(scope=False) — 예전엔 `False or ()` → `()` 로
        # 조용히 격하되어 아무 예외도 없이 성공했다.
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=False, expected_output="n/a")

    def test_dependencies_zero_is_rejected(self):
        # 재현: WorkUnit(dependencies=0) — 예전엔 `0 or ()` → `()` 로
        # 조용히 격하되어 아무 예외도 없이 성공했다.
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"], dependencies=0,
                expected_output="n/a",
            )

    def test_scope_zero_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=0, expected_output="n/a")

    def test_dependencies_false_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"], dependencies=False,
                expected_output="n/a",
            )

    def test_scope_dict_is_rejected(self):
        # 부차 발견(같은 계약 위반) — dict 는 list/tuple 이 아니다. 예전엔
        # 빈 dict 는 falsy 라 조용히 `()` 로, 내용 있는 dict 는
        # `tuple({...})` 가 키만 scope 원소로 오인정했다.
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope={}, expected_output="n/a")

    def test_dependencies_dict_with_content_is_rejected(self):
        with self.assertRaises(WorkUnitError):
            WorkUnit(
                id="A", objective="o", scope=["p"],
                dependencies={"a": 1}, expected_output="n/a",
            )

    def test_scope_none_is_now_rejected_as_empty(self):
        # round 5 HIGH finding 갱신 — scope=None 은 `_normalize_optional_
        # sequence` 에서 빈 tuple 로 정규화된 뒤, 이제는 scope 의
        # non-empty 계약(WorkUnitNonEmptyScopeTest 참조)에 걸려
        # WorkUnitError 가 된다. dependencies=None 은 여전히 허용된다
        # (아래 test_dependencies_none_is_still_accepted_as_empty — scope
        # 만 non-empty 계약을 갖는 비대칭, v1 depends_on: optional 과
        # 일치).
        with self.assertRaises(WorkUnitError):
            WorkUnit(id="A", objective="o", scope=None, expected_output="n/a")

    def test_dependencies_none_is_still_accepted_as_empty(self):
        unit = WorkUnit(
            id="A", objective="o", scope=["p"], dependencies=None,
            expected_output="n/a",
        )
        self.assertEqual(unit.dependencies, ())

    def test_default_omitted_dependencies_still_works(self):
        # 음성 대조군 — dependencies 의 기본값 `()` 은 여전히 정상
        # 동작한다(optional). scope 의 기본값 `()` 은 round 5 HIGH
        # finding 으로 더 이상 유효하지 않다 — scope 는 항상 명시적으로
        # non-empty 값을 채워야 한다(아래
        # WorkUnitNonEmptyScopeTest.test_omitted_scope_default_is_rejected
        # 참조).
        unit = WorkUnit(id="A", objective="o", scope=["p"], expected_output="n/a")
        self.assertEqual(unit.dependencies, ())


if __name__ == "__main__":
    unittest.main()
