# 2026-08-27 — 리뷰 사이클 자기증폭 봉합: 방향 확정 후 별도 사이클로 중단

v2 배포 우선을 위해 spec 단계에서 중단. **방향은 확정**, 재개 지점 명확.

## 진행 상태

- **brainstorm 완료** (`docs/brainstorms/2026-08-27-review-cycle-selfamplification.md`): Option B = **축1 중심**(입력 표면 축소):
  1. 리뷰 요청서 증거 블록 밖 변동 수치/PASS 주장 hard reject(현 advisory→reject).
  2. 주석 규칙 개정(지속 계약만, 이력·수치는 대장으로; **바뀐 주석 줄만** 검사).
  3. 문서-only SUBJECT_EMPTY 조기 통과(자가검증 관문 앞).
- codex-ask 2회: 1차(waiver+severity+예산 방향)는 spec-review High 2건(면제 배선 붕괴·승인 신뢰경계)으로 **폐기**, 2차(축1)는 **조건부 찬성**.
- **spec 초안 2회차 NEEDS-FIX**(`docs/specs/2026-08-27-review-cycle-selfamplification.md`, 미완성): 방향 맞음, 설계 세부 지적 — High 2건(① 문서-only 조기통과 순서가 변경파일 취득실패 fail-closed 를 가림 → A5→A6→A7 순서 재배치 + changed_files_rc≠0 우선 / ② "고정계약 수치 허용 vs 실행결과 건수 증거필수" 선언과 실제 규칙 불일치 → 구분 판정 추가) + Medium 4(added vs modified 표현 통일·회귀 계약 5개 Scope 승격·함수 줄번호·출처 연결).

## 범위 밖 (별도 후속)

축2(완전한 코드-무변경 축약 리뷰): NEEDS-FIX 회차엔 축약 base(이전 PASS 증거) 부재 + 리뷰 시점 X snapshot 복원 설계 필요. "실행범위 PASS 체크포인트 + content-addressed snapshot" 사이클.

## 재개 시

spec High 2건(순서 재배치 + 고정계약/실행결과 구분) + Medium 4 반영 → 재리뷰 → plan → 구현. spec pending 표식은 봉합 중단으로 제거(재개 시 재작성+재리뷰).

## 자기 관찰

이 봉합 자체가 "리뷰 사이클 자기증폭"의 실사례 — spec 이 2회차 회차를 돌았고, 그 과정이 정확히 봉합하려던 문제였다.
