# communication-improve

- 날짜: 2026-05-28
- 유형: feat (rule/agent/hook 가이드 강화)
- DoD: `trail/dod/dod-2026-05-28-communication-improve.md`
- 변경 파일: 16 (14 modify + 2 new)

## 요약

사용자가 작성한 외부 분석 문서 `communication_improve_plan.md` 의 4 phase 개선안 ("내부 설계 용어·ID 가 사용자 대화에 그대로 노출되는 현상" 해소) 을 codex Mode B (gpt-5.5 / high) sanity check 의 5 권고 중 4건 반영 + 1건 (내부 식별자 절대 금지) 은 사용자 결정으로 plan 원안 유지하여 단일 cycle 로 ship.

## 사용자 결정 기록

| codex Mode B 권고 | 사용자 결정 |
|---|---|
| 1. "절대 금지" → "디버그 맥락은 병기" 로 완화 | **거부** — "내부 식별자 절대 금지" 유지 (단 marker file 경로 등 작동에 필요한 식별자는 escape hatch 로 본문 보존 + 평문 병기) |
| 2. Phase 1-C 삭제 또는 hook 함께 수정 | **(b)** — short summary 신규 + user-prompt-submit-rules.sh 가 매 turn short 만 inject, session-start 가 full 본문 ship |
| 3. Phase 2 범위에 feature-builder-worker.md + post-agent-review-trigger.sh 추가 | **수용** |
| 4. Phase 3 = "평문 요약 + 상세 라우팅 정보" 두 층 | **수용** — agent/skills/MCPs 정보는 상세 층 유지 (사용자 승인 정보 보존) |
| 5. Phase 4-C advisory hook 보류 | **수용** — incident template + answer-only §6 자가 점검만 ship |

## 변경 파일

### Phase 1 — Response Tone 강화 (6)
- `plugins/rein-core/rules/response-tone.md` — 전면 재작성. 행동 강령 4 항목 (내부 식별자 사용 금지 / 보고 문장 구조 / 질문 형식 / trail 인용) + 번역 테이블 + sub-section 별도 `## ` 헤더 분리. action mandate 1300/2048 B
- `plugins/rein-core/hooks/session-start-rules.sh` — loop 6-rule 로 확장 (`response-tone` 추가)
- `plugins/rein-core/rules/short/response-tone-summary.md` — 신규, 896 B (per-turn inject 용 압축 버전)
- `plugins/rein-core/hooks/user-prompt-submit-rules.sh` — full → short 로 inject 소스 변경. sentinel idiom + fail-open 유지
- `tests/scripts/test-ups1-short-rule-injection.sh` — 3 short 파일 + 6-rule anchor 갱신, 16 PASS
- `tests/hooks/test-user-prompt-submit-rules.sh` — per-turn envelope 에 short summary 포함, full body translation table 미포함 검증

### Phase 2 — Agent + hook 사용자 보고 평문화 (7)
- `plugins/rein-core/agents/plan-writer.md` — 기존 `## Handoff 메시지` → `## 내부 로깅 (trail/inbox 전용 — 사용자 채팅 본문 금지)` 으로 격리 + `## 사용자 보고 방식` 신규
- `plugins/rein-core/agents/feature-builder.md` — `## 사용자 보고 방식` 신규 (작업 착수 / 완료 / 차단 3 분기)
- `plugins/rein-core/agents/feature-builder-fix.md` — `## 사용자 보고 방식` — 재현 테스트 흐름 평문화
- `plugins/rein-core/agents/feature-builder-refactor.md` — `## 사용자 보고 방식` — 동작 불변 검증 흐름
- `plugins/rein-core/agents/feature-builder-worker.md` — `## 사용자 보고 방식` — parent 가 worker 결과 전달 시 worktree / cherry-pick / blocked_* 평문화
- `plugins/rein-core/agents/security-reviewer.md` — `## 사용자 보고 방식` (이상 없음 / 이슈 경미 / 이슈 심각 / 보류 4 분기)
- `plugins/rein-core/hooks/post-agent-review-trigger.sh` — block reason 평문화 (영문 reason 문자열만 변경, decision/exit code 불변. marker file path 는 hook 작동에 필요해 보존 + 평문 병기 안내 prepend)

### Phase 3 — Routing 평문 + 상세 두 층 (1)
- `plugins/rein-core/rules/routing-procedure.md` — §6 채팅 형식 두 층 구조 (평문 요약 한 줄 → "---" → 상세 라우팅: 담당 에이전트 / 보조 스킬 / 외부 자료 / 근거). DoD YAML schema (`agent:`, `skills:`, `approved_by_user:`) 는 불변 — `post-edit-dod-routing-check.sh` 영향 없음

### Phase 4 — 회귀 방지 (2 — advisory hook 보류)
- `trail/incidents/incident-template-tone-violation.md` — 신규 template (frontmatter 없음 → pending counter 무관). 자동 감지 hook 부재 (codex 권고 5 수용)
- `plugins/rein-core/rules/answer-only-mode.md` — §6 자가 점검 체크리스트에 tone 위반 검출 3 항목 추가

## 검증 결과

- `python3 scripts/rein-check-plugin-drift.py` → OK (boundary + parity + validation all pass)
- `bash tests/scripts/test-ups1-short-rule-injection.sh` → 16/16 PASS
- `bash tests/hooks/test-user-prompt-submit-rules.sh` → OK (envelope + graceful-degrade)
- `bash tests/hooks/test-action-mandate-existing-rules.sh` → OK
- `bash tests/hooks/test-action-mandate-new-rules.sh` → OK
- `bash tests/hooks/test-routing-map-emit.sh` → OK
- `bash tests/hooks/test-auto-mode.sh` → OK
- `bash tests/hooks/test-post-agent-review-trigger.sh` → OK (6 scenarios)
- `bash tests/hooks/run-all.sh` → ALL SUITES PASSED (10/10 dispatch tests)

## 리뷰 결과

- **코드 리뷰** (Round 1: sonnet-fallback, codex_usage_limit) → PASS with 3 Low (정보성)
- **Round 2: self-review** → 3 Low 정리 후 PASS (response-tone 적용 범위 중복 해소 / DoD 산수 표현 정정 / post-agent-review-trigger backtick quoting 은 response-tone.md `## 적용 범위` 의 marker file escape hatch 명시화로 정책 부합)
- **보안 검토** (security_tier: standard, security-reviewer agent) → PASS (0 findings — credential / deserialization / path traversal / .env / TLS / SQL / XSS / 해싱 모두 영향 없음)

## 다음 후보

1. main 머지 + tag bump 판정 — rule/agent/hook 문구 강화이지만 다음 user-visible 변화 동반:
   - 매 turn UserPromptSubmit envelope 본문이 full response-tone → short summary 로 바뀜 (token 절약, 본문 의미는 동일)
   - session-start envelope 에 full response-tone 본문 신규 inject (6-rule)
   - 어시스턴트 답변 톤이 한층 강화된 평문화 정책에 따름
   - hook block reason 평문화 (`post-agent-review-trigger.sh`)
   → Rule A 판정 후보: **minor** (user-facing 신규 hook 동작 추가 — session-start 의 response-tone full body inject + 6-rule loop)
2. dev push (origin/dev 와 동기)
3. main 머지 + tag (선별 체크아웃 패턴)
