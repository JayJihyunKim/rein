# plan-writer 완료 보고 — review-evidence-manifest plan

Plan complete: docs/plans/2026-07-13-review-evidence-manifest.md
- Scope IDs: 15/15 matrix 등재 (15 implemented / 0 deferred), Task 8개 (Phase 4개)
- Validator: exit 0 (scope-id-version=v2), trail/dod/.coverage-mismatch 부재
Spec review: NEEDS-FIX (codex-gpt-5.6-sol-high-automated, 전문: scratchpad codex-spec-review-output.log)
Stamp: 생성 안 됨 (.spec-reviews/*.pending 유지)

리뷰 지적 4건 (전부 plan 문서 보완 수준):
1. EV1-fenced-example PARTIAL — "fence 안 [EVIDENCE] 예시 + fence 밖 정량 주장 + 실블록 0 → exit 4" 조합 fixture 가 Task 1.1 에 누락 (spec EV1 fixture 2번째 케이스).
2. EV3-exclusion PARTIAL — 인라인 백틱 스팬 마스킹의 구현 주체 불명확: Task 1.2 는 "Task 1.1 이 마스킹 완료" 전제이나 spec §4.1 규칙 0 은 인라인 백틱을 패턴 스캐너 전용으로 규정 — 마스킹 책임을 `_scan_quant_claims`(Task 1.2) 로 명시해야 함.
3. EV5 PARTIAL — stamp 무접촉 assertion 구체화 필요: `.codex-reviewed`/`.review-pending`/`.spec-reviews/*` 3종을 사전 seed 하고 exit 4 후 존재 + byte content 비교하는 fixture 명시.
4. awk → shell 전역 변수 전달 프로토콜 누락 — 외부 awk 프로세스는 부모 shell 변수를 못 바꾸므로 임시파일/직렬화 방식 중 무엇을 쓸지 plan 에 명시 (set -euo pipefail 하 결정론 보장).

Next (수동 개입 경로):
  (1) 위 4건 plan 반영
  (2) validator 재실행
  (3) 수동 /codex-review 호출 또는 plan-writer 재실행
