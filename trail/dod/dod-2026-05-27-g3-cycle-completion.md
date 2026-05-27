# G3 brainstorm/spec/plan cycle completion — docs-only commit

- 날짜: 2026-05-27
- 작업: G3 execution-mode-advisor 의 brainstorm + spec + plan + spec-review stamp 2개 사이클 완료 후 dev commit. **docs-only, 코드 변경 0**.

## 범위

본 DoD 는 G3 design phase 산출물 (brainstorm/spec/plan/stamps/inbox/index) 만 commit 한다. 실제 구현 (Phase 1~4 코드 변경) 은 본 DoD 범위 외 — 새 세션에서 별 DoD 로.

## 변경 파일

- `docs/brainstorms/2026-05-27-g3-execution-mode-advisor.md` (신규)
- `docs/specs/2026-05-27-g3-execution-mode-advisor.md` (신규)
- `docs/plans/2026-05-27-g3-execution-mode-advisor.md` (신규)
- `trail/inbox/2026-05-27-g3-brainstorm-spec-plan.md` (신규)
- `trail/index.md` (갱신 — 다음 세션 진입점 + 회고)
- `trail/dod/.spec-reviews/*.reviewed` (2 신규 — spec, plan)
- `trail/dod/dod-2026-05-27-g3-cycle-completion.md` (본 DoD)
- `need-to-confirm.md` (사용자가 IDE 에서 직접 TONE-1 항목 추가 — 본 turn 내 사용자 피드백의 직접 결실, 같은 commit 에 포함)
- `trail/dod/.active-dod` (session-active marker)
- `trail/dod/.session-has-src-edit` (deleted by session cleanup)
- `trail/incidents/active-dod-cleanup.log` (auto-append by session cleanup)
- `trail/incidents/invalid-active-dod-marker.log` (auto-append by session cleanup)

## 검증 기준

1. spec stamp 존재: `trail/dod/.spec-reviews/<spec hash>.reviewed` (reviewer=codex-gpt-5.5-medium-r4)
2. plan stamp 존재: `trail/dod/.spec-reviews/<plan hash>.reviewed` (reviewer=codex-gpt-5.5-medium)
3. pending 0건: `ls trail/dod/.spec-reviews/*.pending 2>/dev/null | wc -l` = 0 (확인 완료)
4. validator PASS: `python3 scripts/rein-validate-coverage-matrix.py plan docs/plans/2026-05-27-g3-execution-mode-advisor.md` exit 0
5. commit message: `<type>(<scope>): description` 형식 + scope 에 점/숫자 prefix 없음 (`feedback_commit_scope_format`)

## 라우팅 추천

agent: rein:feature-builder
skills: []
mcps: []
security_tier: light
approved_by_user: true
rationale: docs-only commit. 코드 변경 0 (markdown 만). security surface 없음 (path traversal / secrets / external input 모두 무관). codex-review 는 docs 차원에서 1회 (commit gate 통과용 `.codex-reviewed` stamp 생성).
