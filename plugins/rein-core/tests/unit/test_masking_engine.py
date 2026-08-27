"""plan Task 2.6 (p2-masking) — 마스킹 엔진 SSOT 계약 테스트.

고정하는 계약 (spec §5.5 [B-5] 첫 항목 + §6.4 Sanitization Validation):
- v1 r2 마스킹 케이스 5건 (hooks/lib/rein-log-block.py `_MASK_PATTERNS`) 이 그대로
  마스킹된다 — authorization header / keyword env-var / URL credential /
  basic-auth flag / standalone bearer.
- 신규 3클래스 각각 fixture 테스트 (SPIKE-2 보안 리뷰 권고 — 클래스별 실측):
  옵션 부착형 (`--password s3cret`, `-ps3cret`, `--token=...`) / URL credential /
  env-var 형 (`TOKEN=` / `SECRET=` / `PASSWORD=`).
- 화이트리스트 오탐 방지: 값 없는 flag (`--password-stdin`), 문서 예시
  placeholder (`<your-password>`, `$VAR`, `${VAR}`, `***`) 는 마스킹하지 않는다.
- 두 소비자 인터페이스 (Shadow `sanitize` / 차단 로그 `redact`) 는 동일 입력에
  동일 결과 — 그리고 멱등 (마스킹 결과 재마스킹 = 불변).
- v1 잔여 케이스 (태깅 `#<sha12>`·raw 회전·gitignore/0600 계열) 는 엔진 표면에
  존재하지 않는다 — 소비자 (rein-log-block.py / Task 2.5 storage) 소유.

주의: 본 파일의 모든 secret 값은 명백한 가짜 상수다 (fake- 접두 / s3cret 류).
실제 secret 형태 (실서비스 토큰 prefix, base64 blob 등) 는 사용 금지.
"""
import os
import sys
import time
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.shadow import masking  # noqa: E402
from rein.shadow.masking import MASK_TOKEN, mask, redact, sanitize  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures. (input, expected) — expected 가 input 과 같으면 "불변" 계약.
# ---------------------------------------------------------------------------

V1_PORTED_CASES = [
    # v1 case 2 — keyword env-var (underscore 포함 식별자: sonnet-fallback R1 High).
    ("GITHUB_TOKEN=fake-gh-value ./deploy.sh",
     "GITHUB_TOKEN=%s ./deploy.sh" % MASK_TOKEN),
    ("AWS_SECRET_ACCESS_KEY=fake-aws-value aws s3 ls",
     "AWS_SECRET_ACCESS_KEY=%s aws s3 ls" % MASK_TOKEN),
    # v1 case 3 — URL credential.
    ("git push https://alice:fakepw@github.com/org/repo.git",
     "git push https://%s@github.com/org/repo.git" % MASK_TOKEN),
    # v1 case 4 — basic-auth flag (colon 필수).
    ("curl -u alice:fakepw https://api.example.com/v1",
     "curl -u %s https://api.example.com/v1" % MASK_TOKEN),
    # v1 case 5 — standalone bearer.
    ("echo bearer fake-bearer-tok",
     "echo bearer %s" % MASK_TOKEN),
]

ATTACHED_OPTION_FIXTURES = [
    # 장 옵션 + 공백 분리 값.
    ("docker login --password s3cret registry.example.com",
     "docker login --password %s registry.example.com" % MASK_TOKEN),
    # 장 옵션 + `=` 부착.
    ("helm repo add stable https://charts.example.com --password=s3cret",
     "helm repo add stable https://charts.example.com --password=%s" % MASK_TOKEN),
    ("vault login --token=fake-root-tok",
     "vault login --token=%s" % MASK_TOKEN),
    ("gh auth login --token fake-gh-tok",
     "gh auth login --token %s" % MASK_TOKEN),
    ("tool --api-key fake-api-key-value",
     "tool --api-key %s" % MASK_TOKEN),
    # 단 옵션 glued 값 — 알려진 password-taking 명령 문맥에서만.
    ("mysql -u root -ps3cret appdb",
     "mysql -u root -p%s appdb" % MASK_TOKEN),
    ("sshpass -p s3cret ssh deploy@bastion",
     "sshpass -p %s ssh deploy@bastion" % MASK_TOKEN),
]

URL_CREDENTIAL_FIXTURES = [
    ("git push https://alice:fakepw@github.com/org/repo.git",
     "git push https://%s@github.com/org/repo.git" % MASK_TOKEN),
    ("psql postgres://admin:fakepw@db.internal:5432/app",
     "psql postgres://%s@db.internal:5432/app" % MASK_TOKEN),
    # 빈 username (redis 형) 도 credential 로 취급.
    ("redis-cli -u redis://:fakepw@cache.local:6379",
     "redis-cli -u redis://%s@cache.local:6379" % MASK_TOKEN),
    # credential 없는 URL 은 불변.
    ("git push https://github.com/org/repo.git",
     "git push https://github.com/org/repo.git"),
    # placeholder credential 은 불변 (문서 예시).
    ("psql postgres://app:${DB_PASSWORD}@db.internal/app",
     "psql postgres://app:${DB_PASSWORD}@db.internal/app"),
    # Medium 2 — 비밀번호 자체에 `@` 가 포함되면 마지막 `@` 를 host 구분자로
    # 삼아야 한다 (greedy). 이전엔 첫 `@` 에서 끊겨 `ssw0rd@host` 가 노출됐다.
    ("curl https://user:p@ssw0rd@host/path",
     "curl https://%s@host/path" % MASK_TOKEN),
    ("curl https://user:a@b@c@host/path",
     "curl https://%s@host/path" % MASK_TOKEN),
]

# 신규 — 보안 리뷰 High. 콜론 없는 단일 토큰 userinfo (`scheme://TOKEN@host`)
# 는 spec §6.4 canonical 예시 형태 자체지만 기존 콜론 전제 규칙 (`user:pw@host`)
# 은 콜론이 없으면 아예 매치하지 않아 토큰이 그대로 노출됐다. Task 2.7
# 워커의 capture 단계 URL 인자 축약 우회는 다른 소비자(차단 로그 redact)·
# 다른 필드를 못 덮으므로 SSOT(`mask()`) 자체를 고친다 — 내부 호스트(IP) /
# 복합 명령에 섞인 형태까지 고정한다.
URL_CREDENTIAL_TOKEN_FIXTURES = [
    ("git push https://ghp_FAKETOKEN123@internal-gitlab/org/repo.git",
     "git push https://%s@internal-gitlab/org/repo.git" % MASK_TOKEN),
    # 내부 호스트 (IP) 형태.
    ("curl https://ghp_FAKETOKEN456@10.0.0.5/api/v1/status",
     "curl https://%s@10.0.0.5/api/v1/status" % MASK_TOKEN),
    # 복합 명령 — 다른 secret 규칙과 섞인 경우 둘 다 마스킹.
    ("AWS_SECRET_ACCESS_KEY=fake1 git push https://ghp_FAKETOKEN789@github.com/org/repo.git",
     "AWS_SECRET_ACCESS_KEY=%s git push https://%s@github.com/org/repo.git"
     % (MASK_TOKEN, MASK_TOKEN)),
    # placeholder 는 불변 (문서 예시).
    ("git push https://${GITHUB_TOKEN}@github.com/org/repo.git",
     "git push https://${GITHUB_TOKEN}@github.com/org/repo.git"),
]

# 오탐 경계 — userinfo 가 없거나 `@` 가 credential 이 아닌 문맥.
URL_CREDENTIAL_TOKEN_WHITELIST = [
    # userinfo 없는 일반 URL.
    "git clone https://github.com/org/repo.git",
    # 경로 안의 `@` (핸들/프로필 등) — userinfo 아님, `://` 직후가 아님.
    "curl https://example.com/a@b/profile",
    # 평문 이메일 — `://` scheme 이 없다.
    "contact devops@example.com for access",
    "mailto:devops@example.com",
]

# 재리뷰 Medium — 다중 `@` 구간 미소비. 형제 규칙 `_URL_CREDENTIAL` 이 이미
# `(?:@[^/\s@]+)*` greedy 반복으로 고친 결함 유형 (파일 주석 "Medium 2")을
# token-form 에도 동일 적용한다. 직접 재현: `mask('curl https://alice@'
# 'ghp_SECONDFAKE123@host/path')` 가 이전엔 'alice@' 만 치환하고
# 'ghp_SECONDFAKE123@' 를 평문 잔존시켜 내부 호스트 조합에서 shadow-corpus
# 디스크 기록에 그대로 남았다.
URL_CREDENTIAL_TOKEN_MULTI_AT_FIXTURES = [
    # 2단 — 두 번째 세그먼트까지 전부 마스킹, host 는 보존.
    ("curl https://alice@ghp_SECONDFAKE123@host/path",
     "curl https://%s@host/path" % MASK_TOKEN),
    # 3단 — 세 세그먼트 전부 마스킹.
    ("curl https://a@b@ghp_THIRDFAKE456@host/path",
     "curl https://%s@host/path" % MASK_TOKEN),
    # 내부 호스트(IP) 조합 + 2단.
    ("curl https://svc@ghp_INTERNALFAKE789@10.0.0.5/status",
     "curl https://%s@10.0.0.5/status" % MASK_TOKEN),
    # 복합 명령 — 다른 secret 규칙과 섞인 다단 URL.
    ("AWS_SECRET_ACCESS_KEY=fake1 curl https://svc@ghp_MULTIFAKE000@internal-gitlab/x",
     "AWS_SECRET_ACCESS_KEY=%s curl https://%s@internal-gitlab/x"
     % (MASK_TOKEN, MASK_TOKEN)),
]

# Low-Medium — scp 형 `TOKEN@host:path` (`://` 없음). 리뷰어가 판단을
# 위임했다: 표준 git scp 문법은 고정 시스템 사용자(`git@host:`)를 쓰므로
# 실제 secret 이 이 자리에 오는 현실성이 낮은 반면, `user@host:path` 형태는
# ssh 프롬프트 표시(`user@host:~$`)·평문 이메일 뒤에 경로가 붙는 케이스 등
# 일상적으로 매우 흔해 blanket 규칙을 추가하면 오탐(과잉 마스킹) 위험이
# 마스킹 실익보다 크다고 판단해 **엔진에 추가하지 않는다** (후속 항목 —
# 좁게 스코프 잡을 근거(예: 알려진 git push/clone 명령 직후 + 토큰 접두사
# 패턴 화이트리스트)가 생기면 별도 규칙으로 재검토). 아래는 이 결정의 알려진
# 한계를 고정하는 회귀 fixture — 마스킹되지 않는 것이 **의도된 현재 동작**.
URL_CREDENTIAL_SCP_FORM_KNOWN_GAP = [
    # 알려진 갭 — 내부 호스트에서 `://` 없는 scp 형은 현재 미마스킹.
    "somehelper ghp_FAKE@internal-gitlab:org/repo.git",
    # 대조군 — 표준 git scp 문법 (고정 시스템 사용자, 원래 secret 아님).
    "git clone git@github.com:org/repo.git",
    # 대조군 — ssh 프롬프트/일반 표기 (secret 아님, 오탐 방지 대상).
    "deploy@bastion:~$ whoami",
]

# 재재검증 Medium — 형제 규칙(콜론형) ↔ token형 규칙 "경계의 틈". 콜론형은
# `://` 직후에 앵커돼 있어 앞에 bare-token 세그먼트가 오면 매치 자체가
# 안 되고, token형은 문자클래스에서 `:` 를 빼서 greedy 체인이 콜론 포함
# 세그먼트에서 멈춘 뒤 backtracking 으로 선두 세그먼트만 마스킹하고 만다.
# 직접 재현: `mask('https://ghp_BEARER123@dbuser:REALFAKEPASSWORD456@'
# 'internal-db-host/status')` 가 'dbuser:REALFAKEPASSWORD456' 를 평문
# 잔존시켜 내부 호스트에서 디스크 기록까지 남는다 (리뷰어 실측). userinfo
# 전체(마지막 `@` 앞 전부)를 하나로 마스킹해야 한다 — 세그먼트별 부분
# 마스킹은 이 클래스의 반복 결함 원인이므로 이번엔 파싱을 한 곳으로
# 통합한다 (masking.py `_URL_CREDENTIAL` 리팩터 docstring 참조).
URL_CREDENTIAL_MIXED_CHAIN_FIXTURES = [
    # token → colon 순서 (재현 그대로).
    ("https://ghp_BEARER123@dbuser:REALFAKEPASSWORD456@internal-db-host/status",
     "https://%s@internal-db-host/status" % MASK_TOKEN),
    # colon → token 순서 (뒤바뀐 경우).
    ("https://dbuser:REALFAKEPASSWORD456@ghp_BEARER123@internal-db-host/status",
     "https://%s@internal-db-host/status" % MASK_TOKEN),
    # 3단 혼합 — token → colon → token.
    ("https://a@user:pw@ghp_TOKEN789@internal-host/path",
     "https://%s@internal-host/path" % MASK_TOKEN),
    # 내부 호스트(IP) 조합.
    ("curl https://svc@dbuser:REALFAKEPW999@10.0.0.5/status",
     "curl https://%s@10.0.0.5/status" % MASK_TOKEN),
    # 복합 명령 — 다른 secret 규칙과 섞인 혼합 체인.
    ("AWS_SECRET_ACCESS_KEY=fake1 curl https://ghp_TOK@dbuser:pw999@internal-gitlab/x",
     "AWS_SECRET_ACCESS_KEY=%s curl https://%s@internal-gitlab/x"
     % (MASK_TOKEN, MASK_TOKEN)),
]

# 신규 (2026-08-09 보안 리뷰 High-1) — 구분자(`=`/`:`/`--flag `) 없이
# 자연어 문장 속에 나타나는 `token X`/`password X` 형태. 직접 재현:
# capture 의 v1_reason(차단 사유 자연어 메시지)이 이 형태로 토큰을 실어
# 나르면 기존 규칙 전부의 사각지대였다(corpus.find_violations() 가
# `mask() != text` 하나로 credential 신호를 재사용하므로 같은 사각지대를
# 그대로 상속 — capture.py docstring 의 "facts/project_state/v1_reason
# 은 항상 마스킹 SSOT 로 걸러진다" 주장을 반증하는 결함이었다).
BARE_KEYWORD_VALUE_FIXTURES = [
    # 리뷰어 실측 그대로.
    ("blocked: token ghp_FAKETOKENabcdef1234567890 detected in argument",
     "blocked: token %s detected in argument" % MASK_TOKEN),
    # 숫자 포함 — 짧아도(6~15자) 마스킹.
    ("password Str0ngPassw0rd!",
     "password %s" % MASK_TOKEN),
    # camelCase(대소문자 혼용, 숫자 없음, 6~15자) — mixed-case 신호.
    ("secret myToken",
     "secret %s" % MASK_TOKEN),
    # 구두점 포함(하이픈) + 숫자.
    ("api key sk-live-abcdef1234",
     "api key %s" % MASK_TOKEN),
    ("apikey sk_live_abcdef1234567890",
     "apikey %s" % MASK_TOKEN),
    ("credential fake-cred-99",
     "credential %s" % MASK_TOKEN),
    # 16자 이상 — 구성과 무관하게 secret 취급(길이만으로).
    ("token abcdefghijklmnop",
     "token %s" % MASK_TOKEN),
]

# 오탐 경계가 핵심 — 리뷰가 명시적으로 지목한 산문 4건 + 추가 경계 확인.
# keyword 바로 뒤에 일반 명사/동사가 오는 문장은 구분자가 없다는 이유만
# 으로 마스킹하면 로그가 못 쓰게 된다.
BARE_KEYWORD_VALUE_WHITELIST = [
    "password reset",
    "token bucket",
    "secret sauce",
    "the password is wrong",
    "api key configuration process",
    "secret meeting notes",
    "credential store lookup",
    "the token pool is exhausted",
]

# 알려진 한계(명시적 미대응, scp 형과 같은 선례) — 값 형태 휴리스틱이
# 6자 이상이면서 숫자/구두점/대소문자 혼용이 전혀 없는 짧은 평문 단어형
# 실제 secret 을 구분하지 못한다. 오탐(산문 과잉 마스킹) 방지와
# trade-off 관계이므로 여기서 포기하고 회귀로 고정 — 마스킹 신호에만
# 의존하지 않는 보완책은 corpus.py `MAX_FIELD_CHARS`(길이 상한, 이
# 갭 자체를 막지는 못하지만 "마스킹 신호 하나에만 의존하는 구조" 라는
# corpus.py 쪽 위험을 완화)로 별도 제안했다(masking.py `_BARE_KEYWORD_
# VALUE` 정의부 주석 참조).
BARE_KEYWORD_VALUE_SHORT_PLAIN_WORD_KNOWN_GAP = [
    "password Sesame",
]

# Medium-3 — URL credential 콜론형에서 password 만 placeholder 판정하고
# username 은 검사하지 않던 결함. password 가 `${VAR}` 이고 username
# 자리에 실제 secret 이 오면 이전엔 전체가 미마스킹됐다(직접 재현).
URL_CREDENTIAL_USERNAME_SECRET_FIXTURES = [
    ("psql postgres://ghp_REALSECRETVALUE123:${DB_PASSWORD}@db.internal/app",
     "psql postgres://%s@db.internal/app" % MASK_TOKEN),
    ("curl https://sk_live_FAKESECRETKEY99:${API_PASSWORD}@10.0.0.5/status",
     "curl https://%s@10.0.0.5/status" % MASK_TOKEN),
]

# 회귀 방지 — 기존 화이트리스트(일반 사용자명 + placeholder password)는
# username 쪽 검사 추가 후에도 그대로 unchanged 여야 한다. 문서 예시
# fixture(`psql postgres://app:${DB_PASSWORD}@db.internal/app`)는
# URL_CREDENTIAL_FIXTURES 에 이미 있으므로 여기서는 추가 경계(둘 다
# placeholder)만 보강한다.
URL_CREDENTIAL_USERNAME_PLACEHOLDER_WHITELIST = [
    # username/password 둘 다 명시적 placeholder — 실제 secret 없음.
    "curl https://${API_USER}:${API_PASSWORD}@host/path",
    # username 이 일반 식별자(6자 미만) + password placeholder.
    "psql postgres://alice:${DB_PASSWORD}@db.internal/app",
]


class BareKeywordValueClassTest(unittest.TestCase):
    """보안 리뷰 High-1 — 구분자 없는 자연어 `keyword value` 형태."""

    def test_fixtures(self):
        for source, expected in BARE_KEYWORD_VALUE_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)

    def test_prose_false_positive_guard(self):
        for source in BARE_KEYWORD_VALUE_WHITELIST:
            self.assertEqual(mask(source), source, msg=source)

    def test_short_plain_word_known_gap_documented(self):
        # 의도된 회귀 아님 — 알려진 구조적 한계(값 형태 휴리스틱이 6자
        # 이상 평문 단어형 짧은 secret 을 구분 못함). 여기서는 "마스킹
        # 되지 않는 것"이 현재 의도된 동작임을 고정한다.
        for source in BARE_KEYWORD_VALUE_SHORT_PLAIN_WORD_KNOWN_GAP:
            self.assertEqual(mask(source), source, msg=source)


class UrlCredentialUsernameSecretTest(unittest.TestCase):
    """보안 리뷰 Medium-3 — URL credential username 쪽 placeholder 미검사."""

    def test_username_secret_with_placeholder_password_is_masked(self):
        for source, expected in URL_CREDENTIAL_USERNAME_SECRET_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)

    def test_ordinary_username_with_placeholder_password_stays_unchanged(self):
        for source in URL_CREDENTIAL_USERNAME_PLACEHOLDER_WHITELIST:
            self.assertEqual(mask(source), source, msg=source)


# High — JSON/직렬화 key:value. 키워드 직후 따옴표가 끼면 구분자 매칭이
# 실패해 전혀 마스킹되지 않던 결함 (capture 의 주 형식인 JSON payload 누락).
JSON_KEY_VALUE_FIXTURES = [
    ('{"password":"hunter2"}',
     '{"password":"%s"}' % MASK_TOKEN),
    ('{"api_key":"sk-live-abcdef"}',
     '{"api_key":"%s"}' % MASK_TOKEN),
    ('{"github_token":"ghp_abcdefghijklmnop"}',
     '{"github_token":"%s"}' % MASK_TOKEN),
]

# Medium 1 — 따옴표로 감싼 값에 공백이 있으면 첫 단어만 치환되고 나머지가
# 노출되던 결함. 닫는 따옴표까지 통째로 마스킹해야 한다.
QUOTED_VALUE_SPACING_FIXTURES = [
    ('password: "super secret value"',
     'password: "%s"' % MASK_TOKEN),
    ('TOKEN="abc123 def456"',
     'TOKEN="%s"' % MASK_TOKEN),
]

# Medium 3 — 키워드 목록에 `password/passwd/pwd` 만 있고 bare `pass` 가
# 없어 `*_PASS=` 계열이 전부 새던 결함. `compass=`/`passenger=` 류 영문 단어
# 오탐은 letter-boundary lookaround 로 차단 (WHITELIST_UNCHANGED 에서 고정).
PASS_KEYWORD_FIXTURES = [
    ("DB_PASS=hunter2",
     "DB_PASS=%s" % MASK_TOKEN),
    ("MYSQL_PASS=hunter2",
     "MYSQL_PASS=%s" % MASK_TOKEN),
    ("PASS=hunter2",
     "PASS=%s" % MASK_TOKEN),
]

# Medium 4 — `api[_-]?key`/`access[_-]?key` 변형만 있고 `private_key` / bare
# `key=` 가 없어 완전 노출되던 결함. `monkey=`/`keyboard=` 류 오탐은
# letter-boundary lookaround 로 차단 (WHITELIST_UNCHANGED 에서 고정).
KEY_KEYWORD_FIXTURES = [
    ('private_key: "-----BEGIN PRIVATE KEY-----FAKEKEYDATA-----END PRIVATE KEY-----"',
     'private_key: "%s"' % MASK_TOKEN),
    ("KEY=abc123",
     "KEY=%s" % MASK_TOKEN),
]

# v2 재-재리뷰 수리 (High) — 키워드 끝 ~ 구분자(`=`/`:`) 사이 접미(suffix)가
# 길면 구 상한(32)에서 전체 매치가 실패해 완전 미마스킹되던 회귀
# (재리뷰어 실측 3건, 접미 42/40/60자). 접미 상한을 128 로 확장한 수정의
# 정확도 lock-in — 접두는 위치 이동으로 이미 안전하므로 (재-재리뷰
# docstring 근거 참조) 별도 접두 fixture 불필요.
LONG_SUFFIX_IDENTIFIER_FIXTURES = [
    ("GITHUB_TOKEN_FOR_CI_DEPLOYMENT_PIPELINE_RUNNER_ACCOUNT=ghp_abcdef",
     "GITHUB_TOKEN_FOR_CI_DEPLOYMENT_PIPELINE_RUNNER_ACCOUNT=%s" % MASK_TOKEN),
    ("API_KEY_FOR_MY_SPECIAL_INTEGRATION_SERVICE_NAME=verysecretvalue",
     "API_KEY_FOR_MY_SPECIAL_INTEGRATION_SERVICE_NAME=%s" % MASK_TOKEN),
    ("TOKEN_FOR_THE_EXTREMELY_LONG_NAMED_DOWNSTREAM_SERVICE_INTEGRATION=abc123",
     "TOKEN_FOR_THE_EXTREMELY_LONG_NAMED_DOWNSTREAM_SERVICE_INTEGRATION=%s" % MASK_TOKEN),
]

# 접미 상한 경계값 — 정확히 128 은 매치(마스킹), 129 는 구조적으로 매치
# 불가(알려진 한계, docstring 명시). 키워드는 lookaround 제약이 없는
# "TOKEN" 을 써서 접미 길이만 순수하게 통제한다.
_SUFFIX_AT_CAP = "TOKEN" + "A" * 128 + "=fakeboundaryvalue"
_SUFFIX_OVER_CAP = "TOKEN" + "A" * 129 + "=fakeboundaryvalue"

ENV_VAR_FIXTURES = [
    ("TOKEN=fake-tok-value ./deploy.sh",
     "TOKEN=%s ./deploy.sh" % MASK_TOKEN),
    ("SECRET=fake-secret-value make release",
     "SECRET=%s make release" % MASK_TOKEN),
    ("PASSWORD=fake-pw-value python manage.py migrate",
     "PASSWORD=%s python manage.py migrate" % MASK_TOKEN),
    ("export GITHUB_TOKEN=fake-gh-value",
     "export GITHUB_TOKEN=%s" % MASK_TOKEN),
    # yaml/config 형 (`key: value`).
    ("password: fake-yaml-value",
     "password: %s" % MASK_TOKEN),
]

WHITELIST_UNCHANGED = [
    # 값 없는 flag — `--password` 뒤가 공백이 아니라 `-stdin` (flag 이름의 일부).
    "docker login --username dev --password-stdin",
    # 문서 예시 placeholder 류.
    "tool --password <your-password>",
    "tool --token <TOKEN>",
    "export TOKEN=$GITHUB_TOKEN",
    "TOKEN=${GITHUB_TOKEN}",
    "PASSWORD=***",
    "sshpass -p $SSH_PASS ssh prod-host",
    # 단 옵션 `-p` 는 알려진 명령 문맥 밖에서 불변 (find -print 오탐 방지).
    "find . -name '*.py' -print",
    # v1 주석 케이스 — colon 없는 `-u` 는 uid (useradd).
    "useradd -u 1000 deploy",
    # 식별자 화이트리스트 — `--author` 는 `auth` 키워드 오탐.
    "git commit --author=octocat -m msg",
    # secret 없는 평범한 명령.
    "curl https://api.example.com/health",
    # bare `pass`/`key` 추가에 따른 letter-boundary 오탐 방지 lock-in.
    # (Medium 3/4 수정 — 앞/뒤가 알파벳으로 이어지면 keyword 로 취급 안 함.)
    "compass=forest_survey_tool",
    "passenger=42",
    "monkey=1",
    "keyboard=us-standard",
    "keystore=/path/to/store",
    "keyword=urgent",
    "database=prod_main",
    "bypass=true",
    # JSON 식별자 화이트리스트 — `"author"` 도 quote 유무와 무관하게 보존.
    '{"author": "octocat"}',
]

ALL_INPUTS = (
    [c[0] for c in V1_PORTED_CASES]
    + [c[0] for c in ATTACHED_OPTION_FIXTURES]
    + [c[0] for c in URL_CREDENTIAL_FIXTURES]
    + [c[0] for c in URL_CREDENTIAL_TOKEN_FIXTURES]
    + list(URL_CREDENTIAL_TOKEN_WHITELIST)
    + [c[0] for c in URL_CREDENTIAL_TOKEN_MULTI_AT_FIXTURES]
    + list(URL_CREDENTIAL_SCP_FORM_KNOWN_GAP)
    + [c[0] for c in URL_CREDENTIAL_MIXED_CHAIN_FIXTURES]
    + [c[0] for c in ENV_VAR_FIXTURES]
    + [c[0] for c in JSON_KEY_VALUE_FIXTURES]
    + [c[0] for c in QUOTED_VALUE_SPACING_FIXTURES]
    + [c[0] for c in PASS_KEYWORD_FIXTURES]
    + [c[0] for c in KEY_KEYWORD_FIXTURES]
    + [c[0] for c in LONG_SUFFIX_IDENTIFIER_FIXTURES]
    + [_SUFFIX_AT_CAP]
    + list(WHITELIST_UNCHANGED)
    + [c[0] for c in BARE_KEYWORD_VALUE_FIXTURES]
    + list(BARE_KEYWORD_VALUE_WHITELIST)
    + list(BARE_KEYWORD_VALUE_SHORT_PLAIN_WORD_KNOWN_GAP)
    + [c[0] for c in URL_CREDENTIAL_USERNAME_SECRET_FIXTURES]
    + list(URL_CREDENTIAL_USERNAME_PLACEHOLDER_WHITELIST)
)


class V1PortedCasesTest(unittest.TestCase):
    """v1 r2 `_MASK_PATTERNS` 5건 이식 계약."""

    def test_authorization_header_value_masked(self):
        # v1 case 1 — value 전체 (scheme 포함) 마스킹.
        result = mask("curl -H 'Authorization: Bearer fake-token-123' https://api.example.com")
        self.assertNotIn("fake-token-123", result)
        self.assertIn("Authorization:", result)
        self.assertIn(MASK_TOKEN, result)

    def test_authorization_equals_form_masked(self):
        result = mask("req -H Authorization=fake-basic-value")
        self.assertNotIn("fake-basic-value", result)
        self.assertIn("Authorization=", result)

    def test_v1_cases_exact(self):
        for source, expected in V1_PORTED_CASES:
            self.assertEqual(mask(source), expected, msg=source)

    def test_nonstandard_auth_header_leaves_no_secret(self):
        # bearer 규칙이 key=value 규칙보다 먼저 돌아 scheme 뒤 토큰이 남지 않는다.
        result = mask("curl -H 'X-Auth: Bearer fake-xauth-tok'")
        self.assertNotIn("fake-xauth-tok", result)


class AttachedOptionClassTest(unittest.TestCase):
    """신규 클래스 1 — 옵션 부착형 (SPIKE-2 클래스별 fixture)."""

    def test_fixtures(self):
        for source, expected in ATTACHED_OPTION_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class UrlCredentialClassTest(unittest.TestCase):
    """신규 클래스 2 — URL credential (SPIKE-2 클래스별 fixture)."""

    def test_fixtures(self):
        for source, expected in URL_CREDENTIAL_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class UrlCredentialTokenClassTest(unittest.TestCase):
    """보안 리뷰 High — 콜론 없는 단일 토큰 URL userinfo (spec §6.4 canonical
    예시 형태). 기존 `_URL_CREDENTIAL` 은 콜론 필수라 이 형태를 전혀 잡지
    못했다 — 직접 재현: `mask('git push https://ghp_FAKETOKEN123@internal-gitlab/org/repo.git')`."""

    def test_fixtures(self):
        for source, expected in URL_CREDENTIAL_TOKEN_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)

    def test_false_positive_guard(self):
        # userinfo 없는 URL / 경로 안의 `@` / 평문 이메일은 과잉 마스킹 금지.
        for source in URL_CREDENTIAL_TOKEN_WHITELIST:
            self.assertEqual(mask(source), source, msg=source)

    def test_multi_at_segments_fully_masked(self):
        # 재리뷰 Medium — 형제 규칙(`_URL_CREDENTIAL`)과 동일하게 마지막
        # `@` 를 host 구분자로 삼아 중간 세그먼트를 전부 마스킹해야 한다.
        for source, expected in URL_CREDENTIAL_TOKEN_MULTI_AT_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)

    def test_scp_form_known_gap_documented(self):
        # Low-Medium — `://` 없는 scp 형은 오탐 위험(ssh 프롬프트·이메일과
        # 구분 불가) 때문에 의도적으로 엔진 대상 밖으로 남겨둔다. 여기서는
        # "마스킹되지 않는 것"이 의도된 현재 동작임을 고정한다.
        for source in URL_CREDENTIAL_SCP_FORM_KNOWN_GAP:
            self.assertEqual(mask(source), source, msg=source)

    def test_mixed_chain_fully_masked(self):
        # 재재검증 Medium — 콜론형/token형 규칙 경계의 틈. userinfo 전체
        # (마지막 `@` 앞 전부)가 세그먼트 순서·구성과 무관하게 통째로
        # 마스킹돼야 한다.
        for source, expected in URL_CREDENTIAL_MIXED_CHAIN_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class EnvVarClassTest(unittest.TestCase):
    """신규 클래스 3 — env-var 형 (SPIKE-2 클래스별 fixture)."""

    def test_fixtures(self):
        for source, expected in ENV_VAR_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class JsonKeyValueClassTest(unittest.TestCase):
    """High — JSON/직렬화 key:value (키워드 뒤 따옴표 개재로 전혀 미마스킹)."""

    def test_fixtures(self):
        for source, expected in JSON_KEY_VALUE_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class QuotedValueSpacingTest(unittest.TestCase):
    """Medium 1 — 따옴표 안 공백 값은 닫는 따옴표까지 통째로 마스킹."""

    def test_fixtures(self):
        for source, expected in QUOTED_VALUE_SPACING_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class PassKeywordClassTest(unittest.TestCase):
    """Medium 3 — bare `pass` 키워드 (`DB_PASS=`, `MYSQL_PASS=`, `PASS=`)."""

    def test_fixtures(self):
        for source, expected in PASS_KEYWORD_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class KeyKeywordClassTest(unittest.TestCase):
    """Medium 4 — `private_key` / bare `key=`."""

    def test_fixtures(self):
        for source, expected in KEY_KEYWORD_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class LongSuffixIdentifierClassTest(unittest.TestCase):
    """v2 재-재리뷰 High — 키워드~구분자 사이 긴 접미 식별자가 완전 미마스킹
    되던 회귀 (재리뷰어 실측 3건). 접미 상한 확장(32→128)의 정확도 lock-in."""

    def test_fixtures(self):
        for source, expected in LONG_SUFFIX_IDENTIFIER_FIXTURES:
            self.assertEqual(mask(source), expected, msg=source)


class SuffixCapBoundaryTest(unittest.TestCase):
    """접미 상한(128) 경계 — 정확히 128 은 매치, 129 는 구조적으로 매치
    불가 (알려진 한계). 실사용 식별자 접미 최대 관측치(60자, 재리뷰어 3건
    중 최장)에 2배 이상 여유를 둔 상한이라 실질 위험은 없다."""

    def test_exactly_at_cap_is_masked(self):
        result = mask(_SUFFIX_AT_CAP)
        self.assertNotIn("fakeboundaryvalue", result)
        self.assertIn(MASK_TOKEN, result)

    def test_over_cap_known_limitation_stays_unmasked(self):
        # 의도된 회귀 아님 — 상한을 넘는 극단적 접미는 여전히 미마스킹되는
        # 알려진 구조적 한계다 (bounded quantifier 의 trade-off). 128 은
        # 실사용 식별자 대비 넉넉한 여유이므로 실질 위험은 낮다고 판단.
        result = mask(_SUFFIX_OVER_CAP)
        self.assertEqual(result, _SUFFIX_OVER_CAP)


class WhitelistFalsePositiveTest(unittest.TestCase):
    """화이트리스트 — 과잉 마스킹 금지 케이스는 입력 불변."""

    def test_whitelisted_inputs_unchanged(self):
        for source in WHITELIST_UNCHANGED:
            self.assertEqual(mask(source), source, msg=source)


class MultiSecretTest(unittest.TestCase):
    def test_combined_command_masks_every_secret(self):
        source = (
            "AWS_SECRET_ACCESS_KEY=fake1 curl -u bob:fake2 "
            "https://carol:fake3@api.test --token=fake4"
        )
        result = mask(source)
        for leak in ("fake1", "fake2", "fake3", "fake4"):
            self.assertNotIn(leak, result)
        self.assertEqual(result.count(MASK_TOKEN), 4)


class ConsumerContractTest(unittest.TestCase):
    """sanitize (Shadow) / redact (차단 로그) — 동일 결과 + 멱등 계약."""

    def test_sanitize_and_redact_identical(self):
        for source in ALL_INPUTS:
            self.assertEqual(sanitize(source), redact(source), msg=source)
            self.assertEqual(sanitize(source), mask(source), msg=source)

    def test_masking_is_idempotent(self):
        for source in ALL_INPUTS:
            once = mask(source)
            self.assertEqual(mask(once), once, msg=source)

    def test_engine_surface_excludes_v1_residual_concerns(self):
        # 태깅·회전 계열은 엔진 대상 아님 (docstring 명시 계약).
        for name in ("safe_command_repr", "rotate_raw", "RAW_ROTATE_THRESHOLD",
                     "RAW_ROTATE_KEEP", "live_count", "append_line"):
            self.assertFalse(hasattr(masking, name), msg=name)
        self.assertEqual(
            sorted(masking.__all__), ["MASK_TOKEN", "mask", "redact", "sanitize"]
        )


def _build_realistic_keyword_text(n_repeats):
    """긴 identifier + 키워드 + 값 반복 텍스트. 순수 영숫자 런과 달리 실제로
    매치되어야 하는 `keyword=value` 쌍을 대량 포함한다 — 접미 상한 회귀
    (매치 자체가 실패해 조용히 새는 클래스) 는 매치가 애초에 없는 순수
    영숫자 런으로는 검출 불가능하므로, 이 fixture 가 성능·정확도 양쪽에서
    그 회귀를 잡아낸다 (재-재리뷰 요구사항)."""
    return " ".join(
        "GITHUB_TOKEN_FOR_CI_DEPLOYMENT_PIPELINE_RUNNER_ACCOUNT_%d=fakeSecretValue%d" % (i, i)
        for i in range(n_repeats)
    )


class RedosScalingRegressionTest(unittest.TestCase):
    """v2 재리뷰 High — `_KEYWORD_VALUE` 의 무경계 `[A-Za-z0-9_-]*` 접두/접미가
    키워드 미매치 긴 영숫자 런에서 위치당 2차 백트래킹을 유발했다
    (재리뷰어 실측: n=5000 0.87s → n=40000 56.63s, 입력 2배마다 시간 4배 =
    O(n^2) 확정). 1차 수정: 접두/접미를 `{0,32}` 로 상한 — 위치당 비용이
    상수가 되어 전체는 O(n).

    v2 재-재리뷰 수리 (High) — 1차 수정의 접두/접미 대칭 상한(둘 다 32)이
    키워드~구분자 사이 긴 접미(42~60자 실측)에서 매치 자체를 실패시켜
    전체 미마스킹을 유발했다 (masking.py `_KEYWORD_VALUE` docstring 의
    비대칭 근거 참조 — `re.sub` 는 시작 위치를 옮겨 접두 초과분을 우회할
    수 있지만 접미는 매치 종료 지점에 고정돼 우회 불가). 접미만 128 로
    확장(접두는 32 유지) — 여전히 상수 상한이므로 ReDoS 방지 성질은 그대로
    유지된다. 아래에서 상한 확장 후 순수 영숫자 런(접두 백트래킹 worst
    case) + 실사용 키워드=값 반복 패턴(접미 회귀를 잡는 패턴) 양쪽으로
    선형 스케일링을 재확인한다.

    판정은 절대시간이 아니라 n 과 2n 의 소요시간 **비율**로 한다 — 느린 CI
    에서는 절대시간 자체가 몇 배씩 흔들릴 수 있지만, 선형 알고리즘이라면
    입력을 2배로 늘려도 소요시간은 여전히 ~2배 근처에 머문다 (로컬 실측
    순수 영숫자 런 20k→40k 1.99배, 40k→80k 2.06배 / 실사용 패턴
    2000→4000 반복 2.01배 — 변동 폭 모두 ±3% 이내). 이차 회귀가 재발하면
    비율이 ~4배로 뛰므로, 임계값 3.0 은 정상 노이즈(로컬 안정 ~2.0 근방)와
    이차 회귀(4.0) 사이에 넉넉한 여유를 둔다. 절대시간 assert 는 "명백히
    느려짐"만 잡는 보조 가드로 별도 유지 — 접미 상한 확장(32→128) 후
    200k 입력 실측 0.47s (확장 전 0.55s 대비 오차범위 내, 위치당 비용
    증가가 상수배(≤4x)에 그쳐 실질 영향 미미), 상한 5s 는 느린 CI 에서도
    flaky 하지 않도록 실측 대비 ~10배 여유.
    """

    def _timed_mask(self, n):
        text = "x" * n  # 키워드 미포함 순수 영숫자 런 — 접두 백트래킹 worst case
        start = time.perf_counter()
        mask(text)
        return time.perf_counter() - start

    def _timed_mask_text(self, text):
        start = time.perf_counter()
        result = mask(text)
        return time.perf_counter() - start, result

    def test_scales_linearly_not_quadratically(self):
        self._timed_mask(2000)  # warm-up — 최초 호출의 1회성 오버헤드 제외

        small_n, large_n = 20000, 40000
        t_small = self._timed_mask(small_n)
        t_large = self._timed_mask(large_n)

        if t_small <= 0:
            self.skipTest("측정 해상도 부족 (t_small=0) — 환경 재시도 필요")

        ratio = t_large / t_small
        self.assertLess(
            ratio, 3.0,
            "n=%d→%d 소요시간 비율 %.2f — 선형이면 ~2.0, 2차 회귀면 ~4.0 근방"
            " (t_small=%.5fs, t_large=%.5fs)"
            % (small_n, large_n, ratio, t_small, t_large),
        )

    def test_large_input_absolute_time_bound(self):
        # 절대시간 보조 가드 — 접미 상한 확장(128) 후 로컬 실측 200k=0.47s
        # 대비 ~10배 여유(5s)로 느린 CI 에서도 flaky 하지 않게 넉넉히 잡는다.
        # 스케일링 비율 테스트가 주 판정이며 이건 "명백히 느려짐"만 잡는
        # 이중 확인.
        elapsed = self._timed_mask(200000)
        self.assertLess(
            elapsed, 5.0,
            "200k 입력 마스킹이 %.2fs 소요 — ReDoS 회귀 의심" % elapsed,
        )

    def test_realistic_keyword_value_pattern_scales_linearly(self):
        # 순수 영숫자 런은 매치가 애초에 없어 접미 상한 회귀(매치 실패로
        # 인한 완전 미마스킹)를 검출하지 못한다 — 실사용 keyword=value 쌍이
        # 반복되는 패턴으로 성능·정확도를 동시에 재확인한다.
        self._timed_mask_text(_build_realistic_keyword_text(200))  # warm-up

        small_reps, large_reps = 2000, 4000
        t_small, _ = self._timed_mask_text(_build_realistic_keyword_text(small_reps))
        t_large, result_large = self._timed_mask_text(
            _build_realistic_keyword_text(large_reps)
        )

        if t_small <= 0:
            self.skipTest("측정 해상도 부족 (t_small=0) — 환경 재시도 필요")

        ratio = t_large / t_small
        self.assertLess(
            ratio, 3.0,
            "실사용 패턴 반복 %d→%d 소요시간 비율 %.2f — 선형이면 ~2.0"
            " (t_small=%.5fs, t_large=%.5fs)"
            % (small_reps, large_reps, ratio, t_small, t_large),
        )

        # 정확도 동시 확인 — 접미 상한 회귀 재발 시 여기서 leak 이 잡힌다.
        leaked = [i for i in range(large_reps)
                  if ("fakeSecretValue%d" % i) in result_large]
        self.assertEqual(leaked, [], "접미 상한 회귀 — %d건 평문 노출" % len(leaked))
        self.assertEqual(result_large.count(MASK_TOKEN), large_reps)


def _build_url_credential_worst_case(n):
    """`scheme://` 뒤에 `@` 없이 non-slash 문자만 n개 이어지는 최악 케이스 —
    통합 `_URL_CREDENTIAL` (`X+Y` 형태, 중첩 quantifier 없음) 이 userinfo
    후보를 전부 삼킨 뒤 `@` 를 못 찾아 위치별로 한 글자씩 백트래킹하는
    시나리오. 이론상 O(n) 이지만 실측으로 고정한다 (위치당 상수 비용
    요구사항)."""
    return "scheme://" + ("x" * n)


def _build_url_credential_chain_worst_case(n):
    """`a@` 를 반복해 `://` 뒤에 다중 `@` 세그먼트 체인(길이 n)을 만들고,
    `@` 없는 tail 로 끝맺어 greedy 매치가 끝까지 소진된 뒤 최종 실패 →
    backtrack 경로를 강제한다. `@` 경계는 항상 유일하게 결정되므로(같은
    부분문자열을 여러 방식으로 재분할할 모호성이 없음) 문헌상 catastrophic
    backtracking 조건에 해당하지 않는다 — 실측으로 선형성을 고정한다."""
    reps = max(1, n // 2)
    body = ("a@" * reps)[:n]
    return "scheme://" + body + "tailnoat"


def _build_url_credential_mixed_chain_worst_case(n):
    """재재검증 Medium 수리(콜론형/token형 통합) 전용 최악 케이스 —
    `u:p@` (콜론 세그먼트) 와 `t@` (token 세그먼트) 를 번갈아 반복해
    실제 혼합 체인 버그 재현(`TOKEN@user:pw@host`)과 같은 모양을 대량
    반복시킨다. 통합 규칙은 콜론을 문자클래스에서 특별 취급하지 않고
    `[^/\\s]+` 로 함께 삼키므로(placeholder 판정에서만 `:` 를 따로
    본다), 콜론 유무가 정규식 엔진의 backtracking 경로 자체에는 영향을
    주지 않아야 한다 — `@` 없는 tail 로 끝맺어 최종 실패 → backtrack 을
    강제한 뒤 선형성을 실측으로 재확인한다."""
    reps = max(1, n // 4)
    body = ("u:p@t@" * reps)[:n]
    return "scheme://" + body + "tailnoat"


class UrlCredentialTokenRedosScalingTest(unittest.TestCase):
    """통합 `_URL_CREDENTIAL` 규칙 전용 스케일링 회귀 — 콜론형/token형/
    다중 `@` 체인/혼합 체인을 하나의 정규식으로 합친 리팩터가
    `RedosScalingRegressionTest` 가 고정한 선형 성질을 깨지 않는지 별도로
    재확인한다. 판정은 절대시간이 아니라 n/2n 비율 — 선형이면 ~2.0 근방,
    2차 회귀면 ~4.0 근방 (파일 상단 `RedosScalingRegressionTest` docstring
    근거와 동일한 판정 방식)."""

    def _timed(self, n):
        text = _build_url_credential_worst_case(n)
        start = time.perf_counter()
        mask(text)
        return time.perf_counter() - start

    def _timed_chain(self, n):
        text = _build_url_credential_chain_worst_case(n)
        start = time.perf_counter()
        mask(text)
        return time.perf_counter() - start

    def _timed_mixed_chain(self, n):
        text = _build_url_credential_mixed_chain_worst_case(n)
        start = time.perf_counter()
        mask(text)
        return time.perf_counter() - start

    def _assert_linear_scaling(self, timings, sizes):
        if timings[0] <= 0:
            self.skipTest("측정 해상도 부족 (t=0) — 환경 재시도 필요")

        ratio_1 = timings[1] / timings[0]
        ratio_2 = timings[2] / timings[1]
        self.assertLess(
            ratio_1, 3.0,
            "n=%d→%d 비율 %.2f — 선형이면 ~2.0 (t=%.5fs/%.5fs)"
            % (sizes[0], sizes[1], ratio_1, timings[0], timings[1]),
        )
        self.assertLess(
            ratio_2, 3.0,
            "n=%d→%d 비율 %.2f — 선형이면 ~2.0 (t=%.5fs/%.5fs)"
            % (sizes[1], sizes[2], ratio_2, timings[1], timings[2]),
        )
        self.assertLess(
            timings[3], 5.0,
            "n=%d 절대시간 %.2fs — ReDoS 회귀 의심" % (sizes[3], timings[3]),
        )

    def test_scales_linearly_not_quadratically(self):
        self._timed(2000)  # warm-up — 최초 호출의 1회성 오버헤드 제외

        sizes = [20000, 40000, 80000, 200000]
        timings = [self._timed(n) for n in sizes]
        self._assert_linear_scaling(timings, sizes)

    def test_multi_at_chain_scales_linearly(self):
        # 다중 `@` 체인(콜론 없음) — 순수 token형 반복 경로.
        self._timed_chain(2000)  # warm-up

        sizes = [20000, 40000, 80000, 200000]
        timings = [self._timed_chain(n) for n in sizes]
        self._assert_linear_scaling(timings, sizes)

    def test_mixed_chain_scales_linearly(self):
        # 재재검증 Medium 수리 전용 — 콜론형/token형을 한 규칙으로 합친
        # 뒤에도 혼합 체인(콜론+token 번갈아) worst case 가 선형을
        # 유지하는지 별도 확인.
        self._timed_mixed_chain(2000)  # warm-up

        sizes = [20000, 40000, 80000, 200000]
        timings = [self._timed_mixed_chain(n) for n in sizes]
        self._assert_linear_scaling(timings, sizes)


def _build_bare_keyword_worst_case(n):
    """`_BARE_KEYWORD_VALUE` 전용 최악 케이스 — 키워드가 반복해서 매치는
    되지만(정규식 엔진이 계속 일을 하게 만듦) 값이 전부 6자 미만이라
    `_looks_like_secret_value()` 에서 매번 거부돼 치환은 발생하지 않는
    경로("거의 매치, 결국 no-op" 반복 — 순수 알고리즘적 최악 케이스는
    아니지만 `_RULES` 파이프라인에 새로 추가된 규칙이 실사용 크기에서
    선형을 유지하는지 확인하는 실측 게이트)."""
    return "token " * (n // 6)


class BareKeywordValueRedosScalingTest(unittest.TestCase):
    """2026-08-09 보안 리뷰 High-1 — 신규 `_BARE_KEYWORD_VALUE` 규칙이
    `_RULES` 파이프라인에 추가된 뒤에도 `mask()` 전체가 선형을 유지하는지
    별도 확인 (판정 방식은 `RedosScalingRegressionTest` 와 동일 — n/2n
    비율)."""

    def _timed(self, n):
        text = _build_bare_keyword_worst_case(n)
        start = time.perf_counter()
        mask(text)
        return time.perf_counter() - start

    def test_scales_linearly_not_quadratically(self):
        self._timed(2000)  # warm-up

        small_n, large_n = 20000, 40000
        t_small = self._timed(small_n)
        t_large = self._timed(large_n)

        if t_small <= 0:
            self.skipTest("측정 해상도 부족 (t_small=0) — 환경 재시도 필요")

        ratio = t_large / t_small
        self.assertLess(
            ratio, 3.0,
            "n=%d→%d 소요시간 비율 %.2f — 선형이면 ~2.0, 2차 회귀면 ~4.0 근방"
            " (t_small=%.5fs, t_large=%.5fs)"
            % (small_n, large_n, ratio, t_small, t_large),
        )

    def test_large_input_absolute_time_bound(self):
        elapsed = self._timed(200000)
        self.assertLess(
            elapsed, 5.0,
            "200k 입력 마스킹이 %.2fs 소요 — ReDoS 회귀 의심" % elapsed,
        )


if __name__ == "__main__":
    unittest.main()
