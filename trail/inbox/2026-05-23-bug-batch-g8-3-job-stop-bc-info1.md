# 실제 버그 배치 — G8-3 + job-stop + BC-INFO1 (병렬 agent teams)

- 날짜: 2026-05-23
- 유형: fix
- 변경 파일: scripts/rein-codex-review.sh (+plugin 사본), scripts/rein.sh, plugins/rein-core/hooks/lib/bootstrap-check.sh, tests/skills/test-codex-review-wrapper.sh, tests/scripts/test-job-stop-posix.sh, tests/hooks/test-bootstrap-check-helper.sh, 3 DoD
- 요약: v1.5 로드맵 보류 후 실제 버그 3건을 worktree 격리 병렬 agent(rein:feature-builder-fix ×3)로 처리. **G8-3**: fresh spec-review 의 무관 active-DoD Tier-2 fallback 차단(spec-review 분기 한정, diff_base=N/A). **job-stop**: `cmd_job_stop` 이 종료상태 미기록(state-machine 계약 위반) → `_rein_job_settle_terminal`(killed/128+sig) 추가, compare-and-set 가드로 자연 settle clobber 방지. **BC-INFO1**: bootstrap-check cold-path `git rev-parse` env sanitize. 통합 codex 리뷰 R1 NEEDS-FIX(job-stop double-settle race) → CAS 가드 추가 → R2 PASS. security 0 차단(INFO-2: sibling libs 동일 패턴 잔존 → need-to-confirm BC-INFO1-siblings 후속 등재). 전체 테스트: codex-review-wrapper 28/28, bootstrap-check 21/21, job 전체 OK, master 15/0. dev 3 commit(`b...`/`...`/`...`), origin/dev 미push. 커밋: G8-3 / job-stop / BC-INFO1 각 1.
