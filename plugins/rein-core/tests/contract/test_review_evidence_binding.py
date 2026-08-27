"""plan Task 3.1 — code_review Evidence 는 Runtime 만 발급 (spec §2.2, §3.6).

Reviewer 가 PASS 를 반환하는 것만으로는 code_review Evidence 가 생기지
않는다 — Runtime 이 structured review response 를 직접 파싱해, 리뷰가 본
code digest 와 현재 code digest 를 결합(비교)해서만 발급한다 (spec §3.6:
"Reviewer PASS 반환만으로 Evidence 자동 인정 안 됨 — Runtime 이 현재
digest 와 결합해 발급"). 리뷰 후 코드가 수정되면(digest 불일치) 발급을
명시 거부한다 — None 반환 같은 침묵 실패가 아니라 구분 가능한 예외다.

검증 축:
- 발급 게이트: verdict + digest 결합 페어 판정 (PASS·일치만 통과).
- strict 파싱: 필수 필드 결손·형식 위반은 관대한 해석 없이 거부 (spec
  §2.2 — structured response 를 Runtime 이 직접 파싱해 검증 강도 확보).
- 평가 결합: 발급된 Evidence 라도 evaluate 시점에 subject 가 현재 digest
  와 일치해야 충족 — evidence 존재만으로는 충족이 아니다.
- policy version 축 (리뷰 1회차 시정): digest 와 독립인 두 번째 무효화
  축 (spec §3.4) — 같은 digest 라도 version 불일치면 미충족, 호환 선언
  (`compatible_versions`)에 명시된 이전 version 만 인정.
- evaluator 관통 (리뷰 1회차 시정): registry 배선 시 실제
  `engine.evaluator.evaluate()` 가 stale digest evidence 를 BLOCK,
  결합 유효 evidence 를 ALLOW 로 판정한다.
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
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    MalformedReviewResponse,
    REQUIREMENT_NAME,
    ReviewDigestMismatch,
    ReviewEvidenceRefusal,
    ReviewVerdictNotPass,
    VERDICT_PASS,
    CodeReviewRequirement,
    issue_code_review_evidence,
    register_code_review,
)
from rein.engine import evaluator, runtime  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.changeset import (  # noqa: E402
    SUBJECT_EMPTY,
    SUBJECT_UNRESOLVED,
    content_digest,
)
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_BLOCK,
)
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
)


def _fs_reader(base):
    def read_content(path):
        try:
            with open(os.path.join(base, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    return read_content


class _StubEvidenceSource:
    """조회는 항상 정상 수행되는 evidence 소스 (부재/존재만 제어)."""

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        if requirement_name == REQUIREMENT_NAME:
            return self._records
        return ()


class _ReviewedFileMixin(unittest.TestCase):
    """리뷰 대상 파일 1개를 실제로 수정해 digest 변화를 만드는 공통 준비."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.path = os.path.join(self.base, "mod.py")
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 1\n")
        self.reader = _fs_reader(self.base)
        self.reviewed_digest = self._current_digest()

    def _current_digest(self):
        return content_digest(("mod.py",), self.reader)

    def _edit_code(self):
        """리뷰 후 코드 수정 시뮬레이션 — 현재 digest 가 달라진다."""
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 2\n")

    def _response(self, verdict=VERDICT_PASS, reviewed_digest=None):
        """Reviewer 가 반환하는 structured review response."""
        if reviewed_digest is None:
            reviewed_digest = self.reviewed_digest
        return {"verdict": verdict, "reviewed_digest": reviewed_digest}

    def _context(
        self, records, digest=None, policy_version="1", compatible=None
    ):
        """digest·version fact + evidence 소스를 담은 평가 컨텍스트."""
        facts = {}
        if digest is not None:
            facts[FACT_CHANGESET_REVIEW_DIGEST] = digest
        if policy_version is not None:
            facts[FACT_POLICY_VERSION] = policy_version
        if compatible is not None:
            facts[FACT_POLICY_COMPATIBLE_VERSIONS] = tuple(compatible)
        return EvaluationContext(
            facts=facts, evidence_source=_StubEvidenceSource(records)
        )


class RuntimeIssuanceTest(_ReviewedFileMixin):
    """(a)~(c) — verdict + digest 결합 페어가 발급을 결정한다."""

    def test_pass_with_matching_digest_issues_evidence(self):
        # (a) verdict PASS + 리뷰 digest == 현재 digest → 발급
        evidence = issue_code_review_evidence(
            self._response(),
            current_digest=self._current_digest(),
            policy_version="1",
        )
        self.assertEqual(evidence.type, REQUIREMENT_NAME)
        self.assertEqual(evidence.subject, self.reviewed_digest)
        self.assertEqual(evidence.result, VERDICT_PASS)
        # 리뷰 판단은 독립적인 암호학적 증명이 아니다 (spec §2.2) —
        # producer 는 runtime_verified 가 아니라 agent_attested 다
        self.assertEqual(evidence.producer, PRODUCER_AGENT_ATTESTED)
        self.assertEqual(evidence.policy_version, "1")

    def test_digest_mismatch_after_edit_refuses_issuance(self):
        # (b) 리뷰 후 코드 수정 → 리뷰가 본 digest ≠ 현재 digest → 미발급.
        # 거부는 None 반환이 아니라 구분 가능한 예외다 (침묵 실패 금지)
        response = self._response()
        self._edit_code()
        current = self._current_digest()
        self.assertNotEqual(current, self.reviewed_digest)
        with self.assertRaises(ReviewDigestMismatch):
            issue_code_review_evidence(
                response, current_digest=current, policy_version="1"
            )

    def test_non_pass_verdict_refuses_even_with_matching_digest(self):
        # (c) digest 가 일치해도 verdict 가 PASS 가 아니면 미발급
        with self.assertRaises(ReviewVerdictNotPass):
            issue_code_review_evidence(
                self._response(verdict="NEEDS-FIX"),
                current_digest=self._current_digest(),
                policy_version="1",
            )

    def test_verdict_matching_is_strict_not_lenient(self):
        # 관대한 해석 금지 — 대소문자·공백 변형을 PASS 로 승격하지 않는다
        for verdict in ("pass", "Pass", " PASS", "PASS "):
            with self.assertRaises(ReviewVerdictNotPass):
                issue_code_review_evidence(
                    self._response(verdict=verdict),
                    current_digest=self._current_digest(),
                    policy_version="1",
                )

    def test_refusals_share_a_distinguishable_base(self):
        # 호출자(Runtime)가 "발급 거부" 부류 전체를 한 계약으로 잡을 수
        # 있어야 한다 — 세 거부 사유는 공통 base 의 하위 타입이다
        self.assertTrue(issubclass(ReviewDigestMismatch, ReviewEvidenceRefusal))
        self.assertTrue(issubclass(ReviewVerdictNotPass, ReviewEvidenceRefusal))
        self.assertTrue(
            issubclass(MalformedReviewResponse, ReviewEvidenceRefusal)
        )


class StructuredResponseParsingTest(_ReviewedFileMixin):
    """(d) — 파싱 불가·필수 필드 결손은 관대한 해석 없이 미발급."""

    def _assert_malformed(self, response):
        with self.assertRaises(MalformedReviewResponse):
            issue_code_review_evidence(
                response,
                current_digest=self._current_digest(),
                policy_version="1",
            )

    def test_non_mapping_response_is_refused(self):
        # 자유 텍스트 "PASS" 를 structured response 로 승격하지 않는다
        self._assert_malformed("PASS")
        self._assert_malformed(None)
        self._assert_malformed(["PASS", self.reviewed_digest])

    def test_missing_required_fields_are_refused(self):
        self._assert_malformed({})
        self._assert_malformed({"verdict": VERDICT_PASS})  # digest 결손
        self._assert_malformed(
            {"reviewed_digest": self.reviewed_digest}  # verdict 결손
        )

    def test_empty_or_non_string_fields_are_refused(self):
        self._assert_malformed(self._response(verdict=""))
        self._assert_malformed(self._response(reviewed_digest=""))
        self._assert_malformed(self._response(verdict=True))
        self._assert_malformed(self._response(reviewed_digest=42))


class RegistryEvaluationTest(_ReviewedFileMixin):
    """(e) — 등록된 capability 의 evaluate 가 digest 재확인 후 충족 판정."""

    def test_registration_is_explicit_not_import_side_effect(self):
        # import 는 이미 모듈 상단에서 일어났다 — 그럼에도 새 registry 가
        # 비어 있어야 "등록은 명시적 코드 등록" 계약(spec §3.1 §32)이 성립
        registry = RequirementRegistry()
        self.assertFalse(registry.is_registered(REQUIREMENT_NAME))
        implementation = register_code_review(registry)
        self.assertTrue(registry.is_registered(REQUIREMENT_NAME))
        self.assertIs(registry.resolve(REQUIREMENT_NAME), implementation)
        self.assertEqual(implementation.name, REQUIREMENT_NAME)
        self.assertIsInstance(implementation, CodeReviewRequirement)

    def test_issued_evidence_satisfies_at_same_digest(self):
        # 발급 → 등록 → evaluate 충족의 정상 경로 1건 (digest 불변)
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        registry = RequirementRegistry()
        register_code_review(registry)
        requirement = registry.resolve(REQUIREMENT_NAME)
        self.assertTrue(
            requirement.evaluate(self._context((evidence,), digest=digest))
        )

    def test_evidence_alone_is_not_satisfaction_after_edit(self):
        # evidence 존재만으로 충족 아님 — 발급 후 코드가 또 수정되면
        # subject ≠ 현재 digest 이므로 재평가는 미충족이다.
        #
        # **픽스처 전제 명시(2026-08-20, spec §3.6 판정 상태표 개정 항목
        # `evidence-expires-when-subject-digest-changes-after-creation`
        # 참조)**: `CodeReviewRequirement.evaluate()` 를 직접 호출하고
        # `evaluator.evaluate(..., project_root=...)` 를 거치지 않으므로
        # authority dual-read·legacy marker 자체가 도달 범위 밖이다 —
        # "legacy 표식 부재" 전제가 구조적으로 항상 성립한다. stale
        # 증거 + 신선 legacy 조합의 최종 dual-read 판정(전환기 legacy
        # 대체)은 `tests/migration/
        # test_authority_valid_evidence_state_table.py` 의 authority
        # Scope 행 소관이다.
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        self._edit_code()
        current = self._current_digest()
        self.assertNotEqual(current, digest)
        requirement = CodeReviewRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((evidence,), digest=current))
        )

    def test_absent_evidence_is_unmet(self):
        requirement = CodeReviewRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((), digest=self._current_digest())
            )
        )

    def test_non_pass_result_record_does_not_satisfy(self):
        # 발급 경로를 우회해 만들어진 non-PASS 레코드는 digest 가 일치해도
        # 충족 재료가 아니다 (평가도 결과 어휘를 재확인한다)
        digest = self._current_digest()
        record = Evidence(
            type=REQUIREMENT_NAME,
            subject=digest,
            result="NEEDS-FIX",
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_AGENT_ATTESTED,
            policy_version="1",
        )
        requirement = CodeReviewRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((record,), digest=digest))
        )

    def test_unknown_current_digest_is_conservatively_unmet(self):
        # 현재 digest fact 를 확보하지 못하면 결합 재확인이 불가능하다 —
        # 확인 불가를 충족으로 승격하지 않는다 (보수적 미충족)
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        requirement = CodeReviewRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((evidence,), digest=None))
        )


class PolicyVersionAxisTest(_ReviewedFileMixin):
    """리뷰 1회차 지적 1 — digest 와 독립인 policy version 축 (spec §3.4).

    같은 digest 라도 Evidence 의 policy_version 이 현재 version 과 다르면
    미충족이다 — 호환 선언(`compatible_versions` fact)에 **명시**된
    version 만 인정한다 (kernel `policy_version_valid` 재사용, 재구현
    금지). version fact 미확보는 digest 미확보와 같은 방향 — 확인 불가를
    충족으로 승격하지 않는다 (보수적 미충족).

    **픽스처 전제 명시(2026-08-20, spec §3.6 판정 상태표 개정 항목
    `evidence-with-mismatched-policy-version-is-invalid-unless-compat-
    declared` 참조)**: 이 클래스는 `CodeReviewRequirement.evaluate()` 를
    직접 호출한다 — `evaluator.evaluate(..., project_root=...)` 를 거치지
    않으므로 authority dual-read·legacy marker 자체가 이 테스트의 도달
    범위 밖이다(trail/ 디렉토리도, project_root 도 만들지 않는다). 즉
    "legacy 표식 부재" 전제가 구조적으로 항상 성립한다 — 무효 v2 증거
    + 신선 legacy 조합의 최종 dual-read 판정(전환기에는 legacy 가 대신
    판정)은 이 클래스가 아니라 `tests/migration/
    test_authority_valid_evidence_state_table.py` 의 authority Scope
    행(§3.6 판정 상태표) 소관이다.
    """

    def setUp(self):
        super().setUp()
        self.digest = self._current_digest()
        # policy version "1" 시절 발급된 유효 Evidence (digest 결합 통과)
        self.evidence = issue_code_review_evidence(
            self._response(), current_digest=self.digest, policy_version="1"
        )
        self.requirement = CodeReviewRequirement()

    def _evaluate(self, policy_version, compatible=None):
        return self.requirement.evaluate(
            self._context(
                (self.evidence,),
                digest=self.digest,
                policy_version=policy_version,
                compatible=compatible,
            )
        )

    def test_same_digest_different_policy_version_is_unmet(self):
        # (i) digest 일치 + version 불일치 + 호환 선언 없음 → 미충족.
        # digest 축이 통과해도 version 축이 독립적으로 무효화한다
        self.assertFalse(self._evaluate(policy_version="2"))

    def test_declared_compatible_version_is_met(self):
        # (ii) version 불일치라도 compatible_versions 에 명시 선언된
        # 이전 version 이면 인정 (spec §3.4 — 명시 선언 시에만)
        self.assertTrue(
            self._evaluate(policy_version="2", compatible=("1",))
        )

    def test_undeclared_version_is_unmet_despite_other_declarations(self):
        # 호환 선언이 있어도 해당 version 이 목록에 없으면 무효 —
        # 선언 존재 자체가 전 version 인정으로 확대되지 않는다
        self.assertFalse(
            self._evaluate(policy_version="3", compatible=("2",))
        )

    def test_absent_policy_version_fact_is_conservatively_unmet(self):
        # (iii) 현재 version fact 미확보 → version 축 재확인 불가 →
        # 보수적 미충족 (digest fact 미확보와 동일 방향)
        self.assertFalse(self._evaluate(policy_version=None))


class EvaluatorIntegrationTest(_ReviewedFileMixin):
    """리뷰 1회차 지적 2 — 실제 evaluator 관통 (registry 배선).

    policy 가 code_review 를 요구할 때, registry 에 등록된 capability 의
    validity 결합(digest + version)이 실제 `engine.evaluator.evaluate()`
    의 Decision 을 결정한다: stale digest evidence → BLOCK / 결합 유효
    evidence → ALLOW. runtime dict 인터페이스의 registry passthrough 도
    같은 결과에 도달한다.
    """

    def setUp(self):
        super().setUp()
        self.policy = {
            "policy_id": "review-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - code_review\n"
                "failure_mode: closed\n",
                source="<test:review-gate>",
            ),
        }
        self.registry = RequirementRegistry()
        register_code_review(self.registry)

    def _facts(self, digest, policy_version="1"):
        return {
            FACT_CHANGESET_REVIEW_DIGEST: digest,
            FACT_POLICY_VERSION: policy_version,
        }

    def test_stale_digest_evidence_yields_block(self):
        # evidence subject = 이전 digest, 현재 digest = 리뷰 후 수정된
        # digest → 레코드가 존재해도 evaluator 결과는 BLOCK
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        self._edit_code()
        current = self._current_digest()
        self.assertNotEqual(current, digest)
        context = EvaluationContext(
            facts=self._facts(current),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (REQUIREMENT_NAME,))
        self.assertEqual(decision.policy, "review-gate")
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_bound_evidence_yields_allow(self):
        # 대칭 — digest 일치 + version 일치 → ALLOW
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        context = EvaluationContext(
            facts=self._facts(digest),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_version_mismatch_yields_block_through_evaluator(self):
        # version 축도 evaluator 관통 — digest 일치·version 불일치 → BLOCK
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        context = EvaluationContext(
            facts=self._facts(digest, policy_version="2"),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (REQUIREMENT_NAME,))

    def test_runtime_passes_registry_through(self):
        # runtime dict 인터페이스(cli 계약)의 registry passthrough —
        # stale digest 가 dict 경로에서도 BLOCK 에 도달한다
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(), current_digest=digest, policy_version="1"
        )
        self._edit_code()
        result = runtime.evaluate(
            "tool.pre",
            self._facts(self._current_digest()),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)


class ClosedValueContractTest(_ReviewedFileMixin):
    """(f) — SUBJECT_EMPTY/SUBJECT_UNRESOLVED 닫힌 값 계약 2상태의
    발급·평가 짝 테스트 (spec §3.6 "리뷰 digest 범위" 절, 2026-08-20
    보강, Phase 7 웨이브 3 ③-a).

    `tests/contract/test_security_review_requirement.py::
    ClosedValueContractAcrossProfilesTest` 와 동일 패턴 — code_review 는
    security_review 와 달리 산정 프로필이 하나뿐이라 2셀(2상태×1)만
    있다(security 는 strict/sensitive 2프로필이라 4셀). 여기서는
    `CodeReviewRequirement`/`issue_code_review_evidence` 자신은 "이 값이
    실제 git 산정 결과인지 합성 값인지" 모른다는 계약(§3.6 "두 상태를
    발급·평가 양쪽이 공유한다")을 겨냥하므로, `_ReviewedFileMixin` 의
    합성 fixture 위에서 센티널 리터럴을 그대로 흘려 넣는다 — 실제 git
    기반 산정(`review_digest()`)의 경계 자체는 `tests/unit/
    test_review_digest_scope.py` 가 별도로 고정한다.
    """

    def _evaluate_with(self, digest):
        return CodeReviewRequirement().evaluate(
            self._context((), digest=digest)
        )

    def _assert_issue_refused_as_caller_contract_violation(self, digest):
        # 두 센티널 모두 발급측에서는 "발급 대상이 없거나 산정 불가"이므로
        # ReviewEvidenceRefusal 계열이 아니라 호출자(Runtime) 계약 위반
        # ValueError 다 (capability.py `issue_code_review_evidence`
        # docstring 참조, security capability 와 대칭).
        with self.assertRaises(ValueError):
            issue_code_review_evidence(
                {"verdict": VERDICT_PASS, "reviewed_digest": digest},
                current_digest=digest,
                policy_version="1",
            )

    def test_subject_empty_is_met_and_issuance_is_refused(self):
        # SUBJECT_EMPTY(변경 전부 검토 면제 허용목록) → 평가는 evidence
        # 없이 곧바로 충족(True), 발급은 대상이 없어 거부(ValueError).
        self.assertTrue(self._evaluate_with(SUBJECT_EMPTY))
        self._assert_issue_refused_as_caller_contract_violation(SUBJECT_EMPTY)

    def test_subject_unresolved_is_unmet_and_issuance_is_refused(self):
        # SUBJECT_UNRESOLVED(산정 불가) → 평가는 보수적으로 미충족
        # (False), 발급은 무엇에 대한 evidence 인지조차 정의되지 않아
        # 거부(ValueError).
        self.assertFalse(self._evaluate_with(SUBJECT_UNRESOLVED))
        self._assert_issue_refused_as_caller_contract_violation(
            SUBJECT_UNRESOLVED
        )

    def test_real_digest_still_satisfies_normal_evidence_path(self):
        # 회귀 유지 — 실제(non-sentinel) digest 는 기존 발급·평가 정상
        # 경로를 그대로 탄다(2상태 도입이 정상 경로를 깨지 않는다).
        digest = self._current_digest()
        evidence = issue_code_review_evidence(
            self._response(reviewed_digest=digest),
            current_digest=digest,
            policy_version="1",
        )
        context = self._context((evidence,), digest=digest)
        self.assertTrue(CodeReviewRequirement().evaluate(context))


if __name__ == "__main__":
    unittest.main()
