# DoD — Phase 2c: HK-5 본격 구현 (post-edit-aggregator stdout envelope merge)

- 날짜: 2026-05-20
- 유형: refactor (no user-facing outcome 변화 — internal advisory surfacing 구조 변경)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2b §Task 2b.3 의 "별 cycle 후속" 본격 land)
- spec ref: docs/specs/2026-05-19-cc-feature-adoption.md (HK-5 본격 구현)
- 직전 cycle: Phase 2b commit `30f4d75` (HK-4 split + PERF-2 cache + HK-5 cleanup-only). local-only, origin/dev 와 1 commit 분기. 본 cycle 후 묶음 push (사용자 결정 2026-05-20).

## 작업 기준 (Acceptance Criteria)

### A. Claude Code v2.x entry-level stdout 평가 모델 — 측정 근거 채택

- [ ] SPIKE-1 (`docs/reports/2026-05-19-cc-feature-spike.md`) 측정 결과를 본 cycle 의 design 근거로 채택: 동일 matcher 의 별개 entry 가 각자 stdout envelope 을 emit 하면 Claude Code 가 **entry 별 system-reminder 로 분리 surface**. 즉 aggregator 가 다른 entry 의 stdout 을 직접 capture/redirect 할 수 없음 — file-system 매개 cache 가 유일한 통합 경로.
- [ ] 외부 공식 spec 추가 조사: Claude Code docs 의 PostToolUse hook output 평가 모델 단락이 있는지 ToolSearch/WebFetch 로 확인 후 DoD 에 reference 추가 (없으면 SPIKE-1 측정만 근거로 채택).

### B. sub-hook stdout envelope cache write — 2개 sub-hook 한정 (정정)

- [ ] sub-hook 8개 전수 조사 결과 (2026-05-20): 본 cycle 진행 중 정정 — 초기 grep 은 `post-edit-index-sync-inbox.sh:106` 의 `cat <<EOF` 를 envelope 출력으로 오분류했으나 실제 본문은 **TARGET_TMP 파일 write** (`> "$TARGET_TMP"`) 였음. 따라서 stdout 으로 `hookSpecificOutput` envelope 을 emit 하는 hook 은 **2개만** — `post-edit-design-plan-coverage-rule.sh:95` (`printf hookSpecificOutput`), `post-edit-routing-procedure-rule.sh:101` (`printf hookSpecificOutput`). 나머지 6개 (`hygiene`, `review-gate`, `spec-review-gate`, `plan-coverage`, `dod-routing-check`, `index-sync-inbox`) 는 **stderr 출력 또는 file system write 만** — entry-level evaluation 영향 없음 (dispatcher historical 본문도 stderr 는 그대로 통과 명시, `post-edit-dispatcher.sh:32-33`).
- [ ] 본 cycle 의 plan-document drift 정정: plan task 2b.3 표현 "sub-hook 8개 output cache write 도입" → **2개 sub-hook (envelope-emitting only) 한정** 으로 정정 (코드 변경 commit 과 같은 cycle 의 plan.md edit, spec-review pending 마커 → reviewed 처리 동반).
- [x] 신규 helper `plugins/rein-core/hooks/lib/hook-output-cache.sh` — `output_cache_dir(tool_use_id)`, `output_cache_write(tool_use_id, sub_hook_name, content)`, `output_cache_collect(tool_use_id)`, `output_cache_cleanup(tool_use_id)` 함수. 경로: `${CLAUDE_PROJECT_DIR}/.rein/cache/hook-output/${tool_use_id}/${sub_hook_name}.json`. tool_use_id sanitizer 는 `hook-resolver-cache.sh:51` 의 함수 재사용 (path traversal 방어). hook_name 도 sanitize (영문/숫자/하이픈/언더스코어 whitelist).
- [x] 신규 helper `plugins/rein-core/hooks/lib/aggregate-envelopes.py` — stdin NUL-delimited envelope JSON 들을 받아 `additionalContext` 만 추출 → `\n\n---\n\n` separator concat → 단일 PostToolUse envelope JSON (compact, `separators=(",",":")`) 으로 emit.
- [x] 2개 sub-hook 의 stdout envelope 출력 직전에 cache write 시도 → cache hit (tool_use_id 유효 + write 성공) 면 stdout 출력 skip, cache miss/no-id 면 stdout 출력 fallback (현재 동작 보존). `output_cache_write` return code (0=success, 1=fail) 가 fallback 분기 결정.

### C. post-edit-aggregator merge 로직 보강

- [x] aggregator 가 PostToolUse(Edit|Write|MultiEdit) 의 **마지막 entry** (현재 등록 상태 유지) 로서 다음 동작 추가:
  1. `output_cache_collect(tool_use_id)` 로 2개 production sub-hook (+ 향후 추가 시 arbitrary-N) 의 envelope JSON 들을 모두 읽음
  2. 각 envelope 의 `hookSpecificOutput.additionalContext` 만 추출
  3. separator `\n\n---\n\n` 로 concat → 단일 PostToolUse envelope 으로 stdout 출력 (`hookSpecificOutput.additionalContext` = merged text)
  4. 이후 `resolver_cache_cleanup` + `output_cache_cleanup` 둘 다 호출 (cache leak 방지)
- [x] no-id / empty cache / invalid JSON 시: aggregator 는 silent skip (`exit 0`) — 기존 fallback 으로 sub-hook 들이 stdout 으로 직접 emit 한 envelope 이 entry-level 별도 surface 로 노출 (현재 동작과 동등, regression 아님).

### D. 단일 trail entry 통합 검증

- [x] 신규 test `tests/hooks/test-post-edit-aggregator-merge.sh`:
  - 2개 production sub-hook + 1 generic fixture (lib 의 arbitrary-N contract 검증) → aggregator 가 collect 후 단일 envelope emit 검증
  - aggregator 출력의 `additionalContext` 가 3 source 의 텍스트를 separator 로 합친 것 검증 (cache contract test — production topology 는 2개 production sub-hook + 향후 추가 시 자동 포함)
  - cleanup 후 cache dir 부재 검증
  - no-id 시나리오: aggregator silent exit 0 (production sub-hook 들의 stdout 은 미변경 fallback 으로 출력)
  - codex R1 regression: CLAUDE_PROJECT_DIR 공백 path 안전성 (`collect_space_path_body_a/b`, 33 assertion)
- [ ] `tests/hooks/run-all.sh` 전수 PASS (UPS-1 영역 3 회귀는 본 cycle 무관, plan 명시대로 별 cycle)
- [ ] PERF-2 race condition advisory (Phase 2b `.codex-reviewed` remaining_issues) 는 본 cycle 에서 measurement 만: 단일 PostToolUse 호출에서 8 sub-hook entry + aggregator entry 가 모두 fire 됐을 때 aggregator 가 cleanup 을 너무 일찍 호출하지 않는지 — Claude Code 가 entry 순서대로 sync 실행함을 SPIKE-1 측정 캐비어트에서 추론. **본격 race resilience 는 별 cycle (Stop / SessionEnd 기반 cleanup 으로 이동 검토)**.

### E. 정직성 (Honest Reporting)

- [x] 본 cycle 에서 plan task 2b.3 의 "sub-hook 8개" 표현이 실제로는 **2개 production stdout envelope-emitting sub-hook 한정** 이었음을 plan.md 수정 + commit message + inbox 모두에 명시. codex R1 review 가 초기 "3개" 표현의 잔존 (post-edit-index-sync-inbox 가 file-system write 만 한다는 사실 누락) 을 잡아 R2 에서 정정.
- [ ] Linux 환경 race / cache-hit 실측은 본 cycle 미포함 — macOS 측정만, **별 cycle 후보 (OS-neutral CI test)** 로 다시 marker.
- [ ] post-edit-dispatcher.sh 의 deprecated marker 는 본 cycle 에서 **제거하지 않음** (Phase 2b stamp 가 "다음 cycle 에 완전 제거 검토" 라고 했으나 사용자 안전 우선 — 더 longer cycle 의 verification 누적 후 결정).

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - superpowers:test-driven-development
  - superpowers:verification-before-completion
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus-4-7
effort_hint: medium
rationale: |
  Bash hook lib 신축 + 2개 production sub-hook 수정 + aggregator 보강 —
  기존 구조 변경 없이 내부 refactor. 실제 4 src + 1 신규 helper + 1 신규 .py
  + 1 신규 test. TDD red-green 필수 (sub-hook output 의 race-free contract).
  /codex-review 는 cache contract / cleanup ordering / path traversal 재점검.
approved_by_user: true
```

## 변경 파일 (예상)

**신축**:
- `plugins/rein-core/hooks/lib/hook-output-cache.sh`
- `tests/hooks/test-post-edit-aggregator-merge.sh`

**수정**:
- `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh` (envelope cache write + stdout fallback)
- `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh` (envelope cache write + stdout fallback)
- `plugins/rein-core/hooks/post-edit-aggregator.sh` (cache collect + merge + cleanup)
- `tests/hooks/run-all.sh` (신규 test 등록)
- `docs/plans/2026-05-19-cc-feature-adoption.md` (Task 2b.3 "8개" → "2개 stdout envelope 한정" 정정)
- `trail/dod/.spec-reviews/fac428f9d2bde994.reviewed` (plan edit 동반 review stamp)

## 비목표 (Out of Scope)

- 6개 non-envelope sub-hook (hygiene/review-gate/spec-review-gate/plan-coverage/dod-routing-check/index-sync-inbox) 의 stderr 또는 file-system write → cache merge — dispatcher historical 본문 명시 (stderr 는 그대로 통과, index-sync-inbox 는 trail/inbox 파일을 직접 write 하므로 entry-level evaluation 영향 없음)
- post-edit-dispatcher.sh 의 deprecated body 제거
- Linux 환경 race / cache-hit 실측
- UPS-1 영역 3 회귀 fix
- PERF-2 cache GC (SessionEnd / cron stale entry 정리)
- v1.3.3 main 머지 + tag push
- Claude Code v2.x stdout 평가 모델의 공식 spec 이 부재할 경우 PR/feedback 제출
