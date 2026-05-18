# DoD — hook 메시지 비서톤/다국어화 2단계 구현

- 날짜: 2026-05-17
- 유형: feat

## 목표

plan `docs/plans/2026-05-17-hook-message-assistant-tone.md` (Phase 1~4 / Task
1.1~4.3) 을 구현한다 — emitter `deny_emit` 3슬롯 재설계, pre-bash-guard 정책 차단
11지점 JSON deny 전환, 사용자 대면 hook 메시지 4표면 비서톤 재작성, AGENTS.md
trail/docs 작성 언어 규칙 추가.

## 완료 기준

- plan Task 1.1~4.3 전부 구현, Scope Items S1~S10 충족
- emitter 3슬롯 + reason_code 필수화, fail-closed 불변식 보존 (신규 fail-open 0)
- pre-bash-guard: 정책 차단 11지점 `exit 0 + JSON deny`, 인프라 5지점 `exit 2` 유지
- 회귀 테스트 통과 (test-json-deny-emitter 14 시나리오, pre-bash-guard 계열)
- codex review + security review 통과 → VERSION 1.3.1

## 범위 연결

plan ref: docs/plans/2026-05-17-hook-message-assistant-tone.md
work unit: Phase 1~4 전체
covers: [S1, S2, S3, S4, S5, S6, S7, S8, S9, S10]

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:subagent-driven-development
  - superpowers:test-driven-development
mcps: []
rationale: >
  bash hook + python 직렬화 구현 — feature-builder 가 신규 기능 구현 전담.
  subagent-driven-development 로 plan 의 13 task 를 implementer subagent 에
  디스패치, TDD 로 각 task 실패 테스트 우선. 외부 API/문서 조회 없어 MCP 불요.
approved_by_user: true  # 2026-05-17 사용자 승인 — 진행 방식: 4 Wave 연속
```

## 병렬 진행 계획 (agent teams)

plan 의존성상 emitter(Phase 1) → pre-bash-guard(Phase 2) 는 순차. 독립 task 만 병렬:

- Wave 1: [Phase 1 — Task 1.1→1.2→1.3 순차] ∥ [Task 3.3 SessionStart] ∥ [Task 3.5 AGENTS.md]
- Wave 2: [Phase 2 — Task 2.1→2.5 순차] ∥ [Task 4.2 보존 문서]
- Wave 3: Task 3.1 → 3.2 → 3.4 (순차 — pre-bash-guard / stop-session-gate 공유)
- Wave 4: Task 4.1 (전체 회귀) → Task 4.3 (versioning)

각 task: implementer subagent → spec reviewer → code+security reviewer (subagent-review.md).
