# Changelog

> **Versioning policy**: 버전 bump 는 `.claude/rules/versioning.md` 의 Rule A/B/C 를 따른다.

## v1.1.3 — 2026-05-14 (Option C — plugin SSOT 단독 + dogfood model)

v1.1.0~v1.1.2 동안 plugin-first 전환을 마쳤지만, plugin source (`plugins/rein-core/`) 와 메인테이너 dev overlay (`.claude/`) 가 sha256-mirror 관계로 양쪽에 같은 hooks/skills/agents 가 중복 보유되어 drift 위험 + tarball 사이즈 부담이 누적됐습니다. v1.1.3 은 **plugin SSOT 단일화 + 메인테이너 dogfood install** 전환을 마치고 그 결과를 ship 합니다. `rein update` 후 사용자 세션에서 바뀌는 것:

- **`design-plan-coverage` rule body 정확화** — SessionStart 시 plugin 이 inject 하는 rule 본문에 `## 행동 강령` summary + behavior-level Scope ID v2 의 acceptable/non-acceptable 예시 + Stage 1/2/3 enforcement 표가 모두 포함됩니다. 사용자 plan 작성 시 더 명확한 contract 가이드.
- **SessionStart banner path 정확화** — banner 의 `answer-only-mode.md` reference 가 `${CLAUDE_PLUGIN_ROOT}/rules/...` 로 재작성. installed plugin cache 에서도 정확한 경로 표기 (이전엔 dev-only path 표시).
- **Plugin tarball 사이즈 감소** — `plugins/rein-core/docs/rules/` 의 4 mirror 파일 (legacy-shipped-pending, background-jobs, design-plan-coverage, subagent-review) 폐기. install size + cache footprint 약간 감소. 사용자 hook 동작 변화 없음 (rule body inject 는 `plugins/rein-core/rules/` 가 source).

영향 없음: `rein` CLI 명령 표면 / hook 차단 정책 / 사용자 ship 표면 자체 변화 없음. 본 release 는 patch — 메인테이너 환경의 큰 변경 (`.claude/{hooks,skills,agents}/` overlay 폐기 → plugin SSOT 단독) 이 사용자에게는 거의 invisible.

Internal (메인테이너 dev 환경, 사용자 무관):
- `.claude/hooks/`, `.claude/skills/`, `.claude/agents/` overlay 전체 폐기. plugin source 가 단독 SSOT. 메인테이너는 `/plugin install rein@rein` 으로 dogfood 운영.
- `scripts/rein-check-plugin-drift.py` 가 boundary (`.claude/rules/` shared rule mirror 금지) + parity (plugin ↔ dev tree sha256 동일) + validation (mandate section + inject envelope + hooks.json schema) 3 layer 통합 도구로 재작성. `scripts/rein-validate-plugin-rules.py` 는 wrapper-only shim (backward compat).
- `tests/scripts/test-rein-check-plugin-drift-boundary.sh` 신규 (8 test, post-cleanup invariant + isolated 7-mirror fixture). `tests/hooks/test-{background-jobs,design-plan-coverage,subagent-review,legacy-pending-heal}-registered.sh` 갱신 (hooks.json nested schema + plugin source path redirect).
- `.claude/rules/branch-strategy.md` 의 ✅ 포함 / ❌ 제외 표를 plugin SSOT 중심으로 재작성. 9 GitHub workflow 모두 분류 (public 도달 2 + maintainer-only mirror-strip 7). `.github/workflows/plugin-drift-check.yml` 의 transitional `--skip-boundary` 제거.
- 본 cycle 의 검증 결과 (sandbox dogfood inject byte > 0, trigger count == 1 deterministic, cache rebuild 검증 5/5 PASS) 모두 `trail/decisions/2026-05-13-option-c-sandbox-verification.md` + `trail/decisions/2026-05-14-plugin-cache-verification-evidence.md` 에 영구 보관.

## v1.1.2 — 2026-05-12 (Plugin self-containment hotfixes)

v1.1.0 plugin-first 전환 이후 사용자 repo 에서 scaffold 잔재를 정리한 환경에서 발견된 plugin 자체 결함 2건 hotfix. `rein update` 후 사용자 세션에서 다음이 바뀝니다.

- **`/codex-review` 가 scaffold 없는 사용자 프로젝트에서도 동작** — wrapper (`rein-codex-review.sh`) 가 더 이상 사용자 repo 의 `.claude/hooks/lib/select-active-dod.sh` 를 source 하지 않습니다. 자기 plugin tree 의 sibling 번들 lib 를 사용 (plugin self-containment). scaffold 를 지운 plugin-first 사용자도 `/codex-review` 정상 호출.
- **monorepo subdirectory 에서 Bash 차단 false-positive 해소** — PreToolUse:Bash hook 의 `bootstrap-check.sh` 가 Claude Code envelope 의 `cwd` (Bash 도구의 셸 CWD) 를 그대로 project_dir 로 채택하던 동작 변경. monorepo 에서 `cd apps/web` 한 뒤 모든 Bash 호출이 차단되던 증상 해결. 이제 `git -C <stdin.cwd> rev-parse --show-toplevel` 로 git root 까지 walk up 해서 부트스트랩 contract 와 정렬.
- **nested .git 경계 존중** — sub-project 가 자체 `.git/` 가진 경우 walk-up 은 그 nested boundary 에서 멈춥니다 (outer monorepo root 로 escape 안 함).
- **git env redirection 차단** — bootstrap-check 의 새 git 호출은 `GIT_DIR` / `GIT_WORK_TREE` / `GIT_COMMON_DIR` / `GIT_INDEX_FILE` 를 unset 한 상태로 실행. caller 환경의 git env 가 walk-up 결과를 다른 worktree 로 redirect 못 함. `GIT_CEILING_DIRECTORIES` 는 policy-sensitive 라 의도적으로 preserve.

영향 없음: `/codex-review` 호출 인터페이스 변경 없음. 기존 scaffold 모드 사용자는 wrapper 가 자동으로 legacy `.claude/hooks/lib/` fallback 사용 (probe-based dual-layout resolver).

## v1.1.1 — 2026-05-12 (Plugin bootstrap gate hotfix)

v1.1.0 의 silent bootstrap failure (`trail/` 미생성 + 사용자 surface 누락) 를 hard gate 로 수정. `rein update` 후 사용자 세션에서 다음이 바뀝니다.

- **첫 source 편집·Bash 호출 직전 차단 + 한 줄 명령 안내** — `trail/` 디렉토리가 없으면 PreToolUse(Edit|Write|MultiEdit) 또는 PreToolUse(Bash) gate 가 `exit 2` 로 차단하고 stderr 에 bootstrap 명령을 표시합니다. 사용자가 그 명령 한 번 실행 → `trail/` + `.rein/` 생성 → 다음 편집부터 정상.
- **`/reload-plugins` 후에도 동일 동작** — 새 세션 시작 경로와 `/reload-plugins` 경로 모두 같은 helper / 같은 메시지 / 같은 명령으로 수렴합니다. SessionStart hook 의 silent surface 한계를 PreToolUse hard gate 로 우회.
- **Non-git 프로젝트 지원** — `rein-bootstrap-project.py` 가 `git_root` 없을 때 `project_dir` 자체를 root 로 사용합니다. `git init` 절대 호출 안 함. 사용자가 git repo 가 아닌 폴더에서도 rein 활성화 가능.
- **UserPromptSubmit advisory** — 사용자가 첫 turn 에서 질문만 하더라도 `trail/` 부재를 알리는 advisory 가 매 user turn 마다 inject 됩니다 (편집 안 하는 turn 도 cover).
- **Opt-out 2-layer × 2-format** — `.rein/policy/hooks.yaml` 의 `bootstrap-gate: false` (umbrella, 두 gate 모두 off) 또는 individual key `pre-edit-trail-bootstrap-gate` / `pre-tool-use-bash-bootstrap-gate` (각각 bool 또는 `{enabled: false}` mapping) 로 비활성. 우선순위: individual > umbrella > default enabled.
- **Helper 메시지에 surface instruction 포함** — 안내 텍스트 끝에 `(Claude: surface this message to the user immediately before doing anything else.)` 명시. 모델 surface 확률 강화 (단 hard guarantee 는 PreToolUse 차단 자체).

Internal: `plugins/rein-core/hooks/lib/bootstrap-check.sh` helper (exit 0/10/11 + 5 unsafe categories + read-only git contract + authoritative write-attempt). 두 신규 차단 hook 가 Edit/Write/MultiEdit + Bash matcher group 의 첫 번째 hook 으로 배치 (`trail-rotate.sh` / `pre-bash-guard.sh` 보다 앞). `session-start-bootstrap.sh` 가 helper source 로 refactor 되어 메시지 owner 통일.

[v1.1.0 release notes](#v110--2026-05-12-plugin-prompt-level-operating-model).

## v1.1.0 — 2026-05-12 (Plugin prompt-level operating model)

7개 user-facing rule 의 prompt-level 책임을 plugin 사용자에게 적시 전달하는 lifecycle 확장. `rein update` 후 사용자 세션에서 다음이 바뀝니다.

- **세션 시작 시 더 풍부한 rule body inject** — 기존 `code-style` / `security` / `testing` 3개에 더해, `answer-only-mode` / `subagent-review` / `background-jobs` / `design-plan-coverage` 4개가 plugin tarball 에 포함됩니다. 각 rule 의 첫 단락은 **행동 강령 (action mandate)** — ≤2KB 의 self-contained 결론으로, Claude Code 의 10,000 chars cap 안에 항상 inline 보장.
- **새 hook 3개 작동 시점**:
  - `UserPromptSubmit` (매 사용자 turn) → `answer-only-mode` rule body advisory
  - `PreToolUse(Bash)` (Bash 도구 선택 직후) → `background-jobs` rule body advisory — `pre-bash-guard.sh` 의 차단 동작은 그대로 유지, 별도 advisory-only hook 으로 분리
  - `PreToolUse(Agent)` (subagent 호출 직전) → `subagent-review` rule body advisory
- **PostToolUse 이벤트 inject** — `docs/specs/**`, `docs/plans/**`, `trail/dod/dod-*.md` write/edit 직후 `design-plan-coverage` rule body 가 자동 inject 됩니다.
- **Rule body 가 cap 초과해도 잘리지 않음** — rein 은 자체 truncate 하지 않고 Claude Code 의 overflow-file handoff (full body 를 임시 파일로 + path 전달) 에 위임합니다.
- **broken reference 5건 해소** — `pre-edit-dod-gate.sh` / `post-write-dod-routing-check.sh` 의 stderr 메시지에서 사용자 repo 에 없는 `orchestrator.md` / `.claude/CLAUDE.md` 참조 제거. 대신 inline 절차 안내 ("DoD 에 '## 라우팅 추천' 섹션을 추가하세요…").
- **plugin rule 위치 정리** — `plugins/rein-core/skills/rules-prompt/` → `plugins/rein-core/rules/` 로 이동. skill 폴더 안 rule body 라는 어색한 layout 해소. `session-start-rules.sh` 의 `RULES_DIR` 함께 갱신.
- **post-edit dispatcher 출력 단일화** — 7 sub-hook 의 stdout 을 단일 JSON envelope 로 통합 (구분자 `\n\n---\n\n`). 기존 stderr 메시지는 그대로 통과. sub-hook 중 어느 하나라도 `exit 2` 면 dispatcher 도 `exit 2` 로 차단 (rein 의 hard-block 의미 보존).
- **publish-time 형식 검사** — `scripts/rein-publish.sh` 가 tarball build 전 `scripts/rein-validate-plugin-rules.py` 를 실행. `## 행동 강령` 절 존재 + ≤2KB + 모든 unconditional inject hook 이 valid PostToolUse/PreToolUse/UserPromptSubmit/SessionStart envelope 을 emit + `hooks.json` 의 모든 command target 이 실재 + executable 인지 검증.

Internal: `plugins/rein-core/hooks/lib/rule-inject.sh` helper (override probe + byte-exact passthrough + size diagnostic), `plugins/rein-core/hooks/lib/aggregator.sh` (NUL-framed concat helper), `tests/hooks/run-all.sh` 에 v1.1.0 신규 16 테스트 등록. `plugins/rein-core/docs/overflow-handoff.md` 신설로 cap 초과 시 동작 원리 문서화.

[v1.0.4 release notes](#v104--2026-05-11-domain-plugin-decommission--tarball-cleanup).

## v1.0.4 — 2026-05-11 (Domain plugin decommission + tarball cleanup)

- **`.claude/rules/legacy-shipped-pending.md` 가 public release tarball 에서 사라집니다** — v1.0.3 의 Q9 fix 후속. 메인테이너 회복 정책 문서로 dev-only 분류되었습니다. 사용자 hook 동작에는 영향 없음 (실 동작은 `scripts/rein-heal-legacy-pending.py` 가 처리).

Internal: 도메인 plugin 패키지 3개 (`plugins/rein-stitch`, `plugins/rein-react`, `plugins/rein-remotion`) + 8개 도메인 skill (`stitch-design`, `stitch-loop`, `taste-design`, `design-md`, `enhance-prompt`, `react-components`, `remotion`, `shadcn-ui`) 모두 폐기. marketplace.json 의 `plugins[]` 에는 처음부터 `rein-core` 만 등록되어 있어 사용자 install 경로가 부재했고, 통합 계획이 취소됐습니다. 의존 `tests/scripts/test-domain-plugins-bundle.sh` + drift checker 의 `DOMAIN_SKILL_DIRS` 화이트리스트 + branch-strategy 11 줄 함께 정리.

[v1.0.3 release notes](#v103--2026-05-11-mirror-tag-hygiene--reinsh-cleanup).

## v1.0.3 — 2026-05-11 (Mirror tag hygiene + rein.sh cleanup)

- **Public release tarball hygiene** — mirror workflow 가 release tag 도 strip 적용된 tree 로 force retag 한 뒤 push합니다. 신규 release (v1.0.3+) 부터 GitHub release `Source code (zip/tar.gz)` 안에 maintainer-only workflow (`daily-trail-audit.yml`, `repo-audit.yml`, `weekly-agent-evolution.yml`) + dev-only rule (`legacy-shipped-pending.md`) 가 포함되지 않습니다. 기존 v1.0.0~v1.0.2 tag 는 그대로 두며, 재게시 (retag) 는 별도 결정 사항.
- **`rein update` 메시지 미세 정정** — `claude plugin update rein-core` → `rein` (plugin manifest 의 `name` 과 정합).

Internal: `scripts/rein.sh` 의 약 1,335 줄 dead code 제거 — v1.0.0/v1.0.1/v1.0.2 거치며 `cmd_init`/`cmd_merge`/`cmd_update`/`cmd_remove` 가 단순화 또는 제거되며 caller 0 가 된 helper 약 30 개 + 7 dead globals + `rein_manifest_helper`/`rein_path_match_helper` 두 dead resolver (v1.0.2 에서 가리키는 Python 파일 삭제됨) 정리. 의존하던 stale 테스트 3 개 (`test-state-helpers.sh` / `test-gitignore-entries.sh` / `test-is-text-file.sh`) 삭제.

[v1.0.2 release notes](#v102--2026-05-11-claude-performance-hooks).

## v1.0.2 — 2026-05-11 (Claude performance hooks)

세션 시작/편집 hook 의 응답성을 개선하는 patch.

- **SessionStart 헤더 압축 + skill/MCP scan cache** — `trail/index.md` + skill 인벤토리 주입 시 cache 활용으로 lean SessionStart 응답속도 단축.
- **post-edit dispatcher 통합** — 7개 post-edit hook 을 단일 `post-edit-dispatcher.sh` 로 묶어 sub-hook fan-out 비용 절감 (Read tool 트리거에서는 post-edit hook 자체 skip).
- **policy profile (`lean` / `standard` / `strict`)** — `.rein/policy/hooks.yaml` 의 `profile:` 키로 hook 활성 범위 토글. lean = 단순 탐색/문서 작업용 (plan-coverage/spec-review-gate/dod-routing-check off).
- **trail-rotate early skip** — 하루 1회 실행 marker 가 fresh 하면 즉시 종료.
- **`rein-policy-loader.py` 신설** — profile + per-hook 토글 resolution 의 SSOT.

Internal: `scripts/rein-manifest-v2.py` + `scripts/rein-path-match.py` 제거 (v1.0.1 의 scaffold drop 으로 caller 0). `scripts/rein-bootstrap-project.py` 신설 (plugin-mode bootstrap 진입점).

[v1.0.1 release notes](#v101--2026-05-11-scaffold-drop-completion).

## v1.0.1 — 2026-05-11 (Scaffold drop completion)

v1.0.0 launch 의 declarative scaffold drop 을 코드 차원에서 완결합니다.

- `rein init` 명령 제거 — `init` / `init --mode=plugin` / `init --mode=scaffold` 모두 `unknown command 'init'` + exit 1 로 응답합니다. 설치는 Claude Code plugin marketplace 흐름만 사용합니다 (`/plugin marketplace add JayJihyunKim/rein` + `/plugin install rein@rein`).
- `rein migrate` 명령 제거 — v1.x scaffold → plugin 마이그레이션 helpers (`rein-migrate.sh` 등) 가 함께 사라집니다. v1.0.0 시점 사용자 베이스 0 가정 기반의 hard cut.
- repo root 의 `install.sh` 제거 — `curl|bash` 설치 흐름이 사라집니다. README / Windows troubleshooting 도 plugin marketplace 흐름으로 갱신.
- 사용자 repo 의 router state 디렉토리가 `.claude/router/` → `.rein/policy/router/` 로 이동합니다. `rein-route-record.py` 는 legacy `.claude/router/` 를 더 이상 fallback 으로 받지 않습니다 (hard-fail).
- README 의 "Claude scaffolds" 표현 + `.claude/settings.json` 자동 생성 안내 제거. plugin marketplace 흐름에 맞춰 KR/EN 동기화.

[v1.0.0 launch](#v100--2026-04-30-plugin-only-oss-launch) 의 deferred 항목을 단일 patch 로 ship 했습니다. user-facing 변경은 위 5 줄이며, 내부 정리 (migrate helpers / drift checker 어휘 / mirror strip 확장 / superseded 배너) 는 dev-only 라 본 entry 에 포함하지 않습니다.

## v1.0.0 — 2026-04-30 (Plugin-only OSS launch)

- 정식 OSS launch 의 첫 버전.
- Claude Code plugin 모드 (rein-core / rein-stitch / rein-react / rein-remotion) 가 유일한 install 경로. scaffold 모드 / `rein init --mode=scaffold` / `rein remove --path` 는 제거됨.
- 이전 dev cycle history (v0.x ~ v2.0.0) 는 [archive](docs/changelog-archive/2026-04-pre-v1.md) 를 참조.
