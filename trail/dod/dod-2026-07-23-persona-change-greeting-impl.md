# DoD — 페르소나 변경 시그니처 인사말 구현

## 범위

페르소나를 스킬로 **바꾸는 순간** 그 캐릭터다운 시그니처 인사말 한 줄을 상태 보고 앞에 prepend 해 전환을 즉시 체감시킨다 (plan 확정분, spec R8 PASS 위):
- 프리셋 frontmatter `greeting:` 저장 계층(boss-ace/jennie curated, `summary:` 공존).
- 로더 `--persona-greeting <name>` 신규 read 모드(검증 통과 builtin/custom 만, 무효/오타/traversal → 빈 출력·exit 0, downgrade 재사용 금지) + `_custom_persona_valid()` (P)∧¬(A) fence 거부 강화, 로더 2벌 byte-identical 파리티.
- 스킬 선택/생성 흐름 인사말(전환 시 prepend, 중립 전환 평문 1줄, fallback 즉석 생성, 생성 흐름 자동 `greeting:` — 8번째 질문 없음, 2줄 cap, tone-only 종속).
- lint (P)∧¬(A) fence 거부(newline-preserving, fail-closed) + greeting L3/L4 자동 커버.
- 세션시작/매턴 훅 소스 불변 — 누출은 로더 런타임 경계 + lint 조기 오류 이중 방어.

## 변경 대상 파일

plan `docs/plans/2026-07-23-persona-change-greeting.md` §실행 전략의 9개 태스크 scope 그대로 — 프리셋 2파일, 로더 2벌(plugin+루트 미러), 스킬 1, lint 1, 테스트 5(로더/lint/스킬/세션시작/신규 preset-greeting) + 러너 1.

## 검증 기준

- plan Task 순 — 구현 워커는 소스만, 테스트 워커는 테스트만 편집, 부모가 실행/검증.
- 로더 2벌 byte-identical (`diff` 빈 출력), (A) 계산에 `str.splitlines()` 금지(`\n` 리터럴 분할만), fence 검사는 newline-preserving raw 읽기.
- 하위호환 회귀 2종 보존: frontmatter 없는 커스텀·정확 `---`(LF) 미폐쇄 fence 는 계속 유효. 거부는 (P)∧¬(A) 한정.
- `bash tests/scripts/run-all.sh` + `bash tests/hooks/run-all.sh` + `bash tests/skills/run-all.sh` 전량 GREEN.
- 구현 완료 후 코드 리뷰 + 보안 리뷰 (리뷰 요청서 두 축 검증 증거 필수).

## 작업 계획

plan 의 2웨이브: Wave 1 = 4개 독립 구현 편집 병렬(프리셋·로더 2벌·스킬·lint) → Wave 2 = 5개 테스트 편집 병렬(각 구현에 depends_on). 로더 2벌은 파리티라 한 태스크. 모든 태스크 mode=edit_only. 커밋·리뷰·기록·테스트 실행은 부모 소유, 워커 git stash 금지, RED 단독 커밋 금지.

## 라우팅 추천

agent: rein:feature-builder
skills: [rein:parallel-execute, rein:codex-review, rein:security-reviewer]
mcps: []
security_tier: standard
complexity: high
model_hint: sonnet
effort_hint: high
rationale:
  - 신규 기능 구현(feature-builder) — 프리셋/로더/스킬/lint 확장.
  - plan 에 2웨이브 병렬 전략 명시 — parallel-execute 로 dispatch.
  - 로더 경로 해석·frontmatter 파싱(보안 표면) 변경이라 코드+보안 리뷰 동반, standard tier.
  - 설계 체인(brainstorm/spec/plan) 전부 리뷰 통과(spec R8·plan 2R), 사용자가 "구현시작해"로 구현 진입 승인.
approved_by_user: true

## 범위 연결

plan ref: docs/plans/2026-07-23-persona-change-greeting.md
design ref: docs/specs/2026-07-23-persona-change-greeting.md
covers: [preset-greeting-stored-in-frontmatter-field-coexisting-with-summary, builtin-presets-carry-curated-signature-greeting-line-under-60-chars, loader-persona-greeting-cli-prints-stored-greeting-for-validated-builtin-or-custom-else-empty, loader-persona-greeting-returns-empty-for-invalid-typo-or-traversal-name, loader-custom-persona-valid-rejects-whitespace-padded-frontmatter-open-fence-fail-safe, greeting-feature-adds-no-new-preset-file-reads-by-skill, skill-prepends-target-preset-greeting-on-activate-switch-and-reselect, skill-emits-plain-non-character-line-on-transition-to-neutral, skill-generates-fallback-greeting-from-collected-candidate-summary-when-greeting-absent, creation-flow-auto-generates-editable-greeting-without-adding-eighth-question, skill-caps-greeting-plus-status-to-two-short-lines-within-invariant-brevity-cap, greeting-stays-tone-only-and-never-weakens-judgment-warnings-or-blocks, lint-covers-stored-greeting-via-existing-l3-size-and-l4-forbidden-scan-no-new-required-rule, lint-rejects-whitespace-padded-frontmatter-fence-to-match-hook-awk-exact-delimiter, session-start-persona-hook-unmodified-and-greeting-absent-from-injected-body, turn-brief-reads-only-summary-and-never-emits-greeting, creation-flow-test-asserts-exactly-seven-questions-and-no-eighth, greeting-length-cap-tested-across-builtin-custom-and-fallback-paths]

## 완료 체크

- [x] Wave 1 (병렬 4): 프리셋 greeting + 로더 greeting read/fence 강화(2벌) + 스킬 인사말 흐름 + lint fence 거부
- [x] Wave 2 (병렬 5): 로더/lint/스킬/세션시작 회귀 + 신규 preset-greeting 테스트 (러너 등재)
- [x] 로더 2벌 파리티 diff 빈 출력 + 3 러너 전량 GREEN
- [x] 코드 리뷰 통과 — codex R1 NEEDS-FIX(Medium fail-open resolver) 수정 → R2 codex 워치독 정지 판정 → sonnet 대체 리뷰 PASS(reviewer: sonnet-fallback, fallback_reason: codex_timeout)
- [x] 보안 리뷰 통과 (standard, 차단급 0 — Low 1 + Info 2 위협모델 수용)
- [x] Self-review + inbox/index 기록 (`trail/inbox/2026-07-23-persona-change-greeting-impl.md`), 커밋 `9e886c3`+`7c4f8e6`
