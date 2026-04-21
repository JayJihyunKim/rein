# Design → Plan 범위 커버리지 규칙

## 핵심 원칙

design 문서에 적힌 scope item 은 plan 문서에서 **전부** 소화되어야 한다. "조용한 누락"을 구조적으로 금지한다.

이 규칙은 **opt-in**: plan 에 `## Design 범위 커버리지 매트릭스` 섹션이 있을 때만 validator 가 강제 검증한다. 섹션이 없는 legacy plan 은 경고만 출력되고 차단되지 않는다.

## 1. Design 문서 — Scope Items 섹션

design/spec 문서의 저장 위치는 제약하지 않는다. plan 의 `design ref:` 줄이 가리키는 파일이 validator 의 유일한 입력 기준이다. design 문서는 `## Scope Items` 섹션에 아래 포맷의 표를 포함한다:

```markdown
## Scope Items

| ID | 설명 |
|----|------|
| A1 | active universe coverage 검증 |
| E1 | preflight_backtest_data_quality() 함수 |
| E2 | runner 3개에 preflight 호출 |
```

- **ID 는 프로젝트 자유** (A1, SUP-01, ci-gate, step-12 등 — 영문·숫자·하이픈·언더스코어만)
- **안정성 규칙**: 한번 부여된 ID 는 의미가 바뀌면 새 ID 로 교체한다 (재사용 금지)
- ID 를 쪼개거나 폐기하려면 design 문서에 **history 노트**를 남긴다 (예: `A1 → A1a/A1b 로 분할 (2026-04-20)`)

### 1.1 Scope ID 는 behavior-level contract (scope-id-version: v2)

Scope ID 는 **한 줄의 behavior-level contract** 로 verifiable 해야 한다. 함수명이나 파일명이 아니라, "무엇이 어떤 상태에서 어떤 방향으로 어느 임계값을 넘게 관찰되는가" 를 기술한다. coarse 한 Phase/Task 수준 ID (예: "A1: 5단계 포지션 모드") 로는 특정 sub-mode 가 다른 mode 와 동일하게 drift 한 경우를 잡지 못한다. behavior-level ID 는 drift 발생 시 test assertion 이 어떤 값을 요구해야 하는지 명확히 규정하므로 codex-review Design Alignment slot 이 MATCH/MISSING/CONTRADICTS 판정을 의미 있게 내릴 수 있다.

### 1.2 Measurable contract 요구사항

behavior-level ID 의 서술부는 다음 세 요소를 **가능한 경우 모두** 포함해야 한다:

1. **entity + verb** (무엇이 어떻게 동작하는가) — 예: `CAUTION-nav-drawdown`
2. **direction / 임계값** (어떤 기준으로 판정하는가) — 예: `-less-than-ATTACK`, `-at-least-50-percent-reduction`
3. **scenario / window** (어떤 조건에서 관찰하는가) — 예: `-in-S1-2020-03-bear-window`

세 요소를 **모두 포함하는 ID** 는 acceptable. 하나 이상 누락 시 codex-review Design Alignment slot 이 MEDIUM 으로 플래그 (block 은 Spec A Stage 에 위임).

### 1.3 scope-id-version 메타 위치

`scope-id-version` 메타는 **design 문서 상단 frontmatter** 에만 위치한다. plan 은 이 메타를 복사하지 않고 design ref 로부터 상속한다 (plan 자체에는 표식 없음).

design frontmatter 예:

```yaml
---
scope-id-version: v2
---
```

3 가지 해석 규칙:

- 버전 미기입 (frontmatter 없음) → **v1 으로 간주** (legacy 호환 — 기존 spec 은 아무 것도 건드리지 않아도 계속 작동)
- `scope-id-version: v2` → §1.1 behavior-level rule 강제
- 알 수 없는 값 (예: `v99`, `draft`) → validator 가 **exit 2 (fail-closed)**. 조용한 downgrade 금지.

이유: design 이 Scope Items 의 source of truth — 버전 주체가 동일. plan 이 버전을 중복 보유하면 design 승격 시 plan 이 stale 상태로 남는 drift 가능. `scripts/rein-validate-coverage-matrix.py plan` subcommand 는 plan 이 참조하는 design 을 읽을 때 frontmatter 의 버전을 추출해 규칙 강도를 분기.

### 1.4 Acceptable / non-acceptable 예시

아래 예시는 **대소문자 포함 원문 그대로** 사용한다 (rein drift-prevention design §2 에서 이식).

**Acceptable (3 예)**:

- `CAUTION-nav-drawdown-less-than-ATTACK-in-S1-2020-03`
  - entity: CAUTION 모드의 NAV drawdown
  - direction: ATTACK 대비 작음 (부등호)
  - scenario: S1 시나리오 2020-03 bear window
- `rotation-leading-biases-risk-off-when-ge2-of-3-bearish`
  - entity: rotation 선행지표
  - direction: 2 이상 조건에서 risk-off 판정 확정 (boolean threshold)
  - scenario: 선행 3지표 중 2 이상 bearish
- `preflight-blocks-empty-universe-returns-false`
  - entity: `preflight_backtest_data_quality()`
  - direction: False 반환 (exact value)
  - scenario: universe 가 빈 상태

**Non-acceptable (부적합, 3 예 + 사유)**:

- `A1: 5단계 포지션 모드`
  - 이유: entity 는 있으나 direction/scenario 부재. "5단계가 각각 어떻게 다른가" 를 테스트로 고정할 수 없음.
- `E1: preflight_backtest_data_quality() 함수`
  - 이유: 함수 존재만 기술. direction (어떤 입력에서 어떤 반환) 과 scenario 부재. 함수 signature 는 contract 아님.
- `CAUTION-differs-from-ATTACK`
  - 이유: direction 에 방향성 없음 (단순 ≠). 잘못된 방향 drift (CAUTION 이 ATTACK 보다 더 공격적) 도 이 contract 를 만족함. "less-than" 등 부등호 방향성 필요.

### 1.5 Legacy migration (edit-only)

- 기존 plan 의 coarse ID 는 **편집 시에만 승격**한다. design 의 버전이 v1 이면 plan 도 v1 규칙 대상. 자동 승격 없음.
- design 이 v2 로 승격될 때 plan 은 자동으로 v2 규칙 적용 (편집하지 않아도 validator 가 v2 로 검증) — 단, 이 전환은 **design 의 명시적 commit** 이 있어야 일어난다. **자동 date-based 승격 없음**.
- design 이 v1 → v2 로 승격되는 순간 해당 design 을 참조하는 모든 plan 의 matrix 가 동시에 v2 규칙으로 검증됨. 영향 받는 plan 이 여러 개라면 design 승격 commit 과 plan commit 이 coordinated 되어야 한다.
- 승격 시 retire 기록 형식 (design 문서 하단):

  ```markdown
  ## Scope Items history
  - 2026-04-21: A1 → caution-nav-drawdown-less-than-attack-in-s1-2020-03, caution-buy-throttle-50-percent-of-attack, caution-position-size-reduces-by-30-percent (split due to granularity rule)
  ```

## 2. Plan 문서 — Coverage Matrix + covers: 메타데이터

### 2.1 Matrix 섹션 (필수)

plan 문서는 `## Design 범위 커버리지 매트릭스` 섹션에 아래 포맷의 표를 포함한다:

```markdown
## Design 범위 커버리지 매트릭스

> design ref: docs/specs/foo-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 2 / Task 2.3 |
| A2 | implemented | Phase 3 / Task 3.1 |
| E1 | deferred | Stage 2.5 로 연기 — 데이터 소스 미확정 |
```

- **design ref** 줄은 반드시 포함. validator 가 여기서 design 파일 경로를 읽어 ID 집합을 비교한다.
- **상태** 는 `implemented` 또는 `deferred` 두 값만 허용.
- `deferred` 는 "위치/사유" 칸에 **반드시 사유 + 후속 위치**를 명시.

### 2.2 work unit `covers:` 메타데이터 (필수)

plan 의 각 Gate/Phase/Task 수준 work unit 은 heading 바로 다음 줄에 `covers:` 를 표기한다. 이름(Gate/Phase/Sprint/Step 등) 은 팀 자유.

```markdown
## Phase 2: 데이터 정합성 강화
covers: [A1, A2]

...

### Task 2.3: preflight 호출 추가
covers: [A1]
```

- `covers:` 의 모든 ID 는 matrix 의 `implemented` 행에 존재해야 한다.
- matrix 의 모든 `implemented` ID 는 최소 1개 work unit 의 `covers:` 에 등장해야 한다.
- `covers:` 는 소문자 `covers:` 로 정확히 시작하는 독립 라인이어야 한다 (대문자/공백 변형 불허). ID 목록은 `[id1, id2, ...]` 형식만 허용하며, ID 는 영문·숫자·하이픈·언더스코어만 포함한다. validator 는 plan 파일 어느 위치에서든 `covers:` 라인을 수집하므로 (heading 다음 줄 제약은 강제하지 않음), 가독성을 위해 관련 work unit heading 바로 다음에 배치할 것을 권장한다.

## 3. DoD 문서 — covers: 필드 + v1.1.0 `## 범위 연결` 섹션

### 3.1 v1 (advisory) — covers: 필드

`trail/dod/dod-*.md` 가 특정 plan 의 work unit 을 구현하는 경우, DoD frontmatter 또는 본문에 `covers: [A1, E1]` 필드를 포함하는 것을 **권고한다**. 이 필드는 plan work unit 의 `covers:` 와 일치해야 한다. v1 에서는 validator 가 강제하지 않으며, §5 참고.

### 3.2 v1.1.0 — `## 범위 연결` 섹션 규격

v1.1.0 부터 DoD 는 `## 범위 연결` 섹션을 포함할 수 있다. 이 섹션이 있으면 validator v2 의 `dod` 서브커맨드가 `covers ⊆ plan.matrix.implemented` 관계를 검증한다.

```markdown
## 범위 연결

plan ref: docs/plans/2026-04-21-foo-plan.md
work unit: Phase 3 / Task 3.2
covers: [A1, E1]
```

- **plan ref**: DoD 가 구현하는 plan 의 repo-relative 경로. validator 가 여기서 matrix + covers 를 읽는다.
- **work unit**: plan 상의 위치 (서술적, validator 가 강제하지 않음).
- **covers**: plan matrix 의 `implemented` 행 ID 부분집합.

### 3.3 Stage 별 enforcement (v1.1.0 governance stage)

v1.1.0 DoD `covers:` 탐지는 rollout stage 에 따라 강도가 달라진다. `.claude/.rein-state/governance.json` 의 `stage` 값이 source of truth:

| Stage | 탐지 방식 | 결과 |
|-------|-----------|------|
| 1 (advisory, 기본값) | active DoD (Tier 1 마커 또는 Tier 2 최신-mtime) 에 `covers` mismatch 시 | `.dod-coverage-advisory` 생성 — pre-bash-guard **차단 안 함** |
| 2 (blocking active DoD) | 동일 조건 | `.dod-coverage-mismatch` 생성 — pre-bash-guard 가 `git commit` / 테스트 차단 |
| 3 (blocking legacy dated plan) | Stage 2 + 편집된 `docs/YYYY-MM-DD/*-plan.md` 까지 확대 | 동일 |

Malformed config 는 **모든 Stage 에서 fail-closed** — Stage 1 silent downgrade 금지. 파일 부재 = Stage 1.

## 4. Validator 및 Enforcement

- `scripts/rein-validate-coverage-matrix.py <plan-file>` — 정적 검증
- `.claude/hooks/post-edit-plan-coverage.sh` — plan 편집 시 자동 실행, 실패 시 `trail/dod/.coverage-mismatch` 마커 생성
- `.claude/hooks/pre-bash-guard.sh` — 마커 존재 시 `git commit` / `pytest` 차단 (exit 2)
- 마커 해제: validator 가 성공할 때까지 plan 을 수정하거나, 예외 승인 후 `rm trail/dod/.coverage-mismatch`

## 5. v1 범위 (이번 구현)

validator 가 강제하는 것:
- matrix 존재 (섹션 + design ref + 표)
- design ↔ matrix ID 집합 일치
- matrix ID 중복 금지
- `covers:` 의 모든 ID 가 `implemented` 상태로 matrix 에 존재
- matrix 의 `implemented` 가 최소 1개 `covers:` 에 등장

validator 가 강제하지 않는 것 (문서 규칙으로만 권고):
- `deferred` 행의 "위치/사유" 칸 형식 (문자열만 존재하면 통과)
- DoD 파일의 `covers:` 필드 존재/일치 (v2 후보)

v2 에서 hard enforcement 로 승격 검토.

## 6. 위반 시 행동

1. hook 이 차단하면 validator 출력(stderr)을 확인해 누락/중복/unknown ID 를 수정한다.
2. 2회 반복 위반은 incidents-to-rule 대상.
