# DoD — cc-feature-adoption Phase 4: short rule injection + Bash hook if-field

- 작업 시작일: 2026-05-20
- 유형: feat (patch — Phase 4 user-facing rule body 축소 + hook config tweak, versioning.md Rule A patch)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 4 신설 예정)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 4 (Task 4.1 short-rule-injection, Task 4.2 bash-hook-if-field)
covers: [UPS-1-user-prompt-submit-rules-and-pre-tool-use-bash-rules-hooks-inject-short-summary-bodies-instead-of-full-answer-only-mode-and-background-jobs-text-while-session-start-rules-keeps-its-existing-four-rule-full-inject-unchanged, PERF-3-background-jobs-advisory-hook-skipped-via-if-field-hot-path-whitelist-pattern-while-bootstrap-gate-and-safety-guard-remain-always-on]

## 배경

2026-05-20 Phase 0 측정 결과:

| 항목 | 1회 크기 | 빈도 | 1시간 누적 |
|---|---:|---:|---:|
| SessionStart (session-start-rules.sh concat) | 12 KB | 1회 | 12 KB |
| UserPromptSubmit (answer-only-mode.md) | 7 KB | 매 user turn | ~140 KB |
| PreToolUse(Bash) (background-jobs.md) | 6 KB | 매 Bash 호출 | ~180 KB |
| **합계** | | | **~332 KB** |

Hook wall-clock (3회 평균):

| Hook | wall-clock | 빈도 |
|---|---:|---|
| session-start-load-trail.sh | 0.184s ⚠️ 가장 느림 (PERF-1 적용 후) | 1회 |
| session-start-rules.sh | 0.154s | 1회 |
| session-start-bootstrap.sh | 0.056s | 1회 |
| user-prompt-submit-rules.sh | 0.102s | 매 turn |
| pre-tool-use-bash-bootstrap-gate.sh | 0.143s | 매 Bash |
| pre-tool-use-bash-rules.sh | 0.061s | 매 Bash |
| pre-bash-guard.sh | 0.003s | 매 Bash |

Phase 1 의 PERF-1 (aggregate 단일 subprocess 통합 = improve_plan #8) 이 session-start-load-trail SessionStart latency 일부 해소했으나, 매 turn / 매 Bash inject body 자체는 그대로. token/attention 효율 + cold-path wall-clock 개선이 필요.

본 Phase 4 는 cc-feature-adoption 14 Scope 와 별개 신규 2 Scope (UPS-1, PERF-3) 로 plan/spec 갱신.

## 완료 기준

### Task 4.1 — Short rule injection (UPS-1)

- [x] `plugins/rein-core/rules/short/answer-only-summary.md` 신축 — **실측 546 B** (≤ 600 B 목표, ≈92% 감소)
- [x] `plugins/rein-core/rules/short/background-jobs-summary.md` 신축 — **실측 515 B** (≤ 600 B 목표, ≈91% 감소)
- [x] `user-prompt-submit-rules.sh` 가 `rule_inject_body short/answer-only-summary` 호출로 변경 (이전: `answer-only-mode`)
- [x] `pre-tool-use-bash-rules.sh` 가 `rule_inject_body short/background-jobs-summary` 호출로 변경 (이전: `background-jobs`)
- [x] **`session-start-rules.sh` 의 기존 4-rule full inject (code-style / security / testing / operating-sequence) 는 미변경** — 이 4개는 SessionStart anchor. **`answer-only-mode` / `background-jobs` 는 SessionStart 에 inject 되지 않고 매 turn / 매 Bash 호출에서만 등장**하므로 short summary 전환만 적용 (R1 mitigation 참조)
- [x] before/after byte 측정 — 실측: 7049 B → 546 B (**92.3% 감소**), 5959 B → 515 B (**91.4% 감소**). 1시간 누적 시나리오 ~332 KB → ~38 KB (89% 감소). DoD ≤ 600 B 목표 (이전 추정 ≤400B 에서 정정 — 한국어 본문 가독성·효력 보존 위해 600B 로 상향, 절대 감소율은 91~92% 로 충분)
- [ ] hook 단위 테스트 통과 (`tests/scripts/test-ups1-short-rule-injection.sh` 신규 — 다음 단계)

### Task 4.2 — background-jobs advisory hook cold-path skip (PERF-3)

> codex 권고 반영: PERF-3 의 범위를 **`pre-tool-use-bash-rules.sh` (background-jobs body inject 전담) 에 한정** + `if` 패턴은 **positive hot-path whitelist** 방식 (cold path enumerate 대신 hot path 만 명시 + 미분류는 hot 으로 fallback). HK-2 (test-commit-gate spawn 조건부화) 와 명확히 분리되는 advisory hook cold-path skip 작업.

- [ ] `plugins/rein-core/hooks/hooks.json` PreToolUse(Bash) 블록의 `pre-tool-use-bash-rules.sh` 엔트리에 `if` 필드 추가
- [ ] **positive hot-path whitelist** — `if: "Bash(<long-running-pattern> *)"` 형식으로 hot path 만 enumerate. 후보: `pytest`, `npm test`, `yarn test`, `pnpm test`, `cargo build`, `docker build`, `playwright`, `make`, `tsc` 등 (background-jobs.md 본문의 "장기 실행 명령" 정의와 일치)
- [ ] **cold path (safe command — `ls`, `pwd`, `git status`, `grep` 등) 에서 `pre-tool-use-bash-rules.sh` 자동 skip** — 미분류는 cold path 로 떨어져 advisory rule 안 inject (사용자 체감 우선)
- [ ] `pre-tool-use-bash-bootstrap-gate.sh` + `pre-bash-safety-guard.sh` 는 미변경 — always-on 유지 (bootstrap check + 정책 차단은 cold/hot 무관 필수)
- [ ] hook 실행 시간 측정 (cold path Bash) — `~0.21s` 합 (3 hook) → **`~0.15s`** (`pre-tool-use-bash-rules.sh` skip 후 bootstrap-gate + safety-guard 만) 확인
- [ ] Claude Code v2.1.85+ 의 `if` 필드 + `Bash(<pattern>)` 패턴 동작 검증 — v1.3.2 의 HK-2 가 이미 13 entry 로 정상 동작 중 (회귀 위험 낮음)
- [ ] **Edit/Write hook 에는 `if` 필드 미적용** — Issue #46103 (Edit/Write 에서 if 필드 무시) 회피
- [ ] HK-2 의 if 필드 적용과 명확히 분리됨을 plan/spec 에 명시 — HK-2 = `pre-bash-test-commit-gate.sh` spawn 조건부화 (policy gate), PERF-3 = `pre-tool-use-bash-rules.sh` advisory inject skip

### 검증 (cycle 통합)

- [ ] codex review PASS (light tier — rule body 축소 + config tweak, 차단 로직 미변경)
- [ ] security review PASS (light tier — user-facing rule body 축소만, secret/auth/차단 무관)
- [ ] 회귀 테스트 통과 (`bash tests/scripts/run-all.sh`)
- [ ] CHANGELOG.md v1.3.3 entry 추가 (user-facing rule body 축소 + hook config tweak)
- [ ] README.md / README.ko.md 버전 히스토리 1~2줄 + CHANGELOG 링크 (`feedback_release_readme_version_entry.md`)
- [ ] dev commit + push
- [ ] main 선별 체크아웃 + tag v1.3.3 + push (`feedback_branch_strategy_order.md` — dev → main 단방향)

## 묶음 release (oneday tag — 사용자 결정)

오늘 (2026-05-20) 작업을 한번에 v1.3.3 patch tag 로 묶음:

| 작업 | user-facing? | 비고 |
|---|---|---|
| 오전: incident cleanup 3건 declined + 파일 삭제 | ❌ internal | trail/incidents 정리, hook 동작 변화 0 |
| Phase 4 Task 4.1 (short rule injection) | ✅ user-facing rule body 축소 | patch 정당화 source |
| Phase 4 Task 4.2 (if-field skip) | ✅ cold-path latency 감소 | patch 정당화 source |

→ versioning.md Rule A patch bump 정당화 (user-facing outcome 변화는 미미, 사용자 워크플로 변화 없음, body 축소 + hook config tweak).

## 비범위

- rule injection 완전 비활성화 (사고 환기 메커니즘 보존 — 2026-04-22 codex hang, 2026-04-29 trail anchoring 회고 근거)
- improve_plan 항목 1 (post-write-* hooks.json 등록) — HK-1 이미 implemented (v1.4.0 예정)
- improve_plan 항목 4 (security tier 분기) — RT-1 이미 implemented
- improve_plan 항목 5 (complexity hints) — RT-2 이미 implemented
- improve_plan 항목 6 (SubagentStop) — HK-3 이미 implemented (PostToolUse(Agent) 형태로)
- improve_plan 항목 7 (PreCompact/PostCompact) — 별 cycle 후보
- improve_plan 항목 8 (aggregate 단일 subprocess) — PERF-1 이미 implemented (v1.3.2 shipped)
- improve_plan 항목 9 (dispatcher 병렬화) — HK-4 deferred (SPIKE-1 go 판정 대기)
- improve_plan 항목 10 (type:agent Stop hook) — DEC-1 보류 결정 문서화 (experimental)
- improve_plan 항목 11/12 (parallelizable + isolation:worktree) — PLN-1, AG-2 (v1.6.0 예정)
- improve_plan 항목 13 (feature-builder 분화) — AG-1 이미 implemented
- improve_plan 항목 14 (자동 리뷰 루프 Ralph) — 별 cycle 후보
- improve_plan 항목 15 (Python subprocess 캐시) — PERF-2 deferred (SPIKE-1 go 판정 대기)
- improve_plan 항목 16 (DoD validator mtime 캐시) — 별 cycle 후보
- improve_plan 항목 17 (PostToolBatch aggregator) — HK-5 deferred (HK-4 land 후)
- rein-performance-plan Phase 5 (State Machine) — 별 cycle 후보
- rein-performance-plan Phase 6 (Release gate 분리) — 별 cycle 후보

## 위험

- **R1**: short summary 가 self-classify anchoring 효력 약화 → trail 단독 trust 같은 회귀 가능성. **사실 정정 (codex Mode B 2026-05-20)**: `session-start-rules.sh` 는 `code-style`/`security`/`testing`/`operating-sequence` **4개만** inject. `answer-only-mode` 와 `background-jobs` 는 **SessionStart 에 inject 되지 않고** 매 user turn (UserPromptSubmit) + 매 Bash 호출 (PreToolUse) 에서만 등장. 즉 본 cycle 의 short summary 전환은 두 rule 의 **유일한 in-session anchor 를 단축**하는 작업. **Mitigation**: (a) `session-start-rules.sh` 의 4-rule full inject 는 미변경 — operating-sequence + 규칙 본문은 세션 시작 시 1회 anchor 보존. (b) `answer-only-mode.md` / `background-jobs.md` 의 원본 rule 본문은 미변경 (user 가 explicit 하게 read 가능 + 추후 본문 복원 가능). (c) 적용 후 첫 몇 세션 관찰 — 단순 질문에 ceremony 재현 또는 codex 계열 호출에서 foreground 룰 위반 발견 시 short summary 본문 늘림 (또는 "변경 감지 시 재주입" 2차 개선으로 escalate — codex Mode B 권고: 1차안에서는 stale-pass 위험 회피).
- **R2**: short summary 의 정확한 문구가 사고 환기에 충분한지 검증 어려움. **Mitigation**: 새 plan Phase 2 의 권고 본문 시작점으로 사용, codex-review 단계에서 문구 적절성 검토.
- **R3**: `if` 필드 환경 변수 (`REIN_RULES_INJECTED` 등 candidate) 가 Claude Code 에서 실제로 평가되는지 미검증. **Mitigation**: Task 4.2 구현 전 사전 simple test (단순 if 분기로 hook 차단 동작 확인). 환경 변수 평가 안 되면 toolName/command pattern 기반 if 로 대체.
- **R4**: Bash hook if 필드 적용이 hot path (test/commit/destructive) 를 잘못 cold path 로 분류하면 차단 게이트 우회 가능성. **Mitigation**: hot path pattern 명시적 enumerate (`git commit`, `pytest`, `npm test`, `cargo build`, `rm -rf`, `git push --force`, etc.) — 미분류면 hot path 로 fallback.
- **R5**: Edit/Write hook 의 `if` 필드 미지원 (Issue #46103) — Task 4.2 적용 범위가 Bash 전용임을 plan/spec/CHANGELOG 에 명시.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:codex-review        # Step 5 필수 게이트
  - rein:writing-plans       # Phase 4 plan section + spec Scope ID 갱신
  - rein:changelog-writer    # v1.3.3 CHANGELOG entry 작성
mcps: []
security_tier: light          # 차단 로직 미변경, secret/auth 무관
complexity: low               # 신축 2 + 편집 3~4 파일, 기존 패턴 확장
model_hint: sonnet            # 아키텍처 결정 없음, Opus 불필요
effort_hint: medium           # rule 본문 단축 문구 + if 필드 평가 메커니즘 검증
rationale:
  - 작업 성격: rule body 단축 + hook config tweak. 신규 hook / 신규 agent / 사용자 명령 변경 없음 → feature-builder (base) 가 적합 (fix/refactor 아님)
  - 파일 패턴: plugins/rein-core/rules/short/*.md (신축 2), plugins/rein-core/hooks/user-prompt-submit-rules.sh + pre-tool-use-bash-rules.sh (편집), plugins/rein-core/hooks/hooks.json (if 필드 추가), docs/plans/2026-05-19-cc-feature-adoption.md (Phase 4 추가), docs/specs/2026-05-19-cc-feature-adoption.md (Scope ID 2개 추가), CHANGELOG.md, scripts/rein.sh VERSION
  - security_tier light 정당화: 차단 로직 (pre-bash-guard, pre-edit-dod-gate) 미변경, secret/auth 무관, hook config tweak 만
  - feature-builder 가 1차 구현 → codex-review 게이트 → security-review (light) → release (CHANGELOG/VERSION/main 머지/tag v1.3.3)
  - writing-plans: Scope ID 2개 신설 + Phase 4 섹션 신축으로 plan/spec 갱신 필요. coverage validator 통과 + spec-review stamp 자동 생성에 활용
  - changelog-writer: 오늘 묶음 release (incident cleanup + Phase 4) entry 작성에 활용 (선택 — manual 작성도 가능)
approved_by_user: true   # 2026-05-20 사용자 승인 — 원안대로 진행 (feature-builder + codex-review + writing-plans + changelog-writer + security_tier:light)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject)
- [x] cc-feature-adoption plan 의 14 Scope 와 중복 없음 확인 (UPS-1, PERF-3 신규 — 본 DoD 의 covers 매트릭스로 plan-coverage validator 통과 가능성 검증 필요)
- [x] dev 브랜치 확인 (origin/dev = f5d3fc4)
- [x] incident gate 해소됨 (--count-pending = 0, 3건 declined + 파일 삭제)
- [x] v1.3.2 shipped 검증 완료 (main HEAD `7795193`, tag annotated, origin/main 일치)
- [x] PERF-1 적용 확인 (`session-start-load-trail.sh:264~273` aggregate 단일 subprocess)
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)
- [ ] plan 갱신 (Scope ID 2개 추가 + Phase 4 섹션) → plan-coverage validator 통과 후 본 DoD covers 매트릭스 활성화

## 다음 단계 (라우팅 승인 후)

1. **plan 갱신**: `docs/plans/2026-05-19-cc-feature-adoption.md`
   - Scope 매트릭스에 UPS-1, PERF-3 행 추가 (상태 planned)
   - Phase 4 섹션 신축 (Task 4.1, 4.2, covers 메타데이터)
   - 릴리즈 표에 v1.3.3 row 추가 (Phase 4 = patch)
2. **spec 갱신**: `docs/specs/2026-05-19-cc-feature-adoption.md`
   - Scope Items 에 UPS-1, PERF-3 정의 추가 (design intent + scope boundary)
3. **Task 4.1 구현**: short rule 2 파일 신축 + 2 hook 수정
4. **Task 4.2 구현**: `hooks.json` if 필드 + 환경 변수 평가 검증
5. **byte/wall-clock 측정** (before/after 비교 — 본 DoD 의 배경 표와 대조)
6. **codex-review** (light tier) + **security-review** (light tier — security_tier light 라 stamp 없이 commit 허용)
7. **CHANGELOG.md v1.3.3 entry** + **VERSION 1.3.2 → 1.3.3** + **README parity**
8. **dev commit + push**
9. **main 선별 체크아웃 + tag v1.3.3 + push** (`feedback_branch_strategy_order.md` — dev → main 단방향)
10. **trail/inbox + trail/index 갱신**
