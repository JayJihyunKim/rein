# Phase 2c — HK-5 본격 (post-edit-aggregator stdout envelope merge + 2개 sub-hook output cache write)

- 날짜: 2026-05-20
- 유형: refactor (no user-facing outcome 변화 — internal advisory surfacing 구조 변경)
- DoD: `trail/dod/dod-2026-05-20-cc-feature-phase-2c-aggregator-merge.md`
- plan ref: `docs/plans/2026-05-19-cc-feature-adoption.md` (Phase 2c 섹션 신축)
- design ref: `docs/specs/2026-05-19-cc-feature-adoption.md` (Scope Items history amendment)

## 변경 파일

**신규**:
- `plugins/rein-core/hooks/lib/hook-output-cache.sh` — output_cache_dir/write/collect/cleanup + sanitizer (hook_name whitelist, tool_use_id 는 hook-resolver-cache.sh 의 sanitizer 재사용). `find -print0 | LC_ALL=C sort -z` + NUL-read 패턴 (codex R1 회귀 방지)
- `plugins/rein-core/hooks/lib/aggregate-envelopes.py` — stdin NUL-delimited envelope JSON 파싱 + additionalContext concat + 단일 envelope re-emit (compact JSON)
- `tests/hooks/test-post-edit-aggregator-merge.sh` — 33 assertion (lib contract + aggregator merge + 공백 path regression + sanitizer + scope-honest)

**수정**:
- `plugins/rein-core/hooks/post-edit-aggregator.sh` — Phase 2b cleanup-only → Phase 2c merge + cleanup
- `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh` — stdout printf → output_cache_write (+ stdout fallback)
- `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh` — 동일 패턴
- `tests/hooks/run-all.sh` — 신규 test 등록
- `docs/specs/2026-05-19-cc-feature-adoption.md` — Phase 2c amendment note (PostToolBatch → PostToolUse 마지막 entry + single trail entry → single PostToolUse envelope 채택)
- `docs/plans/2026-05-19-cc-feature-adoption.md` — Phase 2c 섹션 + Task 2c.1 + matrix HK-5 행 갱신 + Task 2b.3 "8개" 표현 정정

## 핵심 결과

- 본 cycle 의 정직성 정정 (R1→R2→R3 회): plan task 2b.3 의 "sub-hook 8개" 표현은 실제로 **2개 production envelope-emitting sub-hook 한정** + 6개 non-envelope sub-hook (5 stderr-only + 1 file-system write). 전수 grep 으로 검증.
- SPIKE-1 측정 결과 (entry 별 envelope 별도 surface) 가 design 근거로 정착. PostToolBatch / single trail entry → PostToolUse 마지막 entry / 단일 PostToolUse envelope 으로 spec amendment.
- file-system 매개 cache (`.rein/cache/hook-output/${tool_use_id}/${hook_name}.json`) 로 aggregator 가 다른 entry 의 envelope 을 합쳐 단일 PostToolUse envelope emit. cache hit/miss fallback contract 보존.

## 리뷰

- `/codex-review` Round 1~4: NEEDS-FIX → NEEDS-FIX → NEEDS-FIX → **PASS** (FINAL_VERDICT: PASS). 각 round 의 fix:
  - R1: hook-output-cache.sh 공백 path High + aggregator/test 의 "3개" stale + test:73 dead block + design amendment
  - R2: aggregator:63 stale "3개" 표현 잔존 (R1 first docstring 만 정정)
  - R3: DoD/test 의 stale "5개 stderr-only" → "6개 non-envelope" (loop 은 이미 6개 검사 중, comment 만 stale)
  - R4: PASS
- `security-reviewer` (rein:security-reviewer agent): tier=standard, 9/9 PASS + 2 advisory (race/cleanup ordering, cache leak GC — 모두 별 cycle 후속). adversarial path traversal smoke 9 케이스 모두 reject 확인.

## 회귀

- 본 cycle 신규 test (test-post-edit-aggregator-merge.sh): 33/33 PASS
- HK-4 dispatcher deprecation: 4/4 PASS
- HK-4 parallel-entries: 12/12 PASS
- HK-5 aggregator (Phase 2b cleanup-only): 5/5 PASS (변경에도 깨지지 않음)
- PERF-2 resolver-cache: 10/10 PASS
- UPS-1 영역 3 회귀 (test-user-prompt-submit-rules / -bootstrap-advisory / test-pre-tool-use-bash-rules): **본 cycle 무관** — Phase 4 v1.3.3 prep 잔존 (별 cycle, trail/index.md 의 별 cycle 후보 (a) 와 동일).

## 비목표 (별 cycle 후보)

- post-edit-dispatcher.sh deprecated body 제거 (longer verification 누적 후)
- 6개 non-envelope sub-hook 의 stderr → cache merge (현 대비 분리 surface 유지)
- Linux 환경 race / cache-hit 실측 (OS-neutral CI test)
- PERF-2 cache GC (SessionEnd / cron 기반 stale entry 정리)
- UPS-1 영역 3 회귀 fix (Phase 4 v1.3.3 prep)

## 다음 세션 진입점

- (a) Phase 2b commit (`30f4d75`) + Phase 2c commit 묶음 push (사용자 결정 2026-05-20)
- (b) v1.3.3 main 머지 + tag push (codex-ask hedging gate — Linux 실측 또는 OS-neutral CI test)
- (c) UPS-1 회귀 fix
- (d) PERF-2 cache GC
