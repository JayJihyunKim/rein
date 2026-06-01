# Phase 3 — plan-writer v2 + PLN-1 게이트 제거 + 워크트리 기계 폐기

- 날짜: 2026-06-01
- 유형: refactor
- plan ref: docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md §Phase 3
- 변경 파일:
  - `plugins/rein-core/agents/plan-writer.md` (3.1 — `## 실행 전략 결정` v1→v2 재작성)
  - `tests/agents/test-plan-writer-exec-strategy-v2.sh` (3.1 신설, 11 단언)
  - `plugins/rein-core/hooks/pre-edit-dod-gate.sh` (3.2 — PLN-1 parallelizable 블록 제거)
  - `tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh` (3.2 재작성, 7 단언 — 블록 부재 + 타 분기 intact)
  - `plugins/rein-core/agents/feature-builder-worker.md` (3.3 재작성, 4074 byte)
  - `plugins/rein-core/docs/worktree-cleanup.md` (3.3 삭제)
  - `plugins/rein-core/rules/operating-sequence.md` (3.3 dangling worker-result.json 참조 정리)
  - `tests/agents/test-ag2-worktree-frontmatter.sh` (3.3 재작성, 22 단언)
- 요약:
  병렬 실행 재설계 Phase 3 완료 — 구 v1 surface 정리. (3.1) plan-writer 가 v2 `## 실행 전략`
  (depends_on + edit_only/mutating 판단 + 예상 write-set scope + 동시쌍 disjoint) 을 생성하도록
  전환, 구 3-axis/parallelizable/workers[]/worktree-cleanup 참조 제거. (3.2) pre-edit-dod-gate 의
  PLN-1 parallelizable 차단 블록(워크트리 worker-marker 우회 포함) 통째 제거 — DoD/라우팅/spec-review
  /incident 게이트 분기는 전부 보존. (3.3) feature-builder-worker 를 같은-트리 edit-only 워커로
  재작성(Phase 2 결과 스키마 6키 일치, isolation:worktree·marker·result.json·cleanup·cherry-pick
  제거), worktree-cleanup.md 삭제, operating-sequence.md 의 worker-result.json 언급 정리.
- 실행 방식: 세 작업 file-disjoint → 병렬 subagent(feature-builder-refactor) 3개 동시 dispatch,
  부모가 사후 통합 검증 + 단일 커밋 (parallel-execute 모델 dogfood).
- 리뷰:
  - codex PASS (차단 결함 0, 세 Scope 전부 MATCH, 게이트 분기 intact 확인, dangling 참조 0).
    테스트 grep 기반이라 일부 PARTIAL — codex "grep 계약 테스트로 수용 가능" 판정.
  - security standard PASS — 게이트 제거가 workflow-only 블록 제거이며 보안 regression·우회 없음,
    워커 금지 계약(커밋·표시·trail 자체 생성 불가) 유지, 주입·시크릿 없음.
  - 회귀: test-dod-gate 8/8, 3 신규/재작성 테스트 GREEN, dangling 참조 0, 게이트 구문 OK.
- 다음: Phase 4 (결정적 스케줄러 + 부모 델타 검증 동작 테스트 + run-all 등록 + 전체 그린).
