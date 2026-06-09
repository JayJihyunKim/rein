# governance e2e 통합 테스트 부활

작업일: 2026-06-09
DoD: trail/dod/dod-2026-06-09-governance-e2e-revive.md
상태: dev 커밋 완료, main 배포 대기 (내일 묶음; tests-only = no bump)

## 근본 원인 (두 겹)
1. 폐기 경로: `sandbox_init()` 가 `.claude/hooks/`(Option C Phase 3 폐기, 실측 부재)에서 hook 복사 → cp 전부 실패 → 4/5 시나리오 붕괴(Tests run 5, Passed -8, Failed 13).
2. 러너 미등록: `run-all.sh`/CI 어디에도 없음 → 회귀 신호 죽음(게이트 변경을 e2e 가 못 잡음).

## 수정
- cp 소스 fallback: `.claude/hooks` 우선 + `plugins/rein-core/hooks` SSOT fallback (`tests/hooks/lib/test-harness.sh` 검증 패턴). sandbox 타겟 `.claude/hooks/` 유지(hook 이 lib 를 상대경로로 resolve).
- Scenario 2 bash-guard assertion: 옛 `exit 2 + stderr` → 현재 JSON deny 계약(`exit 0 + stdout permissionDecision:deny + COVERAGE_MISMATCH`). 살아있는 `test-pre-bash-test-commit-gate.sh` 의 `assert_json_deny` 정합.
- `run-all.sh` 에 governance-e2e 등록(`$SCRIPT_DIR/../integration/`).

## 디버깅 여정 (systematic-debugging — 가설 폐기 기록)
- 처음 1개 시나리오(tier1_unknown bash-guard) fail. 가설1 = 커밋게이트 self-heal 재검증의 cwd 누락(`pre-bash-test-commit-gate.sh:346` 이 :332/:854/:857 의 `cd PROJECT_DIR` 패턴 안 따름). hook 에 cd 추가 → **여전히 fail**.
- 격리 재현(validator 단독): cwd 맞든 틀리든 둘 다 exit 2(plan 못찾아도 exit 2 "plan ref path not found"). 즉 hook 은 어차피 차단해야 → **cwd 가설 폐기**, hook 수정 원복.
- 격리 재현(bash-guard 단독): hook 이 실제로 JSON deny(exit 0 + stdout permissionDecision:deny, COVERAGE_MISMATCH) 정상 차단. **hook 은 완벽 정상.**
- 진짜 원인 = 테스트 assertion 이 JSON deny 전환 전(exit2+stderr) 기준으로 낡음.
- 교훈: 가설 위에 가설 쌓지 말 것(systematic-debugging Iron Law). 컴포넌트 경계(validator / bash-guard)에서 격리 재현으로 증거 수집 → 진짜 원인 특정.

## 검증
- governance-e2e 5/5 green. 전체 hook 스위트 ALL SUITES PASSED(이제 governance-e2e 포함 실행).
- codex PASS(gpt-5.5) + 보안 PASS(standard, 차단 은폐 아님 확인). dogfood: 이번 리뷰 라벨 marker-blocking 으로 governance-e2e-revive 정확 선택.

## 발견 (무해, 미수정)
- `pre-bash-test-commit-gate.sh:346` self-heal validator 호출이 cwd 미고정(:332/:854/:857 과 불일치). 현재 validator 가 plan 못찾으면 exit 2(차단)라 외부 동작 무해 → 코드 일관성 개선 후보로만 남김(우선순위 낮음).

## 다음
- main 배포(내일, v1.4.7 후속 묶음). 활성 백로그 0(active-DoD + governance-e2e 둘 다 종결).
