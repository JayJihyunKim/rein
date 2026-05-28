# DoD — AG-2 dogfood (4-worker 병렬) + 4/5 pre-existing test fail 처리 (perf3 deferred)

- 날짜: 2026-05-28
- slug: ag2-dogfood-4-worker
- 유형: chore (operational dogfood) + fix (5 pre-existing test fail)
- plan ref: docs/plans/2026-05-28-ag2-dogfood-4-worker.md

## 배경

PLN-1 (plan 의 `## 실행 전략` schema) + AG-2 (`feature-builder-worker` agent — `isolation: worktree` frontmatter) cycle 의 enforcement 활성화 (`PLN1-GATE-ENFORCEMENT-DISABLED-PENDING-AG2-STABILIZATION` 마커 제거) 의 사전 조건이 "AG-2 dogfood 검증". 본 cycle 이 그 dogfood — 5 pre-existing test fail (2026-05-28 backlog-3-track-merge cycle 에서 본 cycle 무관으로 분류된 pre-existing 5건) 을 4 disjoint worker 로 병렬 dispatch 해서 worktree 자동 생성·격리·완주·cleanup 사이클을 실측 검증.

## Scope Items

| Scope ID | 의미 |
|----------|------|
| AG2-DOGFOOD-MULTI-WORKER-DISPATCH | Agent tool 의 multiple call 한 메시지 병렬 dispatch 동작 검증 |
| AG2-DOGFOOD-WORKTREE-ISOLATION | isolation:worktree frontmatter 가 worker 별 worktree 자동 생성 |
| AG2-DOGFOOD-WORKER-SCOPE-DISJOINT | 4 worker 의 file ownership 충돌 0 (각 자기 scope 안에서만 편집) |
| AG2-DOGFOOD-MARKER-PRESENCE | 각 worker 의 .rein/worker-marker.json 생성 |
| AG2-DOGFOOD-MANUAL-CLEANUP | parent session 의 manual cleanup (worktree-cleanup.md 5-step procedure) |
| FIX-PLUGIN-SCRIPTS-BUNDLE-SHA256 | rein-policy-loader.py source ↔ plugin mirror sha256 sync |
| FIX-PUBLISH-DUAL-CHANNEL | rein-publish.sh fail-fast for ANTHROPIC_MARKETPLACE_API + validator path resolution |
| FIX-PUBLISH-TARBALL-MARKETPLACE-JSON | .claude-plugin/marketplace.json fixture path 충족 |
| FIX-REIN-UPDATE-CLAUDE-MD-REDIRECT | scripts/rein.sh update path 의 plugin install 안내 message |
| FIX-PERF3-HOOKS-JSON-HOT-PATH-ENTRIES | plugins/rein-core/hooks/hooks.json 의 13 hot-path × bare+args = 26 entries 등록 |
| FIX-SECURITY-R1-CI-MARKER-ALLOWLIST | scripts/rein-publish.sh 의 REIN_PUBLISH_SKIP_VALIDATE production guard 가 7 CI marker 합집합 ($CI / $GITHUB_ACTIONS / $GITLAB_CI / $JENKINS_URL / $BUILDKITE / $CIRCLECI / $TF_BUILD) 로 우회 차단 |

## 범위

### IN
- **Phase 0**: plan 작성 + PLN-1 validator PASS 확인
- **Phase 1**: 4 worker 병렬 dispatch via Agent tool (`rein:feature-builder-worker` × 4, 한 메시지 안 multiple Agent calls)
- **Phase 2**: 각 worker 의 fix 산출물 (worker worktree 안 commit) 회수 → dev 머지 (cherry-pick 또는 worktree merge)
- **Phase 3**: 통합 codex review + security review → stamp 재발급
- **Phase 4**: 5 fail test 중 4건 PASS (perf3 는 stale-test 로 deferred) + 전체 test suite 회귀 0
- **Phase 5**: worktree cleanup (4개 manual procedure per worktree-cleanup.md)
- **Phase 6**: inbox + index + dev push

### OUT
- `PLN1-GATE-ENFORCEMENT` 마커 제거 본체 (본 dogfood 의 PASS 결과로 별도 cycle 에서 진행)
- main 머지 / release tag (별도 release DoD)
- 5 test fail 외의 다른 bug 처리

## 변경 파일

### Phase 0
- docs/plans/2026-05-28-ag2-dogfood-4-worker.md (신규)

### Phase 1~2 (worker 별 disjoint scope)

**worker_A (scripts-bundle sync)**:
- scripts/rein-policy-loader.py
- plugins/rein-core/scripts/rein-policy-loader.py

**worker_BC (publish 통합 — B+C 같은 파일 묶음)**:
- scripts/rein-publish.sh
- scripts/rein-validate-plugin-rules.py
- .claude-plugin/marketplace.json

**worker_D (claude-md untouched)**:
- scripts/rein.sh

**worker_E (perf3 hooks.json entries)**:
- plugins/rein-core/hooks/hooks.json

### Phase 3~6
- trail/dod/.codex-reviewed (regenerated)
- trail/dod/.security-reviewed (regenerated)
- trail/inbox/2026-05-28-ag2-dogfood-4-worker.md (신규)
- trail/index.md (modified)

## 검증 기준

- [ ] PLN-1 validator (`python3 scripts/rein-validate-coverage-matrix.py plan docs/plans/2026-05-28-ag2-dogfood-4-worker.md`) PASS
- [ ] `parallelizable: true` 인 plan 에 대해 pre-edit-dod-gate.sh 의 PLN-1 NOTICE 가 stderr 에 출력 (enforcement OFF 상태 정상 advisory)
- [ ] 4 worker 모두 worktree create + commit + `.rein/worker-marker.json` 생성 완료
- [ ] 4 worker scope 가 disjoint (PLN-1 fail-closed b/c/d/e 위반 없음)
- [ ] 5 fail test 중 4건 PASS: test-plugin-scripts-bundle / test-rein-publish-dual-channel / test-rein-publish-tarball / test-rein-update-claude-md-untouched. test-perf3-bash-rules-cold-path-skip 은 stale-test 로 deferred (별도 cycle 에서 dispatcher canonical 결정 후 test 재정의 + hook entries)
- [ ] 전체 test suite (tests/hooks + tests/scripts + tests/agents) 회귀 0
- [ ] codex review PASS
- [ ] security review 0 High/Medium
- [ ] 4 worker worktree cleanup 후 `git worktree list` = main dev only

## 라우팅 추천

```yaml
agent: rein:feature-builder-worker
agent_count: 4
worker_assignment:
  worker_A: scripts-bundle sync (rein-policy-loader.py mirror)
  worker_BC: publish 통합 (rein-publish.sh + validate-plugin-rules.py + marketplace.json)
  worker_D: rein.sh redirect message
  worker_E: hooks.json hot-path entries 등록
skills:
  - rein:codex-review                          # Phase 3 통합 review
  - superpowers:verification-before-completion # PASS claim 전 실행 강제
  - superpowers:dispatching-parallel-agents    # 4 worker 병렬 dispatch 절차
mcps: []
security_tier: standard
rationale: |
  AG-2 의 feature-builder-worker agent 를 4 인스턴스 병렬 dispatch — 본 cycle
  의 핵심 dogfood. 각 worker 는 disjoint scope 안에서만 편집. parent
  session (현재 claude) 이 worker 결과 회수 + cherry-pick + 통합 review 담당.
  dispatching-parallel-agents skill 이 다중 Agent tool call 의 single-message
  병렬 dispatch 절차 제공.
approved_by_user: true
approved_at: 2026-05-28
```

## 위험·완화

| 위험 | 영향 | 완화 |
|---|---|---|
| worker 가 자기 scope 밖 편집 (file ownership 위반) | 머지 시 충돌 | PLN-1 validator + plan §실행 전략 의 literal path 명시. worker prompt 에서 명시적 제약 |
| worker worktree merge-base 가 dev tip 와 다르면 옛 파일 부활 위험 | -10k~-40k deletion noise | 본 cycle 시작 시 dev tip (`2ae5b18`) 확인. worktree 생성 시점 ancestor 검증 |
| worker dispatch 가 실패 (Claude Code worktree create 오류) | dogfood 불가 | 1 worker 부분 실패 시 해당 worker 만 manual fix 으로 폴백. 다른 worker 결과는 유지 |
| 4 worker 동시 NEEDS-FIX | review 복잡도 폭증 | sanity test 를 worker 단계에서 강제 (worker 자체가 자기 fix 의 test 통과 보장) |
| worker self-stamps 가 통합 review 에서 무효화 시 missing stamp | commit gate 차단 | parent session 이 worker stamps cherry-pick 제외 + 통합 stamp 재발급 (2026-05-28 backlog-3-track-merge cycle 의 검증된 패턴) |
| 5 test fix 가 다른 영역 regression 유발 | 전체 test suite 회귀 | Phase 4 에서 전체 suite 강제 실행 |

## 후속

- PLN1-GATE-ENFORCEMENT 활성화 (본 dogfood PASS 시 별도 DoD)
- main 머지 + release (별도 release DoD)
- worktree-cleanup.md 의 5-step manual 절차에 본 cycle 의 실측 교훈 추가 검토
