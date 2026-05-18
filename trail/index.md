# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **스마트 라우팅 A+ 구현 완료 — dev 미커밋.** 인벤토리 스캐너 서브시스템 (`rein-scan-skill-mcp.py`/`rein-generate-skill-mcp-guide.py` ×2 + `skill-mcp-inventory.json`/`skill-mcp-guide.md`) 폐기 — Claude Code 의 비문서화 plugin 저장 레이아웃에 결합돼 빈 결과만 내던 것. 라우팅을 Claude Code 가 매 세션 주입하는 skill/agent/MCP 목록 기반으로 전환하고, dev-only `orchestrator.md` 의 발견/매칭 알고리즘을 plugin 배포본 `routing-procedure.md` 로 이식 (self-contained). `session-start-load-trail.sh`/`pre-edit-dod-gate.sh`/`rein-state-paths.py` dewire. DoD `dod-2026-05-18-smart-routing-a-plus.md`. 2-agent 병렬 실행. codex 코드리뷰 R2 PASS (R1 의 doc-consistency 2건 fix 후), 보안 리뷰 PASS, `tests/hooks/` 전체 회귀 `ALL SUITES PASSED`. 설계: 본 세션 tradeoff 검토 + `/codex-ask` gpt-5.5 high → Option A+ 수렴. **다음 작업**: A+ dev 커밋 → 그 후 FU-1~4(`ed8d690`) + v1.3.1 + A+ 묶음 main 머지 (`branch-strategy.md` 선별 체크아웃, `git tag v1.3.1`). dev origin/dev 미push (A+ 커밋 전 11 commit ahead). 미처리: codex-review wrapper 가 stale active DoD 를 envelope 주입 (stamp `cycle`/`active_dod` 가 직전 사이클 가리킴 — G8-3 별건), pre-bash-guard 라인 163 `git (merge|rebase|am)` 면제 unanchored (후보).
- **이전 완료**: 2026-05-18 **need-to-confirm FU-1~4 묶음** (`ed8d690` dev 커밋 — incidents-to-rule AGENTS.md 부재 분기 / mirror AGENTS.md public strip / spec-review resolver fix / pre-bash-guard 분류기 clause-앵커링; codex R4 + 보안 PASS). / 2026-05-18 **hook 비서톤 2단계 cycle (v1.3.1)** (Wave 1~4 `5f83022`~`c0a39c3` dev 커밋, main 머지 대기). / 2026-05-17 **2단계 plan**. / 2026-05-16~17 **hook 비서톤 1단계** (`a1d45b1`). / 2026-05-16 **Q9 + publish CI fix main 머지** (`ba9058e`). / 2026-05-15 **v1.3.0** (main `0709064`, tag). / 2026-05-14 **v1.2.0 / v1.1.3**. / 2026-04-30 v1.0.0 OSS launch.
- **버전**: dev VERSION = **1.3.1** (`scripts/rein.sh`, dev `c0a39c3` — hook 비서톤 2단계 + 드리프트 정리). main/origin = `ba9058e` (v1.3.0 `0709064` 기반, VERSION 1.3.0). public/main = 2026-05-16 mirror. public `v1.3.0` tag → `045f54a`. **v1.3.1 tag 는 미생성** — main 머지 후 생성 예정. release/git/branch/tag/publish claim 은 답변 전 명령 재검증 필수.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
