# DoD — B2 P8 .env-read 탐지 verb 확장 (false-positive 정밀화)

- 날짜: 2026-05-22
- 유형: fix (security)
- plan ref: rein-v1.4-improvement-plan.md §5.2 B2 (확정안 §0.5)
- design ref: codex 검증 (2026-05-22) — P8 누락 verb + quoted-mention false-positive 주의

## 목표 (Why)

`pre-bash-safety-guard.sh` 의 P8 (.env 읽기 차단) 은 read verb 를 `cat|head|tail|less|more|python[23]?|node` 로만 탐지한다(line 102). `grep KEY .env` / `awk … .env.local` / `sed … .env` / `jq . .env` / `cut … .env` 로 시크릿을 읽는 경로가 누락돼 있다. 단순 verb 추가만 하면 `grep ".env" README.md` 처럼 **따옴표 안 검색 패턴**까지 차단되는 false-positive 가 생긴다 (codex 경고).

## 성공 기준 (Acceptance)

1. line 102 verb alternation 에 `grep|awk|sed|jq|cut` 추가.
2. ~~residual 정밀화(quote-boundary 면제)~~ **철회 (codex review 2026-05-22 R1: fail-open 발견)**. quote-boundary 면제는 `cat ".env"` / `grep KEY ".env"`(따옴표 파일명) 을 통과시켜 실제 시크릿 read 우회를 열었음. → residual 은 **deny-by-default 원복**: safe-template strip 후 남는 `.env` 는 따옴표 여부 무관 차단. 따옴표 검색 패턴 vs 따옴표 파일 인자 구분은 shell 파싱 필요 → classifier 범위 밖 → fail-closed.
3. **T2 true-positive**: `grep KEY .env`, `awk '{print}' .env.local`, `sed -n p .env`, `jq . .env`, `cut -d= -f2 .env`, `cat "$HOME/.env"`, **`cat ".env"`, `grep API_KEY ".env"`(quoted filename)** → 모두 차단.
4. **T2 false-positive 방지**: `grep KEY .env.example`(safe template), `echo "use grep .env"`(clause-anchor — verb 아님) → 통과. **`grep ".env" README.md`(quoted pattern) 은 fail-closed 로 보수적 차단** (수용된 false-positive — 보안 우선).
5. 기존 `test-pre-bash-safety-guard.sh` / `test-bash-guard-split-command-anchoring.sh` 전부 PASS (기존 cat/python 동작 보존).

## 제외 (Out of scope)

- 완전한 shell quote 파싱 (command_invokes 의 알려진 한계 — full parser 는 범위 밖).
- P9/P10 (.env stage/commit) 변경.
- `grep .env README.md` 처럼 **따옴표 없는** 모호 패턴 — fail-closed 로 차단 유지 (deny-by-default, 안전 측).

## 리스크

- (R1) 따옴표-경계 휴리스틱이 quoted filename (`cat ".env"`) 을 false-negative 로 통과시킬 수 있음. → 단, quoted path (`"$HOME/.env"`) 는 `/` 경계로 여전히 차단. bare quoted filename 직접 read 는 비현실적 패턴이므로 수용.
- (R2) verb 추가로 기존 통과 케이스가 막힐 수 있음. → acceptance #5 의 기존 테스트 전체 재실행으로 방어.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps:
  - serena
rationale: >
  P8 보안 탐지 확장 + false-positive 정밀화. reproduction-first 로 true/false-positive
  케이스를 test 로 먼저 고정한 뒤 regex 를 확장한다. command_invokes/bash-guard-infra
  의 clause-anchoring 동작 추적이 핵심이라 serena 유효. 보안 차단 동작 변경이므로
  security_tier standard — 전체 security review 필수.
security_tier: standard
approved_by_user: true   # 사용자 위임 (2026-05-22) — 확정안 §0.5 스코프
```

## Self-review 예정 항목 (AGENTS.md §6)

- true-positive (시크릿 read) 모두 차단되는가
- quoted search-pattern false-positive 통과하는가
- 기존 cat/python 차단 동작 보존되는가
- safe template (.env.example 등) 통과 보존되는가
