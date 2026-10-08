# DoD: 리뷰 회차 델타 증거 인정 + 수치 구성 대응 + 보안 무결성 등급 + 설명·질문·운영 원칙 + 에이전트 기본 모델

- 작성일: 2026-10-07
- plan ref: docs/plans/2026-10-07-review-delta-evidence-and-defaults.md
- 사용자 지시: "오케이 그렇게 진행하자. 자동모드 켜고 구현테스트까지 진행해" (2026-10-07). 범위는 직전 두 턴에서 합의 — 규칙 문구 5건(델타 증거·수치 구성·보안 무결성 등급·설명/질문/운영 원칙·기본 모델) + 에이전트 모델 지정. 래퍼·CLI 스크립트 변경(프로젝트 정의 사전검사 훅, 중복 작업 거부)은 두 번째 사이클.
- plan 검토 종결(2026-10-07): spec 은 codex 세 사이클(6회차·3회차·4회차) PASS. plan 은 codex 5회차 상한 도달 — 남은 지적이 후속 안내 절 개수 숫자 2개뿐이라 작성자가 고친 뒤 **사용자가 재검토 없이 직접 승인**("다고쳤으면 통과 내가 직접 승인한다"). 표식은 `rein-mark-spec-reviewed.sh … user-approved-skip-review` 로 생성(문서 전용 변경 + 명시 승인 예외).
- 근거: `docs/reports/[issues]_2026-10-07.md` — 사용자 프로젝트에서 리뷰 회차마다 전체 테스트(약 29분)를 재실행해 회차당 1시간 10분. rein 은 회차마다 전체 스위트를 요구하지 않지만(래퍼 자가검증 관문은 `[axis:test]` 통과 블록 1개를 요구할 뿐 범위를 정하지 않음 — `docs/specs/2026-07-20-review-cycle-efficiency.md` §4.2), 스킬 문서에 그 계약과 "후속 회차 증거 범위"가 없어 사용자 프로젝트가 과잉 해석했다. 수치 표기 2건이 Claim Audit sub-item 6 (b) 로 회차 1개를 소모했고, 보안 Low 로 분류된 TOCTOU 결함이 코드 리뷰에서 High 로 돌아와 회차 1개를 더 썼다. 설명·질문·운영 원칙과 에이전트 모델 기본값은 사용자가 매 세션 손으로 넣던 지시를 rein 기본으로 올리는 것.

## 범위

IN
1. `plugins/rein-core/skills/codex-review/SKILL.md` — (a) 자가검증 관문의 두 축 계약(`[axis:typecheck]`·`[axis:test]`·`diff_self_review:`)을 사용자 문서에 명시, (b) 후속 회차 양식에 **델타 증거 형식** 추가(전체 실행 트리 식별자 + 델타 파일 목록 + 델타가 닿는 대상 테스트 로그 = `[axis:test]` 블록으로 충분, 전체 스위트는 기준 실행 1회 + 최종 트리가 다르면 커밋 전 1회 — 복귀 조건마다 +1 + 전체 재실행 복귀 조건), (c) 수치 주장에 **구성(합산 근거·출처)** 을 적는 요청서 지침.
2. `plugins/rein-core/scripts/rein-codex-review.sh`(+ 루트 사본 `scripts/rein-codex-review.sh` 바이트 동일 동기화 — 정책 테스트가 루트 사본을 읽음) — 코드 봉투 Claim Audit 에 (a) 델타 증거 인정 지시문(요청서가 델타 형식을 갖추면 전체 스위트 재실행을 요구하지 않는다, 복귀 조건 충족 시 Medium), (b) sub-item 6 에 "구성이 제시되고 검증되면 완전한 대응" 단서. 텍스트 슬롯만 변경 — 파서·판정 함수·exit 계약 무변경.
3. `plugins/rein-core/agents/security-reviewer.md` — 재현 가능한 데이터 무결성 결함(지문 계산 시점과 적재 시점 사이 변경 가능성 등 TOCTOU 류)은 Low 로 분류하지 않는다(최소 Medium) + 보안 검토가 코드 검토보다 먼저 수행된 경우 Medium 이상은 코드 검토 전에 반영한다.
4. `plugins/rein-core/rules/response-tone.md` + `rules/short/response-tone-summary.md` — 설명 원칙(한 문장 한 핵심·첫 용어 풀이·같은 개념 같은 이름·사실/추정/미검증 구분·구조는 도식) + 질문 원칙(맥락 → 결정 → 선택의 결과 → 추천과 질문, 기술 이름만으로 선택 요구 금지, 한 번에 결정 하나) + 작업 완료 보고 4분할(변경 내용/이유/영향/검증 결과와 미확인 — 진행 보고 3단은 유지). 언어는 기존 "사용자 언어" 규칙 유지(한국어 고정 아님).
5. `plugins/rein-core/rules/operating-sequence.md` + `rules/short/operating-sequence-summary.md` — 작업 운영 원칙(시작·재개·전환 시 목표/위치/남은 일 알림, 사용자 확인 대상 vs 직접 판단 대상 경계, 합의된 결정 재질문 금지, 결정 기록 위치).
6. `plugins/rein-core/rules/orchestrator-first.md` + `rules/short/orchestrator-first-summary.md` + `rules/routing-procedure.md` — §5 에 기본 모델 배정(설계·검토·조사·보안 = opus 급, 정형 구현·문서 = sonnet 급, 지휘 모델은 세션 모델 그대로) + DoD `model_hint` 를 "지정 시 dispatch 의 model 인자로 전달해 에이전트 기본값을 덮는다"로 승격.
7. `plugins/rein-core/agents/*.md` 10개 — frontmatter `model:` 추가 (opus: spec-writer, plan-writer, researcher, security-reviewer, orchestrator / sonnet: feature-builder, feature-builder-fix, feature-builder-refactor, feature-builder-worker, docs-writer).
8. 테스트 — `tests/scripts/test-ups1-short-rule-injection.sh` response-tone 요약 상한 1300→1800 B, `tests/skills/test-codex-review-claim-audit-policy.sh` 델타·구성 문구 grep 추가, `tests/fixtures/envelope-code-review.golden` 재생성(REIN_GOLDEN_UPDATE=1), `tests/skills/test-review-evidence-manifest.sh` E5 인접성·E5b 정규화 패턴 갱신, 명시 목록 러너 3개(`tests/agents/run-all.sh`·`tests/rules/run-all.sh`·`tests/skills/run-all.sh`)에 신규 테스트 편입, 신규 `tests/agents/test-agent-model-frontmatter.sh`, 신규 `tests/rules/test-communication-principles.sh`(response-tone·operating-sequence·orchestrator-first 본문+요약 문구 고정), 신규 `tests/skills/test-codex-review-delta-evidence.sh`(SKILL.md·security-reviewer 문구 고정).
9. `CHANGELOG.md` Unreleased 항목(user-facing) — 버전 bump 는 릴리스 시점(별도 사이클).
10. 죽은 "`security_tier: light` 면 보안 검토 증거 면제" 문구 5곳 정정(routing-procedure §6 · operating-sequence 11-step 표 6행 · feature-builder·-fix·-refactor 체크리스트) — 게이트는 이 필드를 읽지 않고 light 여도 증거 필수(`tests/hooks/test-security-tier-gate.sh` 고정). 전부 위 변경 파일 안, 게이트 동작 불변. 설계 리뷰 지적(2026-10-07)으로 추가.

OUT
- 래퍼 사전검사 로직·파서·exit 코드·`[EVIDENCE]` 문법 — 무변경(델타 증거는 기존 `[axis:test]` 블록 재사용).
- 프로젝트 정의 사전검사 훅(`.rein/review-precheck.sh`), `rein job` 중복 거부·진행률 보고 — 두 번째 사이클.
- `pytest-xdist`·느린 테스트 마커 — 사용자 프로젝트 몫.
- 보안 규칙 파일(`security/rules/*.md`) 검사 항목 — 무변경.
- 코드 리뷰·보안 리뷰·커밋(plan Phase 3) — 후속 기준서(위 Definition of Done 참조). 리뷰에서 나온 수정도 그 기준서 아래에서.
- 릴리스(버전 bump·main 머지·태그) — 별도 사이클.

## Definition of Done

- [x] 설계 문서(brainstorm → spec → plan) 작성·검토 통과
- [x] 위 IN 1~10 구현 — 각 파일의 문구가 신규 테스트로 고정
- [x] 기존 테스트 스위트(`tests/hooks/run-all.sh`·`tests/skills`·`tests/rules/run-all.sh`·`tests/agents/run-all.sh`·`tests/scripts`) 기준선 대비 회귀 0
- [x] 완료 기록(`trail/inbox/2026-10-07-review-delta-evidence-and-defaults.md`) + `trail/index.md` 갱신 — 이 기준서는 **구현·테스트에서 닫힌다**. 코드 리뷰·보안 리뷰·커밋(plan Phase 3)은 사용자 별도 승인 후 **후속 기준서**(`trail/dod/dod-<날짜>-review-delta-evidence-phase3.md`, 같은 plan 의 Phase 3 를 가리킴)로 진행한다 — 완료 기록이 생기면 이 기준서의 소스 편집이 막히므로 리뷰 수정은 후속 기준서 아래에서 한다

## 검증 기준

- `grep -c "axis:test" plugins/rein-core/skills/codex-review/SKILL.md` → ≥ 2 (두 축 계약 + 델타 증거 절)
- `grep -c "델타 증거" plugins/rein-core/scripts/rein-codex-review.sh` → ≥ 1 ; `grep -c "구성" …` sub-item 6 단서 존재
- `grep -n "^model:" plugins/rein-core/agents/*.md | wc -l` → 10
- `awk '/^## Unreleased/,/^## v2.2.0/' CHANGELOG.md | grep -c '^- \*\*'` → 6; `grep -c "light 여도 보안 검토 증거는 필수" CHANGELOG.md` → 1
- `wc -c < plugins/rein-core/rules/short/response-tone-summary.md` → ≤ 1800
- `bash tests/scripts/test-ups1-short-rule-injection.sh` → response-tone 크기 항목 통과 + 실패 집합이 기준선과 동일(기존 persona 요약 600 B 초과 1건은 기준선 실패, 범위 밖)
- `bash tests/skills/test-codex-review-claim-audit-policy.sh` → OK
- `bash tests/skills/test-review-doc-mode-slots.sh` → DM8 골든 일치
- `bash tests/agents/test-agent-model-frontmatter.sh` · `bash tests/rules/test-communication-principles.sh` · `bash tests/skills/test-codex-review-delta-evidence.sh` → OK
- `bash tests/hooks/run-all.sh`, `bash tests/rules/run-all.sh`, `bash tests/agents/run-all.sh` → 기준선(변경 전 실행 결과) 대비 실패 집합 동일
- `python3 scripts/rein-check-plugin-drift.py` → exit 0
- `grep -c "security_tier:light 면 면제" plugins/rein-core/agents/feature-builder*.md` → 각 0; `grep -c "light 면제는 폐기됨" plugins/rein-core/rules/routing-procedure.md` → 1; `bash tests/hooks/test-security-tier-gate.sh` 결과 기준선과 동일

## 라우팅 추천

agent: rein:feature-builder
orchestration: main-session-orchestrated
worker_strategy: feature-builder-worker 를 파일 소유권으로 분리해 웨이브 2개(웨이브 1 = edit_only 5태스크 병렬: skill-doc·wrapper-claim-audit·agents-model·tone-ops-rules·model-rules-changelog → 웨이브 2 = close-tests 1태스크, 부모 소유). 설계 문서는 spec-writer/plan-writer. 메인 세션이 Agent 도구로 직접 dispatch(커밋 없이 진행하므로 parallel-execute 스킬 미사용)
skills:
  - rein:codex-review
mcps: []
security_tier: standard      # 에이전트 정의·규칙·리뷰 래퍼 텍스트 = 사용자 프로젝트에 배포되는 plugin surface
complexity: medium
model_hint: sonnet            # 워커(정형 문구 편집·테스트). 설계 문서·검토는 세션 모델
effort_hint: medium
rationale:
  - 새 user-facing 동작(델타 증거 인정·구성 단서·등급 하한·원칙·기본 모델) → feature-builder
  - 파일 소유권이 겹치지 않는 문구 편집 10+개 → 지휘자가 분해·병렬 위임. 코드 리뷰·보안 리뷰·커밋은 이 지시 범위 밖 — 별도 승인 후 Phase 3 에서 부모가 수행(plan 참조)
approved_by_user: true  # "오케이 그렇게 진행하자. 자동모드 켜고 구현테스트까지 진행해" (2026-10-07)

## 범위 연결

plan ref: docs/plans/2026-10-07-review-delta-evidence-and-defaults.md
work unit: Phase 1 / Task 1.1~1.5 (웨이브 1, 병렬 5) + Phase 2 / Task 2.1 (웨이브 2) + 부모 웨이브 close-out. Phase 3(리뷰·커밋)는 별도 승인 후
covers: [RDE-LIGHT-DEAD, RDE-SKILL-AXIS, RDE-SKILL-DELTA, RDE-SKILL-COMPOSE, RDE-WRAP-COMPOSE, RDE-WRAP-DELTA, RDE-WRAP-NOLOGIC, RDE-SEC-FLOOR, RDE-TONE-BODY, RDE-TONE-SUMMARY, RDE-OPS-PRINCIPLES, RDE-MODEL-RULE, RDE-MODEL-HINT, RDE-MODEL-FM, RDE-UNCHANGED, RDE-TESTS, RDE-GOLDEN, RDE-CHANGELOG]

## 변경 파일

- plugins/rein-core/skills/codex-review/SKILL.md
- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- plugins/rein-core/agents/security-reviewer.md
- plugins/rein-core/agents/spec-writer.md
- plugins/rein-core/agents/plan-writer.md
- plugins/rein-core/agents/researcher.md
- plugins/rein-core/agents/orchestrator.md
- plugins/rein-core/agents/feature-builder.md
- plugins/rein-core/agents/feature-builder-fix.md
- plugins/rein-core/agents/feature-builder-refactor.md
- plugins/rein-core/agents/feature-builder-worker.md
- plugins/rein-core/agents/docs-writer.md
- plugins/rein-core/rules/response-tone.md
- plugins/rein-core/rules/short/response-tone-summary.md
- plugins/rein-core/rules/operating-sequence.md
- plugins/rein-core/rules/short/operating-sequence-summary.md
- plugins/rein-core/rules/orchestrator-first.md
- plugins/rein-core/rules/short/orchestrator-first-summary.md
- plugins/rein-core/rules/routing-procedure.md
- tests/scripts/test-ups1-short-rule-injection.sh
- tests/skills/test-codex-review-claim-audit-policy.sh
- tests/fixtures/envelope-code-review.golden
- tests/skills/test-review-evidence-manifest.sh
- tests/agents/run-all.sh
- tests/rules/run-all.sh
- tests/skills/run-all.sh
- tests/agents/test-agent-model-frontmatter.sh
- tests/rules/test-communication-principles.sh
- tests/skills/test-codex-review-delta-evidence.sh
- CHANGELOG.md
- docs/brainstorms/2026-10-07-review-delta-evidence-and-defaults.md
- docs/specs/2026-10-07-review-delta-evidence-and-defaults.md
- docs/plans/2026-10-07-review-delta-evidence-and-defaults.md
- trail/inbox/2026-10-07-review-delta-evidence-and-defaults.md
- trail/index.md
