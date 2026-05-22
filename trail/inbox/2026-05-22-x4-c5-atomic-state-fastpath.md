# X4.C.5 — State machine atomic fast-path 결합 (영역 C 완전 close)

- 날짜: 2026-05-22
- 유형: refactor (성능 최적화, correctness 0 변화)
- master plan: `docs/plans/2026-05-20-integrated-roadmap.md` 영역 C, cycle X4.C.5
- 변경 파일:
  - `plugins/rein-core/hooks/lib/state-machine.sh` — 신규 `read_fast_path_state [match_path]` (single python + single shared lock 으로 state_is_valid + effective_mode + dirty match 결합). 기존 함수 하위호환 유지.
  - `plugins/rein-core/hooks/pre-edit-dod-gate.sh` (M1) — 5 python+1 lock → 1 호출
  - `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh` (M2a) — 3 python+1 lock → 1 호출
  - `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh` (M2b) — 동일
  - `tests/hooks/test-state-machine.sh` — behavioral-contract test 10개 추가 (T7-T16, T16=legacy 동치)
  - `docs/plans/2026-05-20-integrated-roadmap.md` / `docs/reports/2026-05-21-area-c-state-machine-spike.md` / `trail/index.md` — 진행도 반영
- 요약: 영역 C fast-path 가 X4.C.4 SPIKE 에서 NET REGRESSION (python cold-start 누적). 여러 python 호출을 single invocation 으로 atomic 결합 → SPIKE 재측정 실측 **regression 전 시나리오 제거** (M1 +57→-33ms, M2a +76→-4ms, M2b +81→-9ms, answer-skip win 확대). 추정(M1 net -1~+21ms) 초과 달성. **영역 C 완전 close**, Option B 불필요.
- 리뷰: codex Mode A Round 1 → NEEDS-FIX 2건 (Medium: read_fast_path_state 주석이 invalid-state fallback 을 "non-zero"라 했으나 실제 rc 0+valid=0 / Claim: DoD "4 hook" 이 실제 3개+M3 N/A). Round 2 author 정정 = 주석/test-title/DoD only (코드 0줄). self-review PASS (escalation §3: Medium + 코드 0줄 → sonnet self-review). codex 핵심 동치성 "no behavioral equivalence defect" PASS.
- 보안: security_tier light (read-only 리팩토링, 외부 입력/보안 경계 변화 0) — 사용자 승인, .security-reviewed stamp 면제. .codex-reviewed (self-review) 생성.
- test: test-state-machine 16/16, 전체 hook suite ALL SUITES PASSED (회귀 0).
- 발견: design memo §8.4 "4 hook" 은 두 상이한 skip 메커니즘(state-read fast-path 3개 + M3 marker-dedup)을 한 heading 으로 묶은 loose 표현. X4.C.5 가 정정.
- commit: 미실행 (사용자 요청 시). 변경은 plugins/rein-core/** (main 머지 대상) + tests/** 포함.
