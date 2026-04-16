# Subagent 코드 리뷰 규칙

## 핵심 원칙

subagent-driven-development 실행 시 **stamp 수동 touch 로 리뷰 gate 를 우회하면 안 된다**.
review stamp (`.codex-reviewed`, `.security-reviewed`) 는 **실제 리뷰를 거친 후에만** 생성한다.

## Task 별 필수 단계

각 task 의 implementer subagent 완료 후 반드시 아래 순서를 따른다:

1. **Implementer** — 코딩 + 테스트 + self-review + commit
2. **Spec Reviewer** (subagent) — plan 준수 확인. 미준수 시 implementer 재디스패치
3. **Code Quality + Security Reviewer** (subagent) — 코드 품질 + 보안 검토. 승인 후 stamp 생성

stamp 는 3단계를 모두 통과한 뒤에만 touch 한다. Implementer 가 자기 commit 전에 stamp 를 먼저 찍는 것은 금지.

## 통합 리뷰

모든 task 완료 후, push 전에 **전체 변경분에 대한 통합 리뷰**를 반드시 1회 실행한다:
- `/codex` 또는 code-reviewer subagent — 전체 diff 대상
- security-reviewer subagent — 보안 surface 가 있는 파일 대상

통합 리뷰 수정분이 발생하면, 해당 수정에 대해서도 리뷰를 다시 실행한다.

## 예외

아래 조건을 **모두** 만족할 때만 stamp 수동 touch 가 허용된다:
- 사용자가 명시적으로 "리뷰 스킵" 을 승인
- 변경이 docs-only (코드 로직 변경 없음)

## 위반 시

- stamp 수동 touch 로 gate 를 우회한 commit 은 push 전에 반드시 리뷰를 소급 실행
- 리뷰 없이 push 된 코드가 발견되면 즉시 revert 또는 hotfix + 리뷰
