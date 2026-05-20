# DoD — cc-feature + performance 통합 roadmap 작성

- 날짜: 2026-05-20
- 유형: docs (master plan 통합)
- slug: integrated-roadmap

## 범위 연결

plan ref: docs/plans/2026-05-20-integrated-roadmap.md
work unit: 본 plan 의 §1 (개요) — meta-cycle (plan 작성 자체 = plan 의 첫 work unit)
covers: []

> 본 DoD 는 plan 작성 cycle 자체이므로 covers 는 빈 배열. plan 의 잔존 영역 (§4 A~E) 의 신규 Scope ID 는 별 cycle (X1~X5) 의 design amendment 와 함께 등재될 예정. validator 는 legacy advisory (matrix 섹션 없음) 로 처리 — exit 0.

## 배경

어제 (2026-05-19) 작성된 `docs/plans/2026-05-19-cc-feature-adoption.md` (16 Scope ID, Phase 1~4, hook/agent/perf 채택) 과 오늘 (2026-05-20) untracked 로 떠 있는 `rein-performance-plan.md` (6 Phase, performance 중심) 두 trajectory 가 **부분만 중복**하고 나머지는 분기. 사용자 의도: 두 source 를 단일 master plan 으로 통합 + 진행 완료 간략 + 잔존 작업 무게 + 작업 종료까지 본 plan 참조.

## 매핑 점검 (이전 답변에서 확정)

| performance-plan Phase | cc-feature-adoption 매핑 | 상태 |
|---|---|---|
| Phase 1 rule injection off | UPS-1 (short summary 전환, 의도 일부 일치) | 부분 완료 (UPS-1 land + 오늘 회귀 fix) |
| Phase 2 short rule + Bash `if` | UPS-1 + PERF-3 (background-jobs `if`-field hot-path) | ✅ 완료 |
| Phase 3 Bash dispatcher 통합 | — | ❌ 미포함, 잔존 |
| Phase 4 post-edit 다이어트 (commit-이동) | HK-4 (분할/병렬화) 만 매핑, commit 이동은 미포함 | 부분 (분할만 완료) |
| Phase 5 State machine | — | ❌ 미포함, 잔존 |
| Phase 6 Release gate 분리 | — (별 cycle e 와 가까우나 다름) | ❌ 미포함, 잔존 |

## 작업 범위

### 신규 산출물

- `docs/plans/2026-05-20-integrated-roadmap.md` — 단일 master plan
  - 구조: 진행 완료 요약 (간략) + 잔존 작업 자세히 (무게)
  - design ref: 두 source (`docs/specs/2026-05-19-cc-feature-adoption.md` + `rein-performance-plan.md` 노트)
  - matrix: legacy advisory (`## Design 범위 커버리지 매트릭스` 섹션 없이 작성 — validator 강제 안 함). 신규 Scope ID 가 등재되려면 별 cycle 에서 design amendment 필요 (본 plan 안에서 amendment 권고 명시)
  - 잔존 Phase 5종 (Bash dispatcher / post-edit diet / state machine / release gate / scaffold 청소) 의 Phase 별 task 목록 + risk + 의존 + 우선순위
  - 본 plan 참조 의무 명시 (매 session SessionStart 후 진입점으로 사용)

### 부수 처리

- `rein-performance-plan.md` (untracked) → 통합 후 정보 가치 plan 으로 이동. 원본은 commit 대신 docs/archive/ 또는 단순 삭제 (사용자 미요청이므로 일단 untracked 유지, commit 안 함)
- `trail/index.md` 의 "다음 진입점" 을 본 통합 plan 으로 갱신

## 변경 범위

| 파일 | 변경 |
|---|---|
| `docs/plans/2026-05-20-integrated-roadmap.md` | 신규 (master plan) |
| `trail/dod/dod-2026-05-20-integrated-roadmap.md` | 본 DoD (이 파일) |
| `trail/inbox/2026-05-20-integrated-roadmap.md` | inbox 기록 |
| `trail/index.md` | 진입점 갱신 — 본 plan 참조 |

## 비범위

- `docs/specs/2026-05-19-cc-feature-adoption.md` 의 spec amendment (별 cycle — design 변경은 codex spec review 필요)
- 잔존 Phase (Bash dispatcher / state machine 등) 의 **실제 구현** — 본 cycle 은 plan 통합만, 구현은 별 cycle
- `rein-performance-plan.md` untracked 파일의 commit (정보 가치는 master plan 으로 이동, 원본 archive 결정은 사용자에게 위임)

## 검증 기준

- [ ] `docs/plans/2026-05-20-integrated-roadmap.md` 작성 — 진행 완료 16 Scope 요약 1단락 + 잔존 5 phase 각각 별 섹션
- [ ] 통합 plan 이 두 source 의 중복 (UPS-1 / PERF-3 ↔ performance Phase 1/2) 을 명확히 표기
- [ ] 잔존 Phase 의 의존 + risk + 우선순위 명시
- [ ] codex review PASS (spec review mode? 아니면 일반 code review mode? — plan 단독 작성이므로 `[NON_INTERACTIVE] spec review for plan:` marker 사용)
- [ ] trail/index.md 의 진입점이 본 plan 을 참조하도록 갱신
- [ ] 매 session SessionStart 후 새 작업 시작 전 본 plan 을 read 하도록 명시 (plan 본문 + index 본문 양쪽)

## 라우팅 추천

```yaml
agent: rein:docs-writer
skills:
  - rein:codex-review
mcps: []
security_tier: light
rationale: |
  - agent: master plan 작성 = docs/changelog writer 영역. rein:writing-plans 는 design 문서 입력 받아 matrix+covers 강제 plan 자동 작성용인데, 본 작업은 두 기존 source 의 manual merge + 진행도 요약 + 잔존 작업 정리로 docs-writer 가 적합.
  - skills/codex-review: spec review mode 로 통합 plan 의 일관성/완전성/우선순위 검증.
  - mcps: 없음.
  - security_tier: light — docs only, secret/외부 input/exec 없음.
approved_by_user: true
```

## 라우팅 승인 사유

사용자 명시 "스스로 판단" + Auto Mode + 명확한 요구사항 (두 source 통합, docs/ 작성, 작업 종료까지 참조). docs-writer agent 호출보다는 직접 Write 도구로 작성하는 게 단순 — master plan 은 두 source 의 직접 비교/병합이라 agent dispatch overhead 불필요.
