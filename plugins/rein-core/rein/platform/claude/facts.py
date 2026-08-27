"""Claude 이벤트 → `action.current` fact 소스 (v2 Phase 6 worker D — spec
§3.6 §21, approval capability 계약).

`rein.capabilities.approval.capability` 의 `user_approval` Evidence 는
"현재 action" 과 "현재 digest" 두 축으로 결속된다(spec §3.6 §21 "기본
scope = 현재 action + 현재 digest"). 이 모듈은 그중 action 식별자
축을 `rein.platform.claude.adapter.normalize_event` 가 만드는 정규화
이벤트 dict(`{"name": ..., "tool": ..., "payload": ...}`)로부터 만든다.

**결정성이 유일한 계약이다**: `FACT_ACTION_CURRENT` 는 발급 시점
(`issue_user_approval_evidence` 호출 시 Runtime 이 계산해 넘기는 값)과
평가 시점(같은 action 이 다시 시도될 때 `UserApprovalRequirement.
evaluate` 가 재확인하는 값) 두 번 계산된다 — 같은 논리적 action(같은
tool, 같은 명령/대상)이면 항상 같은 문자열이 나와야 승인이 재시도 시에도
인식된다. 반대로 다른 action 은 다른 문자열이어야 승인 오적용(예:
`git push` 승인이 `git force-push` 를 통과시키는 것)을 막는다 — 이는
`rein.capabilities.approval.capability.ActionBindingTest` 가 고정하는
계약(문자열 동등 비교)의 platform 측 대응이다.

식별자 형식은 이 모듈이 자유롭게 정할 수 있다(capability 계약은
"비어있지 않은 str 또는 None" 이라는 타입만 요구하고, 특정 포맷을
요구하지 않는다 — `tests/contract/test_approval_one_shot.py` 의 fixture
`"tool.pre:bash:git-push"` 도 그 테스트 자신의 임의 예시 값일 뿐 이
모듈의 실제 출력 포맷을 강제하지 않는다). 이 모듈은
`"<event 이름>[:<tool>[:<digest>]]"` 형태를 쓴다 — event 이름(예:
`tool.pre`)은 항상 있고, tool 은 있을 때만 덧붙는다(둘 다 Claude
어댑터가 정하는 고정 어휘라 비밀값을 담지 않는다). 세 번째 조각은
"action 을 더 구체적으로 식별할 세부 정보"(정규화된 event 의 전체
payload) **원문이 아니라 그 sha256 digest** 다 — 아래 보안 시정 절 참조.

## 보안 시정 (v2 Phase 6 5회차 재리뷰 High) — payload 일부 키만 보던 결함

이전 구현(4회차까지)은 detail 소스를 tool 종류로 분기했다: Bash 는
`payload["command"]` 전체, 그 외 도구는 `file_path`/`notebook_path`/
`path` 중 첫 매치 값 하나만 봤다. 승인 capability(`rein.capabilities.
approval.capability`)는 이 식별자 문자열을 **단순 동등 비교**로
결속하므로(action+digest 결속, spec §3.6 §21), 이 좁은 선택은 실제
승인 우회로 이어졌다 — 리뷰어 재현:

- `Write(/repo/a.py, content=SAFE)` 와 `Write(/repo/a.py,
  content=DANGEROUS)` 는 `content` 키가 detail 추출 대상이 아니므로
  같은 식별자를 받았다 — 안전한 내용에 대한 승인이 위험한 내용으로
  바꿔치기된 요청에도 그대로 적용됐다.
- `WebFetch(url=allowed.example)` 와 `WebFetch(url=other.example)` 는
  `url` 키가 `_PATH_PAYLOAD_KEYS` 화이트리스트에 없어 detail 이 아예
  없었다 — 도구가 다르지 않으면 대상이 완전히 달라도 같은 식별자였다.

수리: tool 종류에 따른 분기와 키 화이트리스트를 모두 없애고, 정규화된
event 의 **payload 전체**를 결정적으로 직렬화(`json.dumps(...,
sort_keys=True)` — 키 순서·중첩 구조에 무관하게 같은 논리적 내용은
항상 같은 바이트열)한 뒤 그 sha256 digest 를 detail 로 쓴다
(`_detail_digest`). 이제 payload 의 어떤 키가 달라져도(내용이든 대상
이든) 식별자가 달라진다 — 반대로 완전히 같은 payload 는 항상 같은
digest 를 받는다(결정성 계약 유지).

**무엇을 해시 대상에서 제외했는가**: 아무것도 명시적으로 제외하지
않았다 — payload 자체가 이미 비결정적 세션 메타데이터를 담지 않는다.
`adapter.normalize_event` 가 tool 이벤트(`PreToolUse`/`PostToolUse`)에서
넘기는 payload 는 Claude hook 원본 페이로드 전체가 아니라
`tool_input`(도구 호출 인자) 하나만 추출한 것이고, `hook_event_name`/
`session_id`/`transcript_path`/`cwd`/`permission_mode` 같은 세션·호출
메타데이터는 애초에 이 payload 에 들어오지 않는다(adapter.py
`normalize_event` 의 `else` 분기, `payload.get(_TOOL_INPUT_KEY)`). agent
계열 이벤트(`task.*`/`agent.*`)도 마찬가지로 `_agent_lifecycle_payload`
가 `_COMMON_HOOK_BASE_FIELDS`(세션 메타데이터 포함)를 이미 제외한 뒤에
넘긴다. 즉 "타임스탬프·호출 id·세션 식별자 등 매 호출 달라지는 필드"는
이 모듈에 도달하기 전에 adapter 경계에서 이미 걸러진다 — 이 모듈이 다시
걸러낼 대상이 남아있지 않다. 만약 향후 어떤 도구의 `tool_input` 자체가
매 호출 달라지는 필드(예: 도구가 스스로 발급하는 난수 nonce)를 담게
되면, 그 경우는 이 모듈이 아니라 adapter 경계에서 그 필드를 제외해야
한다 — payload 전체를 해시하는 계약 자체는 "adapter 가 넘기는 payload =
action 의 정체성 전체" 라는 전제 위에 서 있다.

## 보안 시정 (v2 Phase 6 재리뷰 High A / High B) — detail 원문을 담지 않는다

이전 구현은 세부 정보(Bash 명령 전체, 파일 경로)를 200자로 절단해 그대로
식별자 문자열에 이어붙였다. 두 가지 결함이 있었다:

- **High A (유출)**: `deploy --password hunter2` 같은 Bash 명령이 fact
  값에 원문 그대로 남아, 이 fact 를 실어 나르는 응답 JSON(`rein.cli`)을
  통해 비밀값이 그대로 노출됐다 — 이 저장소가 이미 봉합한 "차단 로그
  민감정보 유출" 과 같은 클래스이면서, 그 마스킹 단일 출처
  (`rein.shadow.masking`)를 완전히 우회하는 별도 경로였다.
- **High B (충돌)**: 200자 절단은 "앞 200자가 같은 서로 다른 명령"을
  같은 식별자로 뭉갰다 — 승인 A 가 소비되기 전에 명령이 B 로 바뀌어도
  A 의 승인이 B 에 그대로 적용되는 오적용 경로였다.

수리: detail 원문은 이제 이 모듈 밖으로 절대 나가지 않는다 — 항상
전체(미절단) 문자열의 sha256 digest 로 치환한다. 절단이 없으므로 B 가
해소되고(다른 길이·다른 내용은 다른 digest), digest 는 일방향이므로
원문이 fact 값에서 복원 불가능해 A 가 해소된다. digest 포맷·알고리즘은
이 저장소의 기존 관례(`rein.kernel.changeset.content_digest`, sha256,
`"<algo>:<hex>"`)를 그대로 재사용한다 — 새 암호 로직을 발명하지 않는다.

마스킹 엔진(`rein.shadow.masking`)은 여기서 쓰지 않는다 — 의도적 선택
이다. 마스킹은 "사람이 읽는 텍스트에서 비밀값만 감추는" 변환이라 결과가
여전히 가독 문자열이고, 같은 마스킹 패턴을 공유하는 서로 다른 명령
(`--password hunter2` 와 `--password other-secret` 은 둘 다
`--password <REDACTED>` 로 마스킹됨)이 같은 결과로 뭉개져 B 의 충돌
문제를 오히려 재도입한다. 반면 digest 는 원문 전체를 그대로 해싱하므로
이 문제가 없다 — 마스킹이 필요한 지점은 "사람이 읽는 로그" 뿐이고, 이
fact 는 애초에 사람이 읽지 않는 불투명 식별자다. 사람이 읽을 라벨이
추후 필요해지면(현재는 어떤 소비자도 요구하지 않는다) 마스킹을 거친
별도 필드로 추가해야 한다 — 이 식별자 자신을 다시 가독 문자열로
되돌리는 방향은 A 를 재도입하므로 선택지가 아니다.
"""
import hashlib
import json

# detail digest 알고리즘·포맷 — `rein.kernel.changeset` 의 기존 관례
# 재사용 (새 암호 로직을 발명하지 않는다).
_DETAIL_DIGEST_ALGORITHM = "sha256"

# 결정적 직렬화 — 키 순서에 무관하게 같은 논리적 내용은 항상 같은
# 바이트열을 낸다(`sort_keys=True` 는 재귀적으로 모든 중첩 dict 에
# 적용된다). `separators` 로 공백 변형까지 고정한다.
_CANONICAL_JSON_KWARGS = {
    "sort_keys": True,
    "separators": (",", ":"),
    "ensure_ascii": True,
}


def current_action_identifier(event):
    """정규화된 Claude 이벤트로부터 결정적 action 식별자를 만든다.

    `event` 는 `rein.platform.claude.adapter.normalize_event` 의 반환
    형태(`{"name": str, "tool": str|None, "payload": dict}`)를 기대한다
    — 이 함수는 그 shape 을 duck-type 으로만 확인한다(어댑터 모듈을
    import 하지 않는다, 계층 간 결합 최소화).

    `event` 가 dict 가 아니거나 `name` 이 비어 있으면(malformed/부재)
    `None` — capability 계약(str 또는 None)을 어기지 않는 안전한 기본값.
    """
    if not isinstance(event, dict):
        return None
    name = event.get("name")
    if not isinstance(name, str) or not name:
        return None
    parts = [name]
    tool = event.get("tool")
    if isinstance(tool, str) and tool:
        parts.append(tool)
    detail = _detail_digest(event.get("payload"))
    if detail:
        parts.append(detail)
    return ":".join(parts)


def _detail_digest(payload):
    """payload 전체의 sha256 digest — 원문은 절대 반환하지 않는다.

    모듈 docstring "보안 시정" 절 참조. `payload` 가 dict 가 아니거나
    비어 있으면(세부 정보 없음) `None`. 그 외에는 payload 전체를
    결정적으로(`sort_keys=True`) JSON 직렬화한 뒤 해싱한다 — 특정
    키만 골라 보지 않으므로, payload 의 어떤 필드가 달라져도(대상이든
    내용이든) digest 가 달라진다. 직렬화 불가한 값(예: JSON 이 아닌
    hook 입력이 실수로 흘러든 경우)은 조용히 `None` 으로 강등한다 —
    이 fact 는 부재를 안전한 기본값으로 다루는 계약(capability 는 값이
    없으면 미충족으로 처리)이라, 여기서 예외를 올리는 대신 세부 정보
    없이 진행하는 쪽이 fail-safe 하다.
    """
    if not isinstance(payload, dict) or not payload:
        return None
    try:
        serialized = json.dumps(payload, **_CANONICAL_JSON_KWARGS)
    except TypeError:
        return None
    hasher = hashlib.new(_DETAIL_DIGEST_ALGORITHM)
    hasher.update(serialized.encode("utf-8", "surrogateescape"))
    return "{}:{}".format(_DETAIL_DIGEST_ALGORITHM, hasher.hexdigest())
