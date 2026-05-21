# DoD — Cycle X3.B.5 (master plan amendment + B.4 보강)

- 날짜: 2026-05-21
- 유형: docs (master plan 정정) + refactor (validator nonzero 정밀화)
- design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md §5.5 (X3.B.0 PASS)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.2 + §5.1 (대상 amendment 본문)
- cycle: X3.B.5 — 영역 B series 마무리

## 범위 (Scope)

포함:

1. `docs/plans/2026-05-20-integrated-roadmap.md` §4.2 본문 amendment
   - 기존 표현: "6 hook 의 책임을 commit gate 로 이전 또는 deferred 검증 모드 도입"
   - 정정: design memo §4 decision table 기반 — **Group A 의 1 hook (`post-edit-plan-coverage`) 만 본질 변경, Group B/C 4 hook + Group A 의 `post-edit-review-gate` 5개는 현 시점 유지** 가 권고안. heavy validator fork 비용 축소가 본질
   - 본 amendment 는 §4 영역 추가/제거/우선순위 변경 아님 → master plan §7 advisory amendment 로 진행 가능 (사용자 confirmation 불필요)

2. `docs/plans/2026-05-20-integrated-roadmap.md` §5.1 cycle 묶음 권고 갱신
   - `Cycle X3` 단일 항목을 `Cycle X3.B` series (X3.B.0/.1/.2/.3/.4/.5) 로 분해 표기
   - `E.3` 합류 추정 해제 — 이미 commit `9ffaf48` 에서 단독 완료됐음 명시
   - 완료 상태 ✅ 표시 갱신: X3.B.0 / X3.B.1+B.2 / X3.E.3

3. `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh` 의 `flush_plan_coverage_dirty` 정밀화 (B.4 보강 — codex Round 1 Advisory 반영)
   - validator rc 의 두 부류 분리:
     - (A) **validation FAIL**: validator 가 정상 실행됐고 mismatch 검출 (`.coverage-mismatch` marker 가 의도된 경로) — 기존 P2 deny path 유지
     - (B) **runtime error**: validator subprocess 자체 실패 (Python import error, syntax error, OS-level fault 등 — `.coverage-mismatch` 도 안 만든 rc != 0) — 본 경우는 인프라 무결성 오류로 분류 → fail-closed (exit 2) + 명확한 stderr 메시지
   - 현재는 두 부류가 동일 path 로 흐름. 본 보강은 stderr 메시지 + exit code 만 정밀화 — 실제 차단 의미는 동일 (둘 다 commit deny)

4. `tests/hooks/test-plan-coverage-deferral.sh` 회귀 test 추가
   - (T17) validator runtime error 시 fail-closed exit 2 + 메시지 분리
   - (T18) `.coverage-mismatch` 있는 정상 FAIL path 는 기존 deny 그대로 (회귀 없음)

5. `trail/index.md` 갱신
   - X3.B series 진행 상태 (X3.B.0/.1+.2/.5 완료, X3.B.3 미진행)
   - 다음 권장 cycle = 영역 C 진입 (state machine design memo)

제외 (별 cycle):

- X3.B.3 (`post-edit-review-gate` 의 dirty source path 본문 append) — 선택 보강, 별 cycle
- 영역 C 본격 구현 — X3.B.5 완료 후 별 cycle 에서 design memo 부터
- SPIKE 측정 (design memo §9 Q-2 의 actual cumulative post-edit time 측정) — 별 cycle 권고

## 작업 기준 (Definition of Done)

1. master plan §4.2 + §5.1 amendment 가 design memo §4 decision table 과 1:1 정합
2. master plan §7 의 amendment policy 준수 — 본문 정정 (영역 추가/제거 아님) advisory amendment
3. `pre-bash-test-commit-gate.sh` 의 flush validator nonzero 분기가 runtime error vs validation FAIL 분리 + 메시지 명확
4. `tests/hooks/test-plan-coverage-deferral.sh` 신규 T17/T18 PASS
5. 기존 test (16/16 + coverage matrix 14/14 + hook suite ALL) 회귀 0
6. codex code review (Mode A) PASS — `.codex-reviewed` stamp
7. security-reviewer PASS — `.security-reviewed` stamp
8. inbox + index 갱신 + dev commit

## 검증 시나리오

- (V1) master plan §4.2 본문에 "Group A 1 hook 만 본질 변경" 표현이 명시되고 design memo §4 와 wording 일관
- (V2) master plan §5.1 표에 X3.B series 분해 + ✅ X3.B.0 / X3.B.1+B.2 / X3.E.3 갱신
- (V3) `tests/hooks/test-plan-coverage-deferral.sh` T17 — Python validator 를 임의로 깨뜨려 (stub) 실행 → flush 가 exit 2 + "validator runtime error" 메시지 + commit deny
- (V4) T18 — `.coverage-mismatch` 시나리오는 기존과 동일하게 P2 deny path (회귀 없음)
- (V5) 전 hook test suite PASS
- (V6) trail/index.md 의 "다음 권장 cycle" 이 영역 C 로 전환

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - superpowers:test-driven-development
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
rationale: |
  본 cycle 은 문서 amendment (master plan) + hook 본문 정밀화 (validator nonzero 분기) 의
  복합 작업. feature-builder-refactor 의 researcher-first 가 두 표면을 정합 검증하기 적합
  (design memo §4 와 plan 본문 + hook 의 분기 의미 cross-check). TDD 로 T17/T18 회귀
  test 먼저 작성. codex-review 는 Mode A — design 은 X3.B.0 에서 PASS 받았고 본 cycle 은
  amendment + 코드 정밀화 자체 리뷰. verification-before-completion 으로 "전 test PASS"
  실증 후 완료 선언.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "1, 2 순차 진행 오토모드" 로 본 cycle 묶음 진입에 동의. hook 차단 경로 일부 정밀화
  동반 → 표준 보안 tier (light 부적합).
```

## self-review 체크리스트

- [ ] master plan §4.2 본문이 design memo §4 decision table 과 정합 (drift 0)
- [ ] master plan §5.1 표에 X3.B series 분해 + 완료 표시 정확
- [ ] master plan §7 amendment policy 준수 — 본문 정정 advisory 로 진행
- [ ] flush validator nonzero 의 두 부류 분리가 stderr + exit code 까지 정확
- [ ] T17/T18 회귀 test 가 두 부류를 독립적으로 검증
- [ ] 전 test suite (run-all.sh) PASS — 회귀 0
- [ ] trail/index.md 의 진입점이 영역 C 로 정확히 sync
