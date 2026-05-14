# Option C v1.x — plugin SSOT + thin maintainer overlay — spec 초안

- 날짜: 2026-05-13
- 유형: spec 작성 (design 단계)
- 변경 파일:
  - `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md` (NEW)
  - `trail/dod/dod-2026-05-13-option-c-plugin-ssot-spec.md` (NEW)
  - `trail/dod/.spec-reviews/<hash>.reviewed` (NEW — codex Round 2 PASS)
- 요약:
  brainstorm 의 7 Open Questions 를 spec 단계에서 D1~D7 로 해소 (D1 prompt inject gap 없음 검증, D2 settings.json 6 hook 제거 대상, D3 drift checker + validator 통합 — 사용자 결정, D4 plugin docs/rules legacy mirror 제거 — 사용자 결정, D5 branch-strategy 새 표, D6 dogfood install 절차 — sandbox 먼저 + 본 repo 전환 7 sub-step, D7 enabledPlugins schema 는 plan 직전 확정 보류).
  Scope Items 10개 v2 behavior-level contract. Implementation Sketch 6 phases. Testing Strategy deterministic. Migration/Rollback phase 별.
  codex Round 1 NEEDS-FIX (6 issues: Phase 3 unsafe ordering, D4 brainstorm 모순, versioning Rule A target-release, Scope IDs S2/S3/S9 약함, Testing S2/S4/S9/S10 weak, missing surface) → Round 2 PASS (all 6 RESOLVED, no new blocker).
  **target-release: none (Rule A 기준 internal — no VERSION bump, no tag, no main 머지)**. 사용자 zero impact. plan 단계에서 O1~O3, O5 해소 후 implementation.
- 라우팅 피드백: agent=feature-builder (메인 세션 직접 spec 작성), skills=codex-review (spec mode, Round 1 + Round 2). Explore agent 1 dispatch (7 OQ 코드 사실 검증). 작업 성격 (spec 작성 + 7 OQ 해소) 대비 적합. ✓
