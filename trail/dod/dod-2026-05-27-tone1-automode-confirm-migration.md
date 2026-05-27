# TONE-1 + 자동모드 → confirmed.md 이관 (docs only)

- 날짜: 2026-05-27
- 유형: docs (backlog cleanup)
- plan ref: 없음 (단발 cleanup)
- 선행 commit: dev `080455e` (자동모드 시맨틱 ship), `413169d` (TONE-1 ship)

## 범위

두 항목 모두 dev 에 ship 완료됐지만 `need-to-confirm.md` 표/상세가 아직 "in-progress" / "RESOLVED 표기 후 이관 대기" 로 남음. 단발 docs cycle 으로 정리.

## 변경 파일

- `need-to-confirm.md` (modify — TONE-1 행 strike, TONE-1 상세 섹션 제거, 자동모드 entry 통째 제거)
- `confirmed.md` (modify — TONE-1 + 자동모드 resolution entry 추가, dev commit reference)
- `trail/dod/dod-2026-05-27-tone1-automode-confirm-migration.md` (본 DoD)
- `trail/dod/.active-dod` / `.codex-reviewed` (light tier)
- `trail/inbox/2026-05-27-tone1-automode-confirm-migration.md` (완료 시점)
- `trail/index.md` (다음 진입점)

## 검증 기준

1. need-to-confirm 한눈 표에서 TONE-1 행 strike + 자동모드 entry 부재
2. confirmed.md 에 TONE-1 + 자동모드 entry (commit reference 포함) 추가
3. need-to-confirm 의 TONE-1 상세 섹션 (line 110-135 부근) 제거
4. plugin drift 0
5. 회귀 무영향 (docs only 라 hook/test 영향 없음)

## 라우팅 추천

agent: rein:docs-writer
skills: []
mcps: []
security_tier: light
approved_by_user: true
rationale: |
  docs-only cleanup. need-to-confirm/confirmed.md markdown 이동만. 코드/hook
  영향 0. security_tier: light 적정 (정적 markdown 편집).

  사용자 명시 "TONE-1 마무리하고 남은 작업 3개는 뭔지 다시한번 보자" =
  TONE-1 이관 implicit approval. 자동모드도 같은 stale 상태라 묶음 처리.
