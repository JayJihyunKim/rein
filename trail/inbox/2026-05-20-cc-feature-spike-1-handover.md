# SPIKE-1 (cc-feature-adoption Phase 2 / Task 2.1) — 측정 단계 새 session 인계

- 날짜: 2026-05-20
- 유형: research (handover, no commit)
- DoD: trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2 / Task 2.1)
- covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

## 요약

cc-feature-adoption Phase 2 SPIKE-1 (병렬 hook exit/deny 병합 + PostToolUse tool_use_id 측정) 진입. DoD + 라우팅 (rein:researcher + codex-review + security_tier:light) 승인 후 probe 2종 작성. hooks.json 에 임시 등록하고 Edit 트리거를 발사했으나 probe 가 fire 되지 않음 — **동일 session 안에서 hooks.json 갱신이 picks up 되지 않는 정황**. 사용자 결정으로 측정 단계는 **새 session 으로 인계**. 부산물로 발견한 "PreToolUse(Bash) 매 호출 ~26회 반복 inject" finding 은 PERF-3-VERIFY 로 `need-to-confirm.md` 등재 (별 cycle).

## 변경 파일

- 신축: `tests/hooks/spike-parallel-exit-probe.sh` (PROBE_ROLE=allow|deny 로 exit2/deny 병합 의미 측정)
- 신축: `tests/hooks/spike-tool-use-id-probe.sh` (PROBE_PHASE=pre|post 로 tool_use_id 필드 dump)
- 신축: `tests/fixtures/spike/.gitignore` (`*.jsonl` 환경별 raw dump 추적 제외)
- 신축: `trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md` (DoD)
- 편집 (**uncommitted**, 새 session 측정용): `plugins/rein-core/hooks/hooks.json` — PreToolUse(Edit|Write|MultiEdit) 에 `spike-tool-use-id-probe` (phase=pre) 별개 entry 1 + PostToolUse(Edit|Write|MultiEdit) 에 phase=post + role=allow + role=deny 별개 entry 3, 총 4 entry 추가
- 편집: `need-to-confirm.md` — PERF-3-VERIFY 항목 추가 + 표/변경 이력 갱신

## 진단 (in-session 측정 실패 원인)

1. ✅ probe 자체는 정상 — sh -c 로 직접 호출 시 `tests/fixtures/spike/tool-use-id-pre.jsonl` 정상 작성됨 (이후 dry-run fixture 정리됨)
2. ✅ inline env (`PROBE_PHASE=pre ${path}`) 도 sh 에서 정상 작동
3. ⚠️ Bash tool 환경에서 `CLAUDE_PROJECT_DIR` / `CLAUDE_PLUGIN_ROOT` 둘 다 unset — hook command context 의 evaluate 여부는 별 (단정 불가)
4. ⚠️ **동일 session 내 hooks.json 변경이 picks up 안 됨** (가장 유력) — Edit/Write trigger 가 probe 를 fire 시키지 않음

## 부산 finding (별 cycle 등재 완료)

`need-to-confirm.md` 의 **PERF-3-VERIFY** 항목:

- v1.3.3 prep 의 Phase 4 PERF-3 (cold-path Bash hook skip) 적용 후에도 cold-path 명령 (`echo`, `ls`) 에서 매 Bash 호출마다 `# Background jobs quick rule` 컨텍스트가 ~26회 반복 inject. PERF-3 의 outcome (cold-path 에서 advisory hook skip → token / TTFT 절감) 미달성 가능성.
- hooks.json revert 직후 첫 Bash 부터 inject 횟수가 1 → 26 으로 폭발. revert 가 Claude Code 의 hook config reload trigger 였던 것으로 해석.
- 단정 불가: Claude Code v2.1.144 의 `if` 필드 평가 spec / reload trigger 정확한 조건.

## 새 session 에서 할 일 (인계)

1. **새 Claude Code session 열기** — 그 session 이 시작 시점의 hooks.json (= spike entry 4개 포함 상태) 을 로드
2. **Edit 1회 발사** — 임의의 repo 내 파일에 한 줄 추가 (예: `tests/fixtures/spike/spike-trigger.txt` Write). 이 trigger 로 probe 가 fire → `tests/fixtures/spike/*.jsonl` 4 종 (parallel-exit-allow, parallel-exit-deny, tool-use-id-pre, tool-use-id-post) 생성
3. **fixture 분석** — HK-4 go/no-go (exit2/deny 가 OR-propagation 처럼 작동하는가) + PERF-2 go/no-go (PostToolUse 가 `tool_use_id` 또는 등가 id 를 제공하는가 + PreToolUse 와 매칭되는가) 판정
4. **`docs/reports/2026-05-19-cc-feature-spike.md` 신축** — 측정 설계 + raw dump 발췌 + 두 go/no-go 판정 + 측정 환경 caveat (macOS Darwin 25.4 / Claude Code 현 release, Linux/CI 재측정 권고)
5. **`plugins/rein-core/hooks/hooks.json` revert** — `/tmp/hooks.json.spike-backup` 부재 시 다음 spike entry 4개 (`PROBE_PHASE=pre/post`, `PROBE_ROLE=allow/deny`) 수동 제거. 본 session 직전의 `git show HEAD:plugins/rein-core/hooks/hooks.json` 으로 ref 비교 가능 (dev HEAD = ab41077, v1.3.3 prep)
6. **codex-review (light tier)** — `/codex-review` 로 probe 2 + report 1 에 대한 리뷰. `trail/dod/.codex-reviewed` stamp 생성
7. **security-review (light tier)** — `security_tier: light` 라 stamp 없이 commit 가능하나 advisory 호출. probe 의 secret/path-traversal 없음 확인
8. **commit (no bump)** — `chore(spike): Task 2.1 — 병렬 hook exit/deny + tool_use_id 측정 (SPIKE-1)`. 포함: tests/hooks/spike-*.sh (2), docs/reports/2026-05-19-cc-feature-spike.md, tests/fixtures/spike/.gitignore, trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md, trail/inbox/2026-05-20-cc-feature-spike-1-handover.md, need-to-confirm.md, trail/index.md. **hooks.json 은 revert 된 상태로 commit (probe entry 포함 변경 없음)**
9. **dev push** (main 머지 없음 — no bump)
10. **다음 cycle 결정** — 사용자. 후보:
    - SPIKE-1 go 판정 시 Phase 2b plan 갱신 (HK-4/PERF-2/HK-5 implemented 전환)
    - SPIKE-1 no-go 판정 시 Phase 3 (DEC-1/PLN-1/AG-2) 진입
    - PERF-3-VERIFY cycle (별 등재) — PERF-3 cold-path skip outcome 검증
    - v1.3.3 main 머지 + tag push (별 cycle — 사용자 결정 대기 상태)

## 측정 환경 제약

- 본 session 의 in-session hot-reload 가설 (= hooks.json 변경의 동일 session 내 picks up 부재) 이 새 session 에서도 부분적으로 작동할 가능성: **새 session 시작 직후의 Edit 1회는 측정 가능 (시작 시점 hooks.json 로드)**, 그 이후 hooks.json 을 다시 편집해도 picks up 안 될 수 있음. 따라서 **새 session 의 첫 Edit 으로 측정을 끝내고 즉시 hooks.json revert**.
- 동일 session 내 측정 재시도 (예: deny entry 만 추가) 가 필요하면 또 다른 fresh session 으로 분리.

## 연관 항목

- 본 DoD: `trail/dod/dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md`
- plan: `docs/plans/2026-05-19-cc-feature-adoption.md` Phase 2 / Task 2.1
- spec: `docs/specs/2026-05-19-cc-feature-adoption.md` Scope SPIKE-1 (implemented), HK-4/PERF-2/HK-5 (deferred — SPIKE-1 go 판정 대기)
- 별 cycle 등재: `need-to-confirm.md` PERF-3-VERIFY
- memory: `project_cc_feature_adoption.md` (다음 갱신 후보 — SPIKE-1 진입·인계 사실 반영)
