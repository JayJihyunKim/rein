#!/usr/bin/env bash
# plugins/rein-core/config/codex-models.sh
#
# codex 모델 단일 출처 (Single Source of Truth).
#
# codex 가 모델을 rename 하면 (예: gpt-5.3-codex → gpt-5.3-codex-spark)
# **이 파일 한 곳만** 고친다. 래퍼(rein-codex-review.sh)와 스킬
# (codex-review / codex-ask)은 모델명을 직접 박지 않고 이 값을 참조한다.
#
# 역할 분리:
#   ANALYSIS_MODEL — 설명 / 분석 / second opinion (/codex-ask).
#   CODE_MODEL     — 코드 리뷰 게이트 + 자동 문서(설계서/플랜) 리뷰 (/codex-review).
# 현재 두 역할 모두 gpt-5.5 범용 모델을 쓴다. 역할 분리는 향후 코드 특화
# 모델로 재분리할 수 있도록 변수만 유지한다(값이 같아도 무방).
#
# 모델 로드 실패(codex 가 "is not supported" / invalid_request_error 응답) 시
# 래퍼와 스킬이 이 파일 경로와 해당 변수명을 짚어 갱신을 안내한다.
#
# 이 파일은 `source` 되어 변수만 노출한다 — 실행 side effect 가 없어야 한다.

# shellcheck disable=SC2034  # source 되어 외부에서 사용됨

# 역할별 모델명.
ANALYSIS_MODEL="gpt-5.5"
CODE_MODEL="gpt-5.5"

# 역할별 기본 reasoning effort (low | medium | high).
# 우선순위: 프롬프트 [EFFORT:] 마커 > 래퍼의 변경 규모 기반 산출(_compute_effort) >
# 이 값(폴백). 즉 CODE_EFFORT 는 마커가 없고 산출 측정마저 실패/불가할 때에만
# 적용되는 fail-closed 기본값(high)이다 — 측정이 안 될 때 약한 effort 로
# 떨어지지 않도록 가장 높은 단계로 고정한다. 값 변경 금지.
ANALYSIS_EFFORT="high"
CODE_EFFORT="high"
