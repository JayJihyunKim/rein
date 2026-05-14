# DoD — 메인테이너 dev overlay hook 3건 sync (Option C prelude)

- 날짜: 2026-05-13
- 유형: refactor / internal sync (no user-facing change)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: 없음 (3 파일 단방향 sync — spec 필요 없음)
- plan ref: 없음 (단일 step refactor — design-plan-coverage Stage 1 advisory)

## 작업 기준

### 목표

메인테이너의 dev overlay (`.claude/hooks/*.sh`) 3건이 plugin SSOT (`plugins/rein-core/hooks/*.sh`) 보다 한 세대 stale 한 상태를 회복. plugin → overlay 단방향 sha256 동일성.

대상 파일:
- `.claude/hooks/pre-edit-dod-gate.sh` (overlay `ce31f82e` → plugin `a1762701`, v1.1.0 `e092c58`)
- `.claude/hooks/post-write-dod-routing-check.sh` (overlay `2b23e14e` → plugin `bd3e5920`, v1.1.0 `e092c58`)
- `.claude/hooks/session-start-bootstrap.sh` (overlay `0b7bf9f1` → plugin `f25f2d8e`, v1.1.1 hotfix `45c1399`)

### Scope (명시)

- 포함: 위 3 파일을 plugin SSOT 의 현재 content 로 덮어씀
- 제외:
  - release / version bump / tag / main 머지 (사용자 결정 Q-Scope (a): no bump — versioning Rule A 기준 internal change)
  - 다른 hooks (PLUGIN-ONLY 8건은 의도된 분리. drift checker false positive 카테고리)
  - rules / skills / agents (Option C 본격 단계에서 처리)
  - drift checker 동작 변경

### 사용자 영향

Zero. sync 대상 파일은 plugin tarball 에 이미 v1.1.0/v1.1.1 버전으로 포함되어 사용자는 영향 받지 않음. 본 작업은 메인테이너 작업 환경의 hook 메시지 일관성 회복 only.

### 성공 기준

- [ ] `python3 scripts/rein-check-plugin-drift.py` 의 HASH-MISMATCH 출력에서 3건 제거 (PLUGIN-ONLY 8건은 그대로 — 의도된 분리)
- [ ] 3 파일 모두 `bash -n` 구문 통과
- [ ] 관련 테스트 (`tests/hooks/test-pre-edit-dod-gate*.sh`, `tests/hooks/test-bootstrap-check-helper.sh`, `tests/scripts/test-rein-check-plugin-drift.sh`) 통과
- [ ] 커밋 메시지: `chore(overlay): dev hook 3종 plugin SSOT 와 sync (v1.1.0/v1.1.1 align)`

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review
mcps: []
rationale: |
  단순 단방향 sync 작업 — plugin SSOT 가 이미 review/release 된 hook 의 본문을 overlay 에 복사. logic 변경 없음.
  - feature-builder: 기존 hook 의 파일 sync 라 일반 implementation agent 가 적합. researcher / general-purpose 필요 없음.
  - codex-review: 정상 시퀀스의 review gate. 변경이 단순하지만 stamp 생성 필요 (pre-bash-guard 가 차단). 단순 copy 라 codex 가 low effort 로 통과 예상.
  - security-reviewer: 추가 호출 — codex-review 후 자동.
  - MCP 없음: 작업이 로컬 파일 cp 만.
approved_by_user: true
```

## 범위 연결

해당 없음 (brainstorm 산출물의 Open Questions 와 별개의 prerequisite work — Option C 본격 spec 작성 전 메인테이너 환경 안정화).
