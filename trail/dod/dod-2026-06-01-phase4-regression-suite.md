# DoD — Phase 4: 회귀 테스트 스위트 통합

- 날짜: 2026-06-01
- 유형: test (병렬 실행 재설계 Phase 4 — 스케줄러/부모-델타 동작 테스트 + 러너 등록)
- plan ref: docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md §Phase 4 (Task 4.1/4.2)

## 목표 (Why)

Phase 1~3 의 산출물(검증기 v2 + schedule emitter, parallel-execute 스킬, plan-writer v2, 게이트 제거, 워크트리 폐기)에 대한 회귀 그물을 완성한다. 검증기 단위 테스트(Phase 1)·스킬/plan-writer/게이트/워커 grep 테스트(Phase 2~3)는 이미 존재 — 본 Phase 는 (1) **결정적 스케줄러 + 부모 델타 검증의 동작(product 표면)** 테스트를 신규 작성하고, (2) 신규 테스트를 러너에 등록해 전체 그린을 확인한다.

## 성공 기준 (Acceptance)

### Task 4.1 — 결정적 스케줄러 + 부모 웨이브-union 검증 동작 테스트
covers: REGRESSION-TESTS-V2

1. `tests/scripts/test-wave-scheduler-and-parent-delta.sh` 신설.
2. **스케줄러 동작 (product 표면 직접 검증)** — fixture plan(혼합 ready 집합: edit_only 2 disjoint + mutating 1, depends_on 구성)에 `python3 scripts/rein-validate-coverage-matrix.py schedule <fixture>` 실행 → 출력 step 순서가 **mutating-solo-then-edit_only + plan 순서 tiebreak** 으로 결정적인지 단언(mutating 단독 step + edit_only 동시 step). "테스트가 테스트를 검증" 회피 — emitter 가 testable product.
3. **부모 델타 검증 로직** — 임시 git repo fixture 에서 (a) 델타 ⊆ scope union → 통과, (b) 선언 밖 파일(untracked 디렉토리 포함) 변경 → reject 단언. 델타 산출은 `git status --porcelain=v1 -z -uall` 정규화 경로 비교를 셸 헬퍼로 재현(스킬 지시 명령과 동일 형태).
4. Run → GREEN.

### Task 4.2 — 러너 등록 + 전체 회귀 그린
covers: REGRESSION-TESTS-V2

5. `tests/scripts/test-wave-scheduler-and-parent-delta.sh` 를 `tests/scripts/run-all.sh` 에 등록(CI 가 invoke 하는 러너 — 명시 리스트 패턴 동일).
6. `tests/agents/` 가 유일하게 run-all.sh 부재 → 다른 디렉토리(hooks/rules/scripts/skills)와 동일 패턴으로 `tests/agents/run-all.sh` 신설, agents 테스트(test-ag2-worktree-frontmatter / test-plan-writer-exec-strategy-v2 / test-dod-changed-files-section) 등록. (test-parallel-execute-skill 은 이미 tests/skills/run-all.sh 등록됨 — 확인만.)
7. 폐기/재작성 테스트 정합: 재작성된 test-pln1-enforce / test-ag2-worktree-frontmatter / 검증기 v2 테스트가 러너에서 호출되며 통과하는지 확인(이름 유지).
8. Run: 전 디렉토리 러너(`tests/hooks/run-all.sh`, `tests/scripts/run-all.sh`, `tests/rules/run-all.sh`, `tests/skills/run-all.sh`, `tests/agents/run-all.sh`) → 전부 GREEN. legacy v1 plan(`docs/plans/2026-05-28-ag2-dogfood-4-worker.md`)은 재검증 안 됨(히스토리) 확인.
9. codex 리뷰 PASS + 보안 리뷰 PASS (commit gate).

## 변경 파일

- `tests/scripts/test-wave-scheduler-and-parent-delta.sh` (신설)
- `tests/scripts/run-all.sh` (신규 테스트 등록)
- `tests/agents/run-all.sh` (신설 — 다른 디렉토리 패턴 따라 agents 테스트 등록)

## 제외 (Out of scope)

- `.github/workflows/tests.yml` 에 tests/agents·tests/skills 러너 추가 — CI 표면 확장은 별 결정(test-ci-matrix.sh 가 현재 hooks+scripts 만 강제). 본 Phase 는 로컬 전체 그린 + scripts 러너(CI 도달) 등록까지. **CI 가 agents/skills 러너를 안 도는 구조적 사실은 부모에게 surface**.
- 검증기/스케줄러 emitter 로직 자체 변경 — Phase 1 확정, 본 Phase 는 소비/검증만.
- 스킬/plan-writer/게이트/워커 grep 테스트 — Phase 2~3 에서 이미 생성.

## 리스크

- (R1) 스케줄러 동작 테스트가 emitter 출력 포맷(`step <n>: <id>...`)에 의존 — 포맷 변경 시 깨짐. mitigation: Phase 1 이 SSOT 로 고정, 본 테스트가 그 계약을 회귀 보호(의도).
- (R2) 부모 델타 검증을 셸 헬퍼로 재현 — 스킬의 마크다운 지시와 drift 가능. mitigation: 스킬이 지시하는 정확한 명령(`git status --porcelain=v1 -z -uall` + repo-relative 정규화)을 그대로 사용, 동일성 주석 명시.
- (R3) 임시 git repo fixture — CI 환경 git 식별자/clean state 의존. mitigation: fixture 내 `git init` + 로컬 config, 절대경로 격리.

## 라우팅 추천

```yaml
agent: rein:feature-builder          # 신규 테스트 파일 + 러너 신설 (add-test) — feature-builder 적합
skills:
  - rein:codex-review                # commit gate 필수
mcps: []
rationale: >
  Phase 4 = 회귀 테스트 신설 + 러너 등록. product 표면(schedule emitter + 델타 로직)을
  직접 검증하는 동작 테스트가 핵심. 단일 coherent 작업(4.1 작성 → 4.2 등록)이라 단일
  subagent 순차. security_tier=normal — 테스트가 임시 git repo·셸 헬퍼를 다루므로 fixture
  격리·주입 표면 확인.
security_tier: normal
approved_by_user: true               # 사용자 "Phase 3,4 오토모드 자동 진행" 위임 (2026-06-01)
```

## Self-review 예정 항목 (AGENTS.md §6)

- 스케줄러 테스트가 emitter product 표면을 직접 호출하는가(테스트가 테스트 검증 회피)
- 부모 델타 테스트가 스킬 지시 명령과 동일 형태(`--porcelain=v1 -z -uall` + 정규화)인가
- 신규 테스트가 CI 도달 러너(tests/scripts/run-all.sh)에 등록됐는가
- tests/agents/run-all.sh 가 다른 디렉토리 패턴과 일치하는가
- 전 디렉토리 러너 전부 GREEN + 임시 fixture 격리(절대경로·로컬 config)
- CI 가 agents/skills 러너 미invoke 하는 구조적 사실을 surface 했는가
