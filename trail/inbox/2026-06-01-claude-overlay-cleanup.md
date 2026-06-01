# .claude/ 오버레이 잔재 정리 (plugin-first 정합)

- 날짜: 2026-06-01
- 유형: refactor
- 변경 파일:
  - 슬림: `.claude/CLAUDE.md` (11단계 시퀀스·orchestrator import 제거, "권위본=plugin 규칙" + 메인테이너 규칙 3종 import만 보존)
  - 삭제(git rm, dev 전용·git history 보존): `.claude/orchestrator.md`, `.claude/workflows/*.md` (5), `.claude/registry/agents.yml`, `.claude/plans/*.md` (2)
  - 참조 정리: `.claude/rules/{branch-strategy,versioning,legacy-shipped-pending}.md`, `AGENTS.md`(에이전트 표 + skill/workflow 참조 → plugin), `scripts/rein-govcheck.py`
  - plugin 규칙(사용자 ship, 사용자 범위확장 승인): `plugins/rein-core/rules/{design-plan-coverage,answer-only-mode}.md`
- 요약: codex-ask second opinion(gpt-5.5/medium)으로 판단 → dev 오버레이가 plugin SSOT와 중복·stale 참조로 세션 시작 시 혼란 유발. CLAUDE.md 슬림화 + 중복/stale 9파일 삭제 + 활성·규칙·plugin 표면의 폐기 경로(`.claude/hooks|skills|agents|orchestrator|workflows|registry`) 참조 전수 정리. govcheck는 ROOT_DOCS에서 orchestrator 제거 + HOOK_GLOB을 plugin 훅으로 재지정(plugin 상대경로 dual-path 해석 추가, 훅 30개 실제 스캔, exit 0).
- 리뷰: codex Round 4 PASS(R1·R3 NEEDS-FIX를 통해 branch-strategy 제외표·AGENTS skill 참조·plugin 규칙 2건·govcheck HOOK_GLOB까지 점진 발견·해소). 보안 light-tier PASS(govcheck dual-path 적대적 입력 8종 no-match로 traversal 불가 실증, 삭제 파일 시크릿 없음, 게이트 약화 없음).
- 검증: 전 표면 live stale 오버레이 참조 0건, govcheck exit 0, CLAUDE.md 메인테이너 규칙 3종 import 보존.
- 미진행: 로컬 커밋만(자동모드). push·main 병합은 진행 중 병렬 실행 시리즈와 함께 별도 승인 대기. 범위/등급: dev 오버레이=릴리스 영향 0, AGENTS.md·govcheck=내부 doc/tooling, plugin 규칙 2건=경로참조 정정(patch급) — 시리즈 종결 시 일괄 bump 판정.
