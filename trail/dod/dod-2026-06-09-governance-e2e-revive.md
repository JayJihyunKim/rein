# DoD — governance e2e 통합 테스트 부활 (폐기 hook 경로 → plugin SSOT)

작성일: 2026-06-09
slug: governance-e2e-revive

## 배경 / 동기

`tests/integration/test-governance-e2e.sh` 는 governance 무결성 trio(validator v2 + pre-edit-dod-gate + pre-bash-test-commit-gate + codex-review wrapper + govcheck)의 end-to-end 회귀를 검증하려는 테스트다. 그러나 두 겹으로 죽어 있다:

1. **폐기 경로 참조**: `sandbox_init()` 가 hook 을 `$REAL_PROJECT_DIR/.claude/hooks/` 에서 복사한다. Option C Phase 3 에서 `.claude/hooks/` 는 폐기됐고(실측: 부재), 실제 SSOT 는 `plugins/rein-core/hooks/`. → `cp: No such file or directory` 가 4개 시나리오에서 발생, hook 부재로 게이트 호출이 깨짐. 실측: `Tests run: 5, Passed: -8, Failed: 13`(카운터까지 음수).
2. **러너 미등록**: `tests/hooks/run-all.sh` 와 CI(`.github/workflows/*.yml`) 어디에도 이 테스트가 없다. 깨진 채 아무도 실행하지 않아 회귀 신호가 죽어 있다(select-active-dod 등 게이트 변경을 e2e 가 못 잡음).

검증된 수정 패턴 존재: `tests/hooks/lib/test-harness.sh`(line 29-54)가 이미 `.claude/hooks` 우선 + `plugins/rein-core/hooks` fallback 으로 복사하되 sandbox 타겟 레이아웃은 `.claude/hooks/` 로 유지한다(hook 이 sandbox 내 상대경로로 lib 를 찾으므로).

## 범위

### IN
- `test-governance-e2e.sh` `sandbox_init()` 의 hook/lib cp 소스를 `.claude/hooks` 우선 + `plugins/rein-core/hooks` fallback 으로 변경(test-harness.sh 검증 패턴). sandbox 타겟 레이아웃 `$SANDBOX/.claude/hooks/` 는 유지.
- 5개 시나리오가 실제 plugin hook 으로 통과하도록 확인(scripts/lib resolve 가 sandbox 에서 정합하는지 실측, 필요한 최소 보정).
- 테스트 러너 등록: `tests/hooks/run-all.sh`(또는 적절한 상위 러너)가 이 e2e 를 호출하도록 추가 → 회귀 신호 부활.

### OUT
- 카운터 로직(assertion-fail 누적 vs 시나리오 단위 — `Passed: -8` 음수 원인) 재설계: 수정 후 0 fail 이면 표면화 안 됨. 별도.
- govcheck.py / hook 본체 / validator 동작 변경 — 테스트 인프라만 수정.
- 다른 `.claude/hooks` 참조 테스트 일괄 점검 — 그들은 test-harness.sh fallback 으로 이미 통과(전체 hook 스위트 PASS). 본 cycle 은 governance-e2e 한정.

## 변경 파일
- tests/integration/test-governance-e2e.sh
- tests/hooks/run-all.sh

## 검증 기준
- 수정 후 `bash tests/integration/test-governance-e2e.sh` → `Failed: 0` + 5 시나리오 통과(Passed: 5). `cp: No such file or directory` 0건.
- 등록된 러너 실행 시 governance-e2e 가 호출되어 통과.
- 전체 hook 테스트 스위트 회귀 없음(ALL SUITES PASSED 유지).
- reproduction: 수정 전 현재 상태(Failed 13)가 red, 수정 후 green.

## 라우팅 추천

agent: 직접 편집 (메인 세션 — 테스트 인프라 수정, reproduction-first)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: low
model_hint: opus
effort_hint: medium
rationale:
  - 죽은 통합 테스트의 hook 소스 경로 정합 + 러너 등록. 검증된 패턴(test-harness.sh) 존재라 직접 수정이 단순
  - governance 게이트 trio 검증 경로라 보안 리뷰 standard 보수 적용(테스트가 실제 게이트를 정확히 호출하는지 회귀 신뢰성 확인)
  - 경로 fallback + 러너 1줄 등록 + 시나리오 통과 확인 → complexity low
approved_by_user: true
