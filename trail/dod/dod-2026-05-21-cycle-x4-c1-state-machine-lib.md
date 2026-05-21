# DoD — Cycle X4.C.1 (state machine lib + journal append helper + tests)

- 날짜: 2026-05-21
- 유형: feat (신규 lib + 신규 test file)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md (X4.C.0 PASS Round 5, stamp `9faa41da2b6fc4b1.reviewed`)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.3 (영역 C)
- cycle: X4.C.1 — design memo §8.2 의 1차 산출물

## 범위 (Scope)

포함 (design memo §8.2 산출물 정의):

1. `plugins/rein-core/hooks/lib/state-machine.sh` 신축 — 다음 함수 export:
   - `read_state` — `.rein/state.json` parse + schema_version 검사. 부재/malformed 시 default state 반환 (mode=answer, dirty_files=[], last_drain_seq=0) + stderr NOTICE
   - `write_state` — atomic rename (`mv -f state.json.tmp state.json`)
   - `append_journal <kind> <entry>` — `.rein/state-pending-<kind>.log` 에 `flock -x` 안에서 append. kind = edits / bash / stop. seq 자동 allocate
   - `read_effective_mode` — `.rein/state.lock` 안에서 state.json + active journals + (있다면) `.processing` 의 entries 합산 후 effective_mode 반환
   - `acquire_state_lock <mode>` / `release_state_lock` — `.rein/state.lock` 의 `flock -x` (exclusive) / `flock -s` (shared) 헬퍼
   - seq allocation: design memo §4.2 의 `next_seq = max(state.last_drain_seq, max(active), max(.processing)) + 1`
   - `.rein/` 디렉토리 부재 시 0700 으로 자동 생성
   - shellcheck clean

2. `tests/hooks/test-state-machine.sh` 신축 — 5 case 최소 (design memo §8.2 검증 a~e):
   - (a) state 부재 → `read_state` default 반환 + state 파일 미생성
   - (b) parse 실패 → stderr NOTICE + default 반환
   - (c) `write_state` 동시 호출 100회 → mtime ≥ 1 회 갱신 + state.json.tmp 잔존 0 (atomic rename 검증)
   - (d) `append_journal` 동시 100회 → entry count == 100 (flock 직렬화 검증)
   - (e) state.json.mode == "answer" + journal 에 edit 1건 → `read_effective_mode` == "source_edit"

3. `tests/hooks/run-all.sh` 에 신규 test 등록

제외 (별 cycle):

- 3 신규 journal writer hook (post-edit / post-bash / stop) — X4.C.2 cycle
- dispatcher 의 drain 로직 — X4.C.2 cycle
- hooks.json 등록 — X4.C.2 cycle
- hook fast-path skip — X4.C.3 cycle
- SPIKE 측정 — X4.C.4 cycle

## 작업 기준

1. TDD red-green 순서. test 먼저 작성 → red 확인 → 구현 → green
2. lib 의 모든 export 함수가 design memo 의 contract (특히 §4.2 의 seq 식, §3.3 의 snapshot lock) 와 1:1 매칭
3. 신규 5 test case 전 PASS
4. 기존 test suite 회귀 0 (tests/hooks/run-all.sh, tests/rein-test.sh)
5. shellcheck clean (`shellcheck plugins/rein-core/hooks/lib/state-machine.sh` exit 0)
6. codex code review (Mode A) PASS — `.codex-reviewed` stamp
7. security-reviewer PASS — `.security-reviewed` stamp
8. inbox + index 갱신

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
rationale: |
  신규 lib + 신규 test = feature-builder. 영역 C 의 첫 implementation cycle —
  design memo §8.2 의 contract 를 1:1 코드로 구현. TDD red-green 으로 5 test
  case 먼저 작성 후 lib 구현. codex Mode A 로 lib 본문 리뷰 (design alignment +
  shell race-safety). verification-before-completion 으로 전 test PASS 확인 후 완료.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "다음단계 진행해" + 오토모드 명시. 신규 hook helper lib (shell + flock +
  JSON parse) 가 보안 표면 일부 (state.json 권한, lock 파일 경로) 동반 → standard tier.
```

## self-review

- [ ] state.json schema 가 design memo §2.2 와 일치 (schema_version=1, mode/dirty_files/updated_at/command_class_cache/risk_score/last_drain_seq)
- [ ] seq allocation 식이 §4.2 의 `next_seq = max(...)` 와 정확히 일치
- [ ] read_effective_mode 가 §3.3 snapshot lock contract 준수 (state + active journals + .processing 일관 read)
- [ ] unified lock invariant — append/drain/read 모두 `.rein/state.lock` 사용
- [ ] atomic rename + flock 기반 race-free
- [ ] schema_version mismatch / parse 실패 → vocal NOTICE + legacy default (silent drop 0)
- [ ] 5 test case 가 design memo §8.2 의 검증 항목 (a~e) 와 1:1 매칭
- [ ] 기존 test 회귀 0
