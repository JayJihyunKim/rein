# DoD — codex 리뷰 모델 gpt-5.5 통일 + 옛 모델 라벨 정합

작성일: 2026-06-09
slug: codex-review-model-unify-gpt55

## 배경 / 동기

어제(2026-06-08, v1.4.6) codex 모델을 단일 출처(`plugins/rein-core/config/codex-models.sh`)로 모으면서 역할을 둘로 나눴다 — 분석/second opinion 은 `ANALYSIS_MODEL=gpt-5.5`, 코드·문서 리뷰는 `CODE_MODEL=gpt-5.3-codex-spark`. 사용자 결정(2026-06-09): 코드 리뷰든 문서(설계서/플랜) 리뷰든 구분 없이 모두 `gpt-5.5` 로 통일한다.

코드 리뷰와 문서 리뷰는 동일하게 `CODE_MODEL` 을 쓰므로(둘 다 `/codex-review` → `rein-codex-review.sh` 가 이 값을 `-m` 으로 전달) 실제 동작 변경은 이 한 변수다.

추가로, 어제 단일 출처 작업의 변경 파일 목록에 agent 파일(spec-writer/plan-writer)이 빠져 있어, 그 안의 reviewer 라벨이 실제 모델과 무관한 옛 문자열(`gpt-5.4`)로 박제된 드리프트가 남아 있다. 이번에 함께 정합화한다.

## 범위

### IN
- **모델 통일**: `plugins/rein-core/config/codex-models.sh` 의 `CODE_MODEL` 을 `gpt-5.3-codex-spark` → `gpt-5.5` 로 변경. 코드 리뷰 게이트 + 자동 문서(설계서/플랜) 리뷰가 모두 gpt-5.5 로 동작.
- **역할 주석 정합**: 같은 파일의 역할 분리 주석에서 "CODE_MODEL — 코드 특화 모델" 설명을 현 상태(코드/문서 리뷰 공통 범용 모델)에 맞게 갱신.
- **옛 라벨 정합**: `plugins/rein-core/agents/spec-writer.md`, `plugins/rein-core/agents/plan-writer.md` 의 옛 모델 라벨(`gpt-5.4`)을 `gpt-5.5` 로 갱신 — 설명문(`default (gpt-5.4 / high ...)`)과 reviewer 추적 라벨(`codex-gpt-5.4-high-automated`) 모두.

### OUT
- `ANALYSIS_MODEL` / `CODE_MODEL` 변수 통합 — 두 변수 유지(미래에 코드 특화 모델로 재분리 가능하도록 값만 같게 둔다). 사용자 결정.
- 수동 `/codex-review` 의 강도(low/med/high) 선택 질문 제거 — 사용자 결정(2026-06-09)으로 현행 유지.
- reviewer 라벨의 placeholder 화 등 구조 리팩토링 — 이번엔 현재값 정합만(scope creep 방지).
- 과거 trail/ · docs/ 운영 기록 안의 모델명 문자열 — 역사 기록이므로 손대지 않음.

## 변경 파일
- plugins/rein-core/config/codex-models.sh
- plugins/rein-core/agents/spec-writer.md
- plugins/rein-core/agents/plan-writer.md

## 검증 기준
- `codex-models.sh` 에서 `CODE_MODEL="gpt-5.5"`, `ANALYSIS_MODEL="gpt-5.5"` (둘 다 gpt-5.5).
- 래퍼(`rein-codex-review.sh`)가 `CODE_MODEL` 을 `-m` 으로 전달하는 기존 경로 변경 없음 → 코드/문서 리뷰가 동일하게 gpt-5.5 사용.
- plugin source 전체 grep 시 `gpt-5.4` 잔존 0건, `codex-spark` 잔존 0건(주석 안의 rename 메커니즘 예시 `gpt-5.3-codex → gpt-5.3-codex-spark` 1줄은 historical 설명이라 예외 — 동작에 영향 없음).
- `bash -n plugins/rein-core/config/codex-models.sh` 구문 통과.
- 기존 fail-soft 테스트 회귀 없음: `bash tests/skills/test-codex-model-failsoft.sh` 통과(존재 시), `tests/skills/run-all.sh` 통과.

## 라우팅 추천

agent: 직접 편집 (메인 세션 — subagent 불필요)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: low
model_hint: opus
effort_hint: low
rationale:
  - 설정값 1줄 + 문서 라벨 5곳의 정합성 변경 → 직접 편집이 가장 단순. 파일 disjoint 하나 변경이 작아 병렬 분배 이득 없음
  - codex 호출 모델 결정 경로를 건드리므로(어제 단일 출처 작업의 연장) 보안 리뷰는 standard 로 보수적 적용 — light+plan-less 게이트 알려진 이슈도 함께 회피
  - 신규 인터페이스 없음 + 로직 변경 없음(값/문자열 정합) → complexity low
approved_by_user: true
