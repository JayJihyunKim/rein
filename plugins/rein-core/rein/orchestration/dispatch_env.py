"""dispatch_env — 중첩 디스패치 능력 감지·강등 상태 기계 (plan Task 5.4, spec §5.1 §4.5).

spec §5.1 확정 결정 원문 인용
(`docs/specs/2026-08-07-rein-v2-governance-orchestration.md` §5.1):
    "감지 시점 = lazy: 세션 시작이 아니라 첫 Orchestration 진입 시 감지한다
    (세션 시작 hot-path 에 비용 추가 금지 — §3.9 정합). 결과는 세션 스코프
    캐시.
    관측 우선 원칙: 사전 감지 결과와 무관하게, 실제 중첩 디스패치 실패가
    관측되면 즉시 메인 세션 직접 디스패치로 강등한다 — 사전 감지는
    최적화, 런타임 강등이 최종 안전망.
    강등 가시성 = 명시: 강등 발생 시 사용자에게 평문 1줄 통지("병렬 조율을
    이 환경에서 지원하는 방식으로 바꿔 진행합니다" 류) + tracker 에
    `degraded` 사유 기록. silent 강등 금지."

spec §4.5 실패 처리 원문 인용:
    "Orchestration failure 로 일반 개발 작업 전체를 BLOCK 하지 않는다 —
    `병렬 실패 → 단일 실행 → Governance 는 계속 적용`. 중첩 디스패치 불가
    감지 → 메인 세션 직접 디스패치 강등 (§2.5 조건 1) 도 동일 계열."

SPIKE-3 채택 신호 (`docs/reports/v2-spike3-nested-dispatch.md`, Task 5.0,
2026-08-11 darwin/Claude Code 2.1.227 실측): 후보 3안(버전 문자열 파싱 /
환경-설정 introspection / 무해한 1회 프로브) 중 거짓 양성 0 이 두 위치
(가능/불가) 실측 모두에서 확인된 신호는 (c) 프로브뿐이다 — Orchestrator
서브에이전트가 no-op 워커 1개를 실제로 중첩 디스패치해 성공을 관측한다.
불가 방향은 툴셋에 Agent 도구 자체가 없어 프로브가 디스패치 시도 없이
~0ms 로 단락하고, 가능 방향 확인(실제 depth-3 중첩 왕복)은 1회성 실측
~10.6s 였다 — 세 후보 중 가장 비싸다. 이 비용은 본 모듈의 lazy + 세션
스코프 캐시 설계로 완화된다(SPIKE-3 리포트 §6 "비용 완화(Task 5.4 연계)").

## Python 은 에이전트를 스폰하지 않는다 (설계 제약, spec §4.1)

이 모듈은 순수한 상태 기계다 — 프로브 실행(실제 중첩 디스패치 시도) 자체는
Prompt 레이어(Orchestrator 자신의 Agent 도구 호출)에서 일어나고, 그 결과만
이 모듈로 "보고"된다. `detect()` 가 받는 `probe` 인자는 인자 없이 호출하면
이미 결정된 `bool` 결과(`True`=capable/`False`=incapable)를 반환하는
콜러블이다 — 이 콜러블 자체가 에이전트를 스폰하는 것이 아니라, Prompt
레이어가 이미 수행한 프로브의 결과를 이 모듈에 전달하는 통로일 뿐이다.
호출자가 그 결과를 어떻게 얻었는지(SPIKE-3 프로브를 언제·어떻게
실행했는지)는 이 모듈의 관심사가 아니다. 이 파일은 어떤 형태로도 Agent
도구를 호출하지 않으며, `work_unit`/`work_graph`/`validator`/`tracker`(병렬
형제 모듈들, Task 5.1~5.3) 도 import 하지 않는다 — 강등 사유는 호출자가
주입하는 `recorder` 콜백으로만 흘러나간다(생성자 `recorder=` 인자, 단일
dict 인자를 받는 콜러블이면 충분한 duck-typed 프로토콜). 실제 프로덕션
배선에서는 Runtime/Orchestrator 가 이 콜백을 tracker 의 기록 함수에
연결하지만, 그 연결은 이 모듈 밖의 책임이다.

## 상태 3종 + 세션 캐시

`STATE_UNKNOWN` → (`detect()` 또는 `report_dispatch_failure()`) →
`STATE_CAPABLE` 또는 `STATE_INCAPABLE`. `detect()` 는 이미 `UNKNOWN` 이
아닌 세션에서는 `probe` 를 다시 부르지 않고 캐시된 state 를 즉시 반환한다
— "첫 Orchestration 진입 시 1회" 계약(spec §5.1)의 실측 축은
`probe_consultations` 프로퍼티로 고정한다(같은 세션 내 반복 `detect()`
호출로는 이 값이 늘지 않는다).

## 관측 우선 — `report_dispatch_failure()` 는 사전 상태를 덮어쓴다

`state` 가 이미 `CAPABLE` 이어도(사전 프로브가 낙관적으로 틀렸거나, 이후
환경이 바뀐 경우), 실제 중첩 디스패치 실패가 관측되면 이 메서드 호출
한 번으로 즉시 `INCAPABLE` 로 전이한다 — 사전 감지는 최적화일 뿐 최종
안전망이 아니다(spec §5.1 "관측 우선 원칙"). `detect()` 를 아직 호출하지
않은(`UNKNOWN`) 세션에서도 동일하게 즉시 반영된다. 한 번 이렇게
강등되면 이 인스턴스는 스스로 다시 `CAPABLE` 로 승격하지 않는다(같은
세션 안에서 재시도해 안전을 재검증하는 로직은 이 모듈의 범위가 아니다 —
새 세션은 새 `DispatchEnvironment` 인스턴스로 시작한다).

## 강등 가시성 — 통지 + 기록은 항상 함께 일어난다

`mode` 가 `MODE_SINGLE_WORKER` 로 바뀌는 두 경로(`detect()` 가 불가를
확인 / `report_dispatch_failure()`) 모두 같은 사설 헬퍼 `_degrade()` 를
거친다 — 강등이 일어나는데 `notice`(평문 1줄 통지)도 안 남고
`recorder`(tracker 로 흘러가는 사유 기록)도 안 불리는 경로는 이 모듈 안에
없다(silent 강등 금지, spec §5.1). `notice` 는 사유(reason)별 고정
템플릿에서 선택되는 사용자 대면 문구다 — 예외 텍스트 등 내부 디테일은
담지 않는다(사용자에게는 "왜 바뀌었는지"만 평문으로, 감사용 상세는
`recorder` 가 받는 record 의 `detail` 필드로 분리한다).

## 일반 작업 BLOCK 금지 (spec §4.5)

이 모듈은 kernel `Decision` 어휘(`rein.kernel.decision`)를 참조하지
않는다 — ALLOW/BLOCK/ASK_USER 같은 governance 판정을 만들지도, 소비하지도
않는다. `detect()`/`report_dispatch_failure()` 어느 경로도 강등 자체를
이유로 예외를 던지지 않는다(예외는 오직 `probe`/`recorder` 가 애초에
계약(콜러블/올바른 반환 타입)을 어긴 경우에만 발생하는 호출자 버그
신호다). Orchestration 강등은 항상 `mode` 값의 조용한 전환일 뿐, 상위
governance 평가나 일반 작업을 막는 신호를 만들지 않는다 — "병렬 실패 →
단일 실행 → Governance 는 계속 적용"(spec §4.5)이라는 계약을 이 모듈은
"애초에 BLOCK 을 만들 수 있는 어휘 자체를 갖지 않는다"는 방식으로
지킨다.
"""

# ---------------------------------------------------------------------------
# 상태 3종 (닫힌 어휘)
# ---------------------------------------------------------------------------

STATE_UNKNOWN = "unknown"
STATE_CAPABLE = "capable"
STATE_INCAPABLE = "incapable"
STATES = (STATE_UNKNOWN, STATE_CAPABLE, STATE_INCAPABLE)

# ---------------------------------------------------------------------------
# 디스패치 모드 — state 로부터 유도되는 2종 (닫힌 어휘). governance
# Decision(ALLOW/BLOCK/ASK_USER) 과는 다른 지붕의 어휘다 — 이 모듈 docstring
# "일반 작업 BLOCK 금지" 절 참조.
# ---------------------------------------------------------------------------

MODE_ORCHESTRATED = "orchestrated"
MODE_SINGLE_WORKER = "single_worker"
MODES = (MODE_ORCHESTRATED, MODE_SINGLE_WORKER)

# ---------------------------------------------------------------------------
# 강등 사유 (닫힌 어휘) — SPIKE-3 채택 신호(프로브)에 대응하는 사유 +
# 관측 우선 원칙에 대응하는 사유.
# ---------------------------------------------------------------------------

REASON_PROBE_INCAPABLE = "probe_incapable"
REASON_OBSERVED_FAILURE = "observed_dispatch_failure"
REASONS = (REASON_PROBE_INCAPABLE, REASON_OBSERVED_FAILURE)

# 강등 가시성 — 사유별 고정 평문 1줄 통지 템플릿(spec §5.1 예시 문구
# 계열). 원본 예외/실패 텍스트는 담지 않는다(모듈 docstring 참조) —
# 감사용 상세는 recorder 가 받는 record 의 `detail` 필드로 분리한다.
_NOTICE_BY_REASON = {
    REASON_PROBE_INCAPABLE: (
        "이 환경은 중첩 디스패치(병렬 Orchestration)를 지원하지 않아, "
        "단일 워커 직접 디스패치 방식으로 바꿔 진행합니다."
    ),
    REASON_OBSERVED_FAILURE: (
        "중첩 디스패치 실행 중 실패가 관측되어, 단일 워커 직접 디스패치 "
        "방식으로 전환해 진행합니다."
    ),
}


class DispatchEnvError(ValueError):
    """dispatch_env 계약 위반 — 호출자 입력이 잘못된 형태."""


def _require_callable(value, label):
    if not callable(value):
        raise DispatchEnvError(
            "{} must be a callable, got {!r} (type {})".format(
                label, value, type(value).__name__
            )
        )
    return value


def _require_bool(value, label):
    # 명시적으로 bool 만 허용한다 — 0/1/None/"true" 등 truthy/falsy 값의
    # 암묵적 강제 변환은 "가능/불가능" 판정처럼 안전이 걸린 이진 신호에서는
    # 조용한 오판정의 함정이 된다(이 저장소의 "조용한 보정 금지" 규율과
    # 동일 방향 — `rein/engine/loop_controller.py` 의 `_validate_positive_int`
    # 가 반대 방향(정수 기대 위치에서 bool 을 명시 거부)으로 같은 원칙을
    # 적용하는 것과 대칭).
    if not isinstance(value, bool):
        raise DispatchEnvError(
            "{} must return a bool (True=capable, False=incapable), got "
            "{!r} (type {})".format(label, value, type(value).__name__)
        )
    return value


class DispatchEnvironment:
    """세션 스코프 중첩 디스패치 능력 상태 기계 (spec §5.1, §4.5).

    한 인스턴스 = 한 세션의 감지 결과다(모듈 전역 상태 없음 — 서로 다른
    인스턴스는 상태를 공유하지 않는다, `rein/engine/loop_controller.py`
    `LoopController` 의 "카운터 단일성"과 동일한 인스턴스-스코프 원칙).
    """

    __slots__ = (
        "_recorder",
        "_state",
        "_probe_consultations",
        "_notice",
        "_degraded_reason",
    )

    def __init__(self, recorder=None):
        if recorder is not None:
            _require_callable(recorder, "recorder")
        self._recorder = recorder
        self._state = STATE_UNKNOWN
        self._probe_consultations = 0
        self._notice = None
        self._degraded_reason = None

    # -- 조회 전용 프로퍼티 --------------------------------------------------

    @property
    def state(self):
        """`STATES` 원소 하나 — 현재 감지 상태."""
        return self._state

    @property
    def mode(self):
        """현재 상태에서 유도되는 디스패치 모드 — governance 판정이 아니다.

        `STATE_CAPABLE` 만 `MODE_ORCHESTRATED` 다. `STATE_UNKNOWN`(아직
        감지 전)과 `STATE_INCAPABLE`(불가 확인 또는 강등)은 모두 안전한
        기본값 `MODE_SINGLE_WORKER` 로 수렴한다 — "확인되지 않은 능력을
        낙관하지 않는다"(확인 불가 ≠ 충족, spec §3.4 와 동형인 원칙)와
        "일반 작업은 절대 막지 않는다"(spec §4.5)는 두 요구를 하나의
        보수적 기본값으로 동시에 만족시킨다.
        """
        if self._state == STATE_CAPABLE:
            return MODE_ORCHESTRATED
        return MODE_SINGLE_WORKER

    @property
    def probe_consultations(self):
        """`detect()` 가 실제로 `probe` 콜러블을 호출한 횟수.

        세션 캐시 계약("첫 Orchestration 진입 시 1회", spec §5.1)의 실측
        축 — 같은 세션에서 `detect()` 를 몇 번을 다시 불러도, 이미 상태가
        결정된 뒤에는 이 값이 늘지 않는다.
        """
        return self._probe_consultations

    @property
    def notice(self):
        """강등 발생 시의 평문 1줄 통지 — 강등 전에는 `None`."""
        return self._notice

    @property
    def degraded_reason(self):
        """강등 사유(`REASONS` 원소) — 강등 전에는 `None`."""
        return self._degraded_reason

    # -- 감지 (lazy, 세션 스코프 캐시) --------------------------------------

    def detect(self, probe):
        """능력을 감지한다 — 이미 결정된 세션은 캐시된 state 를 즉시 반환한다.

        `probe`: 인자 없이 호출하면 `bool` 을 반환하는 콜러블(모듈
        docstring "Python 은 에이전트를 스폰하지 않는다" 절 — 이 콜러블
        자체가 에이전트를 스폰하지 않는다, Prompt 레이어가 이미 얻은
        SPIKE-3 프로브 결과를 전달하는 통로일 뿐이다).

        `state` 가 이미 `STATE_UNKNOWN` 이 아니면(이전 `detect()` 호출로
        결정됐거나, `report_dispatch_failure()` 로 이미 강등됐거나) `probe`
        는 전혀 호출되지 않고 캐시된 state 를 즉시 반환한다 — 후자의
        경우(관측 우선으로 이미 강등된 세션에서 뒤늦게 `detect()` 가
        호출되는 경우) 비싼 프로브(SPIKE-3 실측 ~10.6s)를 다시 치르지
        않고 이미 확인된 더 강한 신호(실제 관측)를 그대로 보존한다.

        `probe()` 가 불가(`False`)를 보고하면 즉시 강등(`_degrade`)한다.

        `probe()` 호출 자체가 예외를 던지면(finding 1, F2 fix review —
        예: 프로브 구현이 타임아웃/IO 오류 등을 그대로 올리는 경우) 그
        예외를 호출자에게 전파하지 않고 불가(`REASON_PROBE_INCAPABLE`)로
        강등한다 — orchestration 실패가 일반 작업을 BLOCK 하지 않는다는
        계약(spec §4.5)의 실행 축이다. 이는 `probe` 자체가 계약을 어긴
        경우(non-callable, non-bool 반환)와는 다르다 — 그런 호출자 버그
        신호는 여전히 `DispatchEnvError` 로 명시 거부한다(아래 `_require_
        callable`/`_require_bool` 은 이 try 블록 밖에서 그대로 동작).
        """
        if self._state != STATE_UNKNOWN:
            return self._state
        _require_callable(probe, "probe")
        self._probe_consultations += 1
        try:
            probe_result = probe()
        except Exception as exc:  # noqa: BLE001 - 의도적 광역 흡수(spec §4.5)
            self._state = STATE_INCAPABLE
            self._degrade(
                REASON_PROBE_INCAPABLE,
                "capability probe raised {}: {} — treated as incapable "
                "(orchestration failure must not propagate, spec "
                "§4.5)".format(type(exc).__name__, exc),
            )
            return self._state
        observed_capable = _require_bool(probe_result, "probe()")
        if observed_capable:
            self._state = STATE_CAPABLE
        else:
            self._state = STATE_INCAPABLE
            self._degrade(
                REASON_PROBE_INCAPABLE,
                "capability probe reported an incapable nested-dispatch "
                "environment (SPIKE-3 adopted probe signal, "
                "docs/reports/v2-spike3-nested-dispatch.md)",
            )
        return self._state

    # -- 관측 우선 강등 -------------------------------------------------------

    def report_dispatch_failure(self, detail=None):
        """실제 중첩 디스패치 실패 관측 — 사전 상태와 무관하게 즉시 강등한다.

        spec §5.1 "관측 우선 원칙": 사전 감지 결과(`STATE_CAPABLE` 이든
        `STATE_UNKNOWN` 이든)와 무관하게, 이 메서드가 호출되면 즉시
        `STATE_INCAPABLE` 로 전이한다 — 런타임 관측이 사전 감지보다
        항상 우선하는 최종 안전망이다. `detail` 은 감사용 상세 문자열
        (예: 실제로 관측된 실패 내용)이며, `notice`(사용자 대면 평문)에는
        노출되지 않고 `recorder` 가 받는 record 의 `detail` 필드로만
        전달된다.

        예외를 던지지 않는다 — orchestration 실패로 일반 작업을 BLOCK
        하지 않는다는 계약(spec §4.5)의 실행 축. 같은 세션에서 여러 번
        호출돼도(반복 관측) 매번 정상적으로 강등 상태를 재확인하고
        `recorder` 를 다시 호출한다 — "단일 실행 지속" 이 안정적으로
        유지된다는 것을 반복 호출로도 보인다.
        """
        self._state = STATE_INCAPABLE
        self._degrade(
            REASON_OBSERVED_FAILURE,
            detail if detail else "an actual nested dispatch attempt failed at runtime",
        )
        return self._state

    # -- 내부 ----------------------------------------------------------------

    def _degrade(self, reason, detail):
        """강등 1건 처리 — notice 갱신 + recorder 통지를 항상 함께 수행한다.

        `detect()`/`report_dispatch_failure()` 두 강등 경로가 모두 이
        메서드를 거친다 — "강등이 일어나는데 통지도 기록도 없는" 경로는
        이 모듈 안에 없다(silent 강등 금지, 모듈 docstring 참조).

        `recorder` 호출이 예외를 던져도(finding 1, F2 fix review — 예:
        조립된 recorder 자신의 내부 계약 위반) 그 예외를 흡수한다 —
        `notice`/`state`/`mode` 는 이미 이 메서드 안에서 확정됐으므로
        recorder 실패가 강등 자체를 되돌리지 않는다. recorder 는 best-
        effort 통지 채널이지, 강등 성립의 전제조건이 아니다(생성자
        `recorder=None` 을 허용하는 것과 동일한 원칙의 연장) — 예외를
        여기서 삼키지 않으면 orchestration 실패가 일반 작업을 BLOCK
        하지 않는다는 계약(spec §4.5)이 recorder 구현의 버그 하나로
        깨진다.
        """
        if reason not in REASONS:
            raise DispatchEnvError(
                "unknown degrade reason {!r} (expected one of {})".format(
                    reason, REASONS
                )
            )
        self._degraded_reason = reason
        self._notice = _NOTICE_BY_REASON[reason]
        record = {
            "reason": reason,
            "detail": detail,
            "state": self._state,
            "mode": self.mode,
            "notice": self._notice,
        }
        if self._recorder is not None:
            try:
                self._recorder(dict(record))
            except Exception:  # noqa: BLE001 - 의도적 광역 흡수(spec §4.5)
                pass
        return record

    # -- 직렬화 ----------------------------------------------------------------

    def to_dict(self):
        """직렬화 — 매 호출 새 dict (kernel `Decision.to_dict` 와 동일 관례)."""
        return {
            "state": self._state,
            "mode": self.mode,
            "probe_consultations": self._probe_consultations,
            "notice": self._notice,
            "degraded_reason": self._degraded_reason,
        }
