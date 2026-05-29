# P10 attached-quote 결합번들 회귀 수정

- 날짜: 2026-05-29
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/pre-bash-safety-guard.sh
  - tests/hooks/test-pre-bash-safety-guard.sh
- 요약: 독립 보안 리뷰(Sonnet fallback)가 P10 SIMPLIFY 정규식에서 MEDIUM false-negative 회귀 발견 — `.env` 존재 시 `git commit -am"msg"` / `-am'msg'` / `-ma"msg"` (공백 없이 따옴표 메시지 attached) 가 비차단. Root cause: arm1 alpha-run 종료 토큰이 `([[:space:]]|$)` 뿐이라 `m` 다음 따옴표에서 매치가 끊김 (arm2/arm3 는 분리 토큰 요구). Fix: arm1 종료 토큰에 따옴표(`["']`)를 추가 → `([[:space:]]|["']|$)`. 회귀 테스트 5건 추가(4 MUST-BLOCK attached-quote + 1 non-block `-m"msg"` a-less). 이전 단순 정규식 `git commit.*-[a-z]*a[a-z]*m` 은 이를 차단했었음(SIMPLIFY 가 연 경로). 실측 확인: new FP 없음(`-m"msg"`/`-a`/`-a "x"` 통과), 4 documented FN 차단. 전체 스위트 GREEN(safety-guard 48/0 + 4 suites). codex usage-limit → §4 sonnet-fallback 리뷰(round 3). security standard 통과(secret/path/injection 무관, ReDoS 없음). commit 미실행.
