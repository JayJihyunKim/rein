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
- 위험 Bash 명령어는 `pre-bash-guard.sh` hook으로 차단
