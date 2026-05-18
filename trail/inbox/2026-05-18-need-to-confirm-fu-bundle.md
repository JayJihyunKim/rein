# need-to-confirm FU-1~4 묶음 처리

- 날짜: 2026-05-18
- 유형: fix + docs
- 변경 파일:
  - `plugins/rein-core/hooks/pre-bash-guard.sh` — `command_invokes()` clause-앵커 헬퍼 신규 + 명령 분류기 6곳 전환
  - `plugins/rein-core/hooks/post-edit-hygiene.sh` — test 파일 제외 glob `*test_*` → `*/test_*|test_*`
  - `plugins/rein-core/scripts/rein-mark-spec-reviewed.sh`, `scripts/rein-mark-spec-reviewed.sh` — PROJECT_DIR → `resolve_project_dir`
  - `.github/workflows/mirror-to-public.yml` — public mirror push 전 루트 AGENTS.md strip
  - `.claude/rules/branch-strategy.md` — AGENTS.md 분류 갱신 (main 포함 + public strip)
  - `plugins/rein-core/skills/incidents-to-rule/SKILL.md` — Step 4 에 AGENTS.md 부재 분기
  - `tests/hooks/test-pre-bash-guard-command-anchoring.sh` (신규, 18 tests)
  - `tests/hooks/test-post-edit-hygiene-test-file-glob.sh` (신규, 2 tests)
  - `trail/dod/dod-2026-05-18-need-to-confirm-fu-bundle.md` (DoD)
- 요약: `need-to-confirm.md` 의 2026-05-18 후속작업 후보 FU-1~4 를 한 묶음으로 처리.
  FU-4 가 핵심 — `pre-bash-guard` 가 명령을 앵커 없는 substring 으로 분류해 키워드를
  단순 "언급" 한 명령(`grep "pytest"`, `npm pkg set ...=vitest`, `echo "git reset --hard"`)
  까지 과다 차단하던 버그를, clause-앵커 `command_invokes` 헬퍼로 전환해 해소
  (test/commit/coverage/.env[P8]/destructive[P11] 6 분류기). P8 `.env` 는 fail-closed
  로 재설계 (미등록·prefix 변형 시크릿 파일까지 차단). FU-1~3 은 plugin 사용자 관점
  gap (incidents-to-rule AGENTS.md 종착지 / 마켓 클론 inert AGENTS.md / spec-review
  stamp writer-reader 경로 불일치).
- 검증: codex 코드리뷰 R4 PASS (R1~R3 fix 3라운드 — P8 fail-closed·command wrapper
  prefix 보강), 보안 리뷰 PASS (base level), `tests/hooks/` 전체 회귀 `ALL SUITES PASSED`.
- 미커밋: dev 미커밋 상태 — 커밋 + v1.3.1/FU 묶음 main 머지는 사용자 결정 대기.
- 미처리 메모: pre-bash-guard 라인 163 `git (merge|rebase|am)` 면제 분류기도
  unanchored 이나 DoD scope 밖 (FU-4 후속 후보). codex-review wrapper 가 stale
  active DoD 를 envelope 주입 (stamp 의 `cycle`/`active_dod` 가 직전 사이클 DoD 가리킴
  — need-to-confirm G8-3 별건).
