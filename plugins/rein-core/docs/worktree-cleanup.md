# Worktree Cleanup — `feature-builder-worker` 의 manual cleanup 절차 (AG-2)

> 본 문서는 `plugins/rein-core/agents/feature-builder-worker.md` (AG-2) 가 만드는 worktree-격리 작업의 cleanup 절차다. Claude Code v2.1.144 의 `WorktreeCreate` / `WorktreeRemove` hook 이 matcher 미지원 (모든 worktree 에 발동) 이라 agent-specific 자동화가 불가능 — 따라서 본 문서가 유일한 cleanup 경로.

## 배경

Claude Code v2.1.144 의 agent frontmatter `isolation: worktree` 는 agent 호출 시 자동으로 `.claude/worktrees/agent-<hash>/` 워크트리를 생성한다. 본 메커니즘은 병렬 worker (`feature-builder-worker`) 의 file ownership 충돌 회피용.

**제약**:
- `WorktreeCreate` / `WorktreeRemove` hook 은 matcher 미지원 — 모든 worktree event 에 발동하므로 agent-specific 로직 부착 불가
- worker 종료 시 자동 cleanup (trail merge / stamp 합산 / worktree remove) 없음
- 결과: cleanup 은 메인 worktree 의 사용자가 manual 로 수행

본 문서가 5-step 절차 + Rein 판별 마커 + stamp 소유권 규칙을 정의.

## Rein worktree 판별 마커

worker worktree 가 Rein 운영 worktree 인지 식별하기 위해 worker 생성 시 다음 marker 파일을 만든다:

**경로**: `<worker-worktree-root>/.rein/worker-marker.json`

**Schema** (JSON):

```json
{
  "schema_version": "1.0.0",
  "marker_type": "rein-feature-builder-worker",
  "worktree_path": "<absolute path of worker worktree>",
  "agent_name": "feature-builder-worker",
  "parent_branch": "<branch name in main worktree>",
  "parent_worktree": "<absolute path of main worktree>",
  "created": "<ISO 8601 UTC, e.g. 2026-05-27T08:50:02>",
  "plan_ref": "<plan file path that dispatched this worker>",
  "worker_scope": ["<literal file path>", "<literal file path>"]
}
```

**필드 의미**:
- `marker_type` — 항상 `rein-feature-builder-worker` (다른 worker agent 추가 시 새 값)
- `worker_scope` — plan §실행 전략 의 `workers[].scope` 그대로 복사. cleanup 시 이 파일들만 머지 대상
- 다른 필드는 audit / 트러블슈팅용

**생성 시점**: worker agent 가 worktree 진입 후 첫 작업 (DoD 생성) 전에 직접 생성. 사용자가 manual dispatch 한 경우 worker agent 의 첫 명령으로 marker write.

## 수동 cleanup 절차 (5 step)

worker 작업 완료 후 메인 worktree 에서 다음 순서로 실행:

### Step 1: worker worktree 의 변경 commit 확인

```bash
cd <worker-worktree-root>
git status
git log --oneline <parent_branch>..HEAD
```

worker scope 외 파일이 dirty 면 사용자 확인 후 commit 또는 discard.

### Step 2: 메인 worktree 로 cherry-pick 또는 merge

worker 의 commits 를 메인으로 옮긴다:

```bash
# 메인 worktree 로 이동
cd <parent_worktree>

# (옵션 A) cherry-pick — 단일 / 소수 commit
git cherry-pick <worker-commit-sha>

# (옵션 B) merge — 다수 commit 또는 branch 통합
git merge --no-ff <worker-branch>
```

옵션 선택 기준:
- cherry-pick: worker 가 1-3 commit + 메인 분기 후 worker 만 변경 → linear history 유지
- merge: worker 가 다수 commit 또는 메인이 worker 작업 중 갱신됨 → merge commit 보존

### Step 3: worker worktree 의 stamps 를 메인으로 이관

worker worktree 의 stamps 는 worker 자체 검증 결과 — 머지 후 메인 합산:

```bash
# Worker worktree 의 stamps 확인
ls <worker-worktree-root>/trail/dod/.codex-reviewed
ls <worker-worktree-root>/trail/dod/.security-reviewed

# 메인 trail/dod/ 로 복사
cp <worker-worktree-root>/trail/dod/.codex-reviewed <parent_worktree>/trail/dod/
cp <worker-worktree-root>/trail/dod/.security-reviewed <parent_worktree>/trail/dod/
```

**주의**: 메인에 이미 다른 작업의 stamps 가 있으면 worker stamps 가 덮어쓴다. 정책:
- 같은 cycle (동일 cycle ID 또는 PR) 의 worker stamps 만 합산
- 다른 cycle 이 진행 중이면 worker 머지 전에 메인 cycle 먼저 정리

대안: 메인에서 머지 후 다시 `/rein:codex-review` + `rein:security-reviewer` 호출하여 stamps 재생성 (가장 안전 — 자동 hook chain 활용).

### Step 4: worker worktree 정리

```bash
# 메인에서 worker worktree 제거
git worktree remove <worker-worktree-root>

# 또는 force (worker 가 dirty 면)
git worktree remove --force <worker-worktree-root>

# worker branch 도 정리 (선택)
git branch -D <worker-branch>
```

### Step 5: 메인 worktree 에 worker 결과 기록

`trail/inbox/YYYY-MM-DD-<slug>-worker-<n>.md` 작성:

```markdown
# Worker N: <slug>
- 날짜: YYYY-MM-DD
- 유형: feat (worker)
- 부모 plan: <plan path>
- worker_scope: [<paths>]
- merge 방식: cherry-pick / merge
- merged commits: <sha list>
- stamps 합산: codex-review PASS / security-review PASS
- 요약: <1-3줄>
```

이후 일반 cycle 처럼 `trail/index.md` 갱신.

## stamp 소유권 규칙

| Stamp | 생성 주체 | 소유 worktree | 머지 후 |
|-------|----------|--------------|--------|
| `trail/dod/.codex-reviewed` | worker 의 `/rein:codex-review` | worker worktree | 메인으로 복사 (Step 3) 또는 메인에서 재생성 |
| `trail/dod/.security-reviewed` | worker 의 `rein:security-reviewer` | worker worktree | 메인으로 복사 (Step 3) 또는 메인에서 재생성 |
| `trail/dod/.spec-reviews/*.reviewed` | worker 의 plan-writer 또는 manual | worker worktree | 메인으로 복사 (hash 충돌 없음 — 파일별 hash) |
| `trail/dod/.review-pending` | worker 의 hook | worker worktree | 머지 전에 worker 에서 처리 |

**원칙**: worker stamps 는 worker 의 작업 단위에 대한 증거. 메인 stamps 는 메인 trail/dod 에 active DoD 가 있을 때만 의미. 따라서:

- worker scope 만 변경 + 메인 inactive → Step 3 의 직접 복사로 충분
- 메인이 active cycle 중 + worker 머지 → 머지 후 메인에서 다시 `/rein:codex-review` 호출 (재생성)

## Troubleshooting

### Q: worker marker 파일이 부재인데 cleanup 어떻게?

가능성:
- worker agent 가 marker 생성 전에 죽음
- 사용자가 수동으로 worktree 생성

대응:
1. `cd <worktree-root> && git log --oneline -5` 로 commit 내용 확인 — Rein worker 의 commit message pattern (`feat(...)`, `feat(agent):`) 식별
2. plan ref 추적 — 메인 worktree 의 `trail/dod/` 에서 본 worktree path 를 plan ref 로 가리키는 DoD 찾기
3. 식별 후 Step 1~5 절차 진행. marker 생성은 skip.

### Q: stamps 충돌 — 메인과 worker 가 동시에 다른 cycle 진행

대응:
- 메인 cycle 먼저 commit + stamps 정리
- worker 머지 전에 메인 stamps 백업 (`trail/dod/.codex-reviewed.backup`)
- worker 머지 후 stamps 비교, 의도된 것만 보존

이상적으로는 worker dispatch 전에 메인 cycle 완료 — worker 는 메인이 clean 상태에서만 dispatch.

## 관련 파일

- `plugins/rein-core/agents/feature-builder-worker.md` — worker agent 본체
- `plugins/rein-core/rules/design-plan-coverage.md` §2A — plan `## 실행 전략` 섹션 schema (PLN-1)
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` — `parallelizable: true` 감지 advisory

## 변경 이력

- 2026-05-27: 초안 작성 (PLN-1 + AG-2 cycle, spec docs/specs/2026-05-27-pln1-ag2-parallel-execution.md)
