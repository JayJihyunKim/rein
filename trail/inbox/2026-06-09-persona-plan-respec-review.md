# plan-writer — persona preset plan re-review (NEEDS-FIX 반영 후 재검토)

Plan complete: docs/plans/2026-06-09-persona-preset-implementation.md
Revision applied: Task 2.1 의 PP-2 fail-open 분기 테스트 보강 (author 결정 = 테스트 추가)
  - 추가 자동 assert (e)~(i): 파일부재 / 파싱실패 / non-dict / enabled 키 부재 / preset 키 부재
  - (j) PyYAML 부재 = 코드 인스펙션 수동 정당화
  - 매트릭스 PP-2 행 + Task 2.1 covers 에 검증(Task 2.1) 참조 추가 (검증 누수 해소 의도)
validator: exit 0 (coverage-matrix scope-id-version=v1)
coverage-mismatch marker: 없음

Spec review: NEEDS-FIX (codex gpt-5.5 / high — 재검토 round)
  - High 1건: PP-2 의 PyYAML 부재 분기 (j) 가 여전히 수동 코드 인스펙션. codex 는
    저렴하게 자동화 가능하다고 판정 — temp PYTHONPATH 에 ImportError 던지는 yaml.py
    를 심어 import-time `yaml = None` 경로를 실제로 태운 뒤 `--persona` 가 exit 0 +
    `boss-ace` 출력하는지 assert (PyYAML 제거 불필요).
  - PP-2 status = PARTIAL (구현 매핑 OK + (e)~(i) 자동 assert 건전, 그러나 (j) 미자동화).
  - 나머지 PP-1, PP-3~PP-14 = MATCH. 신규 scope gap 없음. CONTRADICTS 없음. orphan 없음.
    (b)(c)(d) opt-out/format/membership assert 불변·건전.

Stamp: 생성 안 됨 (.spec-reviews 에 이 plan 의 .reviewed/.pending 마커 부재 유지)
Stamp 분리 검증: .codex-reviewed 미오염 (기존 governance-e2e 코드리뷰 stamp Jun 9 11:08 그대로,
  spec review 가 건드리지 않음), .review-pending 부재.

Next (수동 개입 경로 — self-fix loop 없음, Codex spec review 피드백 자동반영 protocol 부재):
  (1) review High 이슈 plan 에 반영 — author 가 (j) 를 수동 정당화에서 자동 assert 로 승격할지 결정.
      codex 제안 = temp PYTHONPATH 에 raise-ImportError yaml.py shim → loader 의 import-time
      yaml=None 경로 실측. Task 2.1 의 (j) 를 자동 assert (k 또는 (j) 자리) 로 전환하고
      자동 assert 카운트 9→10 으로 갱신.
  (2) validator 재실행
  (3) 수동 /codex-review 호출 또는 plan-writer 재실행
