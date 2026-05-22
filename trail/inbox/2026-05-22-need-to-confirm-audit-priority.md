# need-to-confirm 유효성 검증 + 작업 우선순위 확정

- 날짜: 2026-05-22
- 유형: research (codex-ask second opinion) + docs (note 정리)
- 변경 파일:
  - `need-to-confirm.md` (PERF-1·PERF-3-VERIFY 삭제, BC-INFO1 라인번호 정정, "다음 작업 우선순위" 섹션 추가, 변경이력)
  - `trail/index.md` (다음 진입점 = SR-1)
- 요약: v1.3.4 배포 직후 codex gpt-5.5 high 로 need-to-confirm 전 항목의 현재 유효성을 독립 검증(Mode B). PERF-1·PERF-3-VERIFY 2건이 v1.3.3 아키텍처(short-summary 주입 + dispatcher 단일 entry + `CLASS_NEEDS_BR` 분류)로 RESOLVED 확인 → 삭제. 나머지(G8-3/GE-1/GE-2/SR-1/G3/BC-INFO1/A-LowPrio/자동모드/job-stop) STILL VALID 유지.
- 우선순위 확정: codex 가 need-to-confirm 자체 순위(G8-3 #1)와 플랜 §4 로드맵(v1.5 다음)을 재조정 → **(1) SR-1 → (2) GE-1+GE-2 → (3) v1.5 → (4) 나머지**. 근거: SR-1 은 실재 리뷰 게이트 우회(작고 독립적)이므로 v1.5 인프라 앞에 먼저 닫는다.
- 검증 방식: `/codex-ask` Mode B (stamp 미생성). HEAD `49ed75d`.
- 다음 작업: SR-1 (post-write-spec-review-gate 가 새 `.pending` 작성 시 같은 hash `.reviewed` 제거 또는 freshness 검사).
