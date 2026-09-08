# DoD — 자기증폭 봉합 spec 문구·제목 정규화 (문서 전용)

- date: 2026-09-08 착수
- plan ref: 없음 (문서 전용 — v2.1.0 배포 후 잔여 후속)
- approved_by_user: true (2026-09-08 "문서 전용 사이클 승인, spec 문구·제목 정규화 진행해")

## 배경

v2.1.0 구현 리뷰에서 spec 두 곳이 지적됐다: §7 (h2)·Scope 총계 계약이 "혼합 tier 가 envelope 에 실린다"고 썼으나 실제로는 reject 가 있으면 envelope 이 조립되지 않아 관측 불가(문서 정정 대상), 그리고 제목 `## 9. Scope Items` 가 리뷰 래퍼 자동 추출기의 `## Scope Items` 정확 일치 규약과 달라 매 회차 수동 복구가 필요했다. 배포 중에는 spec 편집이 표식을 무효화하고 그 spec 의 리뷰 회차 예산이 소진 상태라 보류했다.

## 범위

1. `docs/specs/2026-08-27-review-cycle-selfamplification.md`: (h2) 를 스캐너/envelope 두 층으로 분리 서술, Scope 총계 계약 문구 정정, 제목 `## Scope Items` 로 정규화(+ 절 첫머리에 "§9 참조 대응" 안내), §12 에 사이클 기록.
2. 포함하지 않음: plan 편집(plan 의 "§9" 참조는 그대로 유효 — 절 안내로 대응), 코드·테스트 변경(구현은 이미 정정된 계약대로).

## 변경 파일

- docs/specs/2026-08-27-review-cycle-selfamplification.md

## 검증 기준

- [x] 래퍼 추출기 규약대로 `## Scope Items` 절에서 Scope ID 23개가 추출됨(awk 재현).
- [x] plan 검증기(`rein-validate-coverage-matrix.py plan`)가 여전히 통과.
- [x] 편집으로 생긴 미리뷰 표식을 사용자 결정 방식(회차 연장 후 codex 재리뷰 / 문서 전용 스킵 승인 후 표식)으로 해소 → dev 커밋(문서 전용, 리뷰 주제 비어 있음).

## 라우팅 추천

agent: rein:docs-writer
skills: []
mcps: []
security_tier: light
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 문서 문구 2곳 + 제목 1곳, 코드 무변경
approved_by_user: true

## 완료

- 2026-09-08 dev `720704d`. 추출기 23개 추출·plan 검증기 통과, 회차 연장(사용자 승인) 후 codex 설계 리뷰 PASS → 표식(reviewer codex). 상세 `trail/inbox/2026-09-08-spec-scope-heading-normalization.md`.
