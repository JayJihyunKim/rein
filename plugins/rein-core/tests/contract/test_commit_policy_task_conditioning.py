"""Phase 7 결정 1 — 기본 commit/push Policy 의 `task.exists` 조건화
(2026-08-19 사용자 결정).

## 배경

v2 기본 commit/push Policy(`policies/default/commit.yaml`/`push.yaml`)
는 활성 작업 유무와 무관하게 code_review 를 요구해 v1 의미론과 갈라진다
— v1 은 "활성 작업 있을 때만 요구"였다(`hooks/lib/code-review-gate.sh`
의 `dod_exists` precondition, 아래 "v1 predicate 재확인" 절 참조). 이
갈라짐은 v1 → v2 authority 전환(Task 6.1, `hooks/lib/code-review-gate.sh`
라인 298-345 의 위임 구조 주석)이 이미 명시했던 위험이다: "v2 기본
정책은 커밋에 무조건 code_review 를 요구하지만, 그 무조건 요구 의미론이
실제로 발동하는 것은 hooks.json 등록 시점(Phase 7)의 별도 명시 결정이다."
이 파일이 그 Phase 7 결정을 고정한다.

사용자 결정(2026-08-19): v1 의미론을 **전용 fact 방식**으로 인코딩한다
— `testing.configured` fact 의 기존 선례와 동일한 패턴(있으면 고정
리터럴 `"true"`, 없으면 fact 자체가 없음 → policy `when:` 불일치 →
정책 미매칭). fact 산출은 `rein.platform.task.facts.task_exists()`
(v1 `dod_exists` glob 의 **독립 미러(shim)** — `trail/dod/dod-*.md`
글롭에 매치되는 파일이 하나라도 있으면 `"true"`, 완료 여부(inbox 대조)
·날짜 형식은 전혀 보지 않는다. High-1 리뷰 후 `task_active_identifier()`
재사용을 그만두고 v1 glob 의미론을 독립적으로 재현하는 방향으로
바뀌었다 — 아래 "v1 predicate parity" 절 참조).

## v1 predicate 재확인 — `hooks/lib/code-review-gate.sh` 의 `dod_exists`

이 파일이 재현해야 할 v1 predicate 는 `hooks/pre-edit-dod-gate.sh` 의
`DOD_FOUND`(그 로직을 재현하는 대상은 이미 `task_active_identifier()`
자신이다, `rein/platform/task/facts.py` 모듈 docstring)가 **아니라**
실제 **commit 게이트**가 쓰는 `hooks/lib/code-review-gate.sh` 라인
280-296 의 `dod_exists` 다:

```sh
local dod_exists=false
if [ -d "$dod_dir" ]; then
  for f in "$dod_dir"/dod-*.md; do
    [ -f "$f" ] || continue
    dod_exists=true
    break
  done
fi
[ "$dod_exists" = false ] && return 0
```

## v1 predicate parity — 이전에 확인된 차이 2건은 High-1 리뷰로 해소됨

이 절은 이전에 "A/B 동등성 검증 — 발견된 차이 2건 (숨기지 않고 명시
고정)"이라는 제목으로, `task_exists()` 가 `task_active_identifier()`
를 재사용해 파생하던 시절 실측된 두 차이를 "의도적으로 v2 쪽을
채택"하는 결정으로 기록했었다. **그 결정은 뒤집혔다**(High-1 리뷰
지적, 2026-08-19, 리뷰어 실재현) — v2 스캐너 기준을 채택하면
위임·등록 경로에서 v1 이 요구하던 리뷰가 "완료-but-파일-잔존" 창과
레거시 파일명 케이스에서 오늘부터 조용히 사라져(fail-open), v1 이
지금까지 지켜온 "동작 불변 계약"을 깬다는 것이 재현됐기 때문이다.
`task_exists()` 는 이제 `task_active_identifier()` 를 호출하지 않고
v1 `dod_exists` glob 의미론(파일명 `dod-*.md` 매치만, 완료 여부·날짜
형식 무관)을 독립적으로 재현한다(`rein.platform.task.facts.
task_exists()` docstring 참조) — 그 결과 이전에 "차이"였던 두 입력은
이제 v1/v2 가 **완전히 일치**한다. `V1PredicateParityTest`(구
`V1PredicateDivergenceTest` — High-1 리뷰 후 이름도 실제 계약에 맞게
개명)가 이 parity 를 실제 fixture 로 고정한다:

- **(구 차이 A, 완료-파일-잔존)**: "완료 처리됐지만 dod 파일이
  `trail/dod/` 에 여전히 남아있는" 상태에서 이제 v1 `dod_exists` =
  v2 `task.exists` = true(둘 다 리뷰 계속 요구) — commit 은 code_review
  evidence 없이 BLOCK.
- **(구 차이 B, 레거시 파일명)**: 날짜 세그먼트가 없는 파일
  (`dod-notes.md` 류)만 있는 상태에서 이제 v1 `dod_exists` = v2
  `task.exists` = true(둘 다 리뷰 요구) — commit 은 마찬가지로 BLOCK.

## authority 활성(기본 3축) 시나리오 — `AuthorityActiveThreeAxisTest`

위 클래스들은 전부 `evaluator.evaluate(..., project_root=)` 인자를
생략한다 — `rein/engine/evaluator.py` 의 `PROJECT_ROOT_NOT_PROVIDED`
sentinel 기본값이 그대로 유지돼 authority 배선이 비활성인 경로만
관통한다. `AuthorityActiveThreeAxisTest` 는 실제 `project_root` 를
넘겨 authority 를 활성화한다 — Phase 7 결정 4(2026-08-19)로 배포 기본
전환 집합이 5종 전부에서 `code_review`/`security_review`/`active_task`
3종으로 축소된 파급(`rein/engine/authority.py`
`DEFAULT_SWITCHED_CAPABILITIES` 주석)이 이 조건화 스위트 어디에도
실증되지 않고 있었기 때문이다.

## 실행 관통 범위

`kernel.policy.load_policies` 로 실제 배포 정책(`policies/default/`)을
로드하고, 실제 `RequirementRegistry`(`register_code_review` 등) +
`engine.evaluator.evaluate` 를 관통한다 — `test_default_policy_matrix.py`
와 동일한 관례(synthetic 파서/평가 경로를 만들지 않는다). `task.exists`
fact 값은 하드코딩 리터럴이 아니라 `rein.platform.task.facts.task_exists()`
를 실제 임시 `trail/` fixture 에 대해 호출해 얻는다 — fact 산출과 policy
조건화 양쪽을 한 번에 관통 검증한다.
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
from rein.engine import evaluator  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK  # noqa: E402
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    PRODUCER_RUNTIME_VERIFIED,
)
from rein.platform.task import facts as task_facts  # noqa: E402

_POLICIES_ROOT = os.path.join(_PLUGIN_ROOT, "policies")
DEFAULT_POLICY_DIR = os.path.join(_POLICIES_ROOT, "default")

_EVENT = "tool.pre"
_FACT_COMMAND_TYPE = "command.type"
_FACT_POLICY_VERSION = "policy.version"
_FACT_TASK_EXISTS = "task.exists"
_FACT_TESTING_CONFIGURED = "testing.configured"

_DIGEST = "digest-shared-code"
_SENSITIVE_DIGEST = "digest-sensitive-config"
_VERSION = "1"
_CREATED_AT = "2026-08-11T00:00:00+00:00"
_TAG = "code"


def _write(path, content="stub\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


class _StubEvidenceSource:
    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        return tuple(
            record
            for record in self._records
            if record.type == requirement_name
        )


def _build_registry():
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
        producer=PRODUCER_RUNTIME_VERIFIED,
        policy_version=version,
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
    task_exists=None,
    tag=_TAG,
    testing_configured=None,
):
    """(a)-(c) 용 fact 스냅샷 — `task_exists` 는 문자열("true") 또는
    None 만 허용한다(policy YAML `when:` 비교값은 항상 문자열, D3 서브셋
    계약). None 이면 facts dict 에 `task.exists` 키 자체를 안 넣는다 —
    `task_facts.task_exists()` 자신의 None 반환 계약과 대칭이다.

    `testing_configured`(기본 None — `push-testing.yaml` 의 `when:
    testing.configured` 축을 켜고 싶을 때만 문자열 `"true"` 를 넘긴다)
    는 `AuthorityActiveThreeAxisTest` 가 push+testing 조합을 구성하기
    위해 추가했다 — `task_exists` 와 동일하게 None 이면 facts dict 에
    키 자체를 넣지 않는다.
    """
    if task_exists is not None and not isinstance(task_exists, str):
        raise TypeError(
            "task_exists must be a str ('true') or None, matching the D3 "
            "YAML subset's string-only scalar contract and task_facts."
            "task_exists()'s own return contract — got {!r}".format(
                type(task_exists)
            )
        )
    facts = {_FACT_COMMAND_TYPE: command_type}
    if digest is not None:
        # code_review 는 이제 `changeset.review_digest`(검토 면제
        # 허용목록 제외)를 쓰지만 tests_passed 는 여전히 `changeset.
        # digest`(WORKTREE 전체)를 쓴다 — 2026-08-20 개정 전에는 두
        # capability 가 같은 fact 키를 공유해 한 줄로 둘 다 채워졌다
        # (test_default_policy_matrix.py 와 동일한 수리, §3.6 리뷰
        # digest 범위 절).
        facts[CODE_REVIEW_DIGEST_FACT] = digest
        facts[TESTS_PASSED_DIGEST_FACT] = digest
    if sensitive_digest is not None:
        facts[FACT_CHANGESET_SENSITIVE_DIGEST] = sensitive_digest
    if version is not None:
        facts[_FACT_POLICY_VERSION] = version
    if task_exists is not None:
        facts[_FACT_TASK_EXISTS] = task_exists
    if tag is not None:
        facts[FACT_CHANGESET_TAG] = tag
    if testing_configured is not None:
        facts[_FACT_TESTING_CONFIGURED] = testing_configured
    return EvaluationContext(
        facts=facts, evidence_source=_StubEvidenceSource(records)
    )


class CommitTierTaskConditioningTest(unittest.TestCase):
    """commit.yaml — `task.exists` 조건화 (항목 3, 4a/4b)."""

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate(self, records=(), task_exists=None):
        context = _context(
            "git.commit", records=records, task_exists=task_exists
        )
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_no_active_task_allows_commit_without_review_evidence(self):
        # (4a) 활성 작업 없는 git.commit 이벤트 → code_review 요구
        # 미발동(정책 미매칭) → ALLOW. v1 의 "활성 작업 없으면 소스
        # 편집이 애초에 차단되므로 리뷰할 변경이 없다" 의미론 재현.
        decision = self._evaluate(records=(), task_exists=None)
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_active_task_blocks_commit_without_review_evidence(self):
        # (4b) 활성 작업 있는 git.commit → code_review 요구 발동 →
        # evidence 없으면 BLOCK.
        decision = self._evaluate(records=(), task_exists="true")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_active_task_allows_commit_with_review_evidence(self):
        decision = self._evaluate(
            records=(_code_review_evidence(),), task_exists="true"
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)


class PushTierTaskConditioningTest(unittest.TestCase):
    """push.yaml — `task.exists` 조건화 (항목 3, 4c).

    `testing.configured` fact 를 주입하지 않아 `push-testing.yaml`
    (tests_passed 축, 이번 결정 범위 밖 — push.yaml 만 조건화 대상)이
    관여하지 않게 격리한다.
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate(self, records=(), task_exists=None):
        context = _context(
            "git.push", records=records, task_exists=task_exists
        )
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_no_active_task_allows_push_without_review_evidence(self):
        decision = self._evaluate(records=(), task_exists=None)
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_active_task_blocks_push_without_review_evidence(self):
        decision = self._evaluate(records=(), task_exists="true")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_active_task_allows_push_with_review_evidence(self):
        decision = self._evaluate(
            records=(_code_review_evidence(),), task_exists="true"
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)


class ReleaseTierUnconditionedByTaskExistsTest(unittest.TestCase):
    """release.yaml — 조건 없음 유지 고정 (항목 3, 4d).

    이번 결정은 release.yaml 을 건드리지 않는다 — 무작업이어도 release
    (`git.tag`) 는 여전히 세 evidence 모두 매칭·요구해야 한다는 현행
    행위를 그대로 고정한다(회귀 방지 핀).
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate(self, records=()):
        # task.exists 를 아예 주입하지 않는다(활성 작업 없음) — 그래도
        # release 는 매칭돼야 한다는 것이 이 테스트의 핵심.
        context = _context("git.tag", records=records, task_exists=None)
        return evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )

    def test_no_active_task_still_requires_all_three_for_release(self):
        decision = self._evaluate(records=())
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(
            sorted(decision.missing_requirements),
            sorted((TESTS_PASSED, CODE_REVIEW, SECURITY_REVIEW)),
        )

    def test_no_active_task_release_allows_with_all_three_evidence(self):
        decision = self._evaluate(
            records=(
                _code_review_evidence(),
                _tests_passed_evidence(),
                _security_review_evidence(),
            )
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)


class V1PredicateParityTest(unittest.TestCase):
    """v1 `dod_exists`(`hooks/lib/code-review-gate.sh`) 대 v2
    `task.exists` parity 검증 (구 명칭 `V1PredicateDivergenceTest` —
    High-1 리뷰 후 개명, 모듈 docstring "v1 predicate parity" 절, DoD
    항목 4 지시 계승).

    [방향 교체] 이 클래스는 이전에 두 입력에서 v1/v2 가 "의도적으로
    갈라진다"고 고정했었다(`test_divergence_a_*`/`test_divergence_b_*`
    → ALLOW). High-1 리뷰 지적(2026-08-19, 리뷰어 실재현)으로
    `task_exists()` 구현이 v1 glob 의미론의 독립 미러로 교체되면서, 그
    갈라짐 자체가 사라졌다 — 아래 두 테스트는 같은 fixture 로 이제
    v1/v2 가 **일치**(BLOCK, code_review 요구 발동)함을 고정한다. 근거는
    동작 불변 계약: v1 이 요구하던 리뷰를 v2 위임 경로가 조용히
    빼먹으면 안 된다.

    `task_facts.task_exists()` 를 실제 임시 `trail/` fixture 에 호출해
    얻은 값을 그대로 policy 평가에 흘려보낸다 — fact 산출과 commit
    policy 조건화를 한 번에 관통한다.
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def _evaluate_commit_for_trail_root(self, root, records=()):
        value = task_facts.task_exists(root)
        context = _context("git.commit", records=records, task_exists=value)
        decision = evaluator.evaluate(
            _EVENT, context, self.policies, registry=self.registry
        )
        return value, decision

    def test_parity_a_completed_task_file_still_present(self):
        # [방향 교체] 이전 기대: value=None, decision=ALLOW ("v2 스캐너
        # 기준 채택" 결정 시절). 새 기대: value="true", decision=BLOCK.
        # 근거(High-1 리뷰, 동작 불변 계약): v1 `dod_exists` 는 `trail/
        # dod/` 파일 존재만 보고 `trail/inbox/` 완료 기록을 전혀
        # 대조하지 않는다 — "완료 처리됐지만 dod 파일이 여전히 남아있는"
        # 상태에서도 리뷰를 계속 요구한다. `task_exists()` 는 이제 그
        # v1 술어를 그대로 미러링하므로 같은 입력에서 v1/v2 가 일치한다.
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            _write(
                os.path.join(root, "trail", "inbox", "2026-08-11-foo.md")
            )
            value, decision = self._evaluate_commit_for_trail_root(root)
            self.assertEqual(
                value,
                "true",
                msg="task_exists() 는 이제 v1 dod_exists 를 미러링한다 —"
                " 완료 처리된 작업이라도 정의서 파일이 trail/dod/ 에"
                " 남아있으면 true(리뷰 계속 요구)여야 한다",
            )
            self.assertEqual(decision.decision, DECISION_BLOCK)
            self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_parity_b_legacy_filename_without_date(self):
        # [방향 교체] 이전 기대: value=None, decision=ALLOW. 새 기대:
        # value="true", decision=BLOCK.
        # 근거(High-1 리뷰, 동작 불변 계약): v1 `dod_exists` 의 shell
        # glob `dod-*.md` 는 날짜 형식을 요구하지 않아 레거시 파일명도
        # 매칭(true)한다. `task_exists()` 는 이제 `task_active_
        # identifier()` 의 신 포맷 정규식을 상속하지 않는 독립 구현이라
        # 레거시 파일명에서도 v1 과 일치한다.
        with tempfile.TemporaryDirectory() as root:
            _write(os.path.join(root, "trail", "dod", "dod-notes.md"))
            value, decision = self._evaluate_commit_for_trail_root(root)
            self.assertEqual(
                value,
                "true",
                msg="task_exists() 는 이제 v1 dod_exists 를 미러링한다 —"
                " 날짜 없는 레거시 파일명도 true(리뷰 요구)여야 한다",
            )
            self.assertEqual(decision.decision, DECISION_BLOCK)
            self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))

    def test_parity_for_current_format_pending_task(self):
        # 대조군 — 신 포맷 pending 파일 1건만 있는 표준 케이스는 이전
        # 결과와 변함없이 v1/v2 가 일치한다(둘 다 "활성 작업 있음").
        # 위 두 parity 케이스가 이제 예외가 아니라 일반 규칙임을
        # 보여준다.
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            value, decision = self._evaluate_commit_for_trail_root(root)
            self.assertEqual(value, "true")
            self.assertEqual(decision.decision, DECISION_BLOCK)
            self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


class AuthorityActiveThreeAxisTest(unittest.TestCase):
    """authority 활성(기본 3축 스위치 + 실제 `project_root` 전달) 시나리오.

    High-2 리뷰 지적(2026-08-19): 위 모든 클래스는
    `evaluator.evaluate(..., project_root=)` 인자를 생략한다 —
    `rein/engine/evaluator.py` 의 `PROJECT_ROOT_NOT_PROVIDED` sentinel
    기본값이 그대로 유지돼 authority 배선이 아예 비활성인 경로만
    관통했다. Phase 7 결정 4(2026-08-19, 사용자 결정)로 배포 기본 전환
    집합이 5종 전부에서 `code_review`/`security_review`/`active_task`
    3종으로 축소된 파급(`rein/engine/authority.py`
    `DEFAULT_SWITCHED_CAPABILITIES` 주석)이 이 commit/push/release
    조건화 스위트 어디에도 실증되지 않고 있었다 — 이 클래스가 그 공백을
    메운다.

    실제 임시 `project_root`(빈 `trail/` — v2 evidence 없음. **Phase 7
    웨이브 3 ③-d 갱신** 이전에는 여기 "v1 legacy stamp `.codex-reviewed`/
    `.security-reviewed` 없음"도 조건에 들어갔으나, legacy marker
    dual-read 계층 자체가 제거되어 그 조건은 더 이상 의미가 없다 — 파일이
    있든 없든 결과가 같다)를 넘기면:

    - `code_review`/`security_review` — 기본 전환됨. v2 evidence 가
      없으므로 등록 구현체(`CodeReviewRequirement.evaluate`/
      `SecurityReviewRequirement.evaluate`)가 `False` 를 계산하고, 그
      `False`(bool, `None` 아님)가 `authority.resolve_authority()` 에
      그대로 전달돼 `source=SOURCE_V2`/`satisfied=False` 로 확정된다
      (legacy 대체 자체가 ③-d 로 제거됨 — `v2_satisfied` 가 `None` 이
      되는 경로가 이 두 축에는 더 이상 없다, `rein/engine/evaluator.py`
      `_requirement_satisfied` 참조) → missing 에 포함.
    - `tests_passed` — 기본 **미전환**. `evaluator._requirement_
      satisfied()` 는 미전환 capability 를 만나면 v1/v2 어느 쪽 판정도
      계산하지 않고 즉시 `(True, note)` 를 반환한다("v1 이 이
      requirement 의 유일한 판정자로 남아야 한다" 계약을 v2 관점에서
      "missing 계산에서 자동 제외"로 실현) — missing 에 나타나지 않는다.

    **재편입 조건**(둘 다 충족해야 함 — **정본은 canonical spec §3.6
    "전환 유예" 절**, `rein/engine/authority.py` 의 주석은 복제 요약):
    (a) `tests_passed`/`user_approval` 의 실제 증거 발급 배선
    (`observe_test_run`/`issue_user_approval_evidence`) + 자격 검증 +
    닫힌 값 계약 2상태 짝 테스트, (b) 보안
    축에서 이미 관측된 D4 류 충돌 해소. 이 두 조건이 충족돼
    `DEFAULT_SWITCHED_CAPABILITIES` 가 다시 넓어지면 아래 "`tests_passed`
    는 missing 에서 빠진다"는 기대가 깨진다 — 그 시점에 발급 배선과
    충돌 해소를 확인한 뒤 이 클래스를 갱신해야 한다.
    """

    def setUp(self):
        self.policies = kernel_policy.load_policies(DEFAULT_POLICY_DIR)
        self.registry = _build_registry()

    def test_release_missing_requirements_excludes_unswitched_tests_passed(self):
        # release.yaml 은 tests_passed+code_review+security_review 를
        # 조건 없이 요구한다(§11.1). authority 활성 + 실제 project_root
        # 조합에서 missing 목록은 정확히 code_review+security_review
        # 뿐이어야 한다 — tests_passed 는 미전환이라 자동 충족 취급된다.
        with tempfile.TemporaryDirectory() as root:
            context = _context("git.tag", records=(), task_exists=None)
            decision = evaluator.evaluate(
                _EVENT,
                context,
                self.policies,
                registry=self.registry,
                project_root=root,
            )
            self.assertEqual(decision.decision, DECISION_BLOCK)
            self.assertEqual(
                sorted(decision.missing_requirements),
                sorted((CODE_REVIEW, SECURITY_REVIEW)),
            )

    def test_push_with_testing_configured_skips_all_unswitched_policy(self):
        # push.yaml(code_review, 전환됨) + push-testing.yaml
        # (tests_passed 단독, 미전환) 조합 — testing.configured="true"
        # 로 push-testing.yaml 의 `when` 이 매칭될 조건을 갖춰놔도,
        # `evaluate()` 의 정책 단위 사전 필터("이 정책의 requirement 가
        # 전부 미전환이면 `when` 조건조차 계산하지 않고 건너뛴다",
        # `rein/engine/evaluator.py` `evaluate()` 본문 "8회차 리뷰 시정"
        # 절 이전 주석 + `_requirement_satisfied()` docstring "도달 범위
        # 갱신" 절)가 그 정책 자체를 건드리지 않는다 — tests_passed 가
        # missing 에 없는 것은 "매칭됐지만 미전환이라 자동 충족"이 아니라
        # "정책이 애초에 매칭 시도조차 안 됨"이라는 다른 경로다. 이
        # 테스트는 그 사전 필터 경로 자체를 exercise 한다(§ 클래스
        # docstring — release 테스트의 "매칭 후 자동 충족" 경로와 대비).
        with tempfile.TemporaryDirectory() as root:
            context = _context(
                "git.push",
                records=(),
                task_exists="true",
                testing_configured="true",
            )
            decision = evaluator.evaluate(
                _EVENT,
                context,
                self.policies,
                registry=self.registry,
                project_root=root,
            )
            self.assertEqual(decision.decision, DECISION_BLOCK)
            self.assertEqual(decision.missing_requirements, (CODE_REVIEW,))


if __name__ == "__main__":
    unittest.main()
