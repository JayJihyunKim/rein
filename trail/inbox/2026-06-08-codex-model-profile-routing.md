# 2026-06-08 — codex 역할별 모델 단일 출처 + 모델 fail-soft

DoD: `trail/dod/dod-2026-06-08-codex-model-profile-routing.md`

## 무엇을

codex 모델명이 SKILL.md 6군데에 하드코딩돼 있어 codex 가 모델을 rename 하면(`gpt-5.3-codex` → `gpt-5.3-codex-spark`) 죽은 모델명이 남아 조용히 로드 실패하던 문제 해결. 사용자 결정으로 모델명을 rein 단일 출처 1곳에 모으고, 로드 실패 시 위치를 짚어 안내하는 fail-soft 추가.

## 결정 (사용자)

- 모델명을 rein 배포물 안 단일 파일에 둔다(역할별 외부 codex profile 방식은 기각 — 사용자에게 역할 분리를 기본 제공하려면 rein 이 모델명을 알아야 하므로).
- 모델 로드 실패 시 "모델명이 변경된 것 같다 → 이 위치를 고쳐라"를 경로와 변수명까지 안내.
- 강도: 코드리뷰는 기존 변경규모 기반 자동 판정 유지, 분석(codex-ask)은 질문 제거하고 역할 기본값 사용.

## 스파이크 (전제 검증)

- codex moving alias(`gpt-5-codex`/`gpt-codex`)는 ChatGPT 계정 경로에서 미지원 → 무인 추적 불가, 사람이 한 곳에서 관리.
- 모델 거부 시 codex 종료 코드 1 + 출력 `invalid_request_error`/`is not supported`(직접 실행 실측; 이전 "exit 0" 결론은 `| tail` 파이프 아티팩트였음을 정정).

## 한 것

- `plugins/rein-core/config/codex-models.sh` 신설 — `ANALYSIS_MODEL`/`CODE_MODEL` + EFFORT 단일 출처. source-only.
- `rein-codex-review.sh` — config source, `CODE_MODEL` 을 `-m` 배열 전달(빈값이면 생략 graceful), `_detect_model_error`/`_emit_model_failsoft`, 모델 거부 시 전용 exit 3 + 단일 출처 수정 안내(sonnet fallback 차단). **오탐 가드**: `FINAL_VERDICT` 라인이 있으면(정상 리뷰가 거부 문구를 본문에 인용한 경우 포함) 거부로 판정하지 않음.
- `codex-ask`/`codex-review` SKILL.md — 하드코딩 모델명 제거, 단일 출처 참조, codex-ask 모델 질문 제거, exit 3 폴백 금지 규칙.
- `tests/skills/test-codex-model-failsoft.sh`(15 assertions) 신설 + `run-all.sh` 등록.

## 검증

- 신규 테스트 15/15, `tests/skills/run-all.sh` ALL SUITES PASSED, 기존 codex-review 테스트 회귀 없음(33/33 등).
- 코드 리뷰: codex(gpt-5.3-codex-spark, dogfood) 4 라운드 끝에 PASS. R1 패턴 보강, R2 CI 편입+문서 동기화, R3→R4 에서 **dogfood 가 fail-soft 자체의 오탐 결함을 포착**(정상 PASS 본문의 거부 문구 인용을 거부로 오인 → exit 3) → FINAL_VERDICT 가드 + 회귀 테스트 T7 로 수정.
- 보안 리뷰: standard, 통과(injection 불가/ReDoS 없음/민감정보 없음; fail-soft 가 거짓 PASS 우회 차단으로 보안 개선).

## 발견한 별개 이슈 (이 작업 범위 밖)

1. **active DoD 선택기가 plan 없는 DoD 를 거부** — `select-active-dod` 가 `## 범위 연결` 섹션을 요구하는데, 이 섹션은 plan 기반 작업에만 있고 단순 기능 DoD(route-doc-1/onboard-1/release-v1-4-5/본 작업)엔 정상적으로 없음. 결과로 마커가 invalid 처리(`trail/incidents/invalid-active-dod-marker.log`)되어 통과 표시의 `active_dod`/`cycle` 라벨이 엉뚱한 DoD(route-bind-1)로 찍힘. operating-sequence 의 DoD 의무 섹션 목록엔 `## 범위 연결` 이 없어 문서↔구현 drift. (리뷰 자체는 내 변경 diff 에 대해 수행돼 유효 — 라벨만 부정확.)
2. **governance-e2e stale** — `tests/integration/test-governance-e2e.sh` 13건 실패가 변경 전 baseline 과 동일. 폐기된 `.claude/hooks/` 경로 참조(Option C Phase 3 후). 본 작업 무관.

## 다음

- dev 커밋 여부 사용자 승인 대기. main 머지/태그는 별도.
- 별개 이슈 1(선택기) 은 felt-value 있는 버그 — 후속 검토 후보.
