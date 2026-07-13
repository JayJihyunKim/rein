# review evidence manifest plan spec review

- 완료일: 2026-07-13
- 대상 plan: `docs/plans/2026-07-13-review-evidence-manifest.md`
- 대상 design: `docs/specs/2026-07-13-review-evidence-manifest.md`
- 결과: NEEDS-FIX

## 확인 결과

- coverage validator exit 0, design Scope ID 15개와 plan matrix ID 15개가 정확히 일치한다.
- wrapper → mirror → SKILL.md → tests 순차 구현과 TDD 누적 fixture 구조는 전반적으로 실행 가능하다.
- spec §8 수용 기준 1–14는 Task 1.1~1.4, 2.1, 3.1, 4.1~4.2에 모두 연결된다.

## 수정 필요

1. fenced 예시 + fence 밖 정량 주장 + 실제 블록 0 조합 fixture가 빠져, fenced 예시를 유효 블록으로 잘못 계수하는 회귀를 탐지하지 못한다.
2. 인라인 백틱 마스킹은 Task 1.1 산출에 없지만 Task 1.2가 이미 제거된 입력을 받는다고 가정해 구현 책임이 비어 있다.
3. exit 4 stamp 비접촉 검증은 `.codex-reviewed`, `.review-pending`, `.spec-reviews/*`를 각각 seed하고 내용·존재를 비교하도록 구체화할 필요가 있다.

spec-review 모드 규칙에 따라 코드리뷰 stamp와 pending marker는 건드리지 않았다.
