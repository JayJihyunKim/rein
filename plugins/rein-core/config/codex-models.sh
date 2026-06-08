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
#   ANALYSIS_MODEL — 설명 / 분석 / second opinion (/codex-ask). 범용 추론 모델.
#   CODE_MODEL     — 코드 리뷰 게이트 (/codex-review). 코드 특화 모델.
#
# 모델 로드 실패(codex 가 "is not supported" / invalid_request_error 응답) 시
# 래퍼와 스킬이 이 파일 경로와 해당 변수명을 짚어 갱신을 안내한다.
#
# 이 파일은 `source` 되어 변수만 노출한다 — 실행 side effect 가 없어야 한다.

# shellcheck disable=SC2034  # source 되어 외부에서 사용됨

# 역할별 모델명.
ANALYSIS_MODEL="gpt-5.5"
CODE_MODEL="gpt-5.3-codex-spark"

# 역할별 기본 reasoning effort (low | medium | high).
# 코드리뷰 래퍼는 변경 규모 기반 [EFFORT:] 자동 판정을 우선하고,
# 이 값은 마커가 없을 때의 폴백/기본값으로 쓰인다.
ANALYSIS_EFFORT="high"
CODE_EFFORT="high"
