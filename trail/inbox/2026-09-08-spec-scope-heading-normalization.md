# 2026-09-08 — 자기증폭 봉합 spec 문구·제목 정규화 완료 (문서 전용 사이클)

대상 DoD `trail/dod/dod-2026-09-08-spec-scope-heading-normalization.md`. 커밋 dev `720704d`(문서 전용, 리뷰 주제 비어 있음). 사용자 승인 2026-09-08.

## 무엇이 바뀌었나
- `docs/specs/2026-08-27-review-cycle-selfamplification.md` §7 (h2) 와 Scope 총계 계약: "혼합 tier 가 envelope 에 실린다" → 스캐너 수준(`QUANT_FLAGS` 혼합 10건, 테스트 S6)과 envelope 수준(advisory-only 10건, 테스트 E16)으로 분리 서술. 구현·테스트 무변경(이미 이 계약대로).
- 제목 `## 9. Scope Items` → `## Scope Items`(리뷰 래퍼 자동 추출기 `^## Scope Items` 접두 매칭 규약). 본문·plan 의 "§9" 참조는 절 첫머리 안내로 대응. 같은 awk 규칙으로 Scope ID 23개 추출 확인, plan 검증기 통과.

## 리뷰
- spec 편집으로 미리뷰 표식 재발생 → 회차 예산 소진(5/5) 상태라 사용자 결정으로 `[MAX_ROUNDS:6]` 연장 선언(카운터 이력 기록) 후 codex 설계 리뷰 6회차 **PASS**(비차단 참고 1: "정확 일치" 는 엄밀히 행 전체가 아니라 접두 매칭 — 결정 무영향) → 표식 발급(reviewer codex). 이 spec 의 표식은 이제 사용자 승인 종결이 아니라 codex 통과 표식이다.

## 잔여
- Low 3건(advisory 분기 `QUANT_FLAGS` 변수 / SV29 픽스처 역방향 / 워커 stash 구조적 차단), v2.0.3 후속 Low 4건, pending incident 결정(커밋 메시지 포맷·coverage-mismatch 클래스).
