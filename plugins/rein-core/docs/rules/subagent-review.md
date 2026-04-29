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

## Spec/Plan 리뷰 권한 분리

코드 리뷰가 implementer/reviewer 를 분리하듯, **brainstorm/spec/plan 문서의 리뷰 사이클도 author/reviewer 권한을 분리한다**. 같은 주체가 양쪽을 겸하면 self-approval 이 발생해 per-spec stamp (`trail/dod/.spec-reviews/<hash>.reviewed`) 가 무효화된다.

### 권한 매트릭스

| 역할 | 누구 | 책임 |
|------|------|------|
| **요청자 (requester)** | 사용자 | task 의도 제시, AskUserQuestion 답변, 최종 승인. 본인이 직접 markdown 을 작성하지 않는다. |
| **작성자 (author)** | Claude (주 세션) | brainstorm/spec/plan 문서 작성. 리뷰 findings 수신 후 **본인이 보완** 한다. |
| **리뷰어 (reviewer)** | 기본은 codex Mode A (`/codex-review` spec-review subflow). codex 장애 시 `AGENTS.md` §`/codex-review` 장애 시 Fallback 에 따라 `code-reviewer` 스킬 또는 `general-purpose` 에이전트로 대체 가능 (이 경우 `bash scripts/rein-mark-spec-reviewed.sh <path> <reviewer>` 의 `<reviewer>` 인자에 실제 사용된 fallback 식별자 기재). | findings 만 출력. **문서를 직접 수정하지 않는다**. fallback reviewer 도 동일 — author 가 보완하고 재리뷰하는 사이클은 reviewer 주체와 무관하게 유지된다. |

### 핵심 규칙

1. **reviewer 의 직접 수정 금지** — codex 가 "spec 의 X 가 누락" 이라고 지적하면 codex 가 spec 을 고치지 않는다. Claude (author) 가 findings 를 읽고 spec 을 보완한 뒤 **재리뷰** 를 다시 codex 에 요청한다.
2. **사이클 강제** — `작성 → 리뷰 findings → author 가 보완 → 재리뷰 → per-spec stamp`. "리뷰 + 보완" 을 한 step 으로 묶어 stamp 를 한 번에 찍으면 stale review 가 생긴다 (수정 후 검증되지 않은 변경분이 stamp 에 포함됨).
3. **사용자 결정이 필요한 findings** — codex 가 임계값/방향성처럼 author 단독으로 판단할 수 없는 항목을 지적하면 Claude 가 `AskUserQuestion` 으로 사용자에게 묻고, 답변을 반영해 spec 을 보완한 뒤 재리뷰. 이 경우 "결정자" 는 사용자, "실제 작성자" 는 여전히 Claude.
4. **per-spec stamp** — 모든 findings 가 해소되고 codex 가 PASS 를 낸 직후에만 `bash scripts/rein-mark-spec-reviewed.sh <path> <reviewer>` 호출. Claude 가 직접 `touch` 하면 author = stamp 생성자 가 되어 self-approval 발생.

### 위반 패턴 (금지)

- ❌ codex 가 "Scope Items 누락" 을 지적했을 때 Claude 가 codex 에게 "spec 을 고쳐서 다시 줘" 라고 위임 — reviewer 권한 침범
- ❌ 같은 round 에서 spec 보완 + stamp 생성 — 보완분이 검증되지 않음
- ❌ 사용자에게 묻지 않고 author 가 임계값/방향성을 단독 결정 — 사용자 의도 추측 오염

### 코드 리뷰 사이클과의 차이

코드 리뷰의 `Implementer / Spec Reviewer / Code+Security Reviewer` 분리는 같은 원칙의 코드 변경 적용판이다. 위 spec/plan 권한 분리는 **변경 대상이 markdown 문서일 때** 의 동일 원칙 — 권한 경계가 달라지는 것이 아니라 검증 대상이 코드냐 문서냐의 차이.

## 통합 리뷰

모든 task 완료 후, push 전에 **전체 변경분에 대한 통합 리뷰**를 반드시 1회 실행한다:
- `/codex-review` 또는 code-reviewer subagent — 전체 diff 대상
- security-reviewer subagent — 보안 surface 가 있는 파일 대상

통합 리뷰 수정분이 발생하면, 해당 수정에 대해서도 리뷰를 다시 실행한다.

## 예외

아래 조건을 **모두** 만족할 때만 stamp 수동 touch 가 허용된다:
- 사용자가 명시적으로 "리뷰 스킵" 을 승인
- 변경이 docs-only (코드 로직 변경 없음)

## 위반 시

- stamp 수동 touch 로 gate 를 우회한 commit 은 push 전에 반드시 리뷰를 소급 실행
- 리뷰 없이 push 된 코드가 발견되면 즉시 revert 또는 hotfix + 리뷰
