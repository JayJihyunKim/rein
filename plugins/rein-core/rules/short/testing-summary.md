# Testing — quick rule

## 행동 강령

TDD — 모든 feature 작업의 첫 단계는 실패하는 테스트 작성. 테스트는 명세서(이름만 보고 검증 대상 파악), 독립적, 결정론적. 패턴 [무엇을]_[조건]_[기대결과], AAA 구조(Arrange/Act/Assert). 단위 테스트의 외부 API 직접 호출 금지(Mock), timing 의존(sleep/setTimeout) 금지. 신규 기능 커버리지 80%, 버그 수정은 재현 테스트 필수. behavioral-contract 테스트(design Scope 에 `kind` 태그 있을 때)는 방향+임계값을 scenario 실행 결과로 검증(`!=` contrast-only 금지). 구체 claim audit 은 `/codex-review` 단계에서.

> 전체 본문은 `${CLAUDE_PLUGIN_ROOT}/rules/testing.md` 참조.
