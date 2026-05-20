# Phase 2b 구현 — HK-4 + PERF-2 + HK-5 (partial)

- 날짜: 2026-05-20
- 유형: refactor — internal hook 구조 변경 (no bump, VERSION 1.3.3 stay 사용자 결정)
- DoD: trail/dod/dod-2026-05-20-cc-feature-phase-2b-dispatcher-split-and-cache.md
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2b 섹션 신설)
- covers: [HK-4, PERF-2, HK-5]

## 변경 파일

신축:
- `plugins/rein-core/hooks/lib/hook-resolver-cache.sh` — PERF-2 cache lib (sanitizer/write/read/cleanup)
- `plugins/rein-core/hooks/lib/post-edit-policy-gate.sh` — sub-hook 공통 policy gate helper
- `plugins/rein-core/hooks/post-edit-aggregator.sh` — HK-5 partial (cache cleanup 중심)
- `tests/hooks/test-perf-2-resolver-cache.sh` (10 PASS)
- `tests/hooks/test-post-edit-parallel-entries.sh` (12 PASS)
- `tests/hooks/test-post-edit-aggregator.sh` (5 PASS)
- `tests/hooks/test-post-edit-dispatcher-deprecated.sh` (4 PASS)
- `trail/dod/dod-2026-05-20-cc-feature-phase-2b-dispatcher-split-and-cache.md`

수정:
- `docs/plans/2026-05-19-cc-feature-adoption.md` — matrix HK-4/PERF-2/HK-5 `deferred` → `implemented` (HK-5 partial 명시) + Phase 2b 섹션 신설 + Task 2b.0/2b.1/2b.2/2b.3 work units
- `plugins/rein-core/hooks/hooks.json` — PostToolUse(Edit|Write|MultiEdit) single dispatcher entry → **9 entry** (8 sub-hook 별개 entry + aggregator 마지막)
- `plugins/rein-core/hooks/post-edit-dispatcher.sh` — deprecation 헤더 + early exit 0
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` — PreToolUse 단계에서 PERF-2 cache write (leak advisory docstring 동반)
- `plugins/rein-core/hooks/lib/hook-input-cache.sh` — hook_input_load 에 resolver-cache lookup 통합 (cache miss 시 sub-hook 자체 resolver fallback)
- sub-hook 8개 — head 에 `post_edit_policy_gate "<hook-name>"` 호출 추가 (dispatcher 가 처리하던 정책 평가 분산)
- `tests/hooks/test-post-edit-dispatcher.sh` — SKIPPED 처리 (dispatcher deprecated)
- `tests/hooks/run-all.sh` — 4 신규 test 등록
- `trail/dod/.codex-reviewed` + `trail/dod/.security-reviewed` (본 cycle stamp)

## 요약

**HK-4 (MATCH)**: dispatcher 단일 entry → 8 sub-hook 별개 entry. Claude Code 의 native entry-level OR-propagation (SPIKE-1 GO) 가 dispatcher 의 aggregator 로직 대체. dispatcher 자체는 deprecate (rollback 용 본문 보존).

**PERF-2 (PARTIAL, accepted)**: resolver-cache lib 신축 — file_path cache + tool_use_id sanitizer (whitelist `^toolu_[A-Za-z0-9_-]+$`). pre-edit-dod-gate write → sub-hook hook_input_load read fallback. DoD lookup 결과 자체는 cache 안 함 (file_path 만). cache leak / race 가능성은 advisory docstring 명시 — 별 cycle GC 후속.

**HK-5 (PARTIAL, user-approved)**: aggregator hook 신축 + hooks.json 마지막 entry 등록 + cache cleanup. **sub-hook stdout merge / 단일 trail entry 통합은 본 cycle 미구현** — Claude Code 의 entry-level stdout 평가 모델 공식 spec 미확인. 별 cycle (Phase 2c 후보) 후속. plan matrix 의 위치/사유에 "partial" 명시 + Task 2b.3 본문의 Implementation 한계 단락 + aggregator docstring 에 모두 정직 명시.

## 리뷰

- codex Round 1: NEEDS-FIX (HIGH x2 HK-5 align + aggregator race; MEDIUM x2 cache leak + run-all.sh 미등록)
- codex Round 2: NEEDS-FIX (잔여 1건 — plan Task 2b.3 의 stale acceptance bullets)
- codex Round 3: **PASS** (HK-4 MATCH + PERF-2 PARTIAL accepted + HK-5 user-approved PARTIAL)
- security: inline advisory (standard tier — path traversal sanitizer 5 case 검증, secret/network 없음, cache leak advisory)

## 회귀 테스트

`bash tests/hooks/run-all.sh` — 본 cycle 변경에 의한 fail 0. UPS-1 영역 회귀 3건 (test-user-prompt-submit-rules / test-user-prompt-submit-bootstrap-advisory / test-pre-tool-use-bash-rules — "행동 강령" body marker 누락) 은 본 cycle 무관, 별 cycle 후속 (v1.3.3 prep Phase 4 회귀 가능성).

신규 4 test 모두 PASS (31 PASS / 0 FAIL).

## 다음 단계 (사용자 결정 대기)

본 cycle commit 까지 완료 (push 는 사용자 결정으로 다음 turn). 후속 후보:

1. **dev push** — `git push origin dev`. main 머지 hard gate 는 별 cycle (codex-ask hedging 권고: Ubuntu/Linux 실측 또는 OS-neutral CI test 추가)
2. **Phase 2c 후보** — HK-5 본격 implementation (sub-hook output cache write + aggregator merge + 단일 trail entry 통합). Claude Code v2.x entry stdout 평가 spec 조사 우선
3. **UPS-1 회귀 fix 별 cycle** — test-user-prompt-submit-rules / test-pre-tool-use-bash-rules / test-user-prompt-submit-bootstrap-advisory 의 "행동 강령" body marker 회귀
4. **PERF-2 GC 별 cycle** — cache leak (denied PreToolUse) 의 SessionEnd / cron 기반 GC 도입
5. **v1.3.3 main 머지 + tag push** (별 cycle)

## 연관

- DoD: trail/dod/dod-2026-05-20-cc-feature-phase-2b-dispatcher-split-and-cache.md
- plan: docs/plans/2026-05-19-cc-feature-adoption.md Phase 2b
- spec: docs/specs/2026-05-19-cc-feature-adoption.md Scope HK-4/PERF-2/HK-5
- SPIKE-1 evidence: docs/reports/2026-05-19-cc-feature-spike.md
- codex-ask hedging 권고 (2026-05-20): main 머지 hard gate 별 cycle
- 이전 cycle inbox: trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md (Linux 재측정 prep)
