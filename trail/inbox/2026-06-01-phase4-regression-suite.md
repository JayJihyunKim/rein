# Phase 4 — 회귀 테스트 스위트 통합

- 날짜: 2026-06-01
- 유형: test
- plan ref: docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md §Phase 4
- 변경 파일:
  - `tests/scripts/test-wave-scheduler-and-parent-delta.sh` (신설, 8 단언)
  - `tests/agents/run-all.sh` (신설 — 다른 디렉토리 패턴 따라 agents 러너)
  - `tests/scripts/run-all.sh` (신규 테스트 + 미등록이던 test-pln1-execution-strategy 등록)
- 요약:
  병렬 실행 재설계 Phase 4 완료 — 회귀 그물 완성. (4.1) 결정적 스케줄러와 부모 델타 검증의
  **동작(product 표면)** 테스트 신설: schedule emitter 를 직접 호출해 혼합 ready 집합의 웨이브
  순서(edit_only 동시 → mutating 단독)·absent-section exit 0 을 단언, 임시 git repo 에서 스킬과
  동일한 `git status --porcelain=v1 -z -uall` 명령으로 델타 ⊆ scope union 검증(in-scope 수용 /
  out-of-scope 거부 / untracked 디렉토리 미collapse). (4.2) tests/agents/run-all.sh 신설(유일하게
  러너 부재였음), 신규 테스트를 CI 도달 러너 tests/scripts/run-all.sh 에 등록. 5개 디렉토리 러너 전부 GREEN.
- 실행 방식: 단일 feature-builder subagent 순차(4.1→4.2).
- 리뷰:
  - codex R1 HIGH: 델타 부분집합 검사가 공백 구분 문자열 + 부분문자열 매칭이라 공백 포함
    경로에서 오탐 가능 → 배열 + 정확비교로 수정 + 공백경로 회귀 케이스(c1 거부/c2 수용) 추가 →
    codex R2 PASS. (테스트 본연의 경로 처리 soundness 버그를 테스트 자체에서 잡은 셈.)
  - security standard PASS — test/runner bash 만, 임시 repo 격리(mktemp+local identity+trap),
    파괴적 git clean 도 서브셸 내 임시 repo 한정, NUL-safe 파싱, 주입·시크릿 없음.
  - subagent 가 TDD 중 NUL 스트림이 명령치환에서 소실되던 1차 버그도 자체 발견·수정.
- surface (구조적 관찰, 미조치): CI(tests.yml)는 hooks·scripts 러너만 invoke — agents/skills/rules
  러너는 로컬 전용. 신규 스케줄러/델타 테스트는 scripts 러너에 있어 CI 도달. CI 표면을 agents/skills
  까지 확장할지는 별 결정(test-ci-matrix 가 현재 hooks+scripts 만 강제).
- 다음: Phase 1~4 전부 완료 → 병렬 실행 재설계 종결. 잔여 = main 병합(버전 bump 판정) + index 갱신 + 자동모드 해제.
