# DoD: 계획서·웨이브 실행의 검증 비용 규칙 — 같은 코드 상태 전체 검사 1회, 수정 후 대상 테스트만

- 작성일: 2026-10-14
- plan ref: docs/plans/2026-10-14-plan-verification-cost.md
- 계기: 사용자 프로젝트에서 rein 계획서(계약 r2)가 35분짜리 전체 검사를 리허설 한 번에 여러 번 지시하고, 작은 수정에도 1단계부터 재검증하도록 쓰여 실행 에이전트가 그대로 따랐다(사용자 전달 에이전트 보고, 2026-10-14). v2.3.0·v2.4.0 은 **리뷰 회차**의 테스트 범위만 줄였고(델타 증거·선택 도구), 계획서가 검증 절차를 독립적으로 쓰는 단계와 웨이브 barrier 의 "테스트" 는 범위 규정이 없었다.
- 실측한 원인 표면(2026-10-14):
  - `plugins/rein-core/docs/writing-plans-procedure.md` 계획 템플릿의 Task Step 5 `Verify: all prior tests still pass` — 모든 Task 가 전체 재검증을 지시.
  - `plugins/rein-core/agents/plan-writer.md` 에 검증 비용·범위 규칙 부재.
  - `plugins/rein-core/skills/parallel-execute/SKILL.md` barrier 5 "웨이브 단위 1회 포맷/린트/테스트" 와 `plugins/rein-core/agents/orchestrator.md` barrier 2 "웨이브/작업 단위로 포맷·린트·테스트" — 테스트 범위 미규정.
  - 계획 문서 리뷰 봉투(`rein-codex-review.sh` `_emit_doc_review_slots`)에 검증 비용 관점 없음 — 과한 절차가 설계 검토를 통과.
  - 실행자 규율 부재 — 승인된 계획서의 반복 전체 검사를 실행 중 멈추고 계획서 수정을 제안하는 조항 없음.
- 사용자 결정(채팅 2026-10-14): "자동모드 켜고 설계 구현해서 배포까지 진행해". 직전 평가에서 합의한 방향 — (1) 규칙은 저장소 AGENTS.md 가 아니라 플러그인의 계획서 작성 에이전트·절차에 둔다(사용자 프로젝트까지 고쳐짐), (2) 계획 문서 리뷰에 검증 비용 체크를 더한다, (3) 실행자는 계획서를 조용히 덮어쓰지 않고 멈춰 수정을 제안한다, (4) 소요 시간은 이전 실행 기록이 있을 때만 적고 없으면 "미측정" — 범위 추정 값도 쓰지 않는다(spec 설계 검토 1회차에서 3단계 표기가 이 결정과 어긋난다고 지적돼 2값으로 환원).
- 설계 검토 1회차 반영(2026-10-15): codex 불가 시 대체 리뷰어(`code-reviewer` 스킬)의 계획 문서 리뷰에도 같은 검증 비용 판정 계약을 넣는다(범위 밖 → IN 8). 매 세션 요약 두 문장은 훅 JSON 한 줄 상한(10,000자, 현재 9,738자)에 맞춰 영문 ASCII 로 확정(두 문장 모두 복귀 조건 예외 구절 포함, 추가 JSON 239자 → 9,977자; 규칙 주입 5,828 → 6,066 B). 복귀 조건(`codex-review` 스킬 "전체 테스트 재실행으로 돌아가는 조건")을 명시한 재실행은 모든 표면(계획 작성·리뷰 슬롯·대체 리뷰어·실행자 조항)에서 위반이 아니다.
- 등급(versioning Rule A): 계획 리뷰에 새 수정 필요 사유가 추가되어 종전 PASS 가 NEEDS-FIX 가 될 수 있음 → 문자 그대로는 차단 범위 확대(major 후보). 사용자 승인 예외 세 조건 중 종료 코드·채널 불변, 고칠 Step 안내는 충족하나 **"비용 비소모" 는 재리뷰 회차 소모로 미충족**(codex-ask Q7·spec 설계 검토 1회차 동일 판정). **사용자가 2026-10-15 채팅에서 이를 안 상태로 minor(v2.5.0) 를 명시 결정**(제시 선택지: major v3.0.0 / minor 예외 / 참고사항 전용 슬롯). 사유는 여기와 trail 완료 기록에 남긴다(CHANGELOG 에는 쓰지 않음). 현 규범(세 조건 "모두" 충족 시 사용자 결정)은 이 결정을 담지 못하므로 `.claude/rules/versioning.md` 에 "세 조건 미충족 시 사용자 명시 override" 하위 절(네 가지 기록 조건 + v2.5.0 첫 전례)을 신설한다 — 기존 세 조건 문단은 불변. Rule B: 직전 main 병합 2026-10-11.

## 범위

IN
1. 계획 작성 절차(`writing-plans-procedure.md`)에 `## 검증 비용 규칙` 신설 + 템플릿 Task Step 의 전체 재검증 지시 교체 + Self-review 항목 추가.
2. `plan-writer.md` 에 검증 비용 절(요지 + 절차 문서 참조).
3. `parallel-execute/SKILL.md` barrier 5 와 `orchestrator.md` barrier 2 의 테스트 범위 규정(웨이브 델타가 닿는 테스트, 전체 스위트는 기준 1회 + 최종 1회 + 복귀 조건 — `codex-review/SKILL.md` "전체 테스트 재실행으로 돌아가는 조건" 참조).
4. 리뷰 래퍼 문서 봉투에 검증 비용 슬롯 추가(두 사본 바이트 동일). 코드 봉투 바이트 불변.
5. `rules/short/testing-summary.md` + `rules/testing.md` 에 검증 실행 범위 한 문단, `rules/operating-sequence.md` 작업 운영 원칙에 실행자 조항 + 요약.
6. 테스트: 신규 `tests/agents/test-plan-verification-cost.sh`(문구 고정) + `tests/skills/test-review-doc-mode-slots.sh` 확장(문서 모드 슬롯 방출·코드 모드 미방출) + 러너 편입.
7. CHANGELOG `## v2.5.0`, 버전(`scripts/rein.sh`·plugin.json) 2.5.0, README EN/KO 릴리스 히스토리, dev 병합, main 선별 반영, 태그, 미러·발행 워크플로, GitHub Release.
8. 대체 리뷰어(`skills/code-reviewer/SKILL.md` spec-review fallback 분기)의 plan 리뷰에 래퍼 슬롯과 같은 검증 비용 판정 계약(위반 2종 + 복귀 조건 예외 + 이전 기록 없는 소요 수치 NEEDS-FIX + 표기 누락 참고) 추가 + 메인테이너 `.claude/rules/versioning.md` 에 세 조건 미충족 시 사용자 명시 override 하위 절 신설(v2.5.0 첫 전례).

OUT
- 선택 도구(`rein-affected-tests.py`) 변경, 리뷰 회차 델타 증거 규칙 변경(v2.3.0·v2.4.0 그대로 — 이번 규칙은 그 조건을 참조만 한다), 래퍼의 계획서 자동 검사(정적 판정은 리뷰어 몫), 기존 로컬 실패 스위트 정리.

## 변경 파일

- plugins/rein-core/docs/writing-plans-procedure.md
- plugins/rein-core/agents/plan-writer.md
- plugins/rein-core/agents/orchestrator.md
- plugins/rein-core/skills/parallel-execute/SKILL.md
- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- plugins/rein-core/rules/testing.md
- plugins/rein-core/rules/short/testing-summary.md
- plugins/rein-core/rules/operating-sequence.md
- plugins/rein-core/rules/short/operating-sequence-summary.md
- plugins/rein-core/skills/code-reviewer/SKILL.md
- .claude/rules/versioning.md
- tests/agents/test-plan-verification-cost.sh
- tests/agents/run-all.sh
- tests/skills/test-review-doc-mode-slots.sh
- tests/skills/test-parallel-execute-skill.sh
- CHANGELOG.md
- scripts/rein.sh
- plugins/rein-core/.claude-plugin/plugin.json
- README.md
- README.ko.md
- docs/brainstorms/2026-10-14-plan-verification-cost.md
- docs/specs/2026-10-14-plan-verification-cost.md
- docs/plans/2026-10-14-plan-verification-cost.md

## Definition of Done

- [ ] brainstorm(codex-ask 전제 점검) → spec(설계 검토 통과) → plan(커버리지 검증·설계 검토 통과)
- [ ] 구현 — 위 변경 파일, 코드 봉투 골든 바이트 불변, 루트 래퍼 사본 바이트 동일
- [ ] 신규·확장 테스트가 변경 전 실패·변경 후 통과, 영향받는 스위트(agents·skills·rules·hooks 세션 시작) 회귀 없음, 변경 전 트리와 실패 집합 동일
- [ ] 코드 리뷰·보안 리뷰 통과 → 커밋 → dev 병합·push
- [ ] 릴리스 v2.5.0: 태그 전 macOS 포함 CI 성공, main 선별 반영·태그·공식 미러·발행 성공, GitHub Release Latest
- [ ] 완료 기록·index 갱신

## 검증 기준

- `grep -c "all prior tests still pass" plugins/rein-core/docs/writing-plans-procedure.md` = 0
- `grep -c "근거 있는 범위 추정" plugins/rein-core/docs/writing-plans-procedure.md plugins/rein-core/rules/testing.md` 각 0 (사용자 결정: 이전 기록 있을 때만 수치, 없으면 미측정)
- `bash tests/agents/test-plan-verification-cost.sh` exit 0, `bash tests/skills/test-review-doc-mode-slots.sh` exit 0
- `bash tests/skills/test-review-envelope-reduction.sh` exit 0(코드 봉투 골든 불변), `bash tests/skills/test-parallel-execute-skill.sh` exit 0(본문 크기 상한 6144→7168 B — 구현 검증에서 발견, 사용자 결정 2026-10-15), `cmp scripts/rein-codex-review.sh plugins/rein-core/scripts/rein-codex-review.sh` 동일
- `bash tests/agents/run-all.sh`, `bash tests/rules/run-all.sh`, `bash tests/hooks/test-session-start-rules.sh`, `bash tests/hooks/test-session-start-byte-budget.sh`, `bash tests/hooks/test-orchestrator-first-emit.sh` exit 0
- `bash tests/scripts/test-ups1-short-rule-injection.sh` 와 `bash tests/skills/run-all.sh` 는 실패 집합이 기준 트리(`7cb51d5`)와 동일: ups1 persona-summary 1건, skills evidence-manifest 4건 + persona greeting 1건(기존 실패, 범위 밖)
- `python3 scripts/rein-check-plugin-drift.py` exit 0
- 릴리스: `grep '^VERSION="2.5.0"' scripts/rein.sh`, plugin.json 2.5.0, `git ls-remote --tags https://github.com/JayJihyunKim/rein.git v2.5.0` 1건, `gh release list --repo JayJihyunKim/rein --limit 2` 에 v2.5.0 Latest

## 라우팅 추천

agent: rein:feature-builder
orchestration: main-session-orchestrated
worker_strategy: 설계는 rein:spec-writer·rein:plan-writer, 구현은 plan `## 실행 전략` 대로 edit_only 워커(rein:feature-builder-worker), 보안 검토는 rein:security-reviewer 워커. 검증·리뷰·커밋·병합·릴리스는 부모.
skills:
  - rein:brainstorming
  - rein:codex-ask
  - rein:codex-review
  - rein:parallel-execute
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 에이전트·절차·규칙 문서와 래퍼 heredoc 문구 변경 + 래퍼에 문자열 상태 변수 1개(`SPEC_REVIEW_KIND`, 리터럴 plan|design 만 대입)와 plan 전용 조건 분기 1개 — 명령·경로 확장 없음, 코드 봉투 바이트 불변, 문구 고정 테스트로 잠금
  - 래퍼는 위험 경로(scripts/rein-*.sh)라 리뷰는 전체 검토
approved_by_user: true  # "자동모드 켜고 설계 구현해서 배포까지 진행해" (2026-10-14)
