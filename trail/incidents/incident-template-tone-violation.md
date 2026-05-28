# Tone 위반 incident 템플릿

> 본 파일은 **템플릿**이다. 실제 incident 가 아니다 — frontmatter 가 없으므로 `pre-edit-dod-gate.sh` 의 미처리 incident 카운트에 잡히지 않는다.
>
> rein 어시스턴트가 사용자 채팅 본문에 내부 식별자·약어·trail 원문을 그대로 노출했을 때 (response-tone 규칙 위반) 사용자가 본 템플릿을 복사해 `trail/incidents/tone-YYYY-MM-DD-<slug>.md` 로 저장한다. 한 사례당 1 파일.
>
> 자동 감지 hook 은 없다 (codex Mode B sanity check 결과 — false-positive 비용이 효과보다 큼). 회귀 방지는 (1) 본 파일 누적 + 회고 시 패턴 검토 + (2) `answer-only-mode.md` §6 자가 점검 체크리스트로 수행.

---

## 사례 정보

- 발생 시각: YYYY-MM-DD HH:MM
- 노출된 위치: [예 — 라우팅 추천 / 작업 완료 보고 / plan 검토 결과 / 보안 검토 결과 / 차단 사유 설명]
- 호출된 에이전트 (있다면): [예 — `rein:plan-writer` / `rein:feature-builder` / inline (메인 세션)]

## 노출된 표현

> [사용자에게 보인 본문을 그대로 인용. 내부 식별자가 어디에 노출됐는지 표시]

## 어떻게 표현했어야 하나

> [`plugins/rein-core/rules/response-tone.md` 의 번역 테이블 기준으로 어떻게 풀었어야 했는지 평문 보고 예시]

## 원인 분류

(해당하는 곳 체크)

- [ ] `response-tone.md` 규칙이 해당 패턴을 다루지 않음 — 본문에 규칙 추가 필요
- [ ] 호출된 에이전트 파일의 `## 사용자 보고 방식` 섹션이 누락 또는 미흡
- [ ] hook envelope 의 reason / decision 메시지가 내부 식별자를 그대로 전달 — hook 메시지 평문화 필요
- [ ] 어시스턴트가 규칙은 봤지만 적용 누락 — `answer-only-mode.md` §6 자가 점검 항목 강화 필요
- [ ] 사용자가 trail 본문 (`trail/index.md` / `trail/inbox/`) 인용을 명시 요청했는데 평문 재진술 없이 그대로 인용
- [ ] 기타: ...

## 조치

- [ ] `response-tone.md` 번역 테이블에 신규 항목 추가
- [ ] 해당 에이전트 파일의 `## 사용자 보고 방식` 섹션 보강
- [ ] 해당 hook envelope reason 평문화
- [ ] `answer-only-mode.md` §6 체크리스트 항목 추가
- [ ] 다음 회고 (`trail/daily/` 또는 별 cycle) 에서 패턴 검토
- [ ] 기타: ...

## 관련 파일

- 규칙 본문: `plugins/rein-core/rules/response-tone.md` (full) / `plugins/rein-core/rules/short/response-tone-summary.md` (per-turn)
- 매 turn 주입: `plugins/rein-core/hooks/user-prompt-submit-rules.sh`
- 세션 시작 주입: `plugins/rein-core/hooks/session-start-rules.sh`
- 자가 점검: `plugins/rein-core/rules/answer-only-mode.md` §6
