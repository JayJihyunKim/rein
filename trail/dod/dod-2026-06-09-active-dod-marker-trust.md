# DoD — active-DoD 선택기 마커 신뢰 (범위 연결 필수 요구 제거)

작성일: 2026-06-09
slug: active-dod-marker-trust

## 배경 / 동기

`select-active-dod.sh` 의 Tier 1(명시적 `.active-dod` 마커, blocking authority)은 마커가 가리키는 DoD 에 `## 범위 연결` 섹션이 있어야만 인정한다. 그러나:

- `## 범위 연결` 은 `design-plan-coverage.md` 가 명시한 **선택(optional) 섹션** — "DoD 는 `## 범위 연결` 섹션을 포함할 수 있다" (plan 과 연결된 DoD 만 보유). plan-less DoD(작은 작업·answer-only escape 후 DoD)는 이 섹션이 없는 게 정상.
- 마커 writer(`post-edit-dod-routing-check.sh`)는 **라우팅 승인 확정 시** `.active-dod` 를 작성한다 — plan 유무와 무관.
- → writer(승인 기반)와 reader(범위연결 필수)의 contract 불일치. 마커가 plan-less DoD 를 정확히 가리켜도 Tier 1 에서 거부되어 Tier 2 로 fall through, `## 범위 연결` 가진 옛 DoD 가 대신 선택된다.

실측(2026-06-09): `.active-dod` = `dod-2026-06-09-codex-review-model-unify-gpt55.md`(plan-less), incident log `marker target missing '## 범위 연결'` 2회, 선택 결과 = 옛 `dod-2026-06-04-route-bind-1`. 현재 trail/dod/ 20개 중 `## 범위 연결` 보유는 1개뿐 → 선택기가 거의 항상 옛 plan-기반 DoD 로 fall through. 어제(2026-06-08)도 동일 증상 재현.

증상: (1) 리뷰 기록의 cycle/active_dod 라벨이 옛 작업으로 오염, (2) plan-기반 DoD 가 trail/dod 에 없으면 Tier 0 → 보안등급 light 에서 commit 차단.

## 범위

### IN
- `select-active-dod.sh` Tier 1 에서 `_sad_dod_has_range_link` 체크 제거. 마커가 가리키는 DoD 가 (a) containment 통과 + (b) 파일 존재면 Tier 1 인정. `## 범위 연결` 유무 무관.
- Tier 1 의 incident 로그/주석/design 설명을 새 동작에 맞게 갱신 (범위연결 거부 사유 제거).
- 재현 테스트 추가: 마커가 `## 범위 연결` **없는** DoD 를 가리킬 때 → Tier 1 (현재는 Tier 2 fall through). reproduction-first.

### OUT
- Tier 2(advisory fallback, 마커 부재 경로)의 `## 범위 연결` 필터 — 정상 워크플로는 항상 마커가 존재(라우팅 승인 시 자동 작성)하므로 Tier 2 는 거의 미사용. 변경 시 영향 범위 큼(마커 없는 모든 경우의 advisory 추측 동작) → 별도 cycle.
- coverage validator(`rein-validate-coverage-matrix.py`) 동작 변경 — 범위연결 있는 DoD 의 covers 검증은 그대로. 범위연결 없는 DoD 는 validator 가 검증 대상 없음으로 통과(기존 동작).
- `## 범위 연결` 섹션 규격/의미 변경 — design-plan-coverage 의 optional 위상 그대로.

## 변경 파일
- plugins/rein-core/hooks/lib/select-active-dod.sh
- tests/hooks/test-select-active-dod.sh

## 검증 기준
- 새 재현 테스트: 마커 → `## 범위 연결` 없는 DoD → `select_active_dod` 가 tier=1 + 그 DoD 경로 반환 (수정 전 red: tier=2 옛 DoD).
- 기존 테스트 보존: Test 1(범위연결 가진 마커 → Tier 1), Test 2(마커 없음 → Tier 2 최신), Test 3(마커 없음 + 후보 없음 → Tier 0), Test 4(무효 마커 target missing → Tier 2 + incident log) 모두 통과.
- `bash -n plugins/rein-core/hooks/lib/select-active-dod.sh` 구문 통과.
- `tests/hooks/run-all.sh`(존재 시) 또는 hook 테스트 스위트 회귀 없음.

## 라우팅 추천

agent: 직접 편집 (메인 세션 — 작은 hook 로직 수정, TDD)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: low
model_hint: opus
effort_hint: medium
rationale:
  - 게이트 코어(active DoD 선택)의 분기 1개 제거 + 재현 테스트. 단일 함수 수정이라 직접 TDD 가 단순
  - DoD 게이트 selection 경로라 보안 리뷰 standard 보수 적용 — blocking authority 부여 조건 변경이므로 containment 가드 보존 확인 필요
  - 분기 제거 + 테스트 1개 → complexity low
approved_by_user: true
