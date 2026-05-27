# G3 Phase 1 — route-time advisory layer (routing-map rule + emit list)

- 날짜: 2026-05-27
- 유형: feat
- 변경 파일:
  - `plugins/rein-core/rules/routing-map.md` (신규, 774B)
  - `plugins/rein-core/hooks/session-start-rules.sh` (line 41 for-loop 에 `routing-map` 1 단어 append)
  - `tests/hooks/test-routing-map-emit.sh` (신규, 3 assertion)
  - `trail/dod/dod-2026-05-27-g3-phase1-route-time.md` (신규 DoD)
  - `trail/dod/.codex-reviewed` (self-review stamp, prior_reviewer=codex)
- 요약:
  - SessionStart 첫 turn 의 additionalContext 에 routing-map.md 본문 emit (작업 유형 → agent/skill 압축 매핑 표 7행 + routing-procedure.md 링크).
  - codex round 1 verdict PASS + Medium 1건 (`기술 조사` row 의 skill 컬럼이 SSOT 와 drift — `rein:codex-ask` 가 second-opinion 행에 속한 항목인데 잘못 들어감) → self-review path (§3 Escalation: Medium ≤ 3줄) 로 1 줄 수정 (`rein:codex-ask` → `—`), 787B → 774B.
  - 신규 테스트 PASS, 기존 `test-session-start-rules.sh` 회귀 PASS, plugin drift 0.
  - security_tier: light + 변경 surface 정적 markdown + hardcoded literal → security stamp 미생성 (operating-sequence Step 6 light tier 규정).
- plan ref: `docs/plans/2026-05-27-g3-execution-mode-advisor.md` (Phase 1 / Task 1.1 + 1.2 + Phase 4 Task 4.2 — Scope ID G3-RM)
- 다음 작업: G3 Phase 2 (run-time meta-check core + policy loader 확장) — 별 DoD. Phase 2 Task 2.1~2.4 sequential.
