# DoD — codex 역할별 모델 단일 출처 + 모델 fail-soft

작성일: 2026-06-08
slug: codex-model-profile-routing

## 배경 / 동기

codex 스킬은 모델명을 SKILL.md 여러 곳에 직접 박아둬서, codex 가 모델을 rename 하면(`gpt-5.3-codex` → `gpt-5.3-codex-spark`) 스킬 파일을 일일이 고쳐야 하고, 죽은 모델명이 그대로 남아 로드 실패가 난다. 사용자 결정(2026-06-08): 모델명을 rein 배포물 **단일 출처 파일 한 곳**에 모으고, 모델 로드 실패 시 "모델명이 변경된 것 같으니 이 위치를 고치라"를 경로와 함께 명확히 안내한다.

### 스파이크로 확정한 전제 (2026-06-08)

- codex moving alias(`gpt-5-codex`, `gpt-codex`) 는 ChatGPT 계정 경로에서 미지원 — "항상 최신" 별칭으로 무인 추적 불가. 따라서 모델명은 사람이 한 곳에서 관리한다.
- 모델 에러 시 codex 종료 코드 = 1 + 출력에 `invalid_request_error` / `is not supported`(직접 실행 실측, 파이프 미경유). fail-soft 는 이 두 신호로 "모델명 문제"를 특정한다.
- 유효 모델 `gpt-5.5`(분석), `gpt-5.3-codex-spark`(코드) 동작 확인. 옛 `gpt-5.3-codex` 죽음 확인.

## 범위

### IN
- **모델명 단일 출처 파일 신설**: `plugins/rein-core/config/codex-models.sh` — 역할→모델 매핑(`ANALYSIS_MODEL`, `CODE_MODEL`) + 역할별 기본 강도(`ANALYSIS_EFFORT`, `CODE_EFFORT`). 모델 rename 시 수정 지점은 이 파일 한 곳.
- **역할 자동 라우팅**: 코드리뷰 래퍼는 `CODE_MODEL`, second opinion 스킬은 `ANALYSIS_MODEL` 을 codex 에 `-m` 으로 전달. 래퍼는 이 파일을 source 하고, codex-ask SKILL.md 는 이 파일에서 값을 읽도록 지시.
- **모델 fail-soft**: codex 출력의 `is not supported` / `invalid_request_error` 패턴을 감지하면 (1) sonnet fallback 으로 새지 않고 (2) 잘못된 리뷰 통과 표시(`.codex-reviewed`)를 만들지 않으며 (3) "codex 가 모델명을 바꾼 것 같습니다 — `plugins/rein-core/config/codex-models.sh` 의 `<CODE_MODEL 또는 ANALYSIS_MODEL>` 을 최신 이름으로 수정하세요"를 경로와 함께 보고.
- 두 SKILL.md 에서 분산·하드코딩 모델명 제거, 단일 출처 파일 참조로 교체. codex-ask 의 모델 선택 질문 제거(역할 고정).

### OUT
- codex profile 파일(`~/.codex/<name>.config.toml`)로 모델명을 사용자 환경에 외부화하는 방식 — 사용자 결정으로 채택 안 함(모델명은 rein 단일 출처).
- codex 인증 방식 변경(ChatGPT 계정 ↔ API 키)으로 alias 를 여는 것.
- codex-review 의 변경 규모 기반 강도 자동판정(`[EFFORT:]`) 재설계 — 기존 로직 유지(단일 출처의 `CODE_EFFORT` 는 기본값/폴백 용도).

## 변경 파일
- plugins/rein-core/config/codex-models.sh
- plugins/rein-core/scripts/rein-codex-review.sh
- plugins/rein-core/skills/codex-review/SKILL.md
- plugins/rein-core/skills/codex-ask/SKILL.md
- tests/skills/test-codex-model-failsoft.sh
- tests/skills/run-all.sh

## 검증 기준
- 래퍼가 `plugins/rein-core/config/codex-models.sh` 의 `CODE_MODEL` 을 읽어 codex 에 `-m` 으로 전달한다(코드 + 실측).
- codex-ask 가 모델 선택 질문 없이 단일 출처의 `ANALYSIS_MODEL` 로 실행된다.
- 존재하지 않는 모델을 주입하면 래퍼가 sonnet fallback 으로 가지 않고, 리뷰 통과 표시를 만들지 않으며, 안내 메시지에 단일 출처 파일 경로와 수정 대상 항목명이 포함된다.
- 두 SKILL.md grep 시 하드코딩 모델명(`gpt-5.5`, `gpt-5.3-codex`, `gpt-5.3-codex-spark`) 잔존 0건 — 모델명은 단일 출처 파일에만.
- 정상 모델 경로 회귀 없음: 유효 모델로 코드리뷰 PASS 시 기존대로 통과 표시 생성.
- `bash -n` 구문 통과. `tests/test_codex_model_failsoft.sh` 통과.

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - codex 실행 래퍼에 신규 인터페이스(단일 출처 모델 라우팅 + 출력 패턴 fail-soft) 추가 → feature 성격 지배
  - codex 호출/출력 처리 경로 변경이라 보안 리뷰는 standard 로 보수적 적용
  - 단일 출처 파일 1 + 래퍼 1 + SKILL 2 + 테스트 1 로 medium
approved_by_user: true
