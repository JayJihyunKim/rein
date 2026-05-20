# SPIKE-1 측정 단계 완료 (cc-feature-adoption Phase 2 / Task 2.1)

- 날짜: 2026-05-20
- 유형: research (no bump — production 코드 미변경)
- DoD: trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2 / Task 2.1)
- covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

## 변경 파일

신축:
- `tests/hooks/spike-parallel-exit-probe.sh` (PROBE_ROLE=allow|deny whitelist + path traversal sanitization)
- `tests/hooks/spike-tool-use-id-probe.sh` (PROBE_PHASE=pre|post whitelist + path traversal sanitization)
- `tests/fixtures/spike/.gitignore` (`*.jsonl` raw dump 추적 제외)
- `docs/reports/2026-05-19-cc-feature-spike.md` (측정 설계 + raw dump + HK-4 GO + PERF-2 GO + 환경 caveat)
- `trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md` (이전 cycle 산출)
- `trail/inbox/2026-05-20-cc-feature-spike-1-handover.md` (이전 cycle 산출 — 본 cycle 진입 시 참고)

편집:
- `trail/dod/.codex-reviewed` (본 cycle Round 2 PASS stamp — reviewer=codex, review_round=2, prior_rounds=R1 NEEDS-FIX → R2 PASS)

미편집 (production 미오염):
- `plugins/rein-core/hooks/hooks.json` 측정 중에만 spike entry 4개 임시 추가 후 `git checkout HEAD -- ...` 으로 revert — `git diff --stat` empty 검증

## 요약

새 session 첫 Write 로 trigger 발사 → 3회 trigger 일관성 확인 → fixture 16 record (4 entry × 4 trigger, trigger #4 는 hot-reload 부재 양방향 증거) 확보. 측정 직후 hooks.json revert.

**판정**:
- **HK-4 GO**: 동일 matcher 의 별개 entry 4개 모두 fire + deny entry 의 `exit 2` 가 다른 entry 의 allow 결과를 마스킹하지 않고 surface → OR-propagation 등가. dispatcher 분할 안전.
- **PERF-2 GO**: PreToolUse 와 PostToolUse 가 동일 `tool_use_id` 공유 (3 trigger × 2 phase = 6 record 모두 매칭). subprocess cache key 사용 가능.

**부산 finding**: hooks.json revert 후에도 다음 Write/Edit 가 spike probe 를 fire — 이전 cycle 의 "변경 후 fire 안 됨" + 본 cycle 의 "revert 후 여전히 fire" 가 양방향으로 같은 가설 지지 (Claude Code session boot 시점의 hooks.json snapshot 만 in-memory 유지). report §5 에 강한 가설 + 공식 spec 미확인 단정 보류 caveat 함께 기록.

**별 cycle 등재**: `need-to-confirm.md` 의 PERF-3-VERIFY (PreToolUse:Bash advisory ~28회 inject) — 본 cycle 측정 중 캡처. SPIKE-1 와 무관한 별 cycle 로 후속 검증.

## 리뷰

- codex Round 1: NEEDS-FIX (Medium x2 — PROBE_ROLE path traversal + parallel-execution claim 강함)
- codex Round 2: PASS (whitelist sanitization 적용 + parallel-execution claim 약화 + go 판정 유지)
- security: light tier inline advisory (path traversal close, fixture_dir 고정, secret 노출 없음, production 미변경)

## 다음 단계 (사용자 결정 대기)

1. **Phase 2b 진입 후보** — plan 의 HK-4 / PERF-2 / HK-5 항목을 `pending` → `implemented` 전환 candidate 표기 (별 cycle: `rein:plan-writer` + plan-coverage validator).
2. **Linux/CI 재측정** — `tests/hooks/spike-*.sh` 회귀 재현용 유지 — Phase 2b 구현 직전/후 Ubuntu/CI 환경에서 1 cycle 재실행 권고.
3. **PERF-3-VERIFY 별 cycle** — `need-to-confirm.md` 등재 본문 참고. SPIKE-1 commit 과 분리.
4. **v1.3.3 main 머지 + tag push** (별 cycle — 사용자 결정 대기 상태).

## 라우팅 피드백

- 라우팅 추천 (rein:researcher + codex-review + security_tier:light) — **적합**.
- spike research 성격에 researcher 가 정확. light tier 가 production 미변경 작업의 commit overhead 적정.
- codex-review 단일 스킬로 충분 — plan 갱신 / changelog 없음.

## 연관

- DoD: trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md Phase 2 / Task 2.1
- spec: docs/specs/2026-05-19-cc-feature-adoption.md Scope SPIKE-1 (implemented), HK-4 / PERF-2 / HK-5 (deferred — SPIKE-1 GO 판정 완료, Phase 2b 진입 가능)
- 별 cycle 등재: need-to-confirm.md PERF-3-VERIFY
- 이전 cycle 인계: trail/inbox/2026-05-20-cc-feature-spike-1-handover.md
