# Response Tone

## 행동 강령

사용자에게 보이는 모든 답변에 다음 4 항목을 적용한다.

1. **내부 식별자 사용 금지** — `stamp`, `verdict`, `handoff`, `.codex-reviewed`, `.security-reviewed`, `.review-pending`, `approved_by_user`, `security_tier`, 파일 경로 해시, Scope ID (G3, SR-1 등), PLN-1·AG-2 같은 단축 코드를 채팅 본문에 노출하지 않는다. 아래 `## 번역 테이블` 로 평문화한다. 변경한 파일 경로·명령어·코드 블록은 사용자가 검증·복사할 수 있어야 하므로 원형 보존.
2. **보고 문장 구조** — 완료·진행 보고는 "방금 한 것 → 결과 → 다음 단계" 흐름. 결과 1-2문장 + 다음 단계 1문장이 기본 길이.
3. **질문 형식** — 사용자 확인을 받을 때 내부 식별자 (`approved_by_user`, `security_tier` 등) 를 질문 본문에 넣지 않는다. "이 조합으로 진행할까요?" / "보안 검토를 간소화할까요?" 같이 평문.
4. **trail 파일 인용** — `MEMORY.md` / `trail/index.md` / `trail/inbox/` / `trail/dod/` 본문을 그대로 붙여넣지 않는다 — 평문 재진술.

답변을 보내기 전 `## 답변 직전 self-check` 의 4 항목을 다시 훑는다. 적용 대상·예외·원형 보존 항목은 `## 적용 범위` 참조.

## 번역 테이블 (내부 → 사용자 언어)

| 내부 표현 | 사용자 언어 |
|---|---|
| stamp 생성됨 | 검토 완료 표시를 남겼습니다 |
| codex-reviewed stamp | 코드 리뷰 완료 표시 |
| security-reviewed stamp | 보안 검토 완료 표시 |
| review-pending stamp | 검토 대기 표시 |
| PASS / NEEDS-FIX / REJECT | 통과 / 수정 필요 / 반려 |
| handoff to subagent | 다음 단계로 넘어가겠습니다 |
| DoD 작성 | 작업 기준서를 작성합니다 |
| trail/index.md | 현재 프로젝트 상태 기록 |
| trail/inbox/ | 작업 완료 기록 |
| approved_by_user: true | 사용자 승인 완료 |
| security_tier: light / standard / deep | 보안 검토 강도: 가벼움 / 표준 / 깊음 |
| pre-edit-dod-gate / pre-bash-test-commit-gate | 편집 차단 / 커밋 차단 |
| .pending → .reviewed | 검토 대기 → 검토 완료 |

## 보고 문장 구조

완료·진행 보고는 다음 흐름을 따른다:

1. **방금 한 것** — 평문 1문장
2. **결과** — 성공 / 실패 / 보류
3. **다음 단계** — 무엇을 할 것인지

예: "plan 파일을 작성하고 커버리지를 검증했습니다. 모든 항목이 통과됐으니 이제 구현을 시작하겠습니다."

차단·실패 보고는 위 구조를 유지하되 "왜 멈췄나" 1문장 + "무엇을 해결해야 풀리나" 1문장으로 대체한다.

## 질문 형식

사용자에게 확인을 요청할 때 내부 식별자를 질문 본문에 포함하지 않는다.

- 금지: "라우팅 추천에서 approved_by_user 를 true 로 설정할까요?"
- 권장: "이 조합으로 진행할까요?"

- 금지: "security_tier 를 light 로 내리고 .security-reviewed stamp 면제할까요?"
- 권장: "보안 검토를 간소화할까요? (auth/crypto 변경 없는 경우만)"

## trail 파일 인용

`MEMORY.md` / `trail/index.md` / `trail/inbox/` / `trail/dod/` 의 본문을 사용자 답변에 인용할 때 **원본 한 줄을 그대로 붙여넣지 않는다.** 반드시 평문으로 풀어쓴다.

- 금지: "trail/index.md 에 따르면: `**2026-05-28 회고 (worker contract + PLN1 enforce, dev ca80d88)**: AG-2 dogfood 후속으로 …`"
- 권장: "지난 회고 기록을 보면 2026-05-28 에 worker contract 와 PLN1 강제 적용을 한 cycle 로 묶어 마쳤습니다. (이하 평문 요약 …)"

## 답변 직전 self-check

답변을 보내기 전에 본문을 다시 한 번 훑어 다음을 확인한다:

- [ ] 내부 식별자가 평문으로 번역되었나? (`## 번역 테이블` 적용)
- [ ] 보고 문장이 "방금 한 것 → 결과 → 다음 단계" 구조인가?
- [ ] trail 파일 원문이 그대로 인용되지 않았나?
- [ ] 질문에 내부 식별자가 들어가지 않았나?

## 적용 범위

- **적용 대상**: 사용자에게 보이는 텍스트 (chat 본문).
- **적용 제외**: tool call payload, hook envelope, DoD/inbox/index 같은 trail 파일의 본문 (운영 기록이라 원형 보존).
- **원형 보존**: 변경한 파일 경로·명령어·코드 블록·외부 식별자 (라이브러리 이름, 깃 commit hash 등) 는 사용자가 검증·복사할 수 있어야 하므로 그대로 둔다. **marker file 경로 자체** (`trail/dod/.codex-reviewed`, `.review-pending`, `.security-reviewed`) 도 hook 가 작동에 필요한 식별자라 본문에서 보존하되, 의미는 평문으로 병기한다 (예: "코드 리뷰 완료 표시 파일 (`trail/dod/.codex-reviewed`)" 형태).
- **답변 길이**: 결과 1-2문장 + 다음 단계 1문장이 기본. 헤더·표는 정보 밀도가 정말 필요할 때만.

## Output Language

Respond in the language of the user's latest message. Follow any higher-priority system/developer/harness language instruction first (e.g. a Claude Code language preference); otherwise the language the user explicitly requested; otherwise the dominant natural language of the latest user message. Do not infer the response language from repo documentation, injected rein rules, or trail notes — follow the user, not the repository.

Edge cases:

- **Mixed-language message** — use the explicitly requested output language if any, else the dominant natural language of the latest message.
- **Code-only / identifier-only message** — keep the prior conversation language.
- **Language switch mid-session** — follow the latest user message.
- **Non-English / non-Korean user** — use that user's language; do not default to English or Korean.

This rule governs response language only; the plain-language and reporting rules above still apply within whatever language is chosen.
