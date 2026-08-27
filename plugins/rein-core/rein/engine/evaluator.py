"""Evaluation Cycle (plan Task 1.7 — spec §3.4 경계 계약).

세 경계를 코드로 고정한다:
1. requirement 미매칭 이벤트 → 기본 ALLOW + reason (Requirement 가 없는
   안전한 작업은 기본 ALLOW).
2. evidence 부재 → 정상 평가 BLOCK. failure_mode 는 절대 적용되지 않는다.
3. 판단 불능(EvidenceStorageError — storage parse 실패·손상 등)일 때만
   Evaluation Failure 로 보고 failure_mode(closed/open/ask_user) 분기.

충족 판정 (plan Task 3.1 배선): registry 를 주입하면 등록 구현체가 있는
requirement 는 충족 판정이 `implementation.evaluate(context)` 로 위임된다
— validity 결합(subject digest·policy version, kernel/evidence.py 순수
함수)은 capability 구현체가 수행한다. 미등록 requirement / registry=None
(기본) 은 evidence '존재' = 충족 단순화를 유지한다 — 다른 4종 capability
가 아직 미배선이고, 기본 소스(NullEvidenceSource)는 항상 부재를 보고하므로
이 단순화가 허용 경로를 넓히지 않는다. 위임 evaluate 가 던지는
EvidenceStorageError 계열(FactResolutionError 포함)은 evidence_for 경로와
동일하게 failure_mode 분기를 탄다 (판단 불능 ≠ 부재 경계 유지).

Authority 배선 (plan Task 6.1 — spec §3.6 판정 상태표, **③-d(2026-08-24)
로 legacy 대체 제거**): `project_root` 를 주입하면, 위에서 계산한 v2
충족 판정을 `rein.engine.authority` 에 넘겨 capability 별 전환 여부를
적용한다. 그 결과가 최종 satisfied 값이다 — fact 판정형(active_task)
은 **등록 구현체가 있으면 항상 v2 가 이긴다**(authority 계약,
`authority.resolve_authority` docstring). 증거 발급형 4축 중
code_review/security_review 2축은 **2026-08-20 개정**(spec §3.6 판정
상태표, Phase 7 웨이브 3 ③-a) 으로 등록 구현체가 종국 상태표(subject-
empty→충족/subject-unresolved→미충족/non-empty+유효→충족/non-empty+
무효→미충족)를 직접 구현하고, **③-d 부터는** 이 계층이 그 결과를 그대로
authority 에 넘긴다(subject 상태를 이 계층에서 재확인하지 않는다 —
`_requirement_satisfied` 본문 참조) — 나머지 2축(tests_passed/
user_approval)은 기존 "증거 레코드 존재" 게이팅 그대로다. 이 함수
자신은 `rein.capabilities.*` 어떤 구현체도 모른다 — capability 이름은
`rein.kernel.requirement.REQUIREMENT_NAMES` 문자열로만 authority 에
전달한다 (engine → capability 직접 의존 금지, spec §3.1 §31/§4.1 의
대칭 원칙).

**`project_root` 세 가지 값 — sentinel 로 "안 물어봄"과 "물어봤는데
없음"을 구분한다** (기존 1211 테스트 무파손이 이 구분의 유일한 이유):

- **`PROJECT_ROOT_NOT_PROVIDED`(기본값, 이 모듈의 sentinel)**: 호출자가
  authority 를 아예 모른다 — Task 6.1 이전과 정확히 동일하게 동작한다
  (evidence_for 추가 호출도, Decision.reason 변화도 없다). 기존
  1211 테스트 전부가 이 경로를 탄다(project_root 인자를 주지 않으므로).
- **`None`(명시적)**: 호출자가 project_root 를 구하려 시도했지만 실패했다
  — 오늘은 `rein.cli.run_event()` 하나뿐이다(REIN_PROJECT_ROOT 환경변수
  미설정). authority 는 적용하지 않는다(기존 v1/v2 hybrid 판정 유지,
  조용히 지나가지 않는다) — 대신 Decision.reason 에 그 사실을 남긴다
  (`_authority_skipped_note`). cwd 로 추정하지 않는다(부모 지시) — 이
  구분이 없으면 project_root 미설정을 "조용한 통과"로 위장하게 된다.
- **문자열(실제 경로)**: authority 를 실제로 적용한다. "v2 가 판정할
  재료를 가졌다"의 뜻은 capability 의 판정 방식 분류(fact 판정형 vs
  증거 발급형, `authority.FACT_JUDGED_CAPABILITIES`/`authority.
  EVIDENCE_ISSUED_CAPABILITIES`)에 따라 갈린다. fact 판정형
  (active_task)은 등록 구현체가 평가를 수행했으면(`context.
  evidence_for` 조회조차 하지 않는다) 그 결과가 곧 v2 판정이다. 증거
  발급형 중 code_review/security_review 는 **2026-08-20 개정**(spec
  §3.6 판정 상태표, Phase 7 웨이브 3 ③-a)으로 등록 구현체가 종국
  상태표를 직접 구현하므로, **③-d 부터는** 그 결과(`bool`)를 그대로
  authority 에 넘긴다 — subject 가 non-empty digest 인지·유효 PASS
  증거가 있는지는 이 계층이 더 이상 재확인하지 않는다(등록 구현체의
  `evaluate()` 가 이미 그 재확인을 포함한다, `authority.
  CURRENT_SUBJECT_FACT_KEYS` 는 이제 축 분류 판별자로만 쓰인다).
  tests_passed/user_approval 2축은 이 개정 범위 밖 — "레코드가
  존재한다"(`context.evidence_for(requirement)` 가 빈 tuple 이
  아니다)만으로 게이팅하는 기존 규칙 그대로다. 어느 경우든 v2 가
  판정을 냈으면(`bool`) 그 결과가 최종값이고 reason 은 건드리지
  않는다(authority 개입이 있었지만 결과가 바뀌지 않았다는 사실은
  소음이므로 노출하지 않는다). v2 가 판정할 재료가 없으면(`None` —
  현재는 tests_passed/user_approval 의 evidence 부재에서만 발생)
  **보수적으로 미충족**(`satisfied=False`)이고, 그 사실은 항상 reason
  에 남는다(`_authority_source_note`) — legacy marker 대체는 ③-d 로
  제거됐다(예전에는 여기서 legacy marker 로 대체하고 그 사실을
  reason 에 남겼다 — 지금은 대체할 legacy 가 없다). capability 가
  **아직 전환되지 않았으면**(plan Task 6.1 "미전환 capability 는 v1
  경로 유지" 계약, Phase 6 4회차 리뷰 High 1 시정) 이 함수는 그
  requirement 를 v2 결정에서 완전히 제외한다 — v2 는 그 축에 대해
  의견이 없다는 뜻이며(v1 훅이 여전히 그 requirement 의 유일한
  판정자다), 그 사실도 항상 reason 에 남는다(`_authority_unswitched_
  note`). 이전 구현은 미전환 capability 에도 v2 자신의 판정
  (`v2_satisfied`)을 최종값으로 반환했는데, 그 결과 옛 v1 표식이 PASS
  여도 v2 가 독자적으로 재판정해 BLOCK 할 수 있었다(v1·v2 이중 판정
  과차단 — authority 가 "판정에 개입하지 않는다"고 명시적으로 알린
  축을 조용히 다시 판정한 결함).

**정책 단위 사전 필터 — 미전환-단독 정책은 `when` 조건조차 계산하지
않는다** (Phase 6 6회차 리뷰 High 1/High 2 시정). 위 문단은 requirement
단위 short-circuit(`_requirement_satisfied` 내부)을 설명하지만, 5회차
구현까지도 그 short-circuit 에 도달하기 **전에** `evaluate()` 자신이
이미 그 정책의 `when` 조건을 계산해버렸다 — 조건에 지연 계산 resolver 가
있으면(예: git 상태 조회) 그 requirement 가 미전환이라 v2 가 판정에
전혀 개입하지 않을 정책인데도 resolver 가 호출됐고, 그 resolver 가
예외를 던지면 policy 의 `failure_mode` 분기(예: 'closed' → BLOCK)가
발동했다 — "판정에 개입하지 않는다"고 선언한 축이 여전히 부작용으로
결정에 영향을 준 것이다(High 1). 같은 순서 문제가 정반대 방향의 결함도
낳았다: authority 정책 자체가 손상됐는데 조건 resolver 가 먼저 예외를
던지면, 그 정책의 `failure_mode`(예: 'open' → 경고와 함께 ALLOW)가
손상된 authority.yaml 을 한 번도 읽지 못한 채 조용히 통과시켰다(High 2).

수정: `evaluate()` 는 trigger 가 일치한 각 정책에 대해 **`when` 조건을
계산하기 전에** (1) authority 정책을 로드하고(사이클당 최대 1회, 로드
실패는 즉시 전파 — 아래 `_SWITCHED_NOT_LOADED` 주석 참조), (2) 그
정책이 요구하는 requirement 를 전환/미전환으로 분류한다. **전부
미전환이면** `when` 조건은 아예 계산하지 않고(지연 계산 resolver 호출
없음) 그 정책을 완전히 건너뛴다 — `matched_policy_id` 도, 아래에서
설명하는 미전환 note 도 남기지 않는다(그 정책은 v1 의 배타적 관할이라
v2 는 조건이 실제로 맞는지조차 알 이유가 없다 — 리뷰어 권고 원문:
"전부 미전환이면 조건을 계산하지 않고 그 정책을 건너뛴다"). **혼재
정책**(전환된 requirement 와 미전환 requirement 가 한 정책에 같이
있는 경우)은 이 사전 필터를 통과한다 — `when` 조건은 정상적으로
계산되고(전환된 축에 대한 판정이 필요하므로), 아래 `_requirement_satisfied`
의 requirement 단위 short-circuit 은 그 정책의 미전환 축에만 적용된다
(그 축의 note 는 여전히 reason 에 남는다 —
`MixedSwitchedAndUnswitchedRequirementsTest` 참조). 즉 미전환 note
(`_authority_unswitched_note`)는 이제 **혼재 정책의 미전환 축에서만**
관측된다 — 정책 전체가 미전환이면 애초에 `_requirement_satisfied` 가
호출되지 않으므로 note 자체가 생기지 않는다
(`UnswitchedCapabilityUnaffectedTest` 6회차 갱신판 참조, 4회차 판은
정책 전체가 여전히 "matched" 로 처리된다고 (틀리게) 가정했었다).
"""
from rein.engine.context import EvidenceStorageError
from rein.kernel.decision import (
    DECISION_ALLOW,
    DECISION_ASK_USER,
    DECISION_BLOCK,
    Decision,
)
from rein.engine import authority
from rein.kernel.policy import FAILURE_MODES

REASON_NO_MATCH = "no policy matched event"
REASON_NO_REQUIREMENTS = "matched policy declares no requirements"
REASON_MISSING_EVIDENCE = "required evidence is missing"

FAILURE_MODE_CLOSED = "closed"
FAILURE_MODE_OPEN = "open"
FAILURE_MODE_ASK_USER = "ask_user"

# 판단 불능 시 decision 값 — 미지 mode 는 fail-closed (spec §3.4 원칙:
# Critical Governance = closed 가 안전 기본값)
_FAILURE_DECISIONS = {
    FAILURE_MODE_CLOSED: DECISION_BLOCK,
    FAILURE_MODE_OPEN: DECISION_ALLOW,
    FAILURE_MODE_ASK_USER: DECISION_ASK_USER,
}
_FAILURE_REASON_SUFFIX = {
    FAILURE_MODE_CLOSED: "failure_mode 'closed' blocks",
    FAILURE_MODE_OPEN: "failure_mode 'open' allows with warning",
    FAILURE_MODE_ASK_USER: "failure_mode 'ask_user' defers to the user",
}
# 심각도 순서 — 복수 policy 의 판단 불능이 섞이면 가장 보수적인 쪽이 이긴다
_FAILURE_SEVERITY = (
    FAILURE_MODE_CLOSED,
    FAILURE_MODE_ASK_USER,
    FAILURE_MODE_OPEN,
)

# 이중 정의 방어 — 이 모듈의 mode 어휘가 kernel 폐쇄 집합(FAILURE_MODES)
# 과 어긋나면 로드 시점에 즉시 표면화한다 (드리프트 침묵 금지)
assert (
    frozenset(_FAILURE_DECISIONS)
    == frozenset(_FAILURE_REASON_SUFFIX)
    == frozenset(_FAILURE_SEVERITY)
    == frozenset(FAILURE_MODES)
), "evaluator failure-mode vocabulary drifted from kernel FAILURE_MODES"

# authority 배선의 project_root sentinel (모듈 docstring "Authority 배선"
# 절) — evaluate()/`_requirement_satisfied()` 의 기본값. 호출자가
# project_root 인자를 아예 주지 않으면 이 객체가 그대로 전달되고,
# authority 는 완전히 비활성이다(기존 1211 테스트가 이 경로를 탄다).
PROJECT_ROOT_NOT_PROVIDED = object()

# "authority 정책을 아직 로드 시도하지 않음" sentinel (Phase 6 리뷰
# High 2 시정) — `evaluate()` 가 cycle 당 최대 1회만 `authority.
# load_authority_policy()` 를 호출하기 위한 표식이다. `None`/frozenset
# 어느 쪽과도 겹치지 않아야 한다 — 로드했더니 빈 집합(frozenset())이
# 나온 것과 "아직 로드 안 함"을 구분해야 두 번째 requirement 부터
# 파일을 다시 읽지 않는다.
_SWITCHED_NOT_LOADED = object()


def evaluate(event_name, context, policies, registry=None, project_root=PROJECT_ROOT_NOT_PROVIDED):
    """이벤트 1건을 policy 목록에 대해 평가해 Decision 을 반환한다.

    policies 는 로더 형태({"policy_id", "fields"}) 목록. fields 는
    kernel/policy.py 폐쇄 로더 산출물이 정본이나, 로더를 우회한 dict 가
    와도 failure_mode 는 fail-closed 로 처리한다.

    registry (RequirementRegistry, 기본 None): 등록 구현체가 있는
    requirement 의 충족 판정을 위임한다 (모듈 docstring "충족 판정" 절).
    None 이면 기존 존재 검사 동작 그대로다 (하위호환).

    project_root (기본 `PROJECT_ROOT_NOT_PROVIDED`): authority 배선의
    입력 (모듈 docstring "Authority 배선" 절) — 세 값의 의미가 다르다
    (sentinel/`None`/문자열). 정책 손상·미지 capability 는 authority 가
    던지는 예외(`AuthorityError` 계열)를 그대로 전파한다(fail-closed —
    이 함수도 `bin/rein` 의 포괄 예외 처리기도 삼키지 않는다).
    """
    matched_policy_id = None
    blocking_policy_id = None
    missing_requirements = []
    failures = []  # (failure_mode, policy_id, requirement, error)
    authority_notes = []  # 이번 evaluate() 호출 동안 authority 가 남긴 메모
    # authority 정책은 이 cycle 안에서 최대 1회만 로드·검증한다 — 그리고
    # 그 로드는 첫 trigger-매칭 정책의 `when` 조건 계산(지연 계산
    # resolver 를 통해 `FactResolutionError` 를 던질 수 있다)과 requirement
    # 의 v2 판정(등록 구현체 `evaluate()` 호출, 역시 `FactResolutionError`
    # 를 던질 수 있다) 어느 쪽보다도 반드시 먼저 일어난다(Phase 6 리뷰
    # High 2, 6회차에서 조건 계산 앞으로 재확인·이동). 순서가 바뀌면
    # 손상된 authority.yaml 이 조건 계산·requirement 판단 불능
    # (failure_mode='open' 등)에 가려져 한 번도 읽히지 않은 채 넘어갈 수
    # 있다 — "설정이 손상됐다"는 사실이 무관한 fail-open 뒤에 숨는 결함.
    # `_SWITCHED_NOT_LOADED` 는 "아직 로드 시도 안 함"을 뜻하는 sentinel
    # 이고, project_root 가 sentinel/`None` 이면(authority 비활성) 전혀
    # 로드하지 않는다 — 관련 없는 이벤트까지 authority.yaml 읽기를
    # 강제하지 않는다.
    authority_applicable = (
        project_root is not PROJECT_ROOT_NOT_PROVIDED and project_root is not None
    )
    switched = _SWITCHED_NOT_LOADED
    for loaded in policies:
        fields = loaded["fields"]
        if fields.get("trigger") != event_name:
            continue

        # Phase 6 6회차 리뷰 High 1/High 2 시정 — authority 는 이 정책의
        # `when` 조건을 계산하기 전에 로드한다(사이클당 최대 1회, 아래
        # `switched is _SWITCHED_NOT_LOADED` 가드). 순서가 바뀌면 두
        # 결함이 새어나간다 (module docstring "정책 단위 사전 필터" 절
        # 참조): (High 2) 손상된 authority.yaml 이 조건 계산 실패의
        # failure_mode 분기에 가려져 한 번도 읽히지 않을 수 있고, (High 1)
        # 이 정책의 requirement 가 전부 미전환이어도 `when` 조건의 지연
        # 계산 resolver 가 호출된다 — v2 가 판정에 전혀 개입하지 않아야
        # 할 축을 위해 부수효과를 일으키는 것 자체가 계약 위반이다.
        if authority_applicable and switched is _SWITCHED_NOT_LOADED:
            switched = authority.load_authority_policy(project_root=project_root)

        # 8회차 리뷰 시정 — `require` 를 즉시 tuple 로 실체화한다. 로더
        # 정상 경로는 이미 tuple 을 반환하지만(변경 없음), 로더를 우회한
        # 직접 호출(§13 `_raw_policy` 류)이 한 번만 순회 가능한 이터레이터
        # (예: `iter((...))`, 제너레이터)를 `require` 에 넣으면, 아래
        # 전환-여부 사전 필터(리스트 컴프리헨션, 7회차 시정)가 그 값을
        # 전부 소비해버려 더 아래 실제 판정 loop(`for requirement in
        # requirements:`)가 빈 것을 순회하고 조용히 통과했다 — 리뷰어
        # 재현: `require=('code_review',)` 는 BLOCK 이지만 `require=iter((
        # 'code_review',))` 는 ALLOW. 두 소비 지점(사전 필터 컴프리헨션 +
        # 판정 loop)이 반드시 **같은 자료구조**를 공유해야 하므로, 여기서
        # 한 번만 tuple 로 고정해 이후 어느 쪽이 먼저 순회해도 다른 쪽이
        # 여전히 전체 원소를 볼 수 있게 한다(이 함수 안에서 `requirements`
        # 를 소비하는 지점은 이 두 곳뿐 — 전수 확인됨). tuple 재생성은
        # 이미 tuple/list 인 정상 입력에도 안전하고 저렴하다(멤버십 검사만
        # 하는 `is_switched()` 이므로 I/O 비용 없음, module docstring "정책
        # 단위 사전 필터" 절의 "전부 계산해도 비용이 없다" 전제 유지).
        requirements = tuple(fields.get("require") or ())

        if authority_applicable and requirements:
            # Phase 6 7회차 리뷰 시정 — 전환 여부를 리스트 컴프리헨션으로
            # 먼저 전부 계산(materialize)한 뒤에야 `any()` 를 적용한다.
            # 이전 구현은 제너레이터 식을 `any()` 에 바로 넘겼는데,
            # `any()` 는 첫 True 를 만나면 단축 평가(short-circuit)로
            # 나머지 원소의 `is_switched()` 호출을 건너뛴다 — 전환된
            # 유효 축이 앞에, 로더를 우회해 들어온 미지 capability 이름이
            # 뒤에 있으면 그 미지 이름의 `is_switched()` 가 한 번도
            # 호출되지 않아 `UnknownCapabilityError` fail-closed 검증
            # (Medium 6-4) 자체가 새어나갔다 — 리뷰어 재현: 미지 축이
            # 있어도 ALLOW 로 새고(조건 resolver 가 호출된 뒤 failure_mode
            # 로 처리됨), 기대는 조건 resolver 호출 0회 + 미지 이름 즉시
            # 거부다. 리스트 컴프리헨션은 제너레이터와 달리 소비 여부와
            # 무관하게 전체 원소를 즉시 평가하므로, 뒤쪽 원소가 미지
            # 이름이면 이 지점에서 바로 `UnknownCapabilityError` 가
            # 전파된다(순서 무관 — 미지 축이 앞에 있어도 동일). 전환
            # 여부 검사 자체는 이미 로드된 `switched` frozenset 의 멤버십
            # 검사일 뿐이라 I/O 가 없으므로, 전부 계산해도 비용이 없다
            # (module docstring "정책 단위 사전 필터" 절 — 전부 미전환이면
            # 조건 계산 0회·authority 로드가 조건 계산보다 선행·사이클당
            # 1회 로드라는 기존 계약은 그대로 유지된다).
            switched_flags = [
                authority.is_switched(requirement, switched=switched)
                for requirement in requirements
            ]
            if not any(switched_flags):
                # 이 정책의 requirement 가 전부 미전환 — v1 이 이 정책의
                # 유일한 판정자다. `when` 조건조차 계산하지 않고(지연 계산
                # resolver 미호출) 이 정책을 완전히 건너뛴다 — matched_
                # policy_id 도 채우지 않고 authority_notes 도 남기지 않는다
                # (리뷰어 권고 원문: "전부 미전환이면 조건을 계산하지 않고
                # 그 정책을 건너뛴다"). missing_requirements/블록 판정에는
                # 영향이 없다 — 이 정책의 모든 requirement 는 (건너뛰지
                # 않았어도) `_requirement_satisfied` 가 즉시 satisfied=True
                # 로 취급했을 것이므로 최종 BLOCK/ALLOW 판정 자체는 동일하다.
                continue

        conditions = fields.get("when") or {}
        try:
            condition_mismatch = any(
                context.fact(key) != value for key, value in conditions.items()
            )
        except EvidenceStorageError as error:
            # 조건 계산 중 판단 불능(지연 계산 resolver 오류 등) — Phase 6
            # 리뷰 Medium 3 시정. 이전 구현은 이 `context.fact()` 호출을
            # try/except 밖에 두어(requirement 평가 경로만 잡았다),
            # `context.FactResolutionError`(EvidenceStorageError 하위)가
            # 조건 계산 중 나면 Decision 이 아니라 raw 예외로 evaluate()
            # 밖까지 전파됐다 — 정책이 declare 한 failure_mode(예: 'open'
            # 이면 경고와 함께 ALLOW) 의 의미가 통째로 사라지고, 호출자는
            # 예외를 직접 처리해야 했다. requirement 평가와 동일하게
            # `failures` 로 승격해 같은 판단 불능 분기를 태운다 — 이
            # policy 는 매칭 여부조차 확정할 수 없으므로(조건을 평가하지
            # 못했다) 아래 `continue` 로 건너뛰고, 최종 Decision 조립부는
            # 이 실패를 REASON_NO_MATCH(마치 무관했다는 뜻) 로 삼키지
            # 않도록 순서를 재정렬했다(아래 참조) — 부재로 삼키지 않는
            # 경계(spec §3.4)는 그대로 유지: 이 catch 는
            # `EvidenceStorageError` 계열만 잡고, 그 외 예외는 여전히
            # 전파된다.
            failures.append(
                (
                    _normalize_failure_mode(fields.get("failure_mode")),
                    loaded["policy_id"],
                    None,
                    error,
                )
            )
            continue
        if condition_mismatch:
            continue
        if matched_policy_id is None:
            matched_policy_id = loaded["policy_id"]
        for requirement in requirements:
            # authority 는 이미 이 정책의 `when` 조건 계산 이전에
            # 로드됐다(위 참조) — 여기서 다시 로드하지 않는다(사이클당
            # 1회 계약, Phase 6 6회차 리뷰 High 2 시정으로 로드 지점이
            # 위로 이동했다).
            try:
                satisfied, authority_note = _requirement_satisfied(
                    requirement, context, registry, project_root, switched
                )
            except EvidenceStorageError as error:
                failures.append(
                    (
                        _normalize_failure_mode(fields.get("failure_mode")),
                        loaded["policy_id"],
                        requirement,
                        error,
                    )
                )
                continue
            if authority_note is not None:
                authority_notes.append(authority_note)
            if not satisfied and requirement not in missing_requirements:
                if blocking_policy_id is None:
                    # BLOCK 은 첫 missing requirement 를 만든 policy 로
                    # 귀속한다 — 첫 trigger/when 매칭이 아니라. require 없는
                    # 선행 매칭·요구를 이미 충족한 선행 policy 가 자신이
                    # 소유하지 않은 BLOCK 을 뒤집어쓰지 않게 (판단 불능
                    # 경로의 _resolve_failure 귀속과 대칭).
                    blocking_policy_id = loaded["policy_id"]
                missing_requirements.append(requirement)

    if missing_requirements:
        # 정상 평가 BLOCK — 판단은 수행됐고 evidence 가 없을 뿐이다.
        # 다른 policy 의 판단 불능(fail-open 포함)이 이 BLOCK 을 약화하지
        # 않는다 (spec §3.4 경계). missing_requirements 가 비어있지 않다는
        # 것은 어떤 policy 든 이미 matched_policy_id 를 채웠다는 뜻이므로
        # (require 순회는 항상 그 대입 다음에 온다) 이 분기는
        # `matched_policy_id is None` 검사보다 먼저 와도 안전하다.
        return Decision(
            DECISION_BLOCK,
            reason=_with_authority_notes(REASON_MISSING_EVIDENCE, authority_notes),
            policy=blocking_policy_id,
            missing_requirements=tuple(missing_requirements),
        )
    if failures:
        # Medium 3 시정 — `matched_policy_id is None` 검사보다 먼저 확인
        # 한다. when 조건 계산 자체가 실패한 policy 는 `matched_policy_id`
        # 를 절대 채우지 못하므로(위 루프의 `continue`), 그 policy 하나만
        # 있는 경우 이 재정렬이 없으면 실패가 REASON_NO_MATCH 로 조용히
        # 삼켜져 policy 가 선언한 failure_mode 의 의미가 사라진다. missing_
        # requirements 를 여전히 이 분기보다 먼저 확인하는 순서(위)는
        # 그대로 유지된다 — "정상 평가 BLOCK 이 다른 policy 의 판단
        # 불능(fail-open 포함)보다 우선한다"는 기존 계약(spec §3.4)은
        # 손대지 않는다.
        return _resolve_failure(failures)
    if matched_policy_id is None:
        return Decision(DECISION_ALLOW, reason=REASON_NO_MATCH)
    return Decision(
        DECISION_ALLOW,
        reason=_with_authority_notes(REASON_NO_REQUIREMENTS, authority_notes),
        policy=matched_policy_id,
    )


def _requirement_satisfied(
    requirement, context, registry, project_root, switched=_SWITCHED_NOT_LOADED
):
    """requirement 1건의 충족 판정 — 등록 구현체 위임, 아니면 존재 검사,
    그 위에 authority 배선을 얹는다 (모듈 docstring "Authority 배선" 절).

    `switched`: 이 cycle 을 위해 `evaluate()` 가 이미 로드한 authority
    전환 집합(frozenset) — cycle 당 1회 로드 계약(High 2 시정)을 지키기
    위해 호출자가 주입한다. 기본값 `_SWITCHED_NOT_LOADED` 는 "아직 로드
    안 됨"이며, 이 함수가 직접 호출되는 방어적 경로(정상 경로는 항상
    `evaluate()` 가 명시적으로 채워 넘긴다)를 위해 이 함수 스스로
    `authority.load_authority_policy()` 를 호출해 채운다.

    반환값은 `(satisfied, authority_note)` 튜플이다. `authority_note` 는
    이번 requirement 판정에 authority 가 실제로 관여했고(=v2 가 판정할
    재료가 없어 보수적으로 미충족 처리됐거나, project_root 를 못 구해
    적용을 보류했거나, capability 가 아직 미전환이라 v2 결정에서
    제외됐음) 그 사실을 Decision.reason 에 남겨야 할 때만 문자열이고,
    그 외(authority 미배선·v2 가 판정을 냄)에는 항상 `None` —
    호출자(`evaluate`)는 `None` 이 아닌 경우만 모아 reason 에 덧붙인다.

    **순서 — 미전환 축은 v2 판정 자체를 계산하지 않는다** (Phase 6 5회차
    리뷰 시정. 4회차는 "미전환이면 `v2_satisfied` 를 최종값으로 쓰지
    않는다"만 고쳤는데, 그 수정은 *결과값*만 결정에서 제외했을 뿐 그
    결과값을 얻기 위한 *계산 자체*는 여전히 매 requirement 마다 수행하고
    있었다 — 등록 구현체 `evaluate(context)` 호출, `context.evidence_for`
    조회, 그 구현체가 내부적으로 쓰는 지연 계산 resolver 까지 전부 v1 이
    유일한 판정자여야 할 축에서 실행됐다. 이 I/O·부수효과 자체가 계약
    위반이다 — 그중 하나가 `EvidenceStorageError` 를 던지면 `evaluate()`
    루프가 이를 `failures` 로 승격해 policy 의 `failure_mode` 분기(예:
    'closed' → BLOCK)를 타므로, "판정에 개입하지 않는다"고 선언한 축이
    다른 경로로 여전히 결정에 영향을 준다. 그래서 이번 수정은 authority
    가 활성이면 **가장 먼저** 전환 여부부터 확인하고, 미전환이면 그
    자리에서 즉시 반환한다 — registry 조회도, `context.evidence_for` 도,
    구현체의 `evaluate()` 호출도 전혀 일어나지 않는다.

    **도달 범위 갱신 (Phase 6 6회차 리뷰 High 1 — module docstring "정책
    단위 사전 필터" 절)**: 5회차까지는 이 함수가 모든 requirement 에 대해
    호출됐지만, 6회차부터는 `evaluate()` 자신이 정책 단위로 한 번 더
    거른다 — 정책의 requirement 가 **전부** 미전환이면 `evaluate()` 는
    이 함수를 호출하기도 전에(그 정책의 `when` 조건조차 계산하지 않고)
    그 정책을 건너뛴다. 그 결과 이 함수의 미전환 분기(아래 2번 "미전환"
    항목)는 이제 **혼재 정책**(같은 정책에 전환된 requirement 도 함께
    있는 경우)의 미전환 축에서만 실제로 도달한다 — 이 함수 자체의 동작은
    바뀌지 않았다(여전히 registry·evidence·구현체를 건드리지 않고 즉시
    반환한다), 다만 정책 전체가 미전환인 흔한 경우는 이제 이 함수 앞
    단계에서 이미 걸러진다는 뜻이다.

    1. **authority 비활성 경로** — `project_root` 가 sentinel
       (`PROJECT_ROOT_NOT_PROVIDED`, 기본값)이면 v2 충족 판정(등록
       구현체 위임 또는 evidence 존재 검사, 기존 Task 3.1 동작 그대로)만
       계산해 그대로 반환한다 — `context.evidence_for` 를 추가로 호출하지
       않는다(기존 1211 테스트가 이 경로이므로 evidence 조회 횟수까지
       완전히 동일해야 한다 — active_task 처럼 evidence 저장소를 원래
       전혀 건드리지 않는 capability 가 이 배선으로 새로 건드리게 되면
       안 된다). `project_root` 가 `None`(명시) 이면 v2 판정은 그대로
       쓰되 "project_root 없어서 authority 미적용"을 note 로 남긴다
       (조용한 통과 금지, 방향은 부모 지시).
    2. **authority 활성 경로** (`project_root` 가 실제 문자열) — v2 판정을
       계산하기 **전에** `authority.is_switched()` 로 전환 여부부터
       확인한다. 이 조회는 이미 로드된 `switched` frozenset 의 멤버십
       검사일 뿐이라 I/O 도 registry 호출도 없다(단, 5종 밖 이름은 여기서
       바로 `UnknownCapabilityError` 로 fail-closed — 이전 구현이
       `requirement not in REQUIREMENT_NAMES` 를 조기 반환해 로더 우회
       직접 호출에 대해 이 원칙을 적용하지 않았던 구멍, Phase 6 리뷰
       Medium 6-4 시정을 그대로 보존한다).
         - **미전환**이면 즉시 `(True, _authority_unswitched_note(...))`
           를 반환한다 — registry 조회·`context.evidence_for`·등록
           구현체의 `evaluate()` 호출 어느 것도 일어나지 않는다(v1 훅이
           여전히 그 requirement 의 유일한 판정자로 남아야 하는데, v2
           가 판정 재료를 만들려고 부작용을 일으키는 것 자체가 "판정에
           개입하지 않는다"는 계약 위반이다). `satisfied=True` 로
           취급하는 이유는 4회차와 동일 — missing_requirements 계산에서
           사실상 빠지게 하기 위함이다(Phase 6 4회차 리뷰 High 1 시정
           원문 유지).
         - **전환됨**이면 이제 v2 충족 판정을 계산한다(등록 구현체
           위임 또는 evidence 존재 검사). 그 값을 `authority.
           resolve_authority` 에 넘길 `v2_for_authority` 로 무엇을 쓸지는
           capability 의 판정 방식 분류(`authority.is_evidence_issued`,
           유일한 SSOT 는 authority 모듈)에 달려 있다 — **"증거 레코드
           없음"과 "v2 가 판정을 못 내림"은 다른 사실이다** (부모
           재작업 지시, 2026-08-12):
             - **증거 발급형**(`authority.EVIDENCE_ISSUED_CAPABILITIES`
               — code_review/security_review/tests_passed/user_approval):
               code_review/security_review 2축은 **2026-08-20 개정
               (spec §3.6 판정 상태표, Phase 7 웨이브 3 ③-a) +
               ③-d(2026-08-24) 단순화** — 등록 구현체
               (`CodeReviewRequirement.evaluate`/
               `SecurityReviewRequirement.evaluate`)가 종국 상태표
               (subject-empty→충족/subject-unresolved→미충족/non-empty+
               유효→충족/non-empty+무효→미충족)를 이미 구현하므로, 그
               결과(`v2_satisfied`, 항상 `bool`)를 **그대로**
               `v2_for_authority` 로 넘긴다 — subject 상태를 이 계층에서
               재확인하지 않는다(③-a 때는 `SUBJECT_EMPTY`/
               `SUBJECT_UNRESOLVED`/무효 증거를 여기서 한 번 더 걸러
               `None` 을 넘겼으나, 그 재확인은 legacy 대체 여부를 가르는
               게이트였을 뿐이었다 — legacy 가 사라진 ③-d 부터는
               불필요하다). tests_passed/user_approval 2축은 이 단순화
               범위 밖 — 기존 "evidence 레코드 존재" 게이팅을 그대로
               쓴다(무변경, `subject_fact_key` 가 없는 축).
             - **fact 판정형**(`authority.FACT_JUDGED_CAPABILITIES` —
               active_task): 등록 구현체가 있으면(`has_registered_impl`)
               그 결과(`v2_satisfied`)를 무조건 v2 판정으로 넘긴다 —
               `context.evidence_for` 를 조회하지조차 않는다(이 부류는
               Evidence 를 구조적으로 발급하지 않으므로, evidence 유무로
               게이팅하면 v2 판정이 한 번도 쓰이지 못하는 결함이 된다).
           이 지점에서는 `is_switched()` 로 이미 전환을 확인했으므로
           `authority.resolve_authority` 의 `result.intercepted` 는
           항상 `True` 다 — 정책이 호출 사이에 바뀌지 않는 한(cycle 당
           1회 로드 계약, High 2 시정) 재확인은 항상 같은 결과를 낸다.
       `AuthorityError` 계열(정책 손상·미지 capability·미분류
       capability)은 잡지 않고 그대로 전파한다 — `bin/rein` 의 포괄
       예외 처리기가 BLOCK + exit 0 로 fail-closed 변환한다(모듈
       docstring 참조, 이 함수는 그 처리를 책임지지 않는다).
    """
    if project_root is PROJECT_ROOT_NOT_PROVIDED:
        return _compute_v2_satisfied(requirement, context, registry), None
    if project_root is None:
        return (
            _compute_v2_satisfied(requirement, context, registry),
            _authority_skipped_note(requirement),
        )

    # authority 활성 — v2 판정을 계산하기 전에 전환 여부부터 확인한다
    # (이 함수 docstring "순서" 절 참조). `switched` 가 아직 로드되지
    # 않았으면(방어적 직접 호출 경로) 여기서 1회 로드해 이후 재사용한다
    # — evaluate() 의 정상 경로는 이미 로드된 값을 넘기므로 이 분기를
    # 타지 않는다(cycle 당 1회 로드 계약 유지).
    resolved_switched = (
        authority.load_authority_policy(project_root=project_root)
        if switched is _SWITCHED_NOT_LOADED
        else switched
    )
    if not authority.is_switched(requirement, switched=resolved_switched):
        # 미전환 capability (Phase 6 4·5회차 리뷰 시정) — plan Task 6.1
        # 계약 "미전환 capability 는 v1 경로 유지" 를 v2 evaluate() 관점
        # 에서 실현한다. registry 조회·evidence 조회·구현체 evaluate()
        # 호출 어느 것도 하지 않고 즉시 반환한다 — v1 훅이 여전히 그
        # requirement 의 유일한 판정자로 남아야 하는데, v2 가 판정 재료를
        # 만들려는 시도(그리고 그 과정의 예외·부수효과)조차 "판정에
        # 개입하지 않는다"는 계약 위반이기 때문이다(5회차 리뷰: 4회차는
        # 결과값만 제외했을 뿐 계산 자체를 막지 않았다). 그 제외가 조용한
        # 통과로 오인되지 않도록 근거에는 항상 남긴다(v2 가 판정할 재료가
        # 없어 보수적으로 미충족 처리된 축이 항상 reason 에 남는 것과
        # 동일한 "조용히 통과시키지 않는다" 원칙).
        return True, _authority_unswitched_note(requirement)

    has_registered_impl = _has_registered_impl(registry, requirement)
    v2_satisfied = _compute_v2_satisfied(
        requirement, context, registry, has_registered_impl=has_registered_impl
    )

    if has_registered_impl and not authority.is_evidence_issued(requirement):
        # fact 판정형(예: active_task, `authority.FACT_JUDGED_CAPABILITIES`
        # 참조) — 등록 구현체가 실제로 평가를 수행했다면 그 결과가 곧 v2
        # 판정이다. "증거 레코드 없음"을 "v2 가 판정할 재료가 없음"으로
        # 오인해 보수적 미충족(`v2_for_authority=None`)으로 내려가지
        # 않는다 — 이 부류는 Evidence 를 구조적으로 절대 발급하지
        # 않으므로(`context.evidence_for` 가 항상 빈 tuple), evidence
        # 존재 여부로 게이팅하면 전환을 켜도 v2 판정이 한 번도 쓰이지
        # 못하는 결함이 된다(부모 재작업 지시, 2026-08-12). 그래서
        # `context.evidence_for` 를 아예 조회하지 않는다 — fact 판정형은
        # evidence 저장소를 원래 건드리지 않는 capability 다.
        v2_for_authority = v2_satisfied
    else:
        # 증거 발급형(`authority.EVIDENCE_ISSUED_CAPABILITIES`).
        #
        # **③-d(2026-08-24) 단순화 — 전환기 위임 매핑 제거.** code_review/
        # security_review 는 더 이상 이 계층에서 subject 상태를
        # 재확인하지 않는다. ③-a(2026-08-20) 때는 "레코드 존재"만으로
        # v2 를 authority 에 넘기던 구 동작(과거 사이클의 낡은/무효 증거
        # 1건이 "증거 존재 → v2 무조건 승리 → 미충족"으로 이어져 legacy
        # 신선 표식이 있어도 영구 차단되는 함정)을 막기 위해 이 계층이
        # `context.fact(subject_fact_key)` 로 subject 상태
        # (`SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`/부재)를 한 번 더 확인해
        # 무효/부재 상황엔 `None` 을 넘겨 legacy 대체를 유도했다. legacy
        # 대체 자체가 ③-d 로 제거된 지금은 그 재확인이 의미가 없다 —
        # 등록 구현체(`CodeReviewRequirement.evaluate`/
        # `SecurityReviewRequirement.evaluate`)가 subject-empty→충족/
        # subject-unresolved→미충족/non-empty+유효→충족/non-empty+무효→
        # 미충족의 종국 상태표를 이미 구현하므로(spec §3.6), 그 결과
        # (`v2_satisfied`, 등록 구현체가 있는 한 항상 `bool`)를
        # **재구현·재확인 없이 그대로** `authority.resolve_authority`
        # 에 넘긴다(단일 정본 유지 원칙 — capability `evaluate()` 가
        # 유일한 유효성 판정 구현이다).
        #
        # `subject_fact_key` 가 없는 requirement(tests_passed/
        # user_approval — 이 웨이브 범위 밖, `authority.CURRENT_SUBJECT_
        # FACT_KEYS` docstring 참조)는 기존 "증거 레코드 존재" 게이팅을
        # 그대로 쓴다 — 이 두 축은 여전히 evidence-존재 게이팅을 유지
        # 하므로 `context.fact()` 호출도 subject 계산도 필요 없다.
        # `CURRENT_SUBJECT_FACT_KEYS` 는 이제 fact 값을 조회하는 데
        # 쓰이지 않고, "이 requirement 가 종국 상태표 개정 대상 2축에
        # 속하는가"를 가르는 축 분류 판별자로만 쓰인다. 등록 구현체가
        # 없는 경우(has_registered_impl=False)는 종국 상태표 개정 대상인
        # 두 축이라도 그 개정(subject 유효성 검증)을 구현할 코드가 없다
        # — 아래 안쪽 분기가 `v2_for_authority=None`(fail-closed)으로
        # 명시 처리한다(코드리뷰 High 시정, 2026-08-24 — 이전엔 이
        # 조건이 코드에 반영되지 않아 미등록 축의 존재-only 판정이 그대로
        # authority 에 전달됐다).
        if requirement in authority.CURRENT_SUBJECT_FACT_KEYS:
            if has_registered_impl:
                v2_for_authority = v2_satisfied
            else:
                # 등록 구현체가 없으면(예: registry=None) 종국 상태표의
                # subject 유효성 검증(subject 일치+result 충족+policy
                # version 유효)을 수행할 코드가 아예 없다 —
                # `_compute_v2_satisfied` 는 이 경우 검증 없이
                # `bool(context.evidence_for(requirement))`(존재만
                # 확인)로 떨어지므로, 그 값을 그대로 authority 에 넘기면
                # stray/무효 evidence(잘못된 subject·policy version·
                # subject-unresolved 등)가 존재한다는 사실만으로 ALLOW
                # 로 승격된다 — ③-a 가 막으려던 바로 그 "증거 존재 →
                # 무조건 승리" 함정이 등록 부재 경로로 되살아나는
                # 회귀(코드리뷰 High, 2026-08-24). 검증 수단이 없으므로
                # fail-closed: v2 판정 재료가 없다고 명시(`None`)해
                # `resolve_authority` 가 보수적 미충족으로 닫게 한다.
                v2_for_authority = None
        else:
            evidence_present = bool(context.evidence_for(requirement))
            v2_for_authority = v2_satisfied if evidence_present else None

    result = authority.resolve_authority(
        requirement, v2_for_authority, project_root, switched=resolved_switched
    )
    # is_switched() 로 이미 전환을 확인했으므로 여기서는 항상
    # intercepted=True 다 (docstring "전환됨" 절 참조).
    if result.source == authority.SOURCE_V2:
        # v2 가 이겼다(v2 evidence 승리든 fact 판정형의 무조건 v2 채택
        # 이든) — 두 경우 모두 v2_satisfied 와 값이 같고, reason 에 남길
        # 새로운 사실이 없다.
        return v2_satisfied, None
    return result.satisfied, _authority_source_note(requirement, result)


def _has_registered_impl(registry, requirement):
    """registry 에 이 requirement 의 등록 구현체가 있는지 — I/O 없는
    순수 조회(dict 멤버십 검사)라 미전환 short-circuit 이전에도 안전하게
    호출할 수 있지만, 호출자는 여전히 전환 확인 *이후*에만 이 함수를
    부른다 — 등록 구현체의 존재를 아는 것과 그것을 *실행*하는 것을
    섞지 않기 위해서다(실행은 `_compute_v2_satisfied` 소관)."""
    return (
        registry is not None
        and registry.has_contract(requirement)
        and registry.is_registered(requirement)
    )


def _compute_v2_satisfied(requirement, context, registry, has_registered_impl=None):
    """v2 충족 판정 — 등록 구현체 위임, 아니면 evidence 존재 검사(기존
    Task 3.1 동작, 변경 없음). 호출자가 `has_registered_impl` 을 이미
    계산해뒀으면 재사용하고, 아니면 여기서 계산한다."""
    if has_registered_impl is None:
        has_registered_impl = _has_registered_impl(registry, requirement)
    if has_registered_impl:
        return bool(registry.resolve(requirement).evaluate(context))
    return bool(context.evidence_for(requirement))


def _authority_skipped_note(requirement):
    return (
        "authority not applied for requirement {!r} — project_root "
        "unavailable, existing v1/v2 judgement retained".format(requirement)
    )


def _authority_unswitched_note(requirement):
    return (
        "requirement {!r} is not switched to v2 authority yet — this axis "
        "is v1's jurisdiction and v2 declines to judge it (excluded from "
        "the v2 decision)".format(requirement)
    )


def _authority_source_note(requirement, result):
    # ③-d(2026-08-24) — "dual read" 문구는 legacy marker 대체가 있던
    # 시절의 표현이었다. legacy 대체가 제거된 지금 이 note 는 v2 가
    # 판정할 재료 자체가 없어(`result.source == authority.
    # SOURCE_NO_MATERIAL`) 보수적으로 미충족 처리됐다는 뜻만 남는다.
    return (
        "requirement {!r} satisfied={!r} via authority judgement "
        "(source={!r})".format(requirement, result.satisfied, result.source)
    )


def _with_authority_notes(reason, notes):
    if not notes:
        return reason
    return reason + " — " + "; ".join(notes)


def _normalize_failure_mode(failure_mode):
    """미선언·미지 mode 는 fail-closed — 로더 우회 입력의 안전 기본값."""
    if failure_mode in FAILURE_MODES:
        return failure_mode
    return FAILURE_MODE_CLOSED


def _resolve_failure(failures):
    """판단 불능 목록을 가장 보수적인 failure_mode 로 수렴한다.

    `requirement` 이 `None` 이면 requirement 평가가 아니라 policy 의
    `when` 조건 계산 자체가 실패한 경우다(Medium 3 시정 — 위 `evaluate()`
    루프의 조건 매칭 try/except 참조). 두 경우 모두 같은 failure_mode
    수렴·심각도 규칙을 타되, reason 문구만 "requirement" 대신 "policy
    condition" 으로 갈라 실패 지점을 정확히 가리킨다.
    """
    chosen = min(
        failures, key=lambda failure: _FAILURE_SEVERITY.index(failure[0])
    )
    failure_mode, policy_id, requirement, error = chosen
    if requirement is None:
        subject = "policy {!r} condition".format(policy_id)
    else:
        subject = "requirement {!r}".format(requirement)
    reason = "evaluation failure while checking {} ({}) — {}".format(
        subject, error, _FAILURE_REASON_SUFFIX[failure_mode]
    )
    return Decision(
        _FAILURE_DECISIONS[failure_mode], reason=reason, policy=policy_id
    )
