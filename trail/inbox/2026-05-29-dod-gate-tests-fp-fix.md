# DOD-GATE-FP-TESTS — spec 검토 게이트 tests/ false-positive 차단 수정

- 날짜: 2026-05-29
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/pre-edit-dod-gate.sh (spec 게이트에 tests/ 면제 분기 추가, line 525-550)
  - tests/hooks/test-pre-edit-dod-gate-spec-tests-exempt.sh (회귀 테스트 신규, 5 케이스)
  - tests/hooks/run-all.sh (러너 등록)
- 요약: spec 검토 게이트가 미리뷰 사양 존재 시 편집 대상 경로를 보지 않고 전역 차단하던 탓에
  tests/** 편집(reproduction-first/TDD)까지 막던 버그(2026-05-28 incident 351623296a9bc1d8, 5회)를
  수정. FILE_PATH 가 PROJECT_DIR/tests/ 하위로 resolve 되면 차단을 skip(Python realpath+commonpath,
  fail-closed). 실제 소스(plugins/scripts/src)는 차단 유지. reproduction-first 로 RED→GREEN 증명.

## 검증
- 신규 회귀 5/5 통과. 관련 기존 스위트 회귀 없음: spec-review-gate(27), pre-edit-dod-gate(14),
  sr-1-b(5), pln1-enforce(6), dod-gate(8).
- codex 코드 리뷰 PASS (gate-bypass·경로탈출·심볼릭링크·fail-closed 적대적 검토, 차단급 결함 0).
- 보안 검토 PASS (권한 우회·fail-closed·인자 안전성 실측, 차단 이슈 0).
- bash -n 통과.

## 부수 발견 (백로그 stale 정정)
작업 중 코드 확인 결과 아래 두 항목이 이미 구현돼 있었음 — need-to-confirm.md 가 stale 였음:
- **SR-1.b**: orphan .reviewed 백스톱이 pre-edit-dod-gate.sh:450-522 에 이미 구현됨
  (orphan .reviewed 순회 + spec mtime vs reviewed= 비교, fail-closed). → 해결됨으로 정정.
- **G3 (execution-mode advisor)**: 021bbf9 (2026-05-27) 로 route-time(routing-map.md) +
  run-time(post-edit-meta-check.sh) 양 layer + DoD-writer 5종 + 회귀 5테스트 ship 완료.
  "다음 1순위 후보" 표기는 stale. 잔존은 성능 후속(G3-perf-NFR)뿐.

## 커밋/머지 상태
- dev working tree 에 미커밋. 사용자가 commit/push 를 별도 지시하지 않아 dev 누적 상태로 유지.
- 리뷰 완료 표식 2종(코드/보안) 생성 완료 — 추후 commit 시 게이트 통과 가능.
