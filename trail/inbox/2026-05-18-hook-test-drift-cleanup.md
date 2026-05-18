# hook test 드리프트 정리 — 23 suite

- 날짜: 2026-05-18
- 유형: test (no-bump internal — versioning.md Rule A: tests/** only)
- DoD: trail/dod/dod-2026-05-18-hook-test-drift-cleanup.md

## 배경

`tests/hooks/run-all.sh` + `tests/rules/run-all.sh` 에서 23 suite 가 실패 상태였다.
codex 진단으로 근본 원인 5 분류 → 4 병렬 + 후속 fix 에이전트로 정리.

## 변경 (23 test 파일, production 코드 0 — 순수 test-only)

- **Bucket A (~15)** — 폐기 경로 `.claude/hooks/` → `plugins/rein-core/hooks/` repoint (Option C Phase 3 후 SSOT 이동 미반영분).
- **Bucket B (2)** — Wave 3 회귀: test-dod-gate / test-pre-edit-dod-gate `BLOCKED`/`[DoD gate]` 단언 → `[rein]` 갱신.
- **stale 단언 (4)** — test-coverage-matrix / test-stop-incident-gate / test-incidents-semi-automation-full / test-incidents-automation `test_gate_blocks_when_pending` — Wave 1/3 메시지 재작성 반영.
- **#15** — test-incidents-automation: migration 4 테스트 + run_migrate() 삭제 (codex 조사: `rein-migrate-blocks-log.py` 는 v1.0.1 의도적 삭제 helper).
- **#22** — test-design-plan-coverage-plugin-size: 크기 예산 10000→12000B (규칙 문서 정상 증가).
- **#18~23 fixture 재설계 (4)** — BG-1 `.rein/project.json` 계약 / pre-edit gate path-scope filter / SessionStart auto-bootstrap (`REIN_NO_AUTO_BOOTSTRAP` opt-out 활용) / runtime-only 상태 파일 — 현재 계약 기준으로 fixture 재설계. hook 은 모두 정상 (의도된 동작), 테스트 fixture 가 stale 이었음.

## 결과

Task 4.1 — `tests/hooks/**` + `tests/rules/**` 전체 회귀 `ALL SUITES PASSED` (23/23 + 무회귀).
codex-review 2 round (R1 Medium 2건: I3 단언 과도 완화 + test-oracle hollow pass → R2 PASS)
+ security-review PASS (test-only, production surface 0).
처리 incident 2건 (pre-bash-guard P4 stale stamp / pre-edit-dod-gate covers mismatch — 둘 다
멀티-Wave 세션 내부 artifact, 사용자 Decline).
