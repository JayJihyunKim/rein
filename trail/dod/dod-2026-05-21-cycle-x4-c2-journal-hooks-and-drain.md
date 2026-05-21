# DoD — Cycle X4.C.2 (3 journal writer hook + dispatcher drain 통합)

- 날짜: 2026-05-21
- 유형: feat (3 신규 hook + dispatcher 변경 + hooks.json + adversarial test)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md (X4.C.0 PASS Round 5, stamp `9faa41da2b6fc4b1.reviewed`)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.3 (영역 C)
- cycle: X4.C.2 — design memo §8.3 산출물

## 범위 (Scope)

포함:

1. `plugins/rein-core/hooks/post-edit-state-journal.sh` (신규, 신규 PostToolUse Edit|Write|MultiEdit entry):
   - envelope 의 `tool_input.file_path` 추출
   - `kind` 분류 (source / spec / plan / dod / trail / other)
   - `append_journal edits "edit\t<abs-path>\t<kind>"` 호출
   - state-machine.sh 부재 시 silent no-op (legacy fallback)
   - Lib 부재 시 환경 — fail-loud stderr NOTICE

2. `plugins/rein-core/hooks/post-bash-state-journal.sh` (신규, 신규 PostToolUse Bash entry):
   - envelope 의 `tool_input.command` + `tool_response.exit_code` 추출
   - bash-classifier.sh 의 `classify_bash_command` 호출하여 class 결정 (commit / test / safe / dangerous / long-running)
   - `append_journal bash "bash-result\t<exit>\t<class>"`
   - exit_code 부재 envelope → fail-closed stderr NOTICE + skip (design memo §6 R-12)

3. `plugins/rein-core/hooks/stop-state-journal.sh` (신규, 신규 Stop entry):
   - `append_journal stop "turn-end"` 1줄
   - Stop hook 의 다른 책임 (stop-session-gate.sh) 와 독립 — 별 entry

4. `plugins/rein-core/hooks/pre-bash-dispatcher.sh` 변경 (drain 통합):
   - bootstrap gate 직후 + safety guard 앞에 drain 단계 추가 (design memo §4.3 9-step)
   - state-machine.sh source → acquire_state_lock x → state read → journal mv to .processing (+ stale merge) → entries seq 정렬 → 전이 적용 → 본 호출 분류 적용 → state.json write → .processing rm → release_state_lock
   - state-machine.sh 부재 또는 lock 획득 실패 시 legacy path (state 무시, 기존 dispatcher 동작 그대로). 외부 동작 회귀 0
   - drain 실패는 dispatcher exit code 에 영향 안 줌 (fail-soft for state, fail-closed only for downstream gate logic)

5. `plugins/rein-core/hooks/hooks.json` 변경:
   - PostToolUse Edit|Write|MultiEdit 에 `post-edit-state-journal.sh` 추가
   - PostToolUse Bash 추가 (matcher: Bash) — `post-bash-state-journal.sh`
   - Stop 에 `stop-state-journal.sh` 추가 (stop-session-gate.sh 뒤)

6. `tests/hooks/test-state-machine-integration.sh` (신규, 4 adversarial test case — design memo §8.3 검증 a~d):
   - (a) Edit → Bash 시퀀스 → 다음 dispatcher drain 후 state.json.mode == "source_edit"
   - (b) commit class Bash + exit 0 → 다음 drain 후 state.json.mode == "answer" + dirty_files == []
   - (c) commit class Bash + exit != 0 → 다음 drain 후 mode == "source_edit" + dirty_files 보존
   - (d) PostToolUse(Edit) + PostToolUse(Bash) 50x 동시 → journal 합산 entry == 100 (cross-hook race-free)

7. `tests/hooks/run-all.sh` 에 신규 test 등록

제외 (별 cycle):

- X4.C.3: hook fast-path skip (6 policy hooks 가 state 를 read 하고 일부 skip)
- X4.C.4: SPIKE 측정 + 영역 B 통합 검토 (Q-1)

## 작업 기준

1. TDD red-green — test 먼저 작성 → 실패 확인 → 구현 → PASS
2. 본 cycle 의 외부 동작 변화 = state.json + journal 파일 생성만. 기존 hook 의 환경 변화 0 (fail-soft state read 가 legacy path 진입 시)
3. 전 hook test suite 회귀 0 (특히 test-state-machine.sh 의 lib 기능 그대로 + 기존 dispatcher 동작 보존)
4. shellcheck clean (가능 시)
5. codex Mode A code-review PASS — `.codex-reviewed` stamp
6. security-reviewer PASS — `.security-reviewed` stamp
7. inbox + index 갱신 + dev commit (single commit per cycle)

## 검증 시나리오

- (V1) `bash tests/hooks/test-state-machine.sh` (X4.C.1 baseline) 6/6 PASS — lib 회귀 없음
- (V2) `bash tests/hooks/test-state-machine-integration.sh` 4 case PASS
- (V3) `bash tests/hooks/run-all.sh` ALL SUITES PASSED — 본 cycle 의 hook chain 추가가 다른 hook 의 envelope 동작 안 바꿈
- (V4) `bash tests/rein-test.sh` 15/15 PASS — CLI 표면 회귀 0
- (V5) state.json + 3 journal 모두 삭제한 상태에서 hook chain 실행 → 모든 hook 정상 동작 (legacy fallback contract, design memo Scope ID 4)

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
rationale: |
  영역 C 의 wire-up cycle. lib (X4.C.1) 을 실제 hook 에 연결 + dispatcher
  modification. feature-builder 가 신규 hook 3개 + dispatcher 변경을 일관되게
  관리. TDD 로 4 adversarial test 먼저 작성 후 hook 본문 구현. codex Mode A
  로 race-safety + fail-soft contract 리뷰. verification-before-completion 으로
  "lib + 신규 hook + dispatcher 변경 후 ALL SUITES PASSED" 실증 후 완료.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "다음 사이클 진행하자" + 오토모드 명시. dispatcher 본문 변경 +
  Bash exit code 캡처 동반 (security surface) → standard tier 필수.
```

## self-review

- [ ] 3 신규 hook 본문이 design memo §4.2 의 journal entry 형식 (`<seq>\t<iso-ts>\t<payload>`) 와 일치
- [ ] dispatcher drain 이 design memo §4.3 9-step 와 1:1 매칭
- [ ] state-machine.sh source 실패 시 legacy fallback — 외부 동작 회귀 0 (V5)
- [ ] hooks.json 의 신규 entries 가 기존 entries 와 충돌 없음 (PostToolUse Bash matcher 가 신규)
- [ ] adversarial test 가 design memo §8.3 의 (a~d) 와 1:1 매칭
- [ ] Bash exit_code envelope 부재 시 fail-loud (design memo R-12)
- [ ] 전 test suite 회귀 0
