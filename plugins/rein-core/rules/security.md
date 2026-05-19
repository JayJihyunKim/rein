---
paths:
  - "**/*.env"
  - "secrets/**"
  - "config/**"
  - "**/*auth*"
  - "**/*secret*"
  - "**/*password*"
---

# Security Rules

> ⚠️ 보안 민감 파일 작업 시 자동으로 로드됩니다.

## 행동 강령

사용자 repo 의 보안 프로파일 기준으로 security-reviewer 에이전트가 코드 편집 후 자동 호출된다. profile.yaml 과 rules/{level}.md 는 **priority list 순서로 해석**된다 (아래 §경로 우선순위 참조). 차단 패턴: hard-coded credentials, command injection, SQL injection, XSS, 안전하지 않은 deserialize. user input boundary 에서 항상 validation·escape. secret 은 환경변수 또는 secret manager 만 — 코드 hardcode 금지. Codex 리뷰 (.codex-reviewed stamp) 통과 후 security 리뷰 실행, 두 stamp 모두 있어야 `git commit` 통과 (test/commit 게이트가 commit 을 차단). 테스트 실행 자체는 stamp 게이트 대상이 아니다 (GUARD-1 — TDD red-green 루프 허용).

## 절대 금지
- `.env` 파일 Git 커밋 금지
- API 키, 비밀번호, 토큰 소스 코드 하드코딩 금지
- `secrets/` 디렉토리 커밋 금지
- 로그에 민감 정보(비밀번호, 토큰, 개인정보) 출력 금지

## 환경변수 관리
- 모든 민감 설정값은 환경변수로 관리
- `.env.example`에는 키만 포함 (값 없이)
```
# .env.example
DATABASE_URL=
API_KEY=
JWT_SECRET=
```

## 외부 입력 처리
- 모든 외부 입력은 검증 후 사용
- SQL은 파라미터화 쿼리 또는 ORM만 사용
- 파일 경로는 path traversal 방지 처리

## Claude Code 권한
- `.env`, `secrets/**` 파일은 settings.json `deny`에 명시
- 위험 Bash 명령어는 `pre-bash-safety-guard.sh` hook으로 차단

## Security Layer 연동

보안 프로파일과 레벨별 상세 규칙은 두 가지 위치 — 사용자 repo override 와 plugin source default — 에 분리되어 있다. `security-reviewer` 에이전트가 아래 priority list 를 순서대로 시도해 **첫 발견된 경로**를 사용한다.

### 경로 우선순위

#### profile.yaml (보안 레벨·사용자 레벨 선언)

1. `${PROJECT_DIR}/.claude/security/profile.yaml` — 사용자 repo override (normal case). `rein-bootstrap-project.py` 가 신규 프로젝트 init 시 default 본문으로 생성한다.
2. `${CLAUDE_PLUGIN_ROOT}/security/profile.yaml` — plugin override (rare). plugin source 가 직접 ship 한 profile (특수 배포 시나리오).
3. bootstrap default — 위 둘 다 부재 시, `rein-bootstrap-project.py` 의 내장 default 값 (`security_level: standard`, `user_level: auto`) 으로 fallback.

#### rules/{level}.md (레벨별 상세 검사 항목)

1. `${PROJECT_DIR}/.claude/security/rules/{level}.md` — 사용자가 직접 작성한 override. plugin default 를 덮어쓰고자 할 때 수동 생성.
2. `${CLAUDE_PLUGIN_ROOT}/security/rules/{level}.md` — plugin source default. `base.md` / `standard.md` 는 plugin 이 항상 ship 한다 (bootstrap 으로 user repo 에 복사되지 않음).

### 적용 절차

- `security-reviewer` 가 `profile.yaml` priority 1→3 순서로 시도 → 첫 발견 path 에서 `security_level` 추출
- 추출된 `{level}` 로 `rules/{level}.md` priority 1→2 순서로 시도 → 첫 발견 path 의 본문을 검사 기준으로 사용
- 두 priority list 는 독립적으로 평가 — profile 은 repo override 였지만 rules 는 plugin source 인 조합도 정상
