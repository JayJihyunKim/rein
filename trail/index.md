# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **v1.3.0 release dev commit 완료 — main 선별 체크아웃 + push 대기**. 다음 cycle 후보: v1.2.0 의 mirror-to-public Q9 root cause / release postcondition verifier / BG-B allow-list anchor (security LOW-1) / partial-bootstrap stale marker 정리 (codex round 1 missed defect #3). 상세: `trail/inbox/2026-05-15-bootstrap-gate-deadlock-fix.md`.
- **이전 완료**: 2026-05-15 **v1.3.0 dev commit** — BG-A~J (10 scope IDs) bootstrap gate deadlock fix + auto-bootstrap + degraded mode. 통합 codex review round 1 NEEDS-FIX → round 2 PASS + security review PASS. 48/48 fixture PASS. / 2026-05-14 **v1.2.0 release 완료** — 15 Scope IDs + Wave 5 F1-F9 + main fixup F10/F11/F12 + public v1.2.0 force re-tag (clean commit `11169372`). / 2026-05-14 **v1.1.3 release** (main `d8727c8`, tag `v1.1.3`). / 2026-05-13 Option C Phase 1~5. / 2026-04-30 v1.0.0 OSS launch.
- **버전**: VERSION = 1.3.0 (dev `scripts/rein.sh`, `plugin.json` 동기화). main/origin 은 1.2.0 (`d20506e`) — 본 cycle dev commit 후 main 선별 체크아웃 대기. public/main = `11169372` (1.2.0 시점). v1.0.0~v1.2.0 tags 존재 (v1.3.0 tag 미생성). release/git/branch/tag/publish claim 은 답변 전 명령 재검증 필수.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 만 유효
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- main 머지 시 mirror-to-public 의 Q9 force re-tag 가 실패 가능 — 검증 후 manual force push (codex-ask 권고)
- **2026-05-15 paused cycle**: main `.claude/` overlay cleanup (DoD: `dod-2026-05-14-main-claude-overlay-cleanup.md`, dev `b9d6ad7` push 완료). v1.2.0 release 와 충돌 가능성 — v1.2.0 이 trail/ + `.rein/project.json` 을 main 에 include 하기로 변경했으므로 본 cycle 의 `.claude/` exclusion 가정도 재검토 필요. 상세: `trail/inbox/2026-05-15-main-claude-overlay-cleanup-paused.md`
