# DoD — Option C v1.2.0 spec 초안 작성

- 날짜: 2026-05-13
- 유형: spec 작성 (design 단계)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md` (작성 예정)
- plan ref: 없음 (plan 은 후속 cycle)

## 작업 기준

### 목표

Option C "plugin SSOT + thin maintainer overlay" 의 spec 초안 작성. brainstorm 의 7개 Open Questions 를 spec 단계에서 해소 (코드 검증 + 사용자 결정).

### Scope (명시)

- 포함:
  - spec markdown 작성 (`docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`)
  - frontmatter `scope-id-version: v2` (behavior-level contract)
  - Scope Items 표 (v2 behavior-level)
  - Open Questions 7건 해소:
    1. prompt inject gap (`subagent-review`, `background-jobs`) — 사용자 inject 경로 정의 또는 의도된 dev-only 분류
    2. `.claude/settings.json` hook 매핑 — dogfood install 시 제거할 정확한 항목
    3. drift checker + plugin rules validator 통합 vs 별개 유지
    4. `legacy-shipped-pending` 의 docs/rules/ mirror 처리
    5. `branch-strategy.md` 새 정의 표 형식
    6. dogfood install 절차 (`claude --plugin-dir` vs `/plugin marketplace add file://`)
    7. `enabledPlugins` schema 검증 (`.claude/settings.json` 의 `"plugins": {"rein": "^1.0.0"}`)
  - 사용자 결정 변수는 AskUserQuestion 으로 묻기 (의도 추측 오염 방지)
  - codex spec-review mode 통과 → `trail/dod/.spec-reviews/<hash>.reviewed` 생성
- 제외:
  - 실제 구현 (별 plan/implementation cycle)
  - `branch-strategy.md` / `.claude/settings.json` / `.claude/CLAUDE.md` / drift checker 의 실제 편집
  - dogfood install 실행
  - plan 작성 (별 cycle)

### 성공 기준

- [ ] spec markdown 작성 (Problem / Scope Items / Decisions / Constraints / Implementation Sketch / Testing / Rollback)
- [ ] Scope Items 표 = v2 behavior-level (예: `settings-json-hook-removal-yields-zero-duplicate-trigger-on-dogfood-install`)
- [ ] 7 Open Questions 모두 해소 (결정 또는 implementation cycle 이관 명시)
- [ ] codex spec-review mode PASS
- [ ] `trail/dod/.spec-reviews/<hash>.reviewed` stamp 생성

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review
mcps: []
rationale: |
  spec 작성은 brainstorm 산출물 + 코드 검증 + 사용자 결정 합성. 메인 세션 Claude 가 직접 책임지고 작성하는 게 가장 자연스러움 (subagent dispatch 불필요 — author/reviewer 권한 분리 원칙 § subagent-review.md).
  spec review 만 codex-review 호출 (Mode A spec subflow → .codex-reviewed 안 찍고 .spec-reviews/<hash>.reviewed 만 생성).
approved_by_user: true
```

## 범위 연결

- design ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- work unit: spec 작성 cycle (단일 step)
- covers: spec 작성 자체는 plan covers 매트릭스 대상 아님 (plan 이 후속 cycle 에서 작성됨)
