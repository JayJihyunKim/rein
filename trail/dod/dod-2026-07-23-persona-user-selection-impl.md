# DoD — 페르소나 사용자 선택 + 커스텀 프리셋 생성 구현

## 범위

v1.5.0 페르소나 기능을 사용자 선택형으로 확장한다 (plan 확정분):
- loader 중립 기본 flip(명시 `enabled: true` 만 활성) + 커스텀 해석 + `--persona-file` 단일 신뢰 경계.
- 공통 불변층 `_invariant.md`(훅 소유 선두 주입, `_` 이름이라 프리셋 선택 불가) + boss-ace 범용 조항 이관 + 내장 **jennie** 신설(은은한 호감+애교, 단칼 대비, 호칭 오빠+유연).
- per-turn nudge 프리셋 무관화 + 활성 프리셋 요약 1줄.
- 생성 lint `rein-persona-lint.py`(L1~L5) + persona 스킬(선택 + 7문항 Q&A 생성, lint 통과 시에만 저장).
- bootstrap 중립 template + 첫 세션 primer 안내 2줄 + CHANGELOG/README(KR·EN parity) 기본값 변경 안내.
- 기존 default-ON 전제 테스트 전면 교체.

## 변경 대상 파일

plan `docs/plans/2026-07-22-persona-user-selection.md` §실행 전략 12개 태스크의 scope 그대로 — loader(plugin+루트 미러), 훅 `session-start-persona.sh`, 프리셋 3파일, lint 신설, 스킬 신설, bootstrap, primer lib, 문서 3, 테스트 6, 러너 3.

## 검증 기준

- plan Task 순 TDD — RED 확인 후 GREEN 전환.
- loader 2사본 byte-identical, `_invariant.md` ≤1,000자, `jennie.md` ≤1.5KB.
- `bash tests/scripts/run-all.sh` + `bash tests/hooks/run-all.sh` + `bash tests/skills/run-all.sh` 전량 GREEN.
- 구현 완료 후 코드 리뷰 + 보안 리뷰 (리뷰 요청서 두 축 검증 증거 필수).

## 작업 계획

plan 의 4웨이브: wave1 병렬 7(t1 loader RED, t3 훅 RED, t4 프리셋 3파일, t7 lint, t9 bootstrap, t10 primer, t11 문서) → wave2 병렬 2(t2 loader 구현, t8 스킬) → wave3 병렬 2(t5 훅 재배선, t6 nudge) → wave4 단독(t12 러너 등재+전량 회귀). 커밋·리뷰·기록은 부모 소유, RED 단독 커밋 금지, 워커 git stash 금지.

## 라우팅 추천

agent: rein:feature-builder
skills: [rein:parallel-execute, rein:codex-review, rein:security-reviewer]
mcps: []
security_tier: standard
complexity: high
model_hint: sonnet
effort_hint: high
rationale:
  - 신규 기능 구현(feature-builder) — loader/훅/스킬/lint 신설·확장.
  - plan 에 4웨이브 병렬 전략 명시 — parallel-execute 로 dispatch.
  - 훅·loader·경로 해석(보안 표면) 변경이라 코드+보안 리뷰 동반, standard tier.
  - 설계 체인(brainstorm/spec/plan) 전부 리뷰 통과, 사용자가 "계속진행"으로 구현 진입 승인.
approved_by_user: true

## 범위 연결

plan ref: docs/plans/2026-07-22-persona-user-selection.md
design ref: docs/specs/2026-07-22-persona-user-selection.md
covers: [loader-persona-disabled-when-yaml-absent-unparsable-or-enabled-not-true, loader-keeps-boss-ace-for-existing-enabled-true-yaml, loader-resolves-custom-file-under-rein-policy-persona-only-after-format-validation, loader-downgrades-unresolvable-name-to-boss-ace-when-enabled, loader-persona-file-cli-prints-resolved-path-when-active-else-empty, hook-injects-invariant-layer-plus-frontmatter-stripped-preset-from-loader-path-only, invariant-file-underscore-name-never-selectable-as-preset, boss-ace-generic-clauses-migrate-to-invariant-layer-without-duplication, jennie-preset-ships-with-aegyo-plus-blunt-contrast-within-1p5kb, persona-skill-selection-lists-builtins-and-customs-and-writes-yaml, persona-skill-qna-generates-file-only-after-lint-pass, lint-rejects-name-collision-with-builtin-presets, lint-rejects-forbidden-patterns-and-body-over-4000-chars, turn-brief-appends-active-preset-name-and-summary-line, bootstrap-writes-neutral-persona-yaml-template-for-new-installs, primer-adds-persona-selection-guidance-without-new-marker, docs-changelog-readme-note-default-flip-with-boss-ace-restore-oneliner, tests-cover-mirror-parity-custom-resolution-collision-and-invariant-injection]

## 완료 체크

- [x] Wave 1 (병렬 7): RED 테스트 2 + 프리셋 + lint + bootstrap + primer + 문서
- [x] Wave 2 (병렬 2): loader 구현 + persona 스킬 (스킬 워커 1회 무진행 재투입)
- [x] Wave 3 (병렬 2): 훅 재배선 + nudge 무관화
- [x] Wave 4: 러너 등재 + 전량 회귀 GREEN (3 러너 전부, 주입 예산 초과 별건 수리 포함)
- [x] 코드 리뷰 통과 — codex 워치독 2회 정지 판정 → sonnet 대체 리뷰 PASS ×2 (R1 전체 + R2 수정 델타), codex 유언 지적 2건(미폐쇄 머리말 Medium·상대 경로 Low) 실재 확인 후 수정·재검증
- [x] 보안 리뷰 통과 (standard 9검사, 차단급 0 — 정보성 2건 위협모델 내 수용)
- [x] Self-review + inbox/index 기록 (`trail/inbox/2026-07-23-persona-user-selection-impl.md`)
