"""plan Task 5.2 — Orchestration validator 계승 테스트 (spec §5.3, §4.3).

v1 자산(`plugins/rein-core/skills/parallel-execute/SKILL.md` §부모 통합·
§워커 dispatch 계약, `scripts/rein-validate-coverage-matrix.py` 의
`_validate_exec_strategy_tasks`/`_reachable_pairs`)의 검증 판정을 이식해
v2 `orchestration/validator.py` 가 동등하게 판정하는지 고정한다.

fixture 는 전부 inline dict/문자열 + `tempfile` 로 실 파일시스템 경로에
태운다 — 저장소 트리에 fixture 파일을 남기지 않는다 (워커 scope 계약).

고정 대상 4묶음 (plan Task 5.2 Steps 1 원문 그대로):
1. scope 경로 안전화 — 절대경로/`..`/`..\\`/NUL/드라이브문자 reject,
   realpath containment (workspace_root 명시 파라미터, 전역 cwd 비의존).
2. dependency validation (v1 조건 b·c) + scope conflict validation
   (v1 조건 g).
3. 델타 ⊆ scope 부분집합 판정 — scope 밖 델타 → 위반.
4. 워커 결과 스키마 파싱 — 결과 누락(None)은 성공으로 격상되지 않고
   "missing" 으로 명시 구분되며, blocked 과 함께 "미완"으로 취급된다.
"""
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.orchestration import validator  # noqa: E402


# ---------------------------------------------------------------------------
# 1. scope 경로 안전화 (보안 필수 승계 — v1 barrier step 4)
# ---------------------------------------------------------------------------


class PathSafetyTest(unittest.TestCase):
    """`normalize_scope_path` — 거부 5종 + containment + 정상 통과."""

    def setUp(self):
        self._workdir = tempfile.TemporaryDirectory()
        self.workspace_root = self._workdir.name

    def tearDown(self):
        self._workdir.cleanup()

    def test_absolute_posix_path_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("/etc/passwd", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_ABSOLUTE)

    def test_absolute_windows_style_path_rejected(self):
        # 백슬래시 절대경로(`\x`)도 슬래시 정규화 후 선두 '/' 로 걸린다
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("\\etc\\passwd", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_ABSOLUTE)

    def test_parent_traversal_posix_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("../../etc/passwd", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_TRAVERSAL)

    def test_parent_traversal_embedded_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("src/../../etc/passwd", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_TRAVERSAL)

    def test_parent_traversal_windows_style_rejected(self):
        # v1 SKILL.md 원문: "..\\" 도 명시 거부 대상
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("..\\secrets\\token", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_TRAVERSAL)

    def test_nul_byte_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("src/app.py\x00.png", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_NUL_BYTE)

    def test_windows_drive_letter_backslash_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("C:\\Windows\\system32", self.workspace_root)
        self.assertEqual(
            caught.exception.reason, validator.PATH_REJECT_DRIVE_LETTER
        )

    def test_windows_drive_letter_relative_rejected(self):
        # 드라이브 상대 표기(`C:foo`, 백슬래시 없음)도 거부 대상
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("C:foo", self.workspace_root)
        self.assertEqual(
            caught.exception.reason, validator.PATH_REJECT_DRIVE_LETTER
        )

    def test_empty_path_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path("", self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_EMPTY)

    def test_non_string_path_rejected(self):
        with self.assertRaises(validator.PathSafetyViolation) as caught:
            validator.normalize_scope_path(None, self.workspace_root)
        self.assertEqual(caught.exception.reason, validator.PATH_REJECT_EMPTY)

    def test_valid_relative_path_normalizes(self):
        result = validator.normalize_scope_path(
            "src/app.py", self.workspace_root
        )
        self.assertEqual(result, "src/app.py")

    def test_valid_nested_relative_path_normalizes(self):
        result = validator.normalize_scope_path(
            "./plugins/rein-core/rein/orchestration/validator.py",
            self.workspace_root,
        )
        self.assertEqual(
            result, "plugins/rein-core/rein/orchestration/validator.py"
        )

    def test_realpath_containment_symlink_escape_rejected(self):
        # workspace 내부 심볼릭 링크가 workspace 밖 실 경로를 가리키면
        # realpath 해석 후 containment 실패로 거부되어야 한다 (symlink
        # resolve 를 우회하는 경로 탈출 차단).
        with tempfile.TemporaryDirectory() as outside_dir:
            outside_target = os.path.join(outside_dir, "secret.txt")
            with open(outside_target, "w", encoding="utf-8") as handle:
                handle.write("secret")
            link_path = os.path.join(self.workspace_root, "escape_link")
            os.symlink(outside_dir, link_path)
            with self.assertRaises(validator.PathSafetyViolation) as caught:
                validator.normalize_scope_path(
                    "escape_link/secret.txt", self.workspace_root
                )
            self.assertEqual(
                caught.exception.reason,
                validator.PATH_REJECT_OUTSIDE_WORKSPACE,
            )

    def test_realpath_containment_symlink_inside_workspace_allowed(self):
        # symlink 라도 최종 실 경로가 workspace 내부면 정상 통과한다
        # (containment 는 "실제 위치" 기준이지 "symlink 여부" 기준이 아님).
        target_dir = os.path.join(self.workspace_root, "real_target")
        os.mkdir(target_dir)
        with open(
            os.path.join(target_dir, "file.txt"), "w", encoding="utf-8"
        ) as handle:
            handle.write("ok")
        link_path = os.path.join(self.workspace_root, "inside_link")
        os.symlink(target_dir, link_path)
        result = validator.normalize_scope_path(
            "inside_link/file.txt", self.workspace_root
        )
        self.assertEqual(result, "real_target/file.txt")

    def test_workspace_root_is_explicit_not_global_cwd(self):
        # workspace_root 는 호출자가 명시 전달해야 하며, 프로세스 cwd 를
        # 암묵적으로 참조하지 않는다 — cwd 를 workspace 와 무관한 곳으로
        # 옮긴 뒤에도 명시 workspace_root 기준으로 동일하게 정규화되어야
        # 한다.
        original_cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as unrelated_cwd:
            os.chdir(unrelated_cwd)
            try:
                result = validator.normalize_scope_path(
                    "src/app.py", self.workspace_root
                )
            finally:
                os.chdir(original_cwd)
        self.assertEqual(result, "src/app.py")

    def test_workspace_root_required(self):
        with self.assertRaises(TypeError):
            validator.normalize_scope_path("src/app.py", "")


# ---------------------------------------------------------------------------
# 2. Dependency validation (v1 조건 b·c 계승)
# ---------------------------------------------------------------------------


class DependencyValidationTest(unittest.TestCase):
    def test_valid_dependency_graph_has_no_violations(self):
        units = [
            {"id": "a", "dependencies": []},
            {"id": "b", "dependencies": ["a"]},
            {"id": "c", "dependencies": ["a", "b"]},
        ]
        self.assertEqual(validator.validate_dependencies(units), ())

    def test_unknown_dependency_reference_is_violation(self):
        # v1 조건 (b): depends_on 이 존재하지 않는 id 를 참조
        units = [{"id": "a", "dependencies": ["ghost"]}]
        violations = validator.validate_dependencies(units)
        self.assertEqual(len(violations), 1)
        self.assertEqual(
            violations[0].reason, validator.REASON_UNKNOWN_DEPENDENCY
        )
        self.assertEqual(violations[0].unit_id, "a")

    def test_two_node_cycle_is_violation(self):
        # v1 조건 (c): 사이클 — Kahn 위상정렬이 모든 노드를 소진 못 함
        units = [
            {"id": "a", "dependencies": ["b"]},
            {"id": "b", "dependencies": ["a"]},
        ]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_CYCLE, reasons)

    def test_self_dependency_is_cycle(self):
        units = [{"id": "a", "dependencies": ["a"]}]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_CYCLE, reasons)

    def test_three_node_cycle_is_violation(self):
        units = [
            {"id": "a", "dependencies": ["c"]},
            {"id": "b", "dependencies": ["a"]},
            {"id": "c", "dependencies": ["b"]},
        ]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_CYCLE, reasons)

    def test_missing_id_is_violation(self):
        units = [{"dependencies": []}]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_MISSING_ID, reasons)

    def test_duplicate_id_is_violation(self):
        units = [
            {"id": "a", "dependencies": []},
            {"id": "a", "dependencies": []},
        ]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_DUPLICATE_ID, reasons)

    def test_empty_units_has_no_violations(self):
        self.assertEqual(validator.validate_dependencies([]), ())

    def test_diamond_dependency_graph_has_no_violations(self):
        # a -> b, a -> c, b -> d, c -> d (다이아몬드, 사이클 아님)
        units = [
            {"id": "d", "dependencies": []},
            {"id": "b", "dependencies": ["d"]},
            {"id": "c", "dependencies": ["d"]},
            {"id": "a", "dependencies": ["b", "c"]},
        ]
        self.assertEqual(validator.validate_dependencies(units), ())


class DependencyElementTypeValidationTest(unittest.TestCase):
    """codex review round 2 MEDIUM finding — dependencies 리스트 자체가
    bare string 인 경우는 이미 REASON_INVALID_DEPENDENCIES_SHAPE 로
    커버됐지만, **개별 원소**가 비어있지 않은 문자열이 아닌 경우(dict/list
    등)는 조용히 통과해 `dep not in id_set`(set 멤버십 판정)에서 예측
    불가능한 TypeError(unhashable type)로 터졌다. shape violation 으로
    접어(fold) fail-closed 처리한다."""

    def test_list_element_in_dependencies_is_a_shape_violation(self):
        # 재현: {"id": "a", "dependencies": [[]]} — 예전엔 나중에
        # `dep not in id_set` 에서 TypeError: unhashable type: 'list'.
        units = [{"id": "a", "dependencies": [[]]}]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_INVALID_DEPENDENCIES_SHAPE, reasons)

    def test_empty_string_element_in_dependencies_is_a_shape_violation(self):
        units = [{"id": "a", "dependencies": [""]}]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_INVALID_DEPENDENCIES_SHAPE, reasons)

    def test_malformed_dependency_element_does_not_crash_cycle_check(self):
        # validate_dependencies 자체가 예외 없이 반환해야 한다(fold, not
        # raise) — 나머지 그래프 판정도 계속 진행된다.
        units = [
            {"id": "a", "dependencies": [[]]},
            {"id": "b", "dependencies": ["a"]},
        ]
        violations = validator.validate_dependencies(units)
        reasons = [v.reason for v in violations]
        self.assertIn(validator.REASON_INVALID_DEPENDENCIES_SHAPE, reasons)
        self.assertNotIn(validator.REASON_CYCLE, reasons)
        self.assertNotIn(validator.REASON_UNKNOWN_DEPENDENCY, reasons)


# ---------------------------------------------------------------------------
# 2b. Scope conflict validation (v1 조건 g 계승)
# ---------------------------------------------------------------------------


class ScopeConflictValidationTest(unittest.TestCase):
    def test_independent_units_with_overlapping_scope_conflict(self):
        # v1 조건 (g): 서로 depends_on 경로 없는(동시 실행 가능) 두 unit
        # 이 scope 를 공유하면 위반
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/app.py"]},
            {"id": "b", "dependencies": [], "scope": ["src/app.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0].reason, validator.REASON_SCOPE_OVERLAP)
        self.assertEqual(conflicts[0].overlap, ("src/app.py",))

    def test_dependency_ordered_units_may_share_scope(self):
        # v1 조건 (g'): depends_on 으로 순서 강제된 쌍은 겹쳐도 OK
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/app.py"]},
            {"id": "b", "dependencies": ["a"], "scope": ["src/app.py"]},
        ]
        self.assertEqual(validator.validate_scope_conflicts(units), ())

    def test_transitively_ordered_units_may_share_scope(self):
        # round 5 HIGH finding 갱신 — scope 는 이제 non-empty 계약을
        # 갖는다(REASON_EMPTY_SCOPE). 예전엔 중간 유닛 "b" 의 scope 를
        # 빈 리스트로 둬 "자기 scope 없는 pass-through 태스크" 를
        # 표현했지만, 이제는 모든 유닛이 non-empty literal scope 를
        # 가져야 하므로 "b" 에도 겹치지 않는 자기 scope 를 채운다 — 테스트
        # 의도(전이적으로 순서 강제된 a/c 는 겹쳐도 무방, g')는 그대로
        # 보존된다.
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/app.py"]},
            {"id": "b", "dependencies": ["a"], "scope": ["src/b.py"]},
            {"id": "c", "dependencies": ["b"], "scope": ["src/app.py"]},
        ]
        self.assertEqual(validator.validate_scope_conflicts(units), ())

    def test_disjoint_scope_independent_units_no_conflict(self):
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/a.py"]},
            {"id": "b", "dependencies": [], "scope": ["src/b.py"]},
        ]
        self.assertEqual(validator.validate_scope_conflicts(units), ())

    def test_mutating_units_exempt_from_concurrent_overlap_check(self):
        # mutating unit 은 work_graph.py(Task 5.1) 스케줄러가 항상 단독
        # 웨이브로 격리하므로 정적 scope 겹침 검사에서 제외한다.
        units = [
            {
                "id": "a",
                "dependencies": [],
                "scope": ["src/app.py"],
                "mode": "mutating",
            },
            {"id": "b", "dependencies": [], "scope": ["src/app.py"]},
        ]
        self.assertEqual(validator.validate_scope_conflicts(units), ())

    def test_default_mode_is_edit_only_when_unspecified(self):
        # mode 는 WorkUnit 계약(spec §4.3)의 8번째 공식 필드 — 부재 시
        # 보수적으로 edit_only 취급(겹침 검사 대상에 포함).
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/app.py"]},
            {"id": "b", "dependencies": [], "scope": ["src/app.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        self.assertEqual(len(conflicts), 1)


# ---------------------------------------------------------------------------
# 2c. Scope path 순수 어휘적 canonicalization (codex review HIGH finding)
# ---------------------------------------------------------------------------


class CanonicalizeScopePathLexicalTest(unittest.TestCase):
    """`canonicalize_scope_path_lexical` — 파일시스템 접근 없는 순수
    문자열 정규화. `normalize_scope_path`(실 파일시스템 realpath 기반,
    보안용)와는 별개 — 여기는 conflict 판정을 위한 표기 동등성만 다룬다.
    """

    def test_leading_dot_slash_stripped(self):
        self.assertEqual(
            validator.canonicalize_scope_path_lexical("./x"), "x"
        )

    def test_backslash_normalized_to_forward_slash(self):
        self.assertEqual(
            validator.canonicalize_scope_path_lexical("a\\b"), "a/b"
        )

    def test_internal_dotdot_segment_collapsed(self):
        self.assertEqual(
            validator.canonicalize_scope_path_lexical("dir/../dir/x"),
            "dir/x",
        )

    def test_already_canonical_path_is_unchanged(self):
        self.assertEqual(
            validator.canonicalize_scope_path_lexical("a/b/c.py"),
            "a/b/c.py",
        )

    def test_non_string_input_passes_through_unchanged(self):
        # 구조 검증(shape)은 이 함수의 책임이 아니다 — 호출자(예:
        # validate_scope_conflicts)가 이미 scope shape 을 별도로 검증한다.
        self.assertIsNone(validator.canonicalize_scope_path_lexical(None))


class ScopeConflictLexicalCanonicalizationTest(unittest.TestCase):
    """validate_scope_conflicts 의 overlap 판정도 work_graph.py 스케줄러와
    동일한 어휘적 canonicalization 을 거친다 — 두 곳이 서로 다른 정규형을
    쓰면 스케줄러는 겹침으로 보고 validator 는 안 겹침으로 보는(또는
    반대) drift 가 생긴다."""

    def test_leading_dot_slash_vs_bare_path_conflicts(self):
        units = [
            {"id": "a", "dependencies": [], "scope": ["./x"]},
            {"id": "b", "dependencies": [], "scope": ["x"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_OVERLAP, reasons)

    def test_backslash_vs_forward_slash_conflicts(self):
        units = [
            {"id": "a", "dependencies": [], "scope": ["a\\b"]},
            {"id": "b", "dependencies": [], "scope": ["a/b"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_OVERLAP, reasons)

    def test_internal_dotdot_segment_collapses_and_conflicts(self):
        units = [
            {"id": "a", "dependencies": [], "scope": ["dir/../dir/x"]},
            {"id": "b", "dependencies": [], "scope": ["dir/x"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_OVERLAP, reasons)

    def test_genuinely_different_paths_do_not_conflict(self):
        units = [
            {"id": "a", "dependencies": [], "scope": ["dir/x"]},
            {"id": "b", "dependencies": [], "scope": ["dir/y"]},
        ]
        self.assertEqual(validator.validate_scope_conflicts(units), ())


# ---------------------------------------------------------------------------
# 2d. mode fail-closed validation (codex review MEDIUM finding)
# ---------------------------------------------------------------------------


class ScopeConflictModeValidationTest(unittest.TestCase):
    """`mode` 는 WorkUnit 의 8번째 공식 계약 필드(spec §4.3, 2026-08-11
    정정판)다 — 값이 있을 때는 WorkUnit 과 동일하게 {"edit_only",
    "mutating"} 만 허용해야 한다. typo("mutatng" 등)를 조용히 edit_only
    로 격하시키지 않는다(fail-closed, WorkUnitError 와 동형)."""

    def test_unknown_mode_value_is_a_violation(self):
        units = [
            {
                "id": "a",
                "dependencies": [],
                "scope": ["src/a.py"],
                "mode": "mutatng",
            },
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_INVALID_MODE, reasons)

    def test_unknown_mode_is_flagged_and_still_checked_for_overlap(self):
        # typo 된 mode 는 (1) 그 자체로 위반 보고 + (2) 조용히 mutating
        # 취급으로 격상돼 검사에서 면제되지도 않는다 — edit_only 취급으로
        # 겹침 검사 대상에 남는다(더 보수적인 방향).
        units = [
            {
                "id": "a",
                "dependencies": [],
                "scope": ["src/a.py"],
                "mode": "mutatng",
            },
            {"id": "b", "dependencies": [], "scope": ["src/a.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_INVALID_MODE, reasons)
        self.assertIn(validator.REASON_SCOPE_OVERLAP, reasons)

    def test_edit_only_mode_is_allowed(self):
        units = [
            {
                "id": "a",
                "dependencies": [],
                "scope": ["src/a.py"],
                "mode": "edit_only",
            },
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertNotIn(validator.REASON_INVALID_MODE, reasons)

    def test_mutating_mode_is_allowed(self):
        units = [
            {
                "id": "a",
                "dependencies": [],
                "scope": ["src/a.py"],
                "mode": "mutating",
            },
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertNotIn(validator.REASON_INVALID_MODE, reasons)

    def test_missing_mode_key_is_not_a_violation(self):
        # 키 부재는 위반이 아니다 — 값이 "있는데 잘못됐을 때"만 위반
        # (finding 원문: "when the key is present").
        units = [{"id": "a", "dependencies": [], "scope": ["src/a.py"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertNotIn(validator.REASON_INVALID_MODE, reasons)


# ---------------------------------------------------------------------------
# 2e. Scope 원소 타입 검증 (codex review round 2 MEDIUM finding)
# ---------------------------------------------------------------------------


class ScopeElementTypeValidationTest(unittest.TestCase):
    """scope 리스트 자체가 bare string 인 경우는 이미
    REASON_INVALID_SCOPE_SHAPE 로 커버됐지만, **개별 원소**가 비어있지
    않은 문자열이 아닌 경우(dict 등)는 조용히 통과해
    `canonicalize_scope_path_lexical` 을 거친 뒤 set comprehension 에서
    예측 불가능한 TypeError(unhashable type)로 터졌다. shape violation
    으로 접어(fold) fail-closed 처리한다."""

    def test_dict_element_in_scope_is_a_shape_violation(self):
        # 재현: {"id": "a", "scope": [{}]} — 예전엔 scope_by_id 를 만드는
        # set comprehension 에서 TypeError: unhashable type: 'dict'.
        units = [{"id": "a", "dependencies": [], "scope": [{}]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_INVALID_SCOPE_SHAPE, reasons)

    def test_empty_string_element_in_scope_is_a_shape_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": [""]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_INVALID_SCOPE_SHAPE, reasons)

    def test_malformed_scope_element_does_not_crash_overlap_check(self):
        # validate_scope_conflicts 자체가 예외 없이 반환해야 한다(fold,
        # not raise) — 나머지 유닛의 겹침 판정도 계속 진행된다.
        units = [
            {"id": "a", "dependencies": [], "scope": [{}]},
            {"id": "b", "dependencies": [], "scope": ["src/a.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_INVALID_SCOPE_SHAPE, reasons)
        self.assertNotIn(validator.REASON_SCOPE_OVERLAP, reasons)


# ---------------------------------------------------------------------------
# 2f. v1 scope 계약 이식 — non-empty + glob/디렉토리 거부 (codex review
#     round 5 HIGH finding)
# ---------------------------------------------------------------------------


class ScopeV1FormValidationTest(unittest.TestCase):
    """v1 계약 이식(`docs/exec-strategy-schema.md` §scope,
    `scripts/rein-validate-coverage-matrix.py` fail-closed 조건 (e)/(f),
    `GLOB_META_RE = re.compile(r"[\\*\\?\\[\\]]")` 그대로 이식): scope 는
    non-empty 여야 하고, 원소는 glob 메타문자나 디렉토리 형태(trailing
    '/')를 가질 수 없다 — literal file path 만 허용한다."""

    def test_empty_scope_list_is_a_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": []}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_EMPTY_SCOPE, reasons)

    def test_glob_star_in_scope_entry_is_a_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": ["src/*.py"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_GLOB_PATTERN, reasons)

    def test_glob_question_mark_in_scope_entry_is_a_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": ["src/a?.py"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_GLOB_PATTERN, reasons)

    def test_glob_bracket_in_scope_entry_is_a_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": ["src/[ab].py"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_GLOB_PATTERN, reasons)

    def test_directory_trailing_slash_scope_entry_is_a_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": ["src/"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_DIRECTORY_FORM, reasons)

    def test_literal_path_scope_entry_is_not_a_violation(self):
        # 음성 대조군.
        units = [{"id": "a", "dependencies": [], "scope": ["src/app.py"]}]
        self.assertEqual(validator.validate_scope_conflicts(units), ())

    def test_bad_form_entry_does_not_crash_overlap_check(self):
        # fold, not raise — 나머지 유닛의 겹침 판정도 계속 진행된다.
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/*.py"]},
            {"id": "b", "dependencies": [], "scope": ["src/app.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_GLOB_PATTERN, reasons)
        self.assertNotIn(validator.REASON_SCOPE_OVERLAP, reasons)

    def test_bad_form_entry_excludes_scope_from_overlap_detection(self):
        # 형태 위반이 있으면 해당 유닛의 scope 전체를 겹침 판정에서
        # 신뢰하지 않는다(round 2/3 의 REASON_INVALID_SCOPE_SHAPE 와
        # 동일한 "위반 시 전체 무효화" 정책).
        units = [
            {"id": "a", "dependencies": [], "scope": ["src/app.py", "src/*.py"]},
            {"id": "b", "dependencies": [], "scope": ["src/app.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_GLOB_PATTERN, reasons)
        self.assertNotIn(validator.REASON_SCOPE_OVERLAP, reasons)

    def test_non_path_token_scope_entry_is_a_violation(self):
        # round 6 요청 — v1 조건 f 의 세 번째 sub-check 이식: 순수 숫자
        # 문자열은 alpha 문자도 '/' 도 없어 non-path token 이다
        # (rein-validate-coverage-matrix.py: `not re.search(r"[A-Za-z/]",
        # item)`, v1 예시 그대로 "123").
        units = [{"id": "a", "dependencies": [], "scope": ["123"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_NON_PATH_TOKEN, reasons)

    def test_symbols_only_scope_entry_is_a_non_path_token_violation(self):
        units = [{"id": "a", "dependencies": [], "scope": ["___"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_NON_PATH_TOKEN, reasons)

    def test_non_path_token_check_runs_before_glob_and_directory_checks(self):
        # v1 원본 순서 이식 고정 — 원소당 첫 매치(non-path-token → glob →
        # directory)만 보고된다("123" 은 애초에 glob 메타문자도 trailing
        # '/' 도 없으므로 자명하지만, reason 이 정확히 하나만, 그리고
        # non-path-token 으로 보고됨을 명시적으로 고정해둔다).
        units = [{"id": "a", "dependencies": [], "scope": ["123"]}]
        conflicts = validator.validate_scope_conflicts(units)
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0].reason, validator.REASON_SCOPE_NON_PATH_TOKEN)

    def test_slash_only_entry_is_a_directory_violation_not_non_path_token(self):
        # "/" 자체는 '/' 문자를 포함하므로 non-path-token 체크(alpha-or-
        # slash 존재 여부만 봄)는 통과하고, directory 체크(trailing '/')
        # 에서 걸린다 — v1 의 first-match-wins 순서를 그대로 고정.
        units = [{"id": "a", "dependencies": [], "scope": ["/"]}]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_DIRECTORY_FORM, reasons)
        self.assertNotIn(validator.REASON_SCOPE_NON_PATH_TOKEN, reasons)

    def test_literal_alpha_path_is_not_a_non_path_token_violation(self):
        # 음성 대조군.
        units = [{"id": "a", "dependencies": [], "scope": ["src/app.py"]}]
        self.assertEqual(validator.validate_scope_conflicts(units), ())

    def test_non_path_token_entry_does_not_crash_overlap_check(self):
        units = [
            {"id": "a", "dependencies": [], "scope": ["123"]},
            {"id": "b", "dependencies": [], "scope": ["src/app.py"]},
        ]
        conflicts = validator.validate_scope_conflicts(units)
        reasons = [c.reason for c in conflicts]
        self.assertIn(validator.REASON_SCOPE_NON_PATH_TOKEN, reasons)
        self.assertNotIn(validator.REASON_SCOPE_OVERLAP, reasons)


# ---------------------------------------------------------------------------
# 3. 델타 ⊆ scope 부분집합 판정
# ---------------------------------------------------------------------------


class DeltaSubsetValidationTest(unittest.TestCase):
    def setUp(self):
        self._workdir = tempfile.TemporaryDirectory()
        self.workspace_root = self._workdir.name

    def tearDown(self):
        self._workdir.cleanup()

    def test_delta_within_scope_has_no_violations(self):
        result = validator.validate_delta_subset(
            delta_paths=["src/app.py"],
            scope_paths=["src/app.py", "src/other.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ())

    def test_delta_outside_scope_is_violation(self):
        # 델타 ⊆ scope 위반 — scope 밖 파일이 실제로 바뀜
        result = validator.validate_delta_subset(
            delta_paths=["src/app.py", "secrets/token.txt"],
            scope_paths=["src/app.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ("secrets/token.txt",))

    def test_empty_delta_has_no_violations(self):
        result = validator.validate_delta_subset(
            delta_paths=[],
            scope_paths=["src/app.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ())

    def test_unsafe_delta_path_is_violation_even_if_scope_declares_it(self):
        # scope 에 아무리 관대한 선언이 있어도, 델타 경로 자체가 안전화에
        # 실패하면(예: traversal) 무조건 위반 — 어떤 scope 로도 정당화
        # 불가.
        result = validator.validate_delta_subset(
            delta_paths=["../outside.py"],
            scope_paths=["../outside.py"],
            workspace_root=self.workspace_root,
        )
        self.assertIn("../outside.py", result.violations)

    def test_unsafe_scope_declaration_is_excluded_from_union(self):
        # v1 원문: "정규화 실패 경로는 합집합에서 제외" — scope 쪽의 위험한
        # 선언은 조용히 빠지고, 그 경로가 델타에도 나타나면 결국 위반으로
        # 잡힌다(정규화 실패 경로가 scope 로 인정되지 않으므로).
        result = validator.validate_delta_subset(
            delta_paths=["src/app.py"],
            scope_paths=["../escape.py", "src/app.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ())
        self.assertNotIn("../escape.py", result.safe_scope)

    def test_scope_and_delta_compared_in_same_normal_form(self):
        # './' 접두어가 있는 scope 선언과 접두어 없는 델타 경로가 같은
        # 정규형으로 비교되어 일치해야 한다 (v1: "동일 정규형으로 비교").
        result = validator.validate_delta_subset(
            delta_paths=["src/app.py"],
            scope_paths=["./src/app.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ())


class DeltaSubsetBareStringRejectionTest(unittest.TestCase):
    """codex review round 2 MEDIUM finding — `delta_paths`/`scope_paths`
    자체가 bare string 이면(리스트가 아니라) Python 이 문자 단위로
    조용히 분해해 반복한다("src/a.py" 가 8개의 1글자 "경로" 로 오판정
    됨) — 각 글자가 그 자체로 유효한 단일문자 경로 문자열이라
    `normalize_scope_path` 도 이를 잡지 못한다. 컨테이너 수준에서 즉시
    거부한다(이 모듈의 `normalize_scope_path` 가 이미 `workspace_root`
    타입 오류에 대해 `TypeError` 를 던지는 것과 동일한 확립된 방식)."""

    def setUp(self):
        self._workdir = tempfile.TemporaryDirectory()
        self.workspace_root = self._workdir.name

    def tearDown(self):
        self._workdir.cleanup()

    def test_bare_string_delta_paths_is_rejected(self):
        with self.assertRaises(TypeError):
            validator.validate_delta_subset(
                delta_paths="src/a.py",
                scope_paths=["src/a.py"],
                workspace_root=self.workspace_root,
            )

    def test_bare_string_scope_paths_is_rejected(self):
        with self.assertRaises(TypeError):
            validator.validate_delta_subset(
                delta_paths=["src/a.py"],
                scope_paths="src/a.py",
                workspace_root=self.workspace_root,
            )

    def test_bytes_delta_paths_is_rejected(self):
        with self.assertRaises(TypeError):
            validator.validate_delta_subset(
                delta_paths=b"src/a.py",
                scope_paths=["src/a.py"],
                workspace_root=self.workspace_root,
            )

    def test_normal_list_inputs_are_unaffected(self):
        # 음성 대조군 — 정상 list 입력은 여전히 통과해야 한다.
        result = validator.validate_delta_subset(
            delta_paths=["src/a.py"],
            scope_paths=["src/a.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ())


class DeltaElementTypeValidationTest(unittest.TestCase):
    """codex review round 3 MEDIUM finding — delta_paths 의 개별 원소가
    비어 있지 않은 문자열이 아니면(dict/list 등), 예전엔
    `normalize_scope_path` 가 `PathSafetyViolation` 을 던져 잡히지만
    원본 unhashable 값이 그대로 `violations` 리스트에 append 되고, 함수
    끝의 `tuple(sorted(set(violations)))` 에서 TypeError(unhashable
    type)로 터졌다. set() 구성 이전에 미리 걸러 안전하게(항상 hashable
    str) violations 로 접는다(fold, not raise — 이 함수의 content
    violation 처리 방식과 동일; 컨테이너 자체가 bare string 인 경우의
    TypeError 는 그대로 유지된다)."""

    def setUp(self):
        self._workdir = tempfile.TemporaryDirectory()
        self.workspace_root = self._workdir.name

    def tearDown(self):
        self._workdir.cleanup()

    def test_dict_element_in_delta_paths_does_not_crash(self):
        # 재현: delta_paths=[{}] — 예전엔 set(violations) 에서
        # TypeError: unhashable type: 'dict'.
        result = validator.validate_delta_subset(
            delta_paths=[{}],
            scope_paths=["src/a.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(len(result.violations), 1)

    def test_list_element_in_delta_paths_does_not_crash(self):
        result = validator.validate_delta_subset(
            delta_paths=[[]],
            scope_paths=["src/a.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(len(result.violations), 1)

    def test_mixed_valid_and_invalid_delta_elements(self):
        # 정상 경로는 그대로 처리되고, 잘못된 원소만 violation 으로 접힌다.
        result = validator.validate_delta_subset(
            delta_paths=["src/a.py", {}],
            scope_paths=["src/a.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(len(result.violations), 1)

    def test_bare_string_collection_typeerror_still_raised(self):
        # 회귀 방지 — 컨테이너 자체가 bare string 인 caller-contract
        # 위반은 여전히 TypeError (round 2 fix, fold 대상이 아님).
        with self.assertRaises(TypeError):
            validator.validate_delta_subset(
                delta_paths="src/a.py",
                scope_paths=["src/a.py"],
                workspace_root=self.workspace_root,
            )

    def test_normal_string_delta_paths_are_unaffected(self):
        # 음성 대조군.
        result = validator.validate_delta_subset(
            delta_paths=["src/a.py"],
            scope_paths=["src/a.py"],
            workspace_root=self.workspace_root,
        )
        self.assertEqual(result.violations, ())


# ---------------------------------------------------------------------------
# 4. 워커 결과 스키마 파싱 (v1 §워커 dispatch 계약)
# ---------------------------------------------------------------------------


class WorkerResultParsingTest(unittest.TestCase):
    def test_completed_result_parses(self):
        result = validator.parse_worker_result(
            {
                "task_id": "t1",
                "status": "completed",
                "changed_files": ["src/app.py"],
                "summary": "Implemented the thing.",
            }
        )
        self.assertEqual(result.task_id, "t1")
        self.assertEqual(result.status, validator.STATUS_COMPLETED)
        self.assertEqual(result.changed_files, ("src/app.py",))
        self.assertFalse(result.is_incomplete)

    def test_blocked_result_requires_reason_and_recommendation(self):
        result = validator.parse_worker_result(
            {
                "task_id": "t2",
                "status": "blocked",
                "changed_files": [],
                "blocked_reason": "scope too narrow",
                "recommendation": "scope_expand",
                "summary": "Could not proceed within declared scope.",
            }
        )
        self.assertEqual(result.status, validator.STATUS_BLOCKED)
        self.assertEqual(result.blocked_reason, "scope too narrow")
        self.assertEqual(result.recommendation, "scope_expand")
        self.assertTrue(result.is_incomplete)

    def test_missing_result_is_incomplete_never_success(self):
        # v1 원문: "결과 누락(timeout/truncation)을 미완 처리" — 성공으로
        # 격상되지 않는다. raw=None (워커가 아예 응답하지 않음).
        result = validator.parse_worker_result(None)
        self.assertEqual(result.status, validator.STATUS_MISSING)
        self.assertTrue(result.is_incomplete)
        self.assertNotEqual(result.status, validator.STATUS_COMPLETED)

    def test_missing_task_id_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "status": "completed",
                    "changed_files": [],
                    "summary": "no id",
                }
            )

    def test_invalid_status_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "t3",
                    "status": "in_progress",
                    "changed_files": [],
                    "summary": "bad status",
                }
            )

    def test_blocked_without_reason_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "t4",
                    "status": "blocked",
                    "changed_files": [],
                    "recommendation": "split",
                    "summary": "missing blocked_reason",
                }
            )

    def test_blocked_without_recommendation_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "t5",
                    "status": "blocked",
                    "changed_files": [],
                    "blocked_reason": "conflict",
                    "summary": "missing recommendation",
                }
            )

    def test_blocked_with_invalid_recommendation_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "t6",
                    "status": "blocked",
                    "changed_files": [],
                    "blocked_reason": "conflict",
                    "recommendation": "give_up",
                    "summary": "bad recommendation enum",
                }
            )

    def test_missing_changed_files_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {"task_id": "t7", "status": "completed", "summary": "x"}
            )

    def test_changed_files_as_single_string_is_malformed(self):
        # tuple("abc") 문자 단위 분해 오인정 방지 규율과 동일 방향
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "t8",
                    "status": "completed",
                    "changed_files": "src/app.py",
                    "summary": "x",
                }
            )

    def test_missing_summary_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "t9",
                    "status": "completed",
                    "changed_files": [],
                }
            )

    def test_non_mapping_result_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result("completed")

    def test_empty_task_id_is_malformed(self):
        with self.assertRaises(validator.MalformedWorkerResult):
            validator.parse_worker_result(
                {
                    "task_id": "",
                    "status": "completed",
                    "changed_files": [],
                    "summary": "x",
                }
            )


if __name__ == "__main__":
    unittest.main()
