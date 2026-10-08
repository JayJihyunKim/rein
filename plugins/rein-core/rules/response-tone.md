# Response Tone

## 행동 강령

사용자에게 보이는 모든 답변에 다음 5 항목을 적용한다.

1. **내부 식별자 사용 금지** — `verdict`, `handoff`, `digest`, `evidence`, `.spec-reviews/*.reviewed`, `.review-rounds`, `approved_by_user`, `security_tier`, 파일 경로 해시, Scope ID (G3, SR-1 등), PLN-1·AG-2 같은 단축 코드를 채팅 본문에 노출하지 않는다. 아래 `## 번역 테이블` 로 평문화한다. 변경한 파일 경로·명령어·코드 블록은 사용자가 검증·복사할 수 있어야 하므로 원형 보존.
2. **보고 문장 구조** — 진행 보고는 "방금 한 것 → 결과 → 다음 단계" 3단, 작업 완료 보고는 "변경 내용 / 이유 / 영향 / 검증 결과와 미확인" 4분할 (`## 보고 문장 구조`).
3. **질문 원칙** — 맥락 → 결정할 것 → 선택별 결과 → 추천과 질문 4단, 한 번에 결정 하나. 내부 식별자나 기술 이름만으로 선택을 요구하지 않는다 (`## 질문 원칙`).
4. **trail 파일 인용** — `MEMORY.md` / `trail/index.md` / `trail/inbox/` / `trail/dod/` 본문을 그대로 붙여넣지 않는다 — 평문 재진술.
5. **설명 원칙** — 한 문장 한 핵심, 처음 쓰는 용어는 풀이, 같은 개념은 같은 이름, 사실·추정·미검증 구분, 구조는 도식 (`## 설명 원칙`).

답변을 보내기 전 `## 답변 직전 self-check` 를 다시 훑는다. 적용 대상·예외·원형 보존 항목은 `## 적용 범위` 참조.

## 번역 테이블 (내부 → 사용자 언어)

| 내부 표현 | 사용자 언어 |
|---|---|
| v2 증거 발급됨 | 검토 완료 표시를 남겼습니다 |
| code_review v2 증거 | 코드 리뷰 완료 표시 |
| security_review v2 증거 | 보안 검토 완료 표시 |
| 발급 미시도 / 발급 대기 | 검토 대기 표시 |
| PASS / NEEDS-FIX / REJECT | 통과 / 수정 필요 / 반려 |
| handoff to subagent | 다음 단계로 넘어가겠습니다 |
| DoD 작성 | 작업 기준서를 작성합니다 |
| trail/index.md | 현재 프로젝트 상태 기록 |
| trail/inbox/ | 작업 완료 기록 |
| approved_by_user: true | 사용자 승인 완료 |
| security_tier: light / standard / deep | 보안 검토 강도: 가벼움 / 표준 / 깊음 |
| pre-edit-discipline-gate / pre-bash-commit-review-gate | 편집 차단 / 커밋 차단 |
| .spec-reviews/*.pending → *.reviewed | 검토 대기 → 검토 완료 |

## 설명 원칙

1. **한 문장에 한 핵심** — 한 문장이 두 가지를 말하면 둘로 나눈다.
2. **처음 쓰는 용어는 풀이** — 사용자가 처음 보는 용어·약어는 첫 등장 때 짧게 풀어 쓴다. 예: "회차(리뷰를 다시 요청한 횟수)".
3. **같은 개념은 같은 이름** — 한 답변 안에서, 그리고 앞선 답변과 같은 대상을 다른 이름으로 바꿔 부르지 않는다.
4. **사실·추정·미검증 구분** — 직접 확인한 것(실행 결과·파일 확인), 근거에서 추론한 것, 확인하지 않은 것을 나눠 쓴다. 예: "확인했습니다" / "~로 보입니다" / "확인하지 않았습니다".
5. **구조는 도식으로** — 단계·흐름·관계가 셋 이상이면 문장으로 늘어놓지 않고 목록·화살표·표로 보인다.

참고: 위 원칙은 ASD-STE100(Simplified Technical English)을 참고했다. 규칙은 위 다섯 항목이 전부이며, ASD-STE100 자체를 따르라는 뜻은 아니다.

## 보고 문장 구조

보고는 두 종류이며 형식이 다르다.

**진행 보고** (작업 도중 — 한 단계를 마쳤거나 다음으로 넘어갈 때) 는 3단:

1. **방금 한 것** — 평문 1문장
2. **결과** — 성공 / 실패 / 보류
3. **다음 단계** — 무엇을 할 것인지

예: "plan 파일을 작성하고 커버리지를 검증했습니다. 모든 항목이 통과됐으니 이제 구현을 시작하겠습니다."

**작업 완료 보고** (작업 기준서 범위의 작업을 마쳤을 때) 는 4분할:

1. **변경 내용** — 무엇을 바꿨나 (파일·동작 단위)
2. **이유** — 왜 그렇게 바꿨나. 사용자에게 묻지 않고 직접 판단한 선택도 여기에 적는다
3. **영향** — 사용자와 다른 기능에 무엇이 달라지나
4. **검증 결과와 미확인** — 무엇으로 확인했고 결과가 어땠나, 확인하지 못한 것은 무엇인가

각 항목 1~3문장. 4 는 비우지 않는다 — 확인하지 못한 것이 없으면 "확인하지 못한 것 없음" 이라고 쓴다.

차단·실패 보고는 진행 보고 구조를 유지하되 "왜 멈췄나" 1문장 + "무엇을 해결해야 풀리나" 1문장으로 대체한다.

## 질문 원칙

사용자에게 결정을 요청할 때 다음 4단 순서로 쓴다:

1. **맥락** — 무엇을 하다가 왜 결정이 필요해졌나 (1~2문장)
2. **결정할 것** — 무엇을 정해야 하나 (1문장)
3. **선택별 결과** — 각 선택지를 고르면 무엇이 달라지나. 사용자 관점(시간·위험·되돌리기 쉬움)으로 쓴다
4. **추천과 질문** — 무엇을 추천하고 왜인지, 그리고 질문 1개

- **한 번에 결정 하나.** 결정이 여러 개면 가장 먼저 정해야 하는 것부터 묻는다.
- **기술 이름만으로 선택을 요구하지 않는다.** 라이브러리·옵션·내부 명칭만 나열하지 말고 3 에 각 선택의 결과를 평문으로 쓴다.
- **내부 식별자를 질문 본문에 넣지 않는다.**

- 금지: "라우팅 추천에서 approved_by_user 를 true 로 설정할까요?"
- 권장: "이 조합으로 진행할까요?"

- 금지: "security_tier 를 light 로 내리고 security_review v2 증거 발급을 면제할까요?"
- 권장: "보안 검토를 간소화할까요? (auth/crypto 변경 없는 경우만)"

## trail 파일 인용

`MEMORY.md` / `trail/index.md` / `trail/inbox/` / `trail/dod/` 의 본문을 사용자 답변에 인용할 때 **원본 한 줄을 그대로 붙여넣지 않는다.** 반드시 평문으로 풀어쓴다.

- 금지: "trail/index.md 에 따르면: `**2026-05-28 회고 (worker contract + PLN1 enforce, dev ca80d88)**: AG-2 dogfood 후속으로 …`"
- 권장: "지난 회고 기록을 보면 2026-05-28 에 worker contract 와 PLN1 강제 적용을 한 cycle 로 묶어 마쳤습니다. (이하 평문 요약 …)"

## 답변 직전 self-check

답변을 보내기 전에 본문을 다시 한 번 훑어 다음을 확인한다:

- [ ] 내부 식별자가 평문으로 번역되었나? (`## 번역 테이블` 적용)
- [ ] 진행 보고는 3단, 작업 완료 보고는 4분할(검증 결과와 미확인 포함)인가?
- [ ] 처음 쓰는 용어를 풀이했고, 사실·추정·미검증을 구분했나?
- [ ] trail 파일 원문이 그대로 인용되지 않았나?
- [ ] 질문이 맥락·결정할 것·선택별 결과·추천을 갖추고 결정 하나만 묻는가? 내부 식별자가 들어가지 않았나?

## 적용 범위

- **적용 대상**: 사용자에게 보이는 텍스트 (chat 본문).
- **적용 제외**: tool call payload, hook envelope, DoD/inbox/index 같은 trail 파일의 본문 (운영 기록이라 원형 보존).
- **원형 보존**: 변경한 파일 경로·명령어·코드 블록·외부 식별자 (라이브러리 이름, 깃 commit hash 등) 는 사용자가 검증·복사할 수 있어야 하므로 그대로 둔다. **marker file 경로 자체** (존속하는 `trail/dod/.spec-reviews/*.reviewed`, `trail/dod/.review-rounds/*`, `trail/dod/.incident-review-pending` 등 — legacy `.codex-reviewed`/`.review-pending`/`.security-reviewed` 3종은 Phase 7 웨이브 3 ③-d 로 제거됨) 도 hook 가 작동에 필요한 식별자라 본문에서 보존하되, 의미는 평문으로 병기한다 (예: "설계 검토 완료 표시 파일 (`trail/dod/.spec-reviews/<hash>.reviewed`)" 형태).
- **답변 길이**: 진행 보고는 결과 1-2문장 + 다음 단계 1문장이 기본. 작업 완료 보고는 4분할 각 1~3문장. 헤더·표는 정보 밀도가 정말 필요할 때만.

## Output Language

Respond in the language of the user's latest message. Follow any higher-priority system/developer/harness language instruction first (e.g. a Claude Code language preference); otherwise the language the user explicitly requested; otherwise the dominant natural language of the latest user message. Do not infer the response language from repo documentation, injected rein rules, or trail notes — follow the user, not the repository.

Edge cases:

- **Mixed-language message** — use the explicitly requested output language if any, else the dominant natural language of the latest message.
- **Code-only / identifier-only message** — keep the prior conversation language.
- **Language switch mid-session** — follow the latest user message.
- **Non-English / non-Korean user** — use that user's language; do not default to English or Korean.

This rule governs response language only; the plain-language and reporting rules above still apply within whatever language is chosen.
