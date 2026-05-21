# DoD — Cycle X4.C.3 (4 policy hook 에 effective_mode fast-path skip 추가)

- 날짜: 2026-05-21
- 유형: feat (4 hook 에 read_effective_mode 분기 + skip + adversarial test)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md §8.4 (X4.C.0 PASS)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.3 (영역 C)
- cycle: X4.C.3 — design memo §8.4 산출물

## 범위 (Scope)

포함:

1. `plugins/rein-core/hooks/pre-edit-dod-gate.sh` 변경:
   - DoD validator subprocess 호출 (L516~) 직전, state-machine.sh source 시도
   - `read_effective_mode` 결과가 `source_edit` AND 같은 file 이 dirty_files 에 이미 있는 경우, validator subprocess skip + 직전 marker 상태 (DOD_MISMATCH_MARKER / DOD_ADVISORY_MARKER) 그대로 사용
   - state-machine.sh 부재 / lock 실패 시 legacy path (validator 호출 — 외부 동작 회귀 0)
   - 다른 모든 gate (incident / spec-review / routing) 는 skip 대상 외 — 보수적

2. `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh` 변경:
   - INPUT 파싱 직후, `read_effective_mode == answer` 이면 envelope inject skip + exit 0
   - mode==answer 인데 PostToolUse(Edit) 가 fire 됨 = 이상 신호 (Stop 직후 다시 Edit) — body inject 불필요
   - state-machine.sh 부재 → legacy path (정상 inject)

3. `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh` 변경:
   - 위와 동일 패턴 (mode==answer → skip)

4. `plugins/rein-core/hooks/post-edit-spec-review-gate.sh` 변경:
   - 마커 생성 loop 안에서, 이미 같은 path 의 `.pending` marker 가 존재하고 effective_mode == source_edit 이면 mtime touch 만 (재기록 skip — 동일 burst 내 중복 생성 방지)
   - 이 경우 NOTICE 메시지는 그대로 (사용자가 review 필요성을 잊지 않도록)

5. `tests/hooks/test-state-fast-path-skip.sh` (신규, 4 adversarial test — design memo §8.4 검증):
   - (a) pre-edit-dod-gate: state.json mode=source_edit + dirty_files=[src/foo.ts] → 같은 file Edit 두 번째 호출 시 validator subprocess 호출 횟수 1회 (두 번째 skip)
   - (b) post-edit-design-plan-coverage-rule: state.json mode=answer + journal 비어 있음 → envelope 미발행
   - (c) post-edit-routing-procedure-rule: 동일 패턴 (mode=answer → 미발행)
   - (d) post-edit-spec-review-gate: 같은 spec 의 .pending marker 이미 존재 + mode=source_edit → re-write 없음 (mtime 만 갱신)

6. `tests/hooks/run-all.sh` 에 신규 test 등록

제외 (별 cycle):

- X4.C.4: SPIKE 측정 + 영역 B 통합 검토 (Q-1) + 영역 C 종결
- X3.B.3: post-edit-review-gate dirty source path 본문 append

## 작업 기준

1. TDD red-green — test 먼저 작성 → 실패 확인 → 구현 → PASS
2. fail-soft: state-machine.sh 부재 또는 read_effective_mode 실패 → 모든 hook 은 legacy path 진입 (외부 동작 회귀 0). 본 V5 검증
3. design memo §6 R-7 (false-positive skip) mitigation — 보수적 skip 만 적용. 안전 gate (incident/spec-review/routing) 는 skip 대상 외
4. shellcheck clean (가능 시)
5. 전 hook test suite 회귀 0 (X4.C.1/C.2 baseline + 전체 hook chain)
6. codex Mode A code-review PASS — `.codex-reviewed` stamp
7. security-reviewer PASS — `.security-reviewed` stamp
8. inbox + index 갱신 + dev commit (single commit per cycle)

## 검증 시나리오

- (V1) `bash tests/hooks/test-state-machine.sh` X4.C.1 baseline 6/6 PASS
- (V2) `bash tests/hooks/test-state-machine-integration.sh` X4.C.2 4 case PASS
- (V3) `bash tests/hooks/test-state-fast-path-skip.sh` 신규 4 case PASS
- (V4) `bash tests/hooks/run-all.sh` ALL SUITES PASSED
- (V5) state.json + 3 journal 모두 삭제 → 4 patched hook 모두 정상 동작 (legacy fallback)
- (V6) `bash tests/rein-test.sh` 15/15 PASS — CLI 표면 회귀 0

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
rationale: |
  영역 C 의 fast-path skip cycle. lib (X4.C.1) + wire-up (X4.C.2) 가 land 된
  상태에서 4 policy hook 에 read_effective_mode 분기 + 보수적 skip 추가.
  feature-builder 가 4 hook 의 일관된 patch + adversarial test 관리. TDD 로
  4 test 먼저 작성 후 hook 본문 수정. codex Mode A 로 false-positive skip
  (R-7) + fail-soft contract (V5) 리뷰. verification-before-completion 으로
  legacy fallback 까지 실증 후 완료.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "잔존 작업 모두 순차적으로 진행" + 오토모드 명시. dispatcher 본문
  미변경 + Bash exit code 추출 미동반이지만 보안 영향 gate (DoD/incident/spec-review)
  의 conditional skip 분기 추가 → standard tier 필수.
```

## self-review

- [ ] 4 hook patch 의 fast-path 진입 조건이 design memo §3.4 + §6.2 의 "보수적 skip" 정책과 일치
- [ ] 안전 gate (incident / spec-review / routing approved_by_user) 는 skip 대상 외
- [ ] state-machine.sh source 실패 시 legacy path — V5 검증
- [ ] adversarial test 4 case 가 design memo §8.4 의 검증 시나리오 (mode-dependent skip + legacy fallback) 와 1:1 매칭
- [ ] 전 test suite 회귀 0
- [ ] cycle commit message 가 `feat(hooks): Cycle X4.C.3 — ...` 형식 + scope 점(.) 없음 (메모리: feedback_commit_scope_format)
