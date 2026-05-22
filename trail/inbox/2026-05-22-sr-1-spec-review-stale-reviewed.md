# SR-1 spec-review gate stale `.reviewed` 우회 차단

- 날짜: 2026-05-22
- 유형: fix (security gate hardening)
- 변경 파일:
  - `plugins/rein-core/hooks/post-edit-spec-review-gate.sh` (+10) — fix (b)
  - `plugins/rein-core/hooks/pre-edit-dod-gate.sh` (+23) — fix (a)
  - `tests/hooks/test-spec-review-gate.sh` (+191, SR-1 테스트 6건)

## 요약

리뷰 완료된 spec/plan 을 다시 편집하면 새 `.pending` + 옛 `.reviewed` 가 공존하고, gate 가 `.reviewed` 존재만 검사해 통과시키던 **리뷰 우회**를 2겹으로 차단.

- **(b) 주방어** — `post-edit-spec-review-gate.sh`: canonical spec/plan 편집 감지 시 같은 hash 의 기존 `.reviewed` 를 `rm -f` (create/touch 분기 앞) → 재리뷰 강제.
- **(a) 백스톱** — `pre-edit-dod-gate.sh` spec gate: `.reviewed` 존재 시 `.pending.created` vs `.reviewed.reviewed` 비교. trailing Z strip 후 엄격 ISO regex(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$`) shape 검증 → 누락/garbled = fail-closed. 통과 시 digit-only 숫자 비교(locale-independent). created > reviewed → stale 차단. 디스크에 이미 공존하는 stale state 도 즉시 차단.

## 검증

- TDD: 우회 시나리오 6건 failing test 선작성 → 구현 → 27/27 PASS.
- codex R1 NEEDS-FIX(garbled 미검증 High + locale Medium) → 수정 → R2 PASS → R3 PASS(editorial).
- security review (full, standard level): CRITICAL/HIGH/MEDIUM 없음, fail-open 회귀 없음.
- 무회귀: test-dod-gate 8/8, test-pre-edit-dod-gate 14/14.
- 사전 실패: `test-fresh-design-spec-review-no-fallback.sh` 의 "dangling marker NOT cleaned up" 1건은 baseline(git stash)에서도 실패 — SR-1 무관, 별개 이슈.

## 잔존 (향후 후보 — SR-1 범위 밖, pre-existing 신뢰 경계)

- **Info-1**: 백스톱은 `.pending` 존재 전제. post-edit hook 미발화(hooks 비활성/외부 IDE write/`git checkout` 복원/MultiEdit JSON 파싱 실패 exit 0) 시 새 `.pending` 미생성 + 옛 `.reviewed` 잔존 → source 편집 허용 가능. SR-1 이전부터 gate 가 `.pending` 마커에 키잉한 동일 신뢰 경계 (본 변경의 신규 갭 아님). 강화 옵션: pre-edit gate 가 `*.reviewed` 도 순회해 매칭 `.pending` 부재 시 spec 파일 mtime 을 `reviewed=` 와 비교. 별 작업.

## 라우팅 피드백

- agent: 메인 세션 직접 구현 (DoD 추천=feature-builder-fix, 컨텍스트 완비로 메인 세션 채택, 사용자 승인). reproduction-first TDD 적합 — 우회 6 시나리오를 failing test 로 고정 후 수정. 정확.
- skills: rein:codex-review (commit gate) — 3 round 으로 High 1건 잡아냄. 효과적.
