# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **통합 master plan 활성 — `docs/plans/2026-05-20-integrated-roadmap.md` 우선 read**. 본 plan §4 잔존 영역 A~E 종결까지 매 session 진입 시 §4 작업 목록 + §5 우선순위 확인 의무 (advisory). **다음 권장 cycle = X2 (영역 A — Bash dispatcher 통합, plan §4.1 / §5.1)** — 별 spec/design amendment 동반. ✅ Cycle X1 (영역 E.1 + E.2, scaffold 청소) 완료 (commit 대기): `tests/rein-test.sh` 를 현 CLI 표면 검증으로 재작성 (15/15 PASS) + bootstrap drift 진단 결과 drift 아닌 layered SSOT 확정. 오늘 dev 진행 cycle 누적: UPS-1 회귀 fix (`6504dd6`) + hook-test-stale-references (`2b8519c`) + 통합 plan (`07b4443`) + 본 Cycle X1 (commit 대기). local dev HEAD = origin/dev = `07b4443` + 본 cycle 미커밋. main = origin/main = `7795193` (v1.3.2, 불변). release/git/branch/tag/publish claim 은 답변 전 명령 재검증 필수.
- **이전 완료**: 2026-05-19 **v1.3.2 릴리즈** (main `7795193`, annotated tag, public mirror + 마켓플레이스 publish). / 2026-05-18 v1.3.1. / 2026-05-15 v1.3.0. / 2026-04-30 v1.0.0 OSS launch.
- **버전**: 본 Phase 2c commit 직후 dev VERSION = **1.3.3** (Phase 2b + 2c 묶음 push 예정). main = origin/main = **1.3.2** (annotated tag `v1.3.2` → `7795193`, 불변). 분류 노트: Phase 2c = no bump (internal refactor — user-facing outcome 동일).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
