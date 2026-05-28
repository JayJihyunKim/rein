# AG-2 worker contract `.rein/worker-result.json` + PLN1 enforcement 활성화

- 날짜: 2026-05-28
- 유형: feat (worker contract) + feat (gate enforcement)
- DoD: trail/dod/dod-2026-05-28-worker-contract-plus-pln1-enforce.md
- plan: docs/plans/2026-05-28-worker-contract-plus-pln1-enforce.md
- 진행: 본 세션 (claude direct), 자동 모드

## 결과 요약

2 commits 누적 (`caac631` → `ca80d88`):

| SHA | 분류 | 요약 |
|-----|------|-----|
| `837ae4f` | feat | worker contract `.rein/worker-result.json` schema + PLN1 enforcement 활성화 + 회귀 test 5 case |
| `ca80d88` | fix | codex R1 fix: DoD `## 범위 연결` 섹션 + test F6 (no-범위연결 케이스) |

## 핵심 변경

### 1. feature-builder-worker.md 의 새 종료 보고 contract

worker 가 종료 직전 항상 `worker worktree root/.rein/worker-result.json` 생성. parent (호출자) 가 이 artifact 를 read 해서 cleanup / cherry-pick / fallback / split-cycle 결정.

schema 의 핵심 필드:
- `scope_status`: completed / blocked_scope_mismatch / blocked_architectural / blocked_context_exhaustion
- 완료 시 `completed`: commit_sha + tests_passing + files_modified
- 미완 시 `blocked`: reason (5 enum) + required_scope + failing_tests + evidence + recommendation

timeout/context exhaustion 으로 잘리는 대신 **명시적 non-completion artifact** 가 본 contract 의 핵심 (codex Mode B 권고).

### 2. PLN1-GATE-ENFORCEMENT 활성화

`plugins/rein-core/hooks/pre-edit-dod-gate.sh:683-693`:
- 기존 advisory NOTICE → BLOCKED stderr + log_block + exit 2
- 새 worker-marker bypass 분기: `[ -f "$PROJECT_DIR/.rein/worker-marker.json" ]` 존재 시 NOTICE + continue (worker 안 정상 작업)

**truth table**:
| parallelizable | worker-marker | 결과 |
|---|---|---|
| 부재 / false | 무관 | exit 0 (legacy backward-compat) |
| true | 존재 | exit 0 + NOTICE (worker bypass) |
| true | 부재 | **exit 2 + log_block** (parallel plan 인데 worker dispatch 안 함) |

### 3. 회귀 test 6 case

`tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh`:
- F1: parallelizable=true + no worker-marker → exit 2 + BLOCKED stderr
- F2: parallelizable=true + worker-marker → exit 0 + NOTICE
- F3: parallelizable=false → exit 0
- F4: no `## 실행 전략` section → exit 0
- F5: no plan ref in DoD → exit 0
- F6: no `## 범위 연결` section → exit 0 (codex R1 권고 추가)

6/6 PASS. 전체 hooks suite ALL SUITES PASSED.

## Review cycle

- **codex R1**: NEEDS-FIX (Medium×2 + High claim audit) — DoD `## 범위 연결` 부재, test gap (no-범위연결 case), claim audit "4 vs 16" mismatch
- **R1 fix**: DoD 섹션 추가 + test F6 + commit msg 정정
- **codex R2**: NEEDS-FIX — "핵심 4 + 부수 12 = 16" claim 이 본 round diff (7) 와 mismatch
- **codex R3**: NEEDS-FIX — "누적 22 paths" 추정이 실제 17 과 mismatch
- **codex R4**: **PASS** — numeric claim 자체 제거, codex 가 실측 cumulative 17 만 인정
- **security review**: **PASS** + stamp 발급. standard rule §1-9 회귀 0. 2 informational (worker-result.json `evidence` 필드 escape, `_pln1_plan_path` resolution trust source) 는 후속 cycle 참고.

## 자동 모드 운용

본 cycle 은 `rein:auto-mode-on` skill 활성 상태에서 진행 — incident advisory + session-end block silent. cycle 종료 후 `auto-mode-off` 호출 + 누적 incident 정리 예정.

## 후속 작업

- parent-side `.rein/worker-result.json` reader automation — worker 종료 후 parent 가 artifact read + dispatch 결정 자동화 (별도 cycle)
- perf3 architectural cycle — dispatcher canonical vs if-field canonical 설계 결정 + test 재정의
- main 머지 + release — 본 cycle + 이전 dogfood cycle 합쳐 release DoD
- worker-result.json `evidence` 필드 외부 표시 시 escape (security informational 후속)

## PLN1 enforcement 활성화의 의미

본 cycle 부터 `parallelizable: true` plan 의 source 편집은 worker dispatch 흐름 (`.rein/worker-marker.json` 존재) 안에서만 가능. legacy plan (실행 전략 부재 또는 false) 은 backward-compat 으로 영향 0. 이는 PLN-1 의 "plan 의 worker 분할 schema 가 의도된 흐름 강제" 를 처음으로 enforce 한 시점.
