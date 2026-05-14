---
level: standard
description: 표준 수준의 보안 검사 규칙. base 레벨의 5개 검사에 더해 deserialization, path traversal, 민감 데이터 로깅, TLS/HTTPS 강제 4개 검사를 추가한다. security-reviewer 에이전트가 이 파일을 컨텍스트로 로드하여 코드를 리뷰한다.
applies_to: "**/*"
---

# Standard Security Rules (Level 2)

> 이 파일은 `security-reviewer` 에이전트의 리뷰 기준이다.
> 변경된 코드에 대해 아래 항목을 검사하고, 발견 시 대화형으로 수정을 제안한다.
> base 레벨의 5개 검사를 모두 포함하고, 표준 레벨에서 4개 검사를 추가한다 (총 9개).

## 검사 항목

### 1. 시크릿 하드코딩

**탐지 대상:**
- API 키, 비밀번호, 토큰이 소스 코드에 직접 포함된 경우
- 패턴: `api_key = "..."`, `password = "..."`, `token = "..."`, `secret = "..."`
- AWS/GCP/Azure 키 패턴: `AKIA...`, `AIza...`, `-----BEGIN PRIVATE KEY-----`
- 연결 문자열: `postgresql://user:pass@`, `mongodb://user:pass@`

**수정 방향:**
- 환경변수로 분리 (`os.environ`, `process.env`)
- `.env` 파일 사용 (커밋 금지)

### 2. SQL 인젝션

**탐지 대상:**
- 문자열 연결/보간으로 SQL 쿼리를 생성하는 경우
- 패턴: `f"SELECT ... {var}"`, `"SELECT ... " + var`, `` `SELECT ... ${var}` ``
- ORM raw query에 사용자 입력이 직접 삽입되는 경우

**수정 방향:**
- 파라미터화 쿼리 사용 (`cursor.execute("...WHERE id = %s", (id,))`)
- ORM 메서드 사용 (`Model.objects.filter(id=id)`)

### 3. XSS (Cross-Site Scripting)

**탐지 대상:**
- `innerHTML`, `outerHTML`에 사용자 입력이 직접 할당
- `dangerouslySetInnerHTML`에 검증 없는 데이터 사용
- `document.write()` 사용
- 템플릿에서 이스케이프 없이 변수 출력 (`<%- %>`, `{!! !!}`)

**수정 방향:**
- `textContent` 사용 (HTML 아닌 경우)
- DOMPurify 등 sanitization 라이브러리 사용
- 프레임워크 기본 이스케이프 사용 (`{{ }}`, `<%= %>`)

### 4. 안전하지 않은 해싱

**탐지 대상:**
- MD5, SHA1을 비밀번호 해싱에 사용
- 패턴: `hashlib.md5(password)`, `crypto.createHash('md5')`
- salt 없는 해싱

**수정 방향:**
- bcrypt, scrypt, argon2 사용
- 적절한 salt/work factor 적용

### 5. 환경변수 미사용 민감값

**탐지 대상:**
- URL에 인증 정보 포함: `http://user:pass@host`
- 하드코딩된 IP/포트: `127.0.0.1:5432`
- 설정 파일에 직접 기록된 DB 호스트, 포트, 인증 정보

**수정 방향:**
- 환경변수 또는 설정 관리 시스템 사용
- `.env.example`에 키만 포함

### 6. 안전하지 않은 deserialization

**탐지 대상:**
- 사용자 입력을 직접 역직렬화: `pickle.loads(user_input)`, `pickle.load(untrusted_stream)`
- 안전하지 않은 YAML 파서: `yaml.load(data)` (SafeLoader 미지정), `yaml.Loader` 사용
- 임의 코드 실행: `eval(user_input)`, `exec(user_input)`
- Prototype pollution 위험: `JSON.parse` 결과를 그대로 `Object.assign(target, parsed)` 또는 deep merge 시 `__proto__` / `constructor` / `prototype` 키 미차단

**수정 방향:**
- `pickle.loads` → 신뢰 가능한 source 만 허용. 외부 입력은 JSON 등 안전한 포맷으로 교체
- `yaml.load(data)` → `yaml.safe_load(data)` 또는 명시적 `Loader=yaml.SafeLoader`
- `eval` / `exec` 제거. 산술/리터럴 평가가 필요하면 `ast.literal_eval` 사용
- JSON 파싱 후 병합 시 `__proto__` / `constructor` / `prototype` 키를 reject 하거나 `Object.create(null)` 기반 객체 사용. lodash 등은 prototype-safe 버전 채택

### 7. Path traversal

**탐지 대상:**
- 사용자 입력이 파일 경로에 직접 연결: `os.path.join(base_dir, user_input)`, `open(user_input)` 검증 없이 호출
- `Path(user_input).resolve()` 결과가 base directory 안에 있는지 확인하지 않음
- 업로드/다운로드 핸들러가 `../` 패턴을 reject 하지 않음
- ZIP / tar 등 압축 해제 시 entry name 의 traversal 미검증 (zip-slip)

**수정 방향:**
- `os.path.realpath` (또는 `Path.resolve`) 후 base directory prefix 로 시작하는지 명시 검증
- 파일명 allowlist (UUID, 슬러그) 적용. 사용자 제공 이름을 그대로 쓰지 않음
- 입력에 `..`, 절대경로, NUL byte (`\x00`), Windows drive letter 가 포함되면 reject
- 압축 해제 시 entry path 를 normalize 후 base 외부로 빠지면 skip

### 8. 로그에 민감 데이터

**탐지 대상:**
- 사용자 객체 통째 dump: `console.log(user)`, `logger.info(user_dict)` (비밀번호/토큰 필드 포함 가능)
- 자격 증명 직접 로깅: `logger.info({ password })`, `logger.debug(f"token={token}")`
- 예외/스택 트레이스에 token/secret/Authorization 헤더 노출
- request body / response body 통째 dump (`logger.debug(request.body)`)
- 결제/식별번호 (카드번호, 주민번호, SSN, 이메일) 의 평문 기록

**수정 방향:**
- 민감 필드는 redact (`password=***`, 토큰 마지막 4자리만 노출)
- structured logging 의 PII tag 또는 dedicated log filter 적용 (Python `logging.Filter`, pino redact 등)
- request/response 로깅은 allowlist 필드만. body 통째 dump 금지
- 예외 핸들러에서 Authorization / Cookie 헤더 strip

### 9. TLS / HTTPS 강제

**탐지 대상:**
- 프로덕션 코드에 `http://` URL hardcode (테스트/로컬 host 제외)
- 인증서 검증 비활성: `requests.get(url, verify=False)`, `urllib3.disable_warnings`, `ssl._create_unverified_context()`
- Node.js: `axios({ httpsAgent: new https.Agent({ rejectUnauthorized: false }) })`, `NODE_TLS_REJECT_UNAUTHORIZED=0`
- TLS 1.0/1.1 강제 또는 weak cipher (`ssl.PROTOCOL_TLSv1`, `'RC4'`, `'DES'`) 사용
- mutual TLS 가 필요한 환경에서 client cert 미설정

**수정 방향:**
- 모든 외부 호출 `https://` 강제. http URL 은 test 코드 또는 명시적 localhost only
- `verify=True` (기본값) 유지. 자체 CA 가 필요하면 CA bundle path 명시
- Node: `rejectUnauthorized: true` (기본값) 유지, `NODE_TLS_REJECT_UNAUTHORIZED` 환경변수 제거
- 최소 TLS 1.2 강제 (`ssl.PROTOCOL_TLS_CLIENT` + `minimum_version = TLSVersion.TLSv1_2`)
- mutual TLS 가 요구사항이면 client cert + key 명시 로드

## 리뷰 출력 형식

발견된 취약점은 아래 형식으로 보고한다:

```
🔒 [취약점 유형] — [파일:라인]
   [설명]
   수정 제안: [구체적 코드 변경]
```

취약점이 없으면:

```
🔒 보안 리뷰 통과 (Level: standard, 대상 파일 N개)
```
