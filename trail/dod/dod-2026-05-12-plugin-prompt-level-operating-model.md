# DoD — Plugin prompt-level operating model (v1.1.0)

- 날짜: 2026-05-12
- 유형: feat (brownfield, minor release)
- 타깃 release: v1.1.0
- spec ref: docs/specs/2026-05-12-plugin-prompt-level-operating-model.md
- plan ref: docs/plans/2026-05-12-plugin-prompt-level-operating-model.md
- brainstorm ref: docs/brainstorms/2026-05-12-plugin-prompt-level-operating-model.md
- spec stamp: trail/dod/.spec-reviews/595f862cd4d9eb96.reviewed (user-approved)
- plan stamp: trail/dod/.spec-reviews/d4ffff1038bbd3ed.reviewed (user-approved)
- approved_by_user: true

## 목표 한 줄

rein plugin v1.0.4 에 7 user-facing rule 의 prompt-level 책임을 6 mode delivery taxonomy + action mandate + overflow handoff 패턴으로 적시 전달하고, broken ref 5건을 inline 화하며, publish-time 형식 검사 + Claude Code minimum version 강제를 도입한다.

## 범위 연결

plan ref: docs/plans/2026-05-12-plugin-prompt-level-operating-model.md
work unit: Phase 1 ~ Phase 3 전체 (16 tasks)
covers: [plugin-bundled-rules-relocated-from-skills-rules-prompt-to-plugins-rein-core-rules-dir, each-plugin-shipped-rule-has-action-mandate-section-under-2kb-at-start-of-body, design-plan-coverage-body-size-under-10kb-after-stage-3-3-deletion-and-example-diet, dev-only-rules-excluded-from-plugin-tarball-via-branch-strategy-exclusion-list, session-start-rules-hook-injects-action-mandate-plus-body-for-code-style-security-testing-on-session-begin, user-prompt-submit-hook-injects-answer-only-mode-action-mandate-plus-body-every-user-turn, pre-tool-use-bash-hook-emits-background-jobs-action-mandate-plus-body-as-advisory-additional-context-after-bash-tool-selection-for-next-reasoning-step, pre-tool-use-agent-hook-emits-subagent-review-action-mandate-plus-body-as-advisory-additional-context-after-agent-tool-selection-for-next-reasoning-step, post-tool-use-injects-design-plan-coverage-action-mandate-plus-body-when-edit-write-targets-docs-specs-or-docs-plans-or-trail-dod-dod, post-edit-dispatcher-aggregates-all-active-sub-hook-stdout-into-single-json-envelope-preserving-each-stderr-and-propagating-exit-2-from-any-sub-hook, plugin-rule-body-exceeding-10000-chars-passes-through-as-claude-code-overflow-file-not-truncated-by-rein-hooks, pre-edit-dod-gate-stderr-lines-166-and-204-and-379-and-447-replace-orchestrator-md-references-with-inline-routing-procedure-text, post-write-dod-routing-check-stderr-line-77-replaces-orchestrator-md-reference-with-inline-routing-procedure-text, rein-publish-script-rejects-plugin-tarball-when-any-rule-missing-action-mandate-or-action-mandate-exceeds-2048-chars-or-hook-output-invalid-json]

## Task 분할 (plan 의존성 순서)

### Phase 1 — Rule catalog + action mandate (Task 1.1 → 1.2 → 1.3 → 1.4 → 1.5)
- Task 1.1: `skills/rules-prompt/` → `rules/` 마이그레이션 + `session-start-rules.sh` RULES_DIR 갱신
- Task 1.2: code-style / security / testing 에 `## 행동 강령` 절 추가 (≤ 2KB)
- Task 1.3: answer-only-mode / subagent-review / background-jobs 신규 plugin 복사 + 행동 강령 절 추가
- Task 1.4: design-plan-coverage 다이어트 (§3.3 삭제 + §1.4 예시 6→2 + §1.3 압축) → < 10KB + 행동 강령 절
- Task 1.5: dev-only 4 rule (branch-strategy/readme-style/versioning/legacy-shipped-pending) plugin 미포함 확인

### Phase 2 — Hook lifecycle (Task 2.0 → 2.1/2.2/2.3/2.4 → 2.5 → 2.6 → 2.7)
- Task 2.0: `hooks/lib/rule-inject.sh` helper (override probe + body 반환) — 모든 신규 inject hook 의 dependency
- Task 2.1: `user-prompt-submit-rules.sh` 신설 (turn-brief / answer-only-mode)
- Task 2.2: `pre-tool-use-agent-rules.sh` 신설 (tool-brief / subagent-review, Agent matcher)
- Task 2.3: `pre-tool-use-bash-rules.sh` 신설 (tool-brief / background-jobs, 기존 pre-bash-guard 와 분리)
- Task 2.4: `post-write-design-plan-coverage-rule.sh` 신설 (event-brief / docs/specs|plans|trail/dod 매치) + dispatcher sub-hook 등록
- Task 2.5: `hooks.json` final manifest (UserPromptSubmit slot + Agent matcher + Bash matcher 추가)
- Task 2.6: `post-edit-dispatcher.sh` aggregator refactor + `hooks/lib/aggregator.sh` (단일 JSON envelope + exit 2 propagation)
- Task 2.7: overflow handoff 정책 (no truncation + size diagnostic to stderr) + `docs/overflow-handoff.md`

### Phase 3 — Broken refs + CI (Task 3.1/3.2 병렬 가능, 3.3 별도)
- Task 3.1: `pre-edit-dod-gate.sh` line 166/204/379/447 orchestrator.md ref → inline 절차 텍스트
- Task 3.2: `post-write-dod-routing-check.sh` line 77 orchestrator.md ref → inline 절차 텍스트
- Task 3.3: `scripts/rein-validate-plugin-rules.py` + `scripts/rein-publish.sh` pre-publish 호출 (행동 강령 절 / 2KB / JSON envelope / dev-only 부재 검사)

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - superpowers:executing-plans     # 17 task plan 실행 discipline (review checkpoint 포함)
  - superpowers:test-driven-development  # 각 task 의 test 먼저 작성 패턴 — plan 의 모든 task 가 "failing test → impl → green" 구조
  - codex-review                    # 구현 완료 후 통합 코드 리뷰 stamp 생성
mcps: []                            # 외부 service 의존 없음 — 모두 local file/hook/script
rationale: >
  brownfield plugin 확장. plan 이 task 단위 TDD 구조 (test 먼저, impl, green) 로 명시되어 있고
  17 task 의 의존성이 명확해서 executing-plans + TDD 조합이 적합. codex-review 는 11단계 시퀀스
  필수 게이트. security-reviewer 는 codex-review 완료 후 자동 호출되므로 별도 명시 안 함.
  Explore agent 는 Plan/Spec 이 이미 파일 경로/라인 명시해서 불필요.
approved_by_user: true
```

## 위험 / 회귀 영역

1. **rules-prompt → rules/ 마이그레이션 (Task 1.1)** — `session-start-rules.sh` 의 RULES_DIR 갱신과 파일 이동이 atomic 해야 함. plan §"Migration Order" 의 4단계 (생성 → 갱신 → 테스트 → 옛 위치 삭제) 강제.
2. **dispatcher aggregator (Task 2.6)** — 기존 6 sub-hook 의 stderr/exit 2 의미 보존 필수. `post-edit-plan-coverage.sh` 의 exit 2 propagation 회귀 테스트 필수 (plan Task 2.6 Step 5).
3. **PreToolUse(Bash) 2 hook 공존 (Task 2.3)** — 기존 `pre-bash-guard.sh` 의 차단 동작 (codex stamp 부재 시 exit 2) 이 신규 inject hook 으로 인해 깨지지 않음. plan Task 2.3 Step 6 확인.
4. **PostToolUse hook input schema (Task 2.4)** — `tool_input.file_path` primary + `tool_response.filePath` / `tool_result.file_path` fallback 셋 다 fixture 로 검증. MultiEdit 동작은 Claude Code docs 미명시 — fixture 결과로 확정.
5. **overflow handoff 가정 (Task 2.7)** — Claude Code 의 10,000 chars cap + overflow-file 메커니즘은 외부 의존. unit test 는 "rein 이 truncate 안 함" 만 검증, end-to-end 는 integration test 로 분리.

## 검증 계획

- **Unit tests** — Phase 1: action mandate 절 존재/크기, design-plan-coverage size, dev-only 부재. Phase 2: rule-inject helper, 4 신규 hook envelope JSON, aggregator concat/exit 2, overflow no-truncation. Phase 3: orchestrator.md ref 부재, publish-time validation.
- **Integration tests** — MultiEdit hook input schema (Task 2.4), shell-stamp 가 PostToolUse 미 trigger (Task 2.4 deferred 근거), overflow end-to-end (Task 2.7).
- **Regression** — `post-edit-plan-coverage.sh` exit 2 propagation (Task 2.6), `pre-bash-guard.sh` 차단 시나리오 (Task 2.3).
- **Pre-publish dry-run** — Task 3.3 의 `rein-validate-plugin-rules.py` 가 모든 게이트 통과 확인.
- **`/codex-review`** — Phase 1+2+3 전체 diff 대상 통합 리뷰 (stamp 생성).
- **`security-reviewer`** — hook envelope / publish-time script / inline 절차 텍스트의 injection vector 점검.

## 완료 기준

- [ ] 16 task 모두 완료 + 각 task 의 test PASS
- [ ] `python3 scripts/rein-validate-plugin-rules.py` exit 0
- [ ] `scripts/rein-validate-coverage-matrix.py plan docs/plans/2026-05-12-plugin-prompt-level-operating-model.md` 통과
- [ ] `/codex-review` PASS → `trail/dod/.codex-reviewed` stamp
- [ ] `security-reviewer` PASS → `trail/dod/.security-reviewed` stamp
- [ ] `trail/inbox/2026-05-12-plugin-prompt-level-operating-model-impl.md` 작성
- [ ] `trail/index.md` 갱신 (다음 진입점 = v1.1.0 main 머지)
- [ ] CHANGELOG.md 항목 추가 (user-facing 효과 — 행동 강령 적시 inject, broken ref 해소)
- [ ] main 머지 + `v1.1.0` tag 는 별도 release task (본 DoD 외부)
