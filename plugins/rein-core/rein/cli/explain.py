"""`rein explain` — 최근 decision 의 근거 재구성 (plan Task 4.7, spec §3.1).

spec §3.1 패키지 구조표 커버리지 항목(`cli-doctor-reports-config-policy-
storage-health-and-explain-shows-last-decision-basis`) 원문: "`rein
explain` 이 최근 decision 의 policy·missing_requirements·evidence 근거를
보여준다."

## "최근" 의 소스 — 설계 판단 (본 Task 범위에서 결정, 후속 확장 여지 명시)

이 Task(4.7) 시점의 rein v2 런타임은 **decision 을 영속화하지 않는다**
— `rein/cli/__init__.py::run_event` 는 매 호출이 stdin → stdout 1회성
왕복이고, decision 을 파일/DB 에 남기는 로직이 없다(발급되는 것은
evidence/ledger 뿐 — `platform/storage/local.py`, decision 자체가
아니다). 따라서 "가장 최근 decision" 을 조회할 영속 저장소가 아직
존재하지 않는다.

이 상황에서 두 선택지가 있었다:
(a) decision 저장소를 새로 설계·구현한다 — Task 4.7 의 scope(§3.1 cli/
    두 모듈)를 넘어서고, decision 저장 스키마·보존 정책은 아직 spec 이
    결정하지 않은 영역이다(개조 없이 만들면 후속 Task 가 다시 바꿔야
    할 위험).
(b) **이벤트를 인자로 받아 그 자리에서 재평가**해 근거를 보여준다 —
    이 방식은 이미 확립된 재구축 가능성 계약(spec §3.8, "Runtime
    State 삭제 전/후 동일 시나리오는 동일 decision")과 정합한다: 판단
    재료(policy·facts·evidence)는 항상 프로젝트 상태에서 재도출
    가능해야 한다는 원칙을 그대로 "가장 최근 decision 조회"에도
    적용한 것뿐이다.

(b) 를 택했다. "최근 기록 조회" (실제 영속 decision 로그를 시간순으로
찾아 보여주는 것)는 decision 저장이 설계·구현되는 시점(후속 Task)에
자연스럽게 확장할 수 있다 — 이 모듈의 `run_explain` 시그니처(이벤트
텍스트 1건 → 근거 dict)는 그 확장과 충돌하지 않는다(내부에서 "최근
이벤트를 어디서 가져오는가"만 바뀌면 됨).

## 이연 확정 (2026-08-11 사이클 C 리뷰 1회차 Medium 1)

decision 영속화·"최근 기록 조회" 로의 확장은 명시적으로 이연됐다 —
`trail/dod/dod-2026-08-11-v2-phase4.md` 의 "[이연 추적] explain 의 최근
decision 영속 조회" 항목 참조. 그 결정에 따라 이 모듈은 출력 JSON 에
재구성 방식임을 나타내는 명시 필드(`method`)를 항상 포함한다 — 호출자가
"이게 실제 원본 decision 인가, 방금 다시 계산한 것인가"를 필드만 보고
구분할 수 있어야 한다(사람이 `note` 문장을 읽어야만 알 수 있는 상태는
불충분하다는 리뷰 판정).

## 진단은 상태를 바꾸지 않는다 — commit 없는 평가 경로 (2026-08-11 사이클 C 재리뷰 4회차 Medium 2)

이 모듈은 원래 `rein.cli.run_event`(= 사실상 `rein.engine.runtime.
evaluate`)를 그대로 호출해 재평가했다. 그런데 `runtime.evaluate` 는
"cycle 이 ALLOW 로 끝나면 예약된 one-shot 소비(예: `user_approval`)를
실제로 commit 한다"는 부수효과를 갖는다(plan Task 4.5 — 승인 capability
가 `EvaluationContext.reserve_consumption` 으로 예약을 남기면,
`runtime._commit_pending_consumptions` 가 cycle 종료 후 그 예약을
`store.claim()` 으로 실행한다, `rein/engine/runtime.py` 모듈 docstring
참조). `rein/cli/__init__.py::run_event` 가 오늘은 `registry`/
`evidence_source` 를 아직 배선하지 않아 이 경로가 실제로 소비를 만들 수
없지만("등록 구현체 없음 → 단순 존재 검사 fallback"), **그 배선이 나중에
추가되는 순간** — 즉 hook 이벤트 평가 경로에 승인 capability 가
연결되는 시점 — `explain` 을 부르는 것만으로 실제 사용자 승인이
소모되는 사고가 발생한다. "진단 명령이 상태를 바꾼다"는 이 저장소가
반복적으로 경계해 온 종류의 결함이다(doctor 의 read-only 계약과 동일
정신, `rein/cli/doctor.py` 참조).

**수정**: 이 모듈은 `run_event`/`runtime.evaluate` 를 전혀 호출하지
않는다. 대신 `rein.engine.evaluator.evaluate()` 를 **직접** 호출한다 —
이 함수는 순수 `Decision` 을 반환할 뿐, 예약된 소비를 commit 하는 단계
(`runtime._commit_pending_consumptions`)가 애초에 존재하지 않는 함수다.
이 구조적 선택이 옵션 (b, "runtime 에 dry-run 플래그 추가")보다 나은
이유는 추가 표면이 없기 때문이다 — `runtime.evaluate` 에 플래그를
더하면 그 플래그를 빠뜨리는 새 호출부가 생길 때마다 같은 사고가 재발할
여지가 남지만, 이 모듈이 애초에 commit 을 아는 함수를 호출하지 않으면
그 여지 자체가 없다.

안전성이 구조적으로 보장되는 이유(레지스트리를 주입해도 마찬가지):
`context.reserve_consumption()` 은 이 함수 호출 동안 새로 만들어지는
`EvaluationContext` 인스턴스(1 인스턴스 = 1 Evaluation Cycle, `rein/
engine/context.py` 클래스 docstring)에만 쌓인다. `run_explain()` 이
반환하는 순간 이 인스턴스는 어떤 참조도 남기지 않고 버려지므로, 예약이
있었더라도 commit 될 기회 자체가 없다 — `registry`/`evidence_source`
를 나중에 이 함수에 주입해 승인 capability 를 실제로 태워도(테스트
계약, 아래 `run_explain` 참조) 결과는 같다.

`registry`/`evidence_source` 파라미터는 오늘 `bin/rein` 호출부
(`_run_explain`)가 쓰지 않는다(둘 다 기본 `None` — `run_event` 의 오늘
배선과 동일하게 존재 검사 fallback). 이 두 파라미터를 추가한 목적은
전적으로 위 안전성 계약을 직접 테스트하기 위함이다: 소비 저장 프로토콜을
실제로 주입한 뒤에도 `claim()` 이 0 회 호출됨을 고정한다(`tests/cli/
test_doctor_explain.py`).

## authority 배선 — project_root (Phase 6 Task 6.1 재작업, 부모 지시
2026-08-12)

`run_explain()` 도 `rein.cli.ENV_PROJECT_ROOT`(`REIN_PROJECT_ROOT`)
환경변수를 `run_event()` 와 동일한 방식으로 읽어 `evaluator.evaluate(...,
project_root=...)` 에 그대로 넘긴다 — 이전에는 이 인자를 아예 넘기지
않아 `explain` 의 "왜 통과/차단했는지" 설명에 authority 배선이 있었는지
(전환된 capability 가 legacy marker 로 인정됐는지)가 드러나지 않았다.
값이 없으면(미설정·빈 문자열) `None` 을 그대로 넘긴다 — `run_event()`
와 동일하게 cwd 로 추정하지 않는다. `rein/cli/__init__.py` 의
`ENV_PROJECT_ROOT` 상수를 그대로 재사용한다(매직 문자열 복제 금지, 이
모듈이 이미 `ENV_POLICY_DIR` 에 대해 지키는 원칙과 동일 — fact 구성
자체는 아래 "registry/fact 배선" 절이 설명하는 `_build_facts()` 공유로
더 넓게 확장됐다).

새 인자를 추가하지 않는다 — `run_event()` 와 대칭을 유지하기 위해
`project_root` 는 함수 파라미터가 아니라 이 함수 내부에서 환경변수로
직접 읽는다(`registry`/`evidence_source`/`extra_facts` 와 달리, 이
값은 "재평가 재료 주입"이 아니라 "이벤트가 실제로 평가됐을 환경"의
일부이므로 호출자가 인자로 바꿔치기할 이유가 없다).

## registry/fact 배선 — 프로덕션 기본값과의 정합 (Phase 6 Task 6.1 재작업,
독립 리뷰어 Medium 4 지적 수정, 2026-08-12)

위 "authority 배선" 절 작성 이후에도 이 함수는 여전히 `registry=None`
을 기본값으로 유지하고 있었다 — `run_event()` 는 이미 `_build_registry()`
로 5 capability 를 전부 등록한 registry 를 만들어 쓰는데, `run_explain()`
은 그 기본값을 그대로 따라가지 않고 존재 검사 fallback 을 계속
썼다(`rein/cli/__init__.py` `_build_registry()` 자체가 이 함수보다
나중에 추가됐다 — 이 함수의 "기본값 정합" 문서가 갱신되지 않은 채
남아 있었다). 독립 리뷰어가 실제로 재현했다: 동일한 policy·활성
작업·환경변수에서 `run_event` 는 BLOCK, `run_explain` 은 ALLOW(legacy
출처) — "basis 3필드는 항상 같다"는 위 계약이 실제로는 거짓이었다.

**수리**: `registry` 파라미터의 기본값을 **sentinel**
(`_REGISTRY_NOT_PROVIDED`)로 바꾼다 — `rein.engine.evaluator` 의
`PROJECT_ROOT_NOT_PROVIDED` 와 같은 패턴이다: "호출자가 인자를 아예
생략함"과 "호출자가 명시적으로 `None` 을 넘김"을 구분해야 하기
때문이다(테스트, `tests/cli/test_doctor_explain.py` 의 승인 capability
테스트가 명시적으로 자기만의 `RequirementRegistry` 인스턴스를 주입한다
— 그 경로는 그대로 보존돼야 한다). 인자가 생략되면(sentinel 그대로)
`rein.cli._build_registry()` 를 호출해 `run_event()` 와 **동일한**
프로덕션 기본 registry 를 쓴다. registry 구성 로직은 `rein.cli` 모듈
한 곳에만 존재한다 — 이 함수는 그 함수를 import 해 호출할 뿐 복제하지
않는다.

`facts` 구성도 같은 이유로 `rein.cli._build_facts()` 로 옮겼다 — registry
만 맞추고 fact 계산 경로가 갈라지면(이 파일이 여전히 `tool`/`git.branch`
2개만 만들고 `run_event()` 는 `command.type`/`changeset.digest`/
`changeset.sensitive_digest` 까지 만드는 상태), 같은 종류의 "basis 가
다르다" 결함이 fact 축에서 재발한다(`rein/cli/__init__.py` 모듈
docstring "fact 배선" 절). `extra_facts` 는 여전히 이 함수 고유 —
`_build_facts()` 결과 위에 override 로 얹는다(기존 테스트 계약 보존).

## evidence_source 배선 — run_event 와의 parity 확장 (Phase 6 최종 조립
워커)

위 registry/facts 공유가 해소한 것과 같은 부류의 결함이
`evidence_source` 축에도 잠재해 있었다 — `run_event()` 는 이제
`rein.cli._build_evidence_source(project_root)` 로 실 ledger 를 연결
하지만(`rein/cli/__init__.py` 모듈 docstring "evidence_source 연결"
절), 이 함수의 `evidence_source` 기본값이 계속 `None`(=미배선)이면
두 함수는 evidence 유무에 따라 다시 다른 answer 를 낼 수 있다. 그래서
`evidence_source` 도 registry 와 동일한 sentinel 패턴
(`_EVIDENCE_SOURCE_NOT_PROVIDED`)으로 바꿨다 — 생략되면
`_build_evidence_source()` 로 `run_event()` 와 동일하게 구성하고,
명시적으로 `None` 을 넘기면(기존 테스트가 자기 test double 을 주입하는
경로) 그 값을 그대로 쓴다.

(구 절 — Phase 6 4회차 독립 리뷰 Medium 1 로 무효화됨) `_build_facts()`
가 `approval.consumption_store` fact 로 sqlite 연결을 열 수 있었던 것은
이제 과거형이다 — 아래 "fact_resolvers 배선" 절 참조. 이 함수가 여는
연결을 닫는 책임 자체는 그대로 있지만, 여는 지점이
`_build_fact_resolvers()` 로 옮겨갔다.

## fact_resolvers 배선 — lazy parity 전체 확장 (Phase 6 3회차 재리뷰
High 1 + 4회차 독립 리뷰 Medium 1/2)

`_build_facts()` 는 이제 `changeset.digest`/`changeset.sensitive_digest`/
`changeset.tag`/`task.active`/`changeset.task_relevant`/`action.current`/
`approval.consumption_store` 7개 전부를 값으로 계산하지 않는다(`rein/
cli/__init__.py` 모듈 docstring "비용 게이팅" 절) — `rein.cli.
_build_fact_resolvers(event, project_root, read_only=..., resolved_out=
..., opened_approval_store=...)` 가 그 7개의 lazy resolver 를 구성하고,
`run_event()` 와 이 함수 둘 다 그것을 `EvaluationContext(fact_resolvers=
...)` 에 넘긴다. 위 "registry/fact 배선" 절이 이미 확립한 parity 원칙
(공유 헬퍼를 그대로 재사용, 복제 금지)을 그대로 이 축에도 적용한
것뿐이다 — 별도의 새 sentinel 은 필요 없다(`fact_resolvers` 는 매 호출
새로 구성되는 값이라 "생략과 명시적 None 을 구분" 하는 문제 자체가
없다, registry/evidence_source 와 다른 점).

이 함수는 `_build_fact_resolvers()` 에 `read_only=True` 를 넘긴다(구
`_build_facts(..., read_only=True)` 호출을 대체) — 그 인자가 이제
승인 소비 저장소를 여는 유일한 지점(`_open_approval_consumption_store`)
에 직접 도달한다. `resolved_out`(빈 dict)/`opened_approval_store`
(빈 list)도 이 함수가 만들어 넘긴다: 전자는 실제로 조회된 lazy fact
값을 돌려받아 `facts` 응답 키(응답 투명성 계약, `rein/cli/__init__.py`
모듈 docstring "응답 투명성" 절)를 채우고, 후자는 실제로 열린 승인
소비 저장소만 정확히 1회 `close()` 하기 위함이다(`_build_fact_
resolvers()` 모듈 docstring "자원 정리" 절 — "열리지 않았으면 닫을
것도 없고, 열렸으면 반드시 닫혀야 한다"). 호출자가 `extra_facts` 로
`approval.consumption_store` 키를 직접 override 했으면(테스트 전용
경로) `EvaluationContext.fact()` 의 "스냅샷이 resolver 보다 우선한다"
계약에 따라 이 함수의 resolver 는 애초에 조회되지 않는다 — `opened_
approval_store` 는 비어 있고, 이 함수는 호출자가 주입한 객체를 닫지
않는다(기존 계약 보존).

## Medium 2 — `_open_approval_consumption_store` 의 오류 분류 정정
(Phase 6 4회차 독립 리뷰)

`_open_approval_consumption_store`(`rein/cli/__init__.py`)가 `os.lstat`
호출을 `except OSError:` 로 너무 넓게 받아 권한 오류 등도 "파일 없음"
으로 흡수하던 결함이 이 함수(`read_only=True` 호출부)와 `run_event()`
(`read_only=False` 호출부)의 판정을 갈라놓았다 — 그 함수 자체의
docstring 참조. 두 호출부가 같은 함수를 거치므로 그 지점의 수리만으로
양쪽이 다시 같은 판정을 낸다(이 파일은 별도 수정이 필요 없다).
"""
import json
import os

from rein.cli import (
    ENV_POLICY_DIR,
    ENV_PROJECT_ROOT,
    _build_evidence_source,
    _build_fact_resolvers,
    _build_facts,
    _build_registry,
    _serializable_facts,
)

# 재구성 방식 식별자 — decision 영속화가 도입되면 그 경로는 다른 값(예:
# "ledger-lookup")을 쓰게 될 것이므로, 지금부터 고정 문자열 상수로
# 노출해 호출자가 이 값으로 두 경로를 구분할 수 있게 한다.
METHOD_RE_EVALUATION = "re-evaluation"

_RECONSTRUCTION_NOTE = (
    "이 근거는 저장된 decision 기록이 아니라, 현재 프로젝트 상태를 "
    "기준으로 전달된 이벤트를 지금 다시 평가해 재구성한 것입니다 "
    "(런타임이 decision 을 영속화하지 않음 — 이 모듈 docstring 참조). "
    "이벤트가 최초로 평가됐던 시점 이후 policy·evidence 상태가 바뀌었다면, "
    "그 시점의 실제 decision 과 이 재구성 결과가 다를 수 있습니다. "
    "decision 영속화·'최근 기록 조회' 로의 확장은 이연되었습니다 — "
    "trail/dod 의 '[이연 추적] explain 의 최근 decision 영속 조회' "
    "항목 참조. 이 재평가는 상태를 바꾸지 않습니다 — one-shot 소비(예: "
    "승인)를 commit 하는 경로를 의도적으로 쓰지 않습니다."
)


# registry 인자의 "생략됨" sentinel — `rein.engine.evaluator` 의
# `PROJECT_ROOT_NOT_PROVIDED` 와 동일한 패턴("생략"과 "명시적으로 None
# 을 넘김"을 구분해야 하는 이유는 위 모듈 docstring "registry/fact 배선"
# 절 참조).
_REGISTRY_NOT_PROVIDED = object()

# evidence_source 인자의 "생략됨" sentinel — 최종 조립 워커 추가
# (`rein.cli.ENV_PROJECT_ROOT` / "registry/fact 배선" 절과 동일 패턴).
# `run_event()` 가 이제 `_build_evidence_source(project_root)` 로 실
# ledger 를 연결하므로(`rein.cli` 모듈 docstring "evidence_source 연결"
# 절), 이 함수도 인자가 생략되면 같은 방식으로 구성해야 "basis 3필드는
# run_event 와 항상 같다" 계약이 evidence_source 축에서도 성립한다.
# 명시적으로 `evidence_source=None` 을 넘기면(기존 테스트 계약,
# `tests/cli/test_doctor_explain.py` 의 승인 capability 테스트가 자기
# evidence_source test double 을 직접 주입하는 경로) 여전히 그 값을
# 그대로 쓴다 — "생략"과 "명시적 None" 을 구분하는 이유는 registry 와
# 동일하다.
_EVIDENCE_SOURCE_NOT_PROVIDED = object()


def run_explain(
    raw_text,
    registry=_REGISTRY_NOT_PROVIDED,
    evidence_source=_EVIDENCE_SOURCE_NOT_PROVIDED,
    extra_facts=None,
):
    """이벤트 JSON 1건을 재평가해 decision 근거를 재구성한다 — commit 없음.

    raw_text 는 `rein.cli.run_event` 와 동일한 입력 계약(Claude hook
    payload JSON 텍스트) — 파싱(`json.loads` + `adapter.normalize_event`)
    과 policy 로드(`load_policies`)는 그 함수가 쓰는 것과 동일한 함수를
    그대로 재사용한다(재구현 금지). 다만 평가 단계에서
    `rein.engine.runtime.evaluate`(= `run_event` 가 호출하는 함수) 대신
    `rein.engine.evaluator.evaluate()` 를 **직접** 호출한다 — 모듈
    docstring "진단은 상태를 바꾸지 않는다" 절 참조. `rein/engine/
    runtime.py` 는 이 Task 의 선언 scope 밖이라 수정하지 않는다 —
    다만 registry/fact **구성** 로직은 `rein.cli` 의 공유 헬퍼
    (`_build_registry`/`_build_facts`)를 그대로 호출한다(모듈 docstring
    "registry/fact 배선" 절 — 중복 복제 금지, `ENV_POLICY_DIR` 상수도
    `rein.cli` 것을 그대로 참조해 매직 문자열 복제를 피한다).

    `registry` 생략 시(기본값, sentinel) `rein.cli._build_registry()` 로
    `run_event()` 와 동일한 프로덕션 registry(5 capability 전부 등록)를
    쓴다 — 명시적으로 `registry=None` 을 넘기면(구 동작) 여전히 등록
    구현체 없는 단순 존재 검사로 평가한다(테스트가 이 구분을 쓴다,
    `tests/cli/test_doctor_explain.py`). `evidence_source`/`extra_facts`
    는 기본 `None`/생략 — 오늘의 `bin/rein` 호출부는 인자를 주지 않으므로
    `run_event` 와 동일하게 `evidence_source` 는 비어 있다(모듈
    docstring "evidence_source 를 의도적으로 배선하지 않는다" 절,
    `rein/cli/__init__.py` 참조 — 두 함수가 같은 이유로 같은 기본값을
    공유한다). 세 인자는 테스트가 registry/evidence_source 를 직접
    주입해 "레지스트리가 배선된 뒤에도 commit 이 없다"를 검증할 수
    있도록 존재한다.

    반환 dict 의 `basis` 하위 3필드(`policy`/`missing_requirements`/
    `evidence_refs`)는 같은 입력을 `run_event` 로 평가한 decision
    레코드의 동명 필드와 **항상 값이 같다**(오늘의 기본 배선 기준 —
    두 함수 모두 `_build_registry()`/`_build_facts()` 를 공유하고,
    `evidence_source` 는 둘 다 미배선, `project_root` 도 같은
    환경변수(`ENV_PROJECT_ROOT`)에서 동일하게 읽으므로 계산 경로가
    동일하다. 테스트 계약: 대표 BLOCK 이벤트에서 이 일치를 고정한다).
    `reason`(및 `decision["reason"]`)은 이 일치 계약에 포함되지
    않는다 — 둘 다 같은 project_root 를 읽으므로 실제로는 값도 같지만,
    두 함수가 서로 다른 시점에 서로 다른 이벤트로 호출될 수 있는 이상
    "같은 문자열이어야 한다"를 계약으로 고정하지 않는다(계약은 `basis`
    3필드로 이미 충분히 좁다).

    `method` 필드는 항상 `METHOD_RE_EVALUATION`("re-evaluation") 이다 —
    이 CLI 가 아는 유일한 근거 재구성 방식이 재평가뿐이기 때문이다
    (모듈 docstring "이연 확정" 절). decision 영속화가 도입되기 전까지는
    다른 값이 나올 수 없다 — 값 자체가 테스트 계약이다.

    ValueError(잘못된 입력 JSON·미지원 이벤트·policy 파싱 실패)는 그대로
    전파한다 — 이 CLI 는 진단 도구이므로 조용히 흡수하지 않는다
    (`bin/rein` 모듈 docstring의 "doctor/explain 은 fail-closed 매핑
    대상이 아니다" 방향과 동일). fact 계산(`_build_facts()`)이 던지는
    예외(예: `ContentSizeExceededError`)도 같은 이유로 그대로 전파한다.
    """
    # 함수 내 lazy import — 인터프리터 기동 비용 최소화 관례 유지
    # (spec §3.9, `rein/cli/__init__.py::run_event` 와 동일 원칙).
    from rein.engine import evaluator
    from rein.engine.context import EvaluationContext
    from rein.kernel.policy import load_policies
    from rein.platform.claude import adapter

    payload = json.loads(raw_text)
    event = adapter.normalize_event(payload)

    policy_dir = os.environ.get(ENV_POLICY_DIR)
    policies = load_policies(policy_dir)

    # run_event() 와 동일한 env 관례 — cwd 로 추정하지 않는다(모듈
    # docstring "authority 배선" 절). fact 구성보다 먼저 계산한다 —
    # `_build_facts()` 가 changeset digest 게이팅에 project_root 를
    # 필요로 한다(`rein/cli/__init__.py` 모듈 docstring "fact 배선" 절).
    project_root = os.environ.get(ENV_PROJECT_ROOT) or None

    # Medium 1 수리(Phase 6 4회차 독립 리뷰) 이후 `_build_facts()` 는
    # 승인 소비 저장소를 전혀 열지 않는다 — `read_only=True` 는 이제
    # `_build_fact_resolvers()` 에 직접 넘긴다(아래). Medium E 의 취지
    # (DB 파일이 아직 없을 때만 실제 생성을 무해한 대역으로 대체 —
    # `_open_approval_consumption_store`/`_ReadOnlyEmptyApprovalConsumption
    # Store` docstring 참조)는 그대로 유지된다 — 여는 지점이 바뀌었을
    # 뿐 read_only 의미는 동일하다.
    facts = _build_facts(
        event,
        project_root,
        policies=policies,
        policy_dir=policy_dir,
    )
    # changeset 해시 3종 + task.active/changeset.task_relevant/
    # action.current/approval.consumption_store 7개는 `_build_facts()`
    # 가 더 이상 값으로 채우지 않는다 — `run_event()` 와 동일하게
    # `_build_fact_resolvers()` 로 lazy resolver 를 구성해
    # `EvaluationContext` 에 넘긴다(Phase 6 3회차 재리뷰 High 1 + 4회차
    # 독립 리뷰 Medium 1). 이 공유가 없으면 "basis 3필드는 run_event 와
    # 항상 같다" 계약(모듈 docstring)이 다시 깨진다 — `run_event()` 는
    # 실제로 그 fact 를 조회해 판정하는데 `run_explain()` 은 영원히
    # 부재로 보는 상황이 생기기 때문이다.
    #
    # `resolved_out`/`opened_approval_store` 는 `run_event()` 와 동일한
    # 목적 — 실제로 조회된 lazy fact 를 응답(`facts` 키)에 반영하고,
    # 실제로 열린 승인 소비 저장소만 정확히 1회 닫기 위함이다
    # (`_build_fact_resolvers()` 모듈 docstring "응답 투명성"/"자원 정리"
    # 절).
    resolved_out = {}
    opened_approval_store = []
    fact_resolvers = _build_fact_resolvers(
        event,
        project_root,
        read_only=True,
        resolved_out=resolved_out,
        opened_approval_store=opened_approval_store,
    )
    # Low F 수리(Phase 6 독립 리뷰어 지적, 부모 판정 타당함) — 이 지점
    # 이후부터 함수의 나머지 전체(registry/evidence_source 구성, 평가)
    # 를 하나의 try/finally 로 감싼다. registry/evidence_source 구성이
    # 예외를 던져도(context 생성·evaluate() 전이라 resolver 가 아직
    # 한 번도 조회되지 않은 시점일 수 있다) `opened_approval_store` 를
    # 조건부로 확인하는 finally 가 항상 실행된다 — 실제로 열렸으면
    # 닫고, 열리지 않았으면 아무 것도 하지 않는다.
    try:
        if extra_facts:
            facts.update(extra_facts)

        if registry is _REGISTRY_NOT_PROVIDED:
            registry = _build_registry()

        # evidence_source 생략(sentinel) 시 run_event() 와 동일한 방식으로
        # 구성한다 — `rein.cli` 모듈 docstring "evidence_source 연결" 절,
        # 이 파일 위 sentinel 정의 참조. 명시적으로 `None` 을 넘기면(기존
        # 테스트 계약) 그 값을 그대로 쓴다.
        if evidence_source is _EVIDENCE_SOURCE_NOT_PROVIDED:
            evidence_source = _build_evidence_source(project_root)

        context = EvaluationContext(
            facts=facts,
            evidence_source=evidence_source,
            fact_resolvers=fact_resolvers,
        )
        # evaluator.evaluate() 는 순수 Decision 을 반환한다 — commit
        # 단계(runtime._commit_pending_consumptions)가 없는 함수이므로,
        # context 에 예약된 소비가 있어도 이 함수 호출로는 어떤 store 도
        # 바뀌지 않는다(모듈 docstring "진단은 상태를 바꾸지 않는다" 절).
        decision = evaluator.evaluate(
            event["name"],
            context,
            policies,
            registry=registry,
            project_root=project_root,
        ).to_dict()
    finally:
        # 승인 소비 저장소는 이제 lazy resolver 가 실제로 조회될 때만
        # 열린다 — `opened_approval_store` 가 비어 있으면(never
        # queried) 닫을 것도 없다(`_build_fact_resolvers()` 모듈
        # docstring "자원 정리" 절 — "열리지 않았으면 닫을 것도 없고,
        # 열렸으면 반드시 닫혀야 한다" 경계, `tests/cli/
        # test_build_facts_resource_cleanup.py` 고정).
        if opened_approval_store:
            opened_approval_store[0].close()

    merged_facts = dict(facts)
    merged_facts.update(resolved_out)
    return {
        "decision": decision["decision"],
        "reason": decision["reason"],
        "basis": {
            "policy": decision["policy"],
            "missing_requirements": decision["missing_requirements"],
            "evidence_refs": decision["evidence_refs"],
        },
        "facts": _serializable_facts(merged_facts),
        "method": METHOD_RE_EVALUATION,
        "note": _RECONSTRUCTION_NOTE,
    }
