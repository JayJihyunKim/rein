"""plan Task 6.1 — authority 배선 계약 (spec §7 Migration Plan, Scope ID
`authority-switches-per-capability-with-dual-read-of-legacy-markers`).

`rein.engine.authority` 자체(정책 로드·legacy marker 파싱·결합 규칙)는
`tests/migration/test_authority_dual_read.py` 가 이미 고정한다 — 이
파일은 건드리지 않는다. 이 스위트가 고정하는 것은 그 완성된 authority
모듈을 실제 평가 경로(`rein.engine.evaluator.evaluate` →
`rein.engine.runtime.evaluate` → `rein.cli.run_event`)에 **배선**하는
계약이다:

1. 전환된 capability + v2 증거 있음 → 기존과 동일 결정(legacy 무시,
   reason 문자열까지 byte-identical — "v2 증거가 있으면 결과는 지금과
   동일해야 한다"는 계약을 reason 까지 포함해 고정한다).
2. 전환된 capability + v2 증거 없음 + legacy marker PASS → 통과, 근거에
   legacy 출처가 남는다.
3. 전환된 capability + v2 증거 없음 + legacy marker FAIL/부재 → 차단
   (조용한 통과 금지).
4. 미전환 capability → authority 미개입, 기존 경로 그대로.
5. project_root 를 얻을 수 없는 경우 → authority 미적용 + 그 사실이
   근거에 드러난다(조용히 통과시키지 않는다).
6. authority 정책 손상 → fail-closed(명시 에러 전파, 삼키지 않음).

그리고 배선 자체의 안전장치:

7. `project_root` 인자를 아예 주지 않는 기존 1211개 테스트의 호출
   패턴(= `evaluator.evaluate(event, context, policies, registry=...)`,
   `project_root` 생략)은 이 배선 이전과 완전히 동일해야 한다 —
   sentinel(`PROJECT_ROOT_NOT_PROVIDED`)과 명시적 `None` 을 구분하는
   설계 자체를 행위로 고정한다(구분이 없으면 project_root 미지정 시
   reason 문자열이 바뀌어 그 방대한 기존 스위트가 깨진다).
8. `rein.cli.run_event()` 가 `REIN_PROJECT_ROOT` 환경변수를 읽어
   그대로 전달한다(미설정/빈 문자열 → `None`, cwd 로 추정하지 않는다).

실제 `trail/`·`.rein/` 파일 fixture 는 전부 `tempfile.TemporaryDirectory`
안에서만 만든다 — 저장소의 진짜 trail/ 은 절대 건드리지 않는다.
"""
import dataclasses
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import authority, evaluator, runtime  # noqa: E402
from rein.engine.context import (  # noqa: E402
    FACT_COST_CHEAP,
    EvaluationContext,
    EvidenceStorageError,
    FactResolverRegistry,
)
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK  # noqa: E402
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402

from rein.capabilities.review.capability import (  # noqa: E402
    FACT_CHANGESET_REVIEW_DIGEST,
    FACT_POLICY_VERSION as REVIEW_POLICY_VERSION,
    REQUIREMENT_NAME as CODE_REVIEW,
    issue_code_review_evidence,
    register_code_review,
)
from rein.capabilities.security.capability import (  # noqa: E402
    REQUIREMENT_NAME as SECURITY_REVIEW,
    register_security_review,
)
from rein.capabilities.task.capability import (  # noqa: E402
    FACT_CHANGESET_TASK_RELEVANT,
    FACT_TASK_ACTIVE,
    REQUIREMENT_NAME as ACTIVE_TASK,
    register_active_task,
)
from rein.capabilities.testing.capability import (  # noqa: E402
    REQUIREMENT_NAME as TESTS_PASSED,
    register_tests_passed,
)
from rein.capabilities.approval.capability import (  # noqa: E402
    REQUIREMENT_NAME as USER_APPROVAL,
    register_user_approval,
)

_EVENT = "tool.pre"


class _StubEvidenceSource:
    """type 별로 분류해 반환하는 evidence 소스 test double (조회 자체는
    항상 정상 수행 — EvidenceStorageError 를 던지지 않는다)."""

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        return tuple(
            record for record in self._records if record.type == requirement_name
        )


class _MutatingFindEvidenceSource:
    """호출마다 다른 결과를 반환하는 evidence 소스 test double — High 1
    (Phase 6 리뷰) 재현 전용. 실제 저장소가 같은 cycle 안에서 동시
    write 로 상태가 바뀌는 상황(또는 단순 버그)을 흉내낸다: 1차 조회는
    `first_result` 를, 그 이후 조회는 전부 `later_result` 를 반환한다.
    `EvaluationContext.evidence_for()` 의 request-scoped 캐시가 없다면,
    같은 cycle 안에서 등록 구현체의 내부 조회(1차)와 authority 배선의
    재확인 조회(2차)가 서로 다른 스냅샷을 보게 된다."""

    def __init__(self, first_result, later_result=()):
        self._first_result = tuple(first_result)
        self._later_result = tuple(later_result)
        self.calls = 0

    def find(self, requirement_name):
        self.calls += 1
        return self._first_result if self.calls == 1 else self._later_result


class _CountingEvidenceSource:
    """`find()` 호출을 requirement 이름별로 계측하는 evidence 소스 test
    double — "미전환 capability 는 evidence 저장소를 전혀 조회하지
    않는다"(5회차 리뷰 시정)를 직접 관측하기 위한 스파이."""

    def __init__(self, records=()):
        self._records = tuple(records)
        self.calls_by_name = {}

    def find(self, requirement_name):
        self.calls_by_name[requirement_name] = (
            self.calls_by_name.get(requirement_name, 0) + 1
        )
        return tuple(
            record for record in self._records if record.type == requirement_name
        )


class _SpyRequirement:
    """등록 구현체 test double — `evaluate()` 호출 횟수를 계측하고, 선택
    적으로 예외를 던져 "미전환 축의 예외가 결정에 스며드는지"를 검증할
    수 있게 한다."""

    def __init__(self, result=True, raise_error=None):
        self.calls = 0
        self._result = result
        self._raise_error = raise_error

    def evaluate(self, context):
        self.calls += 1
        if self._raise_error is not None:
            raise self._raise_error
        return self._result


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _dod_dir(project_root):
    return os.path.join(project_root, "trail", "dod")


def _write_codex_stamp(project_root, verdict="PASS", reviewed_at="2026-08-01T00:00:00Z", cycle="3"):
    _write(
        os.path.join(_dod_dir(project_root), ".codex-reviewed"),
        "verdict: {}\nreviewed_at: {}\ncycle: {}\n".format(verdict, reviewed_at, cycle),
    )


def _write_authority_policy(project_root, switched_names):
    _write(
        os.path.join(project_root, ".rein", "policy", "authority.yaml"),
        "switched:\n" + "".join("  - {}\n".format(name) for name in switched_names),
    )


def _write_active_dod(project_root, slug="example-task", date="2026-08-01"):
    _write(
        os.path.join(_dod_dir(project_root), "dod-{}-{}.md".format(date, slug)),
        "# DoD\n\n- date: {}\n".format(date),
    )


def _policy(policy_id, require, failure_mode="closed"):
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            "trigger: {}\nrequire:\n{}\nfailure_mode: {}\n".format(
                _EVENT,
                "".join("  - {}\n".format(name) for name in require),
                failure_mode,
            ),
            source="<test:{}>".format(policy_id),
        ),
    }


def _policy_with_when(policy_id, when_key, when_value, require, failure_mode="closed"):
    """`_policy()` 와 동일하지만 `when:` 조건 한 줄을 추가한다 — 6회차
    리뷰(High 1/High 2) 재현 전용. 조건 fact 는 보통 지연 계산 resolver
    (`FactResolverRegistry`)로 공급해 "조건 계산이 실제로 resolver 를
    건드리는지"를 관측할 수 있게 한다."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            "trigger: {}\nwhen:\n  {}: {}\nrequire:\n{}failure_mode: {}\n".format(
                _EVENT,
                when_key,
                when_value,
                "".join("  - {}\n".format(name) for name in require),
                failure_mode,
            ),
            source="<test:{}>".format(policy_id),
        ),
    }


def _code_review_registry():
    registry = RequirementRegistry()
    register_code_review(registry)
    return registry


def _code_review_setup(digest="digest-1", version="v1"):
    """(policy, registry, facts) — code_review 를 요구하는 최소 구성."""
    registry = _code_review_registry()
    policy = _policy("p-review", require=[CODE_REVIEW])
    facts = {FACT_CHANGESET_REVIEW_DIGEST: digest, REVIEW_POLICY_VERSION: version}
    return policy, registry, facts


# ===========================================================================
# 1. 전환된 capability + v2 증거 있음 → 기존과 동일 결정 (reason 포함)
# ===========================================================================


class V2EvidenceWinsUnchangedTest(unittest.TestCase):
    """v2 evidence 판정(유효/무효 어느 쪽이든)이 legacy marker 상태와
    무관하게 authority 배선이 있든 없든 Decision 이 byte-identical
    해야 한다.

    **2026-08-20 개정(③-a) → 2026-08-24 갱신(③-d)** — ③-a 시절에는
    "유효"(subject 일치·result PASS·policy version 유효)한 v2 증거만
    이 "byte-identical" 계약의 범위였다 — subject 가 불일치하는 stale
    증거는 legacy 위임 대상으로 갈라졌었다(아래 두 번째 테스트가 당시
    그 분기를 고정했다, 구 이름 `test_block_decision_diverges_with_
    project_root_when_stale_and_legacy_fresh`). ③-d 로 legacy marker
    대체 자체가 제거되며 그 분기가 사라졌다 — 이제 stale 증거도 다시
    이 클래스의 "byte-identical" 범위 안이다(v2 의 False 판정이
    legacy 로 구제되지 않으므로 baseline == with_authority 가 항상
    성립). 아래 두 번째 테스트를 그 복귀를 증명하도록 갱신했다(무대체
    소멸 아님 — 같은 시나리오가 새 결론으로 이관)."""

    def test_allow_decision_identical_with_and_without_project_root(self):
        policy, registry, facts = _code_review_setup()
        evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": facts[FACT_CHANGESET_REVIEW_DIGEST]},
            current_digest=facts[FACT_CHANGESET_REVIEW_DIGEST],
            policy_version=facts[REVIEW_POLICY_VERSION],
        )
        source = _StubEvidenceSource((evidence,))

        with tempfile.TemporaryDirectory() as project_root:
            # legacy marker says FAIL — must be irrelevant since v2 wins
            _write_codex_stamp(project_root, verdict="NEEDS-FIX")

            baseline = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=source),
                [policy],
                registry=registry,
            )
            with_authority = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=source),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(baseline.decision, DECISION_ALLOW)
        self.assertEqual(baseline, with_authority)

    def test_block_decision_identical_with_and_without_project_root_when_stale(
        self,
    ):
        # **2026-08-20(③-a) → 2026-08-24(③-d) 갱신** — ③-a 시절에는 이
        # 테스트가 정반대(`test_block_decision_diverges_...`, ALLOW 로
        # divergent)를 고정했다: legacy 신선 PASS 표식이 stale v2 증거를
        # 구제해 project_root 유무에 따라 BLOCK/ALLOW 로 갈렸다. ③-d 로
        # legacy 대체 자체가 제거되며 그 구제 경로가 사라졌다 — stale
        # v2 evidence 는 authority 활성 여부와 무관하게 항상 BLOCK 이다
        # (marker 가 PASS 내용으로 있어도 무관 — inert). 이름·기대값을
        # ③-a 이전(=지금)의 "byte-identical" 계약으로 되돌린다.
        policy, registry, facts = _code_review_setup(digest="new-digest")
        stale_evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": "old-digest"},
            current_digest="old-digest",
            policy_version="v1",
        )
        source = _StubEvidenceSource((stale_evidence,))

        with tempfile.TemporaryDirectory() as project_root:
            # legacy marker 는 PASS 내용이지만 ③-d 이후로는 읽히지 않는다
            # — inert fixture, "여전히 무관함"을 계속 증명하기 위해 남김.
            _write_codex_stamp(project_root, verdict="PASS")

            baseline = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=source),
                [policy],
                registry=registry,
            )
            with_authority = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=source),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(baseline.decision, DECISION_BLOCK)
        self.assertEqual(with_authority.decision, DECISION_BLOCK)
        self.assertEqual(baseline, with_authority)


class EvidenceSnapshotConsistencyTest(unittest.TestCase):
    """High 1 (Phase 6 리뷰) — evidence 이중 조회가 서로 다른 스냅샷을
    보면 v2 의 명시적 False 판정이 legacy PASS fallback 으로 뒤집혀
    fail-open ALLOW 가 된다(는 게 구 계약의 위협 모델이었다, ③-a 이전).

    당시 수정: `EvaluationContext.evidence_for()` 가 requirement 별
    request-scoped 캐시를 두어, 등록 구현체와 배선부가 항상 같은
    스냅샷을 보게 강제했다 — 실제 저장소 조회는 cycle 당 requirement
    이름별로 최대 1회.

    **2026-08-20(③-a) → 2026-08-24(③-d) 갱신** — ③-a 로 code_review/
    security_review 축의 배선부는 evidence 존재 여부 재확인 자체를
    하지 않게 됐다(`context.fact(subject_fact_key)` 로 subject 상태만
    확인). ③-d 로는 그 subject 상태 확인마저 사라졌다 —
    `v2_for_authority = v2_satisfied` 를 그대로 넘긴다(`_requirement_
    satisfied` 본문 참조). 그 결과 (a) "2차 evidence 조회가 다른
    스냅샷을 본다"는 경로 자체가 이 두 축에서는 애초에 존재하지
    않는다(캐시가 막는 게 아니라 재조회 자체가 없다) —
    `source.calls == 1` 은 여전히 성립한다. (b) 이 시나리오(subject
    불일치 stale v2 증거 + 신선 legacy PASS)의 최종 판정은 ③-a 때
    ALLOW(legacy 위임)였다가 ③-d 로 다시 BLOCK 으로 돌아왔다 — legacy
    가 더 이상 stale v2 증거를 구제하지 않는다(marker 내용과 무관하게
    v2 의 False 가 그대로 최종값). "이중 조회로 인한 fail-open"이라는
    원래 위협은 여전히 발생하지 않는다는 것이 이 테스트가 계속
    고정하는 핵심이다."""

    def test_stale_v2_evidence_blocks_not_masked_by_fresh_legacy_marker(self):
        policy, registry, facts = _code_review_setup(digest="new-digest")
        # 리뷰가 본 digest 는 "old-digest" — 현재 digest("new-digest")와
        # 어긋나므로 CodeReviewRequirement.evaluate() 는 이 레코드를
        # 발견하고도(=1차 조회는 비어있지 않음) 최종 False 를 반환한다.
        stale_evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": "old-digest"},
            current_digest="old-digest",
            policy_version="v1",
        )
        source = _MutatingFindEvidenceSource((stale_evidence,))

        with tempfile.TemporaryDirectory() as project_root:
            # legacy marker 는 PASS 내용이지만 ③-d 이후로는 읽히지 않는다
            # — inert fixture.
            _write_codex_stamp(project_root, verdict="PASS")

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=source),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)
        # 배선부가 evidence_for 를 재조회하지 않으므로(fact 기반 게이팅
        # 으로 전환) 실제 저장소 질의는 여전히 1회다 — "캐시가 두 번째
        # 조회를 같은 스냅샷으로 흡수해서"가 아니라 "애초에 두 번째
        # 조회 자체가 없어서"다.
        self.assertEqual(source.calls, 1)


# ===========================================================================
# 2/3. 전환된 capability + v2 증거 없음 — legacy dual read
# ===========================================================================


class LegacyDualReadInterceptsTest(unittest.TestCase):
    """③-d 이전: "v2 evidence 가 아예 없을 때만 legacy marker 로
    대체된다"를 고정하던 클래스 — legacy PASS 표식만으로 ALLOW 가 되는
    경로가 실제로 있었다. **③-d 갱신**: legacy marker 대체가 완전히
    제거되며, code_review/security_review 축은 evidence 가 없어도
    `CodeReviewRequirement.evaluate()` 가 곧바로 `False`(bool, `None`
    아님)를 계산하므로 `v2_for_authority` 는 항상 그 bool 값 그대로다
    — legacy marker 가 개입할 여지(`v2_for_authority=None`) 자체가 이제
    이 두 축에서는 구조적으로 발생하지 않는다. 클래스 이름은 유지하되
    (rename 안 함, 다른 파일 참조 없음을 확인했으나 파일 내
    cross-reference 최소화 원칙), 각 테스트는 이제 "legacy marker 의
    내용이 무엇이든(PASS/FAIL/부재) v2 의 판정만 그대로 남는다"를
    증명한다."""

    def test_legacy_pass_marker_does_not_rescue_missing_v2_evidence(self):
        # ③-d 갱신 — 이전 이름은
        # test_legacy_pass_allows_and_reason_names_the_source 였고 ALLOW
        # + reason 에 SOURCE_LEGACY 를 기대했다. 지금은 legacy PASS
        # 표식이 있어도 v2 증거가 없으면(CodeReviewRequirement.evaluate()
        # 가 False 를 반환) BLOCK 이다 — marker 내용은 이제 완전히
        # 무관하다.
        policy, registry, facts = _code_review_setup()
        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="PASS")
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_legacy_fail_blocks_not_a_silent_pass(self):
        # ③-d 갱신 — 이전에는 legacy FAIL marker 가 `_authority_source_
        # note`(requirement 이름을 포함한 문자열)를 reason 에 남겼다.
        # legacy 대체가 사라진 지금은 v2 자신의 False 판정이 그대로
        # 최종값(SOURCE_V2)이라 authority note 가 없다("결과가 바뀌지
        # 않으면 소음을 남기지 않는다" 원칙) — requirement 이름은 이제
        # `missing_requirements` 로만 확인한다.
        policy, registry, facts = _code_review_setup()
        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="NEEDS-FIX")
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_legacy_absent_blocks_not_a_silent_pass(self):
        # marker 파일 자체가 없음 — ③-d 이전부터 BLOCK 이었고 지금도
        # BLOCK(이유는 이제 "legacy 부재"가 아니라 "v2 증거 부재" 그
        # 자체다).
        policy, registry, facts = _code_review_setup()
        with tempfile.TemporaryDirectory() as project_root:
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_runtime_dict_interface_project_root_passthrough_blocks_on_legacy_pass(
        self,
    ):
        # cli 왕복 계약(runtime.evaluate dict 인터페이스)에서도 legacy
        # PASS 표식이 더 이상 통과로 반영되지 않는다는 것을 확인한다
        # (③-d 갱신 — 이전 이름은
        # test_runtime_dict_interface_carries_project_root_through 였고
        # ALLOW 를 기대했다).
        policy, registry, facts = _code_review_setup()
        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="PASS")
            result = runtime.evaluate(
                _EVENT,
                facts,
                [policy],
                evidence_source=_StubEvidenceSource(()),
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(result["decision"], DECISION_BLOCK)
        self.assertIn(CODE_REVIEW, result["missing_requirements"])


# ===========================================================================
# 4. 미전환 capability — authority 미개입
# ===========================================================================


class UnswitchedCapabilityUnaffectedTest(unittest.TestCase):
    """미전환 capability 는 v2 결정에서 완전히 제외된다 (Phase 6 4회차
    리뷰 High 1 시정 — plan Task 6.1 "미전환 capability 는 v1 경로 유지"
    계약).

    이 클래스의 이전 버전은 이 계약을 정반대로 고정하고 있었다: 미전환
    security_review 에 대해 `baseline == with_authority` 그리고 두 값이
    모두 BLOCK 임을 요구했는데, 이는 "authority 가 개입하지 않으면 v2
    자신의 registry/evidence 판정(v2_satisfied, 이 테스트에서는 evidence
    가 없으므로 False)이 그대로 최종값이 된다"는 (버그였던) 옛 구현을
    그대로 스펙인 것처럼 고정한 것이다. 실제 계약은 다르다 — "미전환
    capability 는 v1 경로 유지"란 v2 evaluate() 가 그 축을 아예 판단하지
    않는다는 뜻이다(v1 훅이 여전히 유일한 판정자). v2 가 자기 나름의
    판정을 내려 BLOCK 해버리면 v1·v2 이중 판정으로 과차단하게 되므로,
    수정된 계약에서는 project_root 가 제공되고 authority 가 활성화된
    순간 해당 requirement 는 (missing_requirements 계산에서) 제외되고
    `satisfied=True` 로 취급된다 — `baseline`(project_root 자체가 없는,
    authority 완전 비활성 경로)과 `with_authority`(authority 활성, 그러나
    이 축은 미전환)가 이제 서로 다른 결과를 내는 것이 올바른 동작이다.

    **6회차 리뷰 갱신 (High 1)**: 이 클래스의 첫 번째 테스트
    (`test_unswitched_security_review_is_excluded_from_v2_decision`)의
    이전 버전은 `with_authority.reason` 에 여전히 `SECURITY_REVIEW` 와
    "not switched" 문구가 남아있기를 요구했다 — 이는 정책 전체(이 정책의
    유일한 requirement 가 security_review 하나뿐)가 여전히 "matched" 로
    처리되고 `_requirement_satisfied` 가 호출돼 미전환 note 를 남긴다는
    (5회차까지의) 가정 위에 있었다. 6회차 시정은 그 가정 자체를 바꾼다
    — 정책의 requirement 가 **전부** 미전환이면 `evaluate()` 는 그
    정책의 `when` 조건조차 계산하지 않고 정책을 완전히 건너뛴다(module
    docstring "정책 단위 사전 필터" 절 참조) — `_requirement_satisfied`
    자체가 호출되지 않으므로 미전환 note 도 생기지 않는다. 이 정책이
    유일한 trigger-매칭 정책이므로 최종 reason 은 이제
    `REASON_NO_MATCH`("no policy matched event")다 — "v2 는 이 이벤트에
    대해 판단할 정책이 아예 없다"는 뜻이며, 이는 "v2 가 이 정책을 보긴
    했지만 그 축을 제외했다"보다 오히려 더 정확한 진술이다(v2 는 이
    정책의 `when` 조건이 실제로 이 이벤트에 매치했는지조차 확인하지
    않았다). `missing_requirements == ()` 와 `decision == ALLOW` 는
    변하지 않는다 — v2 가 이 정책 때문에 차단하는 일은 여전히 없다."""

    def test_unswitched_security_review_is_excluded_from_v2_decision(self):
        # 프로젝트 override 가 code_review 만 전환 — security_review 는
        # 미전환이므로 legacy 표식 상태와 무관하게(PASS 든 아니든) v2
        # 결정에서 제외된다. `baseline`(project_root 없음, 순수 v1/v2
        # hybrid fallback)은 evidence 가 없어 BLOCK 이지만,
        # `with_authority`(authority 활성)는 이 requirement 를 v2 가
        # 아예 판단하지 않으므로 ALLOW 다 — 두 값이 이제는 **다른 것이
        # 옳다**(v1 훅이 별도로 그 축을 판정해야 하는 몫이지, v2 evaluate()
        # 가 대신 재판정하면 안 된다).
        policy = _policy("p-security", require=[SECURITY_REVIEW])
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])
            _write(
                os.path.join(_dod_dir(project_root), ".security-reviewed"),
                "verdict=PASS\nreviewed=2026-08-01T01:00:00\ncycle=3\n",
            )
            _write_codex_stamp(project_root, cycle="3")

            baseline = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
            )
            with_authority = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(baseline.decision, DECISION_BLOCK)
        self.assertNotEqual(
            baseline,
            with_authority,
            msg=(
                "authority 활성화 후에는 미전환 requirement 가 v2 결정에서"
                " 제외되므로 project_root 없는 baseline 과 달라지는 것이"
                " 옳다"
            ),
        )
        self.assertEqual(with_authority.decision, DECISION_ALLOW)
        self.assertEqual(with_authority.missing_requirements, ())
        # (③-d 로 이 자리의 `assertNotIn(authority.SOURCE_LEGACY, ...)`
        # 단언 제거 — 그 상수 자체가 삭제됐다. "미전환 축이 legacy
        # marker 로 대체된 것이 아니다"라는 취지는 이제 구조적으로
        # 자명하다: legacy 대체 메커니즘 자체가 코드에 없다. 아래
        # REASON_NO_MATCH 단언이 이 정책이 아예 매치되지 않았음을 —
        # 즉 어떤 대체도 일어나지 않았음을 — 더 강하게 고정한다.)
        # 6회차 시정(High 1) — 이 정책의 유일한 requirement 가 미전환
        # 이므로 `evaluate()` 는 `when` 조건조차 계산하지 않고 정책을
        # 통째로 건너뛴다(class docstring "6회차 리뷰 갱신" 절 참조).
        # matched_policy_id 도, 미전환 note 도 남지 않고 reason 은 다른
        # 매칭 정책이 전혀 없었다는 사실 그대로다.
        self.assertEqual(with_authority.reason, evaluator.REASON_NO_MATCH)
        self.assertIsNone(with_authority.policy)

    def test_unswitched_capability_excluded_even_without_any_legacy_marker(self):
        # legacy marker 조차 없어도(완전 초기 상태) 미전환이면 여전히
        # 제외된다 — "legacy PASS 가 있어서 통과한 것"이 아님을
        # 분리해서 고정한다.
        policy = _policy("p-security", require=[SECURITY_REVIEW])
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())


# ===========================================================================
# 4b. 전환/미전환 혼재 — 전환된 축의 BLOCK 은 미전환 축의 제외로 가려지지
#     않는다 (High 1 회귀 방지 — "v2 가 차단해야 할 것을 놓치는" 방향으로
#     새지 않았는지 직접 고정)
# ===========================================================================


class MixedSwitchedAndUnswitchedRequirementsTest(unittest.TestCase):
    """한 policy 가 전환된 requirement 와 미전환 requirement 를 동시에
    요구할 때: 미전환 축의 제외(High 1 시정)가 전환된 축의 정상 BLOCK 을
    가리지 않아야 한다. 이 클래스가 없으면 "미전환은 항상 통과"라는
    과도하게 관대한(그리고 틀린) 구현으로도 위 클래스의 테스트들이 전부
    통과할 수 있다 — 여기서 전환된 축은 여전히 독립적으로 차단한다는
    사실을 별도로 고정한다."""

    def _mixed_policy(self):
        return _policy("p-mixed", require=[CODE_REVIEW, SECURITY_REVIEW])

    def _registry(self):
        registry = _code_review_registry()
        register_security_review(registry)
        return registry

    def test_switched_requirement_still_blocks_when_unswitched_sibling_is_excluded(self):
        # code_review(전환, evidence 없음·legacy 없음 → BLOCK 대상) +
        # security_review(미전환, legacy PASS 표식 있음 → 그래도 제외).
        # 전체 decision 은 code_review 하나만으로 BLOCK 이어야 하고,
        # missing_requirements 에 security_review 가 섞이면 안 된다
        # (제외가 아니라 "우연히 통과"였다면 이 assert 가 잡는다).
        _, _, facts = _code_review_setup()
        policy = self._mixed_policy()
        registry = self._registry()

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])
            _write(
                os.path.join(_dod_dir(project_root), ".security-reviewed"),
                "verdict=PASS\nreviewed=2026-08-01T01:00:00\ncycle=3\n",
            )
            _write_codex_stamp(project_root, cycle="3", verdict="NEEDS-FIX")

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))
        self.assertNotIn(SECURITY_REVIEW, decision.missing_requirements)

    def test_all_switched_requirements_satisfied_plus_excluded_unswitched_allows(self):
        # ③-d 갱신 — 이전에는 code_review(전환)가 legacy PASS marker
        # 만으로 충족됐다. legacy 대체가 사라진 지금은 실제 v2 evidence
        # (subject 일치·result PASS·policy version 유효)가 있어야
        # code_review 가 충족된다 — 그 v2 evidence + security_review
        # (미전환, 완전히 제외)의 조합으로 전체 decision 이 ALLOW 임을
        # 고정한다.
        policy = self._mixed_policy()
        registry = self._registry()
        _, _, facts = _code_review_setup()
        evidence = issue_code_review_evidence(
            {
                "verdict": "PASS",
                "reviewed_digest": facts[FACT_CHANGESET_REVIEW_DIGEST],
            },
            current_digest=facts[FACT_CHANGESET_REVIEW_DIGEST],
            policy_version=facts[REVIEW_POLICY_VERSION],
        )

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])
            # security_review 의 legacy marker 를 아예 쓰지 않는다 —
            # naive(비수정) 구현이라면 미전환 축도 v2 fallback(evidence
            # 없음 → False)을 그대로 써서 BLOCK 했을 상황.

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts=facts, evidence_source=_StubEvidenceSource((evidence,))
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())


# ===========================================================================
# 4c. 정책 단위 사전 필터 — 6회차 리뷰 High 1/High 2 (evaluator.py module
#     docstring "정책 단위 사전 필터" 절, 리뷰어 재현을 그대로 테스트로
#     고정한다). 두 결함 모두 같은 뿌리(평가 순서)에서 나온다:
#     `when` 조건의 지연 계산 fact 해석이 authority 로드보다 먼저 일어나면
#     (a) 미전환 축만 요구하는 정책도 조건 resolver 가 호출되고,
#     (b) 손상된 authority 정책이 조건 계산의 failure_mode 분기에 가려질
#     수 있다.
# ===========================================================================


class UnswitchedOnlyPolicyConditionNeverEvaluatedTest(unittest.TestCase):
    """High 1 리뷰어 재현: 조건이 `probe: ok` 이고 요구가 미전환 축뿐인
    정책 + `probe` resolver 가 예외를 던지도록 구성 → 수정 전에는 resolver
    가 1회 호출되고 `failure_mode` 분기(여기서는 'closed')로 차단됐다.
    기대는 resolver 0회 호출 + 그 정책이 v2 판정에서 완전히 배제되는 것
    (다른 매칭 정책이 없으므로 최종 결정은 ALLOW/REASON_NO_MATCH)."""

    def test_condition_resolver_never_called_when_all_requirements_unswitched(self):
        calls = []

        def _probe(context):
            calls.append(1)
            raise EvidenceStorageError("boom — should never be called")

        resolvers = FactResolverRegistry()
        resolvers.register("probe", _probe, FACT_COST_CHEAP)

        policy = _policy_with_when(
            "p-probe", "probe", "ok", require=[SECURITY_REVIEW], failure_mode="closed"
        )
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            # security_review 는 미전환 (override 는 code_review 만 전환)
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts={},
                    evidence_source=_StubEvidenceSource(()),
                    fact_resolvers=resolvers,
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(calls, [], msg="probe resolver must not be invoked")
        # 수정 전에는 resolver 예외가 failure_mode='closed' 로 흡수돼
        # BLOCK 이 나갔다 — 지금은 이 정책이 아예 무관했으므로 ALLOW.
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.reason, evaluator.REASON_NO_MATCH)

    def test_decision_unaffected_by_whatever_the_resolver_would_have_returned(self):
        # 대조군 — resolver 가 예외 대신 정상값을 반환해도(그 값이 조건과
        # 일치하든 불일치하든) 여전히 호출되지 않고 결과는 동일해야 한다.
        for probe_value in ("ok", "not-ok"):
            with self.subTest(probe_value=probe_value):
                calls = []

                def _probe(context, _value=probe_value):
                    calls.append(_value)
                    return _value

                resolvers = FactResolverRegistry()
                resolvers.register("probe", _probe, FACT_COST_CHEAP)

                policy = _policy_with_when(
                    "p-probe", "probe", "ok", require=[SECURITY_REVIEW],
                    failure_mode="closed",
                )
                registry = RequirementRegistry()
                register_security_review(registry)

                with tempfile.TemporaryDirectory() as project_root:
                    _write_authority_policy(project_root, ["code_review"])

                    decision = evaluator.evaluate(
                        _EVENT,
                        EvaluationContext(
                            facts={},
                            evidence_source=_StubEvidenceSource(()),
                            fact_resolvers=resolvers,
                        ),
                        [policy],
                        registry=registry,
                        project_root=project_root,
                    )

                self.assertEqual(calls, [])
                self.assertEqual(decision.decision, DECISION_ALLOW)
                self.assertEqual(decision.reason, evaluator.REASON_NO_MATCH)


class CorruptedAuthorityPrecedesConditionFailureModeTest(unittest.TestCase):
    """High 2 리뷰어 재현: authority 정책이 손상(`switched: not-a-list`)된
    상태에서 조건 resolver 도 실패하도록 구성하고, 그 정책의
    `failure_mode` 를 'open'(경고와 함께 ALLOW)으로 선언한다. 수정 전에는
    조건 resolver 실패가 먼저 잡혀 'open' 분기로 조용히 ALLOW 가 나갔고
    손상된 authority.yaml 은 한 번도 읽히지 않았다. 기대는 손상된
    authority 정책이 조건 계산보다 먼저 표면화되어 `AuthorityPolicyError`
    로 fail-closed 하는 것 — 'open' failure_mode 에 흡수되지 않는다."""

    def test_corrupt_authority_policy_raises_even_when_condition_resolver_would_fail_open(
        self,
    ):
        calls = []

        def _probe(context):
            calls.append(1)
            raise EvidenceStorageError("boom — should never be reached")

        resolvers = FactResolverRegistry()
        resolvers.register("probe", _probe, FACT_COST_CHEAP)

        policy = _policy_with_when(
            "p-probe", "probe", "ok", require=[CODE_REVIEW], failure_mode="open"
        )
        registry = _code_review_registry()

        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched: not-a-list\n",
            )

            with self.assertRaises(authority.AuthorityPolicyError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts={},
                        evidence_source=_StubEvidenceSource(()),
                        fact_resolvers=resolvers,
                    ),
                    [policy],
                    registry=registry,
                    project_root=project_root,
                )

        self.assertEqual(
            calls, [], msg="condition resolver must not run before authority load"
        )


class MixedPolicyConditionStillEvaluatedTest(unittest.TestCase):
    """대조군 — 정책이 전환/미전환 requirement 를 혼재해서 요구하면 사전
    필터를 통과한다: `when` 조건은 정상적으로 계산되고(resolver 가
    호출된다), 전환된 축은 여전히 정상적으로 평가·차단한다. 이 클래스가
    없으면 "정책에 미전환 requirement 가 하나라도 있으면 조건을 건너뛴다"
    는 과도하게 공격적인(그리고 틀린) 구현으로도 위 두 클래스가 통과할
    수 있다."""

    def test_condition_resolver_is_called_and_switched_axis_still_blocks(self):
        calls = []

        def _probe(context):
            calls.append(1)
            return "ok"

        resolvers = FactResolverRegistry()
        resolvers.register("probe", _probe, FACT_COST_CHEAP)

        _, _, facts = _code_review_setup()
        policy = _policy_with_when(
            "p-mixed",
            "probe",
            "ok",
            require=[CODE_REVIEW, SECURITY_REVIEW],
            failure_mode="closed",
        )
        registry = _code_review_registry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            # code_review 만 전환 — security_review 는 미전환(제외 대상).
            _write_authority_policy(project_root, ["code_review"])
            # code_review 의 legacy marker 는 일부러 쓰지 않는다 — v2
            # evidence 도 없으므로(중 facts 만 제공) legacy ABSENT → BLOCK.

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts=facts,
                    evidence_source=_StubEvidenceSource(()),
                    fact_resolvers=resolvers,
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(
            calls, [1], msg="mixed policy must still evaluate its when condition"
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))
        self.assertNotIn(SECURITY_REVIEW, decision.missing_requirements)

    def test_authority_still_loaded_exactly_once_when_first_policy_is_fully_unswitched(
        self,
    ):
        # 사이클당 1회 로드 계약이 "첫 정책이 전부 미전환이라 건너뛰는"
        # 경우에도 유지되는지 직접 관측한다 — 건너뛴 정책도 로드 지점을
        # 거치므로(스킵 여부 판단 자체가 로드된 switched 를 필요로 한다),
        # 두 번째(혼재) 정책에서 다시 로드하면 안 된다.
        from unittest import mock

        load_calls = []
        real_load = authority.load_authority_policy

        def _counting_load(project_root=None):
            load_calls.append(project_root)
            return real_load(project_root=project_root)

        unswitched_only = _policy("p-security-only", require=[SECURITY_REVIEW])
        _, _, facts = _code_review_setup()
        mixed = _policy("p-mixed-2", require=[CODE_REVIEW, SECURITY_REVIEW])

        registry = _code_review_registry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])
            _write_codex_stamp(project_root, verdict="NEEDS-FIX")

            with mock.patch.object(
                authority, "load_authority_policy", side_effect=_counting_load
            ):
                decision = evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts=facts, evidence_source=_StubEvidenceSource(())
                    ),
                    [unswitched_only, mixed],
                    registry=registry,
                    project_root=project_root,
                )

        self.assertEqual(len(load_calls), 1)
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


# ===========================================================================
# 5. project_root 를 얻을 수 없는 경우 — 미적용 + 근거에 드러남
# ===========================================================================


class ProjectRootUnavailableTest(unittest.TestCase):
    def test_explicit_none_project_root_keeps_existing_judgement_but_notes_it(self):
        policy, registry, facts = _code_review_setup()
        # v2 evidence 없음 — authority 가 있었다면 legacy 로 갈렸을
        # 상황이지만, project_root 가 없으므로 v2 fallback(False) 이
        # 그대로 유지돼야 한다(legacy 를 몰래 참조하지 않는다).
        decision = evaluator.evaluate(
            _EVENT,
            EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
            [policy],
            registry=registry,
            project_root=None,
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertIn("project_root", decision.reason)
        self.assertIn(CODE_REVIEW, decision.reason)

    def test_omitting_project_root_entirely_is_byte_identical_to_pre_wiring(self):
        # sentinel 기본값 — project_root 인자를 아예 주지 않는 기존
        # 1211개 테스트의 호출 패턴. reason 이 project_root 를 언급하지
        # 않아야 한다(명시적 None 과 달리 "시도했다"는 사실 자체가 없다).
        policy, registry, facts = _code_review_setup()
        decision = evaluator.evaluate(
            _EVENT,
            EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
            [policy],
            registry=registry,
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)
        self.assertNotIn("project_root", decision.reason)

    def test_run_event_without_env_var_still_evaluates_and_notes_unavailability(self):
        from unittest import mock

        from rein.cli import ENV_PROJECT_ROOT, run_event

        payload = (
            '{"hook_event_name": "PreToolUse", "tool_name": "Bash", '
            '"tool_input": {"command": "ls"}}'
        )
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ENV_PROJECT_ROOT, None)
            response = run_event(payload)
        # 정책이 없으므로 ALLOW/REASON_NO_MATCH 다 — authority 가 관여할
        # requirement 자체가 없어 project_root 언급도 없어야 한다(잡음
        # 최소화: 판정에 영향 없는 곳까지 매번 note 를 붙이지 않는다).
        self.assertEqual(response["decision"], "ALLOW")


# ===========================================================================
# 6. authority 정책 손상 — fail-closed
# ===========================================================================


class AuthorityPolicyCorruptionFailsClosedTest(unittest.TestCase):
    def test_corrupt_override_policy_propagates_not_silently_ignored(self):
        policy, registry, facts = _code_review_setup()
        evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": facts[FACT_CHANGESET_REVIEW_DIGEST]},
            current_digest=facts[FACT_CHANGESET_REVIEW_DIGEST],
            policy_version=facts[REVIEW_POLICY_VERSION],
        )
        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched: not-a-list\n",
            )
            with self.assertRaises(authority.AuthorityPolicyError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts=facts, evidence_source=_StubEvidenceSource((evidence,))
                    ),
                    [policy],
                    registry=registry,
                    project_root=project_root,
                )

    def test_unknown_capability_in_override_propagates(self):
        policy, registry, facts = _code_review_setup()
        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["not_a_real_capability"])
            with self.assertRaises(authority.AuthorityPolicyError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts=facts, evidence_source=_StubEvidenceSource(())
                    ),
                    [policy],
                    registry=registry,
                    project_root=project_root,
                )


class AuthorityConfigLoadedBeforeOtherFailuresTest(unittest.TestCase):
    """High 2 (Phase 6 리뷰) — 손상된 authority 정책이 fail-open 뒤로
    숨는 결함. 이전 구현은 requirement 의 v2 판정(등록 구현체
    `evaluate()` 호출)을 authority 정책 로드보다 먼저 수행했다 —
    구현체가 `FactResolutionError` 를 던지면 evaluator 가 그것을 먼저
    잡아 policy 의 `failure_mode` 분기(예: 'open' → ALLOW)로 넘어가고,
    그 경로에서는 손상된 authority.yaml 이 **아예 읽히지 않는다**.
    리뷰어 재현: `switched: not-a-list`(손상) + 잘못된 타입 fact
    (`FactResolutionError` 유발) + `failure_mode: open` → 최종 ALLOW —
    정책 손상이 조용히 통과했다.

    수정: authority 설정은 첫 관련 requirement 평가 이전에, 평가
    사이클당 1회 로드·검증한다(`evaluator.evaluate()` 의 `switched`
    preload) — 손상된 정책은 이제 무관한 fact 해석 실패보다 먼저
    표면화된다."""

    def test_corrupt_authority_policy_raises_even_when_a_sibling_requirement_would_fail_open(
        self,
    ):
        # failure_mode='open' — 만약 authority 정책 로드가 여전히 v2
        # 판정 뒤에 있다면, 아래 FactResolutionError 가 이 open 분기로
        # 흡수돼 손상된 정책이 한 번도 읽히지 않고 ALLOW 가 나갔을 것.
        policy = _policy("p-task", require=[ACTIVE_TASK], failure_mode="open")
        registry = RequirementRegistry()
        register_active_task(registry)
        # task/capability.py 의 strict 타입 계약 — task.active 는 str
        # 또는 None 만 유효하다. int 는 ActiveTaskRequirement.evaluate()
        # 가 즉시 FactResolutionError 로 승격한다.
        facts = {FACT_TASK_ACTIVE: 12345}

        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched: not-a-list\n",
            )
            with self.assertRaises(authority.AuthorityPolicyError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts=facts, evidence_source=_StubEvidenceSource(())
                    ),
                    [policy],
                    registry=registry,
                    project_root=project_root,
                )

    def test_authority_policy_loaded_at_most_once_per_cycle(self):
        # 부가 확인 — 여러 policy 가 서로 다른 switched capability 를
        # 요구해도 authority.yaml 은 cycle 당 1회만 읽힌다(성능 회귀
        # 방지 겸, "1회 로드" 계약을 직접 관측).
        load_calls = []
        real_load = authority.load_authority_policy

        def _counting_load(project_root=None):
            load_calls.append(project_root)
            return real_load(project_root=project_root)

        review_policy, review_registry, review_facts = _code_review_setup()
        task_policy = _policy("p-task", require=[ACTIVE_TASK])
        task_registry = RequirementRegistry()
        register_active_task(task_registry)

        combined_registry = RequirementRegistry()
        register_code_review(combined_registry)
        register_active_task(combined_registry)

        facts = dict(review_facts)
        facts[FACT_TASK_ACTIVE] = "task-1"

        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="PASS")
            from unittest import mock

            with mock.patch.object(
                authority, "load_authority_policy", side_effect=_counting_load
            ):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts=facts, evidence_source=_StubEvidenceSource(())
                    ),
                    [review_policy, task_policy],
                    registry=combined_registry,
                    project_root=project_root,
                )
        self.assertEqual(len(load_calls), 1)


# ===========================================================================
# 9. fact 판정형(active_task) — v2 가 항상 이긴다 (부모 재작업 지시,
#    2026-08-12: "증거 레코드 없음" 과 "v2 가 판정을 못 내림" 은 다르다)
# ===========================================================================


class FactJudgedCapabilityAlwaysUsesV2Test(unittest.TestCase):
    """active_task 는 Evidence 를 전혀 발급하지 않는다 — 등록 구현체가
    평가를 수행했다면 그 결과가 곧 v2 판정이고, legacy marker 는 절대
    참조되지 않는다(원래 배선의 결함: evidence 유무로 게이팅했기 때문에
    이 capability 는 항상 legacy 로 대체됐었다)."""

    def _registry(self):
        registry = RequirementRegistry()
        register_active_task(registry)
        return registry

    def test_v2_true_wins_when_legacy_would_have_said_absent(self):
        # v2: task.active 가 비어있지 않은 문자열 → 충족(True).
        # legacy: trail/dod/ 에 pending dod 파일이 전혀 없음 → ABSENT
        # (=만약 evidence 유무로 게이팅했다면 "v2 모름" 취급돼 legacy 로
        # 대체되고, ABSENT != PASS 라 satisfied=False 로 뒤집혔을
        # 것 — 그 결함을 이 테스트가 재현·고정한다).
        policy = _policy("p-task", require=[ACTIVE_TASK])
        registry = self._registry()
        facts = {FACT_TASK_ACTIVE: "task-123"}

        with tempfile.TemporaryDirectory() as project_root:
            baseline = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
            )
            with_authority = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(baseline.decision, DECISION_ALLOW)
        self.assertEqual(baseline, with_authority)
        # (③-d 로 `assertNotIn(authority.SOURCE_LEGACY, ...)` 제거 — 그
        # 상수 자체가 삭제됐다. `assertEqual(baseline, with_authority)`
        # 가 이미 reason 문자열까지 완전 동일함을 요구하므로 — baseline
        # 에는 authority note 가 전혀 없다 — 그 취지는 그대로 보존된다.)

    def test_v2_false_wins_when_legacy_would_have_said_pass(self):
        # v2: task.active 없음 + changeset 관련(True) → 미충족(False).
        # legacy: 무관한 pending dod 파일이 존재 → PASS(=만약 evidence
        # 유무로 게이팅했다면 legacy 로 대체돼 satisfied=True 로 뒤집혀,
        # v2 가 올바르게 차단하려던 것을 조용히 통과시켰을 것).
        policy = _policy("p-task", require=[ACTIVE_TASK])
        registry = self._registry()
        facts = {FACT_TASK_ACTIVE: None, FACT_CHANGESET_TASK_RELEVANT: True}

        with tempfile.TemporaryDirectory() as project_root:
            _write_active_dod(project_root, slug="unrelated-task")

            baseline = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
            )
            with_authority = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(baseline.decision, DECISION_BLOCK)
        self.assertEqual(baseline, with_authority)

    def test_no_v2_material_fallback_still_blocks_when_unregistered(self):
        # has_registered_impl=False (registry=None) 인 fact 판정형은 "v2
        # 가 실제로 평가를 수행했다"는 전제가 성립하지 않으므로, 이
        # 경우까지 무조건 v2 승리로 처리하지 않는다 — evidence 유무
        # 게이팅(항상 부재 → v2_for_authority=None)으로 떨어진다.
        # 프로덕션에서는 `_build_registry()` 가 5종을 전부 등록하므로 이
        # 분기는 실제로 도달하지 않지만(방어적 사양), 배선 로직이
        # "등록 여부와 무관하게 무조건 v2" 로 설계되지 않았음을
        # 고정한다. **③-d 갱신** — 이전 이름은
        # test_legacy_only_fallback_still_applies_when_unregistered 였고
        # `trail/dod/` 의 pending 파일(legacy marker)이 이 경로를 ALLOW
        # 로 구제했다. legacy 대체가 제거된 지금은 marker 가 있어도
        # v2_for_authority=None 은 그대로 보수적 미충족이다
        # (`SOURCE_NO_MATERIAL`) — active_task 축에서도 (a) 계약
        # ["resolve_authority: None→False+비legacy source"]이 성립함을
        # 이 테스트가 고정한다.
        policy = _policy("p-task", require=[ACTIVE_TASK])
        with tempfile.TemporaryDirectory() as project_root:
            # legacy marker(pending dod 파일)를 일부러 남겨 "있어도
            # 무관함"을 증명한다.
            _write_active_dod(project_root)
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts={}, evidence_source=_StubEvidenceSource(())
                ),
                [policy],
                registry=None,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (ACTIVE_TASK,))


# ===========================================================================
# 10. 증거 발급형 4종 — 분류 도입 후에도 dual read 동작 그대로 (회귀 없음)
# ===========================================================================


class EvidenceIssuedCapabilitiesUnaffectedTest(unittest.TestCase):
    """code_review 는 이미 위 클래스들이 충분히 덮는다 — 여기서는 나머지
    3종(security_review/tests_passed/user_approval)에 대해서도 분류
    도입이 기존 dual read 경로를 바꾸지 않았음을 각각 확인한다."""

    def test_security_review_legacy_pass_marker_no_longer_rescues(self):
        # ③-d 갱신 — 이전 이름은
        # test_security_review_legacy_pass_still_recognized 였고, legacy
        # PASS 두 표식(교차비교 포함)만으로 ALLOW 를 기대했다. legacy
        # 대체가 제거된 지금은 v2 evidence 가 없으면(SecurityReview
        # Requirement.evaluate() 가 False 를 반환) marker 내용과 무관하게
        # BLOCK 이다 — code_review 축의
        # LegacyDualReadInterceptsTest.test_legacy_pass_marker_does_not_
        # rescue_missing_v2_evidence 와 대칭.
        policy = _policy("p-security", require=[SECURITY_REVIEW])
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, cycle="3")
            _write(
                os.path.join(_dod_dir(project_root), ".security-reviewed"),
                "verdict=PASS\nreviewed=2026-08-01T01:00:00\ncycle=3\n",
            )
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (SECURITY_REVIEW,))

    def test_tests_passed_no_v2_no_legacy_still_blocks(self):
        # tests_passed 는 v1 대응 legacy marker 자체가 없다(항상
        # ABSENT) — 분류 도입 후에도 fail-closed(조용한 통과 없음)가
        # 유지돼야 한다. Phase 7 결정 4(2026-08-19)로 배포 기본값이
        # 5축→3축(code_review/security_review/active_task)으로
        # 좁혀져 tests_passed 는 기본 미전환(자동 충족, 개입 안 함)이
        # 됐다 — 이 테스트의 목적("전환됐는데 증거가 없으면 여전히
        # 차단")을 재현하려면 opt-in override 로 tests_passed 를 직접
        # 전환해야 한다(authority.py 모듈 docstring 재편입 조건 미충족
        # 상태에서의 단위 테스트이므로 배포 기본값과 무관).
        policy = _policy("p-tests", require=[TESTS_PASSED])
        registry = RequirementRegistry()
        register_tests_passed(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, REQUIREMENT_NAMES)
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (TESTS_PASSED,))

    def test_user_approval_no_v2_no_legacy_still_blocks(self):
        # 동일 사유(위 tests_passed 케이스 주석 참조) — user_approval 도
        # Phase 7 결정 4 이후 기본 미전환이므로 opt-in override 로
        # 전환해야 이 테스트의 "전환 상태에서의 fail-closed" 단언이
        # 성립한다.
        policy = _policy("p-approval", require=[USER_APPROVAL])
        registry = RequirementRegistry()
        register_user_approval(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, REQUIREMENT_NAMES)
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (USER_APPROVAL,))


# ===========================================================================
# 10b. 등록 구현체 부재(has_registered_impl=False) + stray evidence →
# 여전히 fail-closed (코드리뷰 High 시정, Phase 7 웨이브 3 ③-d)
# ===========================================================================


class UnregisteredEvidenceIssuedCapabilityFailsClosedTest(unittest.TestCase):
    """code_review/security_review 는 종국 상태표(spec §3.6)의 subject
    유효성 검증(subject 일치·result 충족·policy version 유효)을 등록
    구현체(`CodeReviewRequirement.evaluate`/`SecurityReviewRequirement.
    evaluate`)에게만 위임한다 — `_requirement_satisfied()` 는 그 결과를
    재구현하지 않는다(단일 정본 유지). 그런데 `has_registered_impl=
    False`(예: `registry=None` 또는 미등록)면 그 검증을 수행할 코드
    자체가 없다 — `_compute_v2_satisfied()` 는 이 경우 검증 없이
    "evidence 존재"만 보는 옛 판정으로 떨어진다. 이 존재-only 값을
    그대로 authority 에 넘기면, stray(잘못된 digest·policy version 의)
    evidence 가 하나라도 있다는 사실만으로 ALLOW 로 승격된다 — ③-a 가
    막으려던 "증거 존재 → 무조건 승리" 함정이 등록 부재 경로로
    되살아나는 회귀였다(재현·수리: 코드리뷰 High, 2026-08-24). 이
    스위트는 그 수리(`v2_for_authority=None` fail-closed)를 code_review/
    security_review 양쪽에서 고정한다."""

    def test_code_review_unregistered_with_stray_evidence_still_blocks(self):
        policy = _policy("p-review", require=[CODE_REVIEW])
        facts = {FACT_CHANGESET_REVIEW_DIGEST: "current-digest", REVIEW_POLICY_VERSION: "v1"}
        # 다른 digest 에 결속된 stray evidence — 등록 구현체가 있었다면
        # subject 불일치로 무효 처리됐을 레코드다.
        stray_evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": "stale-digest"},
            current_digest="stale-digest",
            policy_version="v1",
        )
        source = _StubEvidenceSource((stray_evidence,))
        # registry=None — has_registered_impl 이 항상 False 로 떨어진다.
        with tempfile.TemporaryDirectory() as project_root:
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=source),
                [policy],
                registry=None,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_security_review_unregistered_with_stray_evidence_still_blocks(self):
        policy = _policy("p-security", require=[SECURITY_REVIEW])
        # security_review 의 subject fact 는 evaluate() 내부에서 계산되므로
        # 여기서는 evidence 존재만으로 판정이 갈리는지가 관심사 — 등록
        # 구현체 없이 stray evidence 하나만 있으면 여전히 BLOCK 이어야
        # 한다 (code_review 케이스와 대칭).
        stray_evidence = dataclasses.replace(
            issue_code_review_evidence(
                {"verdict": "PASS", "reviewed_digest": "stale-digest"},
                current_digest="stale-digest",
                policy_version="v1",
            ),
            type=SECURITY_REVIEW,
        )
        source = _StubEvidenceSource((stray_evidence,))
        with tempfile.TemporaryDirectory() as project_root:
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=source),
                [policy],
                registry=None,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (SECURITY_REVIEW,))


# ===========================================================================
# 11. 분류 완전성 — 5종 전부가 한쪽에 속함, 목록 밖 이름은 fail-closed
# ===========================================================================


class ClassificationCompletenessTest(unittest.TestCase):
    def test_classification_partitions_all_five_requirement_names(self):
        combined = (
            authority.EVIDENCE_ISSUED_CAPABILITIES
            | authority.FACT_JUDGED_CAPABILITIES
        )
        self.assertEqual(combined, frozenset(REQUIREMENT_NAMES))
        self.assertEqual(
            authority.EVIDENCE_ISSUED_CAPABILITIES
            & authority.FACT_JUDGED_CAPABILITIES,
            frozenset(),
        )

    def test_is_evidence_issued_matches_known_classification(self):
        self.assertTrue(authority.is_evidence_issued("code_review"))
        self.assertTrue(authority.is_evidence_issued("security_review"))
        self.assertTrue(authority.is_evidence_issued("tests_passed"))
        self.assertTrue(authority.is_evidence_issued("user_approval"))
        self.assertFalse(authority.is_evidence_issued("active_task"))

    def test_is_evidence_issued_rejects_name_outside_fixed_five(self):
        with self.assertRaises(authority.UnknownCapabilityError):
            authority.is_evidence_issued("not_a_real_capability")

    def test_wiring_never_needs_classification_error_for_policy_requirements(self):
        # 배선부(_requirement_satisfied)는 REQUIREMENT_NAMES 안의 이름만
        # authority 에 넘긴다(정책 로더가 이미 5종 밖을 거부하므로) —
        # 그래서 실제 evaluate() 호출에서 CapabilityClassificationError
        # 가 날 일은 없다. 이 사실을 두 계층에서 동시에 고정한다: (a)
        # 5종 전부가 분류돼 있다는 사실은 위 파티션 테스트가, (b) 분류
        # 함수가 실제로 예외를 던지지 않는다는 사실은 여기서 5종 전부를
        # 순회해 확인한다.
        for name in REQUIREMENT_NAMES:
            authority.is_evidence_issued(name)  # 예외 없이 끝나야 한다


# ===========================================================================
# 13. loader 우회 직접 호출 경계 — 미지 requirement 도 authority 가
#     fail-closed 로 거부한다 (Medium 6-4, Phase 6 리뷰)
# ===========================================================================


def _raw_policy(policy_id, require, failure_mode="closed", when=None):
    """kernel/policy.py 의 로더를 거치지 않고 `evaluate()` 가 받아들이는
    "로더 형태" dict 를 직접 구성한다 — `validate_requirement_names` 의
    로드 시점 거부를 우회한 호출을 흉내낸다(모듈 docstring 참조: "로더를
    우회한 dict 가 와도 failure_mode 는 fail-closed 로 처리한다").

    `when` (기본 None → 빈 dict): 조건 resolver 호출 여부를 관측해야 하는
    단축 평가(short-circuit) 회귀 테스트를 위한 선택적 확장 — 기존
    호출자(`when` 생략)는 이전과 동일하게 빈 조건을 받는다."""
    return {
        "policy_id": policy_id,
        "fields": {
            "trigger": _EVENT,
            "when": dict(when) if when else {},
            "require": tuple(require),
            "failure_mode": failure_mode,
        },
    }


class LoaderBypassedUnknownRequirementFailsClosedTest(unittest.TestCase):
    """Medium 6-4 — 정상 경로는 `kernel.policy.load_policies` 가 5종 밖
    requirement 이름을 로드 시점에 거부한다. 하지만 `evaluator.evaluate()`
    를 그 로더 없이 직접 호출(위 `_raw_policy` 처럼)하면, authority 가
    활성(project_root 제공)이어도 이전 구현은 `requirement not in
    REQUIREMENT_NAMES` 를 조기 반환해 authority 의 `UnknownCapabilityError`
    fail-closed 원칙을 전혀 적용하지 않고 조용히 기존 존재 검사 결과를
    반환했다 — authority.py 자체의 "5종 밖 이름은 절대 조용히 통과시키지
    않는다" 철학이 이 배선 지점에서만 예외적으로 뚫려 있었다."""

    def test_unknown_requirement_name_raises_when_authority_is_active(self):
        policy = _raw_policy("p-bogus", require=["not_a_real_capability"])
        with tempfile.TemporaryDirectory() as project_root:
            with self.assertRaises(authority.UnknownCapabilityError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts={}, evidence_source=_StubEvidenceSource(())
                    ),
                    [policy],
                    registry=None,
                    project_root=project_root,
                )

    def test_unknown_requirement_name_still_falls_back_when_authority_is_inactive(
        self,
    ):
        # authority 가 관여하지 않는 두 경로(sentinel 기본값 / 명시
        # None)는 이 변경의 영향을 받지 않는다 — 여전히 기존 존재 검사
        # fallback 대로 조용히 BLOCK 이다(authority 자체가 개입하지
        # 않으므로 UnknownCapabilityError 도 나지 않는다).
        policy = _raw_policy("p-bogus", require=["not_a_real_capability"])

        omitted = evaluator.evaluate(
            _EVENT,
            EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
            [policy],
            registry=None,
        )
        self.assertEqual(omitted.decision, DECISION_BLOCK)

        explicit_none = evaluator.evaluate(
            _EVENT,
            EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
            [policy],
            registry=None,
            project_root=None,
        )
        self.assertEqual(explicit_none.decision, DECISION_BLOCK)


# ===========================================================================
# 13b. 단축 평가(short-circuit) 회귀 방지 — Phase 6 7회차 리뷰 재현. 정책
#     단위 사전 필터(§14 절 "정책 단위 사전 필터" 참조)는 이 정책의
#     requirement 가 "전부 미전환"인지 `any(is_switched(...) for r in
#     requirements)` 로 판정한다. 6회차 구현은 이 `any()` 에 제너레이터
#     식을 바로 넘겼는데, `any()` 는 첫 True 를 만나면 단축 평가로 나머지
#     원소를 건드리지 않는다 — 전환된 유효 축이 앞에 있으면, 로더를
#     우회해 들어온 미지 capability 이름이 뒤에 있어도 그 이름의
#     `is_switched()` 가 한 번도 호출되지 않아 `UnknownCapabilityError`
#     fail-closed 검증(Medium 6-4, 위 §13 절)이 새어나갔다. 이 절은 그
#     재현을 그대로 테스트로 고정한다 — 리스트로 먼저 전부 materialize
#     한 뒤 `any()` 를 적용하는 수정이 순서와 무관하게 미지 이름을 거부
#     하는지, 그리고 그 거부가 조건 계산보다 먼저 일어나는지(resolver
#     호출 0회)를 직접 관측한다.
# ===========================================================================


class ShortCircuitDoesNotSkipUnknownCapabilityValidationTest(unittest.TestCase):
    """리뷰어 재현: 전환된 유효 축 + 미지 축 + 실패하는 조건 resolver +
    failure_mode='open' → 수정 전에는 `any()` 가 첫(전환된) requirement
    에서 True 를 반환해 단축 평가로 멈추고, 뒤의 미지 이름은
    `is_switched()` 호출조차 되지 않았다 — 정책이 "전부 미전환"이 아니라고
    (틀리지 않게) 판정돼 `when` 조건이 정상 계산되고(resolver 호출 1회),
    그 resolver 가 예외를 던지면 policy 의 `failure_mode='open'` 분기로
    흡수돼 조용히 ALLOW 가 나갔다(관측: ALLOW + resolver 1회). 기대는 미지
    이름이 조건 계산보다 먼저 fail-closed 로 거부되는 것(resolver 호출
    0회) — 수정 후에는 전환 여부를 리스트로 먼저 전부 계산하므로 미지
    이름의 `is_switched()` 가 반드시 호출되고, 그 자리에서
    `UnknownCapabilityError` 가 즉시 전파된다."""

    def _resolver_that_must_not_run(self, calls):
        def _probe(context):
            calls.append(1)
            raise EvidenceStorageError("boom — should never be called")

        resolvers = FactResolverRegistry()
        resolvers.register("probe", _probe, FACT_COST_CHEAP)
        return resolvers

    def test_switched_axis_first_unknown_axis_second_still_raises_with_zero_resolver_calls(
        self,
    ):
        calls = []
        resolvers = self._resolver_that_must_not_run(calls)

        # security_review(전환, is_switched() 첫 호출이 True 를 반환) +
        # not_a_real_capability(미지, 예전 구현이면 any() 단축 평가로
        # is_switched() 자체가 호출되지 않았을 자리).
        policy = _raw_policy(
            "p-mixed-unknown",
            require=[SECURITY_REVIEW, "not_a_real_capability"],
            failure_mode="open",
            when={"probe": "ok"},
        )
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["security_review"])

            with self.assertRaises(authority.UnknownCapabilityError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts={},
                        evidence_source=_StubEvidenceSource(()),
                        fact_resolvers=resolvers,
                    ),
                    [policy],
                    registry=registry,
                    project_root=project_root,
                )

        self.assertEqual(
            calls,
            [],
            msg=(
                "condition resolver must not run — the unknown capability "
                "name must fail closed before when-condition evaluation"
            ),
        )

    def test_unknown_axis_first_switched_axis_second_still_raises_with_zero_resolver_calls(
        self,
    ):
        # 순서 무관 — 미지 축이 앞에 있어도 동일하게 거부돼야 한다(리스트
        # materialize 는 순서와 무관하게 전체 원소를 평가하므로, require
        # 목록의 순서가 결과를 바꾸면 안 된다는 것을 별도로 고정한다).
        calls = []
        resolvers = self._resolver_that_must_not_run(calls)

        policy = _raw_policy(
            "p-mixed-unknown-2",
            require=["not_a_real_capability", SECURITY_REVIEW],
            failure_mode="open",
            when={"probe": "ok"},
        )
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["security_review"])

            with self.assertRaises(authority.UnknownCapabilityError):
                evaluator.evaluate(
                    _EVENT,
                    EvaluationContext(
                        facts={},
                        evidence_source=_StubEvidenceSource(()),
                        fact_resolvers=resolvers,
                    ),
                    [policy],
                    registry=registry,
                    project_root=project_root,
                )

        self.assertEqual(calls, [])

    def test_all_unswitched_policy_condition_still_skipped_entirely(self):
        # 회귀 방지 — 미지 이름이 전혀 없는 순수 미전환 정책은 여전히
        # 조건 계산 0회로 정책 전체를 건너뛴다(6회차 계약, materialize
        # 도입이 이 계약을 깨지 않았는지 직접 확인).
        calls = []
        resolvers = self._resolver_that_must_not_run(calls)

        policy = _policy_with_when(
            "p-probe-regression",
            "probe",
            "ok",
            require=[SECURITY_REVIEW],
            failure_mode="closed",
        )
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts={},
                    evidence_source=_StubEvidenceSource(()),
                    fact_resolvers=resolvers,
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(calls, [])
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.reason, evaluator.REASON_NO_MATCH)

    def test_authority_still_loaded_at_most_once_per_cycle_when_policy_has_unknown_capability(
        self,
    ):
        # 회귀 방지 — authority 로드는 여전히 조건 계산보다 먼저, 그리고
        # 사이클당 최대 1회다. 미지 이름을 포함한 정책에서도(즉시 예외로
        # 끝나더라도) 이 계약이 깨지지 않는지 확인한다.
        from unittest import mock

        load_calls = []
        real_load = authority.load_authority_policy

        def _counting_load(project_root=None):
            load_calls.append(project_root)
            return real_load(project_root=project_root)

        policy = _raw_policy(
            "p-mixed-unknown-3",
            require=[SECURITY_REVIEW, "not_a_real_capability"],
        )
        registry = RequirementRegistry()
        register_security_review(registry)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["security_review"])

            with mock.patch.object(
                authority, "load_authority_policy", side_effect=_counting_load
            ):
                with self.assertRaises(authority.UnknownCapabilityError):
                    evaluator.evaluate(
                        _EVENT,
                        EvaluationContext(
                            facts={}, evidence_source=_StubEvidenceSource(())
                        ),
                        [policy],
                        registry=registry,
                        project_root=project_root,
                    )

        self.assertEqual(len(load_calls), 1)


# ===========================================================================
# 12. explain — project_root 배선 (부모 추가 지시, caveat 3 해소)
# ===========================================================================


class ExplainSurfacesAuthorityBasisTest(unittest.TestCase):
    def test_run_explain_blocks_on_legacy_pass_marker_alone_when_project_root_env_is_set(
        self,
    ):
        # ③-d 갱신 — 이전 이름은
        # test_run_explain_shows_legacy_source_when_project_root_env_is_set
        # 였고 legacy PASS 표식만으로 ALLOW(reason 에 SOURCE_LEGACY 포함)
        # 를 기대했다. legacy 대체가 제거된 지금은 v2 evidence 가 없으면
        # 전체 CLI explain 경로(run_explain → run_event 배선 → evaluator)
        # 를 관통해도 BLOCK 이다 — marker 는 이 전체 경로에서도 완전히
        # 무관하다는 것을 확인한다.
        from unittest import mock

        from rein.cli import ENV_POLICY_DIR, ENV_PROJECT_ROOT
        from rein.cli.explain import run_explain

        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.makedirs(policy_dir)
            with open(
                os.path.join(policy_dir, "10-review.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write(
                    "trigger: tool.pre\nwhen:\n  tool: Bash\nrequire:\n"
                    "  - code_review\nfailure_mode: closed\n"
                )
            # 이 policy 세트가 code_review(증거 발급형)를 선언하므로
            # 버전 메타데이터가 있어야 한다 — 없으면
            # `_load_policy_version_fact` 가 설정 오류로 명시 차단한다
            # (`rein/cli/__init__.py` "Medium D" 절, Phase 6 마무리
            # 수리 워커 H — 부모 판정: 픽스처가 틀렸다, 계약이 옳다).
            with open(
                os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write("version: 1\n")
            # legacy marker 는 PASS 내용이지만 ③-d 이후로는 읽히지 않는다
            # — inert fixture, "여전히 무관함"을 이 전체 경로에서도
            # 증명하기 위해 남김.
            _write_codex_stamp(project_root, verdict="PASS")

            raw_text = (
                '{"hook_event_name": "PreToolUse", "tool_name": "Bash", '
                '"tool_input": {"command": "ls"}}'
            )
            with mock.patch.dict(
                os.environ,
                {ENV_POLICY_DIR: policy_dir, ENV_PROJECT_ROOT: project_root},
            ):
                explanation = run_explain(raw_text)

        self.assertEqual(explanation["decision"], "BLOCK")
        self.assertIn(CODE_REVIEW, explanation["basis"]["missing_requirements"])

    def test_run_explain_without_env_var_omits_authority_source_but_still_evaluates(self):
        from unittest import mock

        from rein.cli import ENV_POLICY_DIR, ENV_PROJECT_ROOT
        from rein.cli.explain import run_explain

        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.makedirs(policy_dir)
            with open(
                os.path.join(policy_dir, "10-review.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write(
                    "trigger: tool.pre\nwhen:\n  tool: Bash\nrequire:\n"
                    "  - code_review\nfailure_mode: closed\n"
                )
            # 위 테스트와 동일한 이유(Medium D) — code_review 를 선언한
            # 정책 세트에는 버전 메타데이터가 필수다.
            with open(
                os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write("version: 1\n")
            _write_codex_stamp(project_root, verdict="PASS")

            raw_text = (
                '{"hook_event_name": "PreToolUse", "tool_name": "Bash", '
                '"tool_input": {"command": "ls"}}'
            )
            with mock.patch.dict(os.environ, {ENV_POLICY_DIR: policy_dir}, clear=False):
                os.environ.pop(ENV_PROJECT_ROOT, None)
                explanation = run_explain(raw_text)

        # project_root 를 몰랐으므로 legacy PASS 표식이 있어도 authority
        # 는 개입하지 않는다(기존 존재 검사 fallback 그대로) — evidence
        # 가 없으므로 BLOCK, 그리고 그 사실이 reason 에 드러난다.
        self.assertEqual(explanation["decision"], "BLOCK")
        self.assertIn("project_root", explanation["reason"])


# ===========================================================================
# 7/8. 배선 안전장치 — sentinel 구분, run_event 환경변수 관례
# ===========================================================================


class WiringSafetyTest(unittest.TestCase):
    def test_sentinel_default_is_not_none(self):
        # evaluator.PROJECT_ROOT_NOT_PROVIDED 와 None 은 다른 객체여야
        # 한다 — 이 구분이 배선 전체의 무파손 전제다.
        self.assertIsNot(evaluator.PROJECT_ROOT_NOT_PROVIDED, None)

    def test_runtime_evaluate_without_project_root_forwards_sentinel_not_none(self):
        # runtime.evaluate 도 자신의 기본값으로 sentinel 을 쓴다 — 만약
        # None 을 기본값으로 쓰면, project_root 를 전혀 모르는 기존
        # runtime.evaluate 호출자 전부가 "시도했지만 실패" 경로로
        # 오분류돼 reason 이 오염된다.
        import inspect

        signature = inspect.signature(runtime.evaluate)
        self.assertIs(
            signature.parameters["project_root"].default,
            evaluator.PROJECT_ROOT_NOT_PROVIDED,
        )

    def test_run_event_reads_rein_project_root_env_var(self):
        from unittest import mock

        from rein.cli import ENV_PROJECT_ROOT, run_event

        self.assertEqual(ENV_PROJECT_ROOT, "REIN_PROJECT_ROOT")

        payload = (
            '{"hook_event_name": "PreToolUse", "tool_name": "Read", '
            '"tool_input": {}}'
        )
        with tempfile.TemporaryDirectory() as project_root:
            with mock.patch(
                "rein.engine.runtime.evaluate", wraps=runtime.evaluate
            ) as spy:
                with mock.patch.dict(
                    os.environ, {ENV_PROJECT_ROOT: project_root}
                ):
                    run_event(payload)
            _, kwargs = spy.call_args
            self.assertEqual(kwargs.get("project_root"), project_root)

    def test_run_event_empty_env_var_is_treated_as_unavailable_not_cwd(self):
        from unittest import mock

        from rein.cli import ENV_PROJECT_ROOT, run_event

        payload = (
            '{"hook_event_name": "PreToolUse", "tool_name": "Read", '
            '"tool_input": {}}'
        )
        with mock.patch(
            "rein.engine.runtime.evaluate", wraps=runtime.evaluate
        ) as spy:
            with mock.patch.dict(os.environ, {ENV_PROJECT_ROOT: ""}):
                run_event(payload)
        _, kwargs = spy.call_args
        self.assertIsNone(kwargs.get("project_root"))


# ===========================================================================
# 14. 미전환 축은 v2 판정 "계산 자체"를 하지 않는다 (Phase 6 5회차 리뷰
#     시정 — 4회차는 계산된 `v2_satisfied` 결과값만 결정에서 제외했을 뿐,
#     그 값을 얻기 위한 registry 호출·evidence 조회·지연 계산 resolver
#     호출은 여전히 매 requirement 마다 수행되고 있었다. 이 클래스가
#     없으면 "결과만 버린다"는 (불충분한) 구현으로도 위 4번 섹션의
#     테스트들이 전부 통과할 수 있다 — 여기서 호출 횟수 자체를 스파이로
#     계측해 "계산이 아예 일어나지 않는다"를 직접 고정한다.
# ===========================================================================


class UnswitchedCapabilitySkipsV2ComputationEntirelyTest(unittest.TestCase):
    def test_evidence_source_never_queried_for_unswitched_capability(self):
        # security_review 는 미전환 — 증거 발급형이므로 naive 구현이라면
        # `context.evidence_for(SECURITY_REVIEW)` 를 최소 1회 호출해 "v2
        # evidence 있는지" 를 먼저 확인했을 것이다. 그 호출 자체가 없어야
        # 한다.
        policy = _policy("p-security", require=[SECURITY_REVIEW])
        registry = RequirementRegistry()
        register_security_review(registry)

        source = _CountingEvidenceSource(())
        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=source),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(source.calls_by_name.get(SECURITY_REVIEW, 0), 0)

    def test_registered_implementation_never_invoked_for_unswitched_capability(self):
        # active_task 는 미전환 — 등록 구현체(`_SpyRequirement`)가 아예
        # 호출되지 않아야 한다.
        policy = _policy("p-task", require=[ACTIVE_TASK])
        registry = RequirementRegistry()
        spy = _SpyRequirement(result=True)
        registry.register(ACTIVE_TASK, spy)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts={FACT_TASK_ACTIVE: "task-1"},
                    evidence_source=_StubEvidenceSource(()),
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(spy.calls, 0)

    def test_deferred_fact_resolver_never_invoked_for_unswitched_capability(self):
        # active_task 의 등록 구현체는 `context.fact(FACT_TASK_ACTIVE)` 를
        # 조회한다 — pre-set fact 가 없으면 지연 계산 resolver 로 떨어진다.
        # 미전환이면 구현체 자체가 호출되지 않으므로 이 resolver 도 전혀
        # 실행되지 않아야 한다.
        policy = _policy("p-task", require=[ACTIVE_TASK])
        registry = RequirementRegistry()
        register_active_task(registry)

        resolver_calls = []

        def _resolve_task_active(context):
            resolver_calls.append(1)
            return "task-999"

        resolvers = FactResolverRegistry()
        resolvers.register(FACT_TASK_ACTIVE, _resolve_task_active, FACT_COST_CHEAP)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts={},
                    evidence_source=_StubEvidenceSource(()),
                    fact_resolvers=resolvers,
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(resolver_calls, [])

    def test_registered_implementation_exception_does_not_affect_decision_when_unswitched(
        self,
    ):
        # 등록 구현체가 예외(EvidenceStorageError 계열)를 던지도록 만들어도
        # 미전환이면 그 구현체가 아예 호출되지 않으므로 예외가 발생할
        # 기회조차 없다 — failure_mode='closed' 분기(BLOCK)로 흡수되지
        # 않고 정상 ALLOW 여야 한다(4회차 재현: "미전환 축의 예외가
        # 실패 분기로 흡수돼 결정에 영향을 준다" 그 자체를 반증한다).
        policy = _policy("p-task", require=[ACTIVE_TASK], failure_mode="closed")
        registry = RequirementRegistry()
        spy = _SpyRequirement(raise_error=EvidenceStorageError("boom"))
        registry.register(ACTIVE_TASK, spy)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts={FACT_TASK_ACTIVE: "task-1"},
                    evidence_source=_StubEvidenceSource(()),
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(spy.calls, 0)

    def test_switched_capability_registered_implementation_is_invoked_normally(self):
        # 대조군 — 전환된 capability 는 여전히 정상적으로 등록 구현체를
        # 호출한다("항상 0회"로 퇴화하지 않았음을 확인).
        policy = _policy("p-task", require=[ACTIVE_TASK])
        registry = RequirementRegistry()
        spy = _SpyRequirement(result=True)
        registry.register(ACTIVE_TASK, spy)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review", "active_task"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(spy.calls, 1)

    def test_mixed_policy_switched_axis_still_blocks_while_unswitched_spy_untouched(
        self,
    ):
        # 전환/미전환 혼재 — code_review(전환, legacy FAIL → BLOCK 재료)
        # + active_task(미전환, 등록 구현체는 스파이). 전환된 축은
        # 정상적으로 평가돼 BLOCK 하고, 미전환 축의 스파이는 단 한 번도
        # 호출되지 않는다.
        _, _, facts = _code_review_setup()
        policy = _policy("p-mixed", require=[CODE_REVIEW, ACTIVE_TASK])
        registry = _code_review_registry()
        spy = _SpyRequirement(result=True)
        registry.register(ACTIVE_TASK, spy)

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])
            _write_codex_stamp(project_root, verdict="NEEDS-FIX")

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts=facts, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))
        self.assertEqual(spy.calls, 0)

    def test_mixed_policy_all_satisfied_switched_evaluated_unswitched_skipped(self):
        # 전환/미전환 혼재의 통과 방향 — code_review(전환, 실제 v2
        # evidence → 충족) + active_task(미전환, 스파이가 호출되면
        # False 를 반환해 BLOCK 을 유발했을 상황) 모두 통과해야 한다.
        # 스파이가 호출되지 않는 것 자체가 "미전환은 제외"가 여전히
        # 유효함을 보여준다. **③-d 갱신** — 이전에는 code_review 가
        # legacy PASS marker 만으로 충족됐다; legacy 대체가 사라진
        # 지금은 실제 v2 evidence 가 있어야 한다.
        policy = _policy("p-mixed", require=[CODE_REVIEW, ACTIVE_TASK])
        registry = _code_review_registry()
        spy = _SpyRequirement(result=False)
        registry.register(ACTIVE_TASK, spy)
        _, _, facts = _code_review_setup()
        evidence = issue_code_review_evidence(
            {
                "verdict": "PASS",
                "reviewed_digest": facts[FACT_CHANGESET_REVIEW_DIGEST],
            },
            current_digest=facts[FACT_CHANGESET_REVIEW_DIGEST],
            policy_version=facts[REVIEW_POLICY_VERSION],
        )

        with tempfile.TemporaryDirectory() as project_root:
            _write_authority_policy(project_root, ["code_review"])

            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts=facts, evidence_source=_StubEvidenceSource((evidence,))
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())
        self.assertEqual(spy.calls, 0)


# ===========================================================================
# 15. 한 번만 순회 가능한 require 입력 — 사전 필터가 목록을 소비해버리는
#     결함 (Phase 6 8회차 리뷰 재현. evaluator.py 의 8회차 시정 주석 참조).
#     7회차는 전환 여부를 리스트로 미리 전부 계산(materialize)하도록
#     고쳤는데, 그 계산 자체가 `require` 원본 이터레이터를 소비해버렸다.
#     정상 로더는 항상 tuple 을 반환하므로 실사용 경로는 영향이 없지만,
#     "로더 우회 입력도 fail-closed 로 막는다"는 이 스위트의 명시적 계약
#     (§13 `_raw_policy` 절)이 깨진다 — 로더를 거치지 않고 `require` 에
#     한 번만 순회 가능한 값(제너레이터, `iter()`)을 넣으면 사전 필터
#     컴프리헨션이 그 값을 전부 소진하고, 그 뒤의 실제 판정 loop
#     (`for requirement in requirements:`)는 빈 것을 순회해 조용히
#     ALLOW 로 샌다. 리뷰어 재현: `require=('code_review',)` 는 BLOCK,
#     `require=iter(('code_review',))` 는 ALLOW.
# ===========================================================================


def _raw_policy_with_require_object(
    policy_id, require_obj, failure_mode="closed", when=None
):
    """`_raw_policy` 와 달리 `require` 를 `tuple()` 로 감싸지 않고 그대로
    싣는다 — 호출자가 넘긴 값(제너레이터·`iter()` 등 한 번만 순회
    가능한 객체 포함)의 정체를 그대로 보존해야, "로더를 거치지 않고
    한 번만 순회 가능한 값이 들어왔을 때"를 재현할 수 있다."""
    return {
        "policy_id": policy_id,
        "fields": {
            "trigger": _EVENT,
            "when": dict(when) if when else {},
            "require": require_obj,
            "failure_mode": failure_mode,
        },
    }


class SinglePassRequireIterableTest(unittest.TestCase):
    """`require` 가 tuple/list 가 아니라 한 번만 순회 가능한 이터레이터로
    들어와도 사전 필터(전환 여부 계산)와 실제 판정 loop 이 동일한 결과를
    내야 한다 — 어느 한쪽이 목록을 먼저 소비해 다른 쪽이 빈 것을 순회하는
    일이 없어야 한다."""

    def test_single_pass_iterator_requirement_still_blocks(self):
        registry = _code_review_registry()
        policy = _raw_policy_with_require_object(
            "p-single-pass", iter((CODE_REVIEW,))
        )

        with tempfile.TemporaryDirectory() as project_root:
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_single_pass_generator_requirement_matches_tuple_equivalent(self):
        # tuple 로 넣었을 때와 제너레이터로 넣었을 때가 decision 전체
        # (missing_requirements 내용까지) byte-identical 해야 한다 —
        # 자료형만 다를 뿐 논리적으로 같은 입력이므로.
        registry = _code_review_registry()

        with tempfile.TemporaryDirectory() as project_root:
            tuple_decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [_raw_policy_with_require_object("p-tuple", (CODE_REVIEW,))],
                registry=registry,
                project_root=project_root,
            )
            generator_decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(facts={}, evidence_source=_StubEvidenceSource(())),
                [
                    _raw_policy_with_require_object(
                        "p-tuple", (x for x in (CODE_REVIEW,))
                    )
                ],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(tuple_decision.decision, generator_decision.decision)
        self.assertEqual(
            tuple_decision.missing_requirements,
            generator_decision.missing_requirements,
        )
        self.assertEqual(tuple_decision.reason, generator_decision.reason)

    def test_single_pass_iterator_requirement_satisfied_still_allows(self):
        # 통과 방향도 확인 — 실제 v2 evidence 로 충족되는 경우, 소비
        # 결함이 있었다면 우연히 ALLOW 가 나왔을 수 있으므로
        # missing_requirements 가 정말로 빈 것인지 고정한다(우연한
        # 통과와 정상 통과를 구분). **③-d 갱신** — 이전에는 legacy
        # PASS marker 만으로 충족(reason 에 SOURCE_LEGACY)됐다; legacy
        # 대체가 사라진 지금은 실제 v2 evidence 가 필요하고, 결과가
        # 바뀌지 않았으므로(SOURCE_V2) reason 에는 authority note 가
        # 없다.
        registry = _code_review_registry()
        policy = _raw_policy_with_require_object(
            "p-single-pass-ok", iter((CODE_REVIEW,))
        )
        _, _, facts = _code_review_setup()
        evidence = issue_code_review_evidence(
            {
                "verdict": "PASS",
                "reviewed_digest": facts[FACT_CHANGESET_REVIEW_DIGEST],
            },
            current_digest=facts[FACT_CHANGESET_REVIEW_DIGEST],
            policy_version=facts[REVIEW_POLICY_VERSION],
        )

        with tempfile.TemporaryDirectory() as project_root:
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts=facts, evidence_source=_StubEvidenceSource((evidence,))
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())


if __name__ == "__main__":
    unittest.main()
