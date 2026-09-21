# DoD: 메인 세션 지휘 기본화 구현 4/4 — 8월 잠긴 설계 문서 §2.5 대체 주석 (마지막 단계)

- 작성일: 2026-09-21 (작업 시작일)
- 사용자 지시: "푸시하고 바로 구현 들어가" (2026-09-21)
- 이 작업 기록은 계획의 네 커밋 단위 중 **마지막만** 가리킨다. 앞 세 단위는 dev `57837de`, `7033d2c`, `40b65e4` 로 커밋됨.

## 범위 연결

plan ref: docs/plans/2026-09-21-orchestrator-first-default.md
work unit: Phase 3 / Task 3.1
covers: [OFD-LOCK-1]

## 범위

IN — 메인 세션이 직접 한다 (서브에이전트 dispatch 없음, 계획 Task 3.1)

- `docs/specs/2026-08-07-rein-v2-governance-orchestration.md` §2.5 말미(§3 헤더 앞)에 설계 `docs/specs/2026-09-10-orchestrator-first-default.md` §3.6 의 대체 주석 블록을 글자 그대로 추가. 원문은 한 글자도 지우지 않는다.
- 곧바로 그 문서의 설계 검토를 받고 통과 표식을 등록한다 (필수). 요청서에는 변경분이 §2.5 말미 주석 블록 추가 하나(원문 무삭제)임을 적는다.

OUT

- 그 문서의 다른 절·다른 결정(D5 포함) — 어떤 지점에도 주석을 달지 않는다. lock 변경은 §2.5 대체 1건뿐
- 설계 검토가 이번 변경과 무관한 옛 본문을 지적하는 경우의 수정 — 고치지 않고 사용자에게 넘긴다 (위험 수용 / 승인 재도장 / 보류 중 결정)
- 설계 §8 의 분리된 후속 항목

## 계획 대비 이탈

- 잠긴 문서의 설계 검토가 추가 블록의 절 참조 한 곳을 지적(조건 1 의 새 의미는 §3.7 이 아니라 §3.8). 그 문안의 정본인 `docs/specs/2026-09-10-orchestrator-first-default.md` §3.6 을 먼저 고쳐 후속 설계 검토를 통과시킨 뒤 잠긴 문서의 블록을 같은 문안으로 맞췄다. 계획 문서는 §3.6 을 절 번호로만 가리켜 영향 없음.

## Definition of Done

- [x] §2.5 말미에 대체 주석 블록 추가, 삭제된 줄 0
- [x] 그 문서의 설계 검토 통과 + 통과 표식 등록
- [x] 계획 Task 3.1 확인 명령 통과, 두 웨이브 전체에 대한 무변경 계약 경로 확인
- [x] 커밋

## 검증 기준

- `grep -cF 'SUPERSEDED (2026-09-10)' docs/specs/2026-08-07-rein-v2-governance-orchestration.md` → 1
- `grep -cF 'docs/specs/2026-09-10-orchestrator-first-default.md' docs/specs/2026-08-07-rein-v2-governance-orchestration.md` → 1 이상
- `git diff -U0 -- docs/specs/2026-08-07-rein-v2-governance-orchestration.md | grep -E '^-' | grep -vE '^---' | wc -l` → 0
- `git diff --stat 135e69c -- plugins/rein-core/rein/orchestration plugins/rein-core/rules/short/operating-sequence-summary.md plugins/rein-core/tests/orchestration/test_prompt_contract.py tests/hooks/test-security-tier-gate.sh tests/scripts/test-feature-builder-variants.sh tests/scripts/test-plugin-agents-bundle.sh tests/scripts/test-ups1-short-rule-injection.sh` → 출력 없음

## 라우팅 추천

agent: rein:spec-writer
skills:
  - rein:codex-review
mcps: []
security_tier: light         # 설계 문서 한 파일에 주석 블록 추가 — 실행 코드 변경 없음
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 기존 설계 문서의 국소 편집 → 설계 문서 영역. 계획 Task 3.1 이 "메인 세션 직접 편집" 을 지정 — 이 편집이 만드는 검토 대기 표식과 통과 표식은 워커 쓰기 범위로 선언할 수 없기 때문
  - 설계 검토는 codex-review 의 설계 검토 모드
approved_by_user: true  # 사용자 지시 "푸시하고 바로 구현 들어가" (2026-09-21) — 계획이 정한 실행 방식 그대로

## 변경 파일

- docs/specs/2026-08-07-rein-v2-governance-orchestration.md
- docs/specs/2026-09-10-orchestrator-first-default.md
- trail/inbox/2026-09-21-orchestrator-first-lock-supersede.md
- trail/index.md
