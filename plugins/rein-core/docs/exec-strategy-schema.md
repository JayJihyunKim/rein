# Plan 실행 전략 schema v2 (wave parallel)

> `plugins/rein-core/rules/design-plan-coverage.md` §2A 의 상세 본문. rule 파일은
> SessionStart inject token budget (≤12000 bytes) 보호를 위해 요약만 두고 본 doc
> 으로 분리한다. 검증기: `scripts/rein-validate-coverage-matrix.py`
> (+ `plugins/rein-core/scripts/` byte-identical 미러).

## 1. 섹션 schema

plan 의 선택적 `## 실행 전략` 섹션은 태스크별 v2 스키마다. 섹션 부재 = 순차 실행
(회귀 없음).

```
## 실행 전략

tasks:
  - id: <task-id>
    depends_on: [<id>, ...]      # optional, default []
    mode: edit_only | mutating
    scope:
      - <literal-file-path>
  - id: <task-id-2>
    depends_on: [<task-id>]
    mode: mutating
    scope:
      - <literal-file-path>
```

### 필드 정의

- **`id`** — 태스크 고유 식별자 (plan 내 unique). 중복 금지.
- **`depends_on: [id, ...]`** (optional, 기본 `[]`) — 선행 태스크 id list. 존재하는
  id 만 참조 가능. inline list 형식 (`[a, b]`).
- **`mode: edit_only | mutating`** —
  - `edit_only`: 부작용 없는 편집만 (커밋·코드젠·전체 포매터·변경성 테스트 금지).
    같은 웨이브에서 병렬 dispatch 가능.
  - `mutating`: 변경성 명령 허용 (코드젠·변경성 테스트·패키지 설치 등). 단
    커밋·리뷰/보안 stamp·trail 기록은 여전히 부모(메인 세션) 소유. 단독 웨이브로만
    실행.
- **`scope`** — 본 태스크가 변경하는 **literal repo-relative file path** list.
  `mutating` 은 선언 파일 + **예상 부작용 경로** 를 함께 포함. **glob/디렉토리
  미지원** — `*`, `?`, `[`, `]` 메타문자 또는 `/` 로 끝나는 디렉토리 경로는
  validator fail-closed (기존 literal-path 규칙 재사용). 명시적 파일만 허용.

## 2. 판정 기준 (태스크별 mode + 동시쌍 disjoint)

plan-writer 는 통짜 불리언이 아니라 **태스크별** 로 판단한다:

- **mode 판단**: 커밋/코드젠/전체포매터/패키지설치/스냅샷/변경성 테스트/scope 밖 쓰기
  가능성 중 하나라도 있으면 `mutating`, 아니면 `edit_only`. 불명확 시 보수적으로
  `mutating` (또는 의존으로 순차화).
- **scope** = 그 태스크의 **예상 실제 write set** (의도 소스가 아닌 실제 쓰기 집합).
- **동시쌍 disjoint**: 서로 `depends_on` 경로가 없어 **동시 실행 가능한** 두
  `edit_only` 태스크의 `scope` 는 겹치면 안 된다. `depends_on` 으로 순서가 강제돼
  동시 실행되지 않는 쌍은 같은 파일을 만져도 무방.

## 3. validator fail-closed (8조건)

`scripts/rein-validate-coverage-matrix.py plan <plan-file>` 가 본 섹션을 파싱한다.
섹션 부재 → exit 0. present 시 아래 중 하나라도 위반 → **exit 2**:

- **(a)** `id` 누락 또는 중복.
- **(b)** `depends_on` 원소가 존재하지 않는 id 참조.
- **(c)** 의존 사이클 (Kahn 위상정렬로 모든 노드 소진 못 함).
- **(d)** `mode` 가 `edit_only`/`mutating` 아님.
- **(e)** `scope` 누락 / 빈 list / inline non-list shape.
- **(f)** `scope` 원소가 glob 메타문자 / 디렉토리 (`/` 끝) / non-path token
  (alpha char 와 `/` 둘 다 없음, 예: `123`).
- **(g)** 동시 실행 가능한 두 `edit_only` 태스크의 `scope` 가 겹침
  (`depends_on` 연결쌍은 허용 — g').
- **(h)** 구 `parallelizable:`/`workers:` shape 감지 → 마이그레이션 메시지 후 exit 2.

## 4. 결정적 웨이브 스케줄

`scripts/rein-validate-coverage-matrix.py schedule <plan-file>` 가 결정적 웨이브
순서를 emit 한다 (스케줄 결정성의 SSOT — 스킬은 이를 소비하거나 같은 규칙을 복제).

알고리즘: 매 스텝 ready 집합 계산 (`depends_on` 가 모두 완료된 미실행 태스크) →
ready 에 `mutating` 이 있으면 **plan 순서 가장 앞선 mutating 1개만 단독 step** 후
재계산; ready 가 전부 `edit_only` 이면 그 전부를 한 step(웨이브). `mutating` 은
어떤 태스크와도 동시 실행 안 됨. 사이클 없음(검증기 보증) → 데드락 없음.

출력: `step <n>: <id> [<id> ...]` (step 내 id 는 plan 순서). 섹션 부재 → 빈 출력 +
exit 0.

## 5. dispatch 소유권

웨이브 dispatch 는 `parallel-execute` 스킬이 **같은 작업 트리에서** 소유한다 — 독립
`edit_only` 태스크를 서브에이전트로 병렬 실행, `mutating`·의존 태스크는 순차 실행.
워커는 편집만 하고 부모가 웨이브 단위로 검증·테스트·커밋한다. (파일시스템 격리 없음 —
안전성은 동시쌍 write-set 분리 + 부모 사후 델타 검증 두 겹.)
