---
level: base
description: 모든 프로젝트에 기본 적용되는 보안 검사 규칙. security-reviewer 에이전트가 이 파일을 컨텍스트로 로드하여 코드를 리뷰한다.
applies_to: "**/*"
---

# Base Security Rules (Level 1)

> 이 파일은 `security-reviewer` 에이전트의 리뷰 기준이다.
> 변경된 코드에 대해 아래 항목을 검사하고, 발견 시 대화형으로 수정을 제안한다.

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

## 리뷰 출력 형식

발견된 취약점은 아래 형식으로 보고한다:

```
🔒 [취약점 유형] — [파일:라인]
   [설명]
   수정 제안: [구체적 코드 변경]
```

취약점이 없으면:

```
🔒 보안 리뷰 통과 (Level: base, 대상 파일 N개)
```
