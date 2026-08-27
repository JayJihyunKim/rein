"""Shadow Capture — masked representation, capture 단계부터 (plan Task 2.7).

spec §6.4 / brainstorm §46 "Shadow Privacy / Masking":
    "Shadow Case 에 raw command 나 민감정보를 그대로 저장하지 않는다.
    가능하면 Capture 단계부터 raw command → parsed fact → masked
    representation 으로 저장한다."
    예시: `git push https://token@host/repo`
        → `command.type=git.push` + `command.redacted=git push <REMOTE>`

이 모듈은 "잠시 원문을 담았다가 나중에 지우는" 구조를 만들지 않는다 —
`ShadowCase` 에는애초에 raw command 를 실을 필드 자체가 없다. `capture()`
는 원문 문자열을 지역 인자로만 받고, `build_redacted_command()` 를 거친
파생값(`command.type` / `command.redacted`) 만 레코드에 대입한다.

마스킹은 SSOT 인 `rein.shadow.masking` 을 그대로 호출한다 (자체 정규식
재구현 금지 — 이 모듈이 새로 여는 유일한 탐지 표면은 "URL 모양 인자를
구조적으로 축약" 뿐이며, 이는 "이 값이 secret 인가" 를 판정하는 마스킹
규칙이 아니라 "이 인자 형태는 무조건 불투명 처리" 라는 별개의 구조적
정책이다 — 근거는 `build_redacted_command()` docstring 참조).

Shadow Case 최소 정보 스키마 (spec §6.4 / brainstorm §47):
    event, relevant facts, masked command, project state subset,
    v1 decision, v1 reason.
`ShadowCase` 는 이 6종을 전부 담고 `captured_at` 을 부가 필드로 더한다 —
"최소 스키마 준수" 는 "이 필드들이 존재" 이지 "이 필드들만 존재" 가
아니므로 추가 필드는 계약 위반이 아니다.
"""
import datetime
import re
import shlex
from dataclasses import dataclass, field

from rein.engine import command_classifier
from rein.shadow import masking
from rein.shadow import paths

__all__ = [
    "MAX_COMMAND_CHARS",
    "TRUNCATION_MARKER",
    "ShadowCase",
    "build_redacted_command",
    "capture",
]

# --- 대용량 입력 길이 정책 (요구사항 6) --------------------------------
#
# 실측 근거 (2026-08-08, `masking.mask()` 대상, 직전 웨이브가 도입한
# 접두 32자/접미 128자 ReDoS 상한 적용 후): `"token=" + "a"*20` 을
# 반복한 입력에서 450KB 입력이 ~36ms, 4.5KB 입력이 ~0.1ms — 선형에
# 가깝고 이차 폭발은 관측되지 않는다.
#
# 절단은 masking **이후**에만 적용한다 (2026-08-09 보안 리뷰 High 수정
# — 상세 근거는 `build_redacted_command()` docstring). Corpus 크기
# 규율(spec §6.4 "최소 정보" — heredoc 스크립트나 거대 one-liner 를
# 통째로 corpus 에 눌러 담지 않는다) 은 여전히 유효하지만, 그 절단이
# masking 규칙(특히 값 뒤에 종결자를 요구하는 URL credential 류)의
# 완전한 패턴 매칭을 방해해서는 안 된다. 따라서 classify/tokenize/mask
# 는 원문 전체 길이에 비례한 비용을 지불하고(masking.py 자체는 위
# 실측처럼 선형, `command_classifier.classify` 도 단일 순회 + shlex 로
# 선형이라 이차 폭발 없음), 상한은 masking 이 끝난 **결과** 문자열에만
# 적용한다.
#
# 이전엔 "masking 엔진 변경에 대한 방어적 격리"(capture 호출 비용을
# masking.py 복잡도와 무관하게 상수 상한으로 두는 것) 를 위해 raw
# text 를 1) 구조적 축약/2) masking 보다 먼저 잘랐다. 그 순서가 절단
# 경계를 secret 값 중간에 떨어뜨려 값 뒤 종결자를 요구하는 masking
# 규칙을 무력화시키는 secret 평문 노출 결함을 낳았다(리뷰어 실측:
# `...REALFAKEPA <TRUNCATED>` 10자 노출 — `tests/shadow/
# test_capture_masked.py` 의 truncation-order 회귀 테스트로 고정).
# 이 프로젝트의 위협모델은 적대적 하드닝을 명시적으로 보류한 "정직한
# 에이전트 규율"까지이므로, correctness(비밀 비노출)를 latency 보다
# 우선한다.
#
# 4096 은 실사용 커맨드라인(수백 자) 대비 여유 있는 상한이면서, 병적
# 입력(수십만~수백만 자)을 정책적으로 잘라내는 값이다.
MAX_COMMAND_CHARS = 4096

# 잘렸음을 뒤에 명시 — masking 이 쓰는 `<REDACTED>`/구조적 `<URL>` 류
# 플레이스홀더와 형태가 겹치지 않게 사람이 읽을 수 있는 마커로 둔다.
TRUNCATION_MARKER = " …<TRUNCATED>"

# --- 구조적 URL 인자 축약 -----------------------------------------------
#
# RFC 3986 scheme 문법(`scheme ":"`)의 앞부분만 확인하는 구문 검사다 —
# "이 토큰 안에 secret 이 있는가" 를 판정하는 마스킹 규칙이 아니라
# "이 토큰이 URL 모양인가" 만 보는 구조 분류다 (command_classifier.py
# 와 같은 종류의 보수적 화이트리스트 접근).
#
# 존재 이유 재검토 (2026-08-09, 동시 웨이브에서 masking.py 의 URL
# credential 규칙(`_URL_CREDENTIAL`)이 콜론 없는 `scheme://TOKEN@host`
# 형태(GitHub PAT 관용 형태, spec §6.4 예시 그 자체)도 잡도록 SSOT 가
# 수정되는 중이다 — 그 수정이 반영되면 "credential 마스킹" 목적만
# 놓고 보면 이 구조적 축약은 masking.py 만으로도 커버되어 중복이다.
# 그럼에도 이 축약을 **유지**하기로 판단한 근거는 credential 마스킹이
# 아니라 별개의 목적 때문이다:
#   masking.py 의 `_URL_CREDENTIAL` 은 URL 안의 "credential 부분"
#   (`user:pass@`/`TOKEN@`) 만 `<REDACTED>` 로 치환하고, host/path
#   (`github.com/org/repo.git` 같은 remote 자체)는 그대로 남긴다 —
#   masking.py 는 "이 값이 credential 인가" 만 판정하지, "이 URL 이
#   내부 git remote 인가" 를 판정하는 모듈이 아니기 때문이다(masking.py
#   docstring "제외 — 엔진 대상 아님" 목록 참조). 반면 spec §6.4 예시
#   (`git push https://token@host/repo` → `command.redacted=git push
#   <REMOTE>`) 는 credential 유무와 무관하게 host/path 까지 통째로
#   `<REMOTE>` 로 지우는 것을 요구한다 — remote 저장소 위치 자체를
#   corpus 에 남기지 않는 것이 목표이며, 이는 masking.py 의 SSOT 수정
#   여부와 무관하게 이 모듈(`command` 필드)이 독자적으로 계속 보장해야
#   하는 정책이다.
#
# masking.py 수정 후에도 충돌·이중 처리 혼선은 없다: 순서가 항상
# "구조적 축약 → masking"(collapse-then-mask, `build_redacted_command`
# 참조) 이므로, 축약이 이미 토큰을 `<REMOTE>`/`<URL>` 플레이스홀더로
# 바꿔놓은 뒤 masking 이 그 위를 다시 훑어도 매치할 대상이 없어
# 아무 일도 하지 않는다(멱등). 축약이 스킵되는 경로(UNKNOWN 분류·
# 토큰화 실패)에서는 원문 URL 이 masking 에게 그대로 넘어가므로, 그
# 경로에서의 credential 방어는 masking.py SSOT 수정에 전적으로
# 의존한다 — 이 worker 는 masking.py 를 수정하지 않으므로(동시 웨이브
# 소유), 그 경로의 실제 커버리지는 부모(메인 세션)가 masking.py
# 최종본으로 재검증해야 한다.
_URL_SCHEME_TOKEN = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*://")

# git 원격 URL 을 인자로 받는 서브커맨드 — spec §6.4 예시와 동일하게
# `<REMOTE>` 로 축약한다. 그 외 URL 모양 인자(curl/wget 등)는 `<URL>`.
_REMOTE_URL_COMMAND_TYPES = frozenset(
    {"git.push", "git.pull", "git.fetch", "git.clone", "git.remote"}
)
_REMOTE_PLACEHOLDER = "<REMOTE>"
_URL_PLACEHOLDER = "<URL>"


def _collapse_url_tokens(tokens, command_type):
    placeholder = (
        _REMOTE_PLACEHOLDER
        if command_type in _REMOTE_URL_COMMAND_TYPES
        else _URL_PLACEHOLDER
    )
    return [
        placeholder if _URL_SCHEME_TOKEN.match(tok) else tok for tok in tokens
    ]


def build_redacted_command(command_text, project_root=None):
    """원문 `command_text` 를 받아 `(command_type, redacted)` 만 돌려준다.

    호출부는 이 두 파생값만 레코드에 대입해야 한다 — `command_text`
    자체를 어디에도 대입하지 않는다 (구조적 보장, spec §46).

    순서 (2026-08-09 보안 리뷰 High 수정 — 절단은 masking 이후에만):
      1) 구조적 URL 인자 축약 — `command_classifier.classify()` 가
         UNKNOWN 이 아니고 `shlex` 토큰화가 성공하면, `scheme://` 형태
         토큰을 통째로 `<REMOTE>`/`<URL>` 로 치환한다 (모듈 상단
         `_URL_SCHEME_TOKEN` 근처 docstring 참조 — 이 축약을 유지하는
         근거는 "masking.py 사각지대 메꾸기" 가 아니라 "remote URL
         host/path 를 통째로 지우는 별개 정책"이다, 2026-08-09 재검토).
      1.5) 사적 경로 축약 — `paths.normalize()` SSOT 로 프로젝트 루트
         하위 절대경로를 루트 기준 상대경로로, 프로젝트 밖 홈 경로를
         `<HOME>/...` 로 줄인다 (2026-08-10 신설). URL 축약과 같은
         성격의 **구조적 정책**이라 같은 단계에 둔다 — "이 값이
         비밀인가" 판정이 아니라 "경로 표기에서 사용자 신원을 지운다"
         이다. 마스킹보다 **앞**에 두는 이유: 축약은 경로 접두만
         갈아끼우는 치환이라 secret 값을 반으로 가르지 않으며(절단과
         다른 성질), 앞서 두면 이후 마스킹이 축약된 문자열 전체를
         한 번 더 훑으므로 경로 안에 섞인 credential 도 그대로 잡힌다.
      2) masking 엔진 SSOT 통과 — 앞 단계들 이후 문자열 **전체**에
         `masking.sanitize()`(자체 재구현 금지, 그대로 호출) 를 적용해
         key=value·Authorization 헤더·standalone bearer·URL credential
         등 나머지 패턴을 마스킹한다.
      3) 길이 정책 — 앞 단계를 마친 **masked 결과**에만
         `MAX_COMMAND_CHARS` 절단을 적용한다 (정의부 주석 참조).

    구조 불확실(UNKNOWN 분류 또는 토큰화 실패, 예: 인용 불균형이나
    `&&`/`;` 등 구조 메타문자 포함)이면 1) 을 건너뛰고 전체 문자열에
    2) 만 적용한다 — `command_classifier` 의 fail-closed 철학(불확실
    하면 손대지 않고 있는 그대로를 더 보수적인 경로로 넘긴다)과
    동일하게, 구조를 아는 척하지 않는다.

    절단을 masking 뒤로 미루는 이유 (보안 리뷰 실측): 이전에는 raw
    text 를 1) 이전에 먼저 잘랐다. 절단 경계가 secret 값 중간에
    떨어지면, masking 규칙 중 값 뒤에 종결자를 요구하는 것들
    (`masking._URL_CREDENTIAL` 의 trailing `@`)이 매칭에 실패해 secret
    조각이 그대로 노출됐다 (리뷰어 실측: `...REALFAKEPA <TRUNCATED>`
    10자 평문 노출 — 절단이 quote 를 반으로 갈라 shlex 토큰화까지
    실패시켜 1) 도 건너뛴 상태였다). masking 이 항상 완전한 원문을
    보게 하면 이 클래스가 사라진다 — 그 대가로 classify/shlex/mask 가
    원문 전체 길이에 비례한 비용을 진다(전부 선형, `MAX_COMMAND_CHARS`
    정의부 주석의 실측/위협모델 근거 참조).
    """
    if not command_text:
        return command_classifier.UNKNOWN, ""

    command_type = command_classifier.classify(command_text)

    tokens = None
    if command_type != command_classifier.UNKNOWN:
        try:
            tokens = shlex.split(command_text, posix=True)
        except ValueError:
            tokens = None

    if tokens:
        working = shlex.join(_collapse_url_tokens(tokens, command_type))
    else:
        working = command_text

    working = paths.normalize(working, project_root)
    redacted = masking.sanitize(working)
    if len(redacted) > MAX_COMMAND_CHARS:
        redacted = redacted[:MAX_COMMAND_CHARS] + TRUNCATION_MARKER
    return command_type, redacted


# --- facts / project_state 방어적 정화 -----------------------------------
#
# 이 키들은 caller 가 실수로 원문 명령을 얹어 넣기 쉬운 이름이다 —
# 값 마스킹과 별개로 키 자체를 드롭한다(방어 심층화). 정상적인
# `command.type`/`command.redacted` 는 capture() 가 별도 `command` 필드로
# 관리하므로 facts/project_state 에 동일 정보를 실을 필요가 없다.
_FORBIDDEN_KEYS = frozenset(
    {"command", "command.raw", "command_raw", "raw", "raw_command", "raw_command_text"}
)


def _sanitize_text(text, project_root):
    """문자열 leaf 하나에 대한 정화 — 경로 축약 후 마스킹 SSOT.

    `command` 필드와 동일한 순서(경로 축약 → 마스킹)를 쓴다. 두 경로가
    다른 순서를 쓰면 같은 입력이 필드에 따라 다르게 남아 대조가 흔들린다.
    """
    return masking.sanitize(paths.normalize(text, project_root))


def _sanitize_value(value, project_root=None):
    if isinstance(value, str):
        return _sanitize_text(value, project_root)
    if isinstance(value, dict):
        return _sanitize_mapping(value, project_root)
    if isinstance(value, (list, tuple)):
        return [_sanitize_value(item, project_root) for item in value]
    return value


def _unique_key(key, taken):
    """축약 후 충돌한 key 에 결정론적 접미를 붙인다.

    code review High 후속 (2026-08-10): key 도 정화 대상이 되면서 서로
    다른 두 key 가 같은 값으로 축약될 수 있다(예: `<root>/a.py` 와 `a.py`).
    조용히 덮어쓰면 값 하나가 사라지므로 — 관측 데이터의 무단 유실 —
    유일해질 때까지 번호를 붙인다. 원래 순서의 첫 항목이 접미 없는 이름을
    갖는다.
    """
    if key not in taken:
        return key
    suffix = 2
    while "{} ({})".format(key, suffix) in taken:
        suffix += 1
    return "{} ({})".format(key, suffix)


def _sanitize_mapping(mapping, project_root=None):
    """mapping 을 정화한다 — **key 와 value 모두**.

    key 를 그대로 두면 `facts={"/Users/alice/x": True}` 같은 입력에서
    사용자명·secret 이 그대로 남는다. 값만 훑는 corpus 검증도 이를 놓치므로
    최후 관문까지 함께 뚫린다 (code review High, 2026-08-10 — 실측 재현).
    corpus 쪽도 같은 라운드에서 key 검사를 추가했지만, 여기서 정화해 두면
    정상 레코드가 그 검증에 걸려 통째로 유실되는 일이 없다.
    """
    out = {}
    for key, value in dict(mapping or {}).items():
        if isinstance(key, str) and key.strip().lower() in _FORBIDDEN_KEYS:
            continue
        clean_key = _sanitize_text(key, project_root) if isinstance(key, str) else key
        out[_unique_key(clean_key, out)] = _sanitize_value(value, project_root)
    return out


def _utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S"
    )


@dataclass(frozen=True)
class ShadowCase:
    """Shadow Case 최소 정보 스키마 (spec §6.4 / brainstorm §47).

    필드: event, facts, command(`{"type", "redacted"}` 2키 고정),
    project_state, v1_decision, v1_reason — spec 명시 6종 그대로 +
    부가 필드 `captured_at`. `command` 필드에 raw 문자열을 실을 수 있는
    슬롯이 애초에 없다 — 항상 `build_redacted_command()` 반환값만
    들어온다 (`capture()` 경유 시).
    """

    event: str
    facts: dict = field(default_factory=dict)
    command: dict = field(default_factory=dict)
    project_state: dict = field(default_factory=dict)
    v1_decision: str = ""
    v1_reason: str = ""
    captured_at: str = ""

    def __post_init__(self):
        if not isinstance(self.event, str) or not self.event:
            raise ValueError("ShadowCase.event must be a non-empty string")
        if not isinstance(self.command, dict) or set(self.command) != {
            "type",
            "redacted",
        }:
            raise ValueError(
                "ShadowCase.command must be {{'type': ..., 'redacted': ...}}, "
                "got {!r}".format(self.command)
            )

    def to_dict(self):
        """직렬화 — corpus.py 가 그대로 소비하는 형태. 매 호출 새 dict."""
        return {
            "event": self.event,
            "facts": dict(self.facts),
            "command": dict(self.command),
            "project_state": dict(self.project_state),
            "v1_decision": self.v1_decision,
            "v1_reason": self.v1_reason,
            "captured_at": self.captured_at,
        }


def capture(
    event,
    facts=None,
    command_text=None,
    project_state=None,
    v1_decision="",
    v1_reason="",
    captured_at=None,
    project_root=None,
):
    """Shadow Case 를 만든다 — capture 단계부터 masked representation.

    `command_text` 는 이 함수의 지역 인자로만 존재한다: `ShadowCase` 의
    어떤 필드에도 원문 그대로 대입되지 않고, `build_redacted_command()`
    를 거친 `(type, redacted)` 파생값만 `command` 필드에 실린다.
    `facts`/`project_state`/`v1_reason` 도 대입 전 `_sanitize_mapping`/
    `_sanitize_text` 를 거친다 — 이 값들에 원문 명령이 섞여 들어와도
    동일 마스킹 SSOT 로 걸러진다.

    `project_root` (2026-08-10 신설): 사적 경로 축약의 기준. 주면 그
    하위 절대경로가 루트 기준 상대경로로 줄고, 안 주면 홈 축약만
    적용된다 — 어느 쪽이든 사용자명은 남지 않는다. **모든 문자열
    필드**에 적용한다: 차단 사유 메시지(`v1_reason`)나 경로 fact 에
    절대경로가 실려 오는 경로가 실제로 존재하고, 그 값이 축약되지
    않으면 corpus 반입 검증(`corpus.py` private path)이 레코드를 통째로
    거부해 조용히 유실된다 — 이 유실이 이 인자를 도입한 계기다
    (Phase 2 잔존 1번, 실측: 편집 계열 훅의 실제 경로 레코드 0건).

    주의 (2026-08-09 보안 리뷰 재확인, Medium — "명령 외 필드는 URL
    축약 우회를 안 거친다"): `facts`/`project_state`/`v1_reason` 은
    `command_text` 전용인 구조적 URL 축약(`build_redacted_command()` 의
    1단계, `_collapse_url_tokens`)을 거치지 않는다 — masking SSOT
    (`masking.sanitize`) 만 거친다. 이는 의도된 설계다: 그 구조적 축약은
    spec §6.4 예시가 요구하는 "remote URL 을 통째로 지운다" 는 `command`
    필드 고유 정책이지, corpus 반입 시점에 `corpus.py` 가 검증하는 spec
    명시 8 categories(§6.4) 요건은 아니다. 따라서 `facts`/
    `project_state`/`v1_reason` 에 URL credential 이 섞여 있어도
    masking.py SSOT 가 해당 형태(콜론 유무 불문)를 인식하는 한 항상
    마스킹된다 — capture.py 쪽에서 추가로 보장할 것은 없다("모든 문자열
    필드가 동일 SSOT 를 거친다" 라우팅 계약만 지키면 충분). 이 라우팅
    계약은
    `test_facts_field_url_credential_routes_through_masking_ssot`
    (tests/shadow/test_capture_masked.py) 로 고정한다 — masking.py 의
    실제 규칙 커버리지(예: 콜론 없는 credential 인식 여부)는 SSOT
    소유이므로 이 테스트가 다루지 않는다.
    """
    command_type, redacted = build_redacted_command(command_text, project_root)
    # `event`/`v1_decision` 도 같은 정화를 거친다 (security review Info-2):
    # 현재 호출부는 리터럴만 넘기지만, 예외를 두면 "모든 문자열 필드가
    # 같은 SSOT 를 거친다" 는 라우팅 계약에 구멍이 남는다 — 값이 열거형
    # 이라 정화가 무해하므로 예외를 없애는 쪽이 싸다.
    return ShadowCase(
        event=_sanitize_text(str(event), project_root),
        facts=_sanitize_mapping(facts, project_root),
        command={"type": command_type, "redacted": redacted},
        project_state=_sanitize_mapping(project_state, project_root),
        v1_decision=_sanitize_text(str(v1_decision or ""), project_root),
        v1_reason=_sanitize_text(str(v1_reason or ""), project_root),
        captured_at=captured_at if captured_at is not None else _utc_now_iso(),
    )
