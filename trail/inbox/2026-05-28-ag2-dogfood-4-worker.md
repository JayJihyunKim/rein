# AG-2 dogfood (4-worker 병렬) + 5 pre-existing test fail 처리 (perf3 deferred)

- 날짜: 2026-05-28
- 유형: chore (operational dogfood) + fix
- DoD: trail/dod/dod-2026-05-28-ag2-dogfood-4-worker.md
- plan: docs/plans/2026-05-28-ag2-dogfood-4-worker.md
- 진행: 본 세션 (claude direct) + 4 worker subagent dispatch

## 결과 요약

5 commits 누적 (dev `2ae5b18` → `30290a2`):

| SHA | 분류 | 요약 |
|-----|------|-----|
| `462c094` | fix | worker_a: scripts/rein-policy-loader.py source ← plugin SSOT sync |
| `91d1217` | fix | worker_d: scripts/rein.sh English plugin-mode redirect msg |
| `825c746` | fix | worker_bc parent fallback: REIN_PUBLISH_SKIP_VALIDATE env + marketplace/ |
| `5f9da2c` | fix | dogfood-r1: plan matrix 정직화 + SKIP_VALIDATE 초기 가드 |
| `6b3d681` | fix | dogfood-r2: test fixture unset CI/GITHUB_ACTIONS for legitimate CI runs |
| `30290a2` | fix | security-r1: F1 — broaden CI marker allowlist (7 marker 합집합) |

(중간 r1/r2/security 정리 commit 들 = codex/security review cycle 의 반영)

## AG-2 dogfood 결론 (정직한 framing)

- **2 worker (worker_a, worker_d)**: 단순 1파일 fix 성공 + commit + test PASS. parent cherry-pick 으로 dev 머지.
- **1 parent fallback (worker_bc 영역)**: worker 가 multi-file dependency fix 에서 worktree 안 commit 도달 못 함 (env var + fixture 수정 + new file 등 3 영역 의존). parent (claude) 가 직접 진행해서 2 test PASS.
- **1 architectural stale-test (worker_e 영역)**: declared 1파일 scope 로는 처리 불가 — test-perf3 가 dispatcher 통합 이전 architecture 를 요구하는 stale 상태. dispatcher canonical vs if-field canonical 설계 결정 선행 후 별도 cycle 로 미룸.

> codex Mode B (second opinion) 의 framing 권고:
> "AG-2 worker 는 명확한 file ownership 과 독립 테스트가 있는 단순/중간 범위 수정에서 유효했다. declared scope 와 실제 fix scope 가 어긋나거나 architectural decision 이 필요한 경우 worker 는 parent fallback 또는 별도 cycle escalation 이 필요하다."

## Review cycle 결과

- **codex Round 1**: NEEDS-FIX (High×3 Medium×2) — plan matrix 의 perf3 가 `implemented` 인데 실제 deferred, "5 test fix" 과장 claim, SKIP_VALIDATE production guard 약함, worker_bc claim mechanism 차이.
- **Round 1 fix**: matrix perf3 → `deferred` + 사유, DoD framing "4/5 + 1 deferred", SKIP_VALIDATE 에 `$CI=true`/`$GITHUB_ACTIONS` 거부 가드.
- **codex Round 2**: NEEDS-FIX — Round 1 가드가 legitimate CI test fixture 까지 차단하는 regression.
- **Round 2 fix**: fixture 가 자기 subshell 안에서 `unset CI GITHUB_ACTIONS`.
- **codex Round 3**: PASS.
- **security review Round 1**: F1 Medium (CI marker allowlist 불완전 — Jenkins/GitLab 등 우회 가능) + F2 informational.
- **F1 fix**: 7 CI marker 합집합 (`$CI` / `$GITHUB_ACTIONS` / `$GITLAB_CI` / `$JENKINS_URL` / `$BUILDKITE` / `$CIRCLECI` / `$TF_BUILD`).
- **security review Round 2**: PASS + stamp 발급.

## Test 결과

- tests/scripts/test-plugin-scripts-bundle.sh: PASS
- tests/scripts/test-rein-update-claude-md-untouched.sh: PASS (3/3)
- tests/scripts/test-rein-publish-tarball.sh: PASS
- tests/scripts/test-rein-publish-dual-channel.sh: PASS
- tests/scripts/test-perf3-bash-rules-cold-path-skip.sh: **expected fail (deferred 별도 cycle)**
- tests/hooks/run-all.sh: ALL SUITES PASSED
- tests/agents/: 2개 PASS

## 라우팅 피드백

라우팅: agent=rein:feature-builder-worker × 4 (병렬), skills=rein:codex-review + superpowers:verification-before-completion + superpowers:dispatching-parallel-agents, security_tier=standard. **dogfood 결과는 mixed**:
- 4-worker 병렬 dispatch 자체는 동작 (Agent tool 의 한 메시지 다중 호출 + worktree 격리 frontmatter)
- 단순 1파일 작업은 worker 가 잘 처리 (worker_a/d)
- 복잡한 작업은 parent fallback 필요 (worker_bc/e)
- worker contract 에 "scope 밖 변경 필요 감지 시 명시적 non-completion artifact 남기고 종료" 추가가 다음 cycle 의 후보 (codex Mode B 권고: `.rein/worker-result.json` 같은 구조화 실패 보고)

## PLN1-GATE-ENFORCEMENT 활성화 의사결정

본 dogfood 결과는 PLN1-GATE-ENFORCEMENT (plan 의 `## 실행 전략` schema enforcement) 활성화의 **충분 근거 아님** — 4/5 worker 또는 task 성공이지만 1 architectural conflict 와 1 parent fallback 이 worker 자동 dispatch 신뢰성의 제한 조건을 노출. PLN-1 schema 자체 enforcement (plan 품질 게이트) 는 활성화 가능하지만, AG-2 worker dispatch 의 무조건 신뢰는 별도 cycle 의 worker contract 보강 후로.

## 후속 작업

- FIX-PERF3-HOOKS-JSON-HOT-PATH-ENTRIES — dispatcher canonical vs if-field canonical 설계 결정 + perf3 test 재정의 (별도 architectural cycle)
- AG-2 worker contract 보강 — `.rein/worker-result.json` 구조화 실패 보고 + 명시적 non-completion artifact (codex Mode B 권고)
- PLN1-GATE-ENFORCEMENT 활성화 — 위 worker contract 보강 후 별도 DoD
- main 머지 + release — 본 dogfood 결과 안정화 + 별도 release DoD
