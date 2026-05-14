# Option C — plan 초안 작성

- 날짜: 2026-05-13
- 유형: plan 작성 (design 단계 후속)
- 변경 파일:
  - `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md` (NEW)
  - `trail/dod/dod-2026-05-13-option-c-plugin-ssot-plan.md` (NEW)
  - `trail/dod/.spec-reviews/<hash>.reviewed` (NEW — plan codex Round 2 PASS)
- 요약:
  spec 의 Implementation Sketch 6 phases 를 task-level 로 분해. 6 phases × 30+ tasks. coverage 매트릭스 S1~S10 implemented. coverage validator PASS (scope-id-version=v2).
  4 OQ 해소:
  - O1 (통합 도구 이름): `rein-check-plugin-drift.py` 재사용 (rename 부담 없음, 의미만 진화)
  - O2 (3 mirror 처리): 사용자 결정으로 4 mirror 모두 제거 + `.claude/rules/` 만 SSOT
  - O3 (enabledPlugins schema): Task 3.0 으로 이관 (Phase 3 실행 직전 Context7/WebFetch 검증)
  - O5 (workflow surface): Phase 5 Task 5.2~5.8 로 분해 (mirror-to-public / govcheck / tests / publish-plugin / plugin-drift-check + marketplace.json + rein-publish.sh)
  codex Round 1 NEEDS-FIX (2 issues: S10 matrix 위치 PARTIAL, Phase 6 Task 6.1 의 tests/** CONTRADICTS) → Round 2 PASS (2 fix RESOLVED, all S1~S10 MATCH, no new blocker).
  **target-release: none** (Rule A internal). 본 cycle main 머지 없음. 다음 user-facing release cycle 에 plugin SSOT 변경분만 묶음 (Task 6.2).
- 라우팅 피드백: agent=feature-builder (메인 직접 작성), skills=writing-plans (가이드 참고 — 직접 호출 안 함, 매트릭스/covers 포맷 적용) + codex-review (plan mode, Round 1+2). 작업 성격 (30+ tasks 분해 + 4 OQ 해소) 대비 적합. ✓
