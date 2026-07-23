# DoD — 페르소나 인사말 다듬기 (언어 적응 + 메타 설명 금지 + jennie 문구)

## 범위

방금 완료한 변경 인사말 기능의 follow-up 3건 (사용자 대화 중 결정):
- **jennie 인사말 교체** — `드디어 오빠! 저 온종일 이 순간만 기다렸어요. 뭐부터 할까요?` (임팩트+설렘, ≤60자).
- **대화 언어 적응 (옵션 B)** — 저장된 `greeting:` 은 정본(내장=한국어). 응답 언어가 정본과 다르면(영어 대화 등) 스킬이 그 언어로 등가 인사말을 낸다(캐릭터·≤60·tone-only·L4-clean 유지). 새 저장 필드·로더 변경 없음 — 적응은 스킬 출력 시점 책임.
- **전환 시 인사말 메타 설명 금지** — 전환 보고 **전체**(인사말·상태 행 모두)에서 "이건 전환 신호다/1회성/다음 세션 적용" 류 메타 서술 금지(상태 행 우회 차단). 인사말 1줄 + 전환 확인 **정확히 1줄**로 끝냄.
- **여러 문장 규칙 명확화 (사용자 승인, 2026-07-23)** — "여러 문장 금지" 를 "장황한 여러 문장 나열·이모지 스팸 금지 + 짧은 다절 인사말은 허용" 으로 명확화. jennie(3절)·boss-ace(2절) 현실과 정합. spec/plan 에도 후속 결정으로 반영.

## 변경 대상 파일

- `plugins/rein-core/rules/persona/jennie.md` — greeting 값 교체.
- `plugins/rein-core/skills/persona/SKILL.md` — 선택 흐름 step 4 에 "대화 언어 적응" 항목 추가 + "출력 예산" 을 메타 설명 금지로 재서술.
- `tests/skills/test-persona-skill.sh` — (g7a~g7j) 정적 계약 assertion 10건(언어 적응·정본·로더 정본 절 보존·전체 메타 금지·다절 허용·정확 1줄 — 변형 회귀 차단).
- `docs/specs/2026-07-23-persona-change-greeting.md` + `docs/plans/2026-07-23-persona-change-greeting.md` — "여러 문장 금지" 를 다절 허용 후속 결정으로 명확화 (dev 문서, main 미포함).

> **변경 파일 총 5개** (기능/가이던스 3: jennie.md · SKILL.md · test-persona-skill.sh + 설계문서 정합 2: spec · plan). 나머지는 trail/DoD 운영 기록.

## 검증 기준

- 새 저장 스키마·로더/lint 로직 변경 없음 — 로더·lint·fence 안전장치 불변(회귀 없음).
- jennie greeting ≤60자·L4-clean·정확 fence — `test-persona-preset-greeting.sh` 통과.
- 스킬 정적 계약 스위트 + 3 러너 GREEN.
- 코드 리뷰 + 보안 리뷰(문서/가이던스·콘텐츠 변경 — 보안 표면 없음 확인).

## 작업 계획

파일 3개 소규모 편집(병렬 불필요, 순차). 부모가 편집·검증·리뷰·커밋. B 는 스킬 지시문 가이던스 변경(런타임 코드 아님) — 정적 계약 테스트로 문구 존재 고정.

## 라우팅 추천

agent: rein:docs-writer
skills: [rein:codex-review, rein:security-reviewer]
mcps: []
security_tier: standard
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - SKILL.md 가이던스 + 프리셋 greeting 콘텐츠 + 테스트 정적 계약 — 로더/보안 로직 불변이라 문서성 변경(docs-writer).
  - 그래도 shipped 파일 변경이라 코드+보안 리뷰 동반.
  - 사용자가 대화 중 3건 각각 명시 승인(문구 8번 확정+꼬리 추가, "B로 가자", 메타 설명 금지 지시).
approved_by_user: true

## 범위 연결

plan ref: docs/plans/2026-07-23-persona-change-greeting.md
design ref: docs/specs/2026-07-23-persona-change-greeting.md
covers: [skill-prepends-target-preset-greeting-on-activate-switch-and-reselect, skill-caps-greeting-plus-status-to-two-short-lines-within-invariant-brevity-cap, builtin-presets-carry-curated-signature-greeting-line-under-60-chars]

## 완료 체크

- [x] jennie greeting 교체 + 검증 테스트 통과
- [x] SKILL.md 언어 적응 + 메타 설명 금지(전체 범위) + 다절 허용 명확화 반영 + spec/plan 정합
- [x] 스킬 정적 계약 (g7a~g7j) 10건 + 변형 검증 + 전 스위트 GREEN
- [x] 코드 리뷰 — codex 3R(R1·R2 Medium 반영, R3 코드결함 0) → 사용자 승인 종결(자체리뷰 도장)
- [x] 보안 리뷰 통과 (차단급 0, 신규 표면 없음, 로더/lint diff 0 재확인)
- [x] inbox/index 기록 (`trail/inbox/2026-07-23-persona-greeting-i18n-polish.md`), 커밋 `88ba9b6`

## 종결 판정 (사용자 승인)

codex 3라운드: R1(Medium 3)·R2(Medium 3) 지적 전량 반영 + 변형 검증으로 회귀 차단 확인. **R3 = 코드 결함 0·런타임 회귀 0** (codex 명시), 잔존은 설계기록 형식뿐. 사용자가 정직한 종결 승인.

**후속(deferred, 비차단 — 이 사이클 미수정)**:
- 언어 적응·전체 메타 금지 전용 measurable Scope ID 를 spec/plan 매트릭스에 신설 (현재는 기존 prepend/cap Scope ID 로 간접 커버 + g7 정적 계약 10건으로 행위 고정).
- spec 헤딩 `## 5. Scope Items` → `## Scope Items` 정규화 (원 사이클부터의 canonical-parse 형식 문제, 이 변경과 무관 — 재발 클래스).
