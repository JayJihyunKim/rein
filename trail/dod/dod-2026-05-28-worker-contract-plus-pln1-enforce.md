# DoD — AG-2 worker contract 보강 + PLN1 enforcement 활성화

- 날짜: 2026-05-28
- slug: worker-contract-plus-pln1-enforce
- 유형: feat (worker contract) + feat (gate enforcement) — 둘 다 AG-2 안정화 영역
- plan ref: docs/plans/2026-05-28-worker-contract-plus-pln1-enforce.md

## 배경

2026-05-28 AG-2 dogfood (4-worker) 의 정직한 결과:
- 단순 1파일 fix 는 worker 가 끝까지 (worker_a/d)
- multi-file dependency 는 worker 가 worktree 안 commit 도달 못 함 (worker_bc, worker_e)
- 미완 worker 는 timeout/context exhaustion 으로 잘리고 parent 가 사후 분석으로 incomplete 진단

codex Mode B (second opinion) 권고: AG-2 worker 가 declared scope 안에서 처리 불가 상황을 만나면 **명시적 non-completion artifact** (`.rein/worker-result.json`) 을 남기고 종료. parent 가 이 artifact 를 read 해서 fallback / split-cycle / scope-expand-approval 결정.

본 cycle 은 두 후속 작업을 묶음:
1. `feature-builder-worker.md` agent contract 에 non-completion 절차 추가
2. PLN1-GATE-ENFORCEMENT 활성화 — `pre-edit-dod-gate.sh:687-688` 주석 해제 + `log_block` + `exit 2`

## Scope Items

| Scope ID | 의미 |
|----------|------|
| AG2-WORKER-RESULT-JSON-SCHEMA | `.rein/worker-result.json` schema 정의 (scope_status / failing_tests / declared_scope / required_scope / reason / evidence / recommendation) |
| AG2-WORKER-NON-COMPLETION-PROCEDURE | worker 가 scope 처리 불가 판단 시 worker-result.json 작성 후 종료하는 절차를 agent contract 에 명시 |
| AG2-WORKER-COMPLETION-PROCEDURE | 정상 완료 시에도 worker-result.json 에 `scope_status: completed` + commit SHA 기록 (parent 가 일관된 read 경로) |
| PLN1-GATE-ENFORCEMENT-ACTIVE | pre-edit-dod-gate.sh 의 PLN1 advisory 분기를 enforcement 활성 (parallelizable: true plan + 본 DoD/active state 가 worker dispatch 아닌 source 편집이면 block) |
| PLN1-ENFORCE-TEST-COVERAGE | 활성화 후 회귀 test 추가 — parallelizable plan + worker 부재 → exit 2 검증 |

## 범위

### IN
- `plugins/rein-core/agents/feature-builder-worker.md` 본문 보강 (non-completion / completion 둘 다 절차)
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh:687-688` 주석 해제 + `log_block` 추가
- `tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh` 신규 — enforcement 동작 회귀
- plan + DoD + inbox 갱신

### OUT
- `.rein/worker-result.json` 의 자동 parent-side reader (parent 가 artifact 를 자동 dispatch 다음 결정에 반영) — 본 cycle 은 agent contract 까지만, parent automation 은 별도 cycle
- perf3 architectural cycle (별도)
- main 머지 + release (별도 release DoD)

## 변경 파일

- plugins/rein-core/agents/feature-builder-worker.md
- plugins/rein-core/hooks/pre-edit-dod-gate.sh
- tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh (신규)
- tests/hooks/run-all.sh (신규 test 등록)
- docs/plans/2026-05-28-worker-contract-plus-pln1-enforce.md (신규)
- trail/dod/dod-2026-05-28-worker-contract-plus-pln1-enforce.md (신규, 본 파일)
- trail/inbox/2026-05-28-worker-contract-plus-pln1-enforce.md (신규)
- trail/index.md (modified)

## 검증 기준

- [ ] PLN-1 validator (`scripts/rein-validate-coverage-matrix.py plan`) PASS
- [ ] `feature-builder-worker.md` 본문에 `.rein/worker-result.json` schema 명시 + 5 reason enum (architectural_contract_conflict / missing_dependency_file / test_contract_stale / scope_mismatch / context_exhaustion) 포함
- [ ] `pre-edit-dod-gate.sh:687-688` 주석 해제 후 `log_block` + `exit 2` 활성
- [ ] enforcement marker `PLN1-GATE-ENFORCEMENT-DISABLED-PENDING-AG2-STABILIZATION` 본문 갱신 — "ACTIVE since 2026-05-28" 명시
- [ ] 신규 test `test-pre-edit-dod-gate-pln1-enforce.sh` 작성: parallelizable: true plan + 본 DoD 가 worker dispatch 아님 → exit 2 검증 + parallelizable: false (legacy) plan → exit 0 (회귀 0)
- [ ] tests/hooks/run-all.sh 전체 회귀 0
- [ ] codex review PASS
- [ ] security review 0 High/Medium
- [ ] dev push 완료 (사용자 승인 후)

## 라우팅 추천

```yaml
agent: claude
skills:
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
security_tier: standard
rationale: |
  본 cycle 은 단일 agent (claude direct) 가 처리. 변경은 hook + agent
  contract 2 파일 + test 1 파일 — multi-file 이지만 disjoint scope 가
  아니라 동일 영역 (AG-2 안정화) 의 응집된 변경. AG-2 worker 자체로
  dispatch 하기에는 본 변경이 worker contract 를 정의하는 자기참조 작업.
approved_by_user: true
approved_at: 2026-05-28
auto_mode: true
```

## 범위 연결

plan ref: docs/plans/2026-05-28-worker-contract-plus-pln1-enforce.md
covers: [AG2-WORKER-RESULT-JSON-SCHEMA, AG2-WORKER-NON-COMPLETION-PROCEDURE, AG2-WORKER-COMPLETION-PROCEDURE, PLN1-GATE-ENFORCEMENT-ACTIVE, PLN1-ENFORCE-TEST-COVERAGE]

## 위험·완화

| 위험 | 영향 | 완화 |
|---|---|---|
| PLN1 enforcement 활성화가 legacy DoD/plan 차단 | 메인테이너 작업 흐름 차단 | `parallelizable: true` 명시 plan 만 block. 부재/false 인 legacy plan 은 통과 (backward-compat) |
| worker-result.json 부재 worker 가 enforcement 적용 시 false-positive block | 단순 작업도 차단 위험 | enforcement 가 "parallelizable: true plan + active DoD 가 worker dispatch 의도" 만 block. 일반 작업은 plan 의 ## 실행 전략 자체가 없으므로 무관 |
| worker contract 변경이 기존 worker (worker_a/d) 의 동작에 영향 | 회귀 위험 | feature-builder-worker.md 변경은 description text 만 — 코드 동작 변경 없음. 새 절차는 future worker 가 자발 채택 |
