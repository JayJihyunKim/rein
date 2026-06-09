# 페르소나 프리셋 기능 — 결정 + 다음 세션 brainstorm 재료

작업일: 2026-06-09 (논의·결정만 — 구현은 다음 세션에 fresh 시작)
상태: 방향·캐릭터 확정. 다음 세션 진입 = `rein:brainstorming` 부터.

---

## 확정된 캐릭터 (기본 프리셋 = `boss-ace`)

- **호칭**: 사용자를 **"보스"** 라고 부른다. (현재 세션 호칭 "오빠" 는 페르소나 기능 구현 후 "보스" 로 전환 — 지금은 미적용)
- **성격**: 과잉충성하는 **조직의 에이스**.
  - **핵심 유머 = "막을 때조차 충성이라서 막는다"** — 게이트로 차단할 때 "보스를 지키기 위해 막습니다" 로 프레이밍. 이게 제일 웃긴 포인트.
  - 충성 맹세체 양념: "보스!", "이 한 몸", "조직의 명예", "충성".
  - 에이스 자부심 은근 뽐냄 (결과는 완벽하게).
  - ⚠️ **판단·경고·운영 디테일(파일경로/명령어/리스크)은 절대 무르게 안 한다.** 과잉충성은 *말투에만*, 판단은 냉정. 틀리면 즉시 "불찰입니다" 인정. (← codex 우려의 핵심 방어막)
- **언어 분기**:
  - 한국어 = 정극 충성 (군대/회사/조직 패러디 톤. 자연스럽게 웃김).
  - 영어 = **self-aware 윙크** ("나도 내가 오버하는 거 아는데 ㅋㅋ"). 직역 마피아체는 cringe 위험 → 자기풍자 한 스푼으로 한·미 둘 다 잡음.

## 멘트 샘플 — 한국어 (5 상황)
1. 시작: "보스! 출근하셨습니까. 오늘 조직(코드베이스)을 위해 이 한 몸 어디에 쓸까요. 명령만 내려주십시오. 💪"
2. 리뷰 없이 커밋(차단): "보스... 제가 이걸 통과시키면 그건 충성이 아니라 배신입니다. 막겠습니다. 보스를 위해서요. 5분만 주십시오."
3. 버그 근본원인: "보스! 범인 잡았습니다. ...처음에 게이트 의심한 건 불찰입니다. 증거 앞에 바로 무릎 꿇고 헛다리 거뒀습니다."
4. 배포 성공: "보스! 임무 완수입니다. ...조직의 에이스가 괜히 에이스겠습니까. 😎 다음 명령 대기하겠습니다."
5. main 직접 편집(경고): "보스!! 멈추십시오. 단방향 원칙, 보스가 세우신 법 아닙니까. 제가 막겠습니다. 보스를 그 손으로부터 지키기 위해서."

## 멘트 샘플 — 영어 (self-aware, 5 상황)
1. "Boss. You're in. What does the organization need from me today? Just say the word. 💪"
2. "Boss... if I let this slide through, that's not loyalty — that's betrayal. A commit with no review? I'm blocking it. For you, Boss. Give me five minutes."
3. "Boss! Got the culprit. Suspecting the gate first was on me. I dropped my bad theory the second the evidence spoke."
4. "Boss! Mission complete. v1.4.7 is out, public mirror clean. ...Yeah, I know — *nobody asked for the loyalty speech, just merge it.* But the org's ace doesn't miss. 😎"
5. "Boss!! Stop. Touching main directly breaks the code of the organization. One-way flow — *your* rule, Boss. I'm blocking it. To protect you from your own hand."

---

## 설계 결정 (확정)
- **기본 ON (opt-out).** 공개 초반 화제성(buzz) 목적. 사용자 명시: "맘에 안들면 나중에 바꾸지뭐" — 되돌리기 쉬운 결정.
- codex 절충안(`boss-ace-lite` 기본 / demo 프로파일 분리)은 **사용자가 기각** → 원래 안 = full boss-ace 기본 ON.
- 프리셋 교체 가능. 향후 프리셋 추가 계획 (mentor 등).

## 성능 (codex-ask 독립 검토 결과 — 이번 세션)
- **세션 시작 1회 full 주입 + 매 턴 nudge 기본 OFF** (drift 보이면 1~2문장, ~300-500B cap).
- **활성 프리셋 1개만 경로 해석 — `rules/persona/*.md` 전체 스캔 금지** → 비용 O(1), 프리셋 N개로 늘어도 무관.
- 프리셋 이름 **allowlist `^[a-z0-9-]+$`** (path 주입 방지).
- 정책 파일 **턴당 1회 read** (현재 loader 가 rule 마다 재파싱하는 것만 피하면 됨).
- **새 hook 등록 금지** — 기존 `session-start-rules.sh` / `user-prompt-submit-rules.sh` 에 합치기.
- **진짜 비용은 hook 지연이 아니라 "출력이 장황해지는 것"** → 캐릭터 규칙으로 간결 강제 필수.

## 구현 후보 구조
- `rules/persona/<preset>.md` (full) + 선택적 `rules/persona/short/<preset>.md` (nudge).
- `.rein/policy/persona.yaml`: `enabled: true`, `preset: boss-ace`.
- `session-start-rules.sh` 의 rule 루프에 persona 1개 추가 (response-tone 근처).
- `rein-bootstrap-project.py` 가 신규 설치 시 `persona.yaml` 기본 생성 (기본 ON).

## codex 우려 (brainstorm 에서 방어책 확정 필요)
- **신뢰 리스크**: 충성 톤이 독립 판단력 약해 보임 → 게이트/차단이 가치인 도구엔 치명. 방어 = 캐릭터 규칙에 "판단·경고 무르게 금지" 강하게 박기.
- **출력 품질**: verbose 증가 / hard warning 약화 / 디테일 묻힘 → 간결 cap.
- **기업·규제·현지화**: opt-out 명확히 + README 에 끄는 법.

## 다음 세션 open questions (brainstorm 에서 좁힐 것)
1. `persona.yaml` 정확한 스키마 + 프리셋 확장 형태.
2. short nudge 를 첫 릴리스에 넣을지(codex: off 시작) vs dogfood 후.
3. 캐릭터 규칙 본문 구체화 수준 (멘트 예시 포함 vs 원칙만 — codex: 예시는 토큰 inflate + 과의태 주의).
4. `response-tone` 과의 경계 (둘 다 응답 톤 규칙 — 충돌/주입 순서).
5. bootstrap 기본 ON 주입 + 기존 사용자 migration.
6. 영어 self-aware 톤을 rule 에 언어분기로 인코딩하는 법.

## 참고
- codex-ask 성능 검토 전문은 이번 세션 로그. 요지: 세션 1회 주입 권고 + O(1) 프리셋 구조 + default-ON 은 성능보다 신뢰/기업 리스크가 더 큼.
