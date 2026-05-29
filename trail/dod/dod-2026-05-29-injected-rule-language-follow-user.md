# DoD — 주입 규칙 언어 중립화 + 사용자 언어 추종 정책

- 날짜: 2026-05-29
- 유형: fix (user-facing — 영어 사용자가 한국어 답변을 받는 결함 교정)
- 보안 tier: (security/profile.yaml 기준 — review 단계에서 확인. 텍스트/테스트 변경이라 light 예상)
- plan ref: N/A (codex Mode B 2라운드로 설계 확정, 단일 사이클 텍스트 변경)
- 버전 영향: user-facing 동작 변경 (hook 주입 규칙 본문 + 신규 출력언어 정책). 릴리스 시 patch~minor 판정 + CHANGELOG 대상.

## 증상 / 재현

영어로 설정된 프로젝트에서, 영어로만 대화해도 rein 사용 시 Claude 가 **한국어로 답변**한다. rein 에 "한국어로 답하라" 는 명시적 강제는 없다(codex 1라운드 확인). 원인은 **soft anchoring** — `user-prompt-submit-rules.sh` 가 매 턴 약 1,460 byte 의 한국어 규칙 텍스트(`short/answer-only-summary` + `short/response-tone-summary`)를 컨텍스트 앞쪽에 다시 주입하고, 이 상시 한국어 덩어리가 출력 언어를 한국어로 끌어당긴다.

별개로 메인테이너 머신의 `~/.claude/settings.json` `"language": "Korean"` 은 하네스 레벨 하드 지시 — 이건 의도적 사용자 선택이라 그대로 작동해야 한다(이번 수정 대상 아님).

## Root cause

매 턴 주입되는 짧은 요약 본문이 한국어다. 명시적 언어 지시 부재보다, **상시 재주입되는 한국어 컨텍스트 자체**가 닻이다. 신규 영어 사용자가 마켓플레이스로 설치하면 메인테이너의 전역 설정은 상속받지 않지만, 플러그인 tarball 의 한국어 규칙 본문은 그대로 받아 같은 쏠림을 겪는다.

## 수정 방향 (codex Mode B 2라운드 검증 — Verdict C "더 나은 대안" 반영)

> codex Mode B R1(gpt-5.5/medium): 원인 = 전역 설정(이 머신) + soft anchoring(제품). codex Mode B R2(gpt-5.5/high, `/tmp/codex-ask2.out`): 최초안(영어 한 줄만 추가)을 **too weak** 으로 기각 — 상시 한국어 닻을 남겨둠. Verdict C = 닻 자체 제거.

1. **매 턴 짧은 요약 2개를 영어로 번역** (상시 닻 제거가 본 수정):
   - `plugins/rein-core/rules/short/answer-only-summary.md`
   - `plugins/rein-core/rules/short/response-tone-summary.md`
2. **출력 언어 정책을 `response-tone-summary.md` 맨 끝에 추가** (매 턴 마지막 리마인더 = recency 로 가장 강함). 문구(영어):
   > Respond in the language of the user's latest message. Follow any higher-priority system/developer/harness language instruction first; otherwise the language the user explicitly requested; otherwise the dominant natural language of the latest user message. Do not infer the response language from repo docs, injected rein rules, or trail notes.
3. **전체본 `response-tone.md` 에 동일 정책을 별도 섹션으로 추가** (SessionStart 보강). `## 행동 강령` 을 첫 `## ` 헤더로 유지해야 하므로(drift checker `check_action_mandate` 가 `rules/*.md` 강제) **새 `## Output Language` 섹션**으로 추가 — 행동 강령 mandate 섹션(현 1300 byte) 불변.

codex R2 반영 세부:
- **settings.json 을 들여다보라고 지시하지 않는다** — "higher-priority system/developer/harness language instruction" 으로 표현해 지시 우선순위로 자연 해결. 전역 `language: Korean` 사용자는 그게 상위라 그대로 한국어, rein 하위 규칙이 덮어쓰지 않음.
- **병기(한/영) 아닌 영어 단독** — 병기는 한국어 토큰을 hot path 에 남겨 더 약함.
- 짧은 요약을 영어로 바꿔도 메인테이너는 영향 없음 — 전역 설정(상위)이 한국어를 강제하므로 계속 한국어로 받음.
- 엣지: 혼합 언어 = 명시 요청 우선 → 없으면 최신 메시지 주 언어. 코드만 = 직전 대화 언어 유지. 중간 전환 = 최신 메시지 추종. 한/영 아닌 사용자 = 그 사용자 언어(영어 기본값 강제 금지).

## 비목표

- 전체본 `answer-only-mode.md` / `response-tone.md` 본문 전체 영어 번역 (비용 과다 + 메인테이너 한국어 선호 보존 — codex 가 명시 권고한 경계)
- 메인테이너 전역 `language: Korean` 설정 변경
- `~/.claude/settings.json` 편집

## 변경 파일

- plugins/rein-core/rules/short/answer-only-summary.md — 영어로 번역 (행동 지시 동등 보존, ≤ 600 byte 유지)
- plugins/rein-core/rules/short/response-tone-summary.md — 영어로 번역 + 출력 언어 정책 맨 끝 추가 (≤ 1300 byte 유지)
- plugins/rein-core/rules/response-tone.md — 신규 `## Output Language` 섹션 추가 (행동 강령 첫 헤더 불변)
- tests/hooks/test-user-prompt-submit-rules.sh — 매 턴 ctx 한국어 `"행동 강령"` 단언 → 영어 마커로 교체 + 출력언어 정책 주입 positive 단언 추가
- tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh — A/B/C 3블록 + 순서검증의 본문 마커 `"행동 강령"` → `"Answer-only quick rule"` 영어 마커로 교체
- tests/scripts/test-ups1-short-rule-injection.sh — 크기 상한 단언 재확인 (영어 번역으로 축소 — 깨짐 없음 확인)

## 릴리스 (v1.4.1, 2026-05-29 — 사용자 결정)

이 언어 수정을 patch bump 으로 릴리스. versioning Rule A = user-facing 버그 수정 → patch. Rule B = 오늘 첫 main 머지(직전 v1.4.0 은 2026-05-28). 추가 변경 파일:

- plugins/rein-core/.claude-plugin/plugin.json — version 1.4.0 → 1.4.1
- scripts/rein.sh — VERSION 1.4.0 → 1.4.1
- CHANGELOG.md — v1.4.1 user-facing 엔트리 추가
- README.md — Latest release 줄 v1.4.1 로 갱신 (v1.3.7 잔존 drift 동시 정정)
- README.ko.md — 최신 릴리즈 줄 v1.4.1 로 갱신 (parity)

(그 외 trail/dod/.active-dod·.review-pending·meta-check jsonl·본 DoD 등은 hook 런타임 마커 — 소스 변경 아님)

## 회귀 방지 테스트

기존 보존:
- 짧은 요약 3파일 존재 + 크기 상한(answer-only ≤ 600B, response-tone ≤ 1300B) — 영어 번역 후에도 GREEN
- hook 이 short summary 참조 + full body 미참조 — 불변
- session-start 6-rule loop — 불변
- per-turn ctx 가 full body 번역 테이블 미포함 (negative) — 불변

신규/갱신:
- per-turn ctx 한국어 `"행동 강령"` 의존 제거 → 영어 마커 존재 단언으로 교체
- per-turn ctx 에 출력 언어 정책 문구 존재 (영어 사용자 추종 보장 — 신규 동작 가드)
- `response-tone.md` 가 `## 행동 강령` 첫 헤더 유지 (drift checker GREEN) + `## Output Language` 섹션 존재

## 라우팅 추천
```yaml
agent: direct-main-session
skills: [codex-review]
mcps: []
rationale: 원인 진단 + codex Mode B 2라운드 설계검증이 모두 이 세션에 누적 — 하위 에이전트 위임 시 맥락 손실. 규칙 텍스트 영어 번역 + 신규 정책 1개 + 테스트 갱신의 집중 변경이라 세션 직접 편집이 효율적. 완료 후 codex-review(Mode A) + security-reviewer.
approved_by_user: true
```
