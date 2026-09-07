# DoD — 리뷰 사이클 자기증폭 고리 봉합 구현 (축1 요청서 reject-tier · 축2 주석 규칙 · 축3 문서-only 조기 통과)

- date: 2026-09-07 착수
- plan ref: docs/plans/2026-09-06-review-cycle-selfamplification.md
- approved_by_user: true (2026-09-06 브리핑 순서 승인 "니가 말한 순서대로 가" → spec 5회차 후 사용자 승인 종결(b) → plan 5회차 후 사용자 승인 종결(b), 2026-09-07 "(b) 승인 종결 + 표식 발급" 선택으로 구현 진입)
- 선행: spec `docs/specs/2026-08-27-review-cycle-selfamplification.md` 표식(user-approved-termination-after-round-5), plan 표식(동일 사유). 훅 실행 루트 실측 = 저장소 트리(plan Architecture).

## 범위 연결

plan ref: docs/plans/2026-09-06-review-cycle-selfamplification.md
work unit: Phase 1 / Task 1.1, 1.2, 1.3, 1.4 + Phase 2 / Task 2.1
covers: [unbacked-ratio-or-percent-claim-outside-evidence-block-hard-rejects-even-with-blocks-present, ratio-or-percent-claim-with-contract-context-and-no-result-verb-outside-evidence-block-remains-advisory-only, unbacked-pass-context-cooccurrence-claim-outside-evidence-block-hard-rejects-even-with-blocks-present, bare-count-claim-with-execution-result-verb-outside-evidence-block-hard-rejects-even-with-blocks-present, bare-count-unit-claim-without-result-verb-outside-evidence-block-remains-advisory-only-unchanged, quant-claim-classification-is-independent-per-category-not-first-match-wins, quant-match-total-count-equals-sum-of-reject-and-advisory-category-counts, exit-code-and-fixed-reference-token-exclusions-remain-unaffected-by-reject-tier-change, zero-evidence-block-rejection-continues-to-apply-regardless-of-quant-claim-category, readiness-reject-tier-applies-only-in-code-review-mode-and-leaves-spec-review-flow-unchanged, code-style-comment-rule-restricts-to-persistent-contract-and-bans-round-history-measured-narrative, code-style-comment-rule-scopes-enforcement-to-diff-added-or-modified-comment-lines-only, code-style-comment-rule-directs-remediation-to-delete-or-relocate-not-in-place-correction, plugin-drift-check-remains-ok-after-code-style-rule-and-summary-edits, print-subject-returns-changeset-paths-from-the-same-worktree-changeset-instance, rein-cli-serializes-changeset-paths-key-for-code-review-and-omits-it-for-security-review, selfverify-should-fire-skips-when-review-subject-is-subject-empty-sentinel, selfverify-subject-empty-skip-requires-current-observation-to-be-subset-of-subject-changeset-paths, selfverify-changed-files-retrieval-failure-fires-before-subject-empty-skip-is-consulted, selfverify-subject-empty-skip-does-not-relax-fail-closed-retrieval-failure-path, selfverify-still-fires-when-any-non-exempt-code-path-is-in-review-subject, selfverify-check-requirement-set-unchanged-when-gate-fires, subject-empty-selfverify-skip-does-not-exempt-spec-review-pending-marker-gate]

## 배경

코드 리뷰가 반복되는 실제 원인은 코드 결함이 아니라 회차마다 바뀌는 수치·이력 서술이 코드 주석과 요청서에 쌓여 그 정정이 전체 재검증을 다시 부르는 것이다(spec §1). 세 곳에서 그 입력을 차단한다 — 요청서의 블록 밖 실행 결과 서술은 거부(축1), 주석은 지속 계약만(축2), 순수 문서 변경은 typecheck/test 증거 요구 없이 통과하되 관측 일관성 검사로 안전하게(축3).

## 범위

plan 의 Task 1.1~1.4(웨이브 1) + Task 2.1(웨이브 2). 실행 방식은 plan Architecture "dispatch 계약"/"격리 태스크 절차" 가 정본:
- 블록의 4 태스크(1.1 · 1.2 · 1.4 · 2.1)는 정본 `parallel-execute` 가 같은 트리에서 dispatch(워커 sonnet).
- Task 1.3(`bin/rein` 3-tuple 직렬화)은 블록 밖 부모 소유 **격리 worktree** 작업 — 이 DoD 와 `trail/dod/.active-dod` 커밋 뒤 worktree 생성, 완성 파일 복사 반입, 웨이브 1 과 동시 진행.
- 웨이브마다 부모 close-out(plan §"부모 웨이브별 close-out"): barrier → 마커 스캔 → typecheck → 테스트 → 저장소 래퍼 명시 경로 codex 리뷰 → 보안 리뷰 → 커밋 1개. 웨이브 1 뒤 같은 슬러그 완료 기록 금지.
- 포함하지 않음: spec §8 Option A/C, pending 마커 게이트·`_selfverify_check` 요구 축·마스킹 제외 규칙·envelope 형식 변경, 실행기 정본(스킬·스키마·워커 정의) 확장.

## 변경 파일

- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- plugins/rein-core/skills/codex-review/SKILL.md
- plugins/rein-core/rules/code-style.md
- plugins/rein-core/rules/short/code-style-summary.md
- plugins/rein-core/skills/code-reviewer/SKILL.md
- plugins/rein-core/rein/cli/issue_evidence.py
- plugins/rein-core/bin/rein
- plugins/rein-core/tests/cli/test_issue_evidence_subcommand.py
- plugins/rein-core/tests/cli/test_print_subject_changeset_paths.py
- tests/skills/test-codex-review-wrapper.sh
- tests/skills/test-review-evidence-manifest.sh
- tests/skills/test-review-selfverify-gate.sh
- tests/hooks/test-spec-review-gate.sh

## 검증 기준

- [x] 웨이브 1: barrier 통과(델타 ⊆ scope 13파일) + Task 1.3 반입 + 충돌 마커 0 + typecheck 3명령 + close-out 4단계 9명령 전부 GREEN + Axis 2 문구 grep 4건 ≥1 → 저장소 래퍼 명시 경로 리뷰 PASS → 보안 리뷰 PASS → 커밋 1개.
- [x] 웨이브 2: 진입 조건(Task 1.3 반입 + 웨이브 1 커밋) → barrier → typecheck → 9명령 GREEN → 리뷰 PASS(편집된 래퍼로 도는 첫 리뷰 — 새 스캐너 실전) → 보안 리뷰 PASS → 커밋 1개.
- [x] 최종 전량: `bash tests/skills/run-all.sh` · `bash tests/hooks/run-all.sh` · `bash tests/scripts/run-all.sh` · `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s plugins/rein-core/tests` 전부 0 → 같은 슬러그 완료 기록 1회 + index 갱신.
- [x] 두 래퍼 사본 byte 동일(`cmp`), `rein-check-plugin-drift.py` OK, 저장소 아래 `__pycache__` 미생성.

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:parallel-execute
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: high
rationale:
  - 코드 3파일(래퍼·CLI·bin) + 규칙 문서 3파일 + 테스트 5파일, 웨이브 2개, 격리 태스크 1개 — 구현 워커 sonnet 고정(사용자 지시 08-11), 리뷰는 웨이브당 codex 1회
  - 워커 금지목록: 커밋·스테이징·리뷰 표식·trail 기록·stash·scope 밖 편집·하위 위임 금지
approved_by_user: true

## 완료

- 2026-09-07 코드 커밋 dev `2c775ae`(웨이브 1) + `7b7c249`(웨이브 2). 각 웨이브 codex 코드 리뷰 PASS + 보안 리뷰 PASS(같은 지문). 전량 배터리 3종 + python 스위트 종료값 0. 상세 `trail/inbox/2026-09-07-review-cycle-selfamplification.md`, 웨이브 1 상세 `trail/inbox/2026-09-07-review-selfamp-wave1-progress.md`.
