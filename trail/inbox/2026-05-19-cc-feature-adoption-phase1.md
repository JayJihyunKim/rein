# cc-feature-adoption Phase 1 구현 (v1.4.0 후보)

- 날짜: 2026-05-19
- 유형: feat + refactor
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 1, Task 1.1~1.6)
- 커밋: `57301c8` (dev, 단일 커밋, 82 파일, +3252/-997 — origin/dev 미푸시)

## 요약

Claude Code v2.1.144 hook·subagent 기능 채택 + Rein 내부 최적화 plan 의 Phase 1
(7 Scope ID) 을 구현. feature-builder 서브에이전트 기반 — Wave 1(1.1‖1.5) 병렬,
1.4→1.2→1.3→1.6 순차. codex 3R(NEEDS-FIX→NEEDS-FIX→PASS) + security PASS.

## 구현 내역 (7 Scope ID)

- **HK-1**: `post-write-*` 4 sub-hook → `post-edit-*` rename + 전 참조 마이그레이션
- **HK-2**: `pre-bash-guard.sh` → `pre-bash-safety-guard.sh`(상시) + `pre-bash-test-commit-gate.sh`(if-gated) 분리, 공통 `lib/bash-guard-infra.sh` — 17 차단지점(P1-P11·I1-I6) 전수 배정
- **RT-1/RT-2**: 라우팅 추천 YAML 에 `security_tier` + `complexity`/`model_hint`/`effort_hint`; test-commit-gate 가 `security_tier:light`+`approved_by_user:true` 시 `.security-reviewed` 면제 (fail-closed)
- **HK-3**: PostToolUse(Agent) 리뷰 트리거 hook `post-agent-review-trigger.sh` 신설
- **PERF-1**: `rein-aggregate-incidents.py` 복합 CLI; session-start aggregate 3회→1회
- **AG-1**: `feature-builder` → base/fix/refactor 3 변형 분화

## 리뷰 (통합 1회 — 사용자 지정 단일 커밋)

- codex Round 1 NEEDS-FIX → R2 NEEDS-FIX → **R3 PASS** (`.codex-reviewed`)
  - R1 HIGH: security_tier active-DoD 선택이 알파벳순 glob → `select_active_dod` 정식 resolver 로 교체
  - R1 MEDIUM: `post-write-` 잔존 참조 2건 → migrate
  - R2 HIGH: security_tier 추출이 DoD 전체 grep → `## 라우팅 추천` 섹션 스코프 awk 로 교체
  - 회귀 테스트 추가: `test-security-tier-gate.sh` case j(stale-DoD)·k(out-of-section) → 11/11
- security-reviewer **PASS** — 취약점 0, gate split·security_tier skip fail-closed 확인 (`.security-reviewed`)

## 검증

- `tests/hooks/run-all.sh` + `tests/scripts/run-all.sh` 전체 PASS
- 신규/회귀 테스트: safety-guard 11/11, test-commit-gate 14/14, security-tier 11/11,
  post-agent-review-trigger 6/6, aggregate-combined 8/8, feature-builder-variants 19/19,
  bash-guard-split 28/28, hk1-rename 5/5

## 미해결 / 선행 문제 (Phase 1 범위 밖 — 기록)

- `tests/integration/test-fresh-design-spec-review-no-fallback.sh`: Option C Phase 3
  `.claude/hooks/` overlay 제거 잔재로 orphan(run-all 미등록). Phase 1 이 참조 마이그레이션
  + 4/5 복구. Scenario 3(session-start dangling marker) 은 선행 문제로 잔존.
- `tests/hooks/test-session-end-stamp.sh` 11/18 fail — dev HEAD 선행 (worktree 검증).
- scripts run-all 에 간헐적 flaky 테스트 (개별·재실행 전부 PASS — 선행, Phase 1 무관).
- 미커밋 잔존: trail 회전 churn, DoD/inbox/index/stamps, `imporve_plan.md`,
  `docs/{brainstorms,plans,specs}/2026-05-19-cc-feature-adoption.*`, `.serena/`.

## 다음 단계

- VERSION bump (v1.4.0) 은 main 머지 시점 결정 (versioning Rule B) — dev 미변경.
- Phase 2 (SPIKE-1, no bump) → Phase 3 (DEC-1·PLN-1·AG-2) 는 별도 릴리즈.
