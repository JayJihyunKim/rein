# DoD — Phase 3: plan-writer v2 + PLN-1 게이트 제거 + 워크트리 기계 폐기

- 날짜: 2026-06-01
- 유형: refactor (병렬 실행 재설계 Phase 3 — 구 워크트리/통짜-불리언 surface 정리 + plan-writer v2 전환)
- plan ref: docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md §Phase 3 (Task 3.1/3.2/3.3)

## 목표 (Why)

Phase 1(스키마/검증기 v2)·Phase 2(parallel-execute 스킬)가 새 모델을 확립했다. Phase 3 은 그 모델과 충돌하는 **구 surface 를 정리**한다: (1) plan-writer 가 v2 `## 실행 전략`(depends_on + edit_only/mutating)을 생성하도록 전환, (2) 더 이상 의미 없는 PLN-1 parallelizable 차단 블록을 게이트에서 제거, (3) 폐기된 워크트리 기계(cleanup doc + worker frontmatter + marker 계약) 제거. 세 작업은 서로 다른 파일을 만지므로 독립 — 병렬 실행 가능.

## 성공 기준 (Acceptance)

### Task 3.1 — plan-writer.md v2 (depends_on + edit_only/mutating 판단)
covers: PLANWRITER-V2-DEPENDS-ON-EDIT-ONLY-MUTATING-JUDGMENT

1. **실패 테스트 먼저 (RED)** — `tests/agents/test-plan-writer-exec-strategy-v2.sh` 신설: plan-writer.md 에 "depends_on"/"edit_only"/"mutating"/"동시 실행"/"disjoint" presence, **부재**: "parallelizable"/"3 axis"/"worktree-cleanup". RED 확인.
2. `plugins/rein-core/agents/plan-writer.md` `## 실행 전략 결정` 섹션 v2 재작성: v2 `## 실행 전략` 자동 첨부(tasks[]+depends_on+mode+scope) + 태스크별 edit_only/mutating 판단(mutating = 커밋/코드젠/전체포매터/패키지설치/스냅샷/변경성 테스트/scope 밖 쓰기 중 하나라도) + scope = 예상 실제 write set(mutating 은 부작용 경로 포함) + **동시 실행 가능한 edit_only 끼리만 pairwise disjoint**(depends_on 으로 순서 강제된 쌍은 겹쳐도 무방) + 불명확 시 순차 기본. 구 3-axis worker-split·workers[].scope·worktree-cleanup 참조·manual dispatch 제거. v2 예시(2 edit_only + 1 mutating) 추가, v1 예시 제거.
3. GREEN.

### Task 3.2 — pre-edit-dod-gate.sh PLN-1 블록 제거 (다른 분기 무영향)
covers: GATE-REMOVAL-PARALLELIZABLE-ENFORCEMENT-OTHERS-INTACT

4. **실패 테스트 먼저 (RED)** — `tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh` 재작성: (a) `grep 'PLN-1: parallelizable enforcement'` 매치 **없어야**, (b) `grep 'parallelizable plan without AG-2 worker'` 없어야, (c) `bash -n` 구문 OK, (d) 다른 분기 intact (DoD/라우팅/spec-review 분기 grep presence 유지). RED(아직 블록 존재).
5. `plugins/rein-core/hooks/pre-edit-dod-gate.sh` 에서 `# === PLN-1: parallelizable enforcement ...` 주석부터 그 `if [ -d "$DOD_DIR" ]; then ... done; fi` 블록까지 통째 삭제. 직후 `if [ "$DOD_FOUND" = true ]` 블록 보존.
6. `bash -n` 구문 검증 + 다른 게이트 회귀 확인(`bash tests/hooks/test-dod-gate.sh`). GREEN.

### Task 3.3 — 워크트리 기계 폐기
covers: WORKTREE-MACHINERY-DISCARD

7. **실패 테스트 먼저 (RED)** — `tests/agents/test-ag2-worktree-frontmatter.sh` 재작성: (a) feature-builder-worker.md frontmatter 에 `isolation: worktree` **없어야**, (b) 본문에 "worker-marker.json"/"worker-result.json"/"git worktree"/"cleanup" **없어야**, (c) "edit_only"/"선언 scope"/"커밋 금지"/"구조화 결과 반환" presence, (d) `worktree-cleanup.md` 파일 부재. RED.
8. `git rm plugins/rein-core/docs/worktree-cleanup.md`. `feature-builder-worker.md` 재작성: frontmatter `isolation: worktree` 제거 + description 을 "같은-트리 edit-only 병렬 워커 — parallel-execute 스킬이 선언 scope 로 dispatch" 로 교체. 본문 = 선언 scope 만 편집 / 금지목록(커밋·스테이징·stamp·trail·전체 포매터·변경성 명령) / 구조화 결과 반환(task_id/status/changed_files/blocked_reason/recommendation/summary — Phase 2 일치). 워크트리 생성·marker·result.json·cleanup·cherry-pick·stamp 소유권 섹션 전부 제거. 본문 ≤ 4 KB(NFR).
9. 잔존 참조 정리: `grep -rn "worktree-cleanup\|worker-marker.json\|worker-result.json\|isolation: worktree" plugins/rein-core/ scripts/` → dangling 참조 함께 정리. **확인된 dangling: `plugins/rein-core/rules/operating-sequence.md:26`** 의 `worker-result.json` blocked 신호 언급 → "worker 는 최종 메시지의 구조화 결과(status=blocked)로 보고" 로 교체. GREEN.

### 공통
10. scripts/ ↔ plugins/rein-core/scripts/ 미러 동기 필요 시 byte-identical 유지(해당 시).
11. codex 리뷰 PASS + 보안 리뷰 PASS (commit gate). 두 stamp 후 커밋.

## 변경 파일

- `plugins/rein-core/agents/plan-writer.md` (3.1)
- `tests/agents/test-plan-writer-exec-strategy-v2.sh` (3.1 신설)
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` (3.2)
- `tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh` (3.2 재작성)
- `plugins/rein-core/agents/feature-builder-worker.md` (3.3 재작성)
- `plugins/rein-core/docs/worktree-cleanup.md` (3.3 삭제)
- `plugins/rein-core/rules/operating-sequence.md` (3.3 dangling worker-result.json 참조 정리)
- `tests/agents/test-ag2-worktree-frontmatter.sh` (3.3 재작성)

## 제외 (Out of scope)

- Phase 4 회귀 스위트 통합 — 별 DoD.
- 검증기/스케줄러/스킬 자체 변경 — Phase 1/2 확정.
- pre-edit-dod-gate 의 DoD/라우팅/spec-review 분기 변경 — PLN-1 블록만 제거, 나머지 무영향.

## 리스크

- (R1) 3.2 가 라이브 게이트 파일 편집 — 그러나 실행 중 훅은 설치된 plugin 사본이라 저장소 편집이 현재 세션 게이트 동작에 영향 없음. 안전. 그래도 `bash -n` + test-dod-gate.sh 로 회귀 확인.
- (R2) feature-builder-worker 재작성 시 다른 agent/rule 의 dangling 참조 — `grep -rn` 으로 전수 확인 후 동시 정리.
- (R3) 병렬 3 subagent 가 같은 트리 공유 — 파일 disjoint(plan-writer / pre-edit-dod-gate / feature-builder-worker+worktree-cleanup)라 write-set 충돌 없음. 부모가 사후 통합 diff 검증.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor   # 구 surface 정리·구조 전환 (기능 변경 없이 모델 정합) — refactor 적합
skills:
  - rein:codex-review                  # commit gate 필수
mcps: []
rationale: >
  Phase 3 = 구 워크트리/통짜-불리언 surface 를 새 모델에 맞춰 정리하는 refactor.
  3.1 plan-writer 지시 전환, 3.2 게이트 블록 제거, 3.3 워크트리 기계 폐기 — 세 작업
  file-disjoint·무의존이라 병렬 dispatch. 각 TDD(부재 검증 포함). security_tier=normal
  — 3.2 가 게이트 코드를 만지나 라이브는 설치 사본이라 자기 영향 0, DoD/라우팅/spec
  분기 보존을 테스트로 강제.
security_tier: normal
approved_by_user: true                 # 사용자 "Phase 3,4 오토모드 자동 진행" 위임 (2026-06-01)
```

## Self-review 예정 항목 (AGENTS.md §6)

- plan-writer v2 가 구 3-axis/parallelizable/worktree 참조를 완전히 제거하고 v2 만 남기는가
- PLN-1 블록 제거 후 DoD/라우팅/spec-review 게이트 분기가 전부 intact 인가 (test-dod-gate.sh 무회귀)
- feature-builder-worker 재작성이 Phase 2 워커 결과 스키마 6키와 일치하는가
- worktree-cleanup.md 삭제 후 dangling 참조 0 (grep 전수)
- 병렬 3 subagent 사후 통합 diff 가 선언 파일 집합 내인가
