"""Request-scoped 평가 컨텍스트 (plan Task 1.7 · 2.2 — spec §3.2, §3.4).

단일 요청(이벤트)의 평가 재료를 한 그릇에 담는다: fact 스냅샷 +
lazy fact resolver + evidence source.

Lazy Fact Resolution (spec §3.2, Task 2.2):
- Policy 가 요구하는 Fact 만 계산한다 — resolver 등록만으로는 아무것도
  실행되지 않고, `fact()` 조회 시점에 처음 계산된다.
- 동일 Evaluation Cycle(= EvaluationContext 인스턴스) 안에서 Fact 는
  1회만 계산된다 (request-scoped cache — 성공·실패 모두 cache).
- resolver 는 cheap(tool.type, path, 기본 명령 분류) / expensive
  (git status, ChangeSet, digest, active task, review state) cost 로
  구분 등록한다. 두 부류 모두 lazy — cost 는 성능 회계·정책 판단용
  메타데이터다.
- 사전 해석된 fact 스냅샷이 resolver 보다 우선한다 (Task 1.7 계약 불변).

fact 해석 실패의 지위 (Task 2.2 에서 결정 — 이전 버전의 "Phase 2 결정
지점" 예약 해소): resolver 예외 = 판단 불능(Evaluation Failure) 승격.
FactResolutionError 는 EvidenceStorageError 의 하위 타입이다 — 해석
실패는 "판단 재료를 확보하지 못해 판단 자체를 수행하지 못한 상태" 이므로
storage parse 실패와 동일 계층이다 (spec §3.4 부재≠판단불능 경계의
fact 측 대칭). 실패를 default 반환(부재 위장)으로 삼키면 정상 평가와
판단 불능이 섞이므로 금지한다.

경계 어휘 (spec §3.4):
- evidence '부재' = 정상 조회 결과 0건. 정상 평가 BLOCK 재료다.
- EvidenceStorageError = 조회 자체가 실패해 판단을 수행하지 못한 상태.
  failure_mode(closed/open/ask_user) 소관이다. 두 상태는 절대 섞이지
  않는다.
"""

# fact resolver cost 구분 (spec §3.2) — 둘 다 lazy, 분류는 메타데이터
FACT_COST_CHEAP = "cheap"
FACT_COST_EXPENSIVE = "expensive"
FACT_COSTS = frozenset((FACT_COST_CHEAP, FACT_COST_EXPENSIVE))


class EvidenceStorageError(Exception):
    """evidence storage 가 판단 재료 제공에 실패 — Evaluation Failure.

    evidence 부재(정상 조회 결과 0건)와 다르다: 부재는 정상 평가 BLOCK,
    이 예외는 판단 불능으로 failure_mode 분기 대상이다 (spec §3.4).
    storage 어댑터(Phase 2)는 parse 실패·손상 등을 이 타입으로 번역해
    올린다 — evaluator 는 이 타입 계열만 Evaluation Failure 로 인정한다.
    """


class FactResolutionError(EvidenceStorageError):
    """fact 해석 자체가 실패 — 판단 불능(Evaluation Failure) 승격.

    EvidenceStorageError 하위 타입: 해석 실패는 판단 재료를 확보하지
    못한 상태라 storage 실패와 동일 계층이다 (spec §3.4). fact 조회가
    default 로 조용히 대체되는 일은 없다 — 부재 위장 금지.

    evaluator 의 evidence 경로(evidence_for)는 이 계열을 잡아
    failure_mode 3분기 하지만, when 매칭 경로에는 catch 가 없으므로
    (evaluator 소유 — Task 2.2 scope 밖) 해석 실패는 호출자까지
    전파된다.

    **미해결 위험 (resolver 실배선 전 인수 조건)**: 이 전파는 안전하지
    않다. bin/rein 의 main() 은 ValueError 만 잡으므로 전파된 예외는
    traceback + exit 1 로 끝나는데, 이 저장소 hook 규약에서 exit 1 은
    non-blocking(통과) 이다 — fail-closed 가 아니라 조용한 ALLOW 로
    귀결된다. 현재는 runtime.evaluate 가 fact_resolvers 를 배선하지
    않고 어떤 hook 도 bin/rein 을 호출하지 않아 도달 불가라 무해하다.
    resolver 를 실제 배선하기 전에 (1) when-경로를 evidence 경로와 같은
    failure_mode 분기로 태우거나 (2) bin/rein 에 미포착 예외 →
    fail-closed BLOCK 매핑을 추가해야 한다.
    """


class FactRegistrationError(ValueError):
    """resolver 등록이 계약을 벗어남 — 등록 시점 명시 실패.

    미지 cost / 중복 키 / callable 아님을 조용히 받아들이면 오류가
    조회 시점(런타임 한가운데)으로 이연되므로 등록 시점에 거부한다.
    """


class FactResolverRegistry:
    """fact 이름 → (resolver, cost) 명시 등록부 (spec §3.2, §32 원칙).

    resolver 계약: `resolver(context) -> value`. context 인자로 다른
    fact 를 조회해 파생 fact 를 만들 수 있다 — Capability 간 공유는
    Fact 경유만 (spec §3.1). 등록만으로는 실행되지 않는다 (lazy).
    """

    def __init__(self):
        self._resolvers = {}

    def register(self, key, resolver, cost):
        if not isinstance(key, str) or not key:
            raise FactRegistrationError(
                "fact key must be a non-empty string, got {!r}".format(key)
            )
        if not callable(resolver):
            raise FactRegistrationError(
                "resolver for fact {!r} must be callable".format(key)
            )
        if cost not in FACT_COSTS:
            raise FactRegistrationError(
                "unknown fact cost {!r} for fact {!r} (allowed: {})".format(
                    cost, key, ", ".join(sorted(FACT_COSTS))
                )
            )
        if key in self._resolvers:
            raise FactRegistrationError(
                "fact {!r} already has a registered resolver".format(key)
            )
        self._resolvers[key] = (resolver, cost)

    def __contains__(self, key):
        return key in self._resolvers

    def resolver(self, key):
        """등록된 resolver callable — 미등록 키는 KeyError."""
        return self._resolvers[key][0]

    def cost(self, key):
        """등록된 cost 분류 — 미등록 키는 KeyError."""
        return self._resolvers[key][1]

    def registered(self):
        """key -> cost 사본 — 호출자가 내부 상태를 변경하지 못하게."""
        return {key: cost for key, (_, cost) in self._resolvers.items()}


class NullEvidenceSource:
    """storage 미배선 단계의 기본 소스 — 모든 requirement 를 '부재'로 본다.

    walking skeleton 의 "evidence 저장소가 아직 없으므로 require 는 전부
    미충족" 동작을 명시적 객체로 승격한 것이다. 조회는 항상 정상 수행되고
    결과가 0건일 뿐이므로 failure_mode 는 발동하지 않는다.
    """

    def find(self, requirement_name):
        return ()


class EvaluationContext:
    """단일 요청의 평가 재료 — fact 스냅샷 + lazy resolver + evidence source.

    인스턴스 1개 = Evaluation Cycle 1회. resolver 계산 결과(성공·실패)
    는 인스턴스에 cache 되고 cycle 간에는 공유되지 않는다.

    **소비 예약 슬롯** (plan Task 4.5 사이클 C 재리뷰 2회차 High 시정 —
    request-scoped pending consumption slot, `reserve_consumption`/
    `pending_consumptions` 참조): one-shot 성격의 Requirement(예:
    `user_approval`)는 "충족 판정"과 "외부 저장소에 소비를 기록하는 것"
    을 같은 순간에 할 수 없다 — 같은 cycle 안에서 여러 policy 가 같은
    요구를 반복 확인하거나(예: policy 2개가 모두 `user_approval` 을
    요구), 한 policy 가 여러 requirement 를 요구하는데 그중 하나가
    부족해 cycle 전체가 결국 BLOCK 으로 끝나는 경우, `evaluate()` 호출
    시점에는 최종 decision 을 아직 모르기 때문이다(evaluator 는 policy
    전부를 다 확인한 뒤에야 decision 을 낸다). 이 슬롯은 "cycle 이
    ALLOW 로 끝나면 실행할 부수효과"를 **모아만 두고 실행하지 않는다**
    — 실제 실행(commit)은 이 cycle 이 끝나고 최종 decision 을 아는
    쪽(`rein.engine.runtime.evaluate`)의 책임이다. Requirement 구현체
    (capability)는 이 슬롯에 무엇을 넣을지만 결정할 뿐, 언제 실행되는지·
    누가 실행하는지는 모른다 — 이 컨텍스트도 "commit 대상이 무엇인지"만
    들고 있을 뿐 그 의미(무엇을 소비하는지)는 모른다(callable 을 그대로
    보관·호출할 뿐).
    """

    def __init__(self, facts=None, evidence_source=None, fact_resolvers=None):
        self._facts = dict(facts or {})
        if evidence_source is None:
            evidence_source = NullEvidenceSource()
        self._evidence_source = evidence_source
        self._fact_resolvers = fact_resolvers
        self._resolved = {}  # request-scoped cache: key -> 계산된 값
        self._resolution_failures = {}  # key -> FactResolutionError
        self._resolving = []  # 해석 진행 중 키 스택 — cycle 감지용
        # (id(store), key) -> (store, key) — cycle 수명. `id()` 기반인
        # 이유는 `reserve_consumption` docstring 참조(Medium 시정, 사이클
        # C 재리뷰 3회차: store 자체를 dict/set key 로 쓰면 store 가
        # __hash__ 없이 __eq__ 만 override 한 경우 TypeError 로 깨진다).
        self._pending_consumptions = {}
        # requirement_name -> evidence tuple. request-scoped cache —
        # `evidence_for()` 참조 (Phase 6 리뷰 High 1 시정: 등록 구현체의
        # 내부 조회와 배선 계층의 재확인 조회가 서로 다른 스냅샷을 보는
        # 것을 막는다).
        self._evidence_cache = {}

    def fact(self, key, default=None):
        """fact 값을 읽는다 — 스냅샷 우선, 없으면 lazy 해석, 그래도 없으면 default.

        해석 실패는 default 로 대체되지 않고 FactResolutionError 로
        승격된다 (판단 불능 ≠ 부재 — 모듈 docstring 참조).
        """
        if key in self._facts:
            return self._facts[key]
        if self._fact_resolvers is not None and key in self._fact_resolvers:
            return self._resolve(key)
        return default

    def facts(self):
        """fact 스냅샷 + 이번 cycle 에 이미 해석된 fact 의 병합 사본.

        미해석 resolver fact 를 강제 해석하지 않는다 (lazy 보존).
        사본이므로 호출자가 내부 상태를 변경하지 못한다.
        """
        merged = dict(self._facts)
        merged.update(self._resolved)
        return merged

    def evidence_for(self, requirement_name):
        """requirement 의 evidence 레코드 tuple 을 반환한다.

        빈 tuple = 부재 (정상 평가 재료). 저장소 실패는
        EvidenceStorageError 그대로 통과시킨다 — 부재로 삼키면 정상
        BLOCK 과 판단 불능이 섞여 failure_mode 경계가 무너진다.

        **request-scoped cache** (Phase 6 리뷰 High 1 시정): 동일
        cycle(=이 컨텍스트 인스턴스) 안에서 같은 `requirement_name` 을
        두 번째 이후 조회하면 첫 조회 결과를 그대로 재사용한다 — fact
        캐시(`_resolve`)와 동일한 request-scoped 원칙이다. 이 캐시가
        없으면, 등록 구현체의 `evaluate(context)` 내부 조회(예:
        `CodeReviewRequirement.evaluate`)와 그 위 배선 계층
        (`evaluator._requirement_satisfied` 의 authority dual-read
        "evidence 존재 여부" 재확인)이 가변 evidence source 에 대해
        서로 다른 시점의 결과를 볼 수 있다 — 리뷰어가 실증한 결함:
        첫 조회에서 digest 불일치로 v2 가 False 를 판정했는데, 두 번째
        조회가 (같은 cycle 안에서 store 가 바뀌어) 빈 tuple 을 보면
        "v2 가 이 requirement 를 아예 모른다"로 오인정되어 legacy
        marker fallback 이 발동하고, legacy 가 PASS 면 v2 의 False
        판정이 조용히 뒤집혀 fail-open ALLOW 가 된다(v2 우선순위 계약
        위반). 캐싱은 두 소비자가 항상 같은 스냅샷을 보게 강제해 이
        경로를 구조적으로 차단한다 — 실제 저장소 조회(`.find()`)는
        cycle 당 requirement 이름별로 최대 1회만 일어난다. 저장소
        실패(예외)는 캐시하지 않는다 — 예외는 그대로 전파되고, 이
        cycle 안에서 같은 이름을 또 조회하면 다시 시도한다(기존 동작
        보존, 성공 결과만 스냅샷 대상이다).
        """
        if requirement_name in self._evidence_cache:
            return self._evidence_cache[requirement_name]
        records = tuple(self._evidence_source.find(requirement_name) or ())
        self._evidence_cache[requirement_name] = records
        return records

    def reserve_consumption(self, store, key):
        """`(store, key)` 쌍을 이 cycle 의 소비 예약 목록에 멱등하게 추가한다.

        one-shot Requirement 구현체(예: `UserApprovalRequirement`)가
        "이 evidence 는 유효하고 아직 소비되지 않았다"를 확인했을 때
        호출한다 — **이 메서드 자체는 어떤 외부 상태도 바꾸지 않는다**
        (클래스 docstring "소비 예약 슬롯" 절). `store` 는 `is_consumed`/
        `claim`/`release` 콜러블을 제공하는 duck-typed 객체로 기대되지만,
        이 컨텍스트는 그 프로토콜을 검증하지 않는다 — 검증은 주입한
        Requirement 구현체(capability)의 책임이다(이 컨텍스트는 어떤
        capability 도 모른다, spec §3.1).

        같은 `(store, key)` 를 여러 번 예약해도(예: 같은 cycle 안에서
        서로 다른 policy 가 같은 요구를 반복 확인) 한 항목으로
        수렴한다 — commit 은 cycle 종료 후 그 조합마다 정확히 한 번씩만
        일어난다(사이클 C 재리뷰 2회차 실증 케이스 (a) 시정: 같은
        승인을 요구하는 policy 2개가 같은 cycle 에서 서로 다른 소비로
        계산되던 결함).

        **dedup 키는 `(id(store), key)` 이지 `(store, key)` 자체가
        아니다** (Medium 시정, 사이클 C 재리뷰 3회차): 이전 구현은
        `(store, key)` tuple 을 그대로 `set` 원소로 넣었는데, 이는 문서화
        된 프로토콜(콜러블 존재만 요구)에 없는 숨은 요구사항 — "store 가
        hashable 해야 한다" — 를 실제로 강제했다. `__eq__` 만 override
        하고 `__hash__` 를 재정의하지 않은 클래스는 Python 규약상 자동
        `unhashable`(`__hash__ = None`)이 되므로(흔한 실수), 그런 store
        를 주입하면 `TypeError` 로 깨졌다. `id(store)` 는 어떤 객체에도
        항상 존재하는 정수라 이 문제가 구조적으로 발생하지 않는다 —
        의미상으로도 "같은 store 인스턴스"를 식별하려는 의도이므로
        identity 비교(`id`)가 오히려 더 정확하다(값 기반 `__eq__`/
        `__hash__` 를 쓰면 우연히 값이 같은 서로 다른 store 인스턴스가
        같은 것으로 오인정될 위험도 있다). `key` 자체는 여전히
        hashable 이어야 한다(dict key 의 나머지 절반) — 이 시스템에서
        `key` 는 항상 kernel `evidence_fingerprint()` 가 만드는 hex
        문자열이므로 문제 없다.
        """
        self._pending_consumptions[(id(store), key)] = (store, key)

    def pending_consumptions(self):
        """예약된 `(store, key)` 쌍의 불변 스냅샷(`tuple`) — commit 주체가 순회한다.

        이 컨텍스트는 언제 commit 할지 모른다 — 최종 decision 을 아는
        `rein.engine.runtime.evaluate` 가 cycle 종료 후 이 스냅샷을 읽어
        decision 이 ALLOW 이고 **모든 예약의 `store.claim(key)` 가 전부
        성공했을 때만** 그 ALLOW 를 유지한다(사이클 C 재리뷰 2회차 실증
        케이스 (b) 시정: BLOCK 으로 끝나는 cycle 은 어떤 예약도 실행하지
        않아 승인이 보존된다. 3회차 실증: claim 이 실패/예외를 내면
        fail-closed BLOCK 으로 downgrade 하고 이미 성공한 claim 은
        best-effort 로 `release` 한다 — `runtime._commit_pending_
        consumptions` 참조). `evaluator.evaluate()` 는 이 슬롯을 읽지도
        커밋하지도 않는다 — Decision 반환 계약이 그대로 유지된다.

        반환 타입이 `tuple`(`frozenset` 아님)인 이유도 hashability
        문제와 같다: `frozenset` 을 만들려면 원소인 `(store, key)`
        tuple 자체를 다시 해시해야 하는데, 그러면 store 의 hashability
        요구가 반환 경계에서 되살아난다. `tuple` 은 그 요구가 없다.
        """
        return tuple(self._pending_consumptions.values())

    def _resolve(self, key):
        """등록 resolver 로 fact 1회 계산 — 성공·실패 모두 cycle cache."""
        if key in self._resolved:
            return self._resolved[key]
        if key in self._resolution_failures:
            raise self._resolution_failures[key]
        if key in self._resolving:
            raise FactResolutionError(
                "cyclic fact resolution: {} -> {!r}".format(
                    " -> ".join(repr(k) for k in self._resolving), key
                )
            )
        self._resolving.append(key)
        try:
            value = self._fact_resolvers.resolver(key)(self)
        except Exception as error:
            wrapped = FactResolutionError(
                "fact {!r} resolution failed: {}".format(key, error)
            )
            wrapped.__cause__ = error
            self._resolution_failures[key] = wrapped
            raise wrapped
        finally:
            self._resolving.pop()
        self._resolved[key] = value
        return value
