# Phase 2 — parallel-execute 스킬 신설 (웨이브 스케줄러 + 워커 계약 + 부모 통합)

- 날짜: 2026-06-01
- 유형: feat
- plan ref: docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md §Phase 2
- 변경 파일:
  - `plugins/rein-core/skills/parallel-execute/SKILL.md` (신설, 6093 byte ≤ 6144 NFR)
  - `tests/skills/test-parallel-execute-skill.sh` (신설, 33 단언)
  - `tests/skills/run-all.sh` (신규 테스트 등록)
  - `trail/dod/dod-2026-06-01-phase2-parallel-execute-skill.md` (DoD)
- 요약:
  병렬 실행 재설계 Phase 2 완료. 활성 plan 의 `## 실행 전략` v2 를 읽어 위상정렬 웨이브로
  나누고, 독립 edit_only 태스크를 같은 트리에서 병렬 서브에이전트로, mutating·의존 태스크는
  순차 실행하는 `parallel-execute` 스킬을 신설. Phase 1 의 schedule emitter
  (`rein-validate-coverage-matrix.py schedule`) 를 canonical 순서 SSOT 로 소비. 워커는 공통
  결과 스키마 6키(task_id/status/changed_files/blocked_reason/recommendation/summary)를 최종
  메시지로 반환, 부모는 클린 시작 → 웨이브 델타 ⊆ scope union 검증 → 위반 reject → 웨이브당 1커밋.

- 리뷰:
  - codex (medium 1): 테스트가 결과 스키마 `summary` 키 미검증 → 단언 추가로 해소.
  - security standard (medium 1): 경로 안전화가 `..` 만 명시, 표준 #7 의 절대경로·NUL·드라이브
    문자·symlink(realpath) 누락 + 검증기가 이 토큰들을 안 걸러 step4 가 유일 방어선 → reject
    집합 전체 + realpath containment + scope·델타 동일 정규형으로 확장, 재리뷰 PASS.
  - 6144 byte 예산: 보안 확장으로 6258 초과 → 목적/preflight/host-fallback/보고 섹션 무손실
    압축으로 6093 복귀 (모든 테스트 키워드 보존).

- 다음:
  - **Phase 3**: plan-writer v2 (depends_on + edit_only/mutating 판단) + pre-edit-dod-gate 의
    PLN-1 parallelizable 블록 제거 + 워크트리 기계 폐기 (worktree-cleanup.md + feature-builder-worker 재작성).
  - **Phase 4**: 회귀 테스트 스위트 통합 (validator + 스케줄러 + 부모 end-to-end).
  - main 병합 시 patch bump (새 user-exposed 스킬 추가 — minor 후보이나 시리즈 종결 후 일괄 판정).
