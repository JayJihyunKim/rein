# DoD — hook test 드리프트 정리 + 비서톤 2단계 Wave 4 마감

- 날짜: 2026-05-18
- 유형: fix + chore

## 목표

`tests/hooks/` + `tests/rules/` 의 pre-existing 드리프트 23 suite 를 정리하고, hook
비서톤 2단계 cycle 의 Wave 4 (전체 회귀 + versioning v1.3.1) 를 마감한다. 오늘
누적된 모든 변경 (Wave 1~3 + 드리프트 정리) 을 v1.3.1 로 묶어 bump 한다.

## 완료 기준

- **드리프트 정리** (codex 진단 23 suite 기반):
  - Bucket A (~15 suite) — 폐기 경로 `.claude/hooks/` → `plugins/rein-core/hooks/` repoint
  - Bucket B (2 suite) — Wave 3 회귀: test-dod-gate / test-pre-edit-dod-gate `BLOCKED`/`[DoD gate]` 단언 → `[rein]` 갱신
  - #15 test-incidents-automation.sh — migration 4 테스트 + run_migrate() 삭제 (codex 조사: v1.0.1 의도적 삭제 helper) + test_gate_blocks_when_pending 진단·수정
  - #22 test-design-plan-coverage-plugin-size.sh — 크기 예산 10000→12000B 상향
  - #18/#19/#20/#23 — hook 동작 검증 (조사) 후 fixture 갱신
- Task 4.1 — `tests/hooks/**` + `tests/rules/**` 전체 회귀 PASS
- Task 4.3 — `scripts/rein.sh` VERSION 1.3.0→1.3.1, `CHANGELOG.md`, git tag `v1.3.1` (versioning.md Rule A/B 점검)
- codex review + security review 통과

## 범위 연결

plan ref: docs/plans/2026-05-17-hook-message-assistant-tone.md
covers: [S5]
work unit: Phase 4 (Task 4.1·4.3) + 드리프트 정리 (plan 범위 밖 — Task 4.1 "전부 PASS" 충족을 위한 선행 정리, no-bump internal)

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:subagent-driven-development
  - superpowers:dispatching-parallel-agents
mcps: []
rationale: >
  드리프트 23 suite 는 disjoint test 파일 — 병렬 fix agent 다수로 분할 가능.
  feature-builder 가 각 bucket 수행, dispatching-parallel-agents 로 disjoint
  버킷 동시 디스패치. #18~23 은 hook 동작 검증 (read-only 조사) 선행 후 fixture
  갱신. Task 4.1 회귀 → Task 4.3 versioning 은 순차 tail.
approved_by_user: true  # 2026-05-18 사용자 승인 — 병렬 진행 + 3 결정 (#15 4개삭제 / #22 예산 12000 상향 / #18~23 검증선행)
```
