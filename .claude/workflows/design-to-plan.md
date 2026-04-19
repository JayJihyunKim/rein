# Workflow: design → plan 전환

> design 문서에서 plan 문서로 넘어갈 때 scope 누락을 구조적으로 막는 절차.
> rein 은 ID 포맷을 지정하지 않는다 (팀 자유). 필요한 건 형식의 일관성.

## 언제 이 워크플로우를 쓰는가

- design/spec 문서 (`docs/**/specs/**.md` 또는 `docs/**/plans/*-design.md`) 에서 구현 plan 으로 전환할 때
- 여러 Gate/Phase/Stage 로 나뉘는 중규모 이상 작업에서 특히 중요

## 단계

### 1. Design 에 Scope Items 섹션 추가

design 문서에 다음을 포함한다:

```markdown
## Scope Items

| ID | 설명 |
|----|------|
| <ID-1> | ... |
| <ID-2> | ... |
```

- ID 는 팀 자유 (A1, SUP-01, feat-12 등)
- 한번 부여된 ID 는 재사용 금지

### 2. Plan 에 Coverage Matrix 섹션 추가

```markdown
## Design 범위 커버리지 매트릭스

> design ref: <design 파일 경로>

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| <ID-1> | implemented | <Work unit 이름 / 위치> |
| <ID-2> | deferred | <사유 + 후속 위치> |
```

### 3. 각 work unit 에 covers: 메타데이터

```markdown
## <Work unit 이름 — Gate/Phase/Sprint 무관>
covers: [<ID-1>, <ID-2>]
```

### 4. Validator 확인

plan 을 저장하면 `post-edit-plan-coverage.sh` 훅이 자동 검증한다:
- 실패 시 `trail/dod/.coverage-mismatch` 마커 생성 → 이후 commit/test 차단
- 성공 시 마커가 있었다면 자동 해제

수동 실행:
```bash
python3 scripts/rein-validate-coverage-matrix.py <plan-file>
```

### 5. DoD 에 covers: 필드 연동

DoD 파일 작성 시 해당 work unit 의 `covers:` 를 그대로 복사한다:

```markdown
# DoD — <작업명>
covers: [<ID-1>]
```

## 자주 묻는 질문

**Q. legacy plan 은 어떻게 되나?**
A. `## Design 범위 커버리지 매트릭스` 섹션이 없으면 경고만 출력하고 차단하지 않는다.

**Q. 범위가 바뀌면?**
A. design 의 Scope Items 에 먼저 반영 → plan matrix 갱신 → hook 이 자동 재검증.

**Q. Gate 이름을 design 어휘로 맞춰야 하나?**
A. 아니다. 이름은 자유. 추적성은 `covers:` 꼬리표가 담당한다.
