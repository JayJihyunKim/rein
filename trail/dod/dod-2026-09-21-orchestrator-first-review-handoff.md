# DoD: 메인 세션 지휘 기본화 구현 1/4 — 워커 리뷰 이관 예외 명문화 (선행 단계)

- 작성일: 2026-09-21 (작업 시작일)
- 사용자 지시: "푸시하고 바로 구현 들어가" (2026-09-21)
- 이 작업 기록은 계획의 네 커밋 단위 중 **첫 번째만** 가리킨다 — 검토 단위와 범위를 맞추기 위해 단위마다 기록을 따로 쓴다.

## 범위 연결

plan ref: docs/plans/2026-09-21-orchestrator-first-default.md
work unit: Phase 0 / Task 0.1
covers: [OFD-REVIEW-1]

## 범위

IN

- `AGENTS.md` §5-1 에 예외 불릿 1개 — 부모가 웨이브 끝에서 리뷰·증거 발급을 하는 흐름에서는 워커로 실행된 에이전트가 자체 코드 리뷰와 수정 후 재리뷰를 하지 않는다(면제가 아니라 부모로 이관)
- 세 Builder 정의의 `## 완료 기준` 세 줄(코드 리뷰·수정 후 재리뷰·보안 리뷰) 각각에 워커 dispatch 시 / 단독 실행 시 구분
- 메인 세션이 직접 편집한다 (서브에이전트 dispatch 없음 — 계획 Task 0.1)

OUT

- 계획의 나머지 단위(워커 웨이브 1·2, 8월 잠긴 설계 문서 주석) — 이 커밋 뒤 별도 작업 기록
- `plugins/rein-core/agents/orchestrator.md` 금지목록·`feature-builder-worker.md` — 무변경
- 커밋 시점 리뷰 요구 게이트 — 무변경
- 설계 §8 의 분리된 후속 항목

## Definition of Done

- [x] `AGENTS.md` §5-1 예외 불릿 1개 추가 (한 불릿 안에 워커·재리뷰·이관)
- [x] 세 Builder 정의 × 세 의무 = 9줄 전부에 `워커 dispatch 시` 구분
- [x] 계획 Task 0.1 확인 명령 전부 통과
- [x] 코드 리뷰 + 보안 리뷰 통과 → 커밋

## 검증 기준

- `awk '/^## 5-1\./,/^### 리뷰 에스컬레이션/' AGENTS.md | grep -F '워커' | grep -F '재리뷰' | grep -cF '이관'` → 1 이상
- 세 Builder 정의 각각에서 세 줄 × `워커 dispatch 시` = 3/3
- `bash tests/scripts/test-feature-builder-variants.sh` → 통과 (무변경)
- `bash tests/rules/run-all.sh`, `bash tests/agents/run-all.sh` → 회귀 없음
- `git diff --stat -- plugins/rein-core/agents/orchestrator.md` → 출력 없음

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: standard      # 규칙·에이전트 정의 4개 파일의 문구 변경 — 판단 불명확 시 기본값
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 새 기능(지휘 기본화)의 선행 단위 → 구현 유형. 단, 계획 Task 0.1 이 "메인 세션 직접 편집, 서브에이전트 dispatch 없음" 을 요구한다 — 하위 에이전트로 실행하면 이 단위가 고치려는 바로 그 규칙 충돌(하위 에이전트 자체 리뷰 의무 vs 부모 리뷰) 아래 놓이기 때문
  - 리뷰는 codex-review, 보안 리뷰는 rein:security-reviewer
approved_by_user: true  # 사용자 지시 "푸시하고 바로 구현 들어가" (2026-09-21) — 계획이 정한 실행 방식 그대로

## 변경 파일

- AGENTS.md
- plugins/rein-core/agents/feature-builder.md
- plugins/rein-core/agents/feature-builder-fix.md
- plugins/rein-core/agents/feature-builder-refactor.md
- trail/inbox/2026-09-21-orchestrator-first-review-handoff.md
- trail/index.md
