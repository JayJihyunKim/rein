# Cycle X4.C.2 — journal writer hooks + dispatcher drain 통합

- 날짜: 2026-05-21
- 유형: feat (영역 C wire-up — lib X4.C.1 을 실제 hook chain 에 연결)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md (X4.C.0 PASS Round 5)
- DoD: trail/dod/dod-2026-05-21-cycle-x4-c2-journal-hooks-and-drain.md

## 변경 파일

- `plugins/rein-core/hooks/lib/state-machine.sh` — `drain_state <current_class?>` 함수 추가 (~110 줄). design memo §4.3 9-step canonical ordering + current_class transition (§4.3 step 6). cat→.processing 성공 검증 후 rm (loss-zero). mkdir mutex timing 10ms/10s.
- `plugins/rein-core/hooks/post-edit-state-journal.sh` (신규 ~55줄) — PostToolUse(Edit|Write|MultiEdit). classify_kind: trail-dod 먼저 → trail / spec / plan / source / other. batch append in single lock.
- `plugins/rein-core/hooks/post-bash-state-journal.sh` (신규 ~50줄) — PostToolUse(Bash). **bash-classifier.sh 의존성 0** — 독립 regex 로 commit/test class 결정. exit_code 부재 → vocal NOTICE + skip (R-12).
- `plugins/rein-core/hooks/stop-state-journal.sh` (신규 ~15줄) — Stop hook entry. append "turn-end".
- `plugins/rein-core/hooks/pre-bash-dispatcher.sh` — classifier 직후 drain_state(_SM_CLASS) 호출. 독립 regex 로 class 결정. fail-soft (drain 실패 시 dispatcher exit code 영향 0).
- `plugins/rein-core/hooks/hooks.json` — 3 신규 entry (post-edit-state-journal 은 aggregator 앞, post-bash-state-journal Bash matcher 신규, stop-state-journal Stop 분리 entry).
- `tests/hooks/test-state-machine-integration.sh` (신규, 9 cases). T1~T9 design memo §8.3 a~d + 회귀.
- `tests/hooks/test-post-edit-parallel-entries.sh` — "8 sub-hook + aggregator = 9" → "9 sub-hook + aggregator = 10" 갱신, expected_subhooks 에 post-edit-state-journal 추가.
- `tests/hooks/run-all.sh` — 신규 test 등록.

## Design contract 매핑

- Scope ID 1 (dispatcher-is-sole-state-json-writer) — drain_state 만 write_state 호출. 3 hook 은 append_journal (별 layer).
- Scope ID 2 (post-edit-journal-append-causes-effective-mode-source-edit) — T1 + T5 (drain + class) 매칭.
- Scope ID 3 (dispatcher-drain-applies-commit-success) — T2/T3 매칭.
- Scope ID 4 (state-json-absence-...zero-test-regression) — T6 fail-soft + run-all PASS.
- Scope ID 6 (pending-journal-append-uses-flock-zero-lost-updates) — T4 100x concurrent + 모든 seq distinct.

## 리뷰 흐름

- codex Round 1 NEEDS-FIX (1 HIGH + 3 Medium):
  - HIGH: drain_state 가 current Bash class 미반영
  - Medium: cat 실패 후 rm 으로 loss, relative path classification 누락, Stop hook 분리 안됨
- codex Round 2 NEEDS-FIX (HIGH + Medium):
  - HIGH: `git  commit` repeated whitespace → CLASS_NEEDS_TC=0 → state 미전이 (bash-classifier 의존성 문제)
  - Medium: trail/dod/* 가 trail/* 패턴에 shadowed
- codex Round 3 NEEDS-FIX (HIGH 1):
  - post-bash-state-journal 의 classifier sourcing 잔존 → 부재 시 early exit
- codex Round 4 **PASS** — 모든 잔존 issue 해소
- security-reviewer **PASS** (base level, 0 findings, informational note 1건 non-blocking)
- 두 stamp 모두 갱신

## 테스트 결과

- `bash tests/hooks/test-state-machine-integration.sh`: **9/9 PASS** (T1~T9)
- `bash tests/hooks/test-state-machine.sh`: 6/6 PASS (X4.C.1 baseline 회귀 0)
- `bash tests/hooks/test-bash-dispatcher.sh`: 34/34 PASS
- `bash tests/hooks/test-post-edit-parallel-entries.sh`: PASS (count + subhook list 갱신)
- `bash tests/hooks/run-all.sh`: **ALL SUITES PASSED**

## 외부 동작 변화

- 모든 Bash/Edit/Stop 호출 시 `.rein/state.json` + 3 journal 파일 생성/갱신
- state.json 부재 또는 lib 부재 시 모든 hook 이 legacy path 로 fail-soft (Scope ID 4 회귀 0)
- 실제 hook chain 의 exit code / deny 동작 변화 0 — 모든 state 작업이 fail-soft

## 잔존 / 다음 작업

- X4.C.3: hook fast-path skip (6 policy hooks 가 effective_mode 조회 후 일부 skip)
- X4.C.4: SPIKE 측정 + 영역 B 통합 검토 (Q-1)
- security-reviewer informational note (`exec 9>` truncation) — non-blocking, 향후 lock 파일에 content 가 들어가면 `exec 9<>` 로 전환 후보
- 영역 D (release gate + v1.3.3 main 머지)
