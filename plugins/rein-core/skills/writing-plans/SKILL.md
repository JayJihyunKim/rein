---
name: writing-plans
description: design 문서를 읽어 구현 plan (coverage 매트릭스 + covers 메타데이터 포함) 을 작성한다. rein 자체 스킬 — superpowers 미의존.
triggers:
  - "design 문서(docs/**/specs/**-design.md) 리뷰 통과 후"
  - "plan-writer 에이전트 내부 호출"
---

# writing-plans

## 목적

design 문서의 `## Scope Items` 표에서 ID 를 추출하고, Phase/Task 로 분해한 뒤, `## Design 범위 커버리지 매트릭스` + `covers:` 메타데이터를 포함하는 plan 파일을 작성한다. 작성 후 `python3 scripts/rein-validate-coverage-matrix.py <plan>` 를 실행해 exit 0 이 될 때까지 자기수정 loop 를 돌린다. 이 스킬의 핵심 산출물은 "validator 가 통과하는 plan 문서" 이다.

## 실행 순서

1. **Scope 추출** — design 문서의 `## Scope Items` 표를 읽어 모든 ID 와 설명을 수집한다. ID 누락 시 작업 중단하고 design 담당자에게 보고한다.

2. **Phase/Task 분해** — 수집한 ID 를 논리적 묶음으로 나눠 Phase N / Task N.M 계층을 설계한다. 각 Phase 는 독립 배포 가능 단위를 권장한다.

3. **Plan 파일 작성 경로** — 프로젝트의 plan 디렉토리 하위 (`docs/**/plans/YYYY-MM-DD-<slug>-implementation.md` 형태) 에 저장. rein-dev 는 `docs/plans/` 를 사용하지만 경로는 프로젝트 자유. 날짜는 작업 시작일, slug 는 design 파일명과 일치시킨다.

4. **Matrix + covers 기입** — `## Design 범위 커버리지 매트릭스` 섹션을 작성하고, `design ref:` 줄에 design 파일의 repo-root 기준 상대경로를 기입한다. 각 Phase/Task heading 바로 다음 줄에 `covers: [ID, ...]` 를 기입한다. `deferred` 상태 항목은 사유 + 후속 위치를 반드시 명시한다. design 문서에 `brainstorm ref:` 줄이 있으면 plan 문서 상단 메타에도 그대로 옮겨 적어 brainstorm→design→plan 추적성을 유지한다 (soft v1 권고).

5. **Validator 실행 (자기수정 loop)** — `python3 scripts/rein-validate-coverage-matrix.py <plan>` 실행. exit 0 이 아니면 stderr 오류 메시지를 읽어 matrix/covers 를 수정하고 재실행한다. 최대 3회 반복 후에도 실패하면 작업 중단하고 오류 내용을 보고한다.

6. **Handoff** — validator exit 0 확인 후 아래 Handoff 메시지 포맷으로 결과를 보고한다.

## Plan 문서 구조 (필수)

~~~markdown
# [Feature Name] Implementation Plan

## Goal
[1-2 sentences describing the outcome]

## Architecture
[Key architectural decisions, constraints]

## Tech Stack
[Languages, frameworks, tools]

## Design 범위 커버리지 매트릭스

> design ref: docs/**/specs/YYYY-MM-DD-<slug>-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 1 / Task 1.1 |
| A2 | implemented | Phase 2 / Task 2.3 |
| E1 | deferred | Phase 3 예정 — 외부 의존성 미확정 |

---

## Phase 1: [Phase Name]
covers: [A1]

### Task 1.1: [Task Name]
covers: [A1]

**Files:**
- Create: `path/to/new-file.py`
- Modify: `path/to/existing-file.py`
- Test: `tests/test_new_feature.py`

**Steps:**
1. Write failing test: `assert new_function() == expected`
2. Implement `new_function()` in `new-file.py`
3. Run test: `pytest tests/test_new_feature.py`
4. Commit: `feat(scope): Task 1.1 — [description]`
5. Verify: all prior tests still pass

## Phase 2: [Phase Name]
covers: [A2]

### Task 2.1: [Task Name]
covers: [A2]

**Files:**
- Modify: `path/to/existing-file.py`
- Test: `tests/test_phase2.py`

**Steps:**
1. Write failing test: `assert extended_behavior() == expected`
2. Implement change in `existing-file.py`
3. Run test: `pytest tests/test_phase2.py`
4. Commit: `feat(scope): Task 2.1 — [description]`
~~~

## 작성 원칙

- **Exact paths** — 파일 경로는 repo-root 기준 전체 경로. 모호한 표현 금지.
- **Complete code** — stub/placeholder 금지. 실행 가능한 코드 스니펫만 기재.
- **Bite-sized steps** — 각 Task 는 30분 이내 완료 가능한 크기. 더 크면 Task 를 쪼갠다.
- **TDD** — 모든 Task 의 Step 1 은 실패하는 테스트 작성. 구현은 Step 2 이후.
- **Frequent commits** — Task 단위 commit. Phase 단위 tag 권장.

## Self-review (plan 완성 후 즉시)

1. **Spec coverage** — design 의 모든 Scope ID 가 matrix 에 `implemented` 또는 `deferred` 로 등재되어 있는가?
2. **Placeholder scan** — `TODO`, `...`, `<placeholder>`, `TBD` 문자열이 plan 에 없는가?
3. **Type consistency** — `covers:` 의 모든 ID 가 matrix `implemented` 행에 존재하는가? `deferred` ID 가 `covers:` 에 등장하지 않는가?
4. **Validator pre-check** — `python3 scripts/rein-validate-coverage-matrix.py <plan>` exit 0 확인.

## Handoff 메시지 포맷

```
Plan 작성 완료: docs/**/plans/YYYY-MM-DD-<slug>-implementation.md
- Scope IDs covered: [A1, A2, A3] (N implemented / M deferred)
- Validator: exit 0

다음 단계:
1. /codex-review 로 plan 문서 리뷰 요청
2. 리뷰 통과 후 bash scripts/rein-mark-spec-reviewed.sh <plan-file> 실행
3. subagent-driven-development 스킬 (또는 executing-plans) 으로 plan 실행
```

## 사용자 안내

이 SKILL 의 결과를 사용자에게 보고할 때 다음 짧은 형식을 **먼저** 출력한다 (위 `Handoff 메시지 포맷` 블록은 그 다음에 그대로 이어 붙인다). 형식은 한 문장 또는 두 문장 — 결과 1줄 + 다음 액션 1줄.

**성공 (plan 작성 + matrix 통과)**:
> plan 작성 완료. design 의 Scope IDs N개 모두 cover 했고 validator 통과. 이제 /codex-review 로 plan 리뷰를 요청하면 됩니다.

**Coverage validator 실패 (gap)**:
> plan 의 coverage matrix 에 [gap 종류 — 미해결 ID N개 또는 unknown ID 등] 가 있어 validator 가 차단했어요. matrix/covers 를 수정한 뒤 다시 시도하세요.

**Self-review 실패 (placeholder/stub 잔존)**:
> plan 에 [placeholder 종류 — TODO / TBD 등] 이 남아 있어요. 실행 가능한 코드/경로로 교체한 뒤 다시 self-review 하세요.
