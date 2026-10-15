# plan 작성 절차 (plan-writer 내부 참조)

이 문서는 `plan-writer` 에이전트가 plan 작성 시 따르는 내부 참조 절차이며, 사용자가 직접 호출하는 스킬이 아니다.

## 목적

design 문서의 `## Scope Items` 표에서 ID 를 추출하고, Phase/Task 로 분해한 뒤, `## Design 범위 커버리지 매트릭스` + `covers:` 메타데이터를 포함하는 plan 파일을 작성한다. 작성 후 `python3 scripts/rein-validate-coverage-matrix.py <plan>` 를 실행해 exit 0 이 될 때까지 자기수정 loop 를 돌린다. 이 절차의 핵심 산출물은 "validator 가 통과하는 plan 문서" 이다.

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

## 검증 계획

- 기준 전체 검사: 첫 웨이브(실행 전략이 없으면 첫 Task) 전 1회 — `[전체 검사 명령]` (소요: 실측 [이전 실행 기록 인용] | 미측정)
- Task·웨이브 검증: 각 Task Steps 의 대상 테스트만 (바뀐 파일이 닿는 테스트 목록 또는 `rein-affected-tests.py` 호출)
- 커밋: 웨이브 barrier 마다 1회 (실행 전략이 없으면 Phase 끝 1회)
- 최종 전체 검사: 마지막 커밋·병합 직전 1회 — 최종 트리가 기준 트리와 다를 때만
- 그 밖의 전체 재실행: `codex-review` 스킬 "전체 테스트 재실행으로 돌아가는 조건" 에 해당할 때만

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
3. Run targeted tests: `pytest tests/test_new_feature.py` (이 Task 가 바꾼 파일이 닿는 테스트만)

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
3. Run targeted tests: `pytest tests/test_phase2.py` (이 Task 가 바꾼 파일이 닿는 테스트만)
~~~

## 작성 원칙

- **Exact paths** — 파일 경로는 repo-root 기준 전체 경로. 모호한 표현 금지.
- **Complete code** — stub/placeholder 금지. 실행 가능한 코드 스니펫만 기재.
- **Bite-sized steps** — 각 Task 는 30분 이내 완료 가능한 크기. 더 크면 Task 를 쪼갠다.
- **TDD** — 모든 Task 의 Step 1 은 실패하는 테스트 작성. 구현은 Step 2 이후.
- **Commit at barriers** — 커밋은 웨이브 barrier 마다 1회(`## 실행 전략` 이 없으면 Phase 끝 1회). Task Step 에 커밋을 넣지 않는다 — barrier 가 검증·리뷰를 마친 델타만 커밋한다.
- **Targeted verification** — Task 의 마지막 Step 은 그 Task 가 바꾼 파일이 닿는 대상 테스트 실행이다(아래 `## 검증 비용 규칙`).

## 검증 비용 규칙

공통 규칙의 정본은 `rules/testing.md` "검증 실행 범위" 다. plan 에는 아래처럼 구체적으로 적는다.

1. **같은 코드 상태에서 전체 검사 1회** — 두 검증 Step 사이에 코드·테스트·설정·의존성을 바꾸는 Step 이 없으면 같은 코드 상태다. 그런 두 Step 이 둘 다 전체 검사(전체 테스트 스위트, 전체 포맷·린트·타입검사, 전체 빌드)를 지시하면 하나를 지운다. Phase 끝과 다음 Phase 시작처럼 경계가 맞닿은 곳이 대표적이다. 복귀 조건을 명시한 재실행은 제외한다 — 어느 조건인지 적혀 있지 않은 반복만 지운다(3번).
2. **수정 뒤에는 대상 테스트만** — Task 의 검증 Step 은 그 Task 가 바꾼 파일이 닿는 테스트 목록, 또는 대상 테스트 선택 도구(`rein-affected-tests.py`) 호출을 적는다. "모든 테스트", "처음 단계부터 다시" 를 Task 검증으로 쓰지 않는다. 이 목록은 하한이다 — 실행자가 실제 웨이브 델타로 선택 도구를 돌릴 수 있으면 그 결과를 우선한다.
3. **전체 검사는 기준 1회 + 최종 1회** — 검증 단위는 `## 실행 전략` 이 있으면 웨이브, 없으면 Task 다. plan 에는 전체 검사를 첫 웨이브 전 기준 1회와 마지막 커밋·병합 직전 최종 1회(기준 트리와 다를 때)만 적는다. 그 밖의 전체 재실행을 plan 에 적으려면 그 Step 이 `codex-review` 스킬 "전체 테스트 재실행으로 돌아가는 조건" 중 어느 것(의존성·빌드 설정·공용 fixture·외부 입력·큰 델타 등)에 해당하는지 함께 적는다 — 조건을 적은 재실행은 1번의 중복이 아니다. 조건 없이 "전체 재실행" 만 적지 않으며, 계획 시점에 모르는 조건은 실행자 판단에 맡기고 plan 에 고정 횟수로 적지 않는다.
4. **소요 시간 표기** — 전체 검사 Step 에 소요를 적을 때 `실측`(이전 실행 기록 인용) / `미측정` 중 하나로 적는다. 이전 기록이 없는 수치는 범위 추정이라도 쓰지 않는다.

## Self-review (plan 완성 후 즉시)

1. **Spec coverage** — design 의 모든 Scope ID 가 matrix 에 `implemented` 또는 `deferred` 로 등재되어 있는가?
2. **Placeholder scan** — `TODO`, `...`, `<placeholder>`, `TBD` 문자열이 plan 에 없는가?
3. **Type consistency** — `covers:` 의 모든 ID 가 matrix `implemented` 행에 존재하는가? `deferred` ID 가 `covers:` 에 등장하지 않는가?
4. **Validator pre-check** — `python3 scripts/rein-validate-coverage-matrix.py <plan>` exit 0 확인.
5. **Verification cost** — 같은 코드 상태에서 전체 검사를 2회 이상 지시하는 Step 이 없는가(복귀 조건을 명시한 재실행은 제외)? 각 Task 의 검증 Step 이 대상 테스트(목록 또는 선택 도구 호출)로 끝나는가? 전체 검사가 기준 1회 + 최종 1회 + 조건을 명시한 재실행으로 한정되고 소요가 실측(이전 기록 인용) 또는 미측정으로 표기됐는가?

## Handoff 메시지 포맷

이 절차는 `plan-writer` 가 수행한다. validator 통과(exit 0) 직후 plan-writer 가 자동으로 codex 리뷰를 이어서 수행하므로 **사용자의 수동 `/codex-review` 호출은 불필요**하다. 리뷰 통과 시 plan-writer 가 리뷰 표식을 생성한 뒤 구현 단계로 핸드오프한다.

```
Plan 작성 완료: docs/**/plans/YYYY-MM-DD-<slug>-implementation.md
- Scope IDs covered: [A1, A2, A3] (N implemented / M deferred)
- Validator: exit 0

이후 자동 진행 (plan-writer 수행):
1. validator 통과 직후 plan-writer 가 plan 문서에 대한 codex 리뷰를 자동 수행 (사용자 수동 트리거 불필요)
2. 리뷰 통과 시 plan-writer 가 리뷰 표식 생성
3. 구현 단계로 핸드오프
```

## 사용자 안내

plan 작성 결과를 사용자에게 보고할 때 다음 짧은 형식을 **먼저** 출력한다 (위 `Handoff 메시지 포맷` 블록은 그 다음에 그대로 이어 붙인다). 형식은 한 문장 또는 두 문장 — 결과 1줄 + 다음 진행 1줄.

**성공 (plan 작성 + matrix 통과)**:
> plan 작성 완료. design 의 Scope IDs N개 모두 cover 했고 validator 통과. plan-writer 가 이어서 codex 리뷰를 자동 수행하며, 통과하면 구현 단계로 넘어갑니다 (별도 수동 리뷰 요청 불필요).

**Coverage validator 실패 (gap)**:
> plan 의 coverage matrix 에 [gap 종류 — 미해결 ID N개 또는 unknown ID 등] 가 있어 validator 가 차단했어요. matrix/covers 를 수정한 뒤 다시 시도하세요.

**Self-review 실패 (placeholder/stub 잔존)**:
> plan 에 [placeholder 종류 — TODO / TBD 등] 이 남아 있어요. 실행 가능한 코드/경로로 교체한 뒤 다시 self-review 하세요.
