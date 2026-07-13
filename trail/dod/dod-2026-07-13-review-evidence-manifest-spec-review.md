# DoD — review evidence manifest plan spec review

- date: 2026-07-13
- plan ref: docs/plans/2026-07-13-review-evidence-manifest.md
- design ref: docs/specs/2026-07-13-review-evidence-manifest.md

## 완료 기준

- [x] design 의 Scope ID 15개가 plan 의 구체 task·경로·검증 명령으로 모두 커버되는지 판정한다.
- [x] wrapper → mirror → SKILL.md → tests 순서와 TDD fixture 구현 가능성을 판정한다.
- [x] exit/stamp/spec-mode/mirror/shell/strip-order 불변조건을 대조한다.
- [x] spec §8 수용 기준 1–14와 테스트 task 매핑을 대조한다.
- [x] 요청된 Code defects, Design Alignment, Test Alignment, Claim Audit 및 최종 verdict를 출력한다.

## 변경 파일

- trail/dod/dod-2026-07-13-review-evidence-manifest-spec-review.md
- trail/inbox/2026-07-13-review-evidence-manifest-spec-review.md

## 작업 계획

1. 프로젝트 상태와 review workflow/role 규칙을 읽는다.
2. spec Scope Items·상세 설계·수용 기준을 추출한다.
3. plan matrix·task·명령·실행 전략을 추출한다.
4. Scope/불변조건/수용 기준을 양방향 대조한다.
5. severity와 verdict를 결정하고 완료 기록을 남긴다.

## 범위 연결

covers: []

리뷰 작업 자체이며 구현 commit의 active DoD covers가 아니다.

## 라우팅 추천

agent: codex
skills: []
mcps: []
security_tier: light
complexity: medium
effort_hint: high
rationale:
  - 세션에 주입된 전용 rein 리뷰 에이전트/스킬이 없어 현재 Codex가 읽기 전용 spec review를 수행한다.
  - 사용자가 NON_INTERACTIVE partial-check 진행을 명시 승인했다.
approved_by_user: true

## Self-review

- [x] 변경 범위가 문서 검토와 trail 기록에 한정된다.
- [x] 테스트 파일 변경 없음 — bad-test pattern: N/A (no test change).
