# hook test 5 fail stale reference 갱신

- 날짜: 2026-05-20
- 유형: refactor (test 갱신 — source-side 의도된 변화 반영)
- 변경 파일 (5):
  - `tests/hooks/test-design-plan-coverage-registered.sh` (EXPECTED_BASENAME)
  - `tests/hooks/test-hk1-post-write-rename.sh` (section 4 교체 + header comment)
  - `tests/hooks/test-post-edit-review-gate-external-paths.sh` (HOOK path)
  - `tests/hooks/test-session-end-stamp.sh` (sandbox source path × 3 + .rein marker seed)
  - `tests/hooks/test-session-start-marker-cleanup.sh` (HOOK + lib path × 2 + sandbox marker seed × 2) + chmod +x

## 요약

UPS-1 fix (commit `6504dd6`) 직후 잔존하던 5 hook test fail 을 갱신. 모두 **source-side 의도된 변화 (Phase 2b HK-4 dispatcher 분할, Option C Phase 3 `.claude/hooks/` overlay 폐기, v1.3.0 BG-D/BG-1 bootstrap-check) 미반영** 으로 인한 stale reference. test 가 의도하는 검증 (HK-1 rename / coverage rule registered / external path exemption / session_end stamp / .active-dod cleanup) 은 그대로 보존하고 reference 만 갱신.

## Root cause 분류

| 그룹 | 원인 | test 수 |
|---|---|---|
| A | Phase 2b HK-4 dispatcher deprecation 미반영 (hooks.json 에서 dispatcher 등록 해제 + 8 sub-hook 직접 등록) | 2 |
| B | Option C Phase 3 `.claude/hooks/` overlay 폐기 후 plugin SSOT (`plugins/rein-core/hooks/`) 로 path 갱신 미적용 | 3 |
| B+ | (그룹 B fix 후 추가 발견) v1.3.0 BG-D/BG-1 bootstrap-check 가 `.rein/project.json` + `trail/index.md` 부재 시 early exit — sandbox marker seed 누락 | (그룹 B 의 2 test 와 동일) |

## 검증

- 5 target test 모두 PASS:
  - test-design-plan-coverage-registered: OK
  - test-hk1-post-write-rename: OK (5/5 sections)
  - test-post-edit-review-gate-external-paths: OK 4/4
  - test-session-end-stamp: 18/18 PASS
  - test-session-start-marker-cleanup: 17/0 PASS
- 전체 81 hook test PASS, FAIL 0 — 회귀 없음

## 리뷰

- codex Round 1 PASS (low effort, gpt-5.5). Low advisory 1건 (test-hk1-post-write-rename.sh 의 file header comment 가 section 4 의 dispatcher trace 표현 잔존) → §3 escalation Low only → sonnet self-review 로 header comment 갱신.
- security tier=light: bash test path/marker seed 갱신만, secret/외부 input/command exec 신규 도입 없음.

## 발견된 다른 stale (별 cycle 후보)

`tests/rein-test.sh` (CLI integration test runner) 가 v1.0.0 OSS launch 에서 제거된 `rein new` 명령을 여전히 호출 → set -e 발동으로 첫 case 부터 abort. 본 cycle 비범위 (hook test 5 fail 만 처리). trail/index.md "별 cycle 후보 (c)" 잔존.

## 라우팅 회고

- 추천: `rein:feature-builder-refactor` (test 갱신, researcher-first) + `rein:codex-review` skill + light security tier — **검증 완료**, 적절했음
- approved_by_user: true (사용자 명시 "나한테 묻지말고 이번 세션은 스스로 판단해서 진행해봐" → reasonable call 자율 진행)
