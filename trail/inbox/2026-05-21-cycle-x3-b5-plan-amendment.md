# Cycle X3.B.5 — master plan amendment + B.4 validator nonzero 정밀화

- 날짜: 2026-05-21
- 유형: docs (master plan 정정) + refactor (validator runtime error vs FAIL 분리)
- design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md §5.5 (X3.B.0 PASS)
- DoD: trail/dod/dod-2026-05-21-cycle-x3-b5-plan-amendment.md

## 변경 파일

- `docs/plans/2026-05-20-integrated-roadmap.md` — §4.2 본문 정정 ("6 hook 일괄 commit 이동" → design memo §4 decision table 의 "Group A 1 hook 본질 변경" 권고안). §5.1 cycle 묶음 권고를 X3.B series (X3.B.0/.1+.2/.5/.3) 로 분해. ✅ 완료 표기 (X1/X2/X3.E.3/X3.B.0/X3.B.1+B.2). E.3 합류 추정 해제 명시.
- `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh` — `flush_plan_coverage_dirty()` 의 validator rc 분기 분리:
  - rc 0 → PASS (continue)
  - rc 2 → validation FAIL (real validator contract, `.coverage-mismatch` 기록)
  - rc != 0,2 → runtime error (Python crash/import error 등 infra integrity issue) → fail-closed (return 2) + stderr `validator runtime error (rc=N) on <path>`
  - mixed: runtime error wins (return 2), validation FAIL evidence 는 `.coverage-mismatch` 에 보존
- `tests/hooks/test-plan-coverage-deferral.sh` — 두 stub validator FAIL rc 1→2 통일 (real validator contract 정합). T17 (runtime error fail-closed) + T18 (mixed runtime + FAIL) 추가. codex Round 1 Low advisory 반영해 T17 assertion `|` → 분리 grep 2회 (phrase + rc value 둘 다 강제).

## Design contract 매핑

- 영역 B design memo §5.5 (X3.B.5 step) — master plan §4.2 amendment + §5.1 cycle 묶음 갱신 ✅
- codex Round 1 Advisory (runtime error vs FAIL 분리) — flush rc 분기 + T17/T18 회귀 ✅

## 리뷰 흐름

- codex Round 1 **PASS** (Low advisory 1건: T17 assertion 강도) — 즉시 self-review 로 grep 분리 (3줄 변경, escalation §3 sonnet self-review path)
- security-reviewer Round 1 **PASS** (intermediate level, profile.yaml standard)
- 두 stamp 모두 생성: `.codex-reviewed` (resolution: passed) + `.security-reviewed`

## 테스트 결과

- `test-plan-coverage-deferral.sh`: 18/18 PASS (T1~T16 기존 + T17/T18 신규)
- `test-coverage-matrix.sh`: 14/14 PASS (회귀 0)
- 전체 hook suite (`bash tests/hooks/run-all.sh`): **ALL SUITES PASSED**
- `bash tests/rein-test.sh`: 15/15 PASS

## 잔존 / 다음 작업

- X3.B.3 (선택 보강, post-edit-review-gate dirty source path append) — 별 cycle, 우선순위 낮음
- **영역 C 진입** — `.rein/state.json` state machine design memo. 영역 A ✅ 완료로 진입 가능. 본 cycle 후속.
- 영역 D — Release gate 분리 + v1.3.3 main 머지, 영역 A/B/C 안정화 후

## Note — codex stamp 후 test edit

codex stamp 생성 후 T17 assertion 을 grep 분리로 강화 (Low advisory 반영). 본 변경은 test 의 assertion 강도만 조정 (production code 행동 변화 없음) — codex 의 production code PASS verdict 유효. self-review 로 처리.
