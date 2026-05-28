# DoD — 백로그 3 트랙 cherry-pick merge + 통합 review

- 날짜: 2026-05-28
- slug: backlog-3-track-cherry-merge
- 유형: feat + fix + perf 통합 통합 (cherry-pick reconciliation)

## 배경

2026-05-27 세션에서 worktree 격리 백그라운드 Agent 3개로 백로그 3 트랙을 dispatch 했고, 각 worktree branch 에 commit 까지 완료된 상태로 보류 중. trail/index.md 의 "B→A→C sequential merge" 계획은 다음 위험을 고려하지 않았음:

1. 각 worktree 의 merge-base 가 dev tip (`d9a6f8a`) 가 아니라 `aaa9e61b` (옛 base) — 옛 docs/ 부활 위험
2. `git diff d9a6f8a <worktree>` 가 -42k~-44k deletion 으로 표시되는 건 옛 base 잔재 (의도된 변경 아님)
3. 3 트랙 간 100+ 파일 overlap (특히 `.codex-reviewed` / `.security-reviewed` stamp 파일)
4. Track C 의 self-approved stamp 는 worktree 안에서 self-review 한 결과 (정식 검증 아님)

따라서 단순 `git merge` 대신 **각 worktree 의 top commit 만 cherry-pick** + **self-stamps 는 cherry-pick 에서 제외 후 통합 review 에서 재생성** 전략.

## 범위

### IN
- **Phase 0**: dev working tree 의 trail/ 변경분(15개 파일) 을 `chore(trail): session housekeeping` 으로 별도 commit
- **Phase 1**: Track B (`d3620e5`) top commit cherry-pick — SR-1.b orphan `.reviewed` backstop
- **Phase 2**: Track A (`b82ddbf`) top commit cherry-pick — PLN-1 plan exec-strategy schema + AG-2 worktree worker agent
- **Phase 3**: Track C (`e924078`) top commit cherry-pick — G3-perf-NFR shell rewrite of meta-check policy loader
- **Phase 4**: 통합 codex review (`/codex-review`) → stamp 재생성
- **Phase 5**: 통합 security review (`rein:security-reviewer`) → stamp 재생성
- **Phase 6**: review NEEDS-FIX 반영
- **Phase 7**: test suite 전체 실행 (tests/hooks/run-all.sh + tests/scripts/* + tests/agents/*)
- **Phase 8**: inbox + index.md 갱신 + 사용자 push 승인 받고 origin/dev push

### OUT
- main 머지 / tag / publish — 본 DoD 범위 아님. dev push 까지만
- worktree 11개의 정리 — 별도 DoD 로 분리
- Track A 의 PLN1-GATE-ENFORCEMENT 활성화 — commit 내 marker 그대로 두고 추후 별도 DoD
- 각 worktree branch 의 self-approved stamps (`.codex-reviewed` / `.security-reviewed` / `.spec-reviews/*`) — cherry-pick 에서 명시적 제외 (`--no-commit` + `git restore --staged`)

## 변경 파일

### Phase 0 (housekeeping commit)
- trail/daily/2026-05-17.md (deletion — rollup 완료)
- trail/daily/2026-05-18.md (deletion)
- trail/daily/2026-05-19.md (deletion)
- trail/daily/2026-05-24.md (신규)
- trail/dod/.active-dod (modified)
- trail/dod/.session-has-src-edit (deletion)
- trail/dod/dod-2026-05-24-v1-3-7-release.md (deletion — 완료)
- trail/inbox/2026-05-24-session-continuation.md (deletion)
- trail/inbox/2026-05-24-session.md (deletion)
- trail/inbox/2026-05-24-v1-3-7-release.md (deletion)
- trail/inbox/2026-05-27-backlog-3-track-parallel-dispatch.md (신규)
- trail/incidents/.last-aggregate-state.json (modified)
- trail/incidents/active-dod-cleanup.log (modified)
- trail/incidents/invalid-active-dod-marker.log (modified)
- trail/index.md (modified)
- trail/weekly/2026-W20.md (modified)
- trail/weekly/2026-W21.md (신규)

### Phase 1 (Track B top commit)
- plugins/rein-core/hooks/pre-edit-dod-gate.sh (modified — orphan .reviewed backstop 추가)
- tests/hooks/run-all.sh (modified)
- tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh (신규)
- trail/dod/dod-2026-05-27-sr-1-b-pre-edit-gate-stale-reviewed.md (신규)
- trail/inbox/2026-05-27-sr-1-b-pre-edit-gate.md (신규)

### Phase 2 (Track A top commit)
- plugins/rein-core/rules/design-plan-coverage.md (modified — section 2A schema)
- scripts/rein-validate-coverage-matrix.py (modified — parse_execution_strategy)
- plugins/rein-core/scripts/rein-validate-coverage-matrix.py (신규 — plugin mirror)
- plugins/rein-core/agents/plan-writer.md (modified — 3-axis judgment)
- plugins/rein-core/hooks/pre-edit-dod-gate.sh (modified — parallelizable advisory)
- plugins/rein-core/docs/worktree-cleanup.md (신규)
- plugins/rein-core/agents/feature-builder-worker.md (신규)
- tests/scripts/test-pln1-execution-strategy.sh (신규)
- tests/agents/test-ag2-worktree-frontmatter.sh (신규)
- docs/brainstorms/2026-05-27-pln1-ag2-parallel-execution.md (신규)
- docs/plans/2026-05-27-pln1-ag2-parallel-execution.md (신규)
- trail/dod/dod-2026-05-27-pln1-ag2-parallel-execution.md (신규)
- trail/inbox/2026-05-27-pln1-ag2-parallel-execution.md (신규)

### Phase 3 (Track C top commit)
- plugins/rein-core/hooks/lib/meta-check-policy.sh (신규 — shell port)
- plugins/rein-core/hooks/post-edit-meta-check.sh (modified — heredoc merge)
- plugins/rein-core/docs/policy-meta-check.md (modified)
- docs/specs/2026-05-27-g3-perf-nfr.md (신규)
- docs/specs/2026-05-27-g3-execution-mode-advisor.md (modified)
- docs/plans/2026-05-27-g3-perf-nfr.md (신규)
- docs/plans/2026-05-27-g3-execution-mode-advisor.md (modified)
- docs/brainstorms/2026-05-27-g3-perf-nfr-design.md (신규)
- tests/hooks/test-meta-check-policy-parity.sh (신규)
- tests/hooks/test-meta-check-policy-shell.sh (신규)
- tests/hooks/test-post-edit-meta-check-perf.sh (신규)
- tests/hooks/test-post-edit-meta-check.sh (modified)
- tests/hooks/test-post-edit-parallel-entries.sh (modified)
- trail/dod/dod-2026-05-27-g3-perf-nfr.md (신규)
- trail/inbox/2026-05-27-g3-perf-nfr.md (신규)

### Phase 4~5 (review stamps — Phase 1~3 cherry-pick 후 통합 review 가 재생성)
- trail/dod/.codex-reviewed (regenerated)
- trail/dod/.security-reviewed (regenerated)
- trail/dod/.spec-reviews/*.reviewed (cherry-pick 으로 들어온 신규 spec/plan 에 대한 stamp 추가)

### Phase 8 (inbox + index)
- trail/inbox/2026-05-28-backlog-3-track-merge.md (신규)
- trail/index.md (modified)

## 검증 기준

- [ ] Phase 0 housekeeping commit 의 git status 가 clean
- [ ] Phase 1 cherry-pick 후 `tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh` 5/5 PASS
- [ ] Phase 1 cherry-pick 후 `tests/hooks/test-spec-review-gate.sh` 27/27 PASS (SR-1 회귀 없음)
- [ ] Phase 2 cherry-pick 후 `tests/scripts/test-pln1-execution-strategy.sh` 10/10 PASS
- [ ] Phase 2 cherry-pick 후 `tests/agents/test-ag2-worktree-frontmatter.sh` 18/18 PASS
- [ ] Phase 3 cherry-pick 후 `tests/hooks/test-meta-check-policy-parity.sh` PASS + `test-meta-check-policy-shell.sh` PASS + `test-post-edit-meta-check-perf.sh` p95 ≤ 180ms
- [ ] Phase 4 `/codex-review` PASS verdict
- [ ] Phase 5 security review 0 high severity
- [ ] Phase 7 전체 test suite 회귀 0
- [ ] cherry-pick 충돌 발생 시 manual merge 결과가 두 트랙의 의도 모두 보존 (특히 pre-edit-dod-gate.sh 의 B SR-1.b orphan backstop + A parallelizable advisory 둘 다)
- [ ] dev branch 의 final tip 이 사용자 push 승인 후 origin/dev 로 푸시 완료
- [ ] worktree branch 3개는 작업 후 그대로 잔존 (별도 cleanup DoD 대상)

## 라우팅 추천

```yaml
agent: claude
skills:
  - rein:codex-review       # Phase 4 통합 review 의 핵심 gate (stamp 재생성)
  - superpowers:verification-before-completion  # PASS claim 전 명령 실행 강제 (self-stamp 재발 방지)
mcps: []
security_tier: standard
push_timing: phase-8-after-all-pass-with-explicit-approval
rationale: |
  본 작업은 git cherry-pick + manual merge + 통합 review 가 주 작업.
  현재 세션 (claude) 이 직접 수행 — subagent 위임 시 충돌 해소 결정이 외부
  로 빠져나가 의도 vs 다른 결과 위험. codex-review 는 통합 후 단일 review
  로 self-stamps 무효화 + 정식 stamp 재발급. verification-before-completion
  은 'test PASS' claim 전 실제 명령 실행을 강제해 self-stamp 패턴 재발 방지.
  security_tier=standard 사유: hook 2개 변경 (pre-edit-dod-gate.sh,
  post-edit-meta-check.sh) + 신규 scripts/validator 포함이라 light 부적합.
  push 는 Phase 8 의 모든 PASS 확인 후 사용자 명시 승인 받고 1회.
approved_by_user: true
approved_at: 2026-05-28
```

## 위험·완화

| 위험 | 영향 | 완화 |
|---|---|---|
| Phase 2 의 pre-edit-dod-gate.sh cherry-pick 가 Phase 1 의 같은 파일 변경과 충돌 | 두 변경 모두 적용 안 됨 | cherry-pick 충돌 시 manual edit — 두 영역(orphan backstop / parallelizable advisory) 모두 보존 |
| 옛 base 의 docs/ 부활 | 의도치 않은 옛 파일 복원 | top commit 만 cherry-pick (`git cherry-pick <sha>` 단일). 전체 branch 머지 금지 |
| self-stamps cherry-pick 으로 정식 검증 우회 | review gate bypass | cherry-pick 시 `.codex-reviewed` / `.security-reviewed` / `.spec-reviews/*` 명시적 `git restore --staged` 후 working tree 에서 제거 |
| Track C 의 perf 임계값 180ms 회귀 | gate 통과 못 함 | cherry-pick 후 `test-post-edit-meta-check-perf.sh` 즉시 실행 |
| dev push 가 다른 협업자 작업 덮어쓰기 | data loss | push 직전 `git fetch origin && git log origin/dev..dev` 확인 + 사용자 명시 승인 |

## 후속

- worktree 11개 cleanup (별도 DoD)
- Track A PLN1-GATE-ENFORCEMENT marker 활성화 — AG-2 stabilization 검증 후 별도 DoD
- main 머지 + tag — dev 안정화 후 별도 release DoD
