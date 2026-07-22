# DoD — 코드리뷰 사이클 효율화 구현 (자가검증 관문 + 출력축소)

## 범위

리뷰 래퍼 `plugins/rein-core/scripts/rein-codex-review.sh` 에 두 기능을 구현한다:
- **A 무상태 자가검증 관문**: 모든 비면제 code-review 호출 직전 로컬 검증 증거(타입체크 exit0 + 테스트 exit0 두 축, 또는 검증명령 없음 폴백, 또는 TDD red-phase escape)를 요구, 부재 시 codex spawn 이전 `exit 4` + 라인 앵커 `ERROR: [codex-review][readiness-reject]`. 무상태(재리뷰/면제 판정 없음).
- **C 통과답변 출력축소**: envelope 지시를 "통과 항목 요약 + 발견만 상세"로, `FINAL_VERDICT` 계약 불변, `REIN_REVIEW_VERBOSE=1` escape, 축소 envelope 에 네 검사 지시문 존재 정적 검증.
- 면제(B)는 범위 아님 (spec §5 defer). 커밋 게이트·post-edit 게이트는 손대지 않는다.

## 변경 대상 파일

- `plugins/rein-core/scripts/rein-codex-review.sh` (SSOT)
- `scripts/rein-codex-review.sh` (sha256 미러 — 동일 편집)
- `tests/skills/test-review-selfverify-gate.sh` (신규 — A 축 계약)
- `tests/skills/test-review-envelope-reduction.sh` (신규 — C 축 계약; plan 확정 파일명)
- `tests/skills/run-all.sh` (신규 스위트 2개 등록)
- `tests/skills/test-review-evidence-manifest.sh` (구현 중 추가 — E5/E5b 전이 불변식 2건을 의도된 envelope 변경(출력 밀도 블록) 기준으로 갱신)
- `tests/skills/test-codex-review-wrapper.sh` / `tests/skills/test-codex-model-profile-routing.sh` (구현 중 추가 — dirty-tree fixture 가 신규 관문에 막히지 않도록 러너에 none 폴백 선언 통행증 추가; 검증 대상 불변)

## 검증 기준

- 각 Scope 항목마다 실패 테스트 먼저(TDD) → 구현 → GREEN.
- `bash -n` 구문 검증 통과 (래퍼 + 미러).
- `bash tests/skills/run-all.sh` GREEN (신규 2 스위트 포함).
- SSOT ↔ 미러 sha256 동일 (`tests/scripts/test-plugin-scripts-bundle.sh`).
- fail-open/fail-silent 회귀 없음: 취득 실패 시 차단(exit4-before-spawn), 의도적 red 거부가 통과로 새지 않음(plan 리뷰 지적 반영분).
- 구현 완료 후 코드 리뷰 + 보안 리뷰 (codex 행 시 Sonnet 대체, 표식에 정직 기록).

## 작업 계획

계획서(`docs/plans/2026-07-20-review-cycle-efficiency.md`)의 Phase/Task 순서를 따른다:
1. Phase 1 (A축): 발동블록 골격 → 빈 요청서 안전초기화(Task 1.1) → 발동판정+취득 fail-closed(1.2) → 두 축 증거(1.3) → none 폴백(1.4) → TDD red escape(1.5). 한 흐름 커밋.
2. Phase 2 (C축): 출력축소+verbose(2.1) → FINAL_VERDICT 불변 회귀 + 네 검사 정적 검증(2.2).
3. Phase 3: 신규 스위트 2개 run-all 등록 + 전량 GREEN.

## 라우팅 추천

agent: rein:feature-builder
skills: [rein:codex-review, rein:security-reviewer]
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: high
rationale:
  - 리뷰 게이트 래퍼에 신규 실행 로직 추가 — 새 기능 구현(feature-builder).
  - 게이트/규율 표면이므로 코드 리뷰 + 보안 리뷰 동반, 위험 경로(scripts/rein-*.sh)라 standard tier.
  - 사용자가 설계·계획 승인 후 구현 진입을 명시 승인함(이 세션).
approved_by_user: true

## 범위 연결

plan ref: docs/plans/2026-07-20-review-cycle-efficiency.md
design ref: docs/specs/2026-07-20-review-cycle-efficiency.md
covers: [A1-selfverify-fires-on-code-review-call-with-changes-missing-evidence-exit4-before-spawn, A2-selfverify-two-distinct-axis-blocks-each-exit0-via-summary-one-token-per-claim, A3-selfverify-fallback-verification-commands-none-masked-body-anchored-requires-diff-review-failclosed, A4-selfverify-tdd-redphase-escape-requires-named-expected-failure-rejects-nonintentional-exit-codes-failclosed, A5-selfverify-spec-review-mode-full-skip-inherits-precheck-skip, A6-selfverify-changed-files-acquisition-failure-failclosed-genuine-empty-skip, C1-envelope-pass-items-collapsed-to-checked-passed-counts-findings-full, C2-envelope-omit-empty-input-sections, C3-final-verdict-line-contract-unchanged-parser-tail-match-stamp-invariant, C4-verbose-env-restores-full-narration-audit, C5-reduced-envelope-static-contains-all-four-review-check-instructions]

## 완료 체크

- [x] Phase 1 A축 구현 + 테스트 GREEN (자가검증 스위트 69 단언)
- [x] Phase 2 C축 구현 + 테스트 GREEN (축소 스위트 19 단언)
- [x] Phase 3 스위트 등록 + 전량 GREEN (skills/hooks/scripts 3종)
- [x] SSOT ↔ 미러 sha256 일치 (bundle 테스트 OK)
- [x] 코드 리뷰 통과 — codex R1 NEEDS-FIX 반영 후 R2 는 codex 행(30분+) → 대체 리뷰 통과 (표식에 codex_timeout 정직 기재)
- [x] 보안 리뷰 통과 (Low 1건 후속 이관 — inbox 참조)
- [x] Self-review (diff 전 hunk + 회귀 전량 확인)
