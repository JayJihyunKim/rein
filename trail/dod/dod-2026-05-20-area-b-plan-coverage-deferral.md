# DoD — Area B X3.B.1 + X3.B.2 묶음 (plan-coverage deferral 구현)

- 날짜: 2026-05-20
- 유형: refactor (hook 책임 재배치 + commit gate flush 신설)
- design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md (X3.B.0 land, stamp `3a5948058005ad00.reviewed`)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.2 (영역 B)
- cycle: X3.B.1+B.2 묶음 — design memo §5.1 + §5.2 구현

## 범위 (Scope)

포함 — 두 hook 의 책임 재배치 + adversarial test 신축:

1. `plugins/rein-core/hooks/post-edit-plan-coverage.sh` 본문 수정 (B.1):
   - 현재 plan 편집 시 즉시 validator 호출 → marker (`.coverage-mismatch`) 생성 로직 제거
   - `trail/dod/.plan-coverage-dirty` 에 dirty plan abs path 한 줄 append 로 교체 (O_APPEND single-line atomic)
   - PIPE_BUF 한도 (>512 bytes) 초과 시 legacy immediate validator fallback (silent corruption 방지)

2. `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh` 의 commit/test 분기에 flush 로직 추가 (B.2):
   - `git commit` / `pytest` 등 기존 분기 진입 직후 (P2 marker 검사 *앞*) flush 실행
   - **Atomic rename protocol**: `mv -f .plan-coverage-dirty .plan-coverage-dirty.processing` 먼저, 새 append 는 신규 dirty 파일로
   - `.processing` 읽고 unique path set 추출 (set 등가 contract, design memo §7 ID 2)
   - 각 unique path 마다 validator 1회 실행. FAIL 시 기존 `.coverage-mismatch` 생성 경로 reuse (P2 deny path 그대로)
   - 모두 PASS + validated_count ≥ 1 → `.processing` 삭제
   - validated_count == 0 (모두 deleted) → conservative-block (`.processing` 잔존, legacy 와 일관)
   - flush subprocess 인프라 오류 (resolver/validator/mv 실패) → fail-closed (exit 2)
   - 진입 시 stale `.processing` 발견 시 우선 처리 (새 `mv` 거부)

3. `tests/hooks/test-plan-coverage-deferral.sh` 신축:
   - design memo §5.1 (a~f) 검증 case
   - design memo §5.2 (a~e) 검증 case
   - concurrent append during flush (간이 race test, 다수 반복)
   - PIPE_BUF fallback test
   - GUARD-1 보존 회귀 test (codex/security review stamp gate 가 pytest 비차단 유지)

제외 (별 cycle):

- X3.B.3 (`post-edit-review-gate` 의 dirty source path 본문 append) — 선택 보강, 별 cycle
- X3.B.4 의 일부 (master plan amendment) — X3.B.5 cycle
- master plan §4.2 본문 정정 — X3.B.5 cycle (사용자 confirmation 필요 여부 판정 동반)
- 영역 C state machine 합류 — 별 cycle

## 작업 기준 (Definition of Done)

1. TDD red-green 순서로 진행 — test 작성 → 실패 확인 → 구현 → PASS
2. 두 hook 변경분이 design memo §5.1 + §5.2 spec 와 1:1 매칭
3. 신규 `.plan-coverage-dirty` / `.plan-coverage-dirty.processing` 파일 lifecycle 이 명세 그대로
4. `tests/hooks/test-plan-coverage-deferral.sh` 전 case PASS
5. 기존 test suite (`bash tests/rein-test.sh` 15/15 + 기타 hook/integration test) 회귀 0
6. codex code review (Mode A) PASS — `.codex-reviewed` stamp
7. security-reviewer PASS — `.security-reviewed` stamp 갱신
8. inbox + index 갱신
9. dev commit (push 는 사용자 확인 대기)

## 검증 시나리오

- (V1) plan edit 5회 (다른 plan) → `.plan-coverage-dirty` 5줄, validator 호출 0
- (V2) `.plan-coverage-dirty` 에 valid plan 1 + invalid plan 1 → `git commit` 시도 → invalid 의 P2 deny 발생, `.coverage-mismatch` 생성
- (V3) flush 도중 새 plan edit → 새 entry 가 `.plan-coverage-dirty` (신규 파일) 에 들어가 손실 없음
- (V4) `.plan-coverage-dirty` 에 모두 deleted plan → `.processing` 잔존 + conservative-block, commit 차단
- (V5) `pytest` 실행 시 dirty list 처리 동작이 `git commit` 와 동일
- (V6) flush python3 resolver 실패 → exit 2 (fail-closed)
- (V7) stale `.processing` 있는 상태에서 새 commit 진입 → 우선 처리 (flush 시도)
- (V8) PIPE_BUF 초과 한 줄 → legacy immediate validator fallback (silent corruption 없음)

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - superpowers:test-driven-development
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
rationale: |
  hook 책임 재배치 = refactor 성격 (외부 동작 = "coverage discipline 차단"
  보존, 내부 시점만 이동). feature-builder-refactor 가 researcher-first
  전략으로 기존 hook 의 호출자/소비자 매핑부터 다시 확인. TDD 강도 강제 —
  test-driven-development skill 의 red-green-refactor 그대로. codex-review
  는 Mode A (code review) — design 은 X3.B.0 에서 이미 PASS 받았으니 본
  cycle 은 코드 자체 리뷰. verification-before-completion 으로 "test
  실행 결과 확인 후" 만 완료 선언.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "오토모드로 진행" 명시 + 이번 cycle 묶음에 동의. refactor 성격에
  표준 보안 tier 적용. hook 변경은 commit gate 의 차단 경로를 건드리므로
  security review 가 필수 (skip 불가).
```

## self-review 체크리스트

- [ ] design memo §5.1/§5.2 spec 와 hook 본문 변경분이 1:1 매칭 (drift 0)
- [ ] atomic rename protocol 이 race-free (test 가 검증)
- [ ] flush 가 commit gate 의 다른 P2~P7 검사 *앞* 에 위치 (기존 P2 동작 보존)
- [ ] fail-closed 정책이 [I1]~[I6] 분류와 일관
- [ ] GUARD-1 (test 실행 stamp gate 비차단) 보존 — coverage discipline 의 pytest 차단은 본 변경의 새 차단이 아니라 기존 동작 유지
- [ ] 기존 81/81 test PASS + 신규 test 모두 PASS
- [ ] `.plan-coverage-dirty` / `.processing` 파일 lifecycle 이 stale 시나리오까지 cover
