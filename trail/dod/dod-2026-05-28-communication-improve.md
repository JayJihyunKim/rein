# DoD — communication-improve (2026-05-28)

> 사용자 외부 분석 문서 `communication_improve_plan.md` 의 4 phase 개선안을 codex Mode B (`gpt-5.5 / high`) sanity check 결과 (`/tmp/codex-ask-comm-plan.out`) 의 5 권고 중 4건 반영, 1건 (내부 식별자 절대 금지) 은 사용자 결정으로 plan 원안 유지. 단일 cycle 로 4 phase 전부 ship.

## 배경

`communication_improve_plan.md` 는 "내부 설계 용어·ID 가 사용자 대화에 그대로 노출되는 현상" 의 5 원인 (response-tone 규칙 강도 부족 / session-start-rules 미주입 / agent 보고 지침 부재 / operating-sequence 기술 용어 노출 / routing 채팅 형식 고정) 을 진단하고 4 phase 개선안을 제시. codex Mode B 검토 결과:

- 5 원인 진단 대체로 정확. 단 "tone 규칙이 아예 전달되지 않는다" 는 부정확 — 2026-05-27 TONE-1 (`413169d`) 에서 UserPromptSubmit 매 turn inject 이미 ship.
- 빠진 원인 3건: `feature-builder-worker.md` / hook 출력 (`post-agent-review-trigger.sh`) / Phase 1-C 의 short summary 가 현재 hook 에 연결 안 됨 (`user-prompt-submit-rules.sh` 가 full body 를 직접 read)
- 정책 충돌 2건: "내부 식별자 절대 금지" 가 gate/review/debug 맥락의 투명성 계약과 충돌 / Phase 3 의 레이블 완전 제거가 사용자 승인 정보 손실 유발

사용자 결정 (본 cycle turn):

| codex 권고 | 사용자 결정 |
|---|---|
| 1. "절대 금지" → "일상 평문, 디버그 맥락은 병기" 로 완화 | **거부 — 원안 "내부 식별자 절대 금지" 유지** |
| 2. Phase 1-C 삭제 또는 hook 함께 수정 | **(b) 옵션 채택 — short summary 신규 + hook 수정 + UPS-1 테스트 갱신** |
| 3. Phase 2 범위에 feature-builder-worker.md + post-agent-review-trigger.sh 추가 | **수용** |
| 4. Phase 3 = 레이블 제거가 아니라 "평문 요약 + 상세 라우팅 정보" 두 층 | **수용** |
| 5. Phase 4-C advisory hook 보류 (false-positive incident spam 위험) | **수용 — incident template + answer-only §6 자가 점검만 ship** |

## 범위

### IN
- **Phase 1**: `response-tone.md` 전면 재작성 (`내부 식별자 절대 금지` 유지, 번역 테이블, 3-step 보고 구조, 질문 형식, `MEMORY.md` 평문 재진술 강제). `session-start-rules.sh` 의 5-rule loop 에 `response-tone` 추가 → 6-rule. `short/response-tone-summary.md` 신규. `user-prompt-submit-rules.sh` 가 매 turn 은 short summary 를, session-start 는 full body 를 inject 하도록 분리. UPS-1 회귀 테스트 갱신
- **Phase 2**: agents/{plan-writer, feature-builder, feature-builder-fix, feature-builder-refactor, feature-builder-worker, security-reviewer}.md 에 `## 사용자 보고 방식` 섹션 추가 (내부 stamp/verdict/handoff 용어 채팅 본문 금지, 평문 보고 템플릿 제공). `post-agent-review-trigger.sh` 의 block reason 평문화
- **Phase 3**: `routing-procedure.md` §6 채팅 형식을 "평문 요약 한 문장 + (접힘 가능한) 상세 라우팅 정보" 두 층 구조로 교체. agent/skills/MCPs 정보는 상세 층에 유지 (사용자 승인 정보 보존)
- **Phase 4**: `trail/incidents/incident-template-tone-violation.md` 신규 (template only, 자동 감지 hook 없음). `answer-only-mode.md` §6 자가 점검 체크리스트에 tone 위반 검출 항목 2개 추가

### OUT
- Phase 4-C advisory tone hook (`post-stop-tone-check.sh` 신설) — codex 권고대로 false-positive 비용 검증 부족, 보류
- `operating-sequence.md` 의 기술 용어 (DoD/stamp/.codex-reviewed) 자체 변경 — 이 용어들은 hook gate 계약 SSOT 라 평문화 시 gate 동작 자체가 모호해짐. plan §원인 4 는 진단으로만 채택하고 변경 대상에서 OUT
- `incidents-to-rule` 등 다른 hook/skill 의 메시지 평문화 — 본 cycle 범위 밖, 별 cycle
- 다른 agent 파일 (docs-writer / researcher) — 두 agent 는 보고 비중 작음. 본 cycle 범위 밖

## 변경 파일

### Phase 1 — Response Tone 강화 (6 파일)
- plugins/rein-core/rules/response-tone.md
- plugins/rein-core/hooks/session-start-rules.sh
- plugins/rein-core/rules/short/response-tone-summary.md
- plugins/rein-core/hooks/user-prompt-submit-rules.sh
- tests/hooks/test-user-prompt-submit-rules.sh
- tests/scripts/test-ups1-short-rule-injection.sh

### Phase 2 — Agent + hook 사용자 보고 평문화 (7 파일)
- plugins/rein-core/agents/plan-writer.md
- plugins/rein-core/agents/feature-builder.md
- plugins/rein-core/agents/feature-builder-fix.md
- plugins/rein-core/agents/feature-builder-refactor.md
- plugins/rein-core/agents/feature-builder-worker.md
- plugins/rein-core/agents/security-reviewer.md
- plugins/rein-core/hooks/post-agent-review-trigger.sh

### Phase 3 — Routing 평문 + 상세 두 층 (1 파일)
- plugins/rein-core/rules/routing-procedure.md

### Phase 4 — 회귀 방지 (2 파일)
- trail/incidents/incident-template-tone-violation.md
- plugins/rein-core/rules/answer-only-mode.md

**총 16 파일** = 14 modify + 2 new
- 14 modify: Phase 1 의 response-tone.md / session-start-rules.sh / user-prompt-submit-rules.sh / test-ups1-short-rule-injection.sh / test-user-prompt-submit-rules.sh (5) + Phase 2 의 agent 6 + post-agent-review-trigger.sh (7) + Phase 3 의 routing-procedure.md (1) + Phase 4 의 answer-only-mode.md (1)
- 2 new: Phase 1 의 short/response-tone-summary.md (1) + Phase 4 의 incident-template-tone-violation.md (1)

## 검증 기준

### Phase 1
1. `bash -n plugins/rein-core/hooks/session-start-rules.sh` 및 `user-prompt-submit-rules.sh` 구문 통과
2. session-start additionalContext envelope 에 `# Response Tone` 본문 포함 (`bash plugins/rein-core/hooks/session-start-rules.sh < /dev/null | python3 -c 'import sys,json; o=json.loads(sys.stdin.read()); print("# Response Tone" in o["hookSpecificOutput"]["additionalContext"])'` → True)
3. UserPromptSubmit envelope 에 short response-tone-summary 본문 포함, **full body 는 포함하지 않음** (token 절약 효과 확인)
4. `bash tests/hooks/test-user-prompt-submit-rules.sh` PASS — short summary 본문 substring 검출
5. `bash tests/scripts/test-ups1-short-rule-injection.sh` PASS — 6-rule (response-tone 포함) 검증으로 갱신
6. response-tone.md 본문 ≥ 5 항목 (내부 식별자 절대 금지 / 번역 테이블 / 3-step 보고 구조 / 질문 형식 / MEMORY.md 평문 재진술), short 버전 ≤ 300 token (1300 byte)

### Phase 2
7. 7 파일 모두 `## 사용자 보고 방식` 섹션 신설 — 작업 착수 / 작업 완료 / 차단 발생 3 분기 평문 템플릿 포함
8. post-agent-review-trigger.sh 의 block reason 에서 `.review-pending` / `codex-review` / `stamp` 영어 식별자가 제거되거나 평문 설명 병기 (단 stamp 파일 경로는 작동에 필요한 식별자라 보존 — "검토 표시 파일 (`trail/dod/.review-pending`)" 형태 병기)

### Phase 3
9. routing-procedure.md §6 의 새 채팅 형식이 두 층 구조 (평문 요약 한 문장 + 접힘 가능한 상세) — 상세 층에 agent/skills/MCPs 명시 유지
10. DoD 파일 저장 형식 (`agent: rein:...`, `skills:`, `mcps:`, `approved_by_user:`) 은 그대로 — hook (`post-edit-dod-routing-check.sh`) 이 이 schema 를 강제하므로 변경 시 hook 도 동시 수정 필요. 본 cycle 은 **schema 불변**, 채팅 표면만 변경

### Phase 4
11. `trail/incidents/incident-template-tone-violation.md` 가 template 으로 존재 (실제 incident 파일 아님 — frontmatter 없음)
12. `answer-only-mode.md` §6 자가 점검 체크리스트에 tone 위반 검출 2개 항목 추가

### 회귀
13. `bash tests/run-all-hooks-tests.sh` 또는 hook-specific 회귀 6/6 PASS
14. `python3 scripts/rein-check-plugin-drift.py` 결과 drift 0
15. `claude plugin validate` PASS (메인테이너 env 가능 시)

## 라우팅 추천

```yaml
## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 16 파일 변경 (rule 4 + hook 3 + agent 6 + test 2 + template 1) — feature 추가/강화 성격
  - 외부 보안 경계 없음 (auth / crypto / .env 미해당) → standard
  - 단일 cycle 묶음. plan-writer / researcher 불필요 — design 문서 (communication_improve_plan.md) 와 codex sanity check 결과로 spec 명확
  - codex-review 필수 (commit gate). security-reviewer 는 standard tier 라 light 면제 미적용
approved_by_user: true
```

## 참고 자료

- 외부 분석: `communication_improve_plan.md` (저장소 루트, 사용자 IDE 에서 직접 작성)
- codex sanity check 결과: `/tmp/codex-ask-comm-plan.out` (Mode B, gpt-5.5/high, 결론 = Go with revisions)
- 직전 관련 ship: 2026-05-27 TONE-1 (`413169d`) — response-tone.md 신설 + UserPromptSubmit 매 turn inject. 본 cycle 은 그 강화·확장
