# Rein Security Layer — 설계 스펙

> 바이브코딩 시대의 AI 네이티브 보안 프레임워크

- 작성일: 2026-04-09
- 상태: 승인됨 (설계 완료, 구현 대기)

---

## 1. 배경과 목적

### 문제
바이브코딩(AI가 코드 대부분을 생성하는 개발 방식)에서 보안은 사각지대다. AI는 "작동하는 코드"를 잘 만들지만, 그 코드가 "안전한 코드"인지는 보장하지 않는다. SQL 인젝션, XSS, 시크릿 노출 같은 취약점이 AI 생성 코드에 그대로 포함될 수 있고, 사용자는 이를 인지하지 못한 채 배포할 수 있다.

### 목적
Rein의 기존 게이트 기반 워크플로우에 **보안 리뷰 레이어**를 추가하여, AI가 생성한 코드의 보안 취약점을 자동으로 탐지하고 대화형으로 수정을 제안한다. 보안을 Rein의 핵심 차별화 포인트로 내세운다.

### 설계 원칙
- 보안은 별도 단계가 아니라 **프레임워크의 레이어**로 존재한다
- 프로젝트 성숙도에 따라 **점진적으로 강화**된다
- 모든 레벨의 사용자에게 **레벨에 맞는 피드백**을 제공한다
- 기존 Rein 아키텍처(hooks + rules + agents)와 **동일한 패턴**으로 확장한다

---

## 2. 대상 사용자

모든 레벨의 사용자를 대상으로 하되, 경험이 다르다:

| 사용자 레벨 | 특성 | Rein 보안 경험 |
|------------|------|---------------|
| beginner (바이브코더) | 코드 지식 거의 없음, AI에 전적 의존 | 자동 수정 + 간단한 설명 |
| intermediate (주니어~미드) | 기본 코딩 가능, 보안 약함 | 취약점 설명 + 수정 제안 + 적용 여부 질문 |
| advanced (시니어/리드) | 보안 이해 있음, 팀 가드레일 필요 | 간결한 리포트 + 적용/무시/예외등록 선택 |

---

## 3. 디렉토리 구조

```
.claude/security/
  ├── profile.yaml          ← 현재 프로젝트의 보안 레벨 + 사용자 레벨
  ├── maturity.yaml         ← 레벨 업그레이드 트리거 조건
  └── rules/
      ├── base.md           ← Level 1: 모든 프로젝트 기본 (init 시 적용)
      ├── standard.md       ← Level 2: 성숙 프로젝트 (업그레이드 시 생성)
      └── strict.md         ← Level 3: 프로덕션급 (업그레이드 시 생성)
```

기존 `.claude/rules/security.md`는 유지한다. security layer의 규칙이 이를 보강하는 관계.

### profile.yaml

```yaml
security_level: base          # base | standard | strict
user_level: auto              # auto | beginner | intermediate | advanced
created_at: 2026-04-09
last_upgraded: 2026-04-09
snoozed_until: null           # 업그레이드 제안 스누즈 시 날짜
upgrade_history: []
```

- `security_level`: 현재 적용 중인 보안 규칙 세트
- `user_level`: 피드백 상세도 결정. `auto`면 상호작용 패턴에서 자동 판별
- `snoozed_until`: 업그레이드 제안을 "나중에"로 선택 시 7일 후 날짜

---

## 4. 보안 레벨별 규칙 체계

### Level 1 — Base (모든 프로젝트 기본)

| 검사 항목 | 탐지 대상 |
|-----------|----------|
| 시크릿 하드코딩 | API 키, 비밀번호, 토큰 패턴 |
| SQL 인젝션 기본 | 문자열 연결/f-string으로 쿼리 생성 |
| XSS 기본 | innerHTML, dangerouslySetInnerHTML 무검증 사용 |
| 안전하지 않은 해싱 | MD5, SHA1을 비밀번호 해싱에 사용 |
| 환경변수 미사용 | 민감값이 코드에 직접 포함 |

### Level 2 — Standard (성숙 프로젝트, Base 포함)

| 검사 항목 | 탐지 대상 |
|-----------|----------|
| SSRF | 사용자 입력으로 URL 구성 |
| Path Traversal | 사용자 입력으로 파일 경로 구성 |
| 인증/인가 누락 | API 엔드포인트에 auth 미들웨어 없음 |
| CORS 과도한 허용 | `*` 와일드카드 origin |
| 의존성 취약점 | package.json/requirements.txt 변경 시 경고 |
| Rate limiting 미적용 | 공개 API 엔드포인트에 rate limit 없음 |

### Level 3 — Strict (프로덕션급, Standard 포함)

| 검사 항목 | 탐지 대상 |
|-----------|----------|
| OWASP Top 10 전항목 | 심층 검사 |
| 비즈니스 로직 취약점 | 권한 상승, IDOR |
| 암호화 통신 | HTTP → HTTPS 미강제 |
| 로깅 민감정보 | 비밀번호, 토큰, 개인정보가 로그에 포함 |
| 에러 정보 노출 | 스택 트레이스, DB 구조가 응답에 포함 |
| 보안 헤더 | CSP, X-Frame-Options 등 미설정 |

각 레벨의 규칙은 LLM 보안 리뷰어에게 컨텍스트로 전달되는 프롬프트 기반이다. 규칙 파일(`.md`)이 리뷰어 에이전트의 검사 기준이 된다.

---

## 5. 워크플로우 통합

### 변경 전

```
IMPLEMENT → CODEX REVIEW → FIX → TEST
```

### 변경 후

```
IMPLEMENT → CODEX REVIEW → SECURITY REVIEW → FIX → TEST
```

### SECURITY REVIEW 단계 동작

1. CODEX REVIEW 완료 후 → `security-reviewer` 에이전트 자동 실행
2. 에이전트가 `profile.yaml`의 `security_level`을 읽어 해당 레벨 규칙 로드
3. 변경된 파일 대상으로 LLM 보안 리뷰 수행
4. 결과를 `user_level`에 맞게 대화형으로 전달
5. `touch SOT/dod/.security-reviewed` stamp 생성
6. `.codex-reviewed`와 `.security-reviewed` 두 stamp 모두 존재해야 테스트 진행 가능

### Hook 변경

기존 `pre-bash-guard.sh`의 테스트/커밋 차단 로직에 `.security-reviewed` stamp 검사를 추가한다. 새 hook 파일은 불필요하다.

```bash
# 기존 check_review_stamp 함수에 추가
SECURITY_STAMP="$PROJECT_DIR/SOT/dod/.security-reviewed"

# DoD 파일이 있을 때만 검사 (기존 로직과 동일)
if [ "$DOD_EXISTS" = true ] && [ ! -f "$SECURITY_STAMP" ]; then
  echo "BLOCKED: 보안 리뷰가 실행되지 않았습니다." >&2
  echo "CODEX 리뷰 후 security-reviewer 에이전트를 실행하세요." >&2
  log_block "보안 리뷰 미실행 (${context})" "$COMMAND"
  return 1
fi
```

### CLAUDE.md 강제 작업 시퀀스 변경

```
4. IMPLEMENT
5. CODEX REVIEW → .codex-reviewed stamp
6. SECURITY REVIEW → .security-reviewed stamp    ← 신규
7. FIX
8. TEST (두 stamp 모두 필요)
```

---

## 6. 보안 리뷰어 에이전트

### 에이전트 정의

- **파일**: `.claude/agents/security-reviewer.md`
- **역할**: 변경된 코드에 대해 현재 보안 레벨 기준으로 취약점을 탐지하고 대화형으로 수정을 제안한다
- **트리거**: CODEX REVIEW 완료 후 자동 실행

### 동작 흐름

1. `.claude/security/profile.yaml`에서 `security_level`과 `user_level` 읽기
2. `.claude/security/rules/{security_level}.md` 규칙 파일 로드
3. 변경된 파일 목록 수집 (`git diff --name-only`)
4. 파일별로 보안 규칙 기준 리뷰 수행
5. 결과를 `user_level`에 맞게 전달

### 사용자 레벨별 피드백

**beginner:**
```
🔒 위험한 코드를 발견해서 수정했습니다.
   app/api/users.py:23 — 외부 입력이 DB 쿼리에 직접 들어가면
   공격자가 데이터를 훔칠 수 있습니다. 안전한 방식으로 변경할게요.
```

**intermediate:**
```
🔒 SQL Injection 취약점 발견
   app/api/users.py:23 — f-string으로 쿼리를 조립하면
   사용자 입력에 악의적 SQL이 삽입될 수 있습니다.
   파라미터화 쿼리로 수정을 제안합니다. 적용할까요?
```

**advanced:**
```
🔒 SQLi — app/api/users.py:23
   f-string query interpolation. 파라미터화 필요.
   제안: cursor.execute("...WHERE id = %s", (user_id,))
   적용/무시/예외등록?
```

### auto 레벨 판별

`user_level: auto` 설정 시 상호작용 패턴에서 자동 판별한다:

- 첫 세션에서는 `intermediate`로 시작
- 사용자가 코드를 직접 작성하는 빈도 vs AI에 전적으로 맡기는 빈도
- 기술 용어 사용 수준
- 수정 제안에 대한 응답 패턴 ("그게 뭔데?" → beginner, "적용해" → intermediate, "이 경우엔 괜찮아" → advanced)

### AGENTS.md 라우팅 테이블 추가

```
| 보안 리뷰 | — | security-reviewer | 해당 언어 디렉토리 |
```

---

## 7. 성숙도 엔진

### 트리거 조건 (maturity.yaml)

```yaml
upgrade_triggers:
  base_to_standard:
    min_conditions: 2       # 아래 중 2개 이상 충족 시 제안
    conditions:
      - metric: commits
        threshold: ">= 50"
      - metric: source_files
        threshold: ">= 30"
      - metric: external_deps
        threshold: ">= 5"
      - metric: has_api_endpoints
        threshold: true
      - metric: age_days
        threshold: ">= 14"

  standard_to_strict:
    min_conditions: 2       # 아래 중 2개 이상 충족 시 제안
    conditions:
      - metric: commits
        threshold: ">= 200"
      - metric: has_auth
        threshold: true
      - metric: has_database
        threshold: true
      - metric: has_user_input
        threshold: true
      - metric: age_days
        threshold: ">= 30"
```

### 실행 시점

세션 시작 시 `SOT/index.md` 읽은 직후, `profile.yaml`을 함께 체크한다.

### 메트릭 수집 방법

| 메트릭 | 수집 방법 |
|--------|----------|
| commits | `git rev-list --count HEAD` |
| source_files | 소스 파일 확장자 glob 카운트 |
| external_deps | `package.json` / `requirements.txt` 파싱 |
| has_api_endpoints | 파일 패턴 + 키워드 grep (route, endpoint, app.get 등) |
| has_auth | 키워드 grep (auth, login, jwt, session 등) |
| has_database | 키워드 grep (database, db, sql, orm, prisma, sqlalchemy 등) |
| has_user_input | 키워드 grep (request.body, req.params, form, input 등) |
| age_days | `profile.yaml`의 `created_at`과 현재 날짜 차이 |

### 사용자 경험

```
🔒 프로젝트 성숙도 변화 감지

현재 보안 레벨: base
커밋 62개, 외부 의존성 7개, API 엔드포인트 존재

→ standard 레벨로 업그레이드하면 SSRF, Path Traversal,
  인증 누락, CORS 검사가 추가됩니다.

업그레이드할까요? (y/n/나중에)
```

### 응답 처리

| 응답 | 동작 |
|------|------|
| y | `profile.yaml`의 `security_level` 변경, 해당 규칙 파일 생성, `upgrade_history`에 기록 |
| n | 다시 제안하지 않음 (다음 레벨 조건 충족 시에만 재제안) |
| 나중에 | `snoozed_until`에 7일 후 날짜 기록, 이후 재제안 |

---

## 8. `rein init` 보안 기본값

### 생성되는 파일

| 파일 | 내용 |
|------|------|
| `.claude/security/profile.yaml` | security_level: base, user_level: auto |
| `.claude/security/maturity.yaml` | 업그레이드 트리거 기본값 |
| `.claude/security/rules/base.md` | Level 1 보안 규칙 |
| `.claude/agents/security-reviewer.md` | 보안 리뷰어 에이전트 정의 |

### 기존 파일 강화

| 파일 | 변경 내용 |
|------|----------|
| `.claude/rules/security.md` | base 규칙 참조 링크 추가 |
| `.claude/settings.json` | deny에 `credentials.json`, `*.pem`, `*.key` 추가 |
| `.gitignore` | `.env*`, `*.pem`, `*.key`, `secrets/` 패턴 추가 (없으면) |

### YAGNI 원칙

`standard.md`와 `strict.md` 규칙 파일은 init 시 생성하지 않는다. 성숙도 엔진이 업그레이드를 제안할 때 해당 규칙 파일을 생성한다.

### init 시 사용자 경험

```
$ rein init

  ✓ 프로젝트 구조 생성
  ✓ 워크플로우 설정
  ✓ 에이전트 설정
  🔒 보안 레이어 설정
    - 보안 프로파일: base (프로젝트 성장에 따라 자동 강화 제안)
    - 시크릿 보호: .env, *.pem, *.key 커밋 차단
    - 보안 리뷰: 코드 변경 시 자동 보안 검사

  프로젝트가 성숙하면 Rein이 보안 레벨 업그레이드를 제안합니다.
```

---

## 9. 범위 외 (명시적 제외)

- 정적 분석 도구(Semgrep, Bandit 등) 직접 연동 — LLM 기반으로 대체
- 런타임 보안 모니터링 — Rein은 개발 시점 도구
- 컨테이너/인프라 보안 스캐닝 — 별도 도메인
- 실시간(코드 생성 시) 보안 검사 — 게이트 방식으로 통일
- CI/CD 파이프라인 보안 통합 — 향후 확장 가능하나 초기 범위 외
