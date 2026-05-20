# DoD — hook test 5 fail stale reference 갱신

- 날짜: 2026-05-20
- 유형: refactor (test 갱신 — source-side 의도된 변화 반영)
- slug: hook-test-stale-references
- plan ref: (none — 단발성 test 갱신, plan 불요)

## 배경

UPS-1 회귀 fix (commit `6504dd6`) 직후 전체 81 hook 테스트 중 5 fail 잔존 — UPS-1 무관 pre-existing 회귀. `git stash plugins/rein-core/rules/short/` 로 변경 반전한 상태에서도 동일 5 fail 확인 (정직성 검증 완료).

## Root cause 분류

### 그룹 A — Phase 2b HK-4 dispatcher deprecation 미반영 (2건)

Phase 2b HK-4 에서 `post-edit-dispatcher.sh` 가 hooks.json 에서 등록 해제됨 (8 sub-hook 직접 등록으로 분할). dispatcher 본문은 deprecation 메시지만 emit. test 가 dispatcher 등록/호출을 가정해 stale.

| Test | 변경 |
|---|---|
| `test-design-plan-coverage-registered` | `EXPECTED_BASENAME="post-edit-dispatcher.sh"` → `"post-edit-design-plan-coverage-rule.sh"` (Phase 2b 분할 후 design-plan-coverage rule 을 직접 등록하는 sub-hook 의 basename) |
| `test-hk1-post-write-rename` | Section (4) "End-to-end: dispatcher invokes the 4 renamed hooks" 를 "hooks.json registers 4 renamed sub-hooks directly" 검증으로 교체 — dispatcher 호출 검증은 더 이상 의미 없음. 의도 (post-write → post-edit rename 완료 검증) 보존. |

### 그룹 B — Option C Phase 3 `.claude/hooks/` overlay 폐기 미반영 (3건)

Option C Phase 3 (2026-05-13) 에서 `.claude/hooks/` overlay 가 폐기되고 `plugins/rein-core/hooks/` 가 단독 SSOT 가 됨. test 가 `.claude/hooks/` 경로를 hardcode → 부재 fail.

| Test | 변경 |
|---|---|
| `test-post-edit-review-gate-external-paths` | `HOOK="$PROJECT_DIR/.claude/hooks/post-edit-review-gate.sh"` → `"$PROJECT_DIR/plugins/rein-core/hooks/post-edit-review-gate.sh"` (1줄) |
| `test-session-end-stamp` | `copy_hooks_into_sandbox()` 내부 `.claude/hooks/` source path 3개를 `plugins/rein-core/hooks/` 로 교체 (sandbox 내부 layout 유지) |
| `test-session-start-marker-cleanup` | `HOOK` + `lib/portable.sh` source path 2줄 |

## 변경 범위

5 test 파일만 편집:
- `tests/hooks/test-design-plan-coverage-registered.sh` (1줄)
- `tests/hooks/test-hk1-post-write-rename.sh` (section 4 교체, ~20줄)
- `tests/hooks/test-post-edit-review-gate-external-paths.sh` (1줄)
- `tests/hooks/test-session-end-stamp.sh` (3줄)
- `tests/hooks/test-session-start-marker-cleanup.sh` (2줄)

## 비범위

- hook 본체 (`plugins/rein-core/hooks/`) 편집 없음 — source 측은 의도된 상태 (deprecation + SSOT 이전 완료)
- 다른 76 PASS test 편집 없음 — 회귀 없음 보장
- dispatcher 본체 (`post-edit-dispatcher.sh`) 추가 정리는 별 cycle (trail/index.md "별 cycle 후보 (f)" 잔존)

## 검증 기준 (Definition of Done)

- [ ] 5 fail test 모두 PASS
  - `test-design-plan-coverage-registered.sh`
  - `test-hk1-post-write-rename.sh`
  - `test-post-edit-review-gate-external-paths.sh`
  - `test-session-end-stamp.sh` (18 assertion 전부)
  - `test-session-start-marker-cleanup.sh` (모든 sub-test 전부)
- [ ] 전체 81 hook test 모두 PASS (회귀 0)

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - rein:codex-review
mcps: []
security_tier: light
rationale: |
  - agent: test 갱신 = researcher-first refactor 성격 (기존 코드 구조 파악 후 의도 보존하며 path/section 갱신, 기능 변경 없음). DoD 키워드 "갱신" 부합.
  - skills/codex-review: test 본체는 plugin SSOT 가 아니라 tests/ 하위지만 회귀 검증 중요성을 감안해 외부 second opinion 유지.
  - mcps: 없음 — 외부 시스템 조회 / 라이브러리 조사 불필요.
  - security_tier: light — bash test 스크립트 path 갱신만, secret/외부 input boundary/command exec 신규 도입 없음. 기존 sandbox/mktemp 패턴 유지.
approved_by_user: true
```

## 라우팅 승인 사유

Auto Mode 활성 + 사용자 직접 명령 "다음 사이클 후보 진행하자" + AskUserQuestion 응답 "(b) hook test 5 fail 진단 (Recommended)" 로 reasonable call 진행. 5 fail 모두 2 root cause 로 분류 완료, fix 방향이 명확 (단순 path/basename/section 갱신) → 별 cycle 분리 불필요.
