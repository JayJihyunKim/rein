"""Corpus 반입 Sanitization Validation (plan Task 2.7 — spec §6.4).

`rein.shadow.capture` 가 이미 capture 시점에 masking 을 적용하지만
(§46), corpus 반입은 **독립된 두 번째 관문**이다 — capture 산출물을
무조건 신뢰하지 않고 반입 직전 재검증한다 (예: 과거 버전 capture
산출물의 재반입, `facts`/`project_state` 에 caller 가 실수로 얹은
잔여 정보, 향후 capture 로직 변경으로 인한 회귀 등). 검출 대상은
spec §6.4 가 명시하는 8 categories: token, password, secret,
authorization header, private path, email, API key, URL credential.

masking.py 가 이미 다루는 6 categories(token/password/secret/
authorization header/API key/URL credential) 는 **재구현하지 않고**
`masking.mask()` 를 신호로 재사용한다 — `mask(text) != text` 면 그
6종 중 하나가 존재했다는 뜻이다 (SSOT 호출, 자체 정규식 재구현 금지).
나머지 2 categories 중 private path 는 `rein.shadow.paths` SSOT 가
소유하고(수집 단계의 경로 축약과 규칙을 공유해야 하므로 — 2026-08-10
분리, 근거는 그 모듈 docstring), email 만 이 모듈이 직접 탐지한다.

거부는 조용한 필터링이 아니다 — `CorpusImportRejected` 예외가 사유
(위반 카테고리 목록)를 담아 올라간다. 검증에 걸리면 파일에 아무것도
쓰지 않는다.

추가 범주(2026-08-09, spec §6.4 8 categories 밖 — 순수 구조적 정책):
`CATEGORY_OVERSIZED_FIELD` (`MAX_FIELD_CHARS` 초과 필드는 반입 거부).
secret 탐지가 아니라 corpus 크기 규율 + ReDoS 방어적 격리 목적이다 —
상세 근거는 `MAX_FIELD_CHARS` 정의부 주석 참조.
"""
import json
import re

from rein.platform.storage import local as storage_local
from rein.shadow import masking
from rein.shadow import paths

__all__ = [
    "CATEGORY_CREDENTIAL",
    "CATEGORY_EMAIL",
    "CATEGORY_OVERSIZED_FIELD",
    "CATEGORY_PRIVATE_PATH",
    "CORPUS_FILENAME",
    "MAX_FIELD_CHARS",
    "CorpusImportRejected",
    "find_violations",
    "validate_case",
    "import_case",
]

CORPUS_FILENAME = "shadow-corpus.jsonl"

# masking.py SSOT 가 다루는 6 categories(token/password/secret/
# authorization header/API key/URL credential) 를 mask() 출력 변화
# 하나의 신호로 묶는다 — 어떤 규칙이 걸렸는지는 masking.py 가 노출하지
# 않으므로(그리고 이 모듈은 그것을 재구현하지 않으므로) 세분화하지
# 않는다.
CATEGORY_CREDENTIAL = "credential-like-value"
CATEGORY_EMAIL = "email"
CATEGORY_PRIVATE_PATH = "private-path"
CATEGORY_OVERSIZED_FIELD = "oversized-field"

# 2026-08-09 보안 리뷰 High-2 수정 — 두 가지 독립된 2차 백트래킹 원인이
# 겹쳐 있었다(둘 다 고쳐야 실제로 선형이 된다 — 하나만 고치고 실측을
# 건너뛰었으면 여전히 O(n^2) 로 남았을 것):
#
#   (1) 도메인 문자클래스(`[A-Za-z0-9.\-]+`)가 뒤따르는 필수 리터럴 `\.`
#       와 겹쳐 있었다 — `@` 는 있지만 유효한 TLD 로 끝나지 않는 입력에서
#       도메인 라벨 경계를 재분할하며 역추적했다. 구조를 `(?:label\.)+TLD`
#       로 바꿔 라벨 문자클래스에서 `.` 자체를 제외했다 — 각 라벨의 경계가
#       리터럴 `.` 위치로 유일하게 결정되므로(문자클래스가 그 구분자를
#       삼킬 수 없어 같은 부분문자열을 여러 방식으로 재분할할 모호성이
#       없다) 이 부분은 이제 위치당 상수 비용이다.
#   (2) **(1) 을 고쳐도 여전히 남아 있던, 더 근본적인 원인** — `@` 가
#       전혀 없거나(또는 한두 개만 있고 나머지는 없는) 텍스트에서
#       `re.search()` 는 실패한 시작 위치마다 다시 처음부터 시도한다.
#       각 시작 위치에서 local-part 문자클래스(`[A-Za-z0-9._%+\-]+` —
#       점·영숫자·`%`/`+`/`-` 를 전부 포함)가 뒤이어 `@` 를 못 찾을 때까지
#       그리디 소비 후 문자 단위로 역추적한다 — `@` 없는 구간의 길이가
#       L 이면 이 시작 위치 하나의 비용이 O(L) 이고, 그런 시작 위치가
#       O(n) 개 있으므로 **도메인 구조와 무관하게** 전체가 O(n^2) 이다
#       (실측 재확인 — `.` 도 `@` 도 없는 순수 `"a"*n` 조차 n=2000→4000→
#       8000→16000 에서 ≈4배씩 증가, (1) 만 고친 뒤에도 동일 배율 관측 —
#       즉 (1) 은 리뷰가 지목한 도메인 구조 결함으로서는 정당한 수정이지만
#       리뷰가 실측한 "30KB 텍스트 0.75초" 의 실제 지배 항은 (2) 였다).
#
# (2) 는 정규식 구조를 아무리 다듬어도 Python `re` 의 backtracking 엔진 +
# `search()` 의 "모든 시작 위치 재시도" 조합 자체에서 나오므로, 정규식
# 표현만으로는 근본 해결이 안 된다 — `@` 리터럴 위치를 `str.find()`(C
# 구현, 순수 backtracking 아님 — O(n))로 먼저 찾고, 그 위치 좌우로 RFC
# 5321 실제 상한(local ≤64자/domain ≤255자)보다 넉넉한 **고정 폭
# window** 만 잘라 그 안에서만 정규식을 돌린다(`_contains_email()`).
# `@` 가 몇 개든 각 `@` 당 비용이 O(window)=O(1) 로 상수이므로 전체는
# O(n) — 스케일링 회귀 테스트로 고정
# (`tests/unit/test_masking_engine.py` 의 이메일 전용 스케일링 클래스
# 및 `tests/shadow/test_corpus_import.py` 의 corpus 검증 경로 스케일링
# 테스트 참조). window 밖으로 벗어나는 비현실적으로 긴 local-part/domain
# 은 알려진 한계로 남긴다(RFC 상한의 수 배 여유를 뒀으므로 실사용
# 이메일에는 영향 없음 — `masking.py` 의 접두/접미 상한과 같은 종류의
# trade-off).
_EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@(?:[A-Za-z0-9\-]+\.)+[A-Za-z]{2,}")

_EMAIL_LOCAL_WINDOW = 128
_EMAIL_DOMAIN_WINDOW = 320


def _contains_email(text):
    """`_EMAIL` 이 `text` 안에 존재하는지, `@` 위치마다 고정 폭 window 로
    검사한다 — 근거는 `_EMAIL` 정의부 주석 (2) 참조."""
    start = 0
    length = len(text)
    while True:
        at = text.find("@", start)
        if at == -1:
            return False
        window_start = max(0, at - _EMAIL_LOCAL_WINDOW)
        window_end = min(length, at + _EMAIL_DOMAIN_WINDOW)
        if _EMAIL.search(text[window_start:window_end]):
            return True
        start = at + 1


# 2026-08-09 보안 리뷰 High-2(b) 수정 — facts/project_state/v1_reason 은
# 길이 상한이 전혀 없었다(command 필드만 capture.py `MAX_COMMAND_CHARS` 가
# 적용되고, 그것도 masking 이후에만 — R1-B 참조). 상한을 어디에 둘지
# 결정: capture.py 는 이번 라운드 scope 밖(다른 라운드 담당)이라 여기
# corpus.py 쪽 반입 검증 게이트에 둔다 — corpus.py 는 이미 "capture 산출물을
# 무조건 신뢰하지 않는 독립된 두 번째 관문" 이므로, 호출부가 capture() 를
# 거쳤든 아니든 이 상한이 항상 적용된다.
#
# 절단이 아니라 **거부**를 선택한 이유(R1-B 의 교훈 — "조용한 절단으로
# 비밀값 조각이 남는 실수를 반복하지 말 것"): corpus.py 는 마스킹을
# 수행하지 않는 순수 검증기다(값을 변형해서 쓰지 않고, 통과한 값을 그대로
# 쓴다). 만약 여기서 "상한 넘으면 잘라서 그대로 저장" 을 택하면, 절단
# 경계가 아직 검증되지 않은 secret 값 중간에 떨어져 그 조각만 파일에
# 남을 위험이 다시 생긴다(R1-B 와 동일 클래스). 반면 **전체 반입을
# 거부**하면 그 레코드는 아예 파일에 쓰이지 않으므로 절단 경계 문제
# 자체가 원천적으로 없다 — corpus.py 의 기존 철학("거부는 조용한 필터링이
# 아니다")과도 그대로 정합적이다.
#
# 값 산정: command 필드는 capture.py 에서 이미 `MAX_COMMAND_CHARS`(4096)
# + `TRUNCATION_MARKER`(13자) ≈ 4109자까지 정상적으로 절단돼 들어올 수
# 있다 — 여기 상한을 그와 같거나 더 낮게 두면 정상적으로 절단된
# command.redacted 조차 매번 거부당한다(절단 정책이 무의미해짐). 8192 는
# 그 최대치(4109)에 2배 가까운 여유를 두면서도, facts/project_state/
# v1_reason 처럼 애초에 절단 정책이 없는 필드에 대해서는 "구조화 메타
# 데이터" 라는 spec §6.4 "최소 정보" 취지에 맞는 상한 역할을 한다.
# capture.py 의 정확한 상수 값에 결합(tightly couple)하지 않고 라운드
# 숫자로 독립적으로 정하는 이유는, 두 모듈이 서로 다른 라운드/작업자가
# 담당할 수 있어 상수 하나가 바뀔 때 다른 모듈이 깨지는 결합을 피하기
# 위함이다.
MAX_FIELD_CHARS = 8192

# 사적 경로 규칙은 `rein.shadow.paths` SSOT 소유다 — 이 모듈은 검출만
# 소비한다 (2026-08-10). 규칙 본문·오탐 경계·ReDoS 근거는 그 모듈 참조.
#
# 왜 여기서 재구현하지 않는가: 같은 규칙이 두 곳에 살면 한쪽만 고쳐져
# 경계가 갈라진다 — Phase 2 에서 마스킹 URL credential 규칙으로 4회 반복
# 확인한 결함 클래스다. 특히 수집 단계(`capture.py`)가 이 규칙에 걸리지
# 않는 형태로 경로를 축약해야 하므로, 검출과 축약이 **반드시 같은 정의**
# 를 봐야 한다 (다르면 축약이 검출을 못 피해 레코드가 통째로 유실된다 —
# 실제로 그 유실이 이 SSOT 분리의 계기다).


class CorpusImportRejected(Exception):
    """Sanitization Validation 불통과 — 명시 거부 (spec §6.4).

    `violations` 는 `{"field": <점표기 경로>, "category": <카테고리>}`
    dict 의 리스트다 — 조용한 필터링이 아니라 사유를 담아 올라간다.
    """

    def __init__(self, violations):
        self.violations = list(violations)
        detail = "; ".join(
            "{}@{}".format(item["category"], item["field"])
            for item in self.violations
        )
        super().__init__(
            "corpus import rejected — sanitization validation failed: "
            "{}".format(detail)
        )


_KEY_SUFFIX = " (key)"

# 필드 라벨에 **이름 그대로** 쓸 수 있는 최상위 key — Shadow Case 스키마의
# 고정 key 집합. 모양 검사(`^[A-Za-z_][A-Za-z0-9_]{0,31}$`)를 쓰다가 집합
# 검사로 바꿨다 (security review Low-1, 2회차): 모양 검사는 경로·이메일은
# 배제하지만 영숫자+밑줄로 이루어진 짧은 secret(토큰·액세스 키 ID)이나
# 사용자명이 섞인 식별자를 통과시켜, 손수 조립한 dict 를 검증에 넘기는
# 경로에서 그 이름이 거부 사유로 되뿜어졌다. 라벨의 진단 가치는 "스키마
# key 일 때" 만 나오므로 모양 검사가 그 위에 얹어주는 것이 없다.
_SAFE_TOP_LEVEL_KEYS = frozenset(
    {
        "event",
        "facts",
        "command",
        "project_state",
        "v1_decision",
        "v1_reason",
        "captured_at",
    }
)


def _iter_string_fields(value, path="", depth=0):
    """문자열 leaf 를 전부 낸다 — **mapping key 도 leaf 다**.

    key 를 빼면 `{"/Users/alice/x": True}` 처럼 민감정보가 key 자리에 있는
    레코드가 검증을 그대로 통과한다 (code review High, 2026-08-10 — 실측
    재현). 정상 경로에서는 `capture.py` 가 key 도 정화하므로 여기 걸리는
    일이 없고, 이 검사는 capture 를 거치지 않은 손수 조립 case·과거 버전
    산출물의 재반입을 막는 최후 관문으로 작동한다.

    **라벨에는 caller 데이터가 절대 들어가지 않는다.** 최상위 key 만 —
    그것도 스키마가 정하는 고정 key 일 때만 — 이름을 쓰고, 그 아래 중첩 key 는 전부
    위치 표기(`<key:N>`)로 낸다. 거부 사유가 곧 유출 경로가 되기 때문이다
    (code review High 2회차: 민감한 key 원문이 예외 메시지로 반사 →
    security review Low-2: 그때의 수정이 "검출기가 잡는 만큼만 안전" 하도록
    검출 신호에 의존해, 검출 사각지대의 key 는 **값** 위반 라벨의 조상
    세그먼트로 여전히 새어나갔다). 라벨 생성 자체를 데이터와 분리하면 그
    결합이 원천적으로 사라진다 — 검출 규칙이 무엇을 놓치든 라벨은 안전하다.

    최상위 key 는 Shadow Case 스키마가 정하는 고정 이름이라 caller 데이터가
    아니며, 진단에 실제로 필요한 정보(`facts` 인지 `command` 인지)도 거기
    담긴다.
    """
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for index, (key, sub) in enumerate(value.items()):
            if depth == 0 and key in _SAFE_TOP_LEVEL_KEYS:
                segment = key
            else:
                segment = "<key:{}>".format(index)
            sub_path = "{}.{}".format(path, segment) if path else segment
            if isinstance(key, str):
                yield sub_path + _KEY_SUFFIX, key
            for item in _iter_string_fields(sub, sub_path, depth + 1):
                yield item
    elif isinstance(value, (list, tuple)):
        for index, sub in enumerate(value):
            sub_path = "{}[{}]".format(path, index)
            for item in _iter_string_fields(sub, sub_path, depth + 1):
                yield item


def find_violations(case_dict):
    """`case_dict` (직렬화된 Shadow Case) 전체를 스캔해 위반 목록을 낸다.

    빈 리스트 = 통과. 문자열 leaf 값 전부(중첩 dict/list 포함)를
    순회하며 4개 신호(길이 상한 / masking SSOT 변화 / email / private
    path) 를 검사한다 — 길이 상한만 예외적으로 **배타적**이다(아래
    참조), 나머지 3개는 한 필드가 여러 카테고리에 동시에 걸릴 수 있다
    (각각 별도 항목으로 보고).

    길이 상한(`MAX_FIELD_CHARS`) 초과 필드는 그 즉시 `CATEGORY_
    OVERSIZED_FIELD` 하나만 보고하고 나머지 3개 정규식 스캔은 **생략**
    한다(`continue`) — 이유는 두 가지: (1) 어차피 이 레코드는 오버사이즈
    하나만으로도 전체 반입이 거부되므로 추가 카테고리를 더 알아내는
    실익이 없다. (2) 정규식이 전부 선형(O(n))으로 수정됐어도(High-2),
    향후 회귀로 다시 비선형이 될 가능성에 대한 방어적 격리 — 상한을
    넘는 값에는 애초에 무거운 정규식을 돌리지 않는다(용량 상한 자체가
    ReDoS 방어의 한 겹이기도 하다).
    """
    violations = []
    for label, text in _iter_string_fields(case_dict):
        if not text:
            continue
        if len(text) > MAX_FIELD_CHARS:
            violations.append(
                {"field": label, "category": CATEGORY_OVERSIZED_FIELD}
            )
            continue
        if masking.mask(text) != text:
            violations.append({"field": label, "category": CATEGORY_CREDENTIAL})
        if _contains_email(text):
            violations.append({"field": label, "category": CATEGORY_EMAIL})
        if paths.contains_private_path(text):
            violations.append(
                {"field": label, "category": CATEGORY_PRIVATE_PATH}
            )
    return violations


def validate_case(case):
    """`case` (ShadowCase 또는 dict) 의 위반 목록을 돌려준다 (순수 함수)."""
    case_dict = case.to_dict() if hasattr(case, "to_dict") else dict(case)
    return find_violations(case_dict)


def import_case(case, project_root):
    """Sanitization Validation 통과 시에만 corpus 에 append 한다.

    실패하면 `CorpusImportRejected` 를 올리고 **아무 것도 쓰지 않는다**
    — 거부는 침묵 필터링이 아니라 예외로 드러난다 (호출부가 사유를
    받아 처리/기록할 수 있게).

    저장은 `platform.storage.local.LocalStateRoot` 의 0600 계약을
    재사용한다 (Task 2.5 SSOT — 이 모듈은 저장 권한 계약을 새로 만들지
    않는다). 반환값은 corpus 파일의 절대 경로다.
    """
    case_dict = case.to_dict() if hasattr(case, "to_dict") else dict(case)
    violations = find_violations(case_dict)
    if violations:
        raise CorpusImportRejected(violations)

    root = storage_local.LocalStateRoot(project_root)
    handle = root.open_log(name=CORPUS_FILENAME)
    try:
        handle.write(json.dumps(case_dict, ensure_ascii=False, sort_keys=True))
        handle.write("\n")
    finally:
        handle.close()
    return root.log_path(CORPUS_FILENAME)
