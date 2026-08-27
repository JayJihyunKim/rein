"""plan Task 4.4 — 기본 Policy 세트 강제 시점 (spec §3.6, §11.1, §5.2).

spec §11.1 원문 인용:
    "commit → code_review만 요구
    push → tests_passed 요구
    release → tests_passed + code_review + security_review"

spec §3.6 원문 인용 (강제 시점 설명):
    "강제 시점은 Policy 가 결정 (§11.1): 기본 세트 = commit 은
    code_review 만, push 는 tests_passed 추가, release 는
    tests_passed+code_review+security_review — TDD Red 단계·중간
    commit 을 과차단하지 않는다."

spec §5.2 원문 인용 (미선언 프로젝트 처리, 확정):
    "기본 Policy 세트의 tests_passed 요구 조항은 testing.configured
    fact 가 true 일 때만 활성화된다(온보딩 마찰 방지 — 미선언
    프로젝트의 push 를 막지 않고 doctor 가 설정을 안내). 프로젝트가
    policy 를 직접 켜서 강제하는 경우, 미선언 상태의 tests_passed
    요구는 정상 평가 BLOCK 이다(reason = "선언된 테스트 명령 없음";
    판단 실패가 아니므로 failure_mode 비적용)."

## 배포물 위치 — policies/default/ (scope 확장 승인, 로더 계약 불변)

`kernel/policy.py` 의 policy 로더는 YAML **파일 1개 = 정책 1개**만
표현한다(`trigger`/`when`/`require`/`failure_mode` 스칼라 4필드
tuple 정확히 하나 — 최상위 매핑 밖 구조·다중 문서·시퀀스는 로드 시점
명시 에러, `tests/unit/test_policy_loader_closure.py` 전수 고정).
따라서 "commit 은 code_review 만 / push 는 조건부 tests_passed 추가 /
release 는 셋 다" 처럼 서로 다른 (when, require) 조합을 갖는 정책
"세트"는 파일 여러 개로만 표현 가능하다 — 로더 계약을 바꾸지 않고
(변경 금지 결정) 정책 4개를 별도 파일로 분리했다:
`commit.yaml` / `push.yaml` / `push-testing.yaml` / `release.yaml`.

이 4개를 `plugins/rein-core/policies/` **바로 아래**가 아니라
`plugins/rein-core/policies/default/` 하위 디렉토리에 둔 이유 —
`load_policies(dir)` 는 지정 디렉토리의 `*.yaml` 전부를 이 4필드
스키마로 파싱한다. `policies/` 바로 아래에는 이미 `tags.yaml`
(경로→Tag 분류 규칙, 최상위 필드가 `rules:` — 이 스키마와 다름)이
있으므로, 같은 디렉토리에 두면 `load_policies("plugins/rein-core/
policies")` 호출이 `tags.yaml` 을 만나는 순간 "unsupported policy
field 'rules'" 로 깨진다. `DirectoryIsolationTest` 가 이 충돌이 실제로
재현됨(따라서 하위 디렉토리 분리가 임의 취향이 아니라 필요조건임)을
직접 실증한다.

## Phase 7 결정 1 갱신 (2026-08-19 사용자 결정) — task.exists 조건화

`dod-2026-08-19-v2-phase7-legacy.md` 선행 결정 4종 중 1 — commit.yaml/
push.yaml 의 `when:` 에 `task.exists: "true"` 가 추가됐다(v1 "활성
작업 없으면 소스 편집이 애초에 차단되므로 리뷰할 변경이 없다" 의미론
재현, `rein.platform.task.facts.task_exists()` 가 값을 낸다 —
testing.configured 와 동일한 "문자열 또는 부재" 계약). 아래 (a)/(b)
의 "code_review 만 요구" 서술은 이제 **task.exists="true" 인 문맥에서만**
성립한다 — task.exists 가 부재(활성 작업 없음)면 그 요구 자체가
미매칭으로 사라진다(release tier, (c)는 이 결정의 범위 밖 — 조건 없이
그대로 유지, `ReleaseTierUnconditionedByTaskExistsTest` 가 이를
`tests/contract/test_commit_policy_task_conditioning.py` 에서 고정).
`_context()`/`_evaluate()` 의 `task_exists` 인자가 이 축을 주입한다.

## 검증 축 (plan Task 4.4 Steps)

(a) commit tier — testing.configured 유무와 무관하게, **활성 작업이
    있으면(task.exists="true")** code_review 만 요구 (2 sub-case:
    evidence 있음 ALLOW / 없음 BLOCK). 활성 작업이 없으면(task.exists
    부재) 그 요구 자체가 미매칭되어 무조건 ALLOW.
(b) push tier × testing 설정 유무 4분면 (아래는 모두 **활성 작업이
    있는** 문맥 — task.exists 부재 시의 대응 케이스는 별도로 명시):
    - 설정 O + 둘 다 충족 → ALLOW
    - 설정 O + tests_passed 만 결여 → BLOCK(missing=[tests_passed])
    - 설정 X + code_review 만 있음 → ALLOW (tests_passed 미요구)
    - 설정 X + code_review 도 없음 → BLOCK(missing=[code_review],
      tests_passed 는 missing 목록에 없음 — 애초에 요구되지 않았음을
      구분)
(c) release 조합 1케이스 — 세 evidence 모두 충족 시 ALLOW, 하나라도
    결여 시 BLOCK(missing 목록에 정확히 그 이름만).
(d) 미선언 + 프로젝트가 policy 를 직접 켜서 강제 — 기본 세트가 아닌
    프로젝트 자체 정책(이 테스트가 인라인으로 구성)이 push 에
    tests_passed 를 무조건 요구하면, testing 미설정 상태에서도 정상
    평가 BLOCK 이다(REASON_MISSING_EVIDENCE) — failure_mode 분기가
    아님을 reason 문자열로 구분해 확인한다.
(e) 사이클 B 리뷰 1회차 Medium 지적 — `command.type=git.tag` 는
    release(`git tag v1.2.3`) 뿐 아니라 태그 조회(`git tag -l`)·삭제
    (`git tag -d`)도 구분 없이 매칭한다(분류기가 인자를 해석하지
    않으므로). 이 사이클에서는 인자 기반 정밀 구분을 채택하지 않고
    (분류기의 "플래그 의미 추측 금지" 철학과 충돌) 과근사를 의도된
    보수 방향으로 고정한다 — `TagQueryOverApproximationTest` 가 현재
    행위를 숨기지 않고 명시적으로 pin 한다(정밀화는 release fact
    resolver 배선 소관, 백로그로 이연).

실제 로더(`kernel.policy.load_policies`) + 실제 Requirement 구현체
(`register_code_review`/`register_tests_passed`/`register_security_review`)
+ `engine.evaluator.evaluate` 를 전부 관통한다 — synthetic 파서/평가
경로를 별도로 만들지 않는다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.capabilities.review.capability import (  # noqa: E402
    FACT_CHANGESET_REVIEW_DIGEST as CODE_REVIEW_DIGEST_FACT,
    REQUIREMENT_NAME as CODE_REVIEW,
    VERDICT_PASS as CODE_REVIEW_PASS,
    register_code_review,
)
from rein.capabilities.security.capability import (  # noqa: E402
    FACT_CHANGESET_SENSITIVE_DIGEST,
    REQUIREMENT_NAME as SECURITY_REVIEW,
    VERDICT_PASS as SECURITY_REVIEW_PASS,
    register_security_review,
)
from rein.capabilities.testing.capability import (  # noqa: E402
    FACT_CHANGESET_DIGEST as TESTS_PASSED_DIGEST_FACT,
    FACT_CHANGESET_TAG,
    REQUIREMENT_NAME as TESTS_PASSED,
    VERDICT_PASS as TESTS_PASSED_PASS,
    register_tests_passed,
)
from rein.engine import command_classifier, evaluator  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK  # noqa: E402
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    PRODUCER_RUNTIME_VERIFIED,
)

# 배포 기본값 경로 — tags.py 의 _PLUGIN_ROOT 유도와 동일 관례
_POLICIES_ROOT = os.path.join(_PLUGIN_ROOT, "policies")
DEFAULT_POLICY_DIR = os.path.join(_POLICIES_ROOT, "default")

_EVENT = "tool.pre"
_FACT_COMMAND_TYPE = "command.type"
_FACT_POLICY_VERSION = "policy.version"
_FACT_TESTING_CONFIGURED = "testing.configured"
# Phase 7 결정 1 (2026-08-19 사용자 결정) — commit.yaml/push.yaml 의
# `when: task.exists: "true"` 조건화가 소비하는 fact. `testing_
# configured` 와 동일한 "문자열 또는 부재" 계약(_context() 참조).
_FACT_TASK_EXISTS = "task.exists"

_DIGEST = "digest-shared-code"
_SENSITIVE_DIGEST = "digest-sensitive-config"
_VERSION = "1"
_CREATED_AT = "2026-08-11T00:00:00+00:00"
# 사이클 B 리뷰 2회차 High 시정 동기화 — tests_passed 평가에 4번째
# 축(tag 결속)이 추가됐다(rein/capabilities/testing/capability.py
# TestsPassedRequirement.evaluate). 이 파일의 모든 tests_passed 시나리오는
# 코드 변경(commit/push/release)을 대상으로 하므로 "code" 가 정확한
# tag 다 — docs/sensitive ChangeSet 을 다루는 시나리오가 없어 다른
# tag 값을 검증할 필요는 이번 동기화 범위 밖이다. 단순 필드 나열이
# 아니라 새 계약(발급 시점 결속 tag == 평가 시점 현재 tag)을 이
# 매트릭스의 모든 tests_passed 픽스처에 반영한 것이다.
_TAG = "code"


class _StubEvidenceSource:
    """조회는 항상 정상 수행되는 evidence 소스 — type 별로 분류해 반환한다.

    기존 capability 테스트들의 `_StubEvidenceSource` 는 requirement 1종
    전용이지만, 이 매트릭스 테스트는 release tier 에서 3종(code_review/
    tests_passed/security_review)을 동시에 다뤄야 하므로 `record.type`
    으로 일반화한다.
    """

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        return tuple(
            record
            for record in self._records
            if record.type == requirement_name
        )


def _build_registry():
    """실제 3개 Requirement 구현체를 등록한 registry — 실 로더 관통 계약."""
    registry = RequirementRegistry()
    register_code_review(registry)
    register_tests_passed(registry)
    register_security_review(registry)
    return registry


def _code_review_evidence(digest=_DIGEST, version=_VERSION):
    return Evidence(
        type=CODE_REVIEW,
        subject=digest,
        result=CODE_REVIEW_PASS,
        created_at=_CREATED_AT,
        producer=PRODUCER_AGENT_ATTESTED,
        policy_version=version,
    )


def _tests_passed_evidence(digest=_DIGEST, version=_VERSION, tag=_TAG):
    return Evidence(
        type=TESTS_PASSED,
        subject=digest,
        result=TESTS_PASSED_PASS,
        created_at=_CREATED_AT,
        # spec §5.2 조건 2 — tests_passed 는 runtime_verified 만 인정.
        producer=PRODUCER_RUNTIME_VERIFIED,
        policy_version=version,
        # tag 축(사이클 B 2회차 High) — 발급 시점에 결속된 tag. 이
        # 매트릭스의 모든 시나리오는 code ChangeSet 대상이므로 기본값
        # "code" 가 _context() 의 changeset.tag fact 기본값과 짝을
        # 이룬다(둘이 다르면 tests_passed 는 항상 미충족으로 떨어진다).
        metadata={"tag": tag},
    )


def _security_review_evidence(digest=_SENSITIVE_DIGEST, version=_VERSION):
    return Evidence(
        type=SECURITY_REVIEW,
        subject=digest,
        result=SECURITY_REVIEW_PASS,
        created_at=_CREATED_AT,
        producer=PRODUCER_AGENT_ATTESTED,
        policy_version=version,
    )


def _context(
    command_type,
    records=(),
    digest=_DIGEST,
    sensitive_digest=_SENSITIVE_DIGEST,
    version=_VERSION,
    testing_configured=None,
    tag=_TAG,
    task_exists=None,
):
    """이벤트 1건 평가에 필요한 fact 스냅샷 + evidence 소스를 담는다.

    testing_configured 는 문자열로만 주입한다 — YAML `when:` 비교값이
    항상 문자열이기 때문(모듈 docstring, push-testing.yaml 주석 참조).
    호출자가 실수로 bool 을 넘기면 매칭이 절대 성립하지 않는 함정을
    막기 위해 여기서 타입을 강제 검사한다.

    task_exists 도 동일한 문자열-only 계약이다(Phase 7 결정 1,
    `policies/default/commit.yaml`/`push.yaml` 의 `when: task.exists:
    "true"` 조건화가 소비). `None`(기본값)이면 fact 자체를 주입하지
    않는다 — `rein.platform.task.facts.task_exists()` 자신의 "활성
    작업 없으면 부재" 계약과 대칭이다(`task_commit_policy_task_
    conditioning.py::_context()` 와 동일 패턴 재사용).

    tag 는 tests_passed 평가의 4번째 축(changeset.tag fact) 재료다 —
    digest/sensitive_digest/version 과 동일하게 기본값이 있는 상시
    fact 로 취급한다(opt-in 인 testing_configured 와 다름). 이 fact 를
    확보하지 못하면 TestsPassedRequirement.evaluate 가 보수적으로
    미충족 처리하므로, tests_passed 를 요구/발급하는 시나리오에서는
    반드시 _tests_passed_evidence() 의 tag 기본값("code")과 일치해야
    한다.
    """
    if testing_configured is not None and not isinstance(
        testing_configured, str
    ):
        raise TypeError(
            "testing_configured must be a str ('true'/'false'), matching "
            "the D3 YAML subset's string-only scalar contract — got "
            "{!r}".format(type(testing_configured))
        )
    if task_exists is not None and not isinstance(task_exists, str):
        raise TypeError(
            "task_exists must be a str ('true'), matching the D3 YAML "
            "subset's string-only scalar contract and task_facts."
            "task_exists()'s own return contract — got {!r}".format(
                type(task_exists)
            )
        )
    facts = {_FACT_COMMAND_TYPE: command_type}
    if digest is not None:
        # code_review 는 이제 `changeset.review_digest`(검토 면제
        # 허용목록 제외)를 쓰지만, tests_passed 는 여전히 `changeset.
        # digest`(WORKTREE 전체, 무변경 축)를 쓴다 — 2026-08-20 개정
        # 이전에는 두 capability 가 같은 fact 키("changeset.digest")를
        # 공유해서 이 한 줄로 둘 다 채워졌지만, 이제는 서로 다른 키라
        # 명시적으로 둘 다 채운다(같은 `digest` 값을 공유하는 기존 fixture
        # 의도는 그대로 — 이 매트릭스는 review/tests_passed digest 값이
        # 갈라지는 시나리오를 검증하지 않는다, §3.6 리뷰 digest 범위 절).
        facts[CODE_REVIEW_DIGEST_FACT] = digest
        facts[TESTS_PASSED_DIGEST_FACT] = digest
    if sensitive_digest is not None:
        facts[FACT_CHANGESET_SENSITIVE_DIGEST] = sensitive_digest
    if version is not None:
        facts[_FACT_POLICY_VERSION] = version
    if testing_configured is not None:
        facts[_FACT_TESTING_CONFIGURED] = testing_configured
    if tag is not None:
        facts[FACT_CHANGESET_TAG] = tag
    if task_exists is not None:
        facts[_FACT_TASK_EXISTS] = task_exists
    return EvaluationContext(
        facts=facts, evidence_source=_StubEvidenceSource(records)
    )


class DefaultPolicyVersionTest(unittest.TestCase):
    """배포 기본 세트의 버전 메타데이터(Phase 6 Task 6.C, spec §3.4).

    `policies/default/_version.yaml` 이 실제로 이 디렉토리에 배포되어
    있고, `load_policy_version(DEFAULT_POLICY_DIR)` 로 정상 로드되며,
    `load_policies(DEFAULT_POLICY_DIR)` 가 그 파일을 정책으로 오인해
    파싱하지 않음(=DirectoryIsolationTest 가 고정하는 4개 policy_id
    목록이 그대로 유지됨)을 배포 경로 그대로 확인한다.
    """

    def test_default_version_file_loads(self):
        version = kernel_policy.load_policy_version(DEFAULT_POLICY_DIR)
        self.assertEqual(version.version, "1")
        self.assertEqual(version.compatible_versions, ())

    def test_version_file_does_not_leak_into_loaded_policy_ids(self):
        policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        policy_ids = sorted(entry["policy_id"] for entry in policies)
        self.assertNotIn("_version", policy_ids)
        self.assertEqual(
            policy_ids, ["commit", "push", "push-testing", "release"]
        )


class DirectoryIsolationTest(unittest.TestCase):
    """policies/default/ 분리 근거를 코드로 실증 (부모 확정 사항 1).

    주석으로만 주장하지 않는다 — `policies/` 바로 아래(= tags.yaml 과
    같은 디렉토리)를 로드하면 실제로 깨지고, `policies/default/` 는
    깨지지 않음을 직접 검증한다.
    """

    def test_loading_policies_root_collides_with_tags_yaml_schema(self):
        # tags.yaml 이 실제로 같은 디렉토리에 있고, 로더가 이를 policy
        # 스키마로 잘못 파싱하려다 명시 에러를 낸다 — 하위 디렉토리
        # 분리가 필요조건임을 증명.
        self.assertTrue(
            os.path.isfile(os.path.join(_POLICIES_ROOT, "tags.yaml"))
        )
        with self.assertRaises(kernel_policy.PolicyLoadError) as caught:
            kernel_policy.load_policies(_POLICIES_ROOT)
        self.assertIn("rules", str(caught.exception))

    def test_default_subdirectory_loads_cleanly(self):
        policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        policy_ids = sorted(entry["policy_id"] for entry in policies)
        self.assertEqual(
            policy_ids,
            ["commit", "push", "push-testing", "release"],
        )


class CommitTierTest(unittest.TestCase):
    """(a) — commit 은 code_review 만, testing.configured 와 무관.

    Phase 7 결정 1 (2026-08-19 사용자 결정) — commit.yaml 은 이제
    `task.exists: "true"` 로도 조건화된다("활성 작업 없으면 소스 편집이
    애초에 차단되므로 리뷰할 변경이 없다"는 v1 의미론 재현). 아래
    "code_review 요구" 를 실제로 pin 하는 케이스는 `task_exists="true"`
    주입 문맥(b)과 미주입 문맥(a) 두 갈래로 나뉜다 — (b)가 옛 단언을
    그대로 계승하고, (a)는 새로 조건화된 "무작업 시 미매칭 ALLOW" 를
    고정한다(단언 약화가 아니라 분기 추가).
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate(self, records, testing_configured=None, task_exists=None):
        context = _context(
            "git.commit",
            records=records,
            testing_configured=testing_configured,
            task_exists=task_exists,
        )
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_commit_with_code_review_allows_regardless_of_testing_state(
        self,
    ):
        # task_exists="true" 를 고정 주입해 commit.yaml 이 실제로
        # 매칭되는 경로를 exercise 한다 — 그렇지 않으면 이 ALLOW 가
        # "정책이 아예 미매칭돼서" 나온 것인지 "evidence 가 실제로
        # 충족해서" 나온 것인지 구분되지 않는다(vacuous pass 방지).
        for testing_configured in (None, "false", "true"):
            with self.subTest(testing_configured=testing_configured):
                decision = self._evaluate(
                    (_code_review_evidence(),),
                    testing_configured=testing_configured,
                    task_exists="true",
                )
                self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_commit_without_code_review_and_no_active_task_allows(self):
        # (a) task.exists fact 없는 문맥 — v1 "활성 작업 없으면 리뷰할
        # 변경이 없다" 의미론 재현. commit.yaml 자체가 미매칭되어
        # code_review 가 요구되지 않는다(missing_requirements 도 빈
        # tuple).
        decision = self._evaluate((), task_exists=None)
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_commit_without_code_review_blocks_when_task_active(self):
        # (b) task.exists="true" 주입 문맥 — 옛 단언 그대로 계승
        # (활성 작업이 있으면 여전히 code_review 없이는 BLOCK).
        decision = self._evaluate((), task_exists="true")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_commit_never_requires_tests_passed(self):
        # testing 이 설정되어 있어도 commit tier 는 tests_passed 를
        # 요구하지 않는다 — push.yaml/push-testing.yaml 의 when 은
        # command.type=git.push 에만 매칭되므로 애초에 이 이벤트에
        # 매칭조차 안 된다. task_exists="true" 로 commit.yaml 이 실제로
        # 매칭되는 경로를 exercise 한다(위와 동일한 vacuous-pass 방지
        # 이유).
        decision = self._evaluate(
            (_code_review_evidence(),),
            testing_configured="true",
            task_exists="true",
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertNotIn(TESTS_PASSED, decision.missing_requirements)


class PushTierMatrixTest(unittest.TestCase):
    """(b) — push × testing 설정 유무 4분면 (완료 판정의 핵심 매트릭스).

    Phase 7 결정 1 (2026-08-19 사용자 결정) — push.yaml(code_review
    하한선)도 commit.yaml 과 동일하게 `task.exists: "true"` 로
    조건화된다. `push-testing.yaml`(tests_passed 축)은 이 결정의 범위
    밖이라 task.exists 와 무관하게 기존 그대로다. 아래 각 케이스는
    `task_exists="true"` 를 기본 주입해 push.yaml 의 code_review
    요구가 실제로 매칭되는 경로를 exercise 한다(그렇지 않으면 다수
    케이스가 "정책이 아예 미매칭돼서" ALLOW 인지 "code_review 가 실제로
    충족돼서" ALLOW 인지 구분되지 않는 vacuous pass 가 된다) — 단,
    "code_review 요구 자체가 pin 되는" 마지막 케이스만 (a)/(b) 두
    갈래로 명시 분리한다.
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate(self, records, testing_configured, task_exists="true"):
        context = _context(
            "git.push",
            records=records,
            testing_configured=testing_configured,
            task_exists=task_exists,
        )
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_configured_with_both_evidences_allows(self):
        decision = self._evaluate(
            (_code_review_evidence(), _tests_passed_evidence()),
            testing_configured="true",
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_configured_missing_tests_passed_blocks(self):
        decision = self._evaluate(
            (_code_review_evidence(),), testing_configured="true"
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (TESTS_PASSED,))

    def test_unconfigured_with_code_review_only_allows(self):
        # 핵심 케이스 — spec §5.2: 미선언 프로젝트의 push 를 막지
        # 않는다 (TDD Red 단계·중간 commit 과차단 금지).
        decision = self._evaluate(
            (_code_review_evidence(),), testing_configured="false"
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_unconfigured_and_absent_fact_both_skip_tests_passed_gate(self):
        # testing.configured fact 자체가 없는 경우(fact 미확보)도
        # "false" 와 동일하게 취급되어야 한다 — push-testing.yaml 의
        # when 은 정확한 문자열 "true" 등호 매칭이므로 부재(None)도
        # 자연히 불일치로 떨어진다.
        allowed_false = self._evaluate(
            (_code_review_evidence(),), testing_configured="false"
        )
        allowed_absent = self._evaluate(
            (_code_review_evidence(),), None
        )
        self.assertEqual(allowed_false.decision, DECISION_ALLOW)
        self.assertEqual(allowed_absent.decision, DECISION_ALLOW)

    def test_unconfigured_without_code_review_and_no_active_task_allows(
        self,
    ):
        # (a) task.exists fact 없는 문맥 — push.yaml 자체가 미매칭되어
        # code_review 가 요구되지 않는다(v1 "활성 작업 없으면 리뷰할
        # 변경이 없다" 의미론 재현, commit tier 와 동일 논리). testing
        # 도 미설정이라 push-testing.yaml 도 미매칭 — 결과적으로 아무
        # 정책도 매칭되지 않는 ALLOW.
        decision = self._evaluate(
            (), testing_configured="false", task_exists=None
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_unconfigured_without_code_review_blocks_on_code_review_only(
        self,
    ):
        # (b) task.exists="true" 주입 문맥 — 옛 단언 그대로 계승.
        # 설정 안 됨 + code_review 도 없음 → BLOCK 이지만, missing 목록에
        # tests_passed 는 없어야 한다(애초에 요구되지 않았음 — 요구
        # 자체가 없는 것과 요구됐지만 결여된 것을 구분).
        decision = self._evaluate(
            (), testing_configured="false", task_exists="true"
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))
        self.assertNotIn(TESTS_PASSED, decision.missing_requirements)


class ReleaseTierTest(unittest.TestCase):
    """(c) — release 조합 1케이스: 세 요구 전부 결합."""

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate(self, records):
        context = _context("git.tag", records=records)
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_release_with_all_three_evidences_allows(self):
        decision = self._evaluate(
            (
                _code_review_evidence(),
                _tests_passed_evidence(),
                _security_review_evidence(),
            )
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_release_missing_security_review_blocks_on_that_alone(self):
        decision = self._evaluate(
            (_code_review_evidence(), _tests_passed_evidence())
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (SECURITY_REVIEW,))

    def test_release_with_no_evidence_blocks_on_all_three(self):
        decision = self._evaluate(())
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(
            set(decision.missing_requirements),
            {CODE_REVIEW, TESTS_PASSED, SECURITY_REVIEW},
        )


class TagQueryOverApproximationTest(unittest.TestCase):
    """사이클 B 리뷰 1회차 Medium 지적 — `git.tag` 는 release 보다 넓다.

    `command_classifier.classify()` 는 `tokens[1]`(서브커맨드)까지만
    보고 `git.<subcommand>` 로 분류하며, 그 뒤 인자(`-l`/`-d`/태그
    이름)는 전혀 해석하지 않는다(command_classifier.py 모듈 docstring:
    "인자 수준의 의미 분석은 하지 않는다 — 그것은 해당 명령 라벨에
    대한 Policy 소관"). 그 결과 태그 **조회**(`git tag`/`git tag -l`)와
    태그 **삭제**(`git tag -d v0.9.0`)도 실제 release(`git tag
    v1.2.3`)와 구별되지 않고 전부 `command.type=git.tag` 로 분류되어
    release.yaml 의 3종 요구 대상이 된다.

    부모 판정(사이클 B): 인자 기반 정밀 구분은 분류기의 "플래그 의미
    추측 금지" 철학(`git -C <path> commit` 을 UNKNOWN 으로 넘기는 것과
    동일 원리)과 충돌해 이 사이클에서 채택하지 않는다 — 과요구(안전
    방향)를 현재 의도된 동작으로 그대로 고정한다. 정밀 식별은 전용
    release fact resolver 배선(백로그) 소관이며, 그 resolver 가
    생기면 이 매칭이 교체된다 — 이 테스트는 **그 전환 시점에 반드시
    깨져서** 의도 변경을 표면화하도록 설계됐다(조용히 숨기지 않는다).
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def test_classifier_does_not_distinguish_release_from_query_or_delete(
        self,
    ):
        # 실제 분류기를 통과시켜 확인 — 셋 다 동일 라벨로 수렴한다.
        self.assertEqual(command_classifier.classify("git tag v1.2.3"), "git.tag")
        self.assertEqual(command_classifier.classify("git tag -l"), "git.tag")
        self.assertEqual(command_classifier.classify("git tag"), "git.tag")
        self.assertEqual(
            command_classifier.classify("git tag -d v0.9.0"), "git.tag"
        )
        self.assertEqual(
            command_classifier.classify("git tag debug-checkpoint"),
            "git.tag",
        )

    def _evaluate_for_command(self, command_text, records=()):
        command_type = command_classifier.classify(command_text)
        context = _context(command_type, records=records)
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_tag_listing_query_is_blocked_by_release_requirements(self):
        # `git tag -l` 는 release 가 아니라 순수 조회지만, 현재 기본
        # 세트 하에서는 release 정책에 매칭되어 evidence 없이는 BLOCK
        # 된다 — 이는 버그가 아니라 **의도된 과근사**(release.yaml
        # "알려진 과근사" 주석)이며, 이 테스트가 그 현재 행위를
        # 명시적으로 고정한다.
        decision = self._evaluate_for_command("git tag -l")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(
            set(decision.missing_requirements),
            {CODE_REVIEW, TESTS_PASSED, SECURITY_REVIEW},
        )

    def test_tag_deletion_is_blocked_by_release_requirements(self):
        decision = self._evaluate_for_command("git tag -d v0.9.0")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(
            set(decision.missing_requirements),
            {CODE_REVIEW, TESTS_PASSED, SECURITY_REVIEW},
        )

    def test_tag_listing_query_can_still_pass_with_full_evidence(self):
        # 과근사는 "더 자주 요구"하는 방향일 뿐 통과 자체를 막지 않는다
        # — evidence 를 전부 갖추면(예: release 직후 연속 조회) ALLOW.
        decision = self._evaluate_for_command(
            "git tag -l",
            records=(
                _code_review_evidence(),
                _tests_passed_evidence(),
                _security_review_evidence(),
            ),
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_actual_release_tag_creation_is_indistinguishable_from_query(
        self,
    ):
        # 대조 확인 — 진짜 release 태그 생성과 조회가 정확히 같은
        # Decision 형태(같은 missing_requirements 집합)로 귀결됨을
        # 보여, "구분 불가"라는 지적의 핵심을 evaluator 결과 수준에서
        # 재확인한다.
        release_decision = self._evaluate_for_command("git tag v1.2.3")
        query_decision = self._evaluate_for_command("git tag -l")
        self.assertEqual(
            release_decision.missing_requirements,
            query_decision.missing_requirements,
        )


class ProjectDirectEnforcementBlocksNormallyTest(unittest.TestCase):
    """(d) — 미선언 + 프로젝트가 policy 로 직접 강제 시 정상 BLOCK.

    spec §5.2 확정 문구: "프로젝트가 policy 를 직접 켜서 강제하는
    경우, 미선언 상태의 tests_passed 요구는 정상 평가 BLOCK 이다
    (판단 실패가 아니므로 failure_mode 비적용)". 여기서 "프로젝트가
    직접 켠 정책"은 기본 세트(push-testing.yaml 의 testing.configured
    게이트)가 아니라, 이 테스트가 인라인으로 구성하는 **project-level
    override 정책**이다 — testing.configured 조건 없이 push 에
    tests_passed 를 무조건 요구한다.
    """

    _PROJECT_POLICY_TEXT = (
        "trigger: tool.pre\n"
        "when:\n"
        "  command.type: git.push\n"
        "require:\n"
        "  - tests_passed\n"
        "failure_mode: closed\n"
    )

    def setUp(self):
        self.registry = _build_registry()
        self.project_policy = {
            "policy_id": "project-force-tests-on-push",
            "fields": kernel_policy.parse_policy(
                self._PROJECT_POLICY_TEXT,
                source="<test:project-force-tests-on-push>",
            ),
        }

    def test_direct_enforcement_without_declared_tests_is_normal_block(self):
        # testing 미설정(evidence 자체가 존재할 수 없는 상태)인데도
        # 프로젝트 정책이 무조건 요구 — tests_passed evidence 가 전혀
        # 없으므로 정상 평가 BLOCK.
        context = _context(
            "git.push", records=(), testing_configured=None
        )
        decision = evaluator.evaluate(
            _EVENT,
            context,
            [self.project_policy],
            registry=self.registry,
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (TESTS_PASSED,))
        # 정상 평가 BLOCK 재료(REASON_MISSING_EVIDENCE) 임을 확인 —
        # failure_mode 분기(판단 불능)의 reason 문구("evaluation
        # failure while checking...")와 다르다.
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)
        self.assertNotIn("evaluation failure", decision.reason)

    def test_default_set_alone_would_have_allowed_the_same_push(self):
        # 대조군 — 같은 상황(testing 미설정 push, code_review 만 충족)
        # 을 기본 세트로 평가하면 ALLOW 다. 즉 위 BLOCK 은 기본 세트의
        # 결함이 아니라 프로젝트가 스스로 더 엄격한 정책을 얹은
        # 결과라는 것을 대조로 보인다. task_exists="true" 를 주입해
        # push.yaml 의 code_review 요구가 실제로 매칭·충족되는 경로를
        # exercise 한다 — 그렇지 않으면 이 ALLOW 가 "code_review 만
        # 충족해서" 가 아니라 "정책이 아예 미매칭돼서" 나온 것이 되어
        # 이 대조군의 주장(comment 원문)과 어긋난다.
        default_policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        context = _context(
            "git.push",
            records=(_code_review_evidence(),),
            testing_configured=None,
            task_exists="true",
        )
        decision = evaluator.evaluate(
            _EVENT, context, default_policies, registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)


if __name__ == "__main__":
    unittest.main()
