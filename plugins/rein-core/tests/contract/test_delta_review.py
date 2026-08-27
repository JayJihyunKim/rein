"""plan Task 3.2 — Delta Review 합성 계약 (spec §3.6 Delta Review, §13).

spec §3.6 (§13, 원문 인용):
    "`Full Review(X) + Delta Review(X→Y) = Validated Review(Y)`. Delta
    대상은 X 이후 실제 변경분으로 제한. Base digest 불명확·중간 상태
    불신 시 Full Review fallback. 목표 = v1 review churn (작은 수정마다
    전체 재리뷰) 제거."

검증 축:
- 합성: Full Review evidence(X) + delta response(base=X, reviewed=Y) →
  Runtime 이 Y subject 의 code_review Evidence 를 발급하고, 기존
  CodeReviewRequirement.evaluate 가 Y 에서 충족 판정한다 (capability.py
  수정 없이 — 합성 산출물은 일반 code_review Evidence 다).
- base 오염: delta 의 base digest 가 검증 가능한 full/validated review
  와 매칭되지 않으면 (불명확 base·비PASS·타입 불일치·version 불신)
  델타 합성을 거부하고 **FullReviewRequired** 로 full review 요구를
  명시 신호한다 — delta 로는 충족 불가.
- scope 결속 (재리뷰 2회차 시정): "X 이후 실변경분 한정" 의 나머지 한
  축 — 리뷰가 봤다는 변경 경로 집합(`reviewed_paths`)이 Runtime 이
  계산한 실제 X→Y 변경 경로 집합과 **집합으로 일치**해야 발급된다.
  미달(실변경 일부 미리뷰)·초과(없는 변경을 봤다는 주장) 모두
  DeltaScopeMismatch 로 거부.
- 체인 (이 스위트가 고정하는 계약): X→Y→Z 는 **검증된 링크를 경유할
  때만** 허용된다 — 합성 산출물 Validated(Y) 가 다음 delta 의 base 자격
  을 가지므로 spec 공식이 귀납 적용된다. 끊긴 체인(중간 링크 미검증)은
  FullReviewRequired.
- strict 파싱: delta response 결손·형식 위반·verdict 비PASS 는 관대한
  해석 없이 명시 거부 (Task 3.1 발급 규율과 동일 — 침묵 실패 금지).
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
from rein.capabilities.review.delta import (  # noqa: E402
    DeltaScopeMismatch,
    FullReviewRequired,
    METADATA_BASE_DIGEST,
    METADATA_REVIEW_SCOPE,
    METADATA_REVIEWED_PATHS,
    RESPONSE_FIELD_BASE_DIGEST,
    RESPONSE_FIELD_REVIEWED_PATHS,
    REVIEW_SCOPE_DELTA,
    issue_delta_review_evidence,
    validate_delta_base,
)
from rein.engine import evaluator  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.changeset import content_digest  # noqa: E402
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


class _DeltaChainMixin(unittest.TestCase):
    """Full Review(X) 이후 실제 코드 수정으로 Y digest 를 만드는 공통 준비.

    setUp 종료 시점 상태: 파일은 Y 내용, `self.full_x` = X 에서 정식
    발급된 Full Review evidence (Task 3.1 발급 경로 — 재구현 금지),
    `self.digest_x`/`self.digest_y` = 각 시점의 실측 digest.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.path = os.path.join(self.base, "mod.py")
        self.reader = _fs_reader(self.base)
        self._edit(b"VALUE = 1\n")
        self.digest_x = self._current_digest()
        # Full Review(X) — Task 3.1 의 Runtime 발급 경로 그대로 사용
        self.full_x = issue_code_review_evidence(
            {"verdict": VERDICT_PASS, "reviewed_digest": self.digest_x},
            current_digest=self.digest_x,
            policy_version="1",
        )
        # X 이후 실변경 → Y (delta 가 검증한다고 주장할 변경분)
        self._edit(b"VALUE = 2\n")
        self.digest_y = self._current_digest()
        self.assertNotEqual(self.digest_x, self.digest_y)

    def _edit(self, content):
        with open(self.path, "wb") as handle:
            handle.write(content)

    def _current_digest(self):
        return content_digest(("mod.py",), self.reader)

    def _delta_response(
        self,
        verdict=VERDICT_PASS,
        base_digest=None,
        reviewed_digest=None,
        reviewed_paths=("mod.py",),
    ):
        """Delta Reviewer 가 반환하는 structured delta review response."""
        if base_digest is None:
            base_digest = self.digest_x
        if reviewed_digest is None:
            reviewed_digest = self.digest_y
        if isinstance(reviewed_paths, (list, tuple)):
            # 정상형은 list 로 전달 — 비정상형(비컬렉션 등)은 원값
            # 그대로 실어 모듈의 strict 파싱이 거부하게 한다
            reviewed_paths = list(reviewed_paths)
        return {
            "verdict": verdict,
            "base_digest": base_digest,
            "reviewed_digest": reviewed_digest,
            "reviewed_paths": reviewed_paths,
        }

    def _compose_delta_y(self, prior_records=None):
        """정상 경로 합성 1회 — Full(X) + Delta(X→Y) = Validated(Y)."""
        if prior_records is None:
            prior_records = (self.full_x,)
        return issue_delta_review_evidence(
            self._delta_response(),
            prior_records,
            current_digest=self.digest_y,
            actual_changed_paths=("mod.py",),
            policy_version="1",
        )

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


class DeltaCompositionTest(_DeltaChainMixin):
    """(a) — Full Review(X) + Delta Review(X→Y) = Validated Review(Y)."""

    def test_full_review_alone_is_stale_at_y(self):
        # churn 전제 재확인: X 의 Full Review evidence 만으로는 Y 에서
        # 미충족이다 (subject ≠ 현재 digest — Task 3.1 digest 축)
        requirement = CodeReviewRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((self.full_x,), digest=self.digest_y)
            )
        )

    def test_full_plus_delta_composes_validated_evidence_at_y(self):
        # 합성 산출물은 Y subject 의 일반 code_review Evidence 다 —
        # 별도 evidence 타입을 만들지 않는다 (spec 공식의 우변이
        # "Validated Review(Y)" 인 이유)
        validated = self._compose_delta_y()
        self.assertEqual(validated.type, REQUIREMENT_NAME)
        self.assertEqual(validated.subject, self.digest_y)
        self.assertEqual(validated.result, VERDICT_PASS)
        # delta 리뷰 판단도 Agent 의 것 — runtime_verified 로 승격 금지
        self.assertEqual(validated.producer, PRODUCER_AGENT_ATTESTED)
        self.assertEqual(validated.policy_version, "1")
        # 합성 이력은 metadata 에 남는다 (kernel 필드 계약 변경 없이)
        self.assertEqual(
            validated.metadata[METADATA_BASE_DIGEST], self.digest_x
        )
        self.assertEqual(
            validated.metadata[METADATA_REVIEW_SCOPE], REVIEW_SCOPE_DELTA
        )
        # 결속된 변경 경로도 metadata 에 남는다 — kernel ChangeSet paths
        # 관례(저장소 상대 경로의 정렬·중복제거 tuple)와 같은 형태.
        # 절대경로는 호출자 계약 위반이므로 여기 실리지 않는다
        self.assertEqual(
            validated.metadata[METADATA_REVIEWED_PATHS], ("mod.py",)
        )

    def test_composed_evidence_satisfies_code_review_at_y(self):
        # 좌변(Full X + Delta X→Y)을 합성하면 기존 CodeReviewRequirement
        # 가 Y 에서 충족 판정한다 — capability.py 수정 없이
        validated = self._compose_delta_y()
        requirement = CodeReviewRequirement()
        self.assertTrue(
            requirement.evaluate(
                self._context(
                    (self.full_x, validated), digest=self.digest_y
                )
            )
        )

    def test_composed_evidence_expires_like_any_review_evidence(self):
        # 합성 산출물도 특권이 없다 — Y 발급 후 코드가 또 수정되면
        # 같은 Evidence 로는 미충족 (Task 3.1 과 동일한 무효화 축)
        validated = self._compose_delta_y()
        self._edit(b"VALUE = 3\n")
        digest_z = self._current_digest()
        requirement = CodeReviewRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((self.full_x, validated), digest=digest_z)
            )
        )

    def test_reviewed_digest_must_match_runtime_current_digest(self):
        # delta 리뷰 후 코드가 또 수정된 상태 — 리뷰가 본 Y ≠ Runtime
        # 이 계산한 현재 digest → 발급 거부 (Task 3.1 과 같은 규율)
        response = self._delta_response()
        self._edit(b"VALUE = 3\n")
        digest_z = self._current_digest()
        self.assertNotEqual(digest_z, self.digest_y)
        with self.assertRaises(ReviewDigestMismatch):
            issue_delta_review_evidence(
                response,
                (self.full_x,),
                current_digest=digest_z,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_runtime_digest_contract_violation_is_error(self):
        # 거부 부류가 아니라 호출자(Runtime) 계약 위반 — capability 와
        # 동일 방향 (digest 미확보 시 발급 시도 자체가 성립 안 함)
        for bad_digest in ("", None):
            with self.assertRaises(ValueError):
                issue_delta_review_evidence(
                    self._delta_response(),
                    (self.full_x,),
                    current_digest=bad_digest,
                    actual_changed_paths=("mod.py",),
                    policy_version="1",
                )

    def test_delta_composition_flows_through_evaluator(self):
        # churn 제거의 실체 — 같은 policy·같은 Y digest 에서 Full(X)
        # 단독은 BLOCK, Delta 합성 추가는 ALLOW (evaluator 관통)
        policy = {
            "policy_id": "review-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - code_review\n"
                "failure_mode: closed\n",
                source="<test:delta-review-gate>",
            ),
        }
        registry = RequirementRegistry()
        register_code_review(registry)
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: self.digest_y,
            FACT_POLICY_VERSION: "1",
        }
        stale = evaluator.evaluate(
            "tool.pre",
            EvaluationContext(
                facts=facts,
                evidence_source=_StubEvidenceSource((self.full_x,)),
            ),
            [policy],
            registry=registry,
        )
        self.assertEqual(stale.decision, DECISION_BLOCK)
        validated = self._compose_delta_y()
        composed = evaluator.evaluate(
            "tool.pre",
            EvaluationContext(
                facts=facts,
                evidence_source=_StubEvidenceSource(
                    (self.full_x, validated)
                ),
            ),
            [policy],
            registry=registry,
        )
        self.assertEqual(composed.decision, DECISION_ALLOW)
        self.assertEqual(composed.missing_requirements, ())


class DeltaBaseValidationTest(_DeltaChainMixin):
    """(b) — base 오염: 불명확·불신 base 는 델타 합성 거부 + full 요구."""

    def test_unknown_base_digest_requires_full_review(self):
        # base digest 가 어떤 검증 가능한 review 와도 매칭 안 됨
        # (불명확 base) → delta 로 충족 불가, full review 요구 명시 신호
        with self.assertRaises(FullReviewRequired):
            issue_delta_review_evidence(
                self._delta_response(base_digest="unreviewed-digest"),
                (self.full_x,),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_empty_prior_records_require_full_review(self):
        # 선행 evidence 자체가 없으면 base 는 정의상 불명확이다
        with self.assertRaises(FullReviewRequired):
            issue_delta_review_evidence(
                self._delta_response(),
                (),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_non_pass_base_record_requires_full_review(self):
        # subject 는 매칭돼도 result 가 PASS 어휘가 아닌 레코드는 base
        # 자격이 없다 — 불신 중간 상태를 delta 로 세탁할 수 없다
        tainted = Evidence(
            type=REQUIREMENT_NAME,
            subject=self.digest_x,
            result="NEEDS-FIX",
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_AGENT_ATTESTED,
            policy_version="1",
        )
        with self.assertRaises(FullReviewRequired):
            issue_delta_review_evidence(
                self._delta_response(),
                (tainted,),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_non_review_type_base_requires_full_review(self):
        # 같은 digest 를 subject 로 가진 다른 타입 evidence (예:
        # tests_passed)는 code_review base 가 아니다
        other_type = Evidence(
            type="tests_passed",
            subject=self.digest_x,
            result="PASS",
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_AGENT_ATTESTED,
            policy_version="1",
        )
        with self.assertRaises(FullReviewRequired):
            issue_delta_review_evidence(
                self._delta_response(),
                (other_type,),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_stale_policy_version_base_requires_full_review(self):
        # base evidence 의 policy version 이 현재 version 과 다르고 호환
        # 선언도 없으면 불신 base 다 — 합성이 version 무효화 축(spec
        # §3.4)을 세탁하면 안 된다 (직접 평가라면 미충족일 evidence 가
        # delta 경유로 신품 version evidence 가 되는 경로 차단)
        old_full = issue_code_review_evidence(
            {"verdict": VERDICT_PASS, "reviewed_digest": self.digest_x},
            current_digest=self.digest_x,
            policy_version="0",
        )
        with self.assertRaises(FullReviewRequired):
            issue_delta_review_evidence(
                self._delta_response(),
                (old_full,),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_declared_compatible_base_version_composes(self):
        # 호환성이 명시 선언된 이전 version base 만 인정 (spec §3.4 —
        # kernel policy_version_valid 재사용, 재구현 금지)
        old_full = issue_code_review_evidence(
            {"verdict": VERDICT_PASS, "reviewed_digest": self.digest_x},
            current_digest=self.digest_x,
            policy_version="0",
        )
        validated = issue_delta_review_evidence(
            self._delta_response(),
            (old_full,),
            current_digest=self.digest_y,
            actual_changed_paths=("mod.py",),
            policy_version="1",
            compatible_versions=("0",),
        )
        # 합성 산출물은 현재 version 으로 발급된다 (생성 당시 기록)
        self.assertEqual(validated.policy_version, "1")
        self.assertEqual(validated.subject, self.digest_y)

    def test_validate_delta_base_returns_matching_record(self):
        # 합성 검증 함수 단독 계약 — 매칭 base 레코드를 그대로 반환
        found = validate_delta_base(
            self.digest_x, (self.full_x,), policy_version="1"
        )
        self.assertIs(found, self.full_x)

    def test_unclear_base_digest_value_requires_full_review(self):
        # base digest 값 자체가 비었거나 문자열이 아니면 불명확 base
        for unclear in ("", None):
            with self.assertRaises(FullReviewRequired):
                validate_delta_base(
                    unclear, (self.full_x,), policy_version="1"
                )

    def test_full_review_required_is_a_distinguishable_refusal(self):
        # 호출자(Runtime)는 Task 3.1 의 공통 base 하나로 "발급되지
        # 않았다" 부류 전체를 잡고, FullReviewRequired 로 fallback
        # 경로(full review 재요청)를 구분한다
        self.assertTrue(issubclass(FullReviewRequired, ReviewEvidenceRefusal))


class DeltaChainTest(_DeltaChainMixin):
    """(c) — 체인 계약 고정: 검증된 링크 경유만 허용, 끊긴 체인은 full."""

    def test_chain_composes_through_validated_link(self):
        # X→Y→Z: Validated(Y) 는 일반 code_review Evidence 이므로 다음
        # delta 의 base 자격을 가진다 — spec 공식의 귀납 적용:
        # Validated(Y) + Delta(Y→Z) = Validated(Z)
        validated_y = self._compose_delta_y()
        self._edit(b"VALUE = 3\n")
        digest_z = self._current_digest()
        validated_z = issue_delta_review_evidence(
            self._delta_response(
                base_digest=self.digest_y, reviewed_digest=digest_z
            ),
            (self.full_x, validated_y),
            current_digest=digest_z,
            actual_changed_paths=("mod.py",),
            policy_version="1",
        )
        self.assertEqual(validated_z.subject, digest_z)
        self.assertEqual(
            validated_z.metadata[METADATA_BASE_DIGEST], self.digest_y
        )
        requirement = CodeReviewRequirement()
        self.assertTrue(
            requirement.evaluate(
                self._context(
                    (self.full_x, validated_y, validated_z),
                    digest=digest_z,
                )
            )
        )

    def test_broken_chain_requires_full_review(self):
        # 중간 링크 미검증: Y 의 Validated evidence 가 합성된 적 없는데
        # base=Y 인 delta 를 들이밀면 끊긴 체인이다 → full review 요구
        self._edit(b"VALUE = 3\n")
        digest_z = self._current_digest()
        with self.assertRaises(FullReviewRequired):
            issue_delta_review_evidence(
                self._delta_response(
                    base_digest=self.digest_y, reviewed_digest=digest_z
                ),
                (self.full_x,),  # Validated(Y) 부재 — X 만 있다
                current_digest=digest_z,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_chain_cannot_skip_over_full_anchor(self):
        # X 에서 Z 로 건너뛰는 delta 는 base=X 가 유효하므로 허용된다 —
        # 단 reviewed 가 현재 digest 와 일치해야 하며, 이는 "X 이후
        # 실변경분 전부"를 한 번에 리뷰했다는 주장이다 (base 유효 +
        # target 결합이 계약의 전부 — 중간 경유 강제는 하지 않는다)
        self._edit(b"VALUE = 3\n")
        digest_z = self._current_digest()
        validated_z = issue_delta_review_evidence(
            self._delta_response(
                base_digest=self.digest_x, reviewed_digest=digest_z
            ),
            (self.full_x,),
            current_digest=digest_z,
            actual_changed_paths=("mod.py",),
            policy_version="1",
        )
        self.assertEqual(validated_z.subject, digest_z)
        self.assertEqual(
            validated_z.metadata[METADATA_BASE_DIGEST], self.digest_x
        )


class DeltaScopeBindingTest(_DeltaChainMixin):
    """(재리뷰 2회차) — "X 이후 실변경분 한정" 의 scope 결속 축.

    digest 결합(X/Y)만으로는 "리뷰가 실제 변경분을 봤는가" 가 결속되지
    않는다 — Runtime 이 platform diff 로 계산해 주입한 실제 X→Y 변경
    경로 집합과, 리뷰가 봤다고 주장하는 경로 집합(`reviewed_paths`)이
    **집합으로 일치**해야 발급된다. 미달이든 초과든 DeltaScopeMismatch
    로 거부 (이 모듈은 집합 비교만 — 경로 해석·diff 산출은 호출자 소관).
    """

    def _issue(self, reviewed_paths, actual_changed_paths):
        return issue_delta_review_evidence(
            self._delta_response(reviewed_paths=reviewed_paths),
            (self.full_x,),
            current_digest=self.digest_y,
            actual_changed_paths=actual_changed_paths,
            policy_version="1",
        )

    def test_matching_scope_issues_with_normalized_paths(self):
        # (i) 집합 일치 → 발급. 순서·중복은 집합 비교에 영향 없고,
        # metadata 에는 정규화(정렬·중복제거)된 tuple 로 남는다 —
        # kernel ChangeSet paths 관례와 동일 형태
        validated = self._issue(
            reviewed_paths=("other.py", "mod.py", "mod.py"),
            actual_changed_paths=("mod.py", "other.py"),
        )
        self.assertEqual(
            validated.metadata[METADATA_REVIEWED_PATHS],
            ("mod.py", "other.py"),
        )

    def test_partial_review_scope_is_refused(self):
        # (ii) 미달 — 실변경 중 일부를 리뷰가 안 봤다 → 검증 공백,
        # 그 delta 는 "실변경분을 리뷰했다" 는 주장이 성립하지 않는다
        with self.assertRaises(DeltaScopeMismatch):
            self._issue(
                reviewed_paths=("mod.py",),
                actual_changed_paths=("mod.py", "other.py"),
            )

    def test_phantom_review_scope_is_refused(self):
        # (iii) 초과 — 실제로 변경되지 않은 경로를 봤다고 주장 →
        # response 자체를 신뢰할 수 없다 (미달과 대칭으로 거부)
        with self.assertRaises(DeltaScopeMismatch):
            self._issue(
                reviewed_paths=("mod.py", "ghost.py"),
                actual_changed_paths=("mod.py",),
            )

    def test_scope_mismatch_is_a_distinguishable_refusal(self):
        # FullReviewRequired 와 다른 부류다 — base 상태는 유효하므로
        # 올바른 범위의 delta 재리뷰로 해소 가능. 공통 base 계약은 유지
        self.assertTrue(issubclass(DeltaScopeMismatch, ReviewEvidenceRefusal))
        self.assertFalse(issubclass(DeltaScopeMismatch, FullReviewRequired))

    def test_actual_changed_paths_caller_contract_violations(self):
        # 거부 부류가 아니라 호출자(Runtime) 계약 위반 — 실변경 경로
        # 집합을 확보하지 못했으면 결속 판정 자체가 성립하지 않는다
        with self.assertRaises(TypeError):
            # 문자열 단일값은 문자 단위 분해 오인정 위험 — 명시 거부
            self._issue(
                reviewed_paths=("mod.py",), actual_changed_paths="mod.py"
            )
        for bad_actual in ((), ("mod.py", ""), ("mod.py", 42)):
            with self.assertRaises(ValueError):
                self._issue(
                    reviewed_paths=("mod.py",),
                    actual_changed_paths=bad_actual,
                )


class RepoRelativePathContractTest(_DeltaChainMixin):
    """(재리뷰 3회차) — 상대경로 계약의 강제: 절대경로류는 양쪽에서 거부.

    "저장소 상대 경로만 metadata 에 싣는다" 는 방향은 검사 없이는 계약이
    아니다 — 리뷰어가 `/Users/.../secret.py` 절대경로가 발급 metadata 에
    그대로 실리는 걸 재현했다 (사적 경로 유출). 화이트리스트 방향으로
    허용 형태(슬래시 구분, 비어있지 않은 일반 세그먼트)를 정의하고
    나머지 전부 거부한다: POSIX 절대·드라이브 문자·백슬래시·`..`/`.`
    세그먼트·빈 세그먼트·NUL. 기존 분리 유지 — reviewed_paths 위반 =
    응답 파싱 거부(MalformedReviewResponse), actual_changed_paths 위반 =
    호출자 계약 위반(ValueError).
    """

    # 리뷰어 재현 경로 + 대표 위반 형태들 (화이트리스트 밖 전부)
    BAD_PATHS = (
        "/Users/alice/private/project/secret.py",  # POSIX 절대 (재현)
        "C:secret.py",  # 드라이브 문자
        "C:/repo/mod.py",  # 드라이브 문자 + 슬래시
        "dir\\mod.py",  # 백슬래시 (Windows 구분자 미정규화)
        "../mod.py",  # 상위 탈출 세그먼트
        "dir/../mod.py",  # 중간 .. 세그먼트
        "dir//mod.py",  # 빈 세그먼트
        "mod.py/",  # 트레일링 슬래시 → 빈 세그먼트
        "./mod.py",  # 비정규 . 세그먼트
        "mod\x00.py",  # NUL
    )

    def test_non_relative_reviewed_paths_are_refused(self):
        # 응답 측 위반 — strict 파싱 거부 (actual 은 유효 상대경로)
        for bad in self.BAD_PATHS:
            with self.assertRaises(MalformedReviewResponse, msg=bad):
                issue_delta_review_evidence(
                    self._delta_response(reviewed_paths=("mod.py", bad)),
                    (self.full_x,),
                    current_digest=self.digest_y,
                    actual_changed_paths=("mod.py",),
                    policy_version="1",
                )

    def test_non_relative_actual_changed_paths_are_refused(self):
        # 호출자 측 위반 — 발급 시도 자체가 성립 안 하는 계약 위반
        for bad in self.BAD_PATHS:
            with self.assertRaises(ValueError, msg=bad):
                issue_delta_review_evidence(
                    self._delta_response(),
                    (self.full_x,),
                    current_digest=self.digest_y,
                    actual_changed_paths=("mod.py", bad),
                    policy_version="1",
                )

    def test_reviewer_reproduced_leak_path_is_now_refused(self):
        # 리뷰어 재현 시나리오 고정 — 절대경로가 양쪽에 일치 주입돼도
        # (이전엔 집합 일치로 발급 + metadata 탑재) 이제 발급 자체가
        # 거부되어 metadata 에 절대경로가 실릴 경로가 없다
        leak = "/Users/alice/private/project/secret.py"
        # 호출자 측이 먼저 걸린다 (검사 순서: 호출자 계약 → 파싱)
        with self.assertRaises(ValueError):
            issue_delta_review_evidence(
                self._delta_response(reviewed_paths=(leak,)),
                (self.full_x,),
                current_digest=self.digest_y,
                actual_changed_paths=(leak,),
                policy_version="1",
            )
        # 호출자 입력이 정상이어도 응답 측 절대경로는 독립적으로 거부
        with self.assertRaises(MalformedReviewResponse):
            issue_delta_review_evidence(
                self._delta_response(reviewed_paths=(leak,)),
                (self.full_x,),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_nested_relative_path_is_allowed(self):
        # 화이트리스트가 정상 형태를 과차단하지 않는다 — 하위 디렉토리
        # 상대경로는 발급되고 정규화 tuple 로 metadata 에 남는다
        validated = issue_delta_review_evidence(
            self._delta_response(reviewed_paths=("pkg/sub/mod.py",)),
            (self.full_x,),
            current_digest=self.digest_y,
            actual_changed_paths=("pkg/sub/mod.py",),
            policy_version="1",
        )
        self.assertEqual(
            validated.metadata[METADATA_REVIEWED_PATHS], ("pkg/sub/mod.py",)
        )


class DeltaResponseParsingTest(_DeltaChainMixin):
    """(d) — strict 파싱: 결손·형식 위반·verdict 비PASS 는 명시 거부."""

    def _assert_malformed(self, response):
        with self.assertRaises(MalformedReviewResponse):
            issue_delta_review_evidence(
                response,
                (self.full_x,),
                current_digest=self.digest_y,
                actual_changed_paths=("mod.py",),
                policy_version="1",
            )

    def test_non_mapping_response_is_refused(self):
        # 자유 텍스트를 structured delta response 로 승격하지 않는다
        self._assert_malformed("PASS")
        self._assert_malformed(None)
        self._assert_malformed([VERDICT_PASS, self.digest_x, self.digest_y])

    def test_missing_required_fields_are_refused(self):
        self._assert_malformed({})
        response = self._delta_response()
        for field_name in (
            "verdict",
            RESPONSE_FIELD_BASE_DIGEST,
            "reviewed_digest",
            RESPONSE_FIELD_REVIEWED_PATHS,
        ):
            partial = dict(response)
            del partial[field_name]
            self._assert_malformed(partial)

    def test_empty_or_non_string_fields_are_refused(self):
        self._assert_malformed(self._delta_response(verdict=""))
        self._assert_malformed(self._delta_response(base_digest=""))
        self._assert_malformed(self._delta_response(reviewed_digest=""))
        self._assert_malformed(self._delta_response(verdict=True))
        self._assert_malformed(self._delta_response(base_digest=42))

    def test_malformed_reviewed_paths_are_refused(self):
        # 빈 목록(아무것도 안 봤다는 delta), 컬렉션 아닌 값, 문자열
        # 단일값(문자 단위 분해 오인정 위험 — kernel compatible_versions
        # 규율과 동일 방향), 비문자열·빈 문자열 원소 전부 strict 거부
        self._assert_malformed(self._delta_response(reviewed_paths=()))
        self._assert_malformed(self._delta_response(reviewed_paths=42))
        response = self._delta_response()
        response[RESPONSE_FIELD_REVIEWED_PATHS] = "mod.py"
        self._assert_malformed(response)
        self._assert_malformed(
            self._delta_response(reviewed_paths=("mod.py", 42))
        )
        self._assert_malformed(
            self._delta_response(reviewed_paths=("mod.py", ""))
        )

    def test_delta_without_actual_change_is_refused(self):
        # base == reviewed 는 변경분이 없다 — "Delta 대상은 X 이후 실제
        # 변경분으로 제한" (spec §3.6) 을 구조적으로 위반한 응답이다
        self._assert_malformed(
            self._delta_response(
                base_digest=self.digest_y, reviewed_digest=self.digest_y
            )
        )

    def test_non_pass_verdict_is_refused(self):
        # delta 리뷰가 변경분에서 문제를 찾음 (NEEDS-FIX) — 합성 없음.
        # 관대한 해석 금지: 대소문자·공백 변형도 PASS 로 승격 안 함
        for verdict in ("NEEDS-FIX", "pass", "Pass", " PASS", "PASS "):
            with self.assertRaises(ReviewVerdictNotPass):
                issue_delta_review_evidence(
                    self._delta_response(verdict=verdict),
                    (self.full_x,),
                    current_digest=self.digest_y,
                    actual_changed_paths=("mod.py",),
                    policy_version="1",
                )


if __name__ == "__main__":
    unittest.main()
