# cc-feature-adoption 개선 설계 체인 (brainstorm → spec → plan)

- 날짜: 2026-05-19
- 유형: docs (설계 — 구현 전 단계)
- 변경 파일:
  - `docs/brainstorms/2026-05-19-cc-feature-adoption.md` (신규)
  - `docs/specs/2026-05-19-cc-feature-adoption.md` (신규 — codex spec-review 4R PASS)
  - `docs/plans/2026-05-19-cc-feature-adoption.md` (신규 — codex plan-review 3R PASS, coverage validator exit 0)
  - `need-to-confirm.md` (PD-1 우선순위 1 등재 + PD-2 추가)
  - `trail/dod/.spec-reviews/{e740bea312dabe02,fac428f9d2bde994}.reviewed` (spec·plan per-spec stamp)
- 요약:
  - `imporve_plan.md` (17항목 완전판) 분석 → 채택 13항목 (14 Scope ID, 3 Phase) / 제외 4항목 (원본 3·7·14·16 — 전제 결함, 재설계 메모 동반).
  - rein 정식 체인: brainstorm(codex-ask Step 0 sanity check) → spec(codex-review 4라운드: HK-2 hook 분리·HK-3 PostToolUse Agent 재설계·PERF-1 2→3 정정·HK-2 P/I 전수 배정) → plan(codex-review 3라운드: 참조 마이그레이션 grep-authoritative 화).
  - 작업 중 발견한 rein 버그: PD-1 (`resolve_project_dir` 가 spec-review stamp 를 repo 밖에 생성) — `need-to-confirm.md` 우선순위 1 등재. spec·plan stamp 모두 PD-1 워크어라운드(수동 in-repo 이동)로 처리.
  - 구현은 다음 세션. **사용자 지시**: 구현 전 오늘 기록된 버그 PD-1·PD-2·GUARD-1 먼저 해결.
