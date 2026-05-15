# Bootstrap gate deadlock fix + auto-bootstrap + degraded mode (v1.3.0)

- 날짜: 2026-05-15
- 유형: feat
- 변경 파일:
  - **신규**: `plugins/rein-core/hooks/lib/degraded-check.sh` (BG-J), `trail/dod/dod-2026-05-15-bootstrap-gate-deadlock-fix.md`, `bootstrap-gate-deadlock.md` (incident 분석)
  - **편집 (plugin source)**: `plugins/rein-core/hooks/lib/bootstrap-check.sh` (BG-E), `pre-tool-use-bash-bootstrap-gate.sh` (BG-B), `pre-edit-trail-bootstrap-gate.sh` (BG-C), `stop-session-gate.sh` (BG-D), `session-start-bootstrap.sh` (BG-A), `scripts/rein-bootstrap-project.py` (BG-F), `skills/incidents-to-rule/SKILL.md` (BG-G), `skills/incidents-to-agent/SKILL.md` (BG-G), `.claude-plugin/plugin.json` (version bump)
  - **편집 (tests)**: `lib/test-harness.sh`, `test-pre-tool-use-bash-bootstrap-gate.sh` (Fixture B fix + BG-I), `test-pre-edit-trail-bootstrap-gate.sh` (Fixture A/I/M/N + BG-I), `test-session-start-bootstrap.sh` (BG-H + Fixture J 추가), `test-stop-gate-deadlock.sh` (BG-I)
  - **편집 (메타)**: `scripts/rein.sh` (VERSION), `CHANGELOG.md` (entry)

## 요약

2026-05-14 v1.2.0 release 후 다른 프로젝트 fresh install 환경에서 SessionStart 의 "bootstrap 미완료" 안내 명령이 Bash gate 에 self-block 되어 회복 불가능한 deadlock 발생 (`bootstrap-gate-deadlock.md` incident). v1.3.0 으로 fix.

옵션 B 채택 — git repo + safe path 에서 자동 bootstrap, non-git/git-missing 은 degraded mode + 1줄 안내. 옵션 결정 과정: codex-ask 2회 (1차 deadlock 분석 + 2차 git init flow 검증) → plan b-prancy-valiant.md → 사용자 결정 4건 확정 (REIN_NO_AUTO_BOOTSTRAP opt-out 추가 / informed 1줄 알림 / 해석 B degraded mode / BG-G 본 cycle 포함).

## 진행 흐름

- **Wave 1 (병렬 6 agent)**: BG-J helper + BG-B/C/D/E/F+A/G 일괄 file 편집. 모든 agent 자체 syntax check 통과
- **Wave 2 (병렬 2 agent)**: BG-H test fixture rewrite + BG-I 신규 gate tests
- **Fix round (test alignment)**: 11 fixture fail → 단일 agent 가 fixture/harness update (hook source 미변경). 36/36 PASS
- **통합 codex-review round 1**: NEEDS-FIX (HIGH-1 rc 0 stale marker / HIGH-2 monorepo subdir / MEDIUM-1 helper chatter / MEDIUM-2 SKILL.md prose)
- **Fix round 2 (codex findings)**: 4 findings + 3 신규 fixture (J/M/N). 48/48 PASS
- **통합 codex-review round 2**: PASS (BG-A~J all MATCH)
- **Security review**: PASS (LOW-1 권고 외 모두 PASS — bash allow-list 에 `python3*` prefix anchor 권고)
- 통합 stamp 갱신: `.codex-reviewed` 본 cycle reflect, `.security-reviewed` 본 cycle reflect, `.review-pending` 제거

## 후속 후보 (다음 cycle)

- BG-B allow-list 에 `python3*` prefix anchor 추가 (security review LOW-1)
- BG-C 의 invalid stdin.cwd branch 가 bootstrap-check.sh 와 mirror 안 됨 (non-blocking note, codex round 2)
- BG-A bootstrap helper output 의 stderr silence trade-off — 실패 진단 정보 손실 가능 (degraded fallback marker reason 으로 mitigate)
- partial-bootstrap stale `.session-has-src-edit` 정리 (codex round 1 missed defect #3, 본 cycle 미포함)
- mirror-to-public.yml Q9 force re-tag GHA 실패 root cause + release postcondition verifier (별도 cycle)

## 참고

- DoD: `trail/dod/dod-2026-05-15-bootstrap-gate-deadlock-fix.md`
- Plan: `~/.claude/plans/b-prancy-valiant.md`
- Codex output 1차: `/tmp/codex-ask-bootstrap-gate.out` (gate 결함 분석)
- Codex output 2차: `/tmp/codex-ask-git-init-flow.out` (git init flow + auto-install 판정)
- Codex review round 1: `/tmp/codex-review-v130.out` (NEEDS-FIX)
- Codex review round 2: `/tmp/codex-review-v130-round2.out` (PASS)
