# DoD — cc-feature-adoption Phase 2b (HK-4 dispatcher 분할 + PERF-2 cache + HK-5 aggregator)

- 작업 시작일: 2026-05-20
- 유형: refactor (internal — user-facing outcome 동일, hook 분할 / cache / aggregator 도입은 internal 구조 변경). no bump — VERSION 1.3.3 stay (사용자 결정 2026-05-20)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (본 cycle 안에 Phase 2b 섹션 + matrix 갱신 동반)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 2b (Task 2b.1 / 2b.2 / 2b.3 — 본 cycle 에서 plan 에 신설)
covers: [HK-4-post-edit-dispatcher-dependency-free-subhooks-split-into-parallel-hook-entries-conditional-on-spike-1-confirming-exit2-deny-merge, PERF-2-pre-edit-dod-gate-and-dispatcher-share-python-resolver-result-via-tool-use-id-keyed-cache-conditional-on-spike-1-confirming-posttooluse-carries-it, HK-5-posttoolbatch-hook-aggregates-parallel-subhook-result-files-into-single-trail-entry-conditional-on-hk-4-parallelization-landing]

## 배경

SPIKE-1 (cc-feature-adoption Phase 2 / Task 2.1) macOS 측정 cycle 완료 (HK-4 GO + PERF-2 GO). 사용자 결정 (2026-05-20):

- Linux 재측정은 deferred validation 으로 처리 (main 머지 직전 hard gate) — codex-ask hedging 권고 채택
- Phase 2b 3 항목 (HK-4 + PERF-2 + HK-5) 을 한 cycle 에 land
- 본 cycle commit 후 dev push 만 (main 머지 별 cycle)

현재 `post-edit-dispatcher.sh` (159 line) 가 PostToolUse(Edit|Write|MultiEdit) 의 single entry 로 등록되어 8 sub-hook 을 순차 호출:

```
post-edit-hygiene.sh
post-edit-review-gate.sh
post-edit-index-sync-inbox.sh
post-edit-spec-review-gate.sh
post-edit-plan-coverage.sh
post-edit-dod-routing-check.sh
post-edit-design-plan-coverage-rule.sh
post-edit-routing-procedure-rule.sh
```

dispatcher 자체에 aggregator + cache + exit 2 OR-propagation 이 이미 구현되어 있음 — Phase 2b 의 목적은 이 internal 구조를 hooks.json 의 native 병렬 entry 평가로 옮겨 Claude Code 가 직접 평가 + propagation 처리하게 함.

## 완료 기준

### plan 갱신 (Task 2b.0)

- [ ] `docs/plans/2026-05-19-cc-feature-adoption.md` 의 coverage matrix 3 row 상태 전환:
  - HK-4: `deferred` → `implemented` (위치/사유: Phase 2b / Task 2b.1)
  - PERF-2: `deferred` → `implemented` (위치/사유: Phase 2b / Task 2b.2)
  - HK-5: `deferred` → `implemented` (위치/사유: Phase 2b / Task 2b.3)
- [ ] 새 Phase 2b 섹션 추가 (Phase 2 다음, Phase 3 앞):
  - Phase 2b heading + `covers: [HK-4, PERF-2, HK-5]`
  - Task 2b.1 (HK-4) heading + `covers: [HK-4]` + Files / Steps / Verify
  - Task 2b.2 (PERF-2) heading + `covers: [PERF-2]` + Files / Steps / Verify
  - Task 2b.3 (HK-5) heading + `covers: [HK-5]` + Files / Steps / Verify
- [ ] plan line 188 의 "Phase 2b (조건부, 본 plan 범위 밖)" 노트를 SPIKE-1 GO 판정 반영 형태로 갱신 — 또는 신설 Phase 2b 섹션으로 흡수
- [ ] plan coverage validator (`post-edit-plan-coverage.sh`) 자동 실행 통과 — `.coverage-mismatch` 마커 부재

### HK-4 — dispatcher 분할 (Task 2b.1)

- [ ] `plugins/rein-core/hooks/hooks.json` 의 PostToolUse(Edit|Write|MultiEdit) 블록을 single dispatcher entry 에서 **8 sub-hook 별개 entry** 로 확장 (각 entry 가 자체 matcher `Edit|Write|MultiEdit` + hooks[] = 1 sub-hook)
- [ ] `plugins/rein-core/hooks/post-edit-dispatcher.sh` 는 **유지** 결정 vs **제거** 결정:
  - **유지 후보**: cache populator 로 축소 (PERF-2 의 PostToolUse 측 cache 채움) + 다른 sub-hook 보다 먼저 fire 되어 cache 준비
  - **제거 후보**: PERF-2 cache 가 pre-edit-dod-gate 에서만 populate 되고 sub-hook 들은 read 만 하면 dispatcher 불필요
  - 결정은 PERF-2 구현 방향에 의존 — Task 2b.2 의 cache lifecycle 설계 안에서 확정
- [ ] 각 sub-hook (`post-edit-*.sh` 8개) 이 **dispatcher 부재 환경에서 자체 stdin 처리** 가능하도록 갱신:
  - 현재는 dispatcher 가 cache 를 env var 로 export 한 상태에서 sub-hook 이 실행됨 — 분할 후엔 각 sub-hook 이 stdin JSON 을 직접 파싱 또는 PERF-2 cache 를 read
- [ ] `tests/hooks/test-post-edit-dispatcher.sh` 갱신 — dispatcher 가 사라지거나 축소된 형태 검증으로 전환. 신규 또는 갱신: `tests/hooks/test-post-edit-parallel-entries.sh` (8 sub-hook 별개 entry 등록 + exit 2 OR-propagation)
- [ ] `tests/hooks/run-all.sh` 의 dispatcher 참조 갱신

### PERF-2 — Python resolver cache 공유 (Task 2b.2)

- [ ] `plugins/rein-core/hooks/pre-edit-dod-gate.sh` 의 Python resolver 결과 (file_path 추출 + DoD lookup 결과) 를 `${CACHE_DIR}/${tool_use_id}.json` 으로 dump
- [ ] cache 위치 정책 — `${CLAUDE_PROJECT_DIR}/.rein/cache/hook-resolver/` 안에 file 단위 (path traversal 차단 — tool_use_id 는 Anthropic Tool Use ID 형식 `toolu_<base64>` 만 통과시키는 sanitizer)
- [ ] cache lifecycle:
  - PreToolUse 단계에서 write
  - PostToolUse 단계에서 read
  - PostToolUse 처리 완료 후 cleanup (별 hook 또는 PostToolBatch aggregator 가 책임)
  - stale entry 방지를 위해 24h TTL 또는 session 단위 정리
- [ ] 분할된 sub-hook 들이 cache 를 read 해 cold-start (Python resolver 재호출) 회피
- [ ] cache miss fallback — sub-hook 이 자체 resolver 호출 가능 (graceful degradation)
- [ ] `tests/hooks/test-perf-2-resolver-cache.sh` 신축 — cache write/read/cleanup 검증 + cache miss fallback 검증

### HK-5 — PostToolBatch aggregator (Task 2b.3)

- [ ] 새 hook `plugins/rein-core/hooks/post-edit-aggregator.sh` 신축 — 분할된 sub-hook 들이 emit 한 결과 파일 (trail entry, additionalContext 등) 을 합쳐 단일 trail entry 로 출력
- [ ] hooks.json 에 aggregator 등록:
  - 첫 후보: PostToolBatch event (만약 Claude Code 가 제공) — 단정 불가, SPIKE-1 범위 밖
  - 두 번째 후보: PostToolUse(Edit|Write|MultiEdit) 의 **마지막 entry** 로 등록되어 다른 sub-hook 8개가 fire 한 뒤 마지막에 합쳐 단일 trail entry emit
- [ ] aggregator 의 결과 파일 위치 — `${CLAUDE_PROJECT_DIR}/.rein/cache/hook-output/<tool_use_id>/<sub-hook>.json` 형태로 sub-hook 들이 write
- [ ] PERF-2 cache cleanup 도 aggregator 가 동반 (cache + output 동일 lifecycle)
- [ ] `tests/hooks/test-post-edit-aggregator.sh` 신축 — sub-hook 8개의 output 을 단일 trail entry 로 집계하는지 검증

### 회귀 / verification

- [ ] `bash tests/hooks/run-all.sh` 전체 통과 — dispatcher 분할 후에도 기존 시나리오 회귀 없음
- [ ] post-edit-dispatcher 관련 기존 테스트 (`tests/hooks/test-post-edit-dispatcher.sh`) 가 새 구조에 맞게 갱신되어 모두 통과
- [ ] PreToolUse Edit/Write/MultiEdit 실제 trigger 후 (e.g. 본 cycle 의 trail/dod 파일 신축) trail entry 가 단일 entry 로 기록 (HK-5 aggregator 정상 동작) — manual smoke test
- [ ] dispatcher 단일 entry 대비 분할 후 8 sub-hook 모두 fire 되는지 (`echo "hooks.PostToolUse" + grep post-edit-*` 로 hooks.json 검증)

### 검증

- [ ] codex review PASS (initial round NEEDS-FIX 가능성 큼 — large diff, 다중 파일. multi-round 예상)
- [ ] security review PASS (`standard` tier — production hook 변경, cache 가 tool_use_id 입력 받아 path 구성 → sanitizer 필수)
- [ ] commit (no bump): `refactor(hooks): Phase 2b — HK-4 dispatcher 분할 + PERF-2 cache + HK-5 aggregator`
- [ ] dev push (main 머지 없음 — no bump 작업, main 머지는 별 cycle 의 PR checklist hard gate 통과 후)

### 비고: main 머지 hard gate (별 cycle)

본 cycle 의 commit 이 dev push 된 후 별 cycle 에서 main 머지를 준비할 때 codex-ask hedging 권고에 따라 다음을 hard gate 로 만족:

- (a) Ubuntu/Linux 환경에서 SPIKE-1 절차 1 cycle 재실행 (handover `2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md` 재사용), 또는
- (b) `tests.yml` (또는 별 workflow) 에 dispatcher split / cache / aggregator 의 OS-neutral unit/integration test 추가

본 DoD 의 acceptance 는 **dev push 까지** — main 머지 hard gate 는 본 cycle 범위 밖.

## 비범위

- Linux 환경 실측 (Phase 2b 본 cycle 의 acceptance 밖 — main 머지 hard gate 의 별 cycle)
- v1.4.0 minor bump 또는 v1.3.3 → v1.3.4 patch bump (사용자 결정 1.3.3 stay 유지)
- Phase 3 진입 (DEC-1 / PLN-1 / AG-2 — 별 cycle)
- PERF-3-VERIFY (need-to-confirm.md 등재 — 별 cycle)
- v1.3.3 main 머지 + tag push (별 cycle)
- spec 본문 갱신 — Scope ID 자체는 conditional 표현 포함이므로 SPIKE-1 GO 결과 반영에 spec 본문 편집 불필요

## 위험

- **R1**: dispatcher 분할 후 sub-hook 의 stdin 처리가 dispatcher 가 export 한 cache env var 부재로 break. **Mitigation**: sub-hook 들이 stdin JSON 직접 파싱 fallback 보유 (PERF-2 cache 가 missing 한 환경에서도 작동). 회귀 테스트가 fallback 경로 cover.
- **R2**: HK-4 분할로 8 sub-hook 이 별개 process spawn → Python resolver cold-start 8회 (현재 dispatcher 가 1회만 호출). PERF-2 cache 없이 분할만 land 하면 latency 가 오히려 증가. **Mitigation**: PERF-2 cache 가 본 cycle 에서 동반 — sub-hook 들이 pre-edit-dod-gate 의 cache 를 read 해 cold-start 회피.
- **R3**: cache file path 가 `${tool_use_id}.json` 형태인데 tool_use_id 가 사용자 입력에서 유래 → path traversal 가능성. **Mitigation**: PERF-2 의 cache write/read 에 tool_use_id sanitizer (정확한 형식 `^toolu_[A-Za-z0-9_-]+$` whitelist) 적용. codex review 의 Code Defects slot 이 검증.
- **R4**: HK-5 aggregator 가 PostToolUse 마지막 entry 로 등록되는 경우, Claude Code 가 entry 순서를 보장하는지 미확인 (SPIKE-1 caveat 4 — entry 순서 민감도 미측정). **Mitigation**: aggregator 가 sub-hook 결과 파일 부재 시 graceful skip — sub-hook 들이 cache write 완료 안 한 상태에서도 aggregator 가 exception 던지지 않음.
- **R5**: 8 sub-hook 별개 entry 등록으로 hooks.json 이 길어짐 (현재 +~80 line 예상) → hooks.json 가독성 저하. **Mitigation**: docs/agents-md-examples.md 또는 plugins/rein-core/README 에 dispatcher 분할 의도 + entry 순서 의미 한 단락 명시. 또는 hooks.json 안에 comment block 추가 (JSON 미지원 — `"_comment"` field 로 대체).
- **R6**: codex review round 가 많아질 가능성 (large diff). **Mitigation**: implement 단계에서 작게 commit 단위로 staged review — 4 sub-step (plan / HK-4 / PERF-2 / HK-5) 마다 self-review 보존하면서 진행, 최종 codex-review 한번에 묶음.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - rein:plan-writer          # Task 2b.0 plan 갱신 (matrix + Phase 2b 섹션 + Task work units)
  - rein:codex-review          # Step 5 필수 게이트 — large refactor 다중 파일
mcps: []
security_tier: standard       # production hook 변경 + cache 도입 (tool_use_id 입력 받음 → sanitizer 필수). light 부적절
complexity: high              # 8 sub-hook 분할 + cache 신축 + aggregator 신축 + plan 갱신 + 다중 테스트
model_hint: sonnet            # 복잡한 refactor — opus 도 가능하지만 sonnet 으로 시작
effort_hint: large            # 4 task (plan / HK-4 / PERF-2 / HK-5) × 다중 파일
rationale:
  - 작업 성격: large refactor — 기존 dispatcher 내부 구조를 hooks.json native 평가로 옮김 + cache 신축 + aggregator 신축. feature-builder-refactor 가 정확 (researcher-first 전략 — 기존 dispatcher / pre-edit-dod-gate / sub-hook 구조 파악 우선)
  - 파일 패턴: plugins/rein-core/hooks/hooks.json + post-edit-dispatcher.sh (제거 또는 축소) + post-edit-*.sh 8개 + pre-edit-dod-gate.sh + post-edit-aggregator.sh (신축) + lib/* 갱신 가능성 + tests/hooks/test-*.sh 다중 신축/갱신 + plan 갱신 (markdown)
  - security_tier standard 정당화: cache file path 가 tool_use_id 받음 → path traversal 위험. production 차단 로직 (post-edit-spec-review-gate, post-edit-plan-coverage 등) 의 평가 흐름이 dispatcher → native entry 로 변경 → 회귀 가능성. light 면 stamp 면제로 가다 회귀 놓칠 위험
  - plan-writer 동반: plan 의 coverage matrix 갱신 + Phase 2b 섹션 신설을 plan-writer 가 처리. plan-writer 가 자동으로 plan codex-review 호출
  - codex-review: 본 작업은 large diff 라 codex Round 다중 가능성 — initial NEEDS-FIX → fix → resume --last 패턴
  - changelog-writer 미포함 이유: internal refactor (versioning.md Rule C) — user-facing outcome 동일이라 CHANGELOG.md 신규 entry 불필요. internal log 가 필요하면 CHANGELOG-internal.md 별 cycle
approved_by_user: true   # 2026-05-20 사용자 승인 (원안: rein:feature-builder-refactor + plan-writer + codex-review + standard tier)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject — SPIKE-1 + Linux 재측정 prep cycle 완료 반영)
- [x] SPIKE-1 GO 판정 확인 (HK-4 GO + PERF-2 GO + 양방향 hot-reload 부재 evidence)
- [x] 사용자 결정 (2026-05-20) 기록: hedging 채택 + Phase 2b 한 cycle land + VERSION 1.3.3 stay
- [x] dispatcher 현재 구조 분석 (159 line, 8 sub-hook 순차 호출 + aggregator + cache + exit 2 OR-propagation 이미 구현)
- [x] sub-hook 8개 본문 확인 — 모두 dispatcher 의 cache env var 의존
- [x] plan 의 HK-4/PERF-2/HK-5 coverage matrix 위치 확인 (line 44-46)
- [x] active DoD 갱신 — 본 DoD 가 새 active (이전 dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md 는 cycle 완료)
- [x] spec-review pending 2건 (cc-feature-adoption.md spec + plan) 은 paired .reviewed 도 존재 — gate 통과
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 다음 단계 (라우팅 승인 후)

1. plan 갱신 (Task 2b.0) — `rein:plan-writer` skill 또는 직접 편집 + validator. matrix 3 row + Phase 2b 섹션 신설
2. HK-4 구현 (Task 2b.1) — dispatcher 분할 결정 (제거 vs 축소) + hooks.json 8 entry 확장 + sub-hook 8개의 stdin fallback 보강
3. PERF-2 구현 (Task 2b.2) — pre-edit-dod-gate cache dump + cache lifecycle (PreToolUse write / PostToolUse read / aggregator cleanup) + tool_use_id sanitizer
4. HK-5 구현 (Task 2b.3) — post-edit-aggregator.sh 신축 + hooks.json 마지막 entry 등록 + cache + output cleanup
5. 회귀 테스트 — `bash tests/hooks/run-all.sh` 전수 통과 + 신규 test 4종 (test-post-edit-parallel-entries / test-perf-2-resolver-cache / test-post-edit-aggregator / test-post-edit-dispatcher 갱신) 통과
6. codex-review (standard tier, multi-round 예상) — wrapper + resume --last 패턴
7. security-review (`standard` tier) — cache path sanitizer + production hook 평가 흐름 회귀
8. fix → final codex review PASS → `.codex-reviewed` + `.security-reviewed` stamp
9. commit (no bump): `refactor(hooks): Phase 2b — HK-4 dispatcher 분할 + PERF-2 cache + HK-5 aggregator`
10. dev push (main 머지 없음 — main 머지는 별 cycle 의 hard gate)
11. trail/inbox 작성 + trail/index 갱신 (진입점을 "v1.3.3 main 머지 hard gate 진행" 또는 "PERF-3-VERIFY 별 cycle" 로 갱신)
