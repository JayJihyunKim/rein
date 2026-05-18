# 스마트 라우팅 A+ — 인벤토리 스캐너 폐기 + routing-procedure 강화

- 날짜: 2026-05-18
- 유형: refactor + docs
- 변경 파일:
  - 삭제: `rein-scan-skill-mcp.py` ×2, `rein-generate-skill-mcp-guide.py` ×2,
    `tests/hooks/test-skill-mcp-inventory.sh`, `tests/scripts/test-state-path-inventory-plugin.sh`
  - dewire: `session-start-load-trail.sh`, `pre-edit-dod-gate.sh`, `rein-state-paths.py`
  - 강화: `plugins/rein-core/rules/routing-procedure.md`
  - 문서: `.claude/CLAUDE.md`, `.claude/orchestrator.md`, `.claude/rules/branch-strategy.md`, `AGENTS.md`
  - 테스트: `tests/hooks/run-all.sh`, `test-session-end-stamp.sh`, `test-session-start-tone.sh`,
    `tests/scripts/test-plugin-scripts-bundle.sh`
  - DoD: `trail/dod/dod-2026-05-18-smart-routing-a-plus.md`
- 요약: 스마트 라우팅의 인벤토리 스캐너 서브시스템을 폐기. 스캐너는 Claude Code 의
  비문서화 plugin 저장 레이아웃(`~/.claude/plugins/cache` 등)에 결합돼 빈 결과만
  냈다. 라우팅을 Claude Code 가 매 세션 주입하는 skill/agent/MCP 목록 기반으로
  전환하고, dev-only `orchestrator.md` 의 발견/매칭 알고리즘을 plugin 배포본
  `routing-procedure.md` 로 이식해 self-contained 화. 발견=세션 주입 목록,
  매칭=정적 권장 조합표 (디스크 스캔 없음).
- 설계 근거: 본 세션 다중 라운드 tradeoff 검토 + `/codex-ask` (gpt-5.5, high)
  독립 검토 → Option A+ 수렴 ("스마트함" 은 파일 본문 스캔이 아니라 좋은
  description + 큐레이션 + override/feedback 학습으로 확보).
- 실행: 2-agent 병렬 (Agent A = routing-procedure.md / Agent B = 폐기·dewire·테스트·문서).
- 검증: codex 코드리뷰 R2 PASS (R1 의 doc-consistency 2건 — CLAUDE/orchestrator/
  branch-strategy stale 참조 — fix 후), 보안 리뷰 PASS (hook dewire 무손상·
  dangling 0·표면 축소), `tests/hooks/` 전체 회귀 `ALL SUITES PASSED`.
- 미커밋: dev 미커밋 — 커밋·main 머지는 사용자 결정 대기.
- 미처리 메모: codex-review wrapper 가 stale active DoD 를 envelope 에 주입
  (생성된 stamp 의 `cycle`/`active_dod` 가 직전 사이클 `hook-test-drift-cleanup`
  을 가리킴 — need-to-confirm G8-3 별건, 이번 changeset 결함 아님).
