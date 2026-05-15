# DoD — Bootstrap Gate Deadlock 해소 + Auto-bootstrap + Degraded Mode (v1.3.0)

## 배경

2026-05-14 v1.2.0 release 후 다른 프로젝트 (`/home/wave/Workspace/contextOS`) 에서 fresh install 시 deadlock 발생. SessionStart hook 의 "bootstrap 미완료" 안내 명령이 Bash gate 자체에 차단되어 회복 불가능. 동시에 `${CLAUDE_PLUGIN_ROOT}` 가 사용자 shell 에서 expand 안 되어 안내 명령도 실패. Stop hook 무한 반복으로 세션 진행 불가. incident 본문: `bootstrap-gate-deadlock.md`.

codex second opinion 2회 분석으로 gate 결함이 dominant root cause 확인. 사용자가 옵션 B (auto-bootstrap on session-start) + git missing/non-git 에서 degraded mode 채택.

참고 plan 문서: `~/.claude/plans/b-prancy-valiant.md` (plan mode 산출물, repo 외부)

## Scope Items (이번 cycle 변경 범위)

| Scope ID | 변경 | 검증 |
|---|---|---|
| BG-A | session-start-bootstrap.sh rc 10 분기 — opt-out / git missing / non-git / auto-bootstrap / bootstrap-refused 6단계 | test-session-start-bootstrap.sh 신규 fixture (BG-H) |
| BG-B | pre-tool-use-bash-bootstrap-gate.sh allow-list (`*rein-bootstrap-project.py*--project-dir*`) + degraded pass-through | test-pre-tool-use-bash-bootstrap-gate.sh (BG-I) |
| BG-C | pre-edit-trail-bootstrap-gate.sh path-scoped (trail/ 외 통과) + degraded pass-through | test-pre-edit-trail-bootstrap-gate.sh append (BG-I) |
| BG-D | stop-session-gate.sh 라인 123 직후 degraded pass + bootstrap-incomplete escape | test-stop-gate-deadlock.sh append (BG-I) |
| BG-E | bootstrap-check.sh:300-312 guidance heredoc 의 `${CLAUDE_PLUGIN_ROOT}` literal 제거 → expanded plugin_root | test-bootstrap-check-helper.sh Fixture B |
| BG-F | rein-bootstrap-project.py:205 argparse default — plugin.json version 동적 read | test-session-start-bootstrap.sh Fixture C version assertion |
| BG-G | incidents-to-rule/agent SKILL.md 의 `${CLAUDE_PLUGIN_ROOT}` 사용자 노출 5곳 → portable resolver | (manual visual check + grep `${CLAUDE_PLUGIN_ROOT}` user-facing) |
| BG-H | test-session-start-bootstrap.sh Fixture A/B/G invert (auto-mutation 또는 degraded marker assertion) | test 자체가 검증 |
| BG-I | 신규 gate fixture (allow-list + path-scoped + degraded pass-through + bootstrap-incomplete escape) | test 자체가 검증 |
| BG-J | lib/degraded-check.sh 헬퍼 (rein_is_degraded/write_degraded/clear_degraded) + .claude/cache/.rein-session-degraded marker | BG-B/C/D fixture 가 marker 작성 후 통과 확인 |

변경 Scope ID 목록: BG-A · BG-B · BG-C · BG-D · BG-E · BG-F · BG-G · BG-H · BG-I · BG-J

## DoD 항목

- [ ] BG-J `lib/degraded-check.sh` 헬퍼 작성 + bash -n 통과
- [ ] BG-B/C/D 각 hook 이 degraded marker 시 즉시 exit 0
- [ ] BG-B bash gate 가 `*rein-bootstrap-project.py*--project-dir*` 패턴 통과
- [ ] BG-C trail edit gate 가 `trail/` 외 path 통과
- [ ] BG-D stop hook 이 marker/trail 부재 시 incident gate skip
- [ ] BG-E guidance 출력에 `${CLAUDE_PLUGIN_ROOT}` literal 부재, 절대경로 포함
- [ ] BG-F bootstrap helper 가 plugin.json version (1.2.0 → 1.3.0 bump 후 1.3.0) 자동 read
- [ ] BG-A 6단계 분기 모두 동작 (opt-out / git missing / non-git / auto-bootstrap / refused / clear)
- [ ] BG-G SKILL.md 5곳 `${CLAUDE_PLUGIN_ROOT}` 사용자 노출 제거
- [ ] BG-H test fixture A/B/G assertion 갱신, all green
- [ ] BG-I 신규 fixture all green
- [ ] 통합 `/codex-review` PASS + `.codex-reviewed` stamp
- [ ] `security-reviewer` PASS + `.security-reviewed` stamp
- [ ] v1.3.0 bump (plugin.json + scripts/rein.sh) + CHANGELOG entry
- [ ] dev commit + main 선별 체크아웃 (branch-strategy.md 절차)
- [ ] main push → mirror-to-public.yml 동작 확인 (v1.2.0 Q9 force re-tag 이슈 재발 모니터)
- [ ] trail/inbox + index.md 갱신

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:codex-review
  - (security-reviewer agent 자동 호출)
mcps: []
rationale: |
  hook script 4개 편집 + helper 1개 신규 + test fixture rewrite + python script 1개 수정.
  feature-builder 가 BG-A~J 일괄 구현 후 통합 codex-review (Mode A) + security-reviewer 2단 검토.
  병렬 dispatch 가능 — Phase 1 Task 1-5 (BG-J/B/C/D/E) 모두 disjoint file. Phase 2 (BG-F/A) 는 Phase 1 의존.
  외부 MCP 불필요 (모두 in-repo 작업).
approved_by_user: true
```

## 참고

- incident: `/Users/jihyunkim/dreamline/rein-dev/bootstrap-gate-deadlock.md`
- codex output 1차 (gate 결함 분석): `/tmp/codex-ask-bootstrap-gate.out`
- codex output 2차 (git-init flow + auto-install 판정): `/tmp/codex-ask-git-init-flow.out`
- plan 본체: `/Users/jihyunkim/.claude/plans/b-prancy-valiant.md`
