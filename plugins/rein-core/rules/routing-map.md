# Routing Map

## 행동 강령

DoD 작성 직후 본 표로 1순위 조합을 확인.

| 작업 유형 | 추천 agent | 추천 skill | DoD 작성 |
|---|---|---|---|
| 새 기능 추가 | `rein:feature-builder` | `rein:codex-review` | 범위 IN/OUT |
| 버그 수정 | `rein:feature-builder-fix` | 〃 | 재현 테스트 |
| 리팩토링 | `rein:feature-builder-refactor` | 〃 | 동작 불변 |
| plan 작성 | `rein:plan-writer` | — | covers 매트릭스 |
| spec 작성 | `rein:spec-writer` | — | Scope Items |
| 기술 조사 | `rein:researcher` | — | 결정 근거 |
| 문서 작성 | `rein:docs-writer` | — | 대상 독자 |
| 보안 리뷰 | `rein:security-reviewer` | — | 위협 모델 |

> routing-procedure.md §5 의 압축 projection (SSOT=§5).
> 메인 세션의 지휘자 기본 동작(분해·병렬 위임)은 `orchestrator-first.md` 참조 — 이 표는 하위 작업 단위의 agent 선택만 담당한다.
