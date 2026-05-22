# DoD — X4.C.5 State machine atomic 결합 (fast-path latency 개선)

- 날짜: 2026-05-22
- 유형: refactor (성능 최적화 — correctness/behavior 영향 0)
- master plan: `docs/plans/2026-05-20-integrated-roadmap.md` 영역 C, cycle 묶음 **X4.C.5** (선택 잔존 → 사용자 진행 결정 2026-05-22)
- plan ref: docs/specs/2026-05-21-area-c-state-machine.md (design memo §9 Q-5 + §8.5 후속 cycle)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md §9 (Q-5), docs/reports/2026-05-21-area-c-state-machine-spike.md §5

## 목표 (Why)

영역 C fast-path 가 X4.C.4 SPIKE 에서 **NET REGRESSION** 판정 (M1 +59ms / M2 source_edit +66~68ms, M2 answer 만 -32ms). 원인은 fast-path 가 state 를 확인할 때 python 을 여러 번 호출 (`state_is_valid` + `read_effective_mode` + dirty match 각각 별도 invocation) → python cold-start (~25ms/회) 누적이 절감분을 초과. 본 cycle 은 이 호출들을 **single python invocation 으로 atomic 결합** 하여 cold-start 횟수를 줄여 regression 을 break-even 또는 개선으로 전환 시도. correctness 영향 0. 부수적으로 codex Round 7 advisory 의 2-call TOCTOU (X4.C.3) 도 1-call 로 해소.

## 성공 기준 (Acceptance)

1. `state-machine.sh` 에 결합 함수 신설 — single python invocation 으로 (a) state_is_valid 판정 + (b) effective_mode 추출 + (c) dirty_files match 를 한 번에 수행, 단일 lock 하에서. 기존 `state_is_valid` / `read_effective_mode` 는 하위호환 유지 (다른 호출처 있을 수 있음 — grep 확인).
2. **3 state-read fast-path hook** (M1 `pre-edit-dod-gate`, M2a `post-edit-design-plan-coverage-rule`, M2b `post-edit-routing-procedure-rule`) 의 fast-path 호출부를 결합 함수로 교체. **M3 `post-edit-spec-review-gate` 는 N/A** — 이 hook 의 fast-path 는 marker mtime-dedup 이라 `state_is_valid`/`read_effective_mode` 호출이 없어 결합 대상 아님 (design memo §8.4 의 "4 hook" 표현은 두 상이한 skip 메커니즘을 한 heading 으로 묶은 loose 표현 — codex X4.C.5 review 확인). **fast-path skip 판정 결과가 기존과 동일** (behavioral-contract test 로 검증 — 같은 state 입력 → 같은 skip/proceed 결정).
3. **SPIKE 재측정** (`tests/hooks/bench-state-fast-path.sh`, N=50, 동일 환경) — atomic 결합 후 M1/M2 latency 측정. design memo §9 Q-5 추정 (M1 net -1~+21ms, M2 source_edit 회귀 절반 축소) 대비 실측 비교.
4. correctness: 기존 `tests/hooks/test-state-machine.sh` 전부 PASS + 결합 함수 단위 test 추가 (state_is_valid 동치 / effective_mode 동치 / dirty match 동치 / malformed→legacy fallback 보존).
5. **판정 분기**: 재측정이 break-even/개선이면 영역 C 완전 close. 여전히 회귀면 Option B (M1/M2 fast-path 제거 또는 limit) 를 사용자에게 제시 — atomic 결합 후에도 안 되면 fast-path 자체를 걷어내는 결정.

## 제외 (Out of scope)

- behavior/correctness 변화 — 본 cycle 은 순수 성능 리팩토링. fast-path 의 skip 의미·gate 차단 조건 불변.
- 영역 B `.plan-coverage-dirty` 와 state.dirty_files 통합 — Q-1 에서 **분리 유지** 결정 (SPIKE §4). 본 cycle 은 영역 C 내부만.
- state.json single-writer property 변경 — dispatcher 가 유일 writer (design memo §4.1). 결합 함수는 **read-only** (writer 아님).
- X3.B.3 (영역 B dirty path append) — 사용자 미진행 결정 (2026-05-22).

## 리스크

- (R1) 결합 함수의 single python 이 기존 3~5 호출의 의미를 정확히 재현 못하면 fast-path 오판 (잘못 skip = gate 우회). → behavioral-contract test (acceptance #2) + malformed fallback test (acceptance #4) 로 방어.
- (R2) atomic 결합 후에도 회귀 잔존 가능 (design memo §9 Q-5 가 이미 "M2 source_edit 여전히 회귀" 명시). → acceptance #5 판정 분기로 정직하게 처리 (실패해도 Option B 경로 존재).
- (R3) python 1회 cold-start 자체가 25ms — 절감 추정의 정확도 한계 (SPIKE §5). → 추정 아닌 실측 (acceptance #3) 으로 판정.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor   # refactor — 기능 변경 없이 구조 개선 (researcher-first)
skills:
  - rein:codex-review                   # 필수 리뷰 gate (.codex-reviewed stamp)
mcps:
  - serena                              # state-machine.sh 함수 심볼 분석 + 호출처 추적 (find_referencing_symbols)
rationale: >
  atomic 결합은 기존 동작 보존이 최우선인 성능 리팩토링 → feature-builder-refactor 의
  researcher-first 전략 (기존 구조 파악 후 기능 불변 개선) 이 적합. state-machine.sh +
  4 hook 의 호출처 정확 추적이 핵심이라 serena 의 symbol 분석이 유효. codex-review 는
  commit gate 필수. security 는 read-only 리팩토링이라 light tier 후보 (correctness 보존
  + 외부 입력 boundary 변화 없음).
security_tier: light   # read-only 성능 리팩토링 — 외부 입력/보안 경계 변화 없음. 사용자 승인 (2026-05-22)
approved_by_user: true # 사용자 승인 (2026-05-22) — 추천 조합 그대로
```

## Self-review 예정 항목 (AGENTS.md §6)

- 결합 함수가 기존 3~5 호출과 동치인가 (behavioral-contract)
- malformed/schema-mismatch 시 legacy fallback 보존되는가
- SPIKE 재측정 수치가 추정과 부합하는가 (정직한 판정)
- 매직넘버/하드코딩 없는가, shellcheck clean 유지하는가
