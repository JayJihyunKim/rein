"""spec §3.6 판정 상태표 — valid-evidence authority 게이팅 전조합 고정
(2026-08-20 신설, Phase 7 웨이브 3 ③-a. **2026-08-24 웨이브 3 ③-d 로
전면 갱신** — legacy marker dual-read 계층 전체가 제거되며 "전환기
(TRANSITION)" 읽기와 "제거 후(END-STATE)" 읽기가 이제 **항상 동일한
결과**를 낸다).

Scope ID `authority-switches-per-capability-with-dual-read-of-legacy-
markers` 의 "판정 상태표 전조합 고정" 요구를 이 파일이 담당한다. ③-d
이전에는 아래 표의 두 열이 실제로 갈렸다(legacy 신선 표식이 무효/부재
v2 evidence 를 구제할 수 있었다):

    유효 v2 ↔ legacy 충돌 → v2 우선                     (양쪽 동일, 불변)
    subject 불일치(stale) + 신선 legacy → legacy 판정     (③-d: 항상 미충족)
    subject 일치 + policy version 무효 + 신선 legacy → legacy 판정
                                                          (③-d: 항상 미충족)
    subject 일치 + result 불충족 + 신선 legacy → legacy 판정
                                                          (③-d: 항상 미충족)
    유효 v2 없음 + legacy 없음 → 미충족                   (양쪽 동일, 불변)
    subject-empty → 전환기: legacy 판정 / 제거 후: 충족   (③-d: 항상 충족)
    subject-unresolved → 전환기: legacy 판정 / 제거 후: 미충족
                                                          (③-d: 항상 미충족)

**③-d 갱신 핵심**: legacy marker 대체가 제거됨에 따라, 등록 구현체
(`CodeReviewRequirement.evaluate`/`SecurityReviewRequirement.evaluate`)
가 이미 구현하는 종국 상태표가 이제 `evaluator._requirement_satisfied()`
를 거쳐 **authority 활성 여부·legacy marker 존재 여부와 무관하게** 그대로
최종 Decision 에 반영된다. 아래 클래스들은 그 사실 자체를 고정한다 —
"전환기" 읽기(`_transition_decision`, `project_root` 실제 경로 + legacy
marker fixture)와 "제거 후" 읽기(`_end_state_decision`, authority 완전
비활성)가 이제 **항상 같은 Decision** 을 낸다는 것을, legacy marker 를
일부러 "신선 PASS 로 씀"과 "아예 안 씀(부재)" 양쪽으로 갈라 증명한다 —
marker 가 있어도 결과가 달라지지 않는다는 것이 곧 "legacy 가 판정에
불참한다"는 계약의 행위 증거다.

`tests/migration/test_authority_wiring.py` 는 배선 자체(project_root
sentinel 구분, registry 배선, 미전환 축 등)를 고정하고,
`tests/migration/test_authority_dual_read.py` 는 `rein.engine.authority`
모듈 자체(정책 로드, `resolve_authority` 결합 규칙 — ③-d 이후로는 legacy
marker 파싱 자체가 없다)를 고정한다 — 이 파일은 그 위에서
**`evaluator._requirement_satisfied()` 의 valid-evidence 게이팅**이
상태표의 각 행을 실제로 만들어내는지를 확인한다.

code_review 를 대표 축으로 쓴다 — `CrossCapabilityMappingSharedTest`
하나만 security_review 로도 같은 공식이 적용됨을 교차 확인한다(매핑이
code_review 전용 특례가 아니라 `authority.CURRENT_SUBJECT_FACT_KEYS`
공유 축임을 보인다).
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
    FACT_POLICY_VERSION as REVIEW_POLICY_VERSION,
    REQUIREMENT_NAME as CODE_REVIEW,
    VERDICT_PASS as CODE_REVIEW_PASS,
    register_code_review,
)
from rein.capabilities.security.capability import (  # noqa: E402
    FACT_CHANGESET_SENSITIVE_DIGEST,
    FACT_POLICY_VERSION as SECURITY_POLICY_VERSION,
    REQUIREMENT_NAME as SECURITY_REVIEW,
    VERDICT_PASS as SECURITY_REVIEW_PASS,
    register_security_review,
)
from rein.engine import evaluator  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.changeset import SUBJECT_EMPTY, SUBJECT_UNRESOLVED  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK  # noqa: E402
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
)

_EVENT = "tool.pre"
_REAL_SUBJECT = "sha256:" + "a" * 64
_OTHER_SUBJECT = "sha256:" + "b" * 64


class _StubEvidenceSource:
    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        return tuple(
            record for record in self._records if record.type == requirement_name
        )


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _dod_dir(project_root):
    return os.path.join(project_root, "trail", "dod")


def _write_fresh_codex_stamp(project_root, verdict="PASS"):
    """legacy `.codex-reviewed` PASS 표식 — ③-d 이후로는 authority 가
    이 파일을 전혀 읽지 않는다. 이 헬퍼가 남아있는 이유는 "표식이
    디스크에 있어도 판정에 참여하지 않는다"를 행위로 증명하기
    위해서다(marker 는 이제 inert fixture)."""
    _write(
        os.path.join(_dod_dir(project_root), ".codex-reviewed"),
        "verdict: {}\nreviewed_at: 2026-08-20T00:00:00Z\ncycle: 1\n".format(
            verdict
        ),
    )


def _write_fresh_security_stamp(project_root, verdict="PASS"):
    """legacy `.security-reviewed` PASS 표식 (+ `.codex-reviewed`) —
    ③-d 이후로는 두 파일 모두 authority 판정에서 읽히지 않는다(inert
    fixture, 위 `_write_fresh_codex_stamp` 참조)."""
    _write_fresh_codex_stamp(project_root, verdict="PASS")
    _write(
        os.path.join(_dod_dir(project_root), ".security-reviewed"),
        "verdict={}\nreviewed=2026-08-20T00:00:01\ncycle=1\n".format(verdict),
    )


def _policy(policy_id, require):
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            "trigger: {}\nrequire:\n{}failure_mode: closed\n".format(
                _EVENT, "".join("  - {}\n".format(name) for name in require)
            ),
            source="<test:{}>".format(policy_id),
        ),
    }


def _code_review_registry():
    registry = RequirementRegistry()
    register_code_review(registry)
    return registry


def _security_registry():
    registry = RequirementRegistry()
    register_security_review(registry)
    return registry


def _code_review_evidence(subject, version="1", result=CODE_REVIEW_PASS):
    """`issue_code_review_evidence()` 를 우회해 직접 구성한다 — 발급
    함수는 verdict != PASS 를 거부하므로("result 불충족" 조합을 만들려면
    발급 게이트를 통과할 수 없다, spec §3.6 판정 상태표의 그 행이 요구하는
    '구성만 가능하고 발급은 불가능한' 상태를 이 헬퍼가 대신한다)."""
    return Evidence(
        type=CODE_REVIEW,
        subject=subject,
        result=result,
        created_at="2026-08-20T00:00:00+00:00",
        producer=PRODUCER_AGENT_ATTESTED,
        policy_version=version,
    )


def _security_evidence(subject, version="1", result=SECURITY_REVIEW_PASS):
    return Evidence(
        type=SECURITY_REVIEW,
        subject=subject,
        result=result,
        created_at="2026-08-20T00:00:00+00:00",
        producer=PRODUCER_AGENT_ATTESTED,
        policy_version=version,
    )


def _transition_decision(
    policy, registry, facts, records, project_root, legacy="fresh_pass"
):
    """authority 활성 읽기 — 실 project_root(trail/dod fixture 포함)로
    `evaluator.evaluate()` 를 호출한다. `legacy`: "fresh_pass"(신선 PASS
    표식 기록) 또는 "absent"(아무 표식도 쓰지 않음).

    **③-d 갱신** — 이 이름은 ③-a 시절("authority dual-read 가 실제로
    개입해 legacy 로 대체될 수 있는 읽기")의 유산이다. legacy 대체 자체가
    제거된 지금, `legacy="fresh_pass"` 와 `legacy="absent"` 는 이제
    **항상 같은 Decision** 을 낸다 — 이 함수가 여전히 두 변형을 받는
    이유는 그 동등성 자체(marker 존재가 결과를 바꾸지 않음)를 각 테스트가
    명시적으로 증명하기 위해서다.
    """
    if legacy == "fresh_pass":
        if CODE_REVIEW in policy["fields"]["require"]:
            _write_fresh_codex_stamp(project_root)
        if SECURITY_REVIEW in policy["fields"]["require"]:
            _write_fresh_security_stamp(project_root)
    elif legacy != "absent":
        raise ValueError("legacy must be 'fresh_pass' or 'absent'")
    context = EvaluationContext(
        facts=facts, evidence_source=_StubEvidenceSource(records)
    )
    return evaluator.evaluate(
        _EVENT, context, [policy], registry=registry, project_root=project_root
    )


def _end_state_decision(policy, registry, facts, records):
    """authority 완전 비활성 읽기 — project_root 를 아예 주지 않는다
    (`PROJECT_ROOT_NOT_PROVIDED` sentinel). 남는 것은 등록 구현체의
    `evaluate()`(=v2_satisfied) 뿐이다. ③-d 이후로는 이 읽기가
    `_transition_decision` 과 항상 동일한 Decision 을 낸다 — 두 읽기
    경로가 서로 다른 코드(authority 활성 vs 비활성)를 지나면서도 같은
    결과에 도달한다는 것 자체가 이 파일이 고정하는 계약이다.
    """
    context = EvaluationContext(
        facts=facts, evidence_source=_StubEvidenceSource(records)
    )
    return evaluator.evaluate(_EVENT, context, [policy], registry=registry)


# ---------------------------------------------------------------------------
# 1. 유효 v2 ↔ legacy 표식 상충 → v2 승 (③-d 로도 불변 — legacy 표식은
#    애초에 읽히지 않으므로 "상충"이라는 개념 자체가 이제 무의미하지만,
#    marker 가 어떤 내용이든 결과에 개입하지 않는다는 것을 계속 고정한다).


class ValidV2WinsOverConflictingLegacyTest(unittest.TestCase):
    def test_valid_matching_evidence_allows_regardless_of_legacy_marker_content(
        self,
    ):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "1",
        }
        evidence = _code_review_evidence(_REAL_SUBJECT, version="1")

        with tempfile.TemporaryDirectory() as project_root:
            # legacy 표식은 NEEDS-FIX(FAIL) 내용이지만 ③-d 이후로는 아예
            # 읽히지 않는다 — v2 가 유효하면 그대로 이긴다.
            _write_fresh_codex_stamp(project_root, verdict="NEEDS-FIX")
            decision = evaluator.evaluate(
                _EVENT,
                EvaluationContext(
                    facts=facts,
                    evidence_source=_StubEvidenceSource((evidence,)),
                ),
                [policy],
                registry=registry,
                project_root=project_root,
            )
        self.assertEqual(decision.decision, DECISION_ALLOW)


# ---------------------------------------------------------------------------
# 2. subject 불일치(stale v2 evidence) → 항상 미충족 (③-d 갱신 — 이전에는
#    신선 legacy 가 이 상태를 구제할 수 있었다).


class StaleSubjectMismatchAlwaysBlocksTest(unittest.TestCase):
    """③-d 이전 이름: StaleSubjectMismatchDefersToLegacyTest — legacy
    marker 대체가 제거되며 두 변형(fresh_pass/absent)이 이제 같은 결과
    (BLOCK)로 수렴한다. 클래스를 남기고 이름·둘째 메서드 이름·표식
    변형의 기대값만 갱신한다(무대체 소멸 아님 — 같은 시나리오의 종국
    상태표 판정으로 이관)."""

    def test_subject_mismatch_blocks_even_with_fresh_legacy_marker_present(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "1",
        }
        # evidence 의 subject 는 다른 값 — 현재 subject 와 불일치(stale).
        evidence = _code_review_evidence(_OTHER_SUBJECT, version="1")

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "fresh_pass"
            )
        # ③-d: 신선 legacy PASS 표식이 있어도 stale v2 evidence 는
        # 구제되지 않는다 — 종국 상태표의 "non-empty+무효 → 미충족" 행.
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_subject_mismatch_with_absent_legacy_is_unmet(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "1",
        }
        evidence = _code_review_evidence(_OTHER_SUBJECT, version="1")

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


# ---------------------------------------------------------------------------
# 3. subject 일치 + policy version 무효 → 항상 미충족 (③-d 갱신).


class SubjectMatchInvalidPolicyVersionTest(unittest.TestCase):
    def test_blocks_even_with_fresh_legacy_marker_present(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "2",  # 현재 version
        }
        # evidence 는 subject 일치하지만 version="1"(현재="2") — 호환
        # 선언 없음 → policy_version_valid() False.
        evidence = _code_review_evidence(_REAL_SUBJECT, version="1")

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "fresh_pass"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_with_absent_legacy_is_unmet(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "2",
        }
        evidence = _code_review_evidence(_REAL_SUBJECT, version="1")

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


# ---------------------------------------------------------------------------
# 4. subject 일치 + result 불충족(policy version 유효) → 항상 미충족
#    (③-d 갱신).


class SubjectMatchUnsatisfiedResultTest(unittest.TestCase):
    def test_blocks_even_with_fresh_legacy_marker_present(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "1",
        }
        # subject·version 은 정확히 일치하지만 result 가 PASS 가 아니다
        # — 발급 게이트로는 만들 수 없는 상태라 직접 구성한다(위
        # `_code_review_evidence` docstring 참조).
        evidence = _code_review_evidence(
            _REAL_SUBJECT, version="1", result="NEEDS-FIX"
        )

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "fresh_pass"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_with_absent_legacy_is_unmet(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "1",
        }
        evidence = _code_review_evidence(
            _REAL_SUBJECT, version="1", result="NEEDS-FIX"
        )

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


# ---------------------------------------------------------------------------
# 5. 유효 v2 없음 + legacy 없음 → 미충족 (양쪽 이전부터 불변).


class NoValidV2NoLegacyIsUnmetTest(unittest.TestCase):
    def test_no_evidence_no_legacy_blocks(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        facts = {
            FACT_CHANGESET_REVIEW_DIGEST: _REAL_SUBJECT,
            REVIEW_POLICY_VERSION: "1",
        }
        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


# ---------------------------------------------------------------------------
# 6/7. SUBJECT_EMPTY / SUBJECT_UNRESOLVED — ③-d 이후로는 authority 활성
#      읽기와 완전 비활성 읽기가 항상 같은 Decision 을 낸다. marker 유무도
#      결과를 바꾸지 않는다 — 세 읽기(활성+신선 marker / 활성+marker 부재
#      / 완전 비활성) 모두 같은 값으로 수렴한다는 것 자체가 이 클래스들이
#      고정하는 계약이다.


class SubjectEmptyStateTableTest(unittest.TestCase):
    """SUBJECT_EMPTY → 종국 상태표: 충족(ALLOW). ③-d 이전에는 authority
    활성 + legacy 부재 조합만 예외적으로 BLOCK 이었다("전환기 지배
    원리" — 유효한 v2 증거가 없으면 v1 판정 보존). 그 예외가 사라져
    이제 세 읽기 전부 ALLOW 로 수렴한다."""

    def _facts(self):
        return {
            FACT_CHANGESET_REVIEW_DIGEST: SUBJECT_EMPTY,
            REVIEW_POLICY_VERSION: "1",
        }

    def test_authority_active_with_fresh_legacy_marker_allows(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, self._facts(), (), project_root, "fresh_pass"
            )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_authority_active_with_absent_legacy_marker_still_allows(self):
        # ③-d 갱신 — 이전 이름은
        # test_transition_with_absent_legacy_blocks 였고 BLOCK 을
        # 기대했다("legacy 부재 = v1 이라면 미검토였을 상태 = 아직
        # 충족으로 승격 안 함"). legacy 대체가 제거된 지금은 v2 의
        # subject-empty→충족 판정이 marker 유무와 무관하게 그대로
        # 최종값이다 — 이 테스트가 그 반전을 고정한다(spec §3.6 종국
        # 상태표 "subject-empty → 충족" 행, marker 파일이 없어도 —
        # 있어도 — 판정에 불참한다는 계약을 이 클래스가 함께 증명).
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, self._facts(), (), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_authority_fully_inactive_also_allows(self):
        # authority 완전 비활성(project_root 없음) — v2_satisfied 단독
        # (SUBJECT_EMPTY → True, end-state 의미론)이 최종 판정이다. 위
        # 두 테스트와 항상 동일한 값(ALLOW)으로 수렴한다.
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        decision = _end_state_decision(policy, registry, self._facts(), ())
        self.assertEqual(decision.decision, DECISION_ALLOW)


class SubjectUnresolvedStateTableTest(unittest.TestCase):
    """SUBJECT_UNRESOLVED → 종국 상태표: 미충족(BLOCK). ③-d 이전에는
    authority 활성 + legacy 신선 PASS 조합만 예외적으로 ALLOW 였다(산정
    불가라도 legacy 가 신선 PASS 면 통과). 그 예외가 사라져 이제 세
    읽기 전부 BLOCK 으로 수렴한다."""

    def _facts(self):
        return {
            FACT_CHANGESET_REVIEW_DIGEST: SUBJECT_UNRESOLVED,
            REVIEW_POLICY_VERSION: "1",
        }

    def test_authority_active_blocks_even_with_fresh_legacy_marker_present(self):
        # ③-d 갱신 — 이전 이름은
        # test_transition_with_fresh_legacy_pass_allows 였고 ALLOW 를
        # 기대했다("산정 자체가 불가한 상태라도 legacy 가 신선 PASS 면
        # 통과"). legacy 대체가 제거된 지금은 신선 PASS 표식이 있어도
        # subject-unresolved 의 보수적 미충족 판정을 뒤집지 못한다 —
        # 이 테스트가 그 반전을 고정한다.
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, self._facts(), (), project_root, "fresh_pass"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_authority_active_with_absent_legacy_blocks(self):
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, self._facts(), (), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_authority_fully_inactive_also_blocks(self):
        # 제거 후 — v2 단독 보수 미충족이 발효(발급기가 sentinel 을
        # 거부하므로 증거로 치유할 수 없다, spec §3.6 판정 상태표 각주).
        policy = _policy("p", require=[CODE_REVIEW])
        registry = _code_review_registry()
        decision = _end_state_decision(policy, registry, self._facts(), ())
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


# ---------------------------------------------------------------------------
# 교차 확인 — 매핑이 code_review 전용이 아니라 security_review 에도 같은
# 공식으로 적용된다(단일 정본 `authority.CURRENT_SUBJECT_FACT_KEYS`).


class CrossCapabilityMappingSharedTest(unittest.TestCase):
    def test_security_review_stale_subject_blocks_even_with_fresh_legacy_marker(
        self,
    ):
        # ③-d 갱신 — 이전 이름은
        # test_security_review_stale_subject_defers_to_fresh_legacy 였고
        # ALLOW 를 기대했다. code_review 축의
        # StaleSubjectMismatchAlwaysBlocksTest 와 대칭되는 반전.
        policy = _policy("p", require=[SECURITY_REVIEW])
        registry = _security_registry()
        facts = {
            FACT_CHANGESET_SENSITIVE_DIGEST: _REAL_SUBJECT,
            SECURITY_POLICY_VERSION: "1",
        }
        evidence = _security_evidence(_OTHER_SUBJECT, version="1")

        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (evidence,), project_root, "fresh_pass"
            )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (SECURITY_REVIEW,))

    def test_security_review_subject_empty_end_state_allows(self):
        policy = _policy("p", require=[SECURITY_REVIEW])
        registry = _security_registry()
        facts = {
            FACT_CHANGESET_SENSITIVE_DIGEST: SUBJECT_EMPTY,
            SECURITY_POLICY_VERSION: "1",
        }
        decision = _end_state_decision(policy, registry, facts, ())
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_security_review_subject_empty_authority_active_reading_also_allows(
        self,
    ):
        # 위 end-state 읽기와 authority 활성 읽기(legacy marker 부재)가
        # 같은 값으로 수렴하는지 security_review 축에서도 확인한다
        # (code_review 축의 SubjectEmptyStateTableTest 와 대칭).
        policy = _policy("p", require=[SECURITY_REVIEW])
        registry = _security_registry()
        facts = {
            FACT_CHANGESET_SENSITIVE_DIGEST: SUBJECT_EMPTY,
            SECURITY_POLICY_VERSION: "1",
        }
        with tempfile.TemporaryDirectory() as project_root:
            decision = _transition_decision(
                policy, registry, facts, (), project_root, "absent"
            )
        self.assertEqual(decision.decision, DECISION_ALLOW)


if __name__ == "__main__":
    unittest.main()
