# DoD — Hook hot-path 성능 최적화 (G3 follow-up)

- 날짜: 2026-06-02
- 작업 유형: 리팩토링 (성능 최적화 — 불필요 process/Python spawn 제거, 단일 의도 deviation 외 동작 불변)
- plan ref: docs/plans/2026-06-02-hook-hotpath-perf-implementation.md

## 요약

매 Edit/Bash 훅 체인의 불필요한 process/Python spawn 을 제거한다. Track A: `resolve_python` 이 POSIX 의 bare python3/python PATH 후보에 한해 launch 기반 health_check 생략(REIN_PYTHON·venv 는 유지). Track B축소: 2 rule 훅의 file_path(3단 fallback 보존)+tool_use_id 추출 python spawn 병합(3→2). Track C: pre-bash bootstrap/safety in-process 인라인(A 적용 후 측정 → 사용자 ship/defer 결정). 동작은 단일 의도된 deviation(깨진 bare python3 exit 12→0) 외 byte-identical.

## 범위 (IN)

- PERF-A-LAUNCH-SKIP / PERF-A-EXIT-PARITY / PERF-A-PARITY-FIXTURE: resolve_python 좁힌 launch-skip + exit-code 계약 보존 + 9 fixture
- PERF-B-RULE-SPAWN-MERGE / PERF-B-BYTE-IDENTICAL: 2 rule 훅 spawn 병합(type-guard 포함) + byte-identical 회귀(routing 전용 fixture 신규)
- PERF-C-INLINE / PERF-C-FAIL-CLOSED / PERF-C-GATED-GAIN: bootstrap/safety lib 추출 + dispatcher in-process + fail-closed 보존 + 측정 게이트(사용자 결정)
- PERF-NFR-PER-HOOK: per-hook 고정 임계 bench(신규)
- PERF-NO-DAEMON / PERF-DOC-RECONCILE: daemon 부재 정적 점검 + post-edit-dispatcher.sh 주석 정합

## 범위 (OUT)

- post-edit 11→1 전체 재통합 (SPIKE-1 닫힌 결정)
- meta-check 추가 최적화 (이미 최적)
- 이벤트당 누적 hard gate (advisory only)
- Track C 는 측정 게이트(Task 3.0) defer 시 미ship — 측정값+결정 회고 기재

## 변경 파일

- plugins/rein-core/hooks/lib/python-runner.sh
- plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh
- plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh
- plugins/rein-core/hooks/post-edit-dispatcher.sh (주석 정합)
- tests/hooks/test-python-runner-launch-skip.sh (신규)
- tests/hooks/test-post-edit-routing-procedure-rule.sh (신규)
- tests/hooks/test-post-edit-design-plan-coverage-rule.sh (fallback 케이스 보강 시)
- tests/hooks/test-hook-hotpath-perf.sh (신규)
- (Track C ship 시) plugins/rein-core/hooks/lib/bash-bootstrap-gate.sh (신규), lib/bash-safety-guard.sh (신규), pre-tool-use-bash-bootstrap-gate.sh, pre-bash-safety-guard.sh, pre-bash-dispatcher.sh

## 완료 기준 (검증)

1. Track A: `test-python-runner-launch-skip.sh` 9 fixture PASS + 기존 `test-python-runner.sh` 회귀 PASS
2. Track B: design-plan + routing(신규) fixture PASS — 3단 fallback + 비문자열 tool_use_id type-guard 검증 + aggregator 병합 회귀 PASS + 정적 grep python3 3→2
3. Track C (ship 시): pre-bash-guard 회귀 + fail-closed 테스트 PASS + always-run fork 0. defer 시: 측정값+결정 회고 기재
4. NFR: `test-hook-hotpath-perf.sh` per-hook p95 고정 strict 임계 이하(구현 후 확정), 누적 advisory only
5. No daemon 정적 grep 0건 + `grep -rn '8 sub' plugins/rein-core/` 0건
6. `bash tests/run-all.sh` 전체 PASS + `rein-check-plugin-drift.py` exit 0
7. codex 코드리뷰 통과 + security 리뷰 통과(safety-guard 리팩토링 surface)

## 라우팅 추천

agent: rein:feature-builder-refactor
skills:
  - rein:parallel-execute
  - rein:codex-review
mcps: []
security_tier: standard
rationale:
  - 작업 유형 = 성능 리팩토링(동작 보존, spawn 제거). 키워드 "성능 개선/리팩터" → feature-builder-refactor.
  - **spec 의 light 에서 standard 로 상향**: Track C 가 pre-bash-safety-guard(보안 게이트)를 in-process 인라인하고 Track A 가 인터프리터 trust boundary(깨진 python 통과)를 건드림 → security-reviewer 가 정식 점검. 동작은 byte-identical 이나 보안 표면 변경이라 보수적 상향.
  - plan 실행 전략의 Wave 1(Track A + B + doc + tests, disjoint scope) 을 parallel-execute 로 병렬 실행. Track C 는 Task 3.0 측정 게이트(사용자 결정) 후 별도 웨이브.
  - codex 복구됨 — 통합 코드리뷰 + per-task 리뷰는 codex Mode A.
approved_by_user: true
