# Changelog

> **Versioning policy (2026-04-22~)**: 버전 bump 는 `.claude/rules/versioning.md` 의 **Rule A/B/C** 를 따른다 — (A) 변경 유형별 bump (user-facing breaking=major, new feature=minor, fix=patch, internal=no bump), (B) 같은 날 복수 bump 금지 (hotfix 예외), (C) CHANGELOG 는 user-facing 만. 규칙 제정 이전 릴리즈 (v1.1.0 이하) 중 **v1.0.0 → v1.1.0 (2026-04-21 당일 2회차)** 는 Rule B 기준 위반이었으나 bump 값 자체는 Rule A 정당 (rein job / rein remove / 3-way merge 등 신규 user-facing CLI). 소급 롤백 없음. 이 policy 부터 새 규칙 적용.

## [v1.1.2] - 2026-04-24

### Fixed

- **`rein update` 후 Permission denied**: 일부 훅 파일의 실행 권한이 사라지던 현상 수정. 내용이 같더라도 mode 가 다르면 이제 갱신된다.
- **3-way merge 가 실제로 동작**: v1.1.0 CHANGELOG 가 약속했던 사용자 수정 보존 + template 병합이 production `rein update` 경로에 연결됐다. v1.1.0 ~ v1.1.1 사용자는 legacy 2-way prompt 만 경험했음.

### Removed

- **`rein-route-record doctor` 서브커맨드** — v0.8.0 일회성 migration 명령. v0.8.0 ~ v1.1.1 사이 `rein update` 한 프로젝트는 이미 migration 완료. 신규 설치는 현재 schema 로 시작하므로 실행할 일 없음.

### Behind the scenes

실행 경로 정합성 + CI 안정화. 구현 디테일은 git log 참조.

## [v1.1.1] - 2026-04-22

### Fixed

- **DoD gate bypass**: `.claude/hooks/pre-edit-dod-gate.sh` 가 `.claude/rules/*`, `.claude/skills/**`, `.claude/agents/*`, `.claude/workflows/*`, `.claude/CLAUDE.md`, `.claude/orchestrator.md`, `.claude/settings.json`, `AGENTS.md`, `.gitignore` 편집 시 DoD 를 요구한다. 이전 버전은 blanket `.claude/**` 면제로 이들 main-포함 source 편집이 DoD 없이 통과됐다. `.claude/cache/**`, `.claude/.rein-state/**`, `trail/**`, `.gitkeep` 는 계속 면제 (runtime state + placeholder).
- **codex-review wrapper 의 design_ref resolve**: `scripts/rein-codex-review.sh` 가 plan 의 `> design ref: ../specs/foo.md` 같은 plan-relative 경로를 올바르게 해석한다. 이전 버전은 문자열 그대로 사용해 파일을 못 찾으면서도 envelope 에는 `design_ref: present` 로 거짓 보고했다. 이제 resolve 실패 시 `MISSING (unresolved ref: <raw>)` 로 정직하게 표기.
- **plan 의 `Design Reference:` 상단 형식 지원**: wrapper 와 validator 양쪽 모두 `> design ref:` 블록인용과 top-level `Design Reference:` 형식을 동등 허용. 이전 validator 는 전자만 지원해 parity 가 깨져 있었다.
- **DoD 의 `plan ref:` annotation strip**: validator 가 `plan ref: path.md (Team A)` 형태의 팀/라벨 suffix 를 strip 한다. 허용된 패턴은 `(Team <LETTER>)` 와 `(<식별자>)` 만 — 경로명 자체 괄호 (`plan(v2).md`) 는 보존.
- **Multi `plan ref:` DoD fail-closed**: DoD 의 `## 범위 연결` 섹션에 `plan ref:` 가 2개 이상이면 validator 가 명시적 에러로 exit 2. 기존 v1.1.0 DoD 는 `PHASE_2_GRANDFATHER_DODS` 예외로 WARN + matrix union 검증 (Phase 2 integration DoD 스키마 랜딩 시 이 리스트에서 제거 예정).

### Security

- v1.1.0 retrospective security review 완료. 4 Low findings (defense-in-depth, 모두 non-blocking). Critical/High/Medium 0. `trail/dod/.security-reviewed` cycle 을 `v1.1.0-retro+phase1` 로 갱신.

## [v1.1.0] - 2026-04-21

### Added

- **rein-govcheck** (`scripts/rein-govcheck.py`): governance self-test that scans AGENTS.md / `.claude/CLAUDE.md` / `.claude/orchestrator.md` / hooks for every `scripts/rein-*.{sh,py}` reference and validates each (ast.parse for Python, `bash -n` for shell). CI workflow `.github/workflows/govcheck.yml` runs it on dev.
- **path-policy lib** (`.claude/hooks/lib/path-policy.sh`): single-source `is_plan_path` / `is_spec_path` matchers (canonical + legacy dated `docs/YYYY-MM-DD/*-{plan,design}.md`). Removes inline regex duplication from hooks.
- **validator v2 subcommands** (`scripts/rein-validate-coverage-matrix.py`): `plan <path>` and `dod <path>` explicit subcommands. Legacy 1-arg CLI preserved as shim.
- **DoD `## 범위 연결` section**: plan_ref / work_unit / covers metadata in DoDs; validator v2 enforces `covers ⊆ matrix.implemented` (advisory in Stage 1, blocking in Stage 2+).
- **codex-review wrapper** (`scripts/rein-codex-review.sh`): centralized context assembly (diff base, active DoD, plan/design refs, scope items, covers, claim sources, changed files), 4-slot envelope (Code defects / Design Alignment / Test Alignment / Claim Audit), `CODEX_BIN` injection seam for tests. CRITICAL spec-review mode invariant: `[NON_INTERACTIVE] spec review for plan:/design:` marker in stdin → wrapper never writes `.codex-reviewed` or touches `.review-pending`.
- **governance stage config** (`.claude/.rein-state/governance.json`, `.claude/hooks/lib/governance-stage.sh`): Stage 1 (advisory) / Stage 2 (blocking active DoD) / Stage 3 (blocking legacy-dated plan) gradual rollout. File absent = Stage 1 (fail-safe default). Malformed config = fail-closed at every stage.
- **rein update manifest v2 + 3-way merge** (`scripts/rein.sh`, `scripts/rein-manifest-v2.py`): on first update from a v1 manifest the update loop preserves text-file user edits and seeds a base snapshot under `.claude/.rein-state/base/` instead of prompting. Subsequent updates run `git merge-file` 3-way against the base, writing conflict `.rej` under `.claude/.rein-state/conflicts/` when merge markers appear. `rein update --prune` splits into review (dry-run) vs `--prune --confirm` (backup to `.rein-prune-backup-<ts>/`).
- **rein remove** (`scripts/rein.sh`, `scripts/rein-path-match.py`): new command with mandatory scope flag — `--path <glob>` (anchored segment matcher, never matches outside rein-installed paths) or `--all --confirm` (typed DELETE confirmation, TTY-only). Modified files always preserved; backups live in `.rein-remove-backup-<ts>/`.
- **rein job** (`scripts/rein.sh`, `scripts/rein-job-wrapper.sh`): new background job infrastructure for long-running commands. `rein job start <name> [--shell] -- <cmd>` detaches the command (setsid preferred, nohup / `( ... & )` fallbacks), writes atomic `.claude/cache/jobs/<jid>.{json,status,exit,log}`, returns within ~1s. Supporting subcommands: `rein job status/stop/tail/list/gc`. POSIX uses `kill -TERM -<pid>` pgroup; MINGW uses `taskkill /F /T /PID` tree kill with `MSYS2_ARG_CONV_EXCL="*"`.
- **background-jobs rule** (`.claude/rules/background-jobs.md`): Claude Code integration guide — `rein job` replaces foreground long-sync commands and cross-turn BashOutput state. Loaded via `@import` in `.claude/CLAUDE.md`.
- **anchored-segment path matcher** (`scripts/rein-path-match.py`): shared glob implementation for `rein remove --path`. Segment-level anchoring — `*.md` matches `foo.md` but not `foo/bar.md`; `**` crosses segments explicitly.
- **`.gitignore` entries** for `.claude/.rein-state/`, `.rein-prune-backup-*/`, `.rein-remove-backup-*/`, `.claude/cache/jobs/`.

### Changed

- **pre-edit-dod-gate**: now invokes validator v2 under `timeout 30` with §4.2 tier × exit-code outcome table (Tier 1 mismatch → `.dod-coverage-mismatch` + exit 2; Tier 2 → `.dod-coverage-advisory` + non-blocking). Previous 5-minute session cache (`.claude/cache/dod-gate-validator*`) removed — every invocation runs the validator fresh, closing the stale-pass drift class.
- **pre-bash-guard**: `BLOCK_MARKERS` array now consumes both `.coverage-mismatch` (legacy plan) and `.dod-coverage-mismatch` (new DoD). `.dod-coverage-advisory` is explicitly non-blocking.

### Breaking

- None. Validator v1 CLI shim preserved; Stage 1 default reproduces pre-v1.1.0 "advisory only" behavior. DoD `covers:` field still advisory — upgraded to required only when governance Stage ≥ 2.

## [v1.0.0] - 2026-04-21

### Breaking changes

- **Codex skill slash command 제거**: `/codex`, `/codex review`, `/codex ask` 명령 모두 제거. 새 명령 `/codex-review`, `/codex-ask` 로 교체. Deprecation wrapper 없음 (clean break).
- **Major bump**: v0.10.x → v1.0.0. semantic versioning 기준 breaking slash-command rename 으로 major 상향.

### Changed

- **문서 경로 정리**: `docs/superpowers/{specs,plans,brainstorms,reports}` → `docs/{specs,plans,brainstorms,reports}`. rein 이 superpowers 미의존을 선언한 이후 남은 drift 해소. main 제외 대상이므로 사용자 프로젝트 영향 없음.
- **plan-writer 자동 codex review**: plan 작성 완료 시 `/codex-review` 를 자동 호출 (`[NON_INTERACTIVE]` prompt marker 기반). PASS 시 spec-review stamp 자동 생성. NEEDS-FIX/REJECT 시 사용자 핸드오프 (self-fix loop 없음 — structured diff protocol 미완성으로 인한 의도적 제외).

### Added

- codex-review skill 에 non-interactive mode — `[NON_INTERACTIVE]` prompt marker 포함 시 AskUserQuestion skip + default (`gpt-5.4`/`high`/`read-only`) 사용. `[MODEL:...]`, `[EFFORT:...]`, `[SANDBOX:...]` marker 로 override.
- 신규 skills: `.claude/skills/codex-review/`, `.claude/skills/codex-ask/` (Mode A / Mode B 분리).

### Migration guide

**구 `/codex` 호출 → 새 `/codex-review`**:
- 기존: `/codex review` 또는 `/codex` 만
- 이후: `/codex-review`
- CLAUDE.md, AGENTS.md, 본인 프로젝트의 agent/skill 문서에서 같은 패턴 grep 후 치환:
  ```bash
  # Perl lookahead 로 이미 치환된 /codex-* 는 건너뛰고 bare /codex 도 처리한다:
  rg -l '/codex\b' .claude AGENTS.md README.md | \
    xargs perl -i -pe 's|/codex review|/codex-review|g; s|/codex ask|/codex-ask|g; s|/codex(?![\w-])|/codex-review|g'
  ```

**구 `/codex ask` 호출 → 새 `/codex-ask`**:
- 기존: `/codex ask`
- 이후: `/codex-ask`

**구 `docs/superpowers/` 참조**:
- main 제외 대상이라 사용자 프로젝트 영향 없음.
- rein-dev 메인테이너는 각 docs/ 갱신 + moved docs 내부 cross-ref 확인 필요 (v1.0.0 에서 자동 완료됨).

### Unsupported modifications

local hook 수정 (예: `pre-bash-guard` 의 fail-closed 를 `exit 0` 으로 변경) 은 언제든 기술적으로 가능하지만, 그 시점에 rein 의 gate 보장은 무효 (unsupported local fork). 이 경로는 rein 의 트래킹 대상이 아님.

## v0.10.1 (2026-04-20) — Windows Git Bash/MSYS `python3 exit 49` 구조적 해결

### Fixed

- **Windows Git Bash / MSYS `python3 exit 49` 차단 이슈 해결** (사용자 제보 2026-04-20). 근본원인: Windows shell 의 `9009` (command not found / App Execution Alias stub 실행 실패) 가 Git Bash/MSYS 에서 8비트로 잘려 `9009 mod 256 = 49` 로 노출. 훅이 이를 "JSON 파싱 실패" 로 뭉뚱그려 fail-closed 차단하던 경로를 구조적으로 개선. Codex gpt-5.4/high 독립 분석 + Microsoft/Python 공식 문서 교차 확인으로 확정.

### Added

- `.claude/hooks/lib/python-runner.sh` — Python interpreter resolver (bash array `PYTHON_RUNNER` 기반, 호출부는 `"${PYTHON_RUNNER[@]}"` 로 expand).
  - 우선순위: `$REIN_PYTHON` (validated 단일 경로, invalid override 는 hard-fail) → `$VIRTUAL_ENV` (POSIX `bin/python` / Windows `Scripts/python.exe`) → `python3` → `python` → MSYS/Cygwin 감지 시 `py -3`
  - WindowsApps App Execution Alias stub 경로 **case-insensitive** 감지 후 skip
  - 각 후보마다 `-c "import sys; sys.exit(0)"` health-check 실제 실행까지 성공한 경우에만 채택
  - Exit code 구분: `10` (missing — 모든 candidate 없음) / `11` (WindowsApps stub) / `12` (launch failure — 실행은 되지만 stub 아닌 다른 이유 / 또는 invalid `REIN_PYTHON` override)
  - `validate_runner_override()` 가 `REIN_PYTHON` 에 쉘 메타문자(`;&|<>$\``) 포함 시 reject → exit 12 (hard-fail, silent fallback 금지)
- `.claude/hooks/lib/extract-hook-json.py` — stdin JSON field 추출 CLI helper (argparse 기반, Python 3 stdlib only).
  - `--field <dotted.path>` (반복), `--array-of <array.path> --subfield <field>` (2단 API, **wildcard 미지원**), `--default`, `--strip-newlines`, `--separator`, `--stdin` / `--input-file`
  - bracket 표기 (`a[0].b`) 는 입력 시점에 `a.0.b` 로 정규화. 각 segment 가 정수 리터럴이면 list 인덱스, 아니면 dict key
  - Exit code: `0` (success) / `20` (invalid JSON) / `21` (missing field + no `--default`, 또는 wildcard reject) / `22` (decode/encoding failure). CRLF payload 는 정상 처리 대상이며 실패 사유 아님

### Changed

- 8개 훅 — `pre-edit-dod-gate.sh`, `pre-bash-guard.sh`, `post-write-dod-routing-check.sh`, `post-edit-hygiene.sh`, `post-edit-review-gate.sh`, `post-edit-index-sync-inbox.sh`, `post-edit-plan-coverage.sh`, `post-write-spec-review-gate.sh` — 의 inline `echo "$INPUT" | python3 -c ...` 패턴을 전부 `resolve_python` + `extract-hook-json.py` helper 호출로 교체. pre-hook 은 fail-closed 유지, post-hook 은 silent (예외: `post-write-dod-routing-check.sh` 는 `.routing-missing-unknown-python-runtime` marker 생성으로 보수적 parity).
- pre-hook (`pre-edit-dod-gate.sh`, `pre-bash-guard.sh`) 실패 시 `[DoD gate]` / `[Bash guard]` prefix 포함 Windows-specific 진단 메시지 출력 — 9009 계열 launch failure 일반 설명 + WindowsApps 대표 원인 + 4단 해결책 (WSL2 전환 / App execution aliases 끄기 / PATH 재정렬 / `REIN_PYTHON` 지정).
- `pre-edit-dod-gate.sh` 와 `pre-bash-guard.sh` 의 `log_block()` 함수가 raw `python3` 대신 `"${PYTHON_RUNNER[@]}"` 사용 → resolver 실패 경로에서도 stderr noise 없이 일관 동작.
- `pre-edit-dod-gate.sh` 의 pending incident count 검증 블록 (`rein-aggregate-incidents.py --count-pending`) 도 resolver 경유로 호출 (기존 fail-closed 경로 유지).

### Testing

- `tests/hooks/test-python-runner.sh` 신규 (12 tests) — fake python stub, fake uname, `REIN_PYTHON` injection reject, venv priority over `py -3`, WindowsApps case-mixed 감지, exit code 10/11/12 분기, bash array safety (공백 포함 경로), MSYS 에서 diagnostics 출력 / POSIX 에서 silent 검증.
- `tests/hooks/test-extract-hook-json.sh` 신규 (16 tests) — valid 단일/다중 field, invalid JSON, missing (with/without `--default`), CRLF 정상 처리, Unicode, Windows 경로 backslash, array index, `--array-of --subfield`, `--strip-newlines`, `--input-file`, bracket 정규화, type mismatch, non-UTF-8 decode error, wildcard reject.
- `tests/hooks/test-dod-gate.sh` + `tests/hooks/test-pre-bash-guard.sh` 에 Windows stub 시뮬레이션 시나리오 추가 — fake python3 = exit 49 + fake uname MSYS 조건에서 hook 이 exit 2 + stderr 진단 키워드(`9009`, `WSL2`, `App execution aliases`) 를 emit 하는지 assert.

### CI

- `.github/workflows/tests.yml` `tests-windows-advisory` job 확장 — `command -v py` probe 선행 + 부재 시 `actions/setup-python@v5` (3.12) 로 fallback + `runner.temp` 에 fake `python3` (exit 49) stub 주입 후 `tests/hooks/test-python-runner.sh` 실행으로 resolver fallback 검증. `continue-on-error: true` 유지 (advisory 경계).

### Unsupported modifications

local hook 수정 (예: `pre-bash-guard` 의 fail-closed 를 `exit 0` 으로 변경해 gate 를 우회) 은 언제든 기술적으로 가능하지만, 그 시점에 rein 의 gate 보장은 무효가 됩니다. 이 경로는 **unsupported local fork** 로 간주하며 rein 의 트래킹/지원 대상이 아닙니다.

## v0.10.0 (2026-04-20) — Follow-up issues 2/3/4/5: tests CI + brainstorming + codex modes + incident classifier

### Added

- **tests CI workflow** (`.github/workflows/tests.yml`): push + PR 트리거, ubuntu+macOS matrix primary, windows-latest advisory (`continue-on-error`). `bash tests/hooks/run-all.sh` + `bash tests/scripts/run-all.sh` 전체 green 을 자동 검증. `github.repository == 'JayJihyunKim/rein-dev'` 가드로 fork/template 방어, `mirror-to-public.yml` 가 main 배포 시 strip.
- **`tests/scripts/run-all.sh`**: scripts 테스트 모음 순차 runner. 개별 `bash <file>` 로 실행하여 실패 전염 방지. 리스트에 적힌 파일이 누락되면 CI 를 red 로 전환 (rename/typo 감지).
- **rein-native `brainstorming` skill** (`.claude/skills/brainstorming/`): brownfield 에서 feasibility·compatibility 를 선검증한 뒤 선택지를 수렴한다. 산출물 포맷 (Problem/Constraints/Options/Chosen/Rejected/Open Questions) 고정, 저장 위치 `docs/brainstorms/YYYY-MM-DD-<slug>.md`. greenfield 는 얇은 경로로 분기.
- **`/codex-ask` subcommand** (당시 `codex ask` 하위 커맨드, v1.0.0 에서 별도 스킬 `/codex-ask` 로 분리): Codex 를 Claude 세션 컨텍스트에 오염되지 않은 독립 관점 에이전트로 호출. stamp 생성 없음, `resume --last` 금지, 항상 새 `codex exec` 세션.
- **incident `agent_eligible` classification field**: `scripts/rein-mark-incident-processed.py` 에 `--set-agent-eligible {true|false|unknown}` + `--set-root-cause <label>` 옵션. `/incidents-to-agent` Step 1 이 `agent_eligible != false` 를 필터로 사용하여 hook-source bug 패턴을 자동 분리. 기존 incident 파일 (필드 없음) 은 `unknown` 해석으로 기존 동작 유지 (backfill 불요).
- **`tests/scripts/test-incident-agent-eligible.sh`**: 분류 필드 회귀 6 케이스 (backward compat, append, update, combined, invalid rejection, no-arg rejection).

### Changed

- **codex skill subcommand split**: `.claude/skills/codex/SKILL.md` 을 Mode A (리뷰 게이트, v1.0.0 에서 `/codex-review` 스킬로 분리) / Mode B (second opinion, v1.0.0 에서 `/codex-ask` 스킬로 분리) 로 재구성. 하위 커맨드 없이 단독 호출 시 backward compat 로 Mode A 해석. `AGENTS.md`, `.claude/CLAUDE.md`, `.claude/orchestrator.md` 의 codex 언급을 리뷰/질의 모드로 명시화.
- **Smart router registry (`.claude/router/registry.yaml`)**: `description_keywords` 에서 `"brainstorm"` 제거 → rein-native brainstorming 이 자동 추천 대상에 포함. `id_globs` 에 `superpowers:brainstorming` / `superpowers:writing-plans` 추가 → 외부 중복 스킬은 id prefix 로 차단되어 rein-native 우선. Claude 가 orchestrator.md:83 지시에 따라 이 두 키를 모두 라우팅 매칭에서 참조한다.
- **`writing-plans` skill**: design 문서에 `brainstorm ref:` 가 있으면 plan 상단 메타에도 옮겨 적어 brainstorm→design→plan 추적성 유지 (soft v1 권고).
- **`.claude/orchestrator.md`**: 라우팅 테이블에 brainstorming / `/codex-ask` 항목 추가, brainstorm→spec→plan 체인 섹션 신설.
- **`.claude/rules/branch-strategy.md`**: `.github/workflows/tests.yml` 을 main 제외 목록에 명시.
- **`.github/workflows/mirror-to-public.yml`**: `tests.yml` 도 strip 대상에 추가 (이중 방어).

### Notes

- v0.10.0 은 rein-native 프로세스의 공백을 메우는 릴리스다. design→plan coverage 강제 뒤에 brainstorm→spec 의 구조화 연결이 추가되었고, 코드 리뷰 전용이던 codex 스킬이 second-opinion 용도까지 확장되었다 (v1.0.0 에서 `/codex-review` + `/codex-ask` 로 clean-break 분리). 사용자 프로젝트에는 `tests.yml` 이 설치되지 않는다 (rein-dev 전용).

## v0.9.1 (2026-04-20) — Hotfix: `rein merge` hook exec bit propagation

### Fixed

- `scripts/rein.sh:copy_file()` 가 기존에 존재하는 dst 파일의 mode 를 갱신하지 못해, 과거 버전(hook 파일이 git tree 에 `100644` 로 커밋돼 있던 시절)에 `rein init` 된 프로젝트가 `rein merge` 후에도 훅 파일이 `-rw-rw-r--` 로 남던 문제. POSIX `cp` 는 dst 존재 시 기존 mode 를 보존하므로 — src 가 실행 가능하고 dst 에 exec bit 이 없을 때만 `chmod +x` 로 승격하도록 수정. 기존에 정상인 755 파일을 낮추지는 않음 (minimal risk).
- 증상: `/bin/sh: .claude/hooks/post-write-spec-review-gate.sh: Permission denied` 가 hook PostToolUse 에서 non-blocking 오류로 출력됨.

### Added

- `tests/cli/test-copy-file-mode.sh` — 4 개 회귀 테스트: src 실행 비트 전파 (신규/기존 dst), 비실행 src 보존, 기존 실행 bit 비삭제.

### Notes

- 기존 설치된 사용자 프로젝트의 이미 644 인 파일은 다음 `rein merge` 에서 자동 승격. 즉시 복구는 `chmod +x .claude/hooks/*.sh` 수동 실행.

## v0.9.0 (2026-04-20) — Cross-platform portability + Windows WSL2 guidance

### Fixed

- Linux 에서 `session-start-load-trail.sh:file_size()` 가 깨지는 버그. GNU `stat -f` 가 exit 0 인 filesystem-info 모드로 해석되어 `||` fallback 이 안 타던 문제를 `uname` 명시 분기 + 숫자 검증으로 해결.

### Added

- `.claude/hooks/lib/portable.sh` — BSD/GNU 분기 헬퍼 모음 (`portable_stat_size`, `portable_mtime_epoch`, `portable_mtime_date`, `portable_date_ymd_to_epoch`). 각 훅은 이 파일을 source 하여 중복 구현을 제거.
- `.gitattributes` — `*.sh`/`*.py`/`*.md` 등 텍스트 파일에 LF 강제. Windows checkout 시 CRLF 변환으로 shebang 훅이 깨지는 것을 예방.
- README / README.en / REIN_SETUP_GUIDE 에 지원 플랫폼 표 + Windows 사용자용 WSL2 설치 안내.

### Changed

- `.claude/hooks/pre-edit-dod-gate.sh`, `pre-bash-guard.sh`, `trail-rotate.sh`, `session-start-load-trail.sh`, `stop-session-gate.sh` 가 각자 보유한 `_mtime`/`_mtime_date`/`file_size` helper 제거하고 `lib/portable.sh` 를 source.
- `tests/hooks/test-stat-portability.sh` 를 `portable.sh` 함수 단위 unit test 로 재구성 (`portable_*` 4 개 함수 + 소스 규약 + parse check + 레거시 체인 grep guard, 총 14 테스트).
- `tests/hooks/lib/test-harness.sh:sandbox_setup()` 가 `.claude/hooks/lib/` 를 샌드박스로 먼저 복사.

### Supported platforms (declared)

- ✅ macOS, Linux, Windows via WSL2
- ⚠️ Git Bash / MSYS2 — best-effort, not part of the regular test matrix
- ❌ PowerShell / CMD native — hooks assume POSIX bash + GNU coreutils

## v0.8.0 (2026-04-XX) — Core Harness Purity

### Breaking changes

- **Stitch / shadcn 도메인 스킬 번들 해제**: `.claude/skills/` 에서 stitch-design, stitch-loop, taste-design, design-md, enhance-prompt, react-components, remotion, shadcn-ui 제거. rein 코어는 도메인·언어 무관.
- **StitchMCP 하드 의존 제거**: `.claude/settings.json` 의 `mcp__StitchMCP__*` 권한 + `mcpServers.StitchMCP` 블록 제거.
- **에이전트 정리**: `service-builder`, `reviewer` 제거. `plan-writer` 신규 추가. 최종 에이전트 5 개 = feature-builder, plan-writer, researcher, docs-writer, security-reviewer.
- **훅 이름·구조 변경**:
  - `inbox-compress.sh` → `trail-rotate.sh` (1-release wrapper alias 유지)
  - `post-edit-lint.sh` 이분할: `post-edit-hygiene.sh` (언어중립) + `post-edit-lint.sh.example` (언어별 autofix 템플릿)
  - `task-completed-incident.sh` 제거 — 기능은 `stop-session-gate.sh` 내부 helper 로 통합
- **AGENTS.md `/codex-review` fallback 체인**: `superpowers:code-reviewer` → rein 자체 `code-reviewer` 스킬 (외부 플러그인 미의존).

### Added

- `.claude/skills/writing-plans/` — rein 자체 plan 작성 스킬 (superpowers:writing-plans 대체).
- `.claude/skills/code-reviewer/` — rein 자체 코드 리뷰어 스킬 (`/codex-review` 장애 시 fallback).
- `.claude/agents/plan-writer.md` — design → plan 변환 전담.
- `scripts/rein-aggregate-incidents.py advisory-summary` — per-pattern/session 집계 CLI.
- `scripts/rein-route-record.py doctor` — legacy feedback-log / overrides 엔트리의 invalid_ids 자동 이관.
- `.session-start-line` stamp — stop-session-gate helper 가 세션 범위 advisory 를 계산하는 기준.

### Changed

- `.claude/router/registry.yaml` `excluded_patterns` 를 description 키워드 기반으로 재설계 (`superpowers:*` 하드코딩 제거).
- `scripts/rein-route-record.py` 가 agent/skill id 를 실제 저장소와 대조 검증. 무효 id 는 `invalid_ids` top-level 필드로 분리 (하위 호환).
- `stop-session-gate.sh` 에 `incident_advisory_check()` helper — 자기진화 파이프라인(2회→rule, 3회→agent) 권장 메시지를 stderr 로 출력.

### Migration

v0.8.0 으로 업그레이드 후 1회 실행:

```bash
python3 scripts/rein-route-record.py doctor
```

→ 기존 `feedback-log.yaml` / `overrides.yaml` 의 stale id 가 `invalid_ids` 로 이관됩니다.

자세한 사용자 영향: `REIN_SETUP_GUIDE.md` § Breaking changes (v0.8.0).

> **v1.1.2 (2026-04-24) 고지**: `doctor` 서브커맨드는 v1.1.2 에서 **제거**됐다. schema 안정화 후 실사용 기록이 없었고 `import yaml as pyyaml` 하드 임포트로 macOS CI 를 깨뜨린 문제 때문. v0.8.0 ~ v1.1.1 사이에 한 번이라도 `rein update` 한 프로젝트는 이미 migration 이 끝난 상태. v1.1.2 부터 업그레이드하는 새 프로젝트는 애초에 신규 스키마로 시작하므로 migration 불필요.
