# DoD — cc-feature-adoption Phase 1 구현 (v1.4.0)

- 날짜: 2026-05-19
- 유형: feat + refactor
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md

## 목표

Claude Code v2.1.144 의 hook·subagent 기능과 Rein 내부 최적화를 적용하는
cc-feature-adoption plan 의 **Phase 1 (Task 1.1~1.6)** 를 구현한다. 7개 Scope ID
(HK-1·HK-2·RT-1·RT-2·HK-3·PERF-1·AG-1) — subprocess 절감, 리뷰·라우팅 차등화,
구현→리뷰 자동 안내, 에이전트 분화. Phase 2(SPIKE-1)·Phase 3 은 비범위.

확정 사실 (2026-05-19 명령 재검증): Claude Code = 2.1.144 (plan 전제 hook 기능
`if` 필드 / PostToolUse Agent matcher 지원 버전과 일치). dev HEAD = `02a69b1`.

## 완료 기준

plan `docs/plans/2026-05-19-cc-feature-adoption.md` 의 Phase 1 Task 1.1~1.6 의
각 Steps + Verify, spec acceptance 시나리오 1~9 를 충족한다.

- **Task 1.1 (HK-1)** — `post-write-*` 4 sub-hook 을 `post-edit-*` 로 rename,
  Step 1 grep 이 식별한 모든 참조 (dispatcher·정책로더·drift checker·테스트 등)
  일괄 갱신. `grep -rn 'post-write-' tests/ plugins/` 결과 0건, dispatcher 회귀 없음.
- **Task 1.2 (HK-2)** — `pre-bash-guard.sh` 를 `pre-bash-safety-guard.sh`(무조건
  실행) + `pre-bash-test-commit-gate.sh`(`if`-gated) 로 분리. P1-P11·I1-I6 17지점을
  spec §HK-2 배정표대로 누락 없이 배정 (I1·I2·I6 공통 lib). `grep -rn
  'pre-bash-guard' tests/ plugins/` 잔존 0건.
- **Task 1.3 (RT-1·RT-2)** — `## 라우팅 추천` YAML 에 `security_tier` +
  `complexity`/`model_hint`/`effort_hint` 추가. `security_tier: light` +
  `approved_by_user: true` 일 때만 `.security-reviewed` 면제 (fail-closed).
- **Task 1.4 (HK-3)** — `post-agent-review-trigger.sh` 신설 + hooks.json
  PostToolUse(Agent) 엔트리. feature-builder 계열 + `.review-pending` 시
  `decision:block`+reason emit, 비대상 agent 는 무동작.
- **Task 1.5 (PERF-1)** — `rein-aggregate-incidents.py` 복합 CLI + `--output-json`,
  `session-start-load-trail.sh` 가 3회 분리 호출 → 1회 통합 호출.
- **Task 1.6 (AG-1)** — `feature-builder` 를 base/fix/refactor 3개로 분화 +
  `routing-procedure.md` 키워드 감지. 세 에이전트 동일 stamp 구조.
- **공통** — 각 Task 재현/회귀 테스트 선작성 (TDD red→green). 신규 필드·동작은
  전부 backward-compat (부재 시 현행 동작). `bash tests/hooks/run-all.sh` +
  `bash tests/scripts/run-all.sh` 무회귀. codex review + security review 통과 후
  stamp 생성. **Phase 1 단일 커밋** (사용자 지정).

## 작업 범위

plan Phase 1 covers: HK-1, HK-2, RT-1, RT-2, HK-3, PERF-1, AG-1 (7 Scope ID).
coverage matrix 는 plan 문서가 SSOT — 본 DoD 는 `plan ref:` 로 연결.

## 비범위 (이번 작업 제외)

- Phase 2 (SPIKE-1, Task 2.1) · Phase 3 (DEC-1·PLN-1·AG-2, Task 3.1~3.3) — 별도 릴리즈.
- HK-4 / PERF-2 / HK-5 — SPIKE-1 종속, plan 에서 `deferred`.
- `scripts/rein.sh` VERSION bump — main 머지 시점 결정 (versioning Rule B). dev 미변경.
- G8-3 / SR-1 / GE-1 / GE-2 — 별개 미해결 항목.
- main 머지 / 선별 체크아웃 — Phase 1 dev 누적까지만, main 머지는 다음 근무일.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
  - rein:codex-review
mcps: []
execution_strategy:
  parallelizable: true
  waves:
    - wave: 1
      tasks: [1.1, 1.5]
      mode: parallel
      rationale: 상호 완전 file-disjoint (검증 완료) — 1.1(hook rename+dispatcher
        +scripts+tests/hooks) / 1.5(aggregate.py+session-start+tests/scripts).
        git index 변경(git mv)은 1.1 만 → index race 없음.
    - wave: 2
      tasks: [1.4]
      mode: sequential
      rationale: 1.1 과 test-registry 파일(tests/hooks/run-all.sh,
        test-plugin-hooks-json-parity.sh) 공유 — 1.1 후. 초안의 Wave 1 동시
        편성을 철회 (run-all.sh 등록 라인·hooks.json 파리티 테스트 충돌 발견).
    - wave: 3
      tasks: [1.2]
      mode: sequential
      rationale: 1.1(rein-policy-loader.py)·1.4(hooks.json) 와 공유 파일 충돌 — 후행.
    - wave: 4
      tasks: [1.3]
      mode: sequential
      rationale: 1.2 가 만드는 pre-bash-test-commit-gate.sh 를 편집 — hard dep.
    - wave: 5
      tasks: [1.6]
      mode: sequential
      rationale: 1.3 과 routing-procedure.md 공유 — plan 명시 순서.
rationale: >
  hook bash 리팩터링 + 신규 hook + 에이전트 분화 — feature-builder 가 기능 구현·
  리팩터링 전담. 6개 Task 는 TDD 재현 테스트 선작성 필수라
  test-driven-development, 리뷰 게이트에 codex-review. 외부 API/문서 조회 없어
  MCP 불요. 파일 의존성 분석 결과 Wave 1(1.1·1.4·1.5)만 병렬, 1.2→1.3→1.6 은
  엄격 순차. Wave 1 은 file-disjoint subagent 병렬 dispatch, 이후 순차 dispatch.
  리뷰는 Phase 1 전체 변경분에 codex/security 1회 (단일 커밋).
approved_by_user: true  # 2026-05-19 사용자 승인 — feature-builder 서브에이전트, Wave 1(1.1‖1.4‖1.5) 병렬 후 1.2→1.3→1.6 순차, codex+security 리뷰 1회 후 단일 커밋
```
