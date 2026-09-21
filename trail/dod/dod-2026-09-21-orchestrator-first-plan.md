# DoD: 메인 세션 지휘 기본화 — 구현 계획 작성

- 작성일: 2026-09-21 (작업 시작일)
- 입력 설계: `docs/specs/2026-09-10-orchestrator-first-default.md` (2026-09-20 후속 검토 통과, 범위 항목 15개)
- 사용자 지시: "바로 작성 시작해" (2026-09-21 — 계획서 작성 착수 여부를 물은 데 대한 답)

## 범위

IN

- 위 설계의 범위 항목 15개 전부를 덮는 구현 계획 1개 작성 (`docs/plans/2026-09-21-orchestrator-first-default.md`)
- 커버리지 매트릭스 + 태스크별 `covers:` + 실행 전략(의존·모드·쓰기 범위) 첨부
- 커버리지 검사기 통과 후 계획 검토 1회

OUT

- 구현 자체 (규칙 파일·훅·테스트 편집) — 계획 통과 후 별도 작업 기록으로
- 설계 문서 수정 — 계획 작성 중 설계 결함이 보이면 고치지 않고 보고
- 설계 §8 에 분리해 둔 후속 항목 7건을 계획에 끌어들이는 것
- 새 절차·검사·게이트 추가

## 지킬 교훈 (직전 사이클 — `trail/decisions/2026-09-19-review-cycle-wallclock-scope-cut.md`)

- 태스크를 승인 단위로 잘게 쪼개지 않는다. 같은 파일·같은 의존 경계는 한 태스크로 묶는다 (직전에 14개로 쪼갰다가 첫 태스크에서 폐기).
- 검토 지적을 절차 문단으로 계획 본문에 넣어 표면을 키우지 않는다 — 지적은 해당 서술을 고치는 것으로 끝낸다.
- 재검토가 필요하면 `plugins/rein-core/skills/codex-review/SKILL.md` §2 의 후속 요청서 양식을 쓴다.

## Definition of Done

- [x] 계획 파일 작성 — 설계의 범위 항목 15개가 매트릭스에 전부 등재
- [x] 커버리지 검사기 통과 (exit 0), 불일치 표식 없음
- [x] 실행 전략 섹션 첨부 — 동시 실행 가능한 편집 전용 태스크끼리 쓰기 범위가 겹치지 않음
- [x] 계획 검토 — 3회(수정 필요 → 수정 필요 → 통과), 통과 표식 등록. 에이전트 자체 수정 반복 없음 — 회차마다 메인 세션이 지적 처리 방향을 정해 지시, 2·3회차는 후속 요청서 양식
- [x] 완료 기록 작성 + 세션 시작점 갱신

## 검증 기준

- `python3 scripts/rein-validate-coverage-matrix.py docs/plans/2026-09-21-orchestrator-first-default.md` → exit 0
- 매트릭스의 범위 항목 수 = 15 (설계 문서 끝의 개수 확인 명령과 일치)
- 계획 검토 판정과 소요가 `trail/review-events/` 에 한 줄로 남음
- 계획에 `TODO`/`TBD`/자리표시 문자열 없음

## 라우팅 추천

agent: rein:plan-writer
skills:
  - rein:codex-review
mcps: []
security_tier: light         # 계획 문서 한 파일 신규 작성 — 실행 코드 변경 없음
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 설계 → 계획 변환은 라우팅 표의 "plan 작성" 행 → plan-writer (커버리지 매트릭스 필수)
  - 계획 검토는 codex-review 의 계획 검토 모드 (plan-writer 가 자동 호출)
approved_by_user: true  # 사용자 지시 "바로 작성 시작해" (2026-09-21)

## 변경 파일

- docs/plans/2026-09-21-orchestrator-first-default.md
- trail/inbox/2026-09-21-orchestrator-first-plan.md
- trail/index.md
