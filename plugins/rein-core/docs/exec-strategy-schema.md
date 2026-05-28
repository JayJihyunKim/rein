# Plan 실행 전략 schema (PLN-1)

> `plugins/rein-core/rules/design-plan-coverage.md` §2A 의 상세 본문. rule 파일은 SessionStart inject token budget (≤12000 bytes) 보호를 위해 schema 핵심만 두고 본 doc 으로 분리한다.

## 1. 섹션 schema 전체

```markdown
## 실행 전략

parallelizable: <true|false>
workers:
  - name: <worker-name>
    scope:
      - <literal-file-path>
      - <literal-file-path>
  - name: <worker-name>
    scope:
      - <literal-file-path>
merge_gate: <description>
```

### 필드 정의

- **`parallelizable: bool`** (기본 false) — 본 plan 의 work units 가 worktree 격리 worker 로 병렬 dispatch 가능한지. plan-writer 의 3 axis 판단 (§2) 결과.
- **`workers[]`** (parallelizable=true 일 때 필수) — worker 분할 list. 각 worker 는 `name` (식별자) + `scope` (literal file path list).
- **`workers[].scope`** — 본 worker 가 변경 권한을 가진 파일들의 **literal repo-relative path** list. **glob/regex 미지원 (첫 cycle)** — `*`, `?`, `[`, `]` 메타문자 포함 시 validator fail-closed. 디렉토리 경로 (`plugins/`) 도 fail-closed — 명시적 파일만 허용.
- **`merge_gate: <description>`** — 모든 worker 완료 후 메인 worktree 머지 시점의 검증 절차 (예: "각 worker 의 codex-review PASS + 메인에서 통합 테스트 실행").

## 2. parallelizable 판정 3 axis

plan-writer 는 다음 3 axis 를 **모두 충족** 할 때만 `parallelizable: true` 로 결정:

| Axis | true 조건 | false 조건 |
|------|-----------|-----------|
| 파일 분산도 | 변경 파일 ≥ 4개 (1 worker 당 ≥2 파일) | 변경 파일 ≤ 3개 (분할 의미 없음) |
| 파일 소유권 충돌 | worker 별 disjoint file set | 동일 파일 다중 worker 편집 |
| 실행 순서 의존 | acceptance 순서만 의존 (각 worker 독립 verify) | implementation 의존 (A 가 B 의 산출물 사용) |

3 axis 중 하나라도 위반 → `parallelizable: false`. 보수적 기본값.

## 3. validator 강제 사항 (fail-closed 상세)

`scripts/rein-validate-coverage-matrix.py plan <plan-file>` 가 본 섹션을 파싱:

- 섹션 부재 = `parallelizable: false` (legacy plan 회귀 없음, exit 0)
- `parallelizable: true` 이면 아래 조건 중 하나라도 위반 시 **exit 2 fail-closed**:
  - **(a)** `workers` list 가 비어있거나 누락
  - **(b)** 임의 worker 의 `scope` 가 누락 (`b1`)·빈 list (`b2`)·inline non-list shape (`b3`)
  - **(c)** `scope` 의 원소가 file path 로 식별 불가 — `c1`: non-string element (markdown parser layer 에서는 unreachable, 방어 깊이 유지) / `c`: alpha char 와 `/` 둘 다 없는 token (numeric-only `123`, symbol-only `---` 등). markdown parser 가 모든 list item 을 string 으로 yield 하므로 c1 만으로는 numeric token 을 잡지 못해 c heuristic 으로 보강 (2026-05-28 codex Round 1 NEEDS-FIX fix).
  - **(d)** `scope` 의 원소가 glob 메타문자 (`*`, `?`, `[`, `]`) 포함
  - **(e)** `scope` 의 원소가 디렉토리 경로 (`/` 로 끝남)

## 4. 단계적 활성화 (advisory only, AG-2 안정화 전까지)

`pre-edit-dod-gate.sh` 는 active DoD 의 plan ref 가 `parallelizable: true` 인지 감지 — **감지 + advisory emit 코드는 active** (실행됨), 차단 (exit 2) 은 다음 cycle 까지 비활성. `# PLN1-GATE-ENFORCEMENT-DISABLED-PENDING-AG2-STABILIZATION` 마커로 활성화 지점 표시.

활성화 시점 (다음 cycle): AG-2 worker (`feature-builder-worker`) dogfood 검증 후, 위 마커 grep 하여 enforcement 코드 주석 제거.

## 5. worker dispatch (manual, 첫 cycle)

본 cycle 에서는 worker 자동 dispatch 메커니즘 부재 — 사용자가 manual 로 `Agent` tool 호출 시 `feature-builder-worker` 를 지정 + 본 섹션의 `workers[].scope` 를 prompt 로 전달. cleanup 절차는 `plugins/rein-core/docs/worktree-cleanup.md` 참조.
