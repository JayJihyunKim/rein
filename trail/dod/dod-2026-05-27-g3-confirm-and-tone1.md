# G3 confirmed.md 이관 + TONE-1 응답 톤 hook 구현

- 날짜: 2026-05-27
- 유형: docs (G3 이관) + feat (TONE-1)
- plan ref: 없음 (단발 cleanup + 소규모 feature — TONE-1 은 need-to-confirm.md 옵션 C 결정 이미 stamped)
- 선행 commit: dev `021bbf9` (G3 ship 완료)

## 범위

(a) G3 (execution-mode-advisor) 가 commit `021bbf9` 으로 ship 됐으니 need-to-confirm.md → confirmed.md 이관. 한눈 표에서 strike + 상세 섹션 제거.
(b) TONE-1 (응답 톤 규칙 매 turn 인젝션) 구현 — `response-tone.md` 신규 + `user-prompt-submit-rules.sh` 에 인젝션 1줄 추가 + 회귀 테스트 확장.

## 변경 파일

- `need-to-confirm.md` (modify — G3 행 strike, 상세 섹션 제거. TONE-1 행 → "구현 중" / 완료 후 별 cycle 에서 confirmed 이관)
- `confirmed.md` (modify — G3 resolution entry 추가)
- `plugins/rein-core/rules/response-tone.md` (신규, 100~150 토큰)
- `plugins/rein-core/hooks/user-prompt-submit-rules.sh` (modify — `rule_inject_body response-tone` 호출 추가, COMBINED 에 합류)
- `tests/hooks/test-user-prompt-submit-rules.sh` (modify — response-tone 본문 substring 회귀)
- `trail/dod/.active-dod` (이 DoD 로 갱신)
- `trail/dod/dod-2026-05-27-g3-confirm-and-tone1.md` (본 DoD)
- `trail/inbox/2026-05-27-g3-confirm-and-tone1.md` (완료 시점)
- `trail/index.md` (다음 진입점 갱신)

## 검증 기준

1. **need-to-confirm 정리**: G3 행 → strike + 상세 섹션 제거. confirmed.md 에 G3 resolution entry (commit `021bbf9` reference) 추가. 한눈 표에서 G3 status `still-unresolved` → 제거 또는 strike.
2. **response-tone.md 크기**: 본문 ≤ 250 토큰 (≈ 1000 byte UTF-8 상한). 3~5 항목 압축. 본 cycle 실측 = 983 byte / ~245 token (`행동 강령` 1 단락 + `적용 범위` 3 bullet). codex R1 High claim-audit 후 가이드라인 정정 — 명확성 우선 trade-off (TONE-1 backlog 의 100~150 토큰은 ballpark 추정이었고, drift checker 가 강제하는 `## 행동 강령` 의무 섹션 + plain-language 본문 + 적용 범위 분리로 자연스럽게 ~250 토큰 수렴).
3. **hook 회귀**: `bash tests/hooks/test-user-prompt-submit-rules.sh` PASS — happy path envelope 에 `행동 강령` + `response-tone` 본문 substring 둘 다 검출, graceful degrade 무영향.
4. **plugin drift**: `python3 scripts/rein-check-plugin-drift.py` exit 0.
5. **plugin validate**: `claude plugin validate plugins/rein-core` PASS.
6. **fail-open**: response-tone 본문 부재 또는 override 실패 시 hook 가 silent degrade (기존 answer-only-summary inject 패턴과 동일).

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: light
approved_by_user: true
rationale: |
  Two surfaces:
  (a) need-to-confirm.md / confirmed.md — 정적 markdown 이동 (G3 cleanup). 코드 영향 0.
  (b) response-tone.md 신규 + user-prompt-submit-rules.sh 1줄 추가 — 기존 answer-only-summary
  인젝션 패턴 복제. attack surface 0 (rule body 는 정적 markdown, hook 은 기존 helper 재사용).
  security_tier: light 적정 (`.security-reviewed` stamp 없이 commit 허용 — operating-sequence
  Step 6 light tier 규정).
  사용자 명시 "구현 시작" = implicit routing approval.
  Phase 1 (route-time) DoD 와 동일한 패턴.
