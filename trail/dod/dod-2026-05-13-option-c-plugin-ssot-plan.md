# DoD — Option C plan 초안 작성

- 날짜: 2026-05-13
- 유형: plan 작성 (design 단계 후속)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md` (작성 예정)

## 작업 기준

### 목표

Option C spec 의 Implementation Sketch (Phase 1~5) 를 task-level plan 으로 구체화. spec 의 4 Open Questions (O1~O3, O5) 를 plan 단계에서 해소 후, coverage 매트릭스 + `covers:` 메타데이터를 작성한다.

### Scope (명시)

- 포함:
  - plan markdown 작성 (`docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`)
  - Design 범위 커버리지 매트릭스 (spec 의 S1~S10 implemented/deferred)
  - Phase / Task 분해 + 각 work unit 의 `covers: [...]` 메타데이터
  - O1~O3, O5 해소:
    - O1: 통합 도구 이름 (코드 검증 + Claude 결정)
    - O2: 나머지 3 plugin docs/rules mirror 처리 (`background-jobs`, `design-plan-coverage`, `subagent-review`) — 사용자 결정 (D4 와 같은 분류로 단일화 vs 유지)
    - O3: `enabledPlugins` schema 검증 (Context7 또는 WebFetch Claude Code docs)
    - O5: workflow surface 영향 (`mirror-to-public.yml`, `govcheck.yml`, `tests.yml`, `publish-plugin.yml`) — 코드 read
  - codex spec-review mode (plan subflow) 통과 → `trail/dod/.spec-reviews/<hash>.reviewed` 생성
- 제외:
  - 실제 구현 (별 implementation cycle 들 — 각 phase 별 cycle 또는 묶음)
  - drift checker / overlay / branch-strategy 의 실제 편집
  - dogfood install 실행
  - 사용자 영향 발생 작업

### 성공 기준

- [ ] plan markdown 작성 (Design 범위 커버리지 매트릭스 + Phase/Task + 각 task 별 covers + 실행 단계 + 검증)
- [ ] `python3 scripts/rein-validate-coverage-matrix.py docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md` 통과
- [ ] O1~O3 + O5 모두 해소 또는 implementation cycle 의 정확한 task 로 명시 이관
- [ ] codex spec-review mode PASS
- [ ] `trail/dod/.spec-reviews/<hash>.reviewed` stamp 생성

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - writing-plans
  - codex-review
mcps:
  - plugin:context7:context7 (enabledPlugins schema 검증용)
rationale: |
  plan 작성은 spec 후속. 메인 세션 직접 작성 (author/reviewer 권한 분리 — spec 의 author 가 plan author 도 자연스러움). writing-plans skill 이 coverage 매트릭스 + covers 메타데이터 가이드. codex-review (plan subflow) 가 검증.
  Context7 MCP 는 O3 (enabledPlugins schema) 검증용. plan 직전 Claude Code 공식 docs 확인.
approved_by_user: true
```

## 범위 연결

- design ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- work unit: plan 작성 cycle (단일 step)
- covers: 본 cycle 자체는 plan 의 coverage 매트릭스 대상이 아님 (plan 작성을 위한 메타 cycle)
