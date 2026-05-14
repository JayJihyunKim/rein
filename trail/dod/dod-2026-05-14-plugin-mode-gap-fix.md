# DoD — scaffold→plugin migration gap fix (v1.2.0)

- 날짜: 2026-05-14
- 유형: feat (cycle)
- 슬러그: plugin-mode-gap-fix
- 대상 버전: v1.2.0 (versioning Rule A — minor bump)
- 브랜치: dev (단방향 원칙 준수, 완료 시 main 선별 체크아웃)

## 범위 연결

plan ref: docs/plans/2026-05-14-plugin-mode-gap-fix.md
work unit: 전체 cycle (Phase 1~3, 14 work units)
covers: [BS-1-security-overlay-exclusion-reason-rewritten-to-state-plugin-source-has-no-security-and-bootstrap-creates-defaults-on-fresh-install, BS-2-scripts-rein-helper-include-reason-clarified-as-plugin-aware-resolver-prefers-plugin-root-and-falls-back-to-repo-only-for-maintainer-dogfood, SEC-1-bootstrap-creates-only-default-security-profile-yaml-in-user-repo-pointing-to-standard-level-without-copying-rules-files-which-stay-in-plugin-source, SEC-2-security-rule-and-agent-resolve-both-profile-and-rules-paths-via-explicit-priority-list-with-repo-override-then-plugin-source-fallback-applied-uniformly-to-profile-yaml-and-rules-level-md, SEC-3-standard-level-security-rules-md-shipped-with-base-five-checks-plus-deserialization-path-traversal-log-leak-tls-enforcement, RES-1-plugin-aware-helper-script-resolver-lib-introduced-and-sourced-by-all-hooks-that-call-scripts-rein-with-plugin-root-priority-over-repo-fallback-on-fresh-plugin-install, RES-2-helper-scripts-needed-by-fresh-plugin-user-shipped-in-plugin-bundle-with-bundle-test-asserting-presence-of-rein-mark-spec-reviewed-rein-codex-review-rein-validate-coverage-matrix, TST-1-plugin-bundle-parity-tests-rewritten-to-assert-overlay-absence-and-plugin-presence-matching-option-c-in-test-plugin-skills-agents-hooks-bundle-sh, VER-1-plugin-json-version-field-bumped-to-1-2-0-and-rein-publish-script-aborts-on-pre-publish-mismatch-between-plugin-json-and-rein-sh-version, BG-1-bootstrap-completion-detection-shared-helper-corrected-to-treat-trail-dir-plus-rein-project-json-marker-as-bootstrapped-and-eliminate-false-positive-across-all-four-gate-hooks, OPSEQ-1-operating-sequence-rule-injects-compact-action-mandate-listing-dod-routing-review-test-inbox-index-flow-on-session-start, WF-1-feature-builder-and-researcher-agent-descriptions-inline-non-obvious-workflow-rules-instead-of-naming-deleted-workflow-files, INC-1-incident-automation-helper-scripts-shipped-in-plugin-bundle-and-skills-resolve-via-plugin-aware-resolver-not-repo-local-paths, RTG-1-routing-procedure-injection-hook-fulfils-pre-edit-dod-gate-stderr-promise-by-emitting-routing-rule-body-on-dod-write-via-post-edit-dispatcher-sub-hook, RTG-2-skill-mcp-inventory-scanner-shipped-in-plugin-bundle-and-rein-state-paths-extended-with-skill-mcp-guide-state-path-replacing-claude-cache-hardcoded-reference]

## 배경

Option C migration (v1.1.0~v1.1.3) 후 plugin SSOT 와 scaffold-mode contract (branch-strategy.md, hook stderr 메시지) 사이 9 drift + 메인테이너 발견 2 추가 (SEC-3 standard.md ship, BG-1 bootstrap-gate false positive). codex 2 round audit + 사용자 product 결정 (incident-automation Keep, routing ceremony Keep) → 15 Scope IDs / 14 work units / 3 phases 로 spec/plan 작성. spec/plan codex review 4 round 후 self-review (Round 4 medium-only 1줄) 로 stamp 완료 (`.spec-reviews/0d935f44a966d2e8.reviewed`, `.spec-reviews/1ce69242c69817e6.reviewed`).

## 완료 기준 (cycle 전체)

### Phase 1 — Contract repair
- [x] BS-1, BS-2: branch-strategy.md L43-50 + L79 정정 (Wave 1 Task 1.1 PASS)
- [x] SEC-1: bootstrap 이 `.claude/security/profile.yaml` 만 생성 (rules 파일 제외) — Wave 2 PASS
- [x] SEC-2: security.md + security-reviewer.md 가 profile + rules 둘 다 priority list (repo override → plugin fallback) — Wave 2 PASS
- [x] SEC-3: `plugins/rein-core/security/rules/{base,standard}.md` ship (Wave 1 Task 1.5 PASS — 146 줄, 9 검사)
- [x] RES-1: `plugins/rein-core/hooks/lib/plugin-script-path.sh` 신축 + 5 hook sourcing (Wave 1 Task 1.2 + Fix A + Fix B 완료, 4 hook 추가 sourcing 14+ 지점)
- [x] RES-2: 3 helper plugin bundle 추가 (Wave 1 Task 1.6 + Fix E stale SOURCES 정리 + 보너스 rein-policy-loader drift sync)
- [x] TST-1: 3 bundle test 가 overlay 부재 + plugin presence assert (Wave 1 Task 1.7 PASS)
- [x] VER-1: plugin.json 1.2.0 + rein.sh VERSION 1.2.0 + rein-publish.sh parity assert (Wave 1 Task 1.8 + Fix C run-all.sh 등록)
- [x] BG-1: `lib/bootstrap-check.sh` 가 trail/ + `.rein/project.json` 동시 존재 시 PASS (Wave 1 Task 1.9 + Fix D fixture 갱신 + 신 K/L case + lib bilingual guidance 정정 + Wave 5 F7 English message + F8 fixture G(b) BG-1 신 contract, 17/17 + 7/7 PASS)

### Phase 2 — Operating-model legibility
- [x] OPSEQ-1: `plugins/rein-core/rules/operating-sequence.md` 신축 (1946 B ≤ 2 KB) + SessionStart inject 4번째 rule (Wave 3 PASS)
- [x] WF-1: feature-builder/researcher agent description 에 minimum workflow procedure inline (Wave 3 PASS)

### Phase 3 — Routing & incident data paths
- [x] INC-1: 4 incident helper plugin ship + 2 skill SKILL.md 의 호출 instruction plugin path + 2 hook RES-1 sourcing (Wave 4 PASS)
- [x] RTG-1: `post-write-routing-procedure-rule.sh` 신축 + `routing-procedure.md` (1019 B ≤ 1 KB) + dispatcher 등록 + stderr false promise 해소 (Wave 3 PASS)
- [x] RTG-2: `rein-scan-skill-mcp.py` plugin ship + `rein-state-paths.py` 에 `skill-mcp-guide` state 추가 + session-start-load-trail.sh 의 `.claude/cache` 하드코딩 제거 + Wave 5 F1 scanner plugin-aware refactor (Wave 4 + F1)

### Wave 5 — 잔존 fix (사용자 Option A 승인)
- [x] F1: scanner plugin-aware refactor (`_resolve_inventory_dir(project)` 추가, 두 mirror sha256 parity) — plugin mode mismatch 해소
- [x] F2: pre-edit-dod-gate.sh L267 (rein-aggregate-incidents resolver, fail-closed) + L292-293 message
- [x] F3: test bundle L31 "12" → "13" doc drift fix
- [x] F4: pre-edit-dod-gate.sh L370 message + L478-486 (rein-generate-skill-mcp-guide resolver, fail-graceful — advisory WARNING 의도 보존)
- [x] F5: scripts/rein-codex-review.sh layout probe (`${PROJECT_DIR}/plugins/rein-core/hooks/lib/` 추가, Option C dogfood drift 해소)
- [x] F6: plugins/rein-core/scripts/rein-codex-review.sh mirror sync (F5 누락 해소, sha256-identical)
- [x] F7: bootstrap-check.sh 영문 메시지에 "directory" 단어 추가 (test fixture A grep substring 호환)
- [x] F8: test-session-start-bootstrap fixture G(b) BG-1 신 contract 갱신 (trail/ only → prompt, 이전 silent)
- [x] F9: test-rules-prompt-bundle-drift skip 처리 (b8f2191 incomplete work, 별 cycle 후속)

### 통합 검증
- [x] `bash tests/scripts/run-all.sh` PASS — ALL SUITES PASSED (test-rules-prompt-bundle-drift SKIP 적용 후)
- [x] codex review (구현 완료 후) PASS — sonnet-fallback path (codex wrapper hang → general-purpose agent) → HIGH 1 + MEDIUM 1 + LOW 2 발견 → F6/F7/F8/F9 fix → ALL SUITES PASSED
- [x] security review PASS — base level, CRITICAL/HIGH/MEDIUM 0, LOW 3 advisory + INFO 4 defense-in-depth
- [x] CHANGELOG.md user-facing 항목 추가 (rein update 사용자 시점)
- [x] inbox 기록 — `trail/inbox/2026-05-14-v1-2-0-cycle-complete.md`
- [x] trail/index.md 갱신
- [ ] dev → main 선별 체크아웃 + tag v1.2.0 + push (사용자 확인 후, 별 turn)

### 제외 (versioning Rule A — internal 변경, no bump 영향 없음)
- 본 cycle 의 spec/plan/brainstorm 자체 (`docs/{specs,plans,brainstorms}/2026-05-14-plugin-mode-gap-fix.md`) — main 제외
- branch-strategy.md 정정 (BS-1, BS-2) — dev-only

## 작업 순서 (plan §작업 순서 권고)

1. **Task 1.2 (RES-1) + Task 1.9 (BG-1)** 먼저 — Phase 2/3 acceptance 가 둘 다 의존
2. SEC 묶음: Task 1.5 (SEC-3) → Task 1.3 (SEC-1) → Task 1.4 (SEC-2)
3. Phase 1 나머지 (1.1, 1.6, 1.7, 1.8) — 독립 병렬
4. Phase 2 (2.1, 2.2) — Phase 1 의 BG-1 PASS 후
5. Phase 3 (3.1, 3.2, 3.3) — Phase 1 의 RES-1, BG-1 PASS 후

본 DoD 의 첫 routing 추천은 **Task 1.2 (RES-1) 단독 시작** — 가장 의존성 많은 lib helper 부터.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:codex-review
  - rein:writing-plans
mcps: []
rationale:
  - 작업 성격: 신규 hook lib 작성 (`plugin-script-path.sh`) + 5 기존 hook 의 sourcing 패턴 통일 + unit test 6 case 신축. 전형적 feature 추가 + refactor.
  - 파일 패턴: `plugins/rein-core/hooks/lib/*.sh` (신규), `plugins/rein-core/hooks/*.sh` (편집), `tests/hooks/test-plugin-script-path-resolver.sh` (신규)
  - feature-builder 가 1차 구현 → codex-review 로 리뷰 게이트 (mandatory) → 코드 변경 적은 hook sourcing 은 sonnet self-review path 가능
  - writing-plans 는 본 cycle 의 plan 이 이미 있으므로 추가 plan 작성에는 불필요할 수 있음. 하지만 Task 1.2 가 lib 신설이므로 sub-plan 형태로 caller 패턴 표 작성 시 유용
  - mcps: 외부 데이터/문서 조회 불필요 — lib helper + 내부 hook refactor 만
approved_by_user: true   # 2026-05-14 user-approved (Task 1.2 RES-1 시작)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (session start)
- [x] spec/plan stamp 확인 (`.spec-reviews/0d935f44a966d2e8.reviewed`, `.spec-reviews/1ce69242c69817e6.reviewed`)
- [x] dev 브랜치 확인
- [x] coverage validator PASS (15 ID 일치)
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 위험 요약 (spec Risks 5건 압축)

- R1: RES-1 lib 이 5+ hook 에서 sourced — caller 패턴 통일 + unit test 6 case 로 회귀 방지
- R2: RTG-1 routing-procedure.md ≤ 1 KB 압축 가능
- R3: SEC-1 default `standard` 의 false positive — generated profile.yaml 헤더에 base 변경 안내
- R4: branch-strategy.md 정정이 main 머지 절차와 동시 — dev 단방향 + main 머지 PR description 강조
- R5: BG-1 marker 강화로 의도된 차단 유지 — `.rein/project.json` 부재 시 차단 (test-bootstrap-check-helper.sh 갱신)

## 다음 단계 (라우팅 승인 후)

1. 사용자 "진행해" 또는 라우팅 수정 의견 → `approved_by_user: true` 갱신
2. Task 1.2 (RES-1) IMPLEMENT — `plugin-script-path.sh` 신축 + 5 hook sourcing + unit test
3. `/codex-review` (Mode A) — Task 1.2 완료 후 코드 리뷰 게이트
4. security-reviewer — Task 1.2 가 hook 동작 변경이므로 보안 리뷰 (lib 의 fail-open 정책 검증)
5. 두 stamp 통과 후 Task 1.9 (BG-1) 또는 다른 Phase 1 task 로 이동
