# DoD — Option C Phase 3: overlay 정리 + dogfood install

- 날짜: 2026-05-13
- 유형: implementation (Phase 3)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`

## 범위 연결

plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md
work unit: Phase 3 / Task 3.0 ~ 3.9
covers: [S4, S5, S6, S7]

## 목적

plugin SSOT 를 단일 source of truth 로 만들기 위해 `.claude/` 에서 plugin 과 중복되는 surface 를 제거한다. 메인테이너 환경이 `/plugin install rein@rein` 으로 동작하는 dogfood 상태가 되어 사용자 환경과 동일해진다.

## 안전 순서 (strict — sub-step 간 세션 재시작 필수)

| # | Task | 동작 | 검증 | 세션 재시작 |
|---|---|---|---|---|
| 1 | 3.0 | `enabledPlugins` schema 검증 (Context7 / WebFetch) | docs 인용 + evidence 기록 | — |
| 2 | 3.1 | `/plugin marketplace add file://…rein-dev` + `/plugin install rein@rein` | `/plugin list` 에 rein 표시 | — |
| 3 | 3.2 | plugin hook 등록 확인 | `/hooks` 출력 + trace trigger count ≥ 2 | ✅ #1 |
| 4 | 3.3 | `.claude/settings.json` overlap 6 hook 제거 (S6) | hooks 항목 == 0 | — |
| 5 | 3.4 | trigger count == 1 (S7) | trace 표 | ✅ #2 |
| 6 | 3.5 | `.claude/CLAUDE.md` shared 7 `@import` 제거 (S4 part 1) | `grep -cE '^@\.claude/rules/'` == 3 | — |
| 7 | 3.6 | `.claude/rules/` shared 7 파일 `rm` (S5) | `ls .claude/rules/*.md \| wc -l` == 4 | — |
| 8 | 3.7 | missing-import 에러 없음 (S4 part 2) | session start log | ✅ #3 |
| 9 | 3.8 | `.claude/{hooks,skills,agents}/` `rm -rf` | `.claude/` 잔존 파일 확인 | — |
| 10 | 3.9 | plugin-only 동작 확인 (S7 part 2) | Edit 차단 + trace path | ✅ #4 |

## 검증 게이트 (모두 통과해야 Phase 3 완료)

- [x] Task 3.0: `enabledPlugins` schema = object `{"<plugin>@<marketplace>": true}` 확인 (Context7 + WebFetch evidence: `trail/decisions/2026-05-13-option-c-phase-3-task-3-0-schema-evidence.md`)
- [x] Task 3.1: `/plugin install rein@rein` 후 `installed_plugins.json` 의 `rein@rein` entry 확인 (scope=local, version=1.1.2, gitCommitSha=bf6b86a)
- [x] Task 3.2: plugin hook 등록 + system-reminder inject 확인 (재시작 #1)
- [x] Task 3.3: settings.json hooks={} + plugins 키 제거 (`hooks 항목 합계 == 0` Bash 검증 통과)
- [x] Task 3.4: 세션 재시작 #2 후 PreToolUse:Bash 의 `Background Jobs` rule 1회 inject (plugin-only hook `pre-tool-use-bash-rules.sh` 만 trigger) — overlap 6 hook 중 어느 것도 1회 초과 inject 없음
- [x] Task 3.5: `grep -cE '^@\.claude/rules/' .claude/CLAUDE.md` == 3 (branch-strategy / readme-style / versioning)
- [x] Task 3.6: `ls .claude/rules/*.md | wc -l` == 4 (branch-strategy / readme-style / versioning / legacy-shipped-pending)
- [x] Task 3.7: 세션 재시작 #3 후 SessionStart context 에 `missing import` 류 없음 + 3 @import 모두 파일 존재 확인 (각 13527/10019/6443 bytes)
- [x] Task 3.8: `/bin/ls -d .claude/{hooks,skills,agents}` 모두 "No such file or directory"
- [x] Task 3.9: 세션 재시작 #4 후 plugin-only 동작 확인 — SessionStart hook 의 `trail/index.md` + `Code Style Rules` + `Security Rules` + `Testing Rules` + `Answer-only Mode` + PreToolUse Bash 의 `Background Jobs` 모두 plugin source `plugins/rein-core/hooks/*-rules.sh` 에서 1회씩 inject. agent type 변화 확인 — overlay agent (feature-builder/researcher/security-reviewer 등) "no longer available", `rein:*` namespaced agent 만 잔존.

## Trace evidence (Phase 3 verification artifact)

본 cycle 의 conversation 안에서 plugin source `plugins/rein-core/hooks/hooks.json` 의 등록 hook 별 inject 측정:

| Event:Matcher | Plugin hook | Inject content (관찰) | Trigger count |
|---|---|---|---|
| SessionStart | `session-start-bootstrap.sh` | trail/* directory bootstrap (silent on existing project) | 1회/세션 (각 재시작 #1~#4) |
| SessionStart | `session-start-load-trail.sh` | trail/index.md + freshness 경고 + skill/MCP 가이드 | 1회/세션 |
| SessionStart | `session-start-rules.sh` | Code Style + Security + Testing Rules (concat 5613 bytes) | 1회/세션 |
| UserPromptSubmit | `user-prompt-submit-rules.sh` | Answer-only Mode | 1회/turn |
| PreToolUse:Edit\|Write\|MultiEdit | `pre-edit-trail-bootstrap-gate.sh` | (정상 trail/ 상태에서 silent) | 0건 inject, hook trigger 됨 |
| PreToolUse:Edit\|Write\|MultiEdit | `trail-rotate.sh` | (rotate 필요 시만 작동, 본 cycle 에서 inbox 7개 → weekly 묶음 1회) | conditional |
| PreToolUse:Edit\|Write\|MultiEdit | `pre-edit-dod-gate.sh` | (active DoD + approved_by_user 통과 시 silent) | gate trigger 됨 |
| PreToolUse:Bash | `pre-tool-use-bash-bootstrap-gate.sh` | (정상 trail/ 상태에서 silent) | gate trigger 됨 |
| PreToolUse:Bash | `pre-bash-guard.sh` | (review stamp 부재 시 BLOCKED, 본 cycle Phase 3 review 전 commit 시도에서 정상 차단) | gate trigger 됨 |
| PreToolUse:Bash | `pre-tool-use-bash-rules.sh` | Background Jobs rule | 1회/Bash 호출 |
| PreToolUse:Agent | `pre-tool-use-agent-rules.sh` | (Agent tool 호출 시 inject. 본 cycle 에서 Agent 호출 없음) | 0 (조건 미충족) |
| PostToolUse:Edit\|Write\|MultiEdit | `post-edit-dispatcher.sh` | (sub-hook aggregate. 본 cycle Edit 후 design-plan-coverage rule body re-inject 관찰) | 1회/Edit |
| Stop | `stop-session-gate.sh` | (세션 종료 gate. 본 cycle 에서 미발화) | conditional |

**Deterministic trigger count == 1 결정적 증거**: 만약 overlay 가 살아있었다면 같은 hook source 가 둘 (overlay + plugin) 등록되어 inject 가 2회 보였을 텐데, 본 cycle 4번 재시작 모두에서 각 inject content 가 1회만 관찰됨. overlay 폐기 후 plugin-only 동작 확증.

추가 evidence:
- Task 3.0 schema 검증: `trail/decisions/2026-05-13-option-c-phase-3-task-3-0-schema-evidence.md`
- Task 3.7 codex-ask second opinion: codex Round 1 (gpt-5.5/medium) — Q4 hidden coupling concern 짚어줌 → Task 3.7.A 후속 (stale test redirect 7+1개) 로 해소

## Rollback

문제 시 3.9 → 3.8 → … → 3.1 역순으로 `git restore .claude/{CLAUDE.md,rules,settings.json,hooks,skills,agents}` + `/plugin uninstall rein@rein`.

## Release

본 cycle main 머지 = none (Rule A, plan §Phase 6). 다음 user-facing release cycle 에 plugin SSOT 변경분과 묶음 (Task 6.2).

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review        # 각 sub-step 묶음별 변경분 리뷰
  - codex-ask           # Task 3.0 schema 검증의 second opinion (선택)
mcps:
  - plugin_context7_context7  # Task 3.0 — Claude Code 공식 docs 조회 (enabledPlugins schema)
  - WebFetch                  # context7 미커버 시 fallback
rationale: |
  Phase 3 는 .claude/ overlay 의 settings.json / CLAUDE.md / rules / hooks-skills-agents
  편집 + 세션 재시작 + trace 검증. 코드 편집 비중이 크므로 feature-builder. Task 3.0 의
  enabledPlugins schema 는 외부 docs 검증이 필요 (rein 코드 내에 답 없음) — context7 MCP
  로 Claude Code 공식 docs 조회, 미커버 시 WebFetch. 각 sub-step 변경분 묶음은
  codex-review 로 리뷰 (stamp 생성). 세션 재시작 4회 사이에 사용자 인터랙션 필요.
approved_by_user: true
```

## Self-review (Phase 3 종료 시 작성)

- [ ] 모든 Task 검증 게이트 통과
- [ ] codex-review PASS + security-reviewer No concerns
- [ ] trail/index.md 갱신 (Phase 3 완료 + Phase 4 진입점)
- [ ] inbox 기록 (`trail/inbox/2026-05-13-option-c-phase-3-overlay-cleanup.md`)
