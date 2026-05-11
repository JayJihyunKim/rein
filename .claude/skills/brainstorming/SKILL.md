---
name: brainstorming
description: "rein-native brainstorming. 기존 코드베이스/아키텍처 제약 하에서 아이디어를 spec 초안으로 구체화한다. brownfield (기존 시스템 변경) 에서는 feasibility·compatibility 를 먼저 검증한 뒤 선택지를 수렴하고, greenfield 에서는 얇은 질문 세트로 의도를 빠르게 수렴한다. 산출물은 docs/brainstorms/ 에 기록되고 spec 이 brainstorm ref: 로 가리킨다. superpowers:brainstorming 과 달리 호환성·구현 가능성을 일급 시민으로 다룬다."
triggers:
  - "신규 기능/변경 아이디어가 들어왔을 때 (구현 착수 전)"
  - "기존 시스템에 기능을 추가할 때 (brownfield)"
  - "설계 결정이 여러 선택지 사이에서 고민될 때"
---

# brainstorming

## 왜 이 스킬이 필요한가

superpowers:brainstorming 은 사용자 의도를 질문으로 구체화하는 데 탁월하다. 하지만:

- **기존 시스템 제약을 고려하지 않는다** — 사용자가 선택한 방향이 기존 훅/규칙과 충돌해도 인지하지 못함
- **구현 가능성을 검증하지 않는다** — 선택이 "실제로 돌아가는가" 를 묻지 않음
- **결론이 설계 문서로 옮겨질 때 일부 항목이 조용히 누락된다**

rein 은 이미 design→plan→DoD 구간에 coverage 강제 장치를 갖지만, **brainstorm→spec 구간은 비어 있었다**. 이 스킬이 그 공백을 메운다.

## 언제 쓰는가

| 상황 | 적용 |
|------|------|
| 기존 시스템에 기능 추가/변경 (brownfield) | **MUST** — Step 0~6 전부 실행 (Step 0 = pre-question sanity gate) |
| 완전 신규 시스템 설계 (greenfield) | SHOULD — Step 1, 3, 5, 6 중심으로 얇게 (Step 0 불필요) |
| 단순 버그 수정 | SKIP — `/codex-review` 체인으로 충분 |
| docs-only 변경 | SKIP |

애매하면 brownfield 로 간주하고 전체 실행.

## 실행 순서

### Brownfield 전용 — Step 0: Pre-question sanity check

brownfield 에서는 **사용자에게 질문을 던지기 전에** 질문 자체가 현재 코드베이스 구조에서 유효한지 codex-ask 로 검증한다. 이 단계를 생략하면 잘못된 전제를 담은 질문이 사용자의 답변으로 굳어 spec/plan/DoD 전 구간을 오염시킨다.

- **0.1 최소 탐색** — `Grep` / `Glob` 로 변경이 닿을 표면 1차 스캔. 이 시점에는 전수 조사 불필요. "어느 훅·규칙·파일이 관련되어 있는가" 만 식별 (상세는 Step 2 에서).
- **0.2 질문 초안 작성** — 사용자에게 던질 질문 3~5 개를 미리 작성한다. 각 질문 옆에 **암묵적 전제 (assumption)** 를 한 줄로 명시한다. 예: `Q1: 훅을 분리할까? (전제: 현재는 단일 훅)`
- **0.3 `/codex-ask` 호출** — fresh session 으로 아래 prompt 를 던진다:
  - "다음 질문 초안이 현재 코드베이스 구조에서 유효한가? 각 질문의 전제 (assumption) 를 읽고 구조적으로 불가능하거나, 이미 결정된 사안이거나, 잘못된 이분법이면 지적해 줘."
  - 입력: Step 0.1 의 표면 스캔 결과 + Step 0.2 의 질문/전제 쌍
  - codex-ask 는 리뷰 게이트가 아니므로 stamp 생성 안 됨. 결과는 Claude 주 세션에 돌아와 반영.
- **0.4 질문 재작성 / 통과** — codex 가 invalid assumption 을 지적하면 해당 질문 제거 또는 재작성 후 **Step 0.3 재호출**. 통과하면 Step 1 로 진행.

Step 0 에서 검증된 질문 세트가 Step 1 의 "사용자 의도 탐색" 에 입력된다. Step 0 없이 Step 1 로 바로 들어가는 것은 brownfield 에서 금지.

### 전체 공통

**Step 1 — 사용자 의도 탐색**
- 문제 진술을 한 문장으로 정리 ("왜 이것을 하려는가")
- 성공 기준을 구체적으로 ("끝났다고 할 수 있는 상태는 무엇인가")
- 2~3 개 질문으로 의도의 모서리를 깎아낸다 (brownfield 에서는 **Step 0 에서 검증된 질문 세트**를 사용)
- **사용자 질문 강제 (필수)**: brownfield 에서 Step 0.4 통과 후 교정된 질문 세트, greenfield 에서 위에서 도출한 2~3 개 질문은 **반드시 `AskUserQuestion` 으로 사용자에게 제시** 한다. 이 단계를 건너뛰고 Step 2~6 을 Claude 단독으로 합성하는 것은 **금지**. 사용자 답변 없이 만들어진 brainstorm 은 사용자 의도가 아니라 Claude 의 추측을 담게 되어 후속 spec/plan/DoD 전 구간을 오염시킨다 (회귀 사례: `need-to-confirm.md` 그룹 8 item 1).

### Brownfield (필수 4단계 추가)

**Step 2 — 관련 기존 시스템 탐색**
- `Grep` / `Glob` 으로 영향 범위 식별
- 관련 훅, 규칙(rules/), 스킬, 에이전트, 테스트, 문서 목록화
- "이 변경이 닿는 surface" 를 문서에 구체적으로 기록

**Step 3 — Constraint 확인**
- 기존 훅 중 이 변경을 차단할 수 있는 것 (pre-edit-dod-gate, pre-bash-guard 등)
- 기존 규칙/커버리지 매트릭스에서 강제되는 불변식
- main/dev 브랜치 전략상 제약 (rein 프로젝트의 경우 `branch-strategy.md`)
- 정책/라이선스/보안 레벨 제약

**Step 4 — Feasibility 평가 (각 Option 별)**
- 각 선택지를 기존 시스템 위에 얹을 때의 **구현 비용** (파일 수, 리팩토링 범위)
- **운영 비용** (추가 훅, 추가 CI 시간, 문서 동기화 부담)
- **리스크** (기존 동작 깨질 가능성, migration 필요성)

**Step 5 — Compatibility 검증**
- Breaking 여부 — 기존 사용자의 워크플로우/파일/인터페이스가 깨지는가?
- Migration 필요성 — 있다면 1회용인가 반복인가?
- 하위 호환 유지 전략 (default 값, deprecation 경로, feature flag 등)

### 모든 경우 공통

**Step 6 — 선택지 수렴 + Open Questions**
- 선택한 방향(Chosen Direction) 과 **근거** 를 명시
- 기각한 옵션(Rejected Options) 과 **기각 이유** 를 기록 (나중에 재검토 가능하도록)
- Open Questions 는 spec 단계에서 풀어야 할 질문으로 이관

## 산출물 포맷

저장 위치: `docs/brainstorms/YYYY-MM-DD-<slug>.md`

**작성 시점 (필수)**: `docs/brainstorms/<slug>.md` 파일은 **Step 6 converge 이후에만** 작성한다. Step 1~5 진행 중 사용자 답변이 모이기 전에 미리 작성하는 것은 **금지** — 그 시점의 문서는 사용자 의도가 아니라 Claude 의 추측을 동결한 결과물이 되어 후속 단계를 오염시킨다. Step 6 의 Chosen Direction + Rejected Options + Open Questions 가 모두 결정된 시점에 한 번만 작성한다.

- 날짜 = 작업 시작일
- slug = 영문 kebab-case, spec slug 와 일치시킨다 (추적 용이)
- 파일 구조:

~~~markdown
# [Feature/Change Name] — brainstorm

- 날짜: YYYY-MM-DD
- 유형: greenfield | brownfield
- 다음 산출물: docs/specs/<slug>.md (예정)

## Problem Statement

[1~3 문장. 왜 이것을 하려는가. 성공 기준이 무엇인가.]

## Question Sanity Check (codex-ask)

[brownfield 에서 **필수**. greenfield 는 생략 가능. Step 0 의 산출물.]

- 초기 질문 초안 (전제 포함):
  - Q1: [질문] — 전제: [assumption 한 줄]
  - Q2: [질문] — 전제: [assumption]
  - ...
- codex-ask 세션: [실행 일시 + 모델 + effort]
- codex 판정 요약: [invalid 지적 / 통과 / 재작성 round 수]
- 최종 질문 세트 (Step 1 에 입력):
  - Q1': [재작성된 질문 또는 유지]
  - ...

## Constraints

[brownfield 에서 필수. 기존 훅/규칙/브랜치 전략/정책 제약.]

- 기존 훅: [이름과 역할]
- 기존 규칙: [파일 경로와 해당 절]
- 브랜치 전략: [main 포함/제외, 하위 호환 요구]
- 기타 정책: [보안 레벨, 라이선스 등]

## Options Considered

### Option A: [이름]

- 구현 스케치: [2~3 줄]
- 구현 비용: [파일 수, 복잡도]
- 운영 비용: [추가 훅/CI/문서 부담]
- 리스크: [깨질 수 있는 지점]
- Breaking: yes/no. [yes 면 마이그레이션 요지]

### Option B: [이름]

[동일 포맷]

### Option C: [이름]

[필요 시]

## Chosen Direction

**Option [X]** 를 선택한다.

- 근거: [왜 이 옵션이 다른 옵션보다 나은가]
- Trade-off 인정: [포기한 것이 무엇인가]

## Rejected Options

- **Option [Y]**: 기각 이유 — [구체적 근거. 재검토 가능하도록]
- **Option [Z]**: 기각 이유 — [...]

## Open Questions

spec 단계에서 해결할 질문들:

- [ ] [질문 1]
- [ ] [질문 2]

→ Next: `docs/specs/<slug>.md`
~~~

## Handoff

완료 후 다음 형식으로 보고한다:

~~~
## Brainstorm 완료

- 파일: docs/brainstorms/YYYY-MM-DD-<slug>.md
- 유형: brownfield | greenfield
- Chosen Direction: [요약 1줄]
- Open Questions: [개수]

다음 단계: spec 초안 작성 (`docs/specs/<slug>.md`)
spec 에 다음 줄을 포함하세요:
  brainstorm ref: docs/brainstorms/<slug>.md
~~~

## Second opinion 체인 (선택)

Step 6 의 Chosen Direction 확정 **후에도** 결론이 의심스러우면 `/codex-ask` 를 한 번 더 호출해 독립 관점으로 반박받을 수 있다. Step 0 의 mandatory pre-question sanity check 와는 역할이 다르다:

| 단계 | 위치 | 대상 | 강제 여부 |
|------|------|------|----------|
| Step 0 (brownfield 필수) | Step 1 이전 | 사용자에게 던질 **질문 초안의 전제** | **mandatory** (brownfield) |
| Second opinion 체인 (선택) | Step 6 이후 | 확정된 **Chosen Direction** | advisory |

두 호출은 목적이 다르므로 각각 fresh codex-ask 세션으로 수행한다 (resume 금지 — codex-ask 원칙).

## 호출 예시

### Good prompt

~~~
사용자: "AGENTS.md 규칙이 너무 길어지는데, 섹션별로 분리하고 싶어"
→ brownfield. Step 0~6 실행:
  - Step 0.1: Grep 으로 AGENTS.md 참조처 1차 스캔 (CLAUDE.md, 훅 스크립트, 스킬)
  - Step 0.2: 질문 초안 +전제
    - Q1: 전체 분리 vs 일부 분리? (전제: 분리가 기술적으로 가능)
    - Q2: 파일명 규칙은? (전제: 여러 파일로 쪼갤 때 naming 충돌 없음)
  - Step 0.3: /codex-ask 로 "이 질문 전제가 현재 @import 체인에서 유효한가?" 검증
    → 예시 invalid 지적: "CLAUDE.md 는 단일 AGENTS.md path 를 하드코딩한 훅이 있음. Q1 의 '분리 가능' 전제가 훅 수정 없이는 불가"
  - Step 0.4: 질문 재작성 후 통과
  - Step 1: 검증된 질문 세트로 사용자 의도 탐색
  - Step 2: 상세 surface 목록화
  - Step 3: 기존 @import 체인 제약 구체화
  - Step 4: 옵션 A (전체 분리 + 훅 수정), B (일부만 분리), C (toc 페이지)
  - Step 5: Breaking 여부 — 기존 사용자의 AGENTS.md path 가 깨지는가?
  - Step 6: 근거 + 기각 이유 기록
~~~

### Bad prompt

~~~
사용자: "새 에이전트 만들자"
→ greenfield 처럼 보이지만 rein 저장소의 에이전트 layout 이 고정돼 있어 사실상 brownfield.
   Step 2 를 건너뛰면 기존 에이전트 naming/role 과 충돌 가능.
~~~

## superpowers:brainstorming 과의 차이

| 항목 | superpowers:brainstorming | rein brainstorming |
|------|--------------------------|-------------------|
| Pre-question sanity check | 없음 | **brownfield 필수 (Step 0, codex-ask fresh session)** |
| 기존 시스템 탐색 | 선택사항 | brownfield 에서 필수 |
| Feasibility 검증 | 암묵적 | 명시 Step 4 |
| Compatibility 확인 | 거의 없음 | 명시 Step 5 |
| 산출물 포맷 강제 | 느슨 | 7개 섹션 (brownfield) / 6개 (greenfield, Question Sanity Check 생략) |
| handoff 체인 | 자유 | spec ref 권고 |

두 스킬은 배타적이지 않다. greenfield 에서는 superpowers 를 호출해도 무방하지만, 산출물은 이 스킬 포맷으로 정리해 `docs/brainstorms/` 에 저장한다.

## 사용자 안내

이 SKILL 의 결과를 사용자에게 보고할 때 다음 짧은 형식을 **먼저** 출력한다 (운영자/디테일 메타데이터인 `## Brainstorm 완료` 블록은 그 다음에 그대로 이어 붙인다). 형식은 한 문장 또는 두 문장 — 결과 1줄 + 다음 액션 1줄.

**성공 (Step 6 converge 후 산출물 작성)**:
> brainstorm 마쳤습니다. [Chosen Direction 한 줄] 을 선택했어요. 이제 [다음 산출물 — 보통 spec 또는 DoD] 를 만들면 됩니다.

**Step 0 codex-ask 가 invalid 지적 (재작성 필요)**:
> codex 가 질문 초안에서 [지적 핵심 1-2건] 을 짚어줬어요. 질문을 재작성한 뒤 Step 0 을 다시 호출하세요.

**Step 1 사용자 결정 대기**:
> brainstorm 진행 중 — Step 1 의 사용자 결정 N건이 필요해요. AskUserQuestion 답변을 받으면 Step 2 로 진행합니다.
