---
name: brainstorming
description: rein-native brainstorming. 기존 코드베이스/아키텍처 제약 하에서 아이디어를 spec 초안으로 구체화한다. brownfield (기존 시스템 변경) 에서는 feasibility·compatibility 를 먼저 검증한 뒤 선택지를 수렴하고, greenfield 에서는 얇은 질문 세트로 의도를 빠르게 수렴한다. 산출물은 docs/superpowers/brainstorms/ 에 기록되고 spec 이 brainstorm ref: 로 가리킨다. superpowers:brainstorming 과 달리 호환성·구현 가능성을 일급 시민으로 다룬다.
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
| 기존 시스템에 기능 추가/변경 (brownfield) | **MUST** — Step 1~6 전부 실행 |
| 완전 신규 시스템 설계 (greenfield) | SHOULD — Step 1, 3, 5, 6 중심으로 얇게 |
| 단순 버그 수정 | SKIP — `/codex review` 체인으로 충분 |
| docs-only 변경 | SKIP |

애매하면 brownfield 로 간주하고 전체 실행.

## 실행 순서

### 전체 공통

**Step 1 — 사용자 의도 탐색**
- 문제 진술을 한 문장으로 정리 ("왜 이것을 하려는가")
- 성공 기준을 구체적으로 ("끝났다고 할 수 있는 상태는 무엇인가")
- 2~3 개 질문으로 의도의 모서리를 깎아낸다

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

저장 위치: `docs/superpowers/brainstorms/YYYY-MM-DD-<slug>.md`

- 날짜 = 작업 시작일
- slug = 영문 kebab-case, spec slug 와 일치시킨다 (추적 용이)
- 파일 구조:

~~~markdown
# [Feature/Change Name] — brainstorm

- 날짜: YYYY-MM-DD
- 유형: greenfield | brownfield
- 다음 산출물: docs/superpowers/specs/<slug>.md (예정)

## Problem Statement

[1~3 문장. 왜 이것을 하려는가. 성공 기준이 무엇인가.]

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

→ Next: `docs/superpowers/specs/<slug>.md`
~~~

## Handoff

완료 후 다음 형식으로 보고한다:

~~~
## Brainstorm 완료

- 파일: docs/superpowers/brainstorms/YYYY-MM-DD-<slug>.md
- 유형: brownfield | greenfield
- Chosen Direction: [요약 1줄]
- Open Questions: [개수]

다음 단계: spec 초안 작성 (`docs/superpowers/specs/<slug>.md`)
spec 에 다음 줄을 포함하세요:
  brainstorm ref: docs/superpowers/brainstorms/<slug>.md
~~~

## Second opinion 체인 (선택)

선택이 의심스러우면 `/codex ask` 를 호출해 독립 관점으로 반박받을 수 있다 (brainstorm artifact 경로를 전달). 이는 권고이며 강제 아님.

## 호출 예시

### Good prompt

~~~
사용자: "AGENTS.md 규칙이 너무 길어지는데, 섹션별로 분리하고 싶어"
→ brownfield. Step 1~6 실행:
  - Step 1: 어떤 범위까지 분리? 모든 섹션을 개별 파일로? 아니면 일부만?
  - Step 2: 현재 AGENTS.md 를 참조하는 CLAUDE.md, 훅, 스킬 식별
  - Step 3: 기존 @import 체인 제약. CLAUDE.md 는 현재 한 파일로 가정하는 훅이 있는가?
  - Step 4: 옵션 A (전체 분리), B (핵심만 분리 + 나머지 유지), C (toc 페이지로 네비)
  - Step 5: Breaking 여부 확인 — 기존 사용자의 AGENTS.md 가 깨지는가?
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
| 기존 시스템 탐색 | 선택사항 | brownfield 에서 필수 |
| Feasibility 검증 | 암묵적 | 명시 Step 4 |
| Compatibility 확인 | 거의 없음 | 명시 Step 5 |
| 산출물 포맷 강제 | 느슨 | 5개 섹션 고정 |
| handoff 체인 | 자유 | spec ref 권고 |

두 스킬은 배타적이지 않다. greenfield 에서는 superpowers 를 호출해도 무방하지만, 산출물은 이 스킬 포맷으로 정리해 `docs/superpowers/brainstorms/` 에 저장한다.
