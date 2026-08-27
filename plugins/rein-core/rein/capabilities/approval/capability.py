"""approval capability — user_approval Evidence 의 one-shot 발급 + 소비 (plan Task 4.5).

spec §3.6 user_approval (§21, 원문 인용):
    "BLOCK 상황의 명시적 승인. 기본 scope = 현재 action + 현재 digest +
    one-shot. 사용된 Approval 재사용 금지. `.skip-review`/`.skip-security`
    류 marker 우회는 제거."

spec §2.2 위협 모델 (원문 인용):
    "Agent 가 Evidence 파일(JSON 등)을 직접 생성하는 것만으로는 어떤
    Requirement 도 충족되지 않는다 — Evidence 는 Rein Runtime 만
    발급한다."

## 이 capability 가 review/security 와 다른 지점 — Evidence 는 불변인데 "소비" 는 가변 상태다

review/security 는 "발급된 Evidence 라도 digest·policy version 두 축을
평가 시점에 재확인한다" 는 계약만으로 충분했다 — 두 축 모두 Evidence
필드(`subject`, `policy_version`)와 **현재 fact** 의 순수 비교라 그
자체로는 상태를 갖지 않는다. user_approval 의 one-shot 은 이 형태로
표현할 수 없다: "이 Evidence 가 이미 다른 요청을 충족시키는 데 쓰였는가"
는 Evidence 레코드 자신의 필드가 아니라 **그 이후에 일어난 사건**이고,
kernel `Evidence` 는 `@dataclass(frozen=True)` 로 불변이다 — 발급 후
"사용됨" 필드를 되돌아가 세팅할 수 없고, 세팅해서도 안 된다(불변
레코드에 사후 가변 필드를 넣으면 원장 fingerprint 대조 계약 자체가
흔들린다, `kernel/evidence.py` "서명이 아니라 원장 대조" 절 참조).

**설계 판단 (plan Task 4.5 지시의 두 옵션 중 (b) 채택, 사이클 C 재리뷰
2회차 High 지적으로 "즉시 claim" 을 "예약 → 최종 ALLOW 시점 commit"
2단계로 재설계)**:

- (a) 평가가 소비를 기록할 저장 인터페이스(주입)를 받아 1회 충족 후
  무효화.
- **(b) 채택 — 발급 시 action+digest 결속 metadata 를 갖고, 평가는
  주입된 "소비 저장 프로토콜"과 대조한다.** capability 는 여전히
  review/security 와 동일하게 `context.fact()` 로 값을 조회하는
  방식만 쓴다 — 다만 그 값이 review 의 `changeset.digest` 같은 단순
  스칼라가 아니라 **소비 여부를 확인·기록하는 객체**(duck-typed
  프로토콜)라는 점이 다르다. capability 는 여전히 그 객체가 무엇으로
  구현됐는지(파일/sqlite/메모리) 모른다 — 프로토콜 메서드 두 개만
  참조한다:
  - `is_consumed(fingerprint) -> bool` — 순수 조회(peek). `evaluate()`
    가 직접 호출한다.
  - `claim(fingerprint) -> bool` — **원자적** check-and-set. `evaluate()`
    는 이 메서드를 **직접 호출하지 않는다** — 아래 "2단계 재설계" 절
    참조.

  **1회차 구현의 결함과 2단계 재설계 (사이클 C 재리뷰 2회차 High)**:
  1회차는 `evaluate()` 가 유효한 미소비 승인을 찾자마자 그 자리에서
  `claim()` 을 호출했다 — "판정과 소비를 한 원자적 사건으로 묶는다"는
  의도였지만, 이는 **evaluate() 호출 시점에는 이 cycle 의 최종 decision
  을 아직 모른다**는 사실을 놓쳤다. evaluator 는 policy 목록 전체를
  순회하며 각 policy 의 `require` 목록을 전부 확인한 뒤에야 최종
  decision 을 낸다(`rein/engine/evaluator.py` — 앞선 requirement 가
  이미 실패했어도 뒤의 requirement 평가를 멈추지 않는다). 리뷰어가
  실증한 두 경로:
    (a) 같은 cycle 에서 서로 다른 policy 2개가 모두 `user_approval` 을
        요구하면, 첫 번째 policy 평가가 그 승인을 소비해 버려 두 번째
        policy 평가에서는 이미 소비된 것으로 보여 미충족 → 전체
        decision 이 BLOCK 으로 뒤집힌다. 실제로는 **같은 승인 하나로
        두 policy 를 동시에 충족**시키는 것이 맞는 동작이다.
    (b) 한 policy 가 `[code_review, user_approval]` 을 요구하는데
        `code_review` evidence 가 없으면, `user_approval` 평가는
        (evaluate 순서상) 여전히 실행돼 승인을 소비해 버리지만, 전체
        decision 은 `code_review` 부재로 어차피 BLOCK 이다 — 승인만
        헛되이 소모된다.
  두 경로 모두 근본 원인이 같다: **"승인 사용"과 "최종 허용"이 원자적
  하나의 사건이 아니었다**(cycle 전체가 끝나기 전에 개별 requirement
  평가가 외부 상태를 먼저 바꿔 버렸다).

  수정: `evaluate()` 를 **무부수효과**로 되돌리고, 부수효과의 실행
  시점을 cycle 종료 + 최종 decision 확정 이후로 미룬다 — 2단계:

  1. **예약 (이 모듈, `evaluate()`)**: 유효한 미소비 승인(`is_consumed()`
     == `False`)을 찾으면 `context.reserve_consumption(store,
     fingerprint)` 로 "이 cycle 이 ALLOW 로 끝나면 이 쌍을 commit
     하라"는 예약만 남기고 충족(`True`)을 반환한다. 외부 저장소는
     아무것도 바뀌지 않는다. `EvaluationContext.reserve_consumption`
     은 `(store, fingerprint)` 조합을 **집합**으로 멱등 저장하므로
     (`rein/engine/context.py` 참조), 같은 cycle 안에서 같은 fingerprint
     가 몇 번을 다시 예약돼도(케이스 (a)) 하나로 수렴한다 — "예약된
     fingerprint 는 이 cycle 안에서는 여전히 유효하다"는 성질이 별도
     분기 없이 자연히 성립한다(`is_consumed()` 는 외부 상태만 보므로,
     예약만 해둔 상태에서는 계속 `False` 를 답한다).
  2. **commit (Runtime, `rein/engine/runtime.py`)**: cycle 전체가 끝나
     최종 decision 이 확정된 뒤, decision 이 **ALLOW 일 때만**
     `context.pending_consumptions()` 를 순회하며 각 `(store, key)` 의
     `store.claim(key)` 를 실제로 호출한다. BLOCK/ASK_USER 면 예약을
     그냥 버린다 — 승인은 소비되지 않은 채 보존된다(케이스 (b) 해결).
     `evaluator.evaluate()` 자신은 이 슬롯을 전혀 건드리지 않는다 —
     `Decision` 반환 계약이 그대로 유지된다.

  이 재설계로 capability 는 여전히 저장 구현을 모른다(프로토콜만
  참조) — 다만 이제 "언제 commit 하는가"까지도 capability 밖(Runtime)
  으로 옮겨졌다. `EvaluationContext` 가 이 예약을 들고 있을 수 있는
  것은 스스로가 "1 인스턴스 = 1 Evaluation Cycle" 계약을 갖기 때문이다
  (`rein/engine/context.py` 클래스 docstring) — 예약은 cycle 수명을
  넘지 않는다.
- 소비 저장 프로토콜 확인 불가(주입 fact 미제공, `None`)는 **보수적으로
  미충족**이다 — 확인 불가를 충족으로 승격하지 않는다(spec §3.4 "확인
  불가 ≠ 충족" 원칙의 이 capability 판, review/security 의 digest·
  version fact 미확보 시 미충족과 동일 방향). 재사용 여부를 확인할 수
  없는 승인을 "아직 안 썼다"고 낙관하면 one-shot 계약 자체가
  무의미해진다(게이트 계열은 FN 이 FP 보다 나쁘다는 이 저장소의 반복
  결정과 동일 방향).

## action+digest 결속 — 두 축의 위치

Evidence 는 단일 `subject` 필드만 갖는다(spec §3.5). digest 는 기존
관례(subject=digest, review/security 와 동일)를 그대로 따르고, action
은 `metadata` 필드에 담는다(`METADATA_KEY_ACTION`). action 은 policy
version 처럼 "digest 와 독립인 무효화 축" 이 아니라 "digest 와 나란히
결속돼야 하는 두 번째 identity 축" 이므로, `policy_version_valid` 같은
별도 kernel 순수 함수를 새로 만들지 않고 단순 동등 비교로 충분하다.

## marker 인식 경로 부재 (spec §21, §3.6, §11.1)

이 모듈은 어떤 파일 경로도 읽지 않는다 — `.skip-review`/`.skip-security`
류 marker 파일을 인식하는 코드 경로가 애초에 존재하지 않는다(정적 grep
검사는 `tests/bypass/test_marker_bypass_removed.py` 가 고정한다). 승인은
오직 이 모듈의 `issue_user_approval_evidence` 를 Runtime 이 호출해야만
생기고, 그 호출은 실제 사용자 승인 상호작용을 전제로 한다 — 파일
존재만으로 우회하는 경로가 없다.

Capability 간 직접 의존 금지 (spec §3.1) — 이 모듈은 kernel 어휘와
engine context 계약만 사용한다. `review`/`security`/`task`/`testing`
capability 는 어떤 형태로도 import 하지 않는다.
"""
from datetime import datetime, timezone

from rein.engine.context import FactResolutionError
from rein.kernel.evidence import (
    Evidence,
    PRODUCER_USER_APPROVED,
    evidence_fingerprint,
    policy_version_valid,
    subject_matches,
)
from rein.kernel.requirement import Requirement

# 고정 5종 계약 이름 (kernel REQUIREMENT_NAMES 원소, spec §3.4)
REQUIREMENT_NAME = "user_approval"

# 발급 result 어휘 — review/security 의 "PASS" 리뷰 verdict 관례를 그대로
# 승계하지 않는다: 이 capability 는 리뷰 판정이 아니라 사용자의 승인
# 행위 자체를 기록하므로, 그 사실에 맞는 자체 어휘를 쓴다. strict —
# 변형(approved/Approved/공백 포함 등)을 승격하지 않는다.
RESULT_APPROVED = "APPROVED"

# Evidence.metadata 안에서 승인 대상 action 식별자를 담는 키(모듈
# docstring "action+digest 결속" 절).
METADATA_KEY_ACTION = "action"

# 현재 action(이벤트/명령) 식별자 fact — 승인 scope 의 첫 번째 축(spec
# §3.6 §21 "현재 action"). 값의 계산(무엇이 "현재 action" 인지 식별)은
# platform/engine fact resolver 소관이고, 이 capability 는 값만 조회한다.
FACT_ACTION_CURRENT = "action.current"

# 현재 ChangeSet digest fact 키 — review capability 의 `changeset.digest`
# 관례를 따르되 import 로 공유하지 않는다(capability 간 직접 의존 금지,
# spec §3.1 — 공유는 kernel/engine 어휘 경유만). 승인 scope 의 두 번째
# 축(spec §3.6 §21 "현재 digest").
FACT_CHANGESET_DIGEST = "changeset.digest"

# 현재 policy version / 호환 선언 fact 키 (spec §3.4 Policy Versioning) —
# review/security 와 동일 관례, import 로 공유하지 않는다. 호환 선언
# 값은 version 문자열 collection 이어야 한다 — 단일 문자열은 kernel
# `policy_version_valid` 가 문자 단위 분해 오인정을 막기 위해 명시
# 거부한다.
FACT_POLICY_VERSION = "policy.version"
FACT_POLICY_COMPATIBLE_VERSIONS = "policy.compatible_versions"

# 소비 저장 프로토콜 주입 fact — "이미 소비된 Evidence 를 확인·기록하는
# 객체"(모듈 docstring "설계 판단" 절의 옵션 (b)). 값은 duck-typed
# 프로토콜을 만족하는 임의 객체다:
#   - `is_consumed(fingerprint) -> bool` — evaluate() 가 직접 호출(peek)
#   - `claim(fingerprint) -> bool` (원자적 check-and-set) — evaluate()
#     는 이 메서드 참조를 `context.reserve_consumption` 에 넘기기만
#     하고 직접 호출하지 않는다(2단계 재설계, 모듈 docstring 참조).
#     실제 호출은 cycle 종료 후 `rein.engine.runtime` 이 한다.
#   - `release(fingerprint) -> Any` (사이클 C 재리뷰 3회차 추가) — 같은
#     cycle 에 예약된 다른 claim 이 실패해 전체가 fail-closed BLOCK 으로
#     downgrade 될 때, 이미 성공한 claim 을 best-effort 로 되돌리기
#     위한 보상 동작. 이 메서드도 `evaluate()` 는 호출하지 않는다 —
#     `rein.engine.runtime._rollback_committed` 가 호출한다.
# review 의 `evidence_source`(= `find()` 하나만 있으면 되는 duck-type,
# ABC 상속 강제 없음)와 동일한 원칙 — 이 capability 는 구현을 모르고
# 프로토콜 모양만 검증한다(`_validate_consumption_store`). `None`(미주입
# /확인 불가)은 보수적으로 미충족 처리한다 — `evaluate()` 가 명시
# 분기한다.
FACT_APPROVAL_CONSUMPTION_STORE = "approval.consumption_store"

# 소비 저장 프로토콜이 갖춰야 하는 콜러블 메서드 이름 — 순서는 "조회 →
# 기록 → 보상" 관례를 반영할 뿐 검증 순서와는 무관하다(셋 다 필수).
# `release` 는 이 capability 자신은 쓰지 않지만(runtime 소관), 발급
# 시점에 이미 프로토콜 전체를 갖춘 store 인지 검증해 두면 "ALLOW 로
# 판정된 뒤 commit 단계에서야 프로토콜 결손이 드러나는" 더 늦고 위험한
# 실패 시점을 앞당길 수 있다 — fail fast.
_CONSUMPTION_STORE_METHODS = ("is_consumed", "claim", "release")


def _validate_consumption_store(store):
    """소비 저장 프로토콜 duck-type 검증 — 필수 콜러블 세 개를 확인한다.

    ABC 상속을 강제하지 않는다(review 의 `evidence_source` 프로토콜과
    동일 원칙) — `is_consumed`/`claim`/`release` 이름의 콜러블 속성만
    있으면 구현 방식은 자유다. 하나라도 없거나 호출 불가능하면
    malformed 주입으로 간주해 `FactResolutionError` 로 승격한다 —
    관대하게 무시하고 "미소비"로 오인정하면 one-shot 계약이 조용히
    새는 경로가 된다.
    """
    for method_name in _CONSUMPTION_STORE_METHODS:
        method = getattr(store, method_name, None)
        if not callable(method):
            raise FactResolutionError(
                "fact {!r} must provide callable {!r} (consumption store "
                "protocol: is_consumed(fingerprint) -> bool, "
                "claim(fingerprint) -> bool, release(fingerprint) -> "
                "Any), got {!r} (missing/non-callable {!r})".format(
                    FACT_APPROVAL_CONSUMPTION_STORE,
                    _CONSUMPTION_STORE_METHODS,
                    store,
                    method_name,
                )
            )


def issue_user_approval_evidence(
    action, current_digest, policy_version, created_at=None
):
    """Runtime 발급 함수 — 현재 action + 현재 digest 를 결속해서만 발급한다.

    review/security 의 `issue_*_evidence(response, ...)` 와 달리 파싱할
    "structured review response" 가 없다 — user_approval 은 리뷰 판정이
    아니라 사용자의 실제 승인 상호작용 그 자체를 기록하는 것이라, 이
    함수는 Runtime 이 그 상호작용을 이미 확인했다는 전제 하에 호출된다
    (모듈 docstring "marker 인식 경로 부재" 절 — 파일 존재만으로 이
    함수를 우회 호출할 경로는 없다).

    - `action`: 승인 대상 action 식별자(비어있지 않은 str). Evidence 의
      `metadata[METADATA_KEY_ACTION]` 에 담긴다.
    - `current_digest`: Runtime 이 스스로 계산한 현재 ChangeSet digest.
      Evidence 의 `subject` 가 된다(review/security 와 동일한
      subject=digest 관례).
    - `created_at`: 발급 시각 주입(`None` 이면 현재 UTC) — 테스트
      결정성.

    두 식별자 모두 Runtime 자신이 계산해 넘기는 값이다(Agent 의
    자기진술이 아니다) — 비어있지 않은 문자열이 아니면 거부 사유별
    예외가 아니라 호출자(Runtime) 계약 위반인 `ValueError` 로 즉시
    실패한다(review 의 `current_digest` 검사와 동일한 위치).
    """
    if not isinstance(action, str) or not action:
        raise ValueError(
            "action must be a non-empty action identifier string computed "
            "by the runtime, got {!r}".format(action)
        )
    if not isinstance(current_digest, str) or not current_digest:
        raise ValueError(
            "current_digest must be a non-empty digest string computed by "
            "the runtime, got {!r}".format(current_digest)
        )
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return Evidence(
        type=REQUIREMENT_NAME,
        subject=current_digest,
        result=RESULT_APPROVED,
        created_at=created_at,
        # 명시적 사용자 승인 — producer 3등급 중 최상위 신뢰 등급
        # (spec §3.5, §2.2 신뢰 위계)
        producer=PRODUCER_USER_APPROVED,
        policy_version=policy_version,
        metadata={METADATA_KEY_ACTION: action},
    )


class UserApprovalRequirement(Requirement):
    """user_approval Requirement 구현체 — action+digest+producer+one-shot 결합 (spec §3.6 §21).

    evidence 존재만으로 충족이 아니다 — `RESULT_APPROVED` 레코드가
    **네 축** 모두를 통과해야 충족이다:

    - digest 축: `subject`가 평가 시점의 현재 digest 와 일치
      (`subject_matches`, kernel 순수 함수 재사용).
    - action 축: `metadata[METADATA_KEY_ACTION]` 이 평가 시점의 현재
      action 과 일치(단순 동등 비교 — 모듈 docstring 참조).
    - producer 축(사이클 C 리뷰 1회차 High 2 추가): `producer ==
      PRODUCER_USER_APPROVED`. review/security 판정이나 runtime 자동
      관측 결과가 `type=user_approval` 로 잘못 기록돼도(다른 producer
      등급) 충족 재료가 아니다 — testing capability 가 `producer ==
      PRODUCER_RUNTIME_VERIFIED` 를 평가 시점에 재확인하는 것과 동일한
      대칭: 발급 함수(`issue_user_approval_evidence`)가 구조적으로
      `PRODUCER_USER_APPROVED` 만 만들 수 있어도, evidence 저장소에 다른
      경로로 다른 producer 레코드가 `type=user_approval` 로 섞여 들어오는
      경우까지 evaluate 가 다시 막는다.
    - policy version 축: `policy_version_valid`(kernel 순수 함수
      재사용) — digest·action·producer 와 독립인 네 번째 무효화 축
      (spec §3.4).

    그리고 **one-shot 축**: 위 네 축을 통과한 레코드라도, 그 fingerprint
    가 주입된 소비 저장 프로토콜(`FACT_APPROVAL_CONSUMPTION_STORE`)에서
    이미 소비된 것으로 확인되면(`is_consumed()`) 재사용이다. 소비되지
    않았으면 `evaluate()` 는 **`context.reserve_consumption(store,
    fingerprint)` 로 예약만 남기고** 충족 판정을 낸다 — 실제 `claim()`
    호출(commit)은 이 메서드가 하지 않는다. cycle 이 최종적으로 ALLOW
    로 끝날 때만 Runtime(`rein/engine/runtime.py`)이 그 예약을 실행한다
    (모듈 docstring "1회차 구현의 결함과 2단계 재설계" 절 — 사이클 C
    재리뷰 2회차 High 시정). 저장 프로토콜 자체를 확보하지 못하면
    (`None`) 소비 여부를 재확인할 수 없으므로 보수적으로 미충족이다.
    """

    @property
    def name(self):
        return REQUIREMENT_NAME

    def evaluate(self, context):
        """충족 여부(bool) — action·digest·producer·policy version·one-shot 결합.

        digest/action/version fact 가 확보되지 않으면(부재) 해당 축의
        재확인이 불가능하므로 보수적으로 미충족이다 — 확인 불가를
        충족으로 승격하지 않는다(review/security 와 동일 방향). fact
        해석 실패(`FactResolutionError`, malformed 타입)는 context
        계약대로 전파된다(판단 불능 ≠ 부재, spec §3.4) — registry 배선
        시 evaluator 가 failure_mode 로 분기한다.

        **무부수효과** (사이클 C 재리뷰 2회차 High 시정 — 모듈 docstring
        "2단계 재설계" 절): 외부 소비 저장소는 이 메서드 안에서 전혀
        바뀌지 않는다. 유효한 미소비 승인을 찾으면 `context.
        reserve_consumption(store, fingerprint)` 로 예약만 남긴다 —
        이 호출은 request-scoped `EvaluationContext` 내부 상태만
        바꾸고, cycle 밖으로는 아무 것도 새어나가지 않는다. 실제
        `store.claim()` 호출은 cycle 종료 후 최종 decision 이 ALLOW 일
        때만 Runtime 이 수행한다.
        """
        current_digest = context.fact(FACT_CHANGESET_DIGEST)
        if not current_digest:
            return False
        current_action = context.fact(FACT_ACTION_CURRENT)
        if current_action is not None and not isinstance(
            current_action, str
        ):
            raise FactResolutionError(
                "fact {!r} must be a str action identifier or None, got "
                "{!r} (type {})".format(
                    FACT_ACTION_CURRENT,
                    current_action,
                    type(current_action).__name__,
                )
            )
        if not current_action:
            return False
        current_version = context.fact(FACT_POLICY_VERSION)
        if not current_version:
            return False
        compatible_versions = context.fact(FACT_POLICY_COMPATIBLE_VERSIONS)
        if compatible_versions is None:
            compatible_versions = ()
        store = context.fact(FACT_APPROVAL_CONSUMPTION_STORE)
        if store is None:
            # 소비 저장 프로토콜 확인 불가 — 보수적 미충족 (모듈
            # docstring "설계 판단" 절: 확인 불가를 "아직 안 썼다"로
            # 낙관하지 않는다)
            return False
        _validate_consumption_store(store)
        for record in context.evidence_for(REQUIREMENT_NAME):
            if record.type != REQUIREMENT_NAME:
                continue
            if record.result != RESULT_APPROVED:
                continue
            if record.producer != PRODUCER_USER_APPROVED:
                # producer 축 (사이클 C 1회차 High 2) — 다른 등급의
                # 레코드가 이 bucket 에 섞여 있어도 충족 재료가 아니다
                continue
            if not subject_matches(record, current_digest):
                continue
            if (record.metadata or {}).get(
                METADATA_KEY_ACTION
            ) != current_action:
                continue
            if not policy_version_valid(
                record, current_version, compatible_versions
            ):
                continue
            fingerprint = evidence_fingerprint(record)
            if store.is_consumed(fingerprint):
                # 이미 소비된 승인 — one-shot 재사용 거부 (spec §3.6 §21)
                continue
            # 예약만 한다 — 실제 소비(claim)는 cycle 종료 후 최종
            # decision 이 ALLOW 일 때만 Runtime 이 commit 한다(모듈
            # docstring "2단계 재설계" 절). 같은 cycle 안에서 이
            # evaluate() 가 다시 호출돼도(다른 policy 가 같은 요구를
            # 재확인) is_consumed() 는 여전히 False 를 답하므로(외부
            # 상태가 아직 안 바뀌었다) 같은 fingerprint 가 다시 예약될
            # 뿐이다 — reserve_consumption 은 집합이라 멱등하다.
            context.reserve_consumption(store, fingerprint)
            return True
        return False


def register_user_approval(registry):
    """RequirementRegistry 에 user_approval 구현체를 명시 등록한다.

    등록은 이 함수 호출로만 일어난다 — import 부작용 등록 금지
    (spec §3.1 §32: Registry 는 명시적 코드 등록). 등록된 구현체를
    반환한다 (호출자가 동일 인스턴스를 재사용할 수 있게).
    """
    implementation = UserApprovalRequirement()
    registry.register(REQUIREMENT_NAME, implementation)
    return implementation
