# DoD — P10 attached-quote message bundle 회귀 수정

- 날짜: 2026-05-29
- 유형: fix
- 보안 tier: (security/profile.yaml 기준 — review 단계에서 확인)

## 증상 / 재현

독립 보안 리뷰(Sonnet fallback)가 P10 단순 정규식(SIMPLIFY 2026-05-29)에서 신규 false-negative 회귀 1건(MEDIUM)을 발견.

`.env` 존재 시에도 공백 없이 따옴표 메시지가 결합 번들에 붙으면 차단되지 않음:
- `git commit -am"msg"` → 비차단 (회귀)
- `git commit -am'msg'` → 비차단
- `git commit -ma"msg"` → 비차단

## Root cause

arm1 (`pre-bash-safety-guard.sh:174`):
```
(^|[[:space:]])-[[:alpha:]]*(a[[:alpha:]]*m|m[[:alpha:]]*a)[[:alpha:]]*([[:space:]]|$)
```
alpha-run 종료 토큰이 `([[:space:]]|$)` 뿐. `-am"msg"` 는 `m` 다음이 `"` 라 매치가 끊김. arm2/arm3 는 분리 토큰(`-a`/`-m`)을 요구해 단일 번들에 안 걸림.

이전 단순 정규식 `git commit.*-[a-z]*a[a-z]*m` 은 attached-quote 를 차단했음(실측 확인) → 단순화가 기존에 막던 경로를 열음. 문서화된 비목표 2건(적대적 따옴표 중첩 / quoted 메시지 over-block) 어디에도 해당 안 됨.

## 수정 방향

arm1 의 alpha-run 종료 조건에 따옴표 시작(`"`/`'`)을 종료 토큰으로 추가:
`([[:space:]]|$)` → `([[:space:]]|["'\'']|$)`
실측으로 false-positive 없음 확인 완료 (`-m"msg"` a 없음 → 비매치, `--amend`/plain 비매치).

## 변경 파일

- plugins/rein-core/hooks/pre-bash-safety-guard.sh
- tests/hooks/test-pre-bash-safety-guard.sh

## 회귀 방지 테스트 (MUST BLOCK, .env 존재 시)

- `git commit -am"msg"`, `git commit -am'msg'`, `git commit -ma"msg"`, `git commit -am"msg with -a"`

## 비차단 유지 (회귀 없어야)

- `git commit -m"msg"` (a 없음 → arm1 비매치), `--amend`, plain `-m`/`-a`, echo/grep 언급, `git -C . log commit -am`

## 라우팅 추천
```yaml
agent: feature-builder-fix
skills: [codex-review]
mcps: []
rationale: 단일 hook 정규식 회귀 수정, reproduction-first. 보안 리뷰어가 root cause + fix 방향 제시.
approved_by_user: true
```
