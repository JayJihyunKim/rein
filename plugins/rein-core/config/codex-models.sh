#!/usr/bin/env bash
# plugins/rein-core/config/codex-models.sh
#
# codex 모델 단일 출처 (Single Source of Truth).
#
# codex 가 모델을 rename 하면 (예: gpt-5.6-sol → gpt-5.7-*)
# **이 파일 한 곳만** 고친다. 래퍼(rein-codex-review.sh)와 스킬
# (codex-review / codex-ask)은 모델명을 직접 박지 않고 이 값을 참조한다.
#
# 역할 프로필 구조:
#   리뷰 게이트 (/codex-review) — CODE_GATE_MODEL 고정 모델. 규모별 모델
#     혼용 금지(판정 일관성). effort 는 래퍼가 결정: 프롬프트 [EFFORT:] 마커 >
#     변경 규모 기반 산출(_compute_effort, 위험 경로 floor 포함) > fail-closed 폴백.
#   Fail-closed 페어 — CODE_FAIL_CLOSED_MODEL + CODE_FAIL_CLOSED_EFFORT.
#     측정 실패/불가 시 이 모델+effort 페어로 수렴한다. CODE_FAIL_CLOSED_MODEL 은
#     래퍼가 별도 분기하지 않는 의미 필드(게이트 모델과 동일값)다 — "fail-closed
#     는 모델+effort 페어" 라는 정책 의미를 config 표면에 명시하기 위해 존재.
#   Second opinion (/codex-ask) 3계층 — 질문 성격으로 선택:
#     fast(기계적 추출·분류) / default(일반) / deep(고위험·모호 판단).
#
# 모델 로드 실패(codex 가 "is not supported" / invalid_request_error 응답) 시
# 래퍼와 스킬이 이 파일 경로와 해당 변수명을 짚어 갱신을 안내한다.
#
# 이 파일은 `source` 되어 변수만 노출한다 — 실행 side effect 가 없어야 한다.

# shellcheck disable=SC2034  # source 되어 외부에서 사용됨

# ---- 리뷰 게이트 (/codex-review) ----
CODE_GATE_MODEL="gpt-5.6-sol"          # 게이트 고정 모델 — 규모별 혼용 금지 (판정 일관성)
CODE_FAIL_CLOSED_MODEL="gpt-5.6-sol"   # 측정 실패 시 모델+effort 페어의 모델측
CODE_FAIL_CLOSED_EFFORT="high"         # 측정 실패 시 페어의 effort측 (fail-closed)

# ---- Second opinion (/codex-ask) 3계층 ----
ANALYSIS_FAST_MODEL="gpt-5.6-luna"     ANALYSIS_FAST_EFFORT="low"      # 기계적 추출·분류
ANALYSIS_DEFAULT_MODEL="gpt-5.6-terra" ANALYSIS_DEFAULT_EFFORT="medium" # 일반 second opinion
ANALYSIS_DEEP_MODEL="gpt-5.6-sol"      ANALYSIS_DEEP_EFFORT="high"     # 고위험·모호 판단

# ---- 라우팅 정책 버전 (도장 증빙용) ----
CODE_ROUTING_POLICY_VERSION="1"

# ---- Legacy alias (기존 소비자 무중단 — 신값 노출) ----
# 신 변수 정의 **이후** 참조 대입으로 값 드리프트를 구조적으로 차단한다.
# ANALYSIS_MODEL/ANALYSIS_EFFORT 의 default tier(terra/medium) 매핑은 의도된
# 변화다 — 3계층 도입 취지로 기존 ANALYSIS_EFFORT="high" 는 deep tier 로 흡수.
# CODE_EFFORT 는 종전과 동일하게 fail-closed 폴백 의미(high)를 유지한다.
CODE_MODEL="$CODE_GATE_MODEL"
CODE_EFFORT="$CODE_FAIL_CLOSED_EFFORT"
ANALYSIS_MODEL="$ANALYSIS_DEFAULT_MODEL"
ANALYSIS_EFFORT="$ANALYSIS_DEFAULT_EFFORT"
