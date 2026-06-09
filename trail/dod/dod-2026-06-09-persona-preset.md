# DoD — 페르소나 프리셋 기능 (boss-ace 기본, 기본 ON + opt-out)

작성일: 2026-06-09
slug: persona-preset
plan ref: docs/plans/2026-06-09-persona-preset-implementation.md

## 배경 / 동기

rein 어시스턴트 응답에 교체 가능한 페르소나 레이어를 추가한다. 기본 프리셋 `boss-ace` 는 사용자를 "보스"라 부르는 과잉충성 "조직의 에이스" 말투를 입히되, 판단·경고·운영 디테일은 절대 무르게 하지 않는다(말투에만 적용, 판단은 냉정). 목적은 OSS 공개 초반 화제성, 기본 ON + 정책 opt-out.

brainstorm → spec → plan 체인 완료(설계·플랜 모두 codex 검토 PASS + 표식 생성). 본 DoD 는 plan 의 구현 단계를 정의한다.

## 범위

### IN
- **PP-2~PP-6 (loader)**: `rein-policy-loader.py` 에 `get_persona()` + `--persona` CLI + `KNOWN_PERSONA_PRESETS={"boss-ace"}` 형식·멤버십 2중 검증. 2사본(plugin SSOT + 루트 fallback) byte-identical 동기화. loader 단위·parity 테스트(fail-open 전 분기 + path 주입 + 미등재 이름).
- **PP-7~PP-8 (프리셋 본문)**: `plugins/rein-core/rules/persona/boss-ace.md` 신규 — 원칙 + 예시 1~2개("복붙 금지"), 불변 조항, response-tone precedence 조항, 한/영 언어분기, 간결 cap(≤약 1.5KB).
- **PP-9~PP-10 (hook 주입)**: `session-start-rules.sh` 6-rule 루프 뒤 persona 주입 블록(활성 프리셋 1개만 해석, O(1), 새 hook 미등록).
- **PP-11~PP-12 (bootstrap)**: plugin 본체 `rein-bootstrap-project.py` 가 신규 설치 시 `persona.yaml`(enabled:true/preset:boss-ace) 생성 + `POLICY_PERSONA_TEMPLATE`. 루트 래퍼는 runpy 위임이라 무편집.
- **PP-13 (주입 테스트)**: persona 주입 회귀 테스트 5 assert.
- **PP-14 (무변경 보존)**: `user-prompt-submit-rules.sh` 무변경 + `rules/persona/short/` 미생성 검증.

### OUT
- 매턴 nudge / short summary(결정: 첫 릴리스 off, decay 측정 후 후속).
- `boss-ace` 외 추가 프리셋(구조는 교체 가능하게 두되 본 릴리스 단일 프리셋).
- 기존 사용자 migration 스크립트(부재=ON default 라 불필요).
- `response-tone.md`/기존 6-rule 본문 변경(precedence 는 persona 본문에서 선언).
- README opt-out 문서화(릴리스 단계 별도 판단).

## 변경 파일
- plugins/rein-core/scripts/rein-policy-loader.py + scripts/rein-policy-loader.py (2사본)
- plugins/rein-core/rules/persona/boss-ace.md (신규)
- plugins/rein-core/hooks/session-start-rules.sh
- plugins/rein-core/scripts/rein-bootstrap-project.py (plugin 본체만)
- tests/scripts/test-policy-loader-persona.sh (신규) + tests/scripts/run-all.sh
- tests/hooks/test-session-start-persona-inject.sh (신규) + tests/hooks/run-all.sh

## 검증 기준
- plan 의 Design 범위 커버리지 매트릭스 PP-1~PP-14 전부 충족(파일·계약·테스트 이진 판정).
- `diff plugins/rein-core/scripts/rein-policy-loader.py scripts/rein-policy-loader.py` 빈 출력(byte-identical).
- loader 테스트: fail-open 전 분기(파일부재/파싱실패/non-dict/enabled부재/preset부재/PyYAML부재) + path 주입(`../x`,`a/b`,`$(x)`,빈) + 미등재 이름(`mentor`,`does-not-exit`) 모두 default `boss-ace` 강등 통과.
- persona 주입 테스트 5 assert 통과(enabled 포함/disabled 미포함/unknown 강등/response-tone 뒤 순서/파일부재 default ON).
- `session-start-rules.sh -n` 구문 통과, 새 hook 미등록.
- 전체 테스트 스위트 회귀 없음. `user-prompt-submit-rules.sh` diff 무변경.
- codex 코드 리뷰 PASS + 보안 리뷰 PASS.

## 라우팅 추천

agent: rein:parallel-execute (plan 의 실행 전략 — Wave 1 4태스크 병렬 edit_only + Wave 2 테스트 2태스크, 각 worker = feature-builder)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - 신규 기능 구현이며 plan 이 Wave 병렬 구조(서로 다른 파일 4개 edit_only)로 설계됨 → parallel-execute 로 Wave 단위 dispatch, 부모가 웨이브별 검증·커밋
  - 보안 표면 = loader 의 preset 이름 path 주입 방어 + hook 주입 경로 → security_tier standard, 통합 보안 리뷰 필수
  - 단일 모듈 다수 파일 + 기존 패턴 복제(meta-check loader/POLICY_TEMPLATE/6-rule 루프) → complexity medium
approved_by_user: true
