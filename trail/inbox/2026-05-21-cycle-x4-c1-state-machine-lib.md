# Cycle X4.C.1 — state machine lib + journal helper + tests

- 날짜: 2026-05-21
- 유형: feat (영역 C 의 1차 implementation cycle — 신규 lib + 신규 test)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md (X4.C.0 PASS Round 5, stamp `9faa41da2b6fc4b1.reviewed`)
- DoD: trail/dod/dod-2026-05-21-cycle-x4-c1-state-machine-lib.md

## 변경 파일

- `plugins/rein-core/hooks/lib/state-machine.sh` (신규 ~280 줄) — `read_state` / `write_state` / `append_journal` / `read_effective_mode` / `acquire_state_lock` / `release_state_lock` / `_state_machine_next_seq` 함수. `.rein/state.lock` 기반 unified lock (flock + mkdir fallback). atomic rename + schema fallback + vocal NOTICE.
- `tests/hooks/test-state-machine.sh` (신규 ~210 줄) — 6 case:
  - T1 state 부재 → default + state.json 미생성
  - T2 malformed JSON → stderr NOTICE + default
  - T3 **100x** concurrent write_state → fail 0 + .tmp 잔존 0 + valid final JSON
  - T4 **100x** concurrent append_journal → entry count 100 + 모든 seq distinct
  - T5 state.mode=answer + edit entry → effective_mode=source_edit
  - T6 **stop(seq=1) + edit(seq=2) → source_edit** (codex Round 1 HIGH seq-order 회귀)
- `tests/hooks/run-all.sh` — 신규 test 등록

## Design contract 매핑

- design memo Scope ID 1 (dispatcher-is-sole-state-json-writer) — `write_state` atomic rename (X4.C.2 cycle 에서 dispatcher 등록)
- design memo Scope ID 2 (post-edit-journal-append-causes-effective-mode-source-edit) — `append_journal` + `read_effective_mode` (T5)
- design memo Scope ID 5 (state-json-malformed-...-stderr-notice) — `read_state` schema fallback (T2)
- design memo Scope ID 6 (pending-journal-append-uses-flock-...-zero-lost-updates) — `append_journal` + unified lock (T4 100회)
- codex Round 5 seq formula 그대로 — `_state_machine_next_seq` = max(state.last_drain_seq, active max, .processing max) + 1

## 리뷰 흐름

- codex Round 1 **NEEDS-FIX** (2 HIGH + 2 Medium):
  - HIGH: read_effective_mode fixed-file-order → design §3.3 sorted_by_seq 위반
  - HIGH: write_state $$ 충돌 (bash subshell parent pid 공유)
  - Medium: T3 per-PID exit status 미캡처
  - Medium: T3/T4 50회 < design 100회 target
- Fix Round 1 → Round 2 **PASS**:
  - awk sort -k1,1n 으로 strict seq 정렬
  - mktemp XXXXXX 패턴으로 tmp collision 차단
  - per-PID fail_log + 100회 강화
  - T6 회귀 test 추가 (stop+edit ordering)
- security-reviewer **PASS** (intermediate, profile.yaml standard)
- 두 stamp 모두 갱신

## 테스트 결과

- `bash tests/hooks/test-state-machine.sh`: **6/6 PASS**
- `bash tests/hooks/run-all.sh`: **ALL SUITES PASSED** (회귀 0)

## 외부 동작 변화

- **본 cycle 의 외부 변화 = 0**. 신규 lib 는 어떤 hook 에도 아직 source 되지 않음. dispatcher 가 lib 를 활용하는 것은 X4.C.2 cycle 에서 (3 신규 journal writer hook + dispatcher drain 등록 동반). 본 cycle 은 lib + test 만 추가 — legacy path 그대로 유지.

## 잔존 / 다음 작업

- X4.C.2: 3 신규 journal writer hook (post-edit-state-journal / post-bash-state-journal / stop-state-journal) + dispatcher drain 통합 + hooks.json 등록 + adversarial test (a~d 시나리오)
- X4.C.3: hook fast-path skip (post-edit policy hooks 6개)
- X4.C.4: SPIKE 측정 + 영역 B 와 통합 검토 (Q-1)
- 잔존 영역 D (release gate + v1.3.3 main 머지)
