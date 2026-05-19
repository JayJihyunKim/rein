# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **cc-feature-adoption Phase 1 완료.** dev `57301c8` 단일 커밋 (82 파일, +3252/-997 — Task 1.1~1.6 / 7 Scope ID: HK-1·HK-2·RT-1·RT-2·HK-3·PERF-1·AG-1). codex 3R(NEEDS-FIX→NEEDS-FIX→PASS) + security PASS, `tests/hooks`·`tests/scripts` run-all 전체 PASS — **origin/dev 미푸시**. **다음 작업**: Phase 2 SPIKE-1 (`docs/plans/2026-05-19-cc-feature-adoption.md` Task 2.1 — 병렬 hook exit/deny + tool_use_id 측정 spike, no bump) 또는 Phase 1 main 머지 (v1.4.0, versioning Rule B). **미해결**: G8-3 · SR-1 · GE-1/GE-2 · test-fresh-design Scenario 3 (선행 orphan) · scripts run-all flaky 테스트 (선행). **미커밋 잔존**: trail 회전/stamp/DoD/inbox/index, `imporve_plan.md`, `docs/{brainstorms,plans,specs}/2026-05-19-cc-feature-adoption.*`.
- **이전 완료**: 2026-05-18 **v1.3.1 릴리즈** (main `069878c`, annotated tag, public mirror + 마켓플레이스 publish) — 스마트 라우팅 A+(`0a908a7`) / FU-1~4(`ed8d690`) / hook 비서 톤 1+2단계 묶음. / 2026-05-16 Q9 + publish CI fix (`ba9058e`). / 2026-05-15 v1.3.0. / 2026-04-30 v1.0.0 OSS launch.
- **버전**: dev VERSION = **1.3.1** (Phase 1 은 v1.4.0 후보 — main 머지 시 minor bump, dev 미변경). main = origin/main = `3ab3944` (v1.3.1 릴리즈 `069878c` + README docs 패치). **annotated tag `v1.3.1` → `069878c`** (불변). dev HEAD = `57301c8` (cc-feature-adoption Phase 1, `02a69b1` 의 자식 — **origin/dev 미푸시**). release/git/branch/tag/publish claim 은 답변 전 명령 재검증 필수.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
