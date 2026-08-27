"""plan Task 5.5 — orchestrator.md Prompt Contract 문안 검사 (spec §4.2, §4.1,
§2.5, §5.3; brainstorm §37~§41, §44).

이 테스트는 `orchestration/` 코드 모듈이 아니라 **agent prompt 문서**
(`agents/orchestrator.md`) 의 텍스트 내용을 검사한다 — plan Task 5.5 Step 1
원문: "계약 문안 존재 검사 — 깊이 규칙·단일 워커 조항·위임 금지·워커
금지목록(커밋/스테이징/stamp/trail/stash)·barrier 통합 절차 문구가
orchestrator.md 에 존재 (섹션 anchor 기반). WorkUnit 직렬화 문안이
8필드(id/objective/scope/dependencies/assigned_agent/status/
expected_output/mode) 와 정확히 일치하고 mode 닫힌 집합
(edit_only|mutating) 을 명시하는지 검사."

파싱 전략: 파일 밖에서 표현이 흔들려도(재작성) 테스트가 안정적으로 앵커를
찾도록 `orchestrator.md` 는 각 계약 요소를 `<!-- anchor:<key> -->` /
`<!-- /anchor:<key> -->` HTML 주석 쌍으로 감싼다(plan 이 요구하는 "섹션
anchor 기반" 검사 방식). 본 테스트는 각 anchor 블록의 존재 + 내용을
검사하며, 산문 재작성에 흔들리지 않는다.

고정 대상 (plan Task 5.5 Steps 1 원문 그대로):
1. brainstorm §37 10항 계약 원문 verbatim 채택.
2. 깊이 규칙 (워커 추가 위임 금지, 3단계 상한 — spec §2.5 조건 2).
3. 단일 워커 조항 (spec §44 / brainstorm §37 마지막 줄).
4. "병렬화 자체를 목표로 하지 않는다" 핵심 원칙.
5. 워커 dispatch 금지목록 5종 (커밋·스테이징·stamp·trail·stash).
6. 부모 barrier 통합 절차 (검증→테스트→리뷰→커밋, 부모 소유).
7. WorkUnit 직렬화 — 8필드 정확히 일치 + mode 닫힌 집합.
8. `expected_output` 의 워커 결과 스키마 (task_id/status/changed_files/
   blocked_reason/recommendation/summary).
9. `[unit:<id>]` task_subject 마커 규약 (tracker.py 상관관계 소비처).
10. D5 결정 — builder/reviewer/security 워커 신설 안 함, v1 기존 에이전트
    (feature-builder 계열/code-reviewer/security-reviewer) 매핑 재사용.

Round 8 코드 리뷰 Medium 지적 수정 (문서 내부 모순 해소, spec 이 이미 정한
바를 문안에 정확히 반영 — 신규 정책 결정 아님):
- 구 문안(깊이 규칙, ~line 54)은 "Worker 가 띄우는 리뷰어(3)" 라고 써서,
  같은 문단의 "워커의 추가 위임 금지" 와 직접 모순됐다.
- barrier 절(~line 139)은 "리뷰는 부모가 수행" 이라고 써서, D5 매핑이
  code-reviewer 를 Worker 로 분류한 것과 누가 code-reviewer 를 호출하는지
  불명확했다.
- 해소(spec §2.5 조건 2 원문 그대로): 워커 위임 금지는 절대적이다. Builder
  뿐 아니라 Reviewer/Security 워커도 전부 **Orchestrator 가 직접
  디스패치**하며, 그 어떤 워커도 다른 서브에이전트를 스스로 띄우지 않는다.
  `DocumentWideConsistencyTest` 가 (a) "워커/빌더가 띄우는" 류 표현의 전역
  부재와 (b) "리뷰어·보안 워커도 Orchestrator 가 디스패치한다" 명시 조항의
  존재를 검사해 이 일관성을 고정한다.
"""
import os
import re
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
_ORCHESTRATOR_MD_PATH = os.path.join(_PLUGIN_ROOT, "agents", "orchestrator.md")

# brainstorm §37 원문 그대로 (2026-08-07 rein-v2-governance-orchestration.md,
# lines 574-588) — 공백/줄바꿈까지 verbatim 비교 대상이다 (spec §4.2:
# "brainstorm §37 의 10항 계약 원문을 orchestrator.md 계약부로 채택").
TEN_CLAUSE_CONTRACT = """For non-trivial development tasks:
1. Analyze the task before implementation.
2. Decompose it into independent WorkUnits where meaningful.
3. Identify dependencies and potential file-scope conflicts.
4. Delegate independent WorkUnits to subagents.
5. Run independent subagents concurrently whenever this provides meaningful benefit.
6. Prefer Builder agents for implementation work and specialist agents where appropriate.
7. Do not perform substantial implementation yourself when it can reasonably be delegated.
8. Collect and inspect all worker results.
9. Resolve integration conflicts.
10. Verify that the integrated result satisfies the original task.

Use a single worker when decomposition or parallel execution would add more overhead than benefit."""

# WorkUnit 8필드 — spec §4.3 정정판 + work_unit.py 계약과 정확히 일치해야
# 하는 순서 (2026-08-11 정정: mode 는 7필드 밖 확장이 아니라 8번째 공식
# 필드).
EXPECTED_WORK_UNIT_FIELDS = [
    "id",
    "objective",
    "scope",
    "dependencies",
    "assigned_agent",
    "status",
    "expected_output",
    "mode",
]

# 워커 결과 스키마 — validator.py / v1 parallel-execute 계승, 정확히 이
# 순서 (task_id/status/changed_files/blocked_reason/recommendation/summary).
EXPECTED_WORKER_RESULT_FIELDS = [
    "task_id",
    "status",
    "changed_files",
    "blocked_reason",
    "recommendation",
    "summary",
]

# 워커 dispatch 금지목록 5종 (spec §5.3 계승 행 원문: "워커의 커밋·
# 스테이징·stamp·trail 기록·stash 금지").
PROHIBITION_KEYWORDS = ["커밋", "스테이징", "stamp", "trail", "stash"]


def _read_orchestrator_md():
    with open(_ORCHESTRATOR_MD_PATH, "r", encoding="utf-8") as fh:
        return fh.read()


def _extract_anchor(content, key):
    """`<!-- anchor:<key> -->...<!-- /anchor:<key> -->` 블록 내용을 반환한다.

    앵커 쌍이 없으면 AssertionError (테스트 실패로 명확히 드러나야 하므로
    None 을 조용히 반환하지 않는다).
    """
    pattern = re.compile(
        r"<!--\s*anchor:%s\s*-->(.*?)<!--\s*/anchor:%s\s*-->" % (re.escape(key), re.escape(key)),
        re.DOTALL,
    )
    match = pattern.search(content)
    if match is None:
        raise AssertionError(
            "anchor '%s' not found in orchestrator.md (expected paired "
            "<!-- anchor:%s --> ... <!-- /anchor:%s --> markers)" % (key, key, key)
        )
    return match.group(1)


def _extract_field_names(block_text):
    """fenced code block 안의 ``<field>: ...`` 라인에서 필드명만 순서대로 추출."""
    names = []
    for line in block_text.splitlines():
        stripped = line.strip()
        field_match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", stripped)
        if field_match:
            names.append(field_match.group(1))
    return names


class OrchestratorFileExistsTest(unittest.TestCase):
    def test_orchestrator_md_exists(self):
        self.assertTrue(
            os.path.isfile(_ORCHESTRATOR_MD_PATH),
            "plugins/rein-core/agents/orchestrator.md must exist (plan Task 5.5)",
        )


class FrontmatterTest(unittest.TestCase):
    def setUp(self):
        self.content = _read_orchestrator_md()

    def test_frontmatter_name_is_orchestrator(self):
        self.assertRegex(self.content, r"^---\s*\nname:\s*orchestrator\s*\n")

    def test_frontmatter_has_description(self):
        frontmatter_match = re.match(r"^---\s*\n(.*?)\n---\s*\n", self.content, re.DOTALL)
        self.assertIsNotNone(frontmatter_match, "orchestrator.md must start with YAML frontmatter")
        self.assertIn("description:", frontmatter_match.group(1))


class TenClauseContractTest(unittest.TestCase):
    """brainstorm §37 10항 계약 원문 verbatim 채택 (spec §4.2)."""

    def setUp(self):
        self.content = _read_orchestrator_md()

    def test_ten_clause_contract_present_verbatim(self):
        block = _extract_anchor(self.content, "ten-clause-contract")
        self.assertIn(
            TEN_CLAUSE_CONTRACT,
            block,
            "orchestrator.md must adopt brainstorm §37's 10-clause contract verbatim "
            "(exact text, including the trailing single-worker sentence)",
        )


class DepthRuleTest(unittest.TestCase):
    """깊이 규칙 — 워커 추가 위임 금지, 3단계 상한 (spec §2.5 조건 2)."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "depth-rule")

    def test_three_level_cap_stated(self):
        self.assertIn("3단계", self.block)

    def test_worker_delegation_ban_stated(self):
        # "워커" + "위임" 금지 표현이 함께 있어야 한다 (워커의 추가 위임 금지).
        self.assertIn("워커", self.block)
        self.assertIn("위임", self.block)
        self.assertTrue(
            "금지" in self.block or "않는다" in self.block,
            "depth-rule block must explicitly forbid further worker delegation",
        )

    def test_depth_chain_mentions_main_orchestrator_worker(self):
        self.assertIn("Orchestrator", self.block)
        self.assertIn("메인", self.block)


class SingleWorkerClauseTest(unittest.TestCase):
    """단일 워커 조항 (spec §44 / brainstorm §37 마지막 줄)."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "single-worker")

    def test_single_worker_clause_present(self):
        self.assertIn("단일 워커", self.block)

    def test_single_worker_overhead_condition_present(self):
        self.assertTrue(
            "오버헤드" in self.block or "이득" in self.block,
            "single-worker clause must state the overhead-vs-benefit condition",
        )


class ParallelNotGoalPrincipleTest(unittest.TestCase):
    """핵심 원칙: 병렬화 자체를 목표로 하지 않는다."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "parallel-not-goal")

    def test_principle_sentence_present(self):
        self.assertIn("병렬화 자체를 목표로 하지 않는다", self.block)


class WorkUnitSerializationTest(unittest.TestCase):
    """WorkUnit 직렬화 포맷 — 8필드 정확히 일치 + mode 닫힌 집합 (spec §4.3)."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "workunit-fields")

    def test_exactly_eight_fields_in_order(self):
        field_names = _extract_field_names(self.block)
        self.assertEqual(
            field_names,
            EXPECTED_WORK_UNIT_FIELDS,
            "WorkUnit serialization must list exactly the 8 contract fields, "
            "in order: id/objective/scope/dependencies/assigned_agent/status/"
            "expected_output/mode",
        )

    def test_mode_closed_set_stated(self):
        mode_lines = [
            line for line in self.block.splitlines() if line.strip().startswith("mode:")
        ]
        self.assertTrue(mode_lines, "workunit-fields block must contain a 'mode:' line")
        mode_line = mode_lines[0]
        self.assertIn("edit_only", mode_line)
        self.assertIn("mutating", mode_line)


class WorkerResultSchemaTest(unittest.TestCase):
    """expected_output 의 워커 결과 스키마 명시 (spec §5.3 계승 행)."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "worker-result-schema")

    def test_six_fields_present_in_order(self):
        field_names = _extract_field_names(self.block)
        self.assertEqual(
            field_names,
            EXPECTED_WORKER_RESULT_FIELDS,
            "expected_output worker result schema must list task_id/status/"
            "changed_files/blocked_reason/recommendation/summary in that order",
        )

    def test_status_closed_set_stated(self):
        status_lines = [
            line for line in self.block.splitlines() if line.strip().startswith("status:")
        ]
        self.assertTrue(status_lines, "worker-result-schema block must contain a 'status:' line")
        self.assertIn("completed", status_lines[0])
        self.assertIn("blocked", status_lines[0])

    def test_missing_result_is_incomplete(self):
        self.assertTrue(
            "missing" in self.block or "누락" in self.block,
            "worker-result-schema block must address missing/timeout results "
            "being treated as incomplete, not silently promoted to success",
        )


class UnitMarkerTest(unittest.TestCase):
    """`[unit:<id>]` task_subject 마커 규약 (tracker.py 상관관계 소비처)."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "unit-marker")

    def test_marker_literal_present(self):
        self.assertIn("[unit:<id>]", self.block)

    def test_task_subject_mentioned(self):
        self.assertIn("task_subject", self.block)


class WorkerProhibitionListTest(unittest.TestCase):
    """워커 dispatch 금지목록 5종 (spec §5.3: 커밋·스테이징·stamp·trail·stash)."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "prohibition-list")

    def test_all_five_prohibitions_present(self):
        missing = [kw for kw in PROHIBITION_KEYWORDS if kw not in self.block]
        self.assertEqual(
            missing,
            [],
            "prohibition-list block must mention all 5 forbidden worker actions "
            "(commit/staging/stamp/trail/stash); missing: %r" % (missing,),
        )

    def test_stash_explicitly_forbidden(self):
        # spec §5.3 은 stash 를 v1 대비 신규 추가 금지항목으로 명시한다 —
        # 단순 언급이 아니라 금지 표현과 함께 있어야 한다.
        stash_lines = [line for line in self.block.splitlines() if "stash" in line]
        self.assertTrue(stash_lines, "stash must appear in the prohibition list")
        self.assertTrue(
            any("금지" in line for line in stash_lines),
            "stash mention must be paired with an explicit prohibition ('금지')",
        )


class BarrierProcedureTest(unittest.TestCase):
    """부모 barrier 통합 절차 — 검증→테스트→리뷰→커밋, 부모 소유."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "barrier-procedure")

    def test_all_four_steps_present(self):
        for keyword in ["검증", "테스트", "리뷰", "커밋"]:
            self.assertIn(keyword, self.block)

    def test_steps_appear_in_verify_test_review_commit_order(self):
        positions = [self.block.find(kw) for kw in ["검증", "테스트", "리뷰", "커밋"]]
        self.assertTrue(
            all(p != -1 for p in positions),
            "all four barrier steps must be present before order can be checked",
        )
        self.assertEqual(
            positions,
            sorted(positions),
            "barrier procedure must state steps in verify -> test -> review -> commit order",
        )

    def test_parent_ownership_stated(self):
        self.assertIn("부모", self.block)


class WorkerAgentMappingTest(unittest.TestCase):
    """D5 결정 — builder/reviewer/security 워커 신설 안 함, v1 에이전트 매핑 재사용."""

    def setUp(self):
        self.content = _read_orchestrator_md()
        self.block = _extract_anchor(self.content, "worker-mapping")

    def test_no_new_worker_agents_stated(self):
        self.assertTrue(
            "신설하지 않" in self.block or "신설 안" in self.block,
            "worker-mapping block must state that no new worker agents are created (D5)",
        )

    def test_feature_builder_family_mapped(self):
        self.assertIn("feature-builder", self.block)

    def test_code_reviewer_mapped(self):
        self.assertIn("code-reviewer", self.block)

    def test_security_reviewer_mapped(self):
        self.assertIn("security-reviewer", self.block)


class DocumentWideConsistencyTest(unittest.TestCase):
    """Round 8 코드 리뷰 Medium 지적 수정 — 워커 위임 금지의 전역 일관성.

    spec §2.5 조건 2 는 워커의 추가 위임을 절대적으로 금지한다. 이는 특정
    섹션(깊이 규칙)만의 문구가 아니라 문서 전체에 걸쳐 일관돼야 하는
    계약이다 — 다른 절(barrier 통합, D5 워커 매핑)이 "리뷰어/보안 워커를
    누군가(빌더?) 가 띄운다" 는 인상을 주면, 깊이 규칙의 금지 문구와
    모순된다. 이 클래스는 anchor 하나에 국한하지 않고 파일 전체 텍스트를
    검사한다.
    """

    # 구 문안의 스모킹건 패턴: "<워커류 주어> 가 띄우(다/는)". 부정문
    # ("~하는 일은 없다" 류)은 주어와 동사 사이에 목적어가 끼어 인접하지
    # 않으므로 이 정규식과 매치되지 않는다 — 오탐 없이 "워커가 직접
    # 띄운다" 형태의 긍정 서술만 잡는다.
    _WORKER_INITIATED_DISPATCH_RE = re.compile(
        r"(?:워커|Worker|빌더|Builder)\s*(?:가|이)\s*(?:추가로\s*)?띄우"
    )

    def setUp(self):
        self.content = _read_orchestrator_md()

    def test_no_worker_initiated_dispatch_phrase(self):
        match = self._WORKER_INITIATED_DISPATCH_RE.search(self.content)
        self.assertIsNone(
            match,
            "orchestrator.md must not contain a clause where a Worker/Builder "
            "launches ('띄우다') another subagent — the old 'Worker 가 띄우는 "
            "리뷰어' phrasing contradicted the absolute worker-delegation ban "
            "(spec §2.5 조건 2); found: %r"
            % (match.group(0) if match else None,),
        )

    def test_explicit_orchestrator_dispatches_reviewer_clause(self):
        self.assertIn(
            "리뷰어·보안 워커도 Orchestrator 가 디스패치한다",
            self.content,
            "orchestrator.md must explicitly state that reviewer/security "
            "workers are dispatched by the Orchestrator itself (never by a "
            "builder worker) to resolve the depth-rule / barrier / "
            "D5-mapping contradiction flagged in round 8",
        )

    def test_worker_mapping_states_builder_never_calls_reviewer(self):
        worker_mapping_block = _extract_anchor(self.content, "worker-mapping")
        self.assertIn(
            "Builder 워커가 이들을 호출하는",
            worker_mapping_block,
            "D5 worker-mapping block must state that Builder workers never "
            "call the reviewer/security workers directly (consistent with "
            "the depth-rule and barrier-procedure clauses)",
        )

    def test_barrier_review_step_owns_reviewer_dispatch(self):
        barrier_block = _extract_anchor(self.content, "barrier-procedure")
        self.assertIn(
            "Orchestrator 가 `code-reviewer` / `security-reviewer` 워커를 디스패치",
            barrier_block,
            "barrier-procedure's review step must state that Orchestrator "
            "(not a builder worker, not an unspecified 'parent' action) "
            "dispatches the reviewer/security workers",
        )


if __name__ == "__main__":
    unittest.main()
