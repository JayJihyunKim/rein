"""plan Task 4.1 — security_review Evidence 는 Runtime 만 발급 (spec §2.2, §3.6).

Security Agent 가 PASS 를 반환하는 것만으로는 security_review Evidence 가
생기지 않는다 — Runtime 이 structured review response 를 직접 파싱해,
리뷰가 본 sensitive ChangeSet digest 와 현재 sensitive digest 를
결합(비교)해서만 발급한다 (spec §3.6: "sensitive ChangeSet digest 대상.
code_review 와 상호 직접 호출 금지 — Policy 가 조합"). 이 테스트 모듈은
`rein.capabilities.review` 의 code_review capability 를 어떤 형태로도
import 하지 않는다 — 두 capability 는 조합되지 않고 각자 독립적으로
검증된다 (capability 간 직접 의존 금지, spec §3.1).

검증 축 (plan Task 4.1 steps):
(a) sensitive 변경 존재(sensitive digest fact 확보) + 유효 evidence
    부재 → 미충족 (요구 발생) — Requirement.evaluate 직접 + evaluator
    관통 BLOCK 양쪽에서 확인.
(b) 발급 경로 — verdict PASS + digest 일치 → 발급, 불일치/비PASS/
    malformed → 사유별 거부.
(c) evaluate 가 digest·policy version 두 축을 평가 시점에 재확인한다
    (review capability 의 (a)~(e) 패턴을 준용).
(d) 실제 `engine.evaluator.evaluate(..., registry=...)` 관통 1건 —
    BLOCK(evidence 부재/stale) → 발급 → ALLOW.
(e) digest scope 프로필 2종(spec §3.6 "digest scope 프로필" 절,
    2026-08-19) × 닫힌 값 계약 2상태(SUBJECT_EMPTY/SUBJECT_UNRESOLVED)의
    발급·평가 전조합(4셀) — 이 모듈이 검증하는 `SecurityReviewRequirement.
    evaluate()`/`issue_security_review_evidence()` 는 fact 값이 어느
    프로필(strict/sensitive)의 산정 함수에서 나왔는지 모른다(닫힌 값
    계약이 프로필에 독립적이라는 스펙 요건 자체가 이 무지를 요구한다)
    — 그래서 이 테스트는 추상 센티널 상수가 아니라 **두 프로필의 실제
    production 산정 함수**(`rein.platform.git.facts.
    strict_security_digest()` = strict, `rein.cli._git_changeset_facts()`
    = sensitive)가 실제로 낸 값을 그대로 evaluate()/issue() 에 흘려
    넣어 4셀 전부를 검증한다(`ClosedValueContractAcrossProfilesTest`).
"""
import os
import subprocess
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

import rein.cli as rein_cli  # noqa: E402

from rein.capabilities.security.capability import (  # noqa: E402
    FACT_CHANGESET_SENSITIVE_DIGEST,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    MalformedSecurityReviewResponse,
    REQUIREMENT_NAME,
    SecurityReviewDigestMismatch,
    SecurityReviewEvidenceRefusal,
    SecurityReviewVerdictNotPass,
    VERDICT_PASS,
    SecurityReviewRequirement,
    issue_security_review_evidence,
    register_security_review,
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
from rein.platform.git import facts as git_facts  # noqa: E402


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


class _SensitiveChangeMixin(unittest.TestCase):
    """sensitive 변경 파일 1개를 실제로 수정해 digest 변화를 만드는 공통 준비."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        # sensitive 태그 분류 대상 예시 경로 (secret/credential 류) —
        # 이 테스트는 태그 분류(Phase 2 완료 소관)를 재구현하지 않고
        # sensitive ChangeSet digest 값만 직접 주입한다
        self.path = os.path.join(self.base, "config", "secrets.env")
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "wb") as handle:
            handle.write(b"API_KEY=old\n")
        self.reader = _fs_reader(self.base)
        self.reviewed_digest = self._current_digest()

    def _current_digest(self):
        return content_digest(("config/secrets.env",), self.reader)

    def _edit_sensitive_change(self):
        """리뷰 후 sensitive 변경 수정 시뮬레이션 — 현재 digest 가 달라진다."""
        with open(self.path, "wb") as handle:
            handle.write(b"API_KEY=new\n")

    def _response(self, verdict=VERDICT_PASS, reviewed_digest=None):
        """Security Agent 가 반환하는 structured review response."""
        if reviewed_digest is None:
            reviewed_digest = self.reviewed_digest
        return {"verdict": verdict, "reviewed_digest": reviewed_digest}

    def _context(
        self, records, digest=None, policy_version="1", compatible=None
    ):
        """sensitive digest·version fact + evidence 소스를 담은 평가 컨텍스트."""
        facts = {}
        if digest is not None:
            facts[FACT_CHANGESET_SENSITIVE_DIGEST] = digest
        if policy_version is not None:
            facts[FACT_POLICY_VERSION] = policy_version
        if compatible is not None:
            facts[FACT_POLICY_COMPATIBLE_VERSIONS] = tuple(compatible)
        return EvaluationContext(
            facts=facts, evidence_source=_StubEvidenceSource(records)
        )


class RequirementUnmetWithoutEvidenceTest(_SensitiveChangeMixin):
    """(a) — sensitive 변경 존재 + 유효 evidence 부재 → 미충족(요구 발생)."""

    def test_sensitive_digest_present_without_evidence_is_unmet(self):
        # sensitive ChangeSet digest fact 는 확보됐지만 evidence 가 전혀
        # 없다 — 확인 불가가 아니라 정상 조회 결과 0건(부재), 미충족
        requirement = SecurityReviewRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((), digest=self._current_digest())
            )
        )

    def test_absent_sensitive_digest_fact_is_conservatively_unmet(self):
        # sensitive digest fact 자체가 없으면(비sensitive 변경 등) 재확인
        # 불가 — 보수적으로 미충족
        requirement = SecurityReviewRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((), digest=None))
        )


class RuntimeIssuanceTest(_SensitiveChangeMixin):
    """(b) — verdict + sensitive digest 결합 페어가 발급을 결정한다."""

    def test_pass_with_matching_digest_issues_evidence(self):
        evidence = issue_security_review_evidence(
            self._response(),
            current_sensitive_digest=self._current_digest(),
            policy_version="1",
        )
        self.assertEqual(evidence.type, REQUIREMENT_NAME)
        self.assertEqual(evidence.subject, self.reviewed_digest)
        self.assertEqual(evidence.result, VERDICT_PASS)
        # 보안 리뷰 판단도 독립적인 암호학적 증명이 아니다 (spec §2.2) —
        # producer 는 runtime_verified 가 아니라 agent_attested 다
        self.assertEqual(evidence.producer, PRODUCER_AGENT_ATTESTED)
        self.assertEqual(evidence.policy_version, "1")

    def test_digest_mismatch_after_edit_refuses_issuance(self):
        # 리뷰 후 sensitive 변경 수정 → 리뷰가 본 digest ≠ 현재 digest →
        # 미발급. 거부는 None 반환이 아니라 구분 가능한 예외다
        response = self._response()
        self._edit_sensitive_change()
        current = self._current_digest()
        self.assertNotEqual(current, self.reviewed_digest)
        with self.assertRaises(SecurityReviewDigestMismatch):
            issue_security_review_evidence(
                response,
                current_sensitive_digest=current,
                policy_version="1",
            )

    def test_non_pass_verdict_refuses_even_with_matching_digest(self):
        with self.assertRaises(SecurityReviewVerdictNotPass):
            issue_security_review_evidence(
                self._response(verdict="NEEDS-FIX"),
                current_sensitive_digest=self._current_digest(),
                policy_version="1",
            )

    def test_verdict_matching_is_strict_not_lenient(self):
        # 관대한 해석 금지 — 대소문자·공백 변형을 PASS 로 승격하지 않는다
        for verdict in ("pass", "Pass", " PASS", "PASS "):
            with self.assertRaises(SecurityReviewVerdictNotPass):
                issue_security_review_evidence(
                    self._response(verdict=verdict),
                    current_sensitive_digest=self._current_digest(),
                    policy_version="1",
                )

    def test_refusals_share_a_distinguishable_base(self):
        self.assertTrue(
            issubclass(
                SecurityReviewDigestMismatch, SecurityReviewEvidenceRefusal
            )
        )
        self.assertTrue(
            issubclass(
                SecurityReviewVerdictNotPass, SecurityReviewEvidenceRefusal
            )
        )
        self.assertTrue(
            issubclass(
                MalformedSecurityReviewResponse,
                SecurityReviewEvidenceRefusal,
            )
        )

    def test_current_digest_must_be_provided_by_caller(self):
        # 호출자(Runtime) 계약 위반 — digest 를 확보하지 못했으면 발급
        # 시도 자체가 성립하지 않는다 (거부 부류가 아니라 ValueError)
        for bad_digest in (None, "", 42):
            with self.assertRaises(ValueError):
                issue_security_review_evidence(
                    self._response(),
                    current_sensitive_digest=bad_digest,
                    policy_version="1",
                )


class StructuredResponseParsingTest(_SensitiveChangeMixin):
    """파싱 불가·필수 필드 결손은 관대한 해석 없이 미발급."""

    def _assert_malformed(self, response):
        with self.assertRaises(MalformedSecurityReviewResponse):
            issue_security_review_evidence(
                response,
                current_sensitive_digest=self._current_digest(),
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


class RegistryEvaluationTest(_SensitiveChangeMixin):
    """(c) — 등록된 capability 의 evaluate 가 digest 재확인 후 충족 판정."""

    def test_registration_is_explicit_not_import_side_effect(self):
        # import 는 이미 모듈 상단에서 일어났다 — 그럼에도 새 registry 가
        # 비어 있어야 "등록은 명시적 코드 등록" 계약(spec §3.1 §32)이 성립
        registry = RequirementRegistry()
        self.assertFalse(registry.is_registered(REQUIREMENT_NAME))
        implementation = register_security_review(registry)
        self.assertTrue(registry.is_registered(REQUIREMENT_NAME))
        self.assertIs(registry.resolve(REQUIREMENT_NAME), implementation)
        self.assertEqual(implementation.name, REQUIREMENT_NAME)
        self.assertIsInstance(implementation, SecurityReviewRequirement)

    def test_issued_evidence_satisfies_at_same_digest(self):
        # 발급 → 등록 → evaluate 충족의 정상 경로 1건 (digest 불변)
        digest = self._current_digest()
        evidence = issue_security_review_evidence(
            self._response(),
            current_sensitive_digest=digest,
            policy_version="1",
        )
        registry = RequirementRegistry()
        register_security_review(registry)
        requirement = registry.resolve(REQUIREMENT_NAME)
        self.assertTrue(
            requirement.evaluate(self._context((evidence,), digest=digest))
        )

    def test_evidence_alone_is_not_satisfaction_after_edit(self):
        # evidence 존재만으로 충족 아님 — 발급 후 sensitive 변경이 또
        # 수정되면 subject ≠ 현재 digest 이므로 재평가는 미충족이다.
        #
        # **픽스처 전제 명시(2026-08-20, spec §3.6 판정 상태표, Scope
        # `evidence-expires-when-subject-digest-changes-after-creation`
        # 참조)**: `SecurityReviewRequirement.evaluate()` 를 직접 호출
        # 하고 `evaluator.evaluate(..., project_root=...)` 를 거치지
        # 않으므로 authority dual-read·legacy marker 자체가 도달 범위
        # 밖이다 — "legacy 표식 부재" 전제가 구조적으로 항상 성립한다.
        # stale 증거 + 신선 legacy 조합의 최종 dual-read 판정(전환기
        # legacy 대체)은 `tests/migration/
        # test_authority_valid_evidence_state_table.py` 의
        # `CrossCapabilityMappingSharedTest` 소관이다.
        digest = self._current_digest()
        evidence = issue_security_review_evidence(
            self._response(),
            current_sensitive_digest=digest,
            policy_version="1",
        )
        self._edit_sensitive_change()
        current = self._current_digest()
        self.assertNotEqual(current, digest)
        requirement = SecurityReviewRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((evidence,), digest=current))
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
        requirement = SecurityReviewRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((record,), digest=digest))
        )


class PolicyVersionAxisTest(_SensitiveChangeMixin):
    """(c) 계속 — digest 와 독립인 policy version 축 (spec §3.4).

    같은 digest 라도 Evidence 의 policy_version 이 현재 version 과
    다르면 미충족이다 — 호환 선언(`compatible_versions` fact)에
    **명시**된 version 만 인정한다 (kernel `policy_version_valid` 재사용,
    재구현 금지).

    **픽스처 전제 명시(2026-08-20, spec §3.6 판정 상태표, Scope
    `evidence-with-mismatched-policy-version-is-invalid-unless-compat-
    declared` 참조)**: `SecurityReviewRequirement.evaluate()` 직접 호출
    — authority dual-read·legacy marker 도달 범위 밖("legacy 표식 부재"
    전제가 구조적으로 성립). 무효 증거 + 신선 legacy 조합의 최종 판정은
    `tests/migration/test_authority_valid_evidence_state_table.py` 소관.
    """

    def setUp(self):
        super().setUp()
        self.digest = self._current_digest()
        # policy version "1" 시절 발급된 유효 Evidence (digest 결합 통과)
        self.evidence = issue_security_review_evidence(
            self._response(),
            current_sensitive_digest=self.digest,
            policy_version="1",
        )
        self.requirement = SecurityReviewRequirement()

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
        # digest 일치 + version 불일치 + 호환 선언 없음 → 미충족.
        # digest 축이 통과해도 version 축이 독립적으로 무효화한다
        self.assertFalse(self._evaluate(policy_version="2"))

    def test_declared_compatible_version_is_met(self):
        # version 불일치라도 compatible_versions 에 명시 선언된 이전
        # version 이면 인정 (spec §3.4 — 명시 선언 시에만)
        self.assertTrue(
            self._evaluate(policy_version="2", compatible=("1",))
        )

    def test_undeclared_version_is_unmet_despite_other_declarations(self):
        # 호환 선언이 있어도 해당 version 이 목록에 없으면 무효
        self.assertFalse(
            self._evaluate(policy_version="3", compatible=("2",))
        )

    def test_absent_policy_version_fact_is_conservatively_unmet(self):
        # 현재 version fact 미확보 → version 축 재확인 불가 → 보수적
        # 미충족 (digest fact 미확보와 동일 방향)
        self.assertFalse(self._evaluate(policy_version=None))


class EvaluatorIntegrationTest(_SensitiveChangeMixin):
    """(d) — 실제 evaluator 관통 (registry 배선), BLOCK → 발급 → ALLOW.

    policy 가 security_review 를 요구할 때, registry 에 등록된
    capability 의 validity 결합(digest + version)이 실제
    `engine.evaluator.evaluate()` 의 Decision 을 결정한다: evidence
    부재/stale digest → BLOCK / 결합 유효 evidence 발급 후 → ALLOW.
    """

    def setUp(self):
        super().setUp()
        self.policy = {
            "policy_id": "security-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - security_review\n"
                "failure_mode: closed\n",
                source="<test:security-gate>",
            ),
        }
        self.registry = RequirementRegistry()
        register_security_review(self.registry)

    def _facts(self, digest, policy_version="1"):
        return {
            FACT_CHANGESET_SENSITIVE_DIGEST: digest,
            FACT_POLICY_VERSION: policy_version,
        }

    def test_missing_evidence_yields_block(self):
        # evidence 가 전혀 없는 정상 평가 BLOCK — 요구가 실제로 발생한다
        digest = self._current_digest()
        context = EvaluationContext(
            facts=self._facts(digest),
            evidence_source=_StubEvidenceSource(()),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (REQUIREMENT_NAME,))
        self.assertEqual(decision.policy, "security-gate")
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_stale_digest_evidence_yields_block_then_reissue_yields_allow(
        self,
    ):
        # BLOCK → 발급 → ALLOW 한 사이클: evidence subject = 리뷰 시점
        # digest, 이후 sensitive 변경이 수정되어 현재 digest 가 달라지면
        # BLOCK. 새로 발급한 evidence(현재 digest 결합)로는 ALLOW.
        digest = self._current_digest()
        stale_evidence = issue_security_review_evidence(
            self._response(), current_sensitive_digest=digest,
            policy_version="1",
        )
        self._edit_sensitive_change()
        current = self._current_digest()
        self.assertNotEqual(current, digest)

        block_context = EvaluationContext(
            facts=self._facts(current),
            evidence_source=_StubEvidenceSource((stale_evidence,)),
        )
        block_decision = evaluator.evaluate(
            "tool.pre",
            block_context,
            [self.policy],
            registry=self.registry,
        )
        self.assertEqual(block_decision.decision, DECISION_BLOCK)
        self.assertEqual(
            block_decision.missing_requirements, (REQUIREMENT_NAME,)
        )

        fresh_evidence = issue_security_review_evidence(
            self._response(reviewed_digest=current),
            current_sensitive_digest=current,
            policy_version="1",
        )
        allow_context = EvaluationContext(
            facts=self._facts(current),
            evidence_source=_StubEvidenceSource((fresh_evidence,)),
        )
        allow_decision = evaluator.evaluate(
            "tool.pre",
            allow_context,
            [self.policy],
            registry=self.registry,
        )
        self.assertEqual(allow_decision.decision, DECISION_ALLOW)
        self.assertEqual(allow_decision.missing_requirements, ())

    def test_version_mismatch_yields_block_through_evaluator(self):
        digest = self._current_digest()
        evidence = issue_security_review_evidence(
            self._response(), current_sensitive_digest=digest,
            policy_version="1",
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
        # 결합 유효 evidence 는 dict 경로에서도 ALLOW 에 도달한다
        digest = self._current_digest()
        evidence = issue_security_review_evidence(
            self._response(), current_sensitive_digest=digest,
            policy_version="1",
        )
        result = runtime.evaluate(
            "tool.pre",
            self._facts(digest),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_ALLOW)


# ---------------------------------------------------------------------------
# (e) 닫힌 값 계약 2상태 × digest scope 프로필 2종 — 발급·평가 전조합.


def _git(args, cwd, check=True):
    return subprocess.run(
        ("git",) + tuple(args), cwd=cwd, check=check, capture_output=True
    )


def _init_git_repo(base_dir):
    """빈 git 저장소 — 커밋 없이도 `worktree_changeset`/`strict_security_
    digest` 양쪽이 유효한(비-None) 결과를 낸다(변경 0건 = 두 프로필 모두
    SUBJECT_EMPTY 방향)."""
    _git(("init", "-q"), base_dir)
    _git(("config", "user.email", "t@example.com"), base_dir)
    _git(("config", "user.name", "t"), base_dir)


def _write_and_stage(base_dir, rel_path, content):
    full_path = os.path.join(base_dir, rel_path)
    os.makedirs(os.path.dirname(full_path) or base_dir, exist_ok=True)
    with open(full_path, "w", encoding="utf-8") as handle:
        handle.write(content)
    _git(("add", "-A"), base_dir)


class ClosedValueContractAcrossProfilesTest(unittest.TestCase):
    """(e) — strict/sensitive 두 프로필의 실제 production 산정 함수가 낸
    SUBJECT_EMPTY/SUBJECT_UNRESOLVED 를 그대로 evaluate()/issue() 에 흘려
    4셀(2상태×2프로필) 전부에서 같은 계약이 성립함을 고정한다.

    `SecurityReviewRequirement`/`issue_security_review_evidence` 자신은
    "이 값이 어느 프로필에서 왔는가"를 모른다 — 이 무지 자체가 spec §3.6
    의 "두 프로필이 닫힌 값 계약을 공유한다" 요건이다. 그래서 여기서는
    프로필별로 별도 판정 로직을 세우지 않고, 두 프로필의 production
    함수가 낸 값을 그대로 같은 evaluate()/issue() 경로에 통과시킨다.
    """

    def _requirement(self):
        return SecurityReviewRequirement()

    def _evaluate_with(self, digest):
        context = EvaluationContext(
            facts={
                FACT_CHANGESET_SENSITIVE_DIGEST: digest,
                FACT_POLICY_VERSION: "1",
            },
            evidence_source=_StubEvidenceSource(()),
        )
        return self._requirement().evaluate(context)

    def _assert_issue_refused_as_caller_contract_violation(self, digest):
        # 두 센티널 모두 issue 측에서는 "발급 대상이 없거나 산정 불가"
        # 이므로 SecurityReviewEvidenceRefusal 계열이 아니라 호출자
        # (Runtime) 계약 위반 ValueError 다 (capability.py
        # `issue_security_review_evidence` docstring 참조).
        with self.assertRaises(ValueError):
            issue_security_review_evidence(
                {"verdict": VERDICT_PASS, "reviewed_digest": digest},
                current_sensitive_digest=digest,
                policy_version="1",
            )

    # -- strict 프로필: rein.platform.git.facts.strict_security_digest --

    def test_strict_empty_is_met_and_issuance_is_refused(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)  # staged 변경 0건
            digest = git_facts.strict_security_digest(cwd=base_dir)
        self.assertEqual(digest, SUBJECT_EMPTY)
        self.assertTrue(self._evaluate_with(digest))
        self._assert_issue_refused_as_caller_contract_violation(digest)

    def test_strict_unresolved_is_unmet_and_issuance_is_refused(self):
        # git 저장소가 아닌 디렉토리 — staged 경로 획득 자체가 실패한다
        # (`strict_security_digest` 의 git 실패 → SUBJECT_UNRESOLVED 분기,
        # `tests/unit/test_security_digest_scope.py` 의 동일 실증 재사용).
        with tempfile.TemporaryDirectory() as base_dir:
            digest = git_facts.strict_security_digest(cwd=base_dir)
        self.assertEqual(digest, SUBJECT_UNRESOLVED)
        self.assertFalse(self._evaluate_with(digest))
        self._assert_issue_refused_as_caller_contract_violation(digest)

    def test_strict_real_change_still_satisfies_normal_evidence_path(self):
        # 회귀 유지 — 실제(non-sentinel) strict digest 는 기존 발급·평가
        # 정상 경로를 그대로 탄다 (D4 수리가 정상 경로를 깨지 않는다).
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            _write_and_stage(base_dir, "src/app.py", "x = 1\n")
            digest = git_facts.strict_security_digest(cwd=base_dir)
        self.assertTrue(digest.startswith("sha256:"))
        evidence = issue_security_review_evidence(
            {"verdict": VERDICT_PASS, "reviewed_digest": digest},
            current_sensitive_digest=digest,
            policy_version="1",
        )
        context = EvaluationContext(
            facts={
                FACT_CHANGESET_SENSITIVE_DIGEST: digest,
                FACT_POLICY_VERSION: "1",
            },
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        self.assertTrue(self._requirement().evaluate(context))

    # -- sensitive 프로필: rein.cli._git_changeset_facts (index 1) --

    def test_sensitive_empty_is_met_and_issuance_is_refused(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)  # sensitive 로 분류될 변경 0건
            digest = rein_cli._git_changeset_facts(base_dir)[1]
        self.assertEqual(digest, SUBJECT_EMPTY)
        self.assertTrue(self._evaluate_with(digest))
        self._assert_issue_refused_as_caller_contract_violation(digest)

    def test_sensitive_unresolved_is_unmet_and_issuance_is_refused(self):
        # git 저장소가 아닌 디렉토리 — `worktree_changeset()` 자체가
        # None 을 내 changeset 해석이 실패한다.
        with tempfile.TemporaryDirectory() as base_dir:
            digest = rein_cli._git_changeset_facts(base_dir)[1]
        self.assertEqual(digest, SUBJECT_UNRESOLVED)
        self.assertFalse(self._evaluate_with(digest))
        self._assert_issue_refused_as_caller_contract_violation(digest)

    def test_sensitive_real_change_still_satisfies_normal_evidence_path(self):
        # 회귀 유지 — 실제 sensitive 변경의 digest 는 기존 발급·평가
        # 정상 경로를 그대로 탄다.
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            _write_and_stage(base_dir, ".env", "SECRET=1\n")
            digest = rein_cli._git_changeset_facts(base_dir)[1]
        self.assertIsNotNone(digest)
        self.assertNotIn(digest, (SUBJECT_EMPTY, SUBJECT_UNRESOLVED))
        self.assertTrue(digest.startswith("sha256:"))
        evidence = issue_security_review_evidence(
            {"verdict": VERDICT_PASS, "reviewed_digest": digest},
            current_sensitive_digest=digest,
            policy_version="1",
        )
        context = EvaluationContext(
            facts={
                FACT_CHANGESET_SENSITIVE_DIGEST: digest,
                FACT_POLICY_VERSION: "1",
            },
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        self.assertTrue(self._requirement().evaluate(context))


if __name__ == "__main__":
    unittest.main()
