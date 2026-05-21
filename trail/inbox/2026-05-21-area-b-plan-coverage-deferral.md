# Cycle X3.B.1 + X3.B.2 — Area B plan-coverage deferral 구현

- 날짜: 2026-05-21
- 유형: refactor (hook 책임 재배치 + commit gate flush 신설)
- design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md (X3.B.0 PASS)
- DoD: trail/dod/dod-2026-05-20-area-b-plan-coverage-deferral.md

## 변경 파일

- `plugins/rein-core/hooks/post-edit-plan-coverage.sh` — validator 즉시 호출 제거, `.plan-coverage-dirty` append 로 deferral. mkdir-based mutex `.plan-coverage-dirty.lock` 으로 race 보호. PIPE_BUF 초과 또는 lock contention 시 legacy immediate validator fallback (vocal stderr).
- `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh` — `flush_plan_coverage_dirty()` 함수 신설 (commit/test 분기 진입 직후 호출). 같은 lock 획득 후 dirty list 와 stale `.processing` merge → validator → `.coverage-mismatch` 생성 또는 fail-closed.
- `tests/hooks/test-plan-coverage-deferral.sh` — 신규 16 cases (T1~T5 post-edit append, T6~T11 flush, T12~T14 lock + fallback, T15 stale+fresh merge, T16 validation-fail vocal)
- `tests/hooks/test-coverage-matrix.sh` — 4 legacy fn 갱신 (deferral contract 매칭, 14/14 PASS)
- `tests/hooks/run-all.sh` — 신규 test 등록

## Design contract 매핑

- `post-edit-plan-coverage-defers-validator-to-commit-gate-when-dirty-plan-list-non-empty-keeping-edit-time-cost-at-append-marker-only` → post-edit-plan-coverage.sh 의 `append_dirty_path()`
- `commit-gate-flushes-plan-coverage-dirty-list-and-runs-validator-once-per-dirty-plan-emitting-existing-p2-deny-on-fail` → pre-bash-test-commit-gate.sh 의 `flush_plan_coverage_dirty()` (lock + merge + validator + P2 deny path 재사용)

## 리뷰 흐름

- codex Round 1 NEEDS-FIX (HIGH race) — open-before-rename window
- mkdir-based mutex 적용 → codex Round 2 NEEDS-FIX (HIGH stale+fresh masking)
- stale+fresh merge fix + T15/T16 추가 → codex Round 3 **PASS**
- security-reviewer Round 1 **PASS** (0/0/0/0/0)

## 테스트 결과

- `test-plan-coverage-deferral.sh`: 16/16 PASS
- `test-coverage-matrix.sh`: 14/14 PASS
- 전체 hook suite (`bash tests/hooks/run-all.sh`): ALL SUITES PASSED

## 다음 작업

- X3.B.3 (선택 보강): `post-edit-review-gate.sh` 의 dirty source path 본문 append. 별 cycle, 우선순위 낮음 (design memo §5.3, security 영향 없음)
- X3.B.5: master plan §4.2 본문 amendment ("6 hook 일괄 이동 → 1 hook 만 실제 본질 변경") + B.5 의 cycle grouping 갱신
- X3.B.4 추가 보강 가능: validator nonzero exit-code 정밀 구분 (codex Round 1 Advisory — runtime error vs FAIL 분리). 우선순위 낮음
