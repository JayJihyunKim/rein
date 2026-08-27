"""마스킹 엔진 SSOT — Shadow sanitization + 차단 로그 redaction 공용.

plan Task 2.6 (p2-masking) / spec §5.5 [B-5] "raw 로그 마스킹 정교화 → v2 흡수":
Shadow Sanitization (spec §6.4, Capture 단계부터 masked representation) 과
차단 로그 redaction 이 규칙을 각자 들고 갈라지지 않도록, 마스킹 규칙은 이
모듈 한 곳에만 산다. 두 소비자 인터페이스 `sanitize()` / `redact()` 는 동일
입력에 항상 동일 결과를 낸다 (계약 테스트: tests/unit/test_masking_engine.py).

v1 이식: `plugins/rein-core/hooks/lib/rein-log-block.py` 의 `_MASK_PATTERNS`
r2 케이스 5건 (v1.6.6 안전 릴리스에서 정착) —
  1. authorization header value        (`Authorization: Bearer x` / `authorization=x`)
  2. 민감 keyword key=value / key: value (underscore 포함 식별자: `GITHUB_TOKEN=`)
  3. URL credential                    (`scheme://user:pw@host`)
  4. basic-auth flag value             (`-u user:pw` / `--user user:pw`, colon 필수)
  5. standalone bearer token           (`bearer x`)

v1 백로그 정교화 흡수 (신규):
  - 옵션 부착형: `--password s3cret` (공백 분리), `--token=x` (= 부착 — v1 규칙
    2 가 커버, 클래스로 명시 테스트), `-ps3cret` (glued — mysql 계열·sshpass 등
    알려진 password-taking 명령 문맥에서만: `find -print` 오탐 방지).
  - URL credential 빈 username 허용 (`redis://:pw@host`).
  - 화이트리스트 오탐 방지: 값 없는 flag (`--password-stdin` — 구조적으로
    불일치), 문서 예시 placeholder 값 (`<your-password>`, `$VAR`, `${VAR}`,
    `***`) 은 마스킹하지 않는다. 식별자 화이트리스트 (`--author` 의 `auth`
    키워드 오탐) 포함.

보안 리뷰 수리 이력 (URL credential, v2 — 같은 결함 클래스 4회 반복 후
통합 리팩터): (1) High — 콜론 형태(`user:pw@host`)만 잡고 콜론 없는 단일
토큰 형태(`scheme://TOKEN@host`, spec §6.4 canonical 예시 형태 자체)를
전혀 못 잡던 갭 (소비자별 우회는 비대칭이라 다른 소비자·필드·복합 명령
경로를 못 덮는다는 판정으로 SSOT 직접 수리). (2) Medium — 다중 `@`
세그먼트(`alice@TOKEN@host`)를 첫 구간만 치환하던 결함. (3) Medium —
두 규칙(콜론형/token형)이 서로 다른 앵커·문자클래스를 쓰다 보니 혼합
체인(`TOKEN@user:pw@host`)에서 어느 쪽도 전체를 못 잡던 경계의 틈. 세
번째 재발 시점에 개별 패치 대신 **userinfo 파싱을 `_URL_CREDENTIAL`
하나로 통합**했다 — 상세 설계 근거·ReDoS 분석은 아래 규칙 정의부 주석
참조.

보안 리뷰 수리 (2026-08-09, capture.py 소비 경로 실사용 재현) —
High-1: 구분자(`=`/`:`/`--flag `) 없이 자연어 문장에 등장하는 `token X`/
`password X` 형태(예: 차단 사유 메시지 `"blocked: token ghp_... detected"`)
가 기존 규칙 전부의 사각지대였다. 신규 `_BARE_KEYWORD_VALUE` 규칙 +
`_looks_like_secret_value()` 값 형태 휴리스틱(길이/숫자/구두점/대소문자
혼용)으로 "keyword 다음 단어가 산문인지 실제 값인지" 를 구분해서만
마스킹한다 — 상세 근거·오탐 경계(`password reset`/`token bucket`/
`secret sauce` 미마스킹 고정)는 규칙 정의부 주석 참조.
Medium-3: URL credential 콜론형에서 password 만 placeholder 판정하고
username 은 검사하지 않아, password 가 `${VAR}` 이고 username 자리에
실제 secret 이 오면 전체가 미마스킹됐다. username 쪽도 placeholder 판정
+ 값 형태 휴리스틱으로 검사하도록 `_sub_url_credential` 수정 — 상세는
그 함수 근처 주석 참조.

의도적 미대응 (Low-Medium, 재리뷰 판단 위임 항목) — scp 형
`TOKEN@host:path` (`://` 없음): 표준 git scp 문법은 고정 시스템 사용자
(`git@host:`)를 쓰므로 이 자리에 실제 secret 이 올 현실성이 낮은 반면,
`user@host:path` 형태 자체는 ssh 프롬프트(`user@host:~$`)·이메일 뒤 경로
표기 등 일상적으로 매우 흔해 blanket 규칙 추가 시 오탐(과잉 마스킹) 위험이
마스킹 실익보다 크다고 판단해 엔진에 추가하지 않는다. 후속 항목 — 좁게
스코프를 잡을 근거(예: 알려진 git 명령 직후 + 토큰 접두사 화이트리스트)가
생기면 재검토 (알려진 한계 회귀 fixture: `URL_CREDENTIAL_SCP_FORM_KNOWN_GAP`
in tests/unit/test_masking_engine.py).

제외 — 엔진 대상 아님 (v1 잔여 케이스, 소비자 소유):
  - 추적 레코드 태깅 (`<verb> #<sha12>` 표현, safe_command_repr) —
    v1 rein-log-block.py / v2 Shadow capture (Task 2.7) 소유.
  - raw 로그 회전 (RAW_ROTATE_*) — 로그 writer 소유.
  - gitignore·0600 저장 정책 — storage 계층 (Task 2.5) 소유.

방향: v1 계승의 fail-closed — 모호하면 과잉 마스킹을 허용한다 (`tokenize=`
류 lookalike 포함). 화이트리스트는 "값이 존재하지 않거나 이미 비밀이 아닌"
명백한 오탐만 좁게 보존한다. stdlib (re) 만 사용.
"""
import re

__all__ = ["MASK_TOKEN", "mask", "redact", "sanitize"]

MASK_TOKEN = "<REDACTED>"

# 문서 예시 placeholder 형태 — 이미 비밀 값이 아니므로 마스킹하지 않는다.
# `<REDACTED>` 자신도 `<...>` 형태에 포함되어 멱등성이 성립한다.
_PLACEHOLDER = re.compile(
    r"^(?:<[^<>\s]+>"                      # <your-password>, <TOKEN>, <REDACTED>
    r"|\$[A-Za-z_][A-Za-z0-9_]*"           # $GITHUB_TOKEN
    r"|\$\{[A-Za-z_][A-Za-z0-9_]*\}"       # ${GITHUB_TOKEN}
    r"|\*{3,})$"                           # ***
)

# 민감 keyword 를 포함하지만 값이 비밀이 아닌 식별자 (선행/후행 `-` 제거 후 비교).
_SAFE_IDENTIFIERS = frozenset({"author", "authors"})

_AUTH_SCHEME_WORDS = frozenset({"bearer", "basic"})


def _is_placeholder(value):
    return bool(_PLACEHOLDER.match(value))


# --- 값 형태(shape) 휴리스틱 — 자연어 구분자 없는 케이스 전용 ------------
#
# 2026-08-09 보안 리뷰 High-1 / Medium-3 공용. 구분자(`=`/`:`/`--flag `)가
# 있는 케이스는 "keyword 바로 뒤에 오는 토큰이 곧 값"이라는 구조적 신호가
# 이미 확실하므로 값의 생김새를 볼 필요가 없다 — 구조 자체가 신호다.
# 반면 (a) 자연어 문장 속 `token X`/`password X` 처럼 구분자가 아예 없는
# 형태와 (b) URL userinfo 콜론형에서 password 가 placeholder 일 때
# username 쪽이 진짜 secret 인지 판정해야 하는 형태는, 구조만으로는 "이
# 다음 단어가 값인지 그냥 문장의 일부인지" 를 구분할 수 없다 — `token
# bucket`(자연어)과 `token ghp_abc123`(실제 값)은 문법상 동일한 모양이다.
# 그래서 이 두 곳에서만 값의 "생김새"(entropy 대용 — 길이/숫자 포함
# 여부/문자 구성)를 근거로 판단한다.
#
# 임계값 근거:
#   - `_MIN_LEN`(6) 미만이면 판단 보류(= secret 아님으로 취급) — 영어
#     일반명사 다수가 이 길이 이하다(`is`, `reset`(5), `sauce`(5),
#     `bucket`(6 — 경계값도 아래 조건에서 전부 걸러짐). 6자 미만에서
#     digit/구두점/대소문자 혼용 없이 secret 을 자연어와 구분할 근거가
#     없다고 판단해 과탐(오탐) 쪽을 포기한다 — 이 프로젝트의 fail-closed
#     방향(모호하면 과잉 마스킹)과 반대로 보이지만, 이 두 소비처는 이미
#     "구분자 없음/placeholder 존재" 라는 약한 신호 뒤에 오는 **추가**
#     필터이므로, 짧은 값까지 전부 마스킹하면 산문이 통째로 못 쓰게 된다
#     (리뷰 요구사항 그 자체 — `password reset`/`token bucket`/`secret
#     sauce`/`the password is wrong` 과잉 마스킹 금지). 알려진 한계로
#     문서화하고 회귀 테스트로 고정한다 (아래 테스트 참조).
#   - `_LONG_LEN`(16) 이상이면 구성과 무관하게 secret 취급 — 영어 문장에
#     구분자 없이 등장하는 단일 "단어"가 16자 이상인 경우는 드물고
#     (긴 합성어 오탐 가능성은 인지하되, 짧은 값 놓치는 위험보다 낫다는
#     판단), 실제 토큰(`ghp_...`, JWT 조각 등)은 흔히 이보다 길다.
#   - 6~15자 구간은 숫자 포함/구두점 포함/camelCase 류 대소문자 혼용 중
#     하나라도 있으면 secret 취급 — 평범한 영어 단어는 대개 소문자
#     전부이고 숫자·`_`/`-`/`.`/`+` 를 포함하지 않는다.
_BARE_VALUE_MIN_LEN = 6
_BARE_VALUE_LONG_LEN = 16
_BARE_VALUE_PUNCTUATION = frozenset("_-./+")


def _looks_like_secret_value(value):
    """자연어 산문과 secret 값을 길이/구성으로 구분하는 보수적 휴리스틱.

    True 라고 반드시 secret 인 것도, False 라고 반드시 안전한 것도 아니다
    — "구분자 없음" 이라는 약한 신호를 보강하는 2차 필터일 뿐이다. 알려진
    한계: 6자 미만 실제 secret(false negative), 16자 이상 단일 영단어
    (false positive, 실사용 텍스트에서 드묾) — 둘 다 회귀 테스트로 고정.
    """
    if len(value) < _BARE_VALUE_MIN_LEN:
        return False
    if len(value) >= _BARE_VALUE_LONG_LEN:
        return True
    if any(ch.isdigit() for ch in value):
        return True
    if any(ch in _BARE_VALUE_PUNCTUATION for ch in value):
        return True
    rest = value[1:]
    if any(ch.isupper() for ch in rest) and any(ch.islower() for ch in rest):
        return True
    return False


# --- 규칙 정의 (순서 유의: URL credential 이 key=value 보다 먼저 돌아
# `https://token:pw@host` 류에서 host 를 삼키지 않는다) ------------------------

# v1 case 1. Authorization header — value 전체 (scheme 단어 포함) 마스킹.
_AUTH_HEADER = re.compile(r"(?i)(authorization\s*[:=]\s*)(\S+(?:\s+\S+)?)")


def _sub_auth_header(m):
    words = m.group(2).split()
    if all(w.lower() in _AUTH_SCHEME_WORDS or _is_placeholder(w) for w in words):
        return m.group(0)
    return m.group(1) + MASK_TOKEN


# v1 case 3, 통합 리팩터 (2026-08-09 재재검증 Medium — 경계의 틈).
#
# 역사: 콜론형(`user:pw@host`)과 콜론 없는 token형(`TOKEN@host`)을 각자
# 다른 정규식으로 따로 유지하다가 같은 클래스의 결함이 네 번 반복됐다 —
# (1) 콜론형 password 의 `@` 미소비 ("Medium 2"), (2) 그 수리의 접두/접미
# 상한 부작용, (3) token형 신설 시 다중 `@` 미소비 재발, (4) 이번 — 두
# 규칙이 서로 다른 문법(콜론형은 `://` 직후 앵커, token형은 `:` 를
# 문자클래스에서 제외)을 쓰다 보니 "bare-token → colon-credential" 혼합
# 체인(`https://TOKEN@user:pw@host`)에서 **어느 쪽도 매치하지 못하거나
# 선두 세그먼트만 치환**했다 (직접 재현: `mask('https://ghp_BEARER123@'
# 'dbuser:REALFAKEPASSWORD456@internal-db-host/status')` 가
# `dbuser:REALFAKEPASSWORD456` 을 평문 잔존시켜 내부 호스트에서 디스크
# 기록까지 남았다).
#
# 개별 패치를 계속 덧대는 대신 userinfo 파싱을 한 곳으로 모은다 — URL
# 문법상 "`://` 직후부터 host 앞 **마지막** `@` 까지 전부"가 userinfo 의
# 정의 그 자체이므로, 콜론 유무·중간 `@` 개수와 무관하게 이 정의 하나로
# 순수 콜론형/순수 token형/다중 `@` 체인/혼합 체인을 전부 통일해서 잡는다.
#
# 정규식 `[^/\s]+` (host 경계인 `/`·공백만 제외 — `:`/`@` 모두 허용) 를
# greedy 로 최대한 삼킨 뒤 `@` 를 요구한다. greedy quantifier 는 실패하면
# 끝에서부터 한 글자씩 줄여가며 재시도하므로, 결과적으로 **가장 뒤쪽**
# `@` 에서 멈춘다 (userinfo/host 경계는 정의상 항상 마지막 `@`) — 규칙이
# 콜론 유무나 중간 `@` 개수를 몰라도 항상 올바른 지점에서 멈추는 이유다.
#
# placeholder 판정: 캡처된 userinfo 블록에 콜론이 있으면 **첫 번째** 콜론
# 기준으로 나눈다(username 은 콜론을 포함할 수 없다는 기존 문법을 그대로
# 계승). 콜론이 없으면(순수 token형) 블록 전체를 검사한다. 멱등 보장 —
# 이미 마스킹된 `<REDACTED>@host` 는 콜론이 없으므로 블록 전체 검사
# 경로를 타고, `<REDACTED>` 는 placeholder 패턴에 매치해 재마스킹하지
# 않는다.
#
# 2026-08-09 보안 리뷰 Medium-3 수정 — username 쪽도 검사한다. 이전엔
# password 세그먼트만 placeholder 패턴과 대조했다 — password 가
# `${DB_PASSWORD}` 같은 placeholder 이면 username 내용과 무관하게
# unchanged 를 반환했다. 그 결과 `postgres://ghp_REALSECRET:${DB_PASSWORD}
# @host/app` 처럼 password 가 placeholder 이고 username 자리에 실제
# secret 이 온 경우 전체가 미마스킹됐다(직접 재현, 리뷰어 실측).
#
# 단, password 판정과 동일하게 순수 `_is_placeholder` 매칭만 쓰면 기존
# 화이트리스트 fixture 가 깨진다 — `postgres://app:${DB_PASSWORD}@
# db.internal/app` 의 `app` 은 placeholder 패턴(`<...>`/`$VAR`/`${VAR}`/
# `***`)에 매치하지 않는 일반 사용자명이지만, 이 케이스는 여전히
# unchanged 가 맞다(문서 예시 — 실제 secret 이 없다). "placeholder 패턴
# 매치" 와 "일반 식별자(사용자명 등)" 를 구분해야 하므로, username 쪽은
# placeholder 패턴 매치 **또는** 위 `_looks_like_secret_value()` 로 secret
# 형태가 아니라고 판단되면(예: `app`, `alice` 처럼 짧고 숫자/구두점/
# camelCase 없는 일반 식별자) safe 로 본다. password 쪽은 기존과 동일하게
# `_is_placeholder` 만 본다(값 슬롯이므로 placeholder 가 아니면 기본
# 마스킹 — fail-closed 유지, username 만 형태 휴리스틱을 추가로 허용).
#
# ReDoS: 중첩 quantifier 없는 단일 `X+Y` 형태(X=`[^/\s]+`, Y=`@`) — 이전
# token형 규칙의 단일 세그먼트 케이스와 동일 구조라 동일하게 O(n) 이다.
# 오히려 다중 `@` 체인 하드닝에 썼던 `(?:@[^/\s:@]+)*` 중첩 star 를
# 걷어냈으므로 구조적으로 더 단순해졌다 — `@` 를 못 찾는 최악 케이스도
# 토큰을 한 번 삼킨 뒤 끝에서부터 선형으로 되짚는 것뿐이고, 되짚다가
# `@` 를 찾으면 그 자리에서 즉시 성공하므로(추가 재시도 없음) 2차
# 백트래킹이 없다 (스케일링 회귀 테스트로 실측 고정:
# `UrlCredentialTokenRedosScalingTest`, n=20k/40k/80k/200k 비율 ≈2.0,
# 혼합 체인 worst case 포함).
_URL_CREDENTIAL = re.compile(r"://([^/\s]+)@")


def _sub_url_credential(m):
    userinfo = m.group(1)
    if ":" in userinfo:
        username_part, _, password_part = userinfo.partition(":")
        password_safe = _is_placeholder(password_part)
        username_safe = _is_placeholder(username_part) or not _looks_like_secret_value(
            username_part
        )
        if password_safe and username_safe:
            return m.group(0)
    elif _is_placeholder(userinfo):
        return m.group(0)
    return "://" + MASK_TOKEN + "@"


# v1 case 4. -u/--user user:pw — colon 필수 (`useradd -u 1000` 불변).
# `://` 포함 값은 URL 규칙이 이미 credential 만 정밀 마스킹했으므로 건드리지
# 않는다 (`redis-cli -u redis://:pw@host` 에서 host 보존).
_BASIC_AUTH_FLAG = re.compile(r"(^|\s)(-u|--user)(\s+)([^\s:]+:\S+|:\S+)")


def _sub_basic_auth_flag(m):
    value = m.group(4)
    if "://" in value or _is_placeholder(value.split(":", 1)[1]):
        return m.group(0)
    return m.group(1) + m.group(2) + m.group(3) + MASK_TOKEN


# v1 case 5. standalone bearer — key=value 규칙보다 먼저 돌아
# `X-Auth: Bearer tok` 에서 scheme 만 마스킹되고 tok 이 남는 구멍을 막는다.
_BEARER = re.compile(r"(?i)\b(bearer)(\s+)(\S+)")


def _sub_bearer(m):
    if _is_placeholder(m.group(3)):
        return m.group(0)
    return m.group(1) + m.group(2) + MASK_TOKEN


# v1 case 2. 민감 keyword key=value / key: value.
# \b 미사용 의도 유지: \b 는 `_` 를 단어 문자로 취급해 `GITHUB_TOKEN=` /
# `AWS_SECRET_ACCESS_KEY=` 가 새기 때문 (v1 sonnet-fallback R1 High).
# `--token=x` / `--password=x` 부착형도 식별자 클래스의 `-` 로 함께 커버.
#
# v2 보안 리뷰 수리 (High + Medium 3/4):
#   - lead/trail 옵션 quote — JSON/직렬화 `"password":"..."` 는 키워드 직후
#     따옴표가 끼어 구분자(`[=:]`) 매칭이 실패해 완전 미마스킹이었다 (High).
#   - bare `pass`/`key`/`private[_-]?key` alternative 추가 (Medium 3/4).
#     letter-boundary lookaround (`(?<![A-Za-z])`/`(?![A-Za-z])`) 로 감싸
#     `compass=`/`passenger=`/`monkey=`/`keyboard=` 류 영문 단어 오탐을
#     차단한다 (`\b` 는 위 이유로 미사용 — 동일하게 언더스코어는 boundary
#     아님 취급되어 `DB_PASS=`/`private_key:` 는 정상 매칭된다).
#
# v2 재리뷰 수리 (High — ReDoS): 위 식별자 접두/접미를 무경계 `*` 로 두면
# 키워드가 매칭되지 않는 긴 영숫자 런에서 시작 위치마다 접두 길이를 전부
# 되짚어보는 2차 백트래킹이 발생한다 (`"x" * 40000` 이 56초, 2배 입력마다
# 4배 시간 — 실측 O(n^2)). 접두/접미 quantifier 에 상한을 둬 위치당 비용을
# 상수로 고정한다 (택 (a): finditer 앵커링 재구조화(택 (b))보다 diff 최소,
# 기존 그룹/치환 함수 구조를 그대로 보존).
#
# v2 재-재리뷰 수리 (High — 접두/접미 비대칭, 앞선 근거 정정): "실제 키
# 식별자가 32자를 넘길 이유 없다" 는 접두에는 맞지만 접미에는 **틀렸다**.
# `re.sub` 는 전체 매치 시작 위치를 좌에서 우로 옮겨가며 재시도하므로,
# 키워드 앞 prefix 가 상한을 넘겨도 그 초과분보다 더 오른쪽 (키워드에서
# 상한 이내) 위치부터 다시 시작해 매치가 성립한다 — prefix 캡처가 원래
# 식별자 전체를 담지 못해도 마스킹 자체는 정상 동작한다 (레이블 일부만
# 캡처에서 빠질 뿐). 반면 접미는 키워드 매치가 끝난 지점에 위치가
# **고정**되어 있어 시작 위치를 옮겨 회피할 수 없다 — 키워드 끝부터 `=`/`:`
# 까지의 실제 문자 수가 상한을 넘으면 그 지점에서 전체 매치가 **실패**하고,
# 결과적으로 `key=value` 전체가 마스킹 없이 그대로 노출된다 (재리뷰어 실측:
# `GITHUB_TOKEN_FOR_CI_DEPLOYMENT_PIPELINE_RUNNER_ACCOUNT=ghp_abcdef` 류
# 3건 전량 평문 노출 — 접미 42~60자, 구 상한 32 초과). 따라서 접두/접미를
# 비대칭으로 둔다: 접두는 32 유지(위치 이동으로 이미 안전), 접미는 128 로
# 확장(키워드 끝 ~ 구분자 사이 실사용 식별자 스니펫에 3~4배 여유 — 위 3건
# 실측 최대 60자 대비). 128 도 여전히 상수 상한이므로 위치당 비용은
# O(128)=O(1) 로 유지되어 ReDoS 방지 성질은 그대로 보존된다 (스케일링
# 회귀 테스트 참조 — 상한 확장 후에도 n/2n 비율 ≈2.0, 절대시간 병기).
_KEYWORD_VALUE = re.compile(
    r"(?i)(?P<lead>[\"']?)(?P<key>[A-Za-z0-9_-]{0,32}(?:token|secret|password|passwd|pwd|"
    r"api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential[s]?|auth|"
    r"(?<![A-Za-z])pass(?![A-Za-z])|(?<![A-Za-z])key(?![A-Za-z]))[A-Za-z0-9_-]{0,128})"
    r"(?P<trail>[\"']?)(?P<sep>\s*[=:]\s*)"
    r"(?:(?P<vq>[\"'])(?P<qval>.*?)(?P=vq)|(?P<val>\S+))"
)


def _sub_keyword_value(m):
    key = m.group("key")
    if key.strip("-").lower() in _SAFE_IDENTIFIERS:
        return m.group(0)
    value = m.group("qval") if m.group("qval") is not None else m.group("val")
    if _is_placeholder(value):
        return m.group(0)
    quote = m.group("vq") or ""
    return (
        m.group("lead") + key + m.group("trail") + m.group("sep")
        + quote + MASK_TOKEN + quote
    )


# 신규. 장 옵션 + 공백 분리 값 (`--password s3cret`). `--password-stdin` 은
# 옵션명 뒤가 공백이 아니라 `-` 이므로 구조적으로 불일치 (화이트리스트).
_OPTION_SPACE_VALUE = re.compile(
    r"(?i)(^|\s)(--(?:password|passwd|pwd|token|secret|api[-_]?key|apikey|"
    r"access[-_]?key|auth[-_]?token|credentials?))(\s+)(\S+)"
)


def _sub_option_space_value(m):
    value = m.group(4)
    if value.startswith("-") or _is_placeholder(value):
        return m.group(0)  # 다음 flag 이거나 placeholder — 값 아님.
    return m.group(1) + m.group(2) + m.group(3) + MASK_TOKEN


# 신규 (2026-08-09 보안 리뷰 High-1). 구분자(`=`/`:`/`--flag `) 없이
# 자연어 문장 속에 나타나는 `token X`/`password X` 형태. 재현: capture 의
# `v1_reason`(차단 사유 자연어 메시지)이
# `"blocked: token ghp_FAKETOKENabcdef1234567890 detected in argument"`
# 처럼 keyword 뒤에 값이 공백만으로 이어지면 기존 규칙 어디에도 안
# 걸려(구분자 없음 → `_KEYWORD_VALUE` 불일치, `--` 없음 → `_OPTION_SPACE_
# VALUE` 불일치, "bearer" 아님 → `_BEARER` 불일치) 그대로 디스크에 남았다
# (corpus.find_violations() 가 `mask() != text` 하나로 credential 신호를
# 재사용하므로 같은 사각지대를 그대로 상속 — capture.py docstring 의
# "facts/project_state/v1_reason 은 항상 마스킹 SSOT 로 걸러진다" 주장을
# 반증하는 결함).
#
# 오탐 경계가 핵심이다 — 구분자가 없다는 것은 "이 keyword 다음 단어가
# 정말 값인지, 그냥 문장의 일부인지" 를 구조만으로 알 수 없다는 뜻이다
# (`password reset`/`token bucket`/`secret sauce`/`the password is wrong`
# 은 keyword 바로 뒤에 일반 명사·동사가 오는 산문이지 key=value 가
# 아니다). 그래서 다음 단어를 무조건 마스킹하지 않고, `_looks_like_secret_
# value()` 값 형태 휴리스틱(길이/숫자/구두점/대소문자 혼용 — 정의 및
# 임계값 근거는 그 함수 docstring 참조)을 추가로 통과해야만 마스킹한다.
# 키워드 집합은 `_KEYWORD_VALUE` 전체가 아니라 **좁힌 부분집합**
# (`token`/`password`/`passwd`/`pwd`/`secret`/`credential(s)`/`api key`/
# `apikey`)만 쓴다 — bare `pass`/`key`/`auth` 는 자연어에서 지나치게 흔해
# (`key insight`, `auth flow`, `next pass`, `keyword`, `keystore`,
# `database`, `bypass`, `compass` 등, WHITELIST_UNCHANGED 기존 화이트리스트
# 항목 다수가 바로 이 부류다) 구분자 없는 문맥에 그대로 적용하면 오탐이
# 폭증한다 — 구분자가 있는 `_KEYWORD_VALUE` 는 letter-boundary lookaround
# 로 충분히 좁혀지지만, 자연어 문맥에서는 그 정도로 부족하다고 판단해
# 아예 후보 키워드 집합에서 제외한다.
#
# 값 형태 휴리스틱으로도 못 잡는 알려진 한계(예: `password Sesame` 처럼
# 6자 이상이지만 숫자/구두점/대소문자 혼용이 전혀 없는 실제 약한 패스워드)
# 는 명시적으로 미대응으로 남긴다 — fixture
# `BARE_KEYWORD_VALUE_SHORT_PLAIN_WORD_KNOWN_GAP` (test_masking_engine.py)
# 로 고정. 이 갭을 마스킹 신호만으로 메우는 것은 오탐 폭증과 trade-off
# 관계라 여기서 포기하고, corpus.py 쪽에 독립적인 보완책을 제안한다(값
# 형태와 무관하게 필드 길이 상한으로 corpus 크기 자체를 제한 — corpus.py
# `MAX_FIELD_CHARS`/`CATEGORY_OVERSIZED_FIELD` 참조. 이건 이 특정 갭을
# 직접 막지는 못하지만, "마스킹 신호 하나에만 의존하는 구조" 라는
# corpus.py 쪽 위험 자체를 완화한다).
_BARE_KEYWORD_VALUE = re.compile(
    r"(?i)(?<![A-Za-z0-9_-])(?P<keyword>token|password|passwd|pwd|secret|"
    r"credentials?|api[ _-]?key|apikey)(?![A-Za-z0-9_-])"
    r"(?P<sep>\s+)(?P<value>\S+)"
)


def _sub_bare_keyword_value(m):
    value = m.group("value")
    if _is_placeholder(value) or not _looks_like_secret_value(value):
        return m.group(0)
    return m.group("keyword") + m.group("sep") + MASK_TOKEN


# 신규. 단 옵션 -p 부착/분리 값 — 알려진 password-taking 명령 문맥에서만
# (`mysql -ps3cret`, `sshpass -p x`). 무문맥 적용은 `find -print` 류 오탐.
_SHORT_P_CONTEXT = re.compile(
    r"(?i)\b((?:mysql|mysqldump|mysqladmin|mariadb|sshpass)\b"
    r"[^|;&\n]*?\s-p)(\s?)(\S+)"
)


def _sub_short_p(m):
    value = m.group(3)
    if value.startswith("-") or _is_placeholder(value):
        return m.group(0)
    return m.group(1) + m.group(2) + MASK_TOKEN


_RULES = [
    (_AUTH_HEADER, _sub_auth_header),
    (_URL_CREDENTIAL, _sub_url_credential),
    (_BASIC_AUTH_FLAG, _sub_basic_auth_flag),
    (_BEARER, _sub_bearer),
    (_KEYWORD_VALUE, _sub_keyword_value),
    (_OPTION_SPACE_VALUE, _sub_option_space_value),
    (_SHORT_P_CONTEXT, _sub_short_p),
    (_BARE_KEYWORD_VALUE, _sub_bare_keyword_value),
]


def mask(text):
    """모든 마스킹 규칙을 순서대로 적용한 결과를 돌려준다 (멱등)."""
    for pattern, sub_fn in _RULES:
        text = pattern.sub(sub_fn, text)
    return text


def sanitize(text):
    """Shadow sanitization 소비자 진입점 (spec §6.4) — `mask()` 와 동일 결과."""
    return mask(text)


def redact(text):
    """차단 로그 redaction 소비자 진입점 — `mask()` 와 동일 결과."""
    return mask(text)
