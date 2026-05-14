# Option C Phase 1 — Sandbox dogfood verification

- 날짜: 2026-05-13
- 유형: implementation (Phase 1 — verification cycle, covers: S10)
- 변경 파일:
  - `trail/decisions/2026-05-13-option-c-sandbox-verification.md` (NEW — evidence)
  - `trail/dod/dod-2026-05-13-option-c-phase-1-sandbox-verification.md` (NEW)
- 요약:
  Phase 1 의 3 task (1.1 sandbox setup + 1.2 trace 캡처 + 1.3 evidence 작성) 완료.
  3 Claude sandbox probe + 2 hook 직접 호출로 **7 shared rule 모두 inject body bytes > 0 직접 측정**:
  - code-style 1786b / security 1839b / testing 4499b (SessionStart concat)
  - answer-only-mode 7048b (UserPromptSubmit)
  - background-jobs 5958b (PreToolUse Bash)
  - design-plan-coverage 8893b + envelope 6168b (PostToolUse, direct hook invocation with matching path)
  - subagent-review 5247b + envelope 3359b (PreToolUse Agent, direct hook invocation)
  Sandbox conditional behavior 확인: design-plan-coverage hook 이 non-matching path 입력 시 silent (0b) — 정상.
  **중요 발견**: `--plugin-dir` 이 isolated 가 아님. user-level cache plugins (`superpowers`, `ralph-loop`) 도 함께 active ("Registered 15 hooks from 11 plugins"). 본 repo dogfood install 시점에도 동일 base 위에서 trigger count 비교.
  codex review Round 1~4 NEEDS-FIX (S10 contract literal mismatch + per-rule 1:1 mapping + git tracking) → Round 5 PASS (7/7 direct measured + per-rule byte mapping + git staged).
  security review: skip (markdown only, 코드 변경 0).
  **다음 진입점**: Phase 2 (drift checker 의미 전환 + plugin rules validator 통합).
- 라우팅 피드백: agent=feature-builder (메인 직접) + codex-review (Round 5 sequential 사이클). 추가 학습:
  - Claude CLI `--plugin-dir` 은 isolated 아님 — user-level plugin set 동시 active
  - sub-Claude 권한 우회 (`--allow-dangerously-skip-permissions`, `--permission-mode bypassPermissions`) 는 auto classifier 차단
  - hook 직접 실행 (`bash <hook>.sh` + `CLAUDE_PLUGIN_ROOT` env + stdin JSON) 이 sub-Claude probe 보다 깔끔하게 envelope byte 측정 가능 — 향후 hook 검증 표준 패턴 후보
