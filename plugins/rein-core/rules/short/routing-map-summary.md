# Routing Map — quick rule

## 행동 강령

DoD 작성 직후 작업 유형으로 1순위 조합을 확인한다: 새 기능 → `rein:feature-builder`, 버그 수정 → `rein:feature-builder-fix`(재현 테스트), 리팩토링 → `rein:feature-builder-refactor`(동작 불변), plan 작성 → `rein:plan-writer`(covers 매트릭스), spec 작성 → `rein:spec-writer`(Scope Items), 기술 조사 → `rein:researcher`(결정 근거), 문서 작성 → `rein:docs-writer`(대상 독자), 보안 리뷰 → `rein:security-reviewer`(위협 모델). 구현 유형은 `rein:codex-review` 동반.

> 전체 본문(절차 SSOT)은 `${CLAUDE_PLUGIN_ROOT}/rules/routing-procedure.md` 참조.
