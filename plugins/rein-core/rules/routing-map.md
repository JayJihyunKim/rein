# Routing Map

## 행동 강령

DoD 작성 직후 본 표로 1순위 조합을 확인. 상세는 routing-procedure.md.

| 작업 유형 | 추천 agent | 추천 skill | DoD 작성 |
|---|---|---|---|
| 새 기능 | `rein:feature-builder` | `rein:codex-review` | 범위 IN/OUT |
| 버그 수정 | `rein:feature-builder-fix` | 〃 | 재현 테스트 |
| 리팩토링 | `rein:feature-builder-refactor` | 〃 | 동작 불변 |
| plan 작성 | `rein:plan-writer` | — | covers 매트릭스 |
| spec 작성 | `rein:spec-writer` | — | Scope Items |
| 기술 조사 | `rein:researcher` | — | 결정 근거 |
| 문서 | `rein:docs-writer` | — | 대상 독자 |
| 보안 리뷰 | `rein:security-reviewer` | — | 위협 모델 |

> 상세: plugins/rein-core/rules/routing-procedure.md
