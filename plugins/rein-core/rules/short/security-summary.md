# Security — quick rule

## 행동 강령

보안 민감 파일 편집 후 security-reviewer 가 profile.yaml 레벨 기준으로 자동 호출된다. 차단 패턴: hard-coded credentials, command injection, SQL injection, XSS, 안전하지 않은 deserialize. user input boundary 에서 항상 validation·escape. secret 은 환경변수 또는 secret manager 만 — 코드 hardcode 금지. .env/secrets/ 커밋 금지, 로그에 민감정보 출력 금지. SQL 은 파라미터화 쿼리/ORM, 파일 경로는 path traversal 방지. Codex 리뷰 + security 리뷰 두 stamp 모두 있어야 `git commit` 통과(테스트 실행 자체는 비차단 — TDD red-green 허용).

> 전체 본문은 `${CLAUDE_PLUGIN_ROOT}/rules/security.md` 참조.
