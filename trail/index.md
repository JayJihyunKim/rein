# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **v1.2.0 cycle 종결 (구현 + 통합 review PASS), main 머지 + tag + push 대기** — DoD `trail/dod/dod-2026-05-14-plugin-mode-gap-fix.md`. 15 Scope IDs + Wave 5 잔존 fix F1-F9 모두 완료. stamps 생성 (sonnet-fallback codex + base security PASS). ALL SUITES PASSED. 사용자 확인 후 main 선별 체크아웃 + tag v1.2.0 + push 진행 — 자동 trigger: mirror-to-public + publish-plugin. 상세: `trail/inbox/2026-05-14-v1-2-0-cycle-complete.md`.
- **이전 완료**: 2026-05-14 **v1.2.0 cycle 구현 + 통합 review 완료** — Wave 1 (7 parallel + 5 fix, 이전 session) → Wave 2 (SEC-1+SEC-2 parallel) → Wave 3 (OPSEQ-1+WF-1+RTG-1 parallel) → Wave 4 (INC-1→RTG-2 sequential) → Wave 5 (F1-F9 잔존 fix 9건) → sonnet-fallback code review (codex wrapper hang, F6/F7/F8/F9 추가 fix 후 ALL SUITES PASSED) → base security review PASS. / 2026-05-14 **v1.1.3 release** (main `d8727c8`, tag `v1.1.3`). / 2026-05-13 Option C Phase 1~5 완료. / 2026-05-12 v1.1.2 (`c15bdb1`) / v1.1.1 (`6f588ca`) / v1.1.0 (`9360650`). / 2026-04-30 v1.0.0 OSS launch.
- **버전**: VERSION = 1.2.0 (`scripts/rein.sh`, plugin.json 동기화). main HEAD = `d8727c8` (v1.1.3, origin 푸시 완료). dev HEAD = `b9d6ad7` + working tree 누적 (v1.2.0 cycle 변경, 미 commit). v1.0.0~v1.1.3 tags 존재. v1.2.0 tag 대기. release/git/branch/tag/publish claim 은 답변 전 명령 재검증 필수.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 만 유효
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
