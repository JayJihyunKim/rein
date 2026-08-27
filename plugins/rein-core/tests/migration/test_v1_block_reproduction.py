"""v1 BLOCK 재현 테스트 — Task 6.0 진입 증거 (dod-2026-08-12-v2-phase6-authority.md).

목적: Phase 6 authority 전환 착수 전, corpus(`.rein/state/shadow-corpus.jsonl`)
에서 확인된 v1 실제 BLOCK 16건이 (A) v2 Governance Runtime 5-capability
(active_task/tests_passed/code_review/security_review/user_approval) 소관으로
재현 가능한지, 또는 (B) v2 가 관여하지 않는 v1 존속 기능인지를 행위 테스트로
고정한다.

배경 (사용자 결정 2026-08-12): 수집된 corpus 3966건의 `facts` 필드가 전부
`{"hook": "<이름>"}` 뿐이라 v2 평가에 넘길 재료가 없어 자동 Shadow Replay 대조가
성립하지 않는다. corpus 의 v1 BLOCK 16건을 재현 테스트로 개별 고정해 진입
증거로 삼고, 캡처 계층 보강(v1 hook 에서 실제 fact 를 기록하도록 하는 작업)은
후속 항목으로 분리한다.

판정 대장: docs/reports/v2-v1-block-reproduction.md (corpus 줄번호별 판정 근거
+ 이 파일의 어느 테스트가 어느 corpus 줄을 커버하는지 매핑).

corpus 원본 파일은 이 테스트가 직접 읽거나 참조하지 않는다 — 사적 절대경로가
섞여 있으므로, 재현에 필요한 fact 만 이 파일에 명시적으로 구성한다(실 파일
fixture 는 tempfile 로만 만든다 — 저장소의 실제 `trail/`·`.rein/` 은 절대
건드리지 않는다).
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

from rein.capabilities.review.capability import (  # noqa: E402
    FACT_CHANGESET_REVIEW_DIGEST,
    FACT_POLICY_VERSION as CODE_REVIEW_POLICY_VERSION,
    REQUIREMENT_NAME as CODE_REVIEW,
    VERDICT_PASS as CODE_REVIEW_PASS,
    issue_code_review_evidence,
    register_code_review,
)
from rein.capabilities.security.capability import (  # noqa: E402
    FACT_CHANGESET_SENSITIVE_DIGEST,
    FACT_POLICY_VERSION as SECURITY_POLICY_VERSION,
    REQUIREMENT_NAME as SECURITY_REVIEW,
    VERDICT_PASS as SECURITY_REVIEW_PASS,
    issue_security_review_evidence,
    register_security_review,
)
from rein.engine import evaluator, runtime  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.changeset import content_digest  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK  # noqa: E402

_EVENT = "tool.pre"


class _StubEvidenceSource:
    """조회는 항상 정상 수행되는 evidence 소스 — type 별로 분류해 반환."""

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        return tuple(
            record for record in self._records if record.type == requirement_name
        )


def _policy(text, policy_id, source):
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(text, source=source),
    }


def _fs_reader(base):
    def read_content(path):
        try:
            with open(os.path.join(base, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    return read_content


# ===========================================================================
# Class A — v2 5-capability 소관: v1 BLOCK 이 v2 evaluator 로도 재현돼야 한다.
# ===========================================================================


class SecurityReviewStaleReproductionTest(unittest.TestCase):
    """corpus 줄 3648, 3651 — pre-bash-test-commit-gate SECURITY_REVIEW_STALE.

    v1 조건 (`plugins/rein-core/hooks/pre-bash-test-commit-gate.sh`
    `check_review_stamp()` 의 M2 비교, 주석 원문): "The recorded security
    review is stale relative to the codex review (older, different cycle,
    empty cycle, or unreadable)". `trail/dod/.security-reviewed` 표식은
    존재하지만 최신 codex 리뷰 cycle 과 어긋나 commit 직전 BLOCK 한다.

    v2 대응: `security_review` capability 의 validity 결합 — 발급 당시
    sensitive digest·policy_version 이 평가 시점의 현재 값과 어긋나면
    재확인 시점에 미충족이다 (`rein/capabilities/security/capability.py`
    `SecurityReviewRequirement.evaluate` 의 두 독립 무효화 축, spec §3.4).
    v1 의 "older"(코드 변경)는 digest 축, "different cycle"(리뷰 사이클
    갈림)은 policy_version 축에 대응한다 — 이 테스트는 두 축을 각각 직접
    재현한다.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.path = os.path.join(self.base, "config", "secrets.env")
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "wb") as handle:
            handle.write(b"API_KEY=old\n")
        self.reader = _fs_reader(self.base)
        self.digest = content_digest(("config/secrets.env",), self.reader)
        self.policy = _policy(
            "trigger: tool.pre\nrequire:\n  - security_review\n"
            "failure_mode: closed\n",
            "security-gate",
            "<test:security-gate-stale>",
        )
        self.registry = RequirementRegistry()
        register_security_review(self.registry)

    def _facts(self, digest, version="1"):
        return {
            FACT_CHANGESET_SENSITIVE_DIGEST: digest,
            SECURITY_POLICY_VERSION: version,
        }

    def _issue(self, digest, version="1"):
        return issue_security_review_evidence(
            {"verdict": SECURITY_REVIEW_PASS, "reviewed_digest": digest},
            current_sensitive_digest=digest,
            policy_version=version,
        )

    def test_stale_by_digest_drift_blocks(self):
        # v1 "older" — 리뷰 시점 digest 로 발급된 evidence 를, 코드가 그
        # 뒤 다시 바뀐(현재 digest 가 달라진) 상태에서 재평가.
        evidence = self._issue(self.digest)
        with open(self.path, "wb") as handle:
            handle.write(b"API_KEY=new\n")
        current = content_digest(("config/secrets.env",), self.reader)
        self.assertNotEqual(current, self.digest)

        context = EvaluationContext(
            facts=self._facts(current),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            _EVENT, context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (SECURITY_REVIEW,))

    def test_stale_by_policy_version_drift_blocks(self):
        # v1 "different cycle" — 같은 코드(digest 불변)라도 리뷰
        # cycle(policy version)이 갈리면 재확인 시점에 무효.
        evidence = self._issue(self.digest, version="1")
        context = EvaluationContext(
            facts=self._facts(self.digest, version="2"),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            _EVENT, context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (SECURITY_REVIEW,))

    def test_fresh_matching_evidence_allows(self):
        # 대조 — digest·version 둘 다 일치하는 신선한 evidence 는 통과
        # (stale 이 아니면 v1 도 v2 도 막지 않는다).
        evidence = self._issue(self.digest, version="1")
        context = EvaluationContext(
            facts=self._facts(self.digest, version="1"),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            _EVENT, context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_runtime_dict_interface_reproduces_the_block(self):
        # cli 계약(runtime.evaluate dict 인터페이스)에서도 동일 BLOCK.
        evidence = self._issue(self.digest, version="1")
        result = runtime.evaluate(
            _EVENT,
            self._facts(self.digest, version="2"),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)
        self.assertEqual(result["missing_requirements"], [SECURITY_REVIEW])


class SpecReviewEvidenceReproductionTest(unittest.TestCase):
    """corpus 줄 2571, 2577, 2608, 3400, 3406, 3409 — pre-edit-dod-gate
    "미리뷰 사양 문서" (Spec review gate, GSD-1/GSD-2).

    v1 조건: `trail/dod/.spec-reviews/*.pending` 표식이 있는 스펙/플랜
    문서가 활성 작업과 관련되어 있고(`_spec_related_to_active_work`) 대응
    `*.reviewed` 표식이 없거나 stale 이면, 관련 있는 경우에만 소스 편집
    자체를 BLOCK 한다(무관이면 경고만 — spec §6.3 표 1행).

    v2 대응은 `active_task` 가 아니라 `code_review` 다.
    `rein/capabilities/task/capability.py` 의 모듈 docstring 이 명시적으로
    선을 긋는다(원문 인용): "관련성 축소는 spec-review 계열의 별도 관심사
    였고 이 Requirement 의 전신이 아니다." 즉 "task 가 존재하면 관련성과
    무관하게 항상 충족"이 `active_task` 의 계약이고(무관 문서 대량잠금
    버그 재발 방지), "문서 자체가 리뷰됐는가"는 `code_review` capability
    의 digest 결합 Evidence 모델로 재현한다 — 이 테스트의 subject digest
    는 코드 파일이 아니라 v1 이 pending 으로 추적하던 스펙/플랜 문서 자체
    의 digest 다.

    한계 (정직히 명시): 이 테스트는 "문서가 리뷰됐는가" evidence 축만
    재현한다. "무관 문서는 차단하지 않는다"는 relevance 축은 이미
    `tests/contract/test_active_task_relevance.py` 가 `active_task` 축으로
    고정하고 있고, 두 축(문서 리뷰 evidence + 관련성 필터)을 하나의 Policy
    로 결합하는 정확한 배선(예: fact resolver 가 편집 중인 파일 대신 어느
    스펙 digest 를 `code_review` 대상으로 삼는가)은 Task 6.2 대장에서
    확정할 설계 결정이며, 이 워커(Task 6.0)는 그 배선을 선취하지 않는다.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        # v1 corpus 의 실제 pending 대상과 동형인 스펙/플랜 문서 픽스처
        # (예: docs/plans/2026-08-08-rein-v2-governance-orchestration.md).
        self.path = os.path.join(self.base, "docs", "plans", "phase.md")
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "wb") as handle:
            handle.write(b"# Phase Plan\n")
        self.reader = _fs_reader(self.base)
        self.digest = content_digest(("docs/plans/phase.md",), self.reader)
        self.policy = _policy(
            "trigger: tool.pre\nrequire:\n  - code_review\n"
            "failure_mode: closed\n",
            "spec-review-gate",
            "<test:spec-review-gate>",
        )
        self.registry = RequirementRegistry()
        register_code_review(self.registry)

    def _facts(self, digest, version="1"):
        return {
            FACT_CHANGESET_REVIEW_DIGEST: digest,
            CODE_REVIEW_POLICY_VERSION: version,
        }

    def test_pending_unreviewed_spec_blocks_related_source_edit(self):
        context = EvaluationContext(
            facts=self._facts(self.digest),
            evidence_source=_StubEvidenceSource(()),
        )
        decision = evaluator.evaluate(
            _EVENT, context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_reviewed_spec_allows(self):
        evidence = issue_code_review_evidence(
            {"verdict": CODE_REVIEW_PASS, "reviewed_digest": self.digest},
            current_digest=self.digest,
            policy_version="1",
        )
        context = EvaluationContext(
            facts=self._facts(self.digest),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            _EVENT, context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_re_edited_spec_after_review_blocks_again(self):
        # v1 SR-1 (스펙 재편집 시 재차 pending) 과 동형 — 리뷰 후 문서가
        # 또 수정되면 digest 가 달라져 같은 evidence 로는 재충족되지
        # 않는다.
        evidence = issue_code_review_evidence(
            {"verdict": CODE_REVIEW_PASS, "reviewed_digest": self.digest},
            current_digest=self.digest,
            policy_version="1",
        )
        with open(self.path, "ab") as handle:
            handle.write(b"more content\n")
        current = content_digest(("docs/plans/phase.md",), self.reader)
        self.assertNotEqual(current, self.digest)

        context = EvaluationContext(
            facts=self._facts(current),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            _EVENT, context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_runtime_dict_interface_reproduces_the_block(self):
        result = runtime.evaluate(
            _EVENT,
            self._facts(self.digest),
            [self.policy],
            evidence_source=_StubEvidenceSource(()),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)
        self.assertEqual(result["missing_requirements"], [CODE_REVIEW])


# ===========================================================================
# Class B — v1 존속 기능: v2 가 관여하지 않는 것이 정상이다.
# ===========================================================================


class _V1PersistingMechanismTestMixin:
    """B급 공통 패턴.

    두 사실을 함께 고정한다:
    1. 이 이름은 v2 의 고정 5종 Requirement 밖이므로, policy 선언 자체가
       로드 시점에 거부된다(closed registry, `rein/kernel/requirement.py`
       `REQUIREMENT_NAMES`) — v2 가 이 상황을 Requirement 로 표현할
       방법이 구조적으로 없다는 사실을 코드로 고정.
    2. 대응 Requirement/Policy 가 v2 에 아예 없으므로, 이 상황을 나타내는
       fact 를 쥐어줘도(실제 hook 이 이런 fact 를 v2 로 넘길 계획도 없다
       — v1 훅이 계속 판정을 전담) `evaluate()` 는 매칭되는 policy 가
       없어 ALLOW 다. 이 ALLOW 는 v2 의 결함이 아니라 "이 판정은 v1
       소관" 이라는 설계다 — 실제 차단은 여전히 v1 훅이 수행한다(각
       서브클래스 docstring 의 근거 참조).
    """

    custom_name = None  # subclass 오버라이드
    facts = None

    def test_custom_requirement_name_is_rejected_at_policy_load(self):
        with self.assertRaises(kernel_policy.PolicyLoadError):
            kernel_policy.parse_policy(
                "trigger: tool.pre\nrequire:\n  - {}\n"
                "failure_mode: closed\n".format(self.custom_name),
                source="<test:{}>".format(self.custom_name),
            )

    def test_v2_quietly_allows_with_no_policy_modeling_this(self):
        result = runtime.evaluate(_EVENT, dict(self.facts), [])
        self.assertEqual(result["decision"], DECISION_ALLOW)
        self.assertEqual(result["reason"], evaluator.REASON_NO_MATCH)


class RoutingApprovalIsV1OnlyTest(
    _V1PersistingMechanismTestMixin, unittest.TestCase
):
    """corpus 줄 2425, 2428, 2429, 2432, 2447 — pre-edit-dod-gate
    "routing section 위반" (`## 라우팅 추천` 섹션에 `approved_by_user:
    true` 없음).

    spec §제외(v2.0 비범위) 표: "Routing / Trail Aggregation / Persona /
    Meta-check | v1 기능 유지 — Governance/Orchestration 본체와 독립, v2
    이관 이득이 당장 없음"
    (docs/specs/2026-08-07-rein-v2-governance-orchestration.md 표 행).
    plan Task 7.1(docs/plans/2026-08-08-rein-v2-governance-orchestration.md)
    은 `pre-edit-dod-gate.sh` 전체를 삭제 대상으로 명시하되 "비이관 기능
    분리 보존 확인" 절이 이런 v1 존속 기능은 분리해 존속시킨 뒤 제거하라고
    지시한다 — routing 판정 자체가 v2 Requirement 가 되는 것이 아니라
    별도 메커니즘으로 v1 쪽에 남는다.
    """

    custom_name = "routing_approval"
    facts = {"dod.routing_section_approved": False}


class IncidentReviewIsV1OnlyTest(
    _V1PersistingMechanismTestMixin, unittest.TestCase
):
    """corpus 줄 3547, 3552 — pre-edit-dod-gate "incident review pending"
    (미해결 incident 존재, `trail/dod/.incident-review-pending` 표식).

    spec §제외(v2.0 비범위) 표: "Incident→Rule / Incident→Agent / Agent
    Evolution | v1 스킬 유지 — v2.x 에서 Evidence/Ledger 기반 재구축
    후보" (동일 spec 파일 표).
    """

    custom_name = "incident_review_pending"
    facts = {"incident.pending_count": 3}


class DestructiveGitConfirmIsV1OnlyTest(
    _V1PersistingMechanismTestMixin, unittest.TestCase
):
    """corpus 줄 648 — pre-bash-safety-guard DESTRUCTIVE_GIT_CONFIRM
    (`git reset --hard`/`push --force`/`checkout --`/`restore` 류 확인
    요청).

    판단 보류에 가까운 사례 — spec 의 "제외 (v2.0 비범위)" 표에 이 항목이
    문자 그대로 명명되어 있지는 않다. 그러나 두 근거로 "v1 전용 잔존"
    으로 분류한다:

    (1) Requirement 는 고정 5종(active_task/tests_passed/code_review/
        security_review/user_approval, spec §3.4 "Requirement 폐쇄")뿐
        이다 — "파괴적 명령 실행 전 사용자 확인"은 Evidence·digest 결합
        모델에 맞지 않는 실시간 행동 규범(mistake-prevention nudge)이라
        애초에 이 5종 어디에도 속하지 않는다.
    (2) plan Task 7.1 의 legacy hook 삭제 목록(`pre-edit-dod-gate.sh` /
        `pre-bash-test-commit-gate.sh` / `post-edit-review-gate.sh` /
        `post-edit-spec-review-gate.sh`)에 `pre-bash-safety-guard.sh` 는
        포함돼 있지 않다 — Phase 7 이후에도 존속이 계획돼 있다.

    이 판단은 이 워커(Task 6.0)의 잠정 결론이며, spec 원저자의 명시적
    확인이 있는 것은 아니라는 점을 판정 대장(docs/reports/
    v2-v1-block-reproduction.md)에 별도 표시한다 — 문서 갭 후속 필요
    사항이지, Phase 6 진입을 막는 사유는 아니다(v1 이 계속 이 check 를
    집행하므로 false-allow 위험이 없다).
    """

    custom_name = "destructive_git_confirm"
    facts = {"command.type": "git.restore"}


if __name__ == "__main__":
    unittest.main()
