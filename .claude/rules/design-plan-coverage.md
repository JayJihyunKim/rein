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

## 2. Plan 문서 — Coverage Matrix + covers: 메타데이터

### 2.1 Matrix 섹션 (필수)

plan 문서는 `## Design 범위 커버리지 매트릭스` 섹션에 아래 포맷의 표를 포함한다:

```markdown
## Design 범위 커버리지 매트릭스

> design ref: docs/superpowers/specs/foo-design.md

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

## 3. DoD 문서 — covers: 필드

`trail/dod/dod-*.md` 가 특정 plan 의 work unit 을 구현하는 경우, DoD frontmatter 또는 본문에 `covers: [A1, E1]` 필드를 포함하는 것을 **권고한다**. 이 필드는 plan work unit 의 `covers:` 와 일치해야 한다. v1 에서는 validator 가 강제하지 않으며, §5 참고.

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
