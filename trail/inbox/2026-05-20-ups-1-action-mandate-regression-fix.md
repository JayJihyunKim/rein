# UPS-1 회귀 fix — 행동 강령 body marker 복원

- 날짜: 2026-05-20
- 유형: fix (회귀)
- 변경 파일:
  - `plugins/rein-core/rules/short/answer-only-summary.md` (+2 lines: `## 행동 강령` 헤더)
  - `plugins/rein-core/rules/short/background-jobs-summary.md` (+2 lines: 동일)
  - `trail/dod/dod-2026-05-20-ups-1-action-mandate-regression.md` (신규)

## 요약

v1.3.3 prep Phase 4 시점 short rule (`rules/short/*.md`) 도입 때 풀버전의 `## 행동 강령` 헤더 이전이 누락돼 3 hook 테스트가 fail 하던 회귀를 fix. UserPromptSubmit / PreToolUse hook 이 `rule_inject_body short/<name>` 으로 emit 하는 `additionalContext` 본문에 `행동 강령` 문자열이 다시 포함되도록 두 short md 의 `# Title` 다음 줄에 `## 행동 강령` 헤더 + 빈 줄을 삽입.

## 검증

- 3 UPS-1 hook 테스트 PASS:
  - `test-user-prompt-submit-rules.sh`
  - `test-user-prompt-submit-bootstrap-advisory.sh` (A/B/C path 3)
  - `test-pre-tool-use-bash-rules.sh` (a/b/c path 3)
- 전체 81 hook 테스트 중 76 PASS, 5 fail 잔존 — pre-existing 회귀 (변경 stash 한 상태에서도 동일 5 fail). UPS-1 fix 는 회귀 일으키지 않음.

## 리뷰

- codex review (Mode A, low effort, gpt-5.5 default): **PASS** — Code Defects 없음, Design Alignment MATCH, Test Alignment MATCH, Claim Audit PASS. stamp: `trail/dod/.codex-reviewed` (cycle 필드는 wrapper 가 잘못된 active DoD 를 잡아서 수동 정정).
- security: light tier (markdown 본문만, secret/외부 input/command exec 없음). DoD 라우팅 `security_tier: light` + `approved_by_user: true` 로 stamp 직접 생성.

## 잔존 issue (UPS-1 무관 별 cycle 후보)

전체 81 hook 테스트 중 pre-existing fail 5 건:
- `test-design-plan-coverage-registered.sh`
- `test-hk1-post-write-rename.sh`
- `test-post-edit-review-gate-external-paths.sh`
- `test-session-end-stamp.sh`
- `test-session-start-marker-cleanup.sh`

추가로 `tests/rein-test.sh` CLI integration test 가 `rein new` 명령을 호출하나 v1.0.0 OSS launch (`1dac71a`) 에서 scaffold drop 으로 명령 제거됨 → set -e 발동으로 첫 case 에서 abort. 별 cycle 에서 test 본체 갱신 필요.

## Phase 2c claim 정정

trail/index.md 의 "Phase 2c 결과: test 33/33 PASS" 는 hook-test subset (33) 기준일 가능성이 높음 — 현재 hook-test 81 중 5 fail + rein-test 본체 abort 가 동시 존재. claim audit 으로 추후 별 cycle 에서 확인 필요.

## 라우팅 회고

- 추천: `rein:feature-builder-fix` (회귀 fix) + `rein:codex-review` skill + light security tier — **검증 완료**, 적절했음
- approved_by_user: true (Auto Mode 활성 + 사용자 "갱신하고 (a) 진행해" 명령으로 reasonable call)
