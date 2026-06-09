# active-DoD 선택기 마커 신뢰 (범위 연결 필수 요구 제거)

작업일: 2026-06-09
DoD: trail/dod/dod-2026-06-09-active-dod-marker-trust.md
상태: dev 커밋 완료, main 배포 대기 (하루 1머지 규칙 — 오늘 v1.4.7 머지함 → 내일 배포)

## 근본 원인 (systematic-debugging Phase 1~2)
- `select-active-dod.sh` Tier 1(명시 `.active-dod` 마커, blocking authority)이 마커 대상 DoD 에 `## 범위 연결` 섹션 보유를 강제.
- 그런데 `## 범위 연결` 은 `design-plan-coverage.md` 의 **optional** 섹션(plan 연결 DoD 만 보유). 마커 writer(`post-edit-dod-routing-check.sh`)는 **라우팅 승인 시** 작성(plan 무관).
- → writer(승인 기반)와 reader(범위연결 필수) **contract 불일치**. plan-less DoD 마커가 정확히 가리켜도 Tier 1 거부 → Tier 2 fall through → `## 범위 연결` 가진 옛 plan-기반 DoD 선택.
- 증상: (1) 리뷰 기록 cycle/active_dod 라벨이 옛 작업으로 오염, (2) plan-기반 DoD 부재 시 Tier 0 → light tier commit 차단.
- 실측: trail/dod 20개 중 범위연결 보유 1개뿐 → 거의 항상 옛 DoD 로 fall through. incident log 에 2026-06-08·09 동일 거부 기록(반복 버그).

## 수정 (reproduction-first)
- Tier 1 에서 `_sad_dod_has_range_link` 체크 제거. 마커 대상이 `_sad_marker_contained`(경로 봉쇄) + `-f`(존재) 통과면 Tier 1 인정. `## 범위 연결` 무관.
- Tier 2(마커 부재 fallback)는 **미변경**(범위연결 필터 유지) — OUT 범위(영향 큼, 별도 cycle).
- 주석/design 헤더 갱신.

## 검증
- 재현 테스트 Test 1b(마커→plan-less DoD→Tier1): 수정 전 **red**(tier=2 옛 DoD fall-through), 수정 후 **green**. 기존 11 보존 → 12/12.
- 전체 hook 스위트 ALL SUITES PASSED. consumer 테스트(pre-edit-dod-gate / pre-bash-test-commit-gate / post-edit-meta-check / active-dod-auto-write) 회귀 0.
- codex 코드리뷰 PASS(gpt-5.5) — containment 순서 보존·Tier2 미변경·dead code 아님 확인.
- 보안 PASS(standard) — containment fail-closed 보존 + 다운스트림 validator 가 범위연결 없으면 exit 0 skip(편집 차단 없음) 확인.
- **dogfood 증명**: 이번 codex 리뷰 표식 active_dod = `marker-blocking`(Tier1)으로 이번 DoD 정확 선택. 직전 작업의 `advisory-latest-mtime` 오염 해소.

## 다음
- main 배포(내일, patch). governance-e2e stale 백로그 유지.
