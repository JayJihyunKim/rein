# DoD — 페르소나/규칙 주입 truncation 수정 (요약화 + 격리 + 매턴 통합 + 회귀 테스트)

작성일: 2026-06-11
slug: persona-injection-truncation-fix
plan ref: docs/plans/2026-06-11-persona-injection-truncation-fix.md

## 배경 / 동기

사용자가 rein 업데이트 후 페르소나(`boss-ace`)가 발동하지 않는 버그 보고. 실측 검증 결과 `session-start-rules.sh` 가 규칙 6종 본문 + 페르소나를 단일 봉투(22,592 bytes)로 방출 → 하네스가 cap 초과분을 파일로 빼고 앞부분 프리뷰만 인라인 → 페르소나(꼬리 1,634 bytes)와 testing/operating-sequence/routing-map/response-tone 전문이 모델에 도달 못 함. codex 독립 검증 + perf 평가 완료(2026-06-11). 네 갈래 수정: 요약화(2b) + 페르소나 격리(1) + 매턴 통합(3) + 회귀 테스트(4).

spec → plan 체인 완료(둘 다 codex 검토 대상). 본 DoD 는 plan 의 구현 단계를 정의한다.

## 범위

### IN
- **PT-1·PT-6 (요약 본문)**: `rules/short/` 에 5개 규칙 요약(code-style/security/testing/operating-sequence/routing-map) + persona 매턴 요약 신설.
- **PT-2·PT-4 (세션시작 요약 전환)**: `session-start-rules.sh` 가 full body 대신 요약 주입(override 우선 → 요약 → full body fallback) + 기존 페르소나 블록 제거.
- **PT-3·PT-5 (페르소나 격리)**: `session-start-persona.sh` 신규 hook(자체 봉투, --persona 해석, graceful degrade) + `hooks.json` 등재(rules 뒤).
- **PT-7·PT-8 (매턴 단일화 + perf)**: loader `--turn-brief` envelope 방출 모드(2사본 동기화, env fail-open) + `user-prompt-submit-rules.sh` 정확히 1 spawn 리팩토링(persona 추가하면서 spawn 회귀 없음).
- **PT-9·PT-10·PT-11·PT-12 (회귀 테스트 + 등록)**: per-hook byte 예산 테스트 + turn-brief loader 테스트 + 요약 전환으로 깨지는 기존 테스트 6건 갱신 + 신규 hook 의 drift checker 2사본·parity allowlist 등록.

### OUT
- 규칙 본문 전문 내용 변경(요약만 신설, 전문 보존).
- 추가 페르소나 프리셋.
- 하네스 truncation cap 역공학(설계가 per-hook/총합 양쪽 안전).
- README/CHANGELOG 사용자 문서화 + 버전 bump/릴리스(별도 cycle).

## 변경 파일
- plugins/rein-core/rules/short/code-style-summary.md (신규)
- plugins/rein-core/rules/short/security-summary.md (신규)
- plugins/rein-core/rules/short/testing-summary.md (신규)
- plugins/rein-core/rules/short/operating-sequence-summary.md (신규)
- plugins/rein-core/rules/short/routing-map-summary.md (신규)
- plugins/rein-core/rules/short/persona-summary.md (신규)
- plugins/rein-core/hooks/session-start-rules.sh
- plugins/rein-core/hooks/session-start-persona.sh (신규)
- plugins/rein-core/hooks/hooks.json
- plugins/rein-core/scripts/rein-policy-loader.py
- scripts/rein-policy-loader.py
- plugins/rein-core/hooks/user-prompt-submit-rules.sh
- tests/hooks/test-session-start-byte-budget.sh (신규)
- tests/hooks/run-all.sh
- tests/scripts/test-policy-loader-turn-brief.sh (신규)
- tests/scripts/run-all.sh
- tests/hooks/test-session-start-persona-inject.sh
- tests/scripts/test-ups1-short-rule-injection.sh
- tests/hooks/test-session-start-rules.sh
- tests/hooks/test-routing-map-emit.sh
- tests/hooks/test-policy-rules-override.sh
- tests/scripts/test-policy-yaml-fails-open.sh
- tests/scripts/test-plugin-hooks-json-parity.sh

## 검증 기준
- plan 의 커버리지 매트릭스 PT-1~PT-11 전부 충족(파일·계약·테스트 이진 판정).
- `diff plugins/rein-core/scripts/rein-policy-loader.py scripts/rein-policy-loader.py` 빈 출력(byte-identical).
- `session-start-rules.sh` 방출 additionalContext ≤ 8,000 bytes + 요약 마커 포함·full-body-only 마커 미포함.
- `session-start-persona.sh` 방출 ≤ 4,000 bytes + enabled 시 boss-ace 본문 포함 / disabled 시 미포함.
- `user-prompt-submit-rules.sh` 방출 ≤ 4,000 bytes + persona 요약 포함(enabled) + 매턴 python spawn 정확히 1개(회귀 없음).
- 모든 SessionStart hook 개별 방출 ≤ per-hook 예산(per-hook cap 모델 — 총합 assertion 없음).
- 모든 hook `bash -n` 통과 + `hooks.json` valid JSON + persona hook 이 rules 뒤 등재 + drift 0(코드 변경 없이 persona 자동 인지) + parity allowlist 통과.
- 신규 테스트(byte-budget assert (a)~(e), turn-brief assert (a)~(h)) 통과 + 갱신 테스트 6건(persona-inject·ups1·session-start-rules·routing-map-emit·policy-rules-override·policy-yaml-fails-open) + parity 테스트 통과.
- 전체 스위트(`tests/hooks/run-all.sh`, `tests/scripts/run-all.sh`) 회귀 없음.
- codex 코드 리뷰 PASS + 보안 리뷰 PASS.

## 범위 연결

plan ref: docs/plans/2026-06-11-persona-injection-truncation-fix.md
work unit: Implementation 전체 — Phase 1~4 / 모든 Task
covers: [PT-1, PT-2, PT-3, PT-4, PT-5, PT-6, PT-7, PT-8, PT-9, PT-10, PT-11, PT-12]

## 라우팅 추천

agent: claude (부모 메인 세션 순차 구현)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - 단일 주입 파이프라인 리팩토링 — loader `--turn-brief` 인터페이스 ↔ 호출 hook ↔ 양쪽 검증 테스트가 정확히 합의해야 하는 교차 불변식. 파일은 대부분 disjoint 이나 의미적 결합이 강해(인터페이스 contract) worker 병렬 시 추정 불일치 리스크 → 부모 순차가 안전(parallel 평가 완료, 순차 선택)
  - 보안 표면 = persona hook 의 preset 이름 경로 조합(loader 검증값만 신뢰, 기존 PP-3 신뢰 경계 재사용) + `--turn-brief` 의 CLAUDE_PLUGIN_ROOT 파일 read → security_tier standard, 통합 보안 리뷰 필수
  - hot-path 변경(매턴 hook) 포함 — perf 회귀 방지가 설계 목표라 spawn 수 비회귀를 검증 기준에 포함. complexity medium(6 파일 신규 + 6 파일 수정, 기존 패턴 복제)
approved_by_user: true
