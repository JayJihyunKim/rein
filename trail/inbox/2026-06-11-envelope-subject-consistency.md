# envelope-subject-consistency

작업일: 2026-06-11
DoD: dod-2026-06-11-envelope-subject-consistency.md
brainstorm: docs/brainstorms/2026-06-11-envelope-subject-consistency.md
상태: 완료 (dev 커밋 — 릴리스는 사용자 별도 판단)

## 배경 — 백로그 ①의 방향 전환

원래 백로그는 "codex-review wrapper envelope 슬롯 전면 재설계"였으나, brainstorm Step 0
codex 검증에서 **전면 재설계 기각** (서로 다른 성격의 슬롯을 단일 reference-point 로 묶으면
모델이 악화). Fable/codex 독립 의견이 모두 "경계 있는 정합 수정 + 근본 원인(C) 수정"으로
수렴, 사용자 승인.

## 구현 (4건)

### A. envelope 모드 정합 (wrapper 2사본)
- review_subject 명시 선언 / head_iso 모드별 정직화(working_tree·spec 은 명시 N/A) /
  spec diff_base_iso 명시 N/A / **Tier 2 추측 DoD 컨텍스트 advisory 강등**(표시 qualifier +
  설계정합·claim 노트, Tier 1 은 기존 blocking 유지) / freshness 비교 모드 한정.

### C. 근본 원인 — marker 청소 모순 (session-start-load-trail.sh)
- 청소부가 "`## 범위 연결` 없으면 marker 삭제" 옛 조건 유지 → selector Tier 1 의
  marker-trust(2026-06-09)와 모순 → 정상 marker 세션마다 삭제 → Tier 2 추측 오선택.
  조건 제거 (containment/존재/archived 유지, archived 가 section-less DoD 에도 도달).

### D. 작업 중 발견·수정 — SIGPIPE fail-open 2건 (wrapper)
- D1: fail-soft 가드의 `printf 대용량 | grep -q` 가 pipefail 아래 SIGPIPE(141)로 무력화 —
  Round 1 리뷰가 PASS 인데 wrapper 가 종료 3(모델거부 오인). verdict 파서 비상경로 3건 포함
  `-q` 제거로 수정. v1.4.6 잠복.
- D2 (Round 2 codex High): 모드 감지 `printf | head -1 | grep -q` 동일 클래스 — 대용량 spec
  프롬프트가 code-review 오분류 → **코드 게이트 stamp 오염 가능** (테스트로 실측). 첫 줄
  추출을 파이프 없는 bash 파라미터 확장으로 교체.

## 검증

- TDD: 신규 계약/재현 테스트 11건 모두 red 선행 후 green. wrapper 테스트 54/54.
- 부수: test-codex-review-claim-audit-policy.sh Test 8 의 잠복 실패 수정 (B5 분할로 추출
  anchor 가 깨져 있었음 — skills 러너 CI 미등록이라 미관측).
- codex 3 rounds (R1 PASS → R2 NEEDS-FIX(D2 High) → R3 PASS) + 보안 리뷰 PASS.
- 세 활성 스위트(scripts/hooks/skills) 전부 green.

## 메모

- skills 러너가 CI(tests.yml)에 없음 — 오늘 2번째 같은 클래스 발견 (오전 orphan 테스트 2건,
  오후 Test 8 잠복 실패). CI 등록 검토 후보.
- Round 3 호출이 auto-background 전환으로 hang (출력 0 + CPU 0, 6분) → kill 후 foreground
  재실행으로 정상 — 기존 background-jobs 규칙대로.
- 분류: `/codex-review` 오탐 수정 + 게이트 구멍 봉합 = user-facing patch 급. main 머지/릴리스는
  사용자가 별도 판단 (Rule B: 오늘 v1.5.1 기출고).
