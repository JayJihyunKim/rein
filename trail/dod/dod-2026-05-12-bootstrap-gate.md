# DoD — Plugin bootstrap gate (v1.1.1 hotfix)

- 날짜: 2026-05-12
- 유형: feat (brownfield, patch release v1.1.1)
- 타깃 release: v1.1.1
- spec ref (예정): docs/specs/2026-05-12-bootstrap-gate.md
- plan ref (예정): docs/plans/2026-05-12-bootstrap-gate.md
- 선행 분석:
  - codex-ask 1차 (trail bootstrap 진단): /tmp/codex-ask-trail-out.log
  - codex-ask 2차 (방향 검증): /tmp/codex-ask-bootstrap-direction.out
- 선행 release: v1.1.0 (main `9360650`, tag `v1.1.0`)

## 목표 한 줄

rein plugin 사용자가 자기 프로젝트 (git or non-git 무관) 에서 새 세션 시작 또는 `/reload-plugins` 실행 후, `trail/` 폴더가 없으면 첫 source 편집·Bash 도구 시도 직전에 차단되고 한 줄짜리 bootstrap 명령 안내를 받도록 한다. 두 trigger 경로 모두 동일한 helper·메시지·명령으로 수렴.

## 범위 한계 (이번 DoD — 확장)

- 본 DoD 는 **spec + plan + 구현 + review + release** 전 단계 cover.
- spec 단계 완료 (Round 3 PASS, stamp `51eb8141e61f7dfe.reviewed`).
- plan 단계 완료 (Round 4 user-approved, stamp `f3a299ca44af7698.reviewed`).
- 구현 단계 — 11 task / 4 wave 병렬 dispatch (file partitioning conflict-free):
  - Wave 1: Task 1.1 helper (단독)
  - Wave 2 (병렬 4): Task 1.2 / 1.3 / 1.5 / 2.3
  - Wave 3 (병렬 3): Task 1.4 / 2.1 / 2.2
  - Wave 4 (병렬 5): Task 3.1 / 3.2 / 3.3 / 3.4 / 3.5
- review 단계: codex-review (Mode A) + security-reviewer
- release: dev commit + main 선별 체크아웃 + `v1.1.1` tag + mirror-to-public

## 라우팅 추천

```yaml
agent: plan-writer       # plan 단계 — design 읽어 coverage matrix + covers 메타데이터 plan 작성 + validator + codex-review + plan stamp 자동
skills:
  - codex-review         # spec 단계에서 spec-review subflow 호출 (이미 완료, Round 3 PASS)
mcps: []
rationale: >
  spec 단계는 plain markdown 작성 + codex spec-review (이미 완료). plan 단계는
  plan-writer agent 가 자동 흐름 — spec 의 Scope Items 를 plan work unit 에 1:1
  매핑 + coverage matrix validator + codex spec-review subflow + plan stamp 자동
  생성. self-fix loop 없음 — NEEDS-FIX 시 사용자 핸드오프.
approved_by_user: true
```

## Task 분할 (spec + plan)

**Spec 단계 (완료)**:
1. ✅ spec markdown 작성 — `docs/specs/2026-05-12-bootstrap-gate.md` (19 Scope Items)
2. ✅ codex-review spec-review subflow 3 rounds (R1 NEEDS-FIX → fix → R2 NEEDS-FIX → fix → R3 PASS)
3. ✅ spec stamp 생성 — `trail/dod/.spec-reviews/51eb8141e61f7dfe.reviewed`

**Plan 단계**:
4. plan-writer agent dispatch — spec ref 전달, plan target `docs/plans/2026-05-12-bootstrap-gate.md`
5. agent 가 자동 수행:
   - design 의 Scope Items 읽기 → plan 의 `## Design 범위 커버리지 매트릭스` + 각 work unit `covers:` 메타데이터 생성
   - Phase 분할 (spec §"Phase 분할" 참고 — Phase 1 helper+차단, Phase 2 advisory+non-git, Phase 3 test+README)
   - `python3 scripts/rein-validate-coverage-matrix.py plan ...` PASS 확인
   - codex spec-review subflow 호출 (`[NON_INTERACTIVE] spec review for plan: docs/plans/...`)
   - PASS 시 `bash scripts/rein-mark-spec-reviewed.sh <plan-path> codex` 로 plan stamp 자동 생성
   - NEEDS-FIX/REJECT 시 사용자 핸드오프 (self-fix loop 없음)
6. plan stamp 생성 확인 후 inbox 기록 + index 갱신

## 핵심 scope 후보 (spec 에서 확정)

codex-ask 2차 결과 반영:
- A. trail/ 부재 시 PreToolUse(Edit|Write|MultiEdit) 차단 + 안내 stderr
- B. trail/ 부재 시 PreToolUse(Bash) 도 동일 차단 (source-writing Bash 우회 cover)
- C. trail/ 부재 시 UserPromptSubmit 가 모델에게 advisory inject (read-only session cover)
- D. 세 hook 가 동일 helper `bootstrap-check.sh` 사용 (DRY 메시지·명령)
- E. project dir resolution = stdin.cwd → git root → PWD (env var 의존 금지) — 기존 `project-dir.sh` 재사용
- F. helper API contract: stdout = 안내 텍스트, exit 0 = trail 존재 (no-op), exit 10 = bootstrap 필요, exit 11 = unsafe/refused
- G. hooks.json Edit|Write|MultiEdit matcher group 에서 bootstrap gate 가 첫 번째 (trail-rotate 보다 앞)
- H. `.rein/policy/hooks.yaml` 에서 bootstrap-gate disable 가능 (opt-out)
- I. helper 메시지에 "사용자에게 즉시 surface" instruction 포함 (모델 surface 확률 강화)
- J. project root 결정 — monorepo subdir launch 기본값 = git root (override env / option 은 v1.1.2+ defer)

## 위험 / 회귀 영역

1. **trail-rotate 순서 변경**: bootstrap gate 가 Edit matcher group 첫 번째로 가면, 기존 hook 순서에 의존하는 시나리오가 깨질 수 있음. test-pre-edit-dod-gate.sh / test-post-edit-dispatcher.sh 회귀 필수.
2. **Bash 도구 차단의 부작용**: PreToolUse(Bash) 의 추가 차단 hook 가 기존 `pre-bash-guard.sh` 의 stamp 체크와 충돌 가능. 우선순위 + 누적 차단 시나리오 검증.
3. **opt-out 의 의미**: `.rein/policy/hooks.yaml` 에서 bootstrap-gate disable 시 사용자 책임으로 trail/ 미생성 상태에서 작업 가능 — 의도적 동작이지만 다른 hook (예: stop-session-gate) 가 trail/ 부재로 오작동 가능.
4. **`/reload-plugins` lifecycle**: spec 상 SessionStart 재실행 안 됨 가정 — 검증 못 함 (codex-ask 의 UNVERIFIED). 실제 spec 미확정 동작에 의존하지 말고 PreToolUse hard gate 만 보장 contract.
5. **stderr surface 보장**: Claude Code UI 의 stderr 전체 surface 는 spec 부재. contract = "차단 + 모델이 메시지 받음" 까지만. 사용자 surface 는 best-effort.

## 검증 계획 (spec 단계)

- **Scope Items v2 contract**: 각 ID 가 entity + direction/threshold + scenario 3요소 포함 (design-plan-coverage.md §1.2)
- **coverage matrix validator**: spec subcommand 부재 (`scripts/rein-validate-coverage-matrix.py` 는 plan/dod 만 지원). 본 cycle 에서는 spec 의 내적 일관성을 codex spec-review subflow 가 검증 — 별도 spec validator 없음. plan 단계에서 plan matrix 가 본 spec 의 Scope Items 와 정합성 검증.
- **codex-review spec-review subflow**: `[NON_INTERACTIVE] spec review for design: docs/specs/2026-05-12-bootstrap-gate.md`
- **PASS 시 stamp**: `trail/dod/.spec-reviews/<hash>.reviewed`

## 완료 기준 (본 DoD)

- [ ] `docs/specs/2026-05-12-bootstrap-gate.md` 작성
- [ ] coverage matrix validator exit 0
- [ ] codex spec-review PASS verdict + spec stamp 생성
- [ ] `trail/inbox/2026-05-12-bootstrap-gate-spec.md` 작성
- [ ] `trail/index.md` 갱신 — 다음 진입점 = "bootstrap gate plan 작성 + 구현 (v1.1.1)"
