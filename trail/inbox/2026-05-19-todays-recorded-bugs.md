# 2026-05-19 기록 버그 3건 해결 (PD-1 · PD-2 · GUARD-1)

- 날짜: 2026-05-19
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/lib/project-dir.sh (PD-1)
  - scripts/rein-mark-spec-reviewed.sh + plugins/rein-core/scripts/rein-mark-spec-reviewed.sh (PD-1)
  - scripts/rein-codex-review.sh + plugins/rein-core/scripts/rein-codex-review.sh (PD-2)
  - plugins/rein-core/hooks/pre-bash-guard.sh (GUARD-1)
  - plugins/rein-core/rules/operating-sequence.md, plugins/rein-core/rules/security.md, .claude/CLAUDE.md (GUARD-1 문서 동기화)
  - tests/hooks/test-project-dir-resolution.sh, tests/hooks/test-pre-bash-guard.sh, tests/hooks/test-pre-bash-guard-command-anchoring.sh, tests/skills/test-codex-review-wrapper.sh, tests/skills/test-codex-review-stale-stamp.sh
  - confirmed.md, need-to-confirm.md, trail/dod/dod-2026-05-19-todays-recorded-bugs.md
- 요약: need-to-confirm.md 의 2026-05-19 기록 버그 3건 해결. PD-1 = `resolve_project_dir` 의 고정 2단계 `../..` 가정을 caller-depth-agnostic `trail/` walk-up + script_dir-anchored git 으로 교체 (1단계 `scripts/*.sh` caller 가 repo 부모를 반환하던 버그), `rein-mark-spec-reviewed.sh` 는 temp+atomic-rename fail-closed. PD-2 = codex-review wrapper 가 `cd` 전 PROJECT_DIR 을 git toplevel + `trail/` 로 sanity check. GUARD-1 = pre-bash-guard 의 테스트 *실행* 게이트 제거 (커밋 게이트 유지, TDD red-green 허용 — 사용자 승인). codex 코드리뷰 3R (NEEDS-FIX→NEEDS-FIX→PASS) + security 리뷰 PASS, 9개 파일 127 테스트 PASS. confirmed.md 이관 완료. codex 가 동반 지적한 spec-review staleness gap 은 SR-1 로 need-to-confirm.md 신규 등재. dev 작업 — main 미머지/미태그.
