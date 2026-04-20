# Changelog

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
- **rein-native `brainstorming` skill** (`.claude/skills/brainstorming/`): brownfield 에서 feasibility·compatibility 를 선검증한 뒤 선택지를 수렴한다. 산출물 포맷 (Problem/Constraints/Options/Chosen/Rejected/Open Questions) 고정, 저장 위치 `docs/superpowers/brainstorms/YYYY-MM-DD-<slug>.md`. greenfield 는 얇은 경로로 분기.
- **`/codex ask` subcommand**: Codex 를 Claude 세션 컨텍스트에 오염되지 않은 독립 관점 에이전트로 호출. stamp 생성 없음, `resume --last` 금지, 항상 새 `codex exec` 세션.
- **incident `agent_eligible` classification field**: `scripts/rein-mark-incident-processed.py` 에 `--set-agent-eligible {true|false|unknown}` + `--set-root-cause <label>` 옵션. `/incidents-to-agent` Step 1 이 `agent_eligible != false` 를 필터로 사용하여 hook-source bug 패턴을 자동 분리. 기존 incident 파일 (필드 없음) 은 `unknown` 해석으로 기존 동작 유지 (backfill 불요).
- **`tests/scripts/test-incident-agent-eligible.sh`**: 분류 필드 회귀 6 케이스 (backward compat, append, update, combined, invalid rejection, no-arg rejection).

### Changed

- **`/codex` subcommand split**: `.claude/skills/codex/SKILL.md` 을 Mode A (`/codex review` — 기존 리뷰 게이트) / Mode B (`/codex ask` — second opinion) 로 재구성. 하위 커맨드 없이 `/codex` 만 호출하면 backward compat 로 Mode A 해석. `AGENTS.md`, `.claude/CLAUDE.md`, `.claude/orchestrator.md` 의 `/codex` 언급을 `/codex review` 로 명시화.
- **Smart router registry (`.claude/router/registry.yaml`)**: `description_keywords` 에서 `"brainstorm"` 제거 → rein-native brainstorming 이 자동 추천 대상에 포함. `id_globs` 에 `superpowers:brainstorming` / `superpowers:writing-plans` 추가 → 외부 중복 스킬은 id prefix 로 차단되어 rein-native 우선. Claude 가 orchestrator.md:83 지시에 따라 이 두 키를 모두 라우팅 매칭에서 참조한다.
- **`writing-plans` skill**: design 문서에 `brainstorm ref:` 가 있으면 plan 상단 메타에도 옮겨 적어 brainstorm→design→plan 추적성 유지 (soft v1 권고).
- **`.claude/orchestrator.md`**: 라우팅 테이블에 brainstorming / `/codex ask` 항목 추가, brainstorm→spec→plan 체인 섹션 신설.
- **`.claude/rules/branch-strategy.md`**: `.github/workflows/tests.yml` 을 main 제외 목록에 명시.
- **`.github/workflows/mirror-to-public.yml`**: `tests.yml` 도 strip 대상에 추가 (이중 방어).

### Notes

- v0.10.0 은 rein-native 프로세스의 공백을 메우는 릴리스다. design→plan coverage 강제 뒤에 brainstorm→spec 의 구조화 연결이 추가되었고, 코드 리뷰 전용이던 `/codex` 가 second-opinion 용도까지 확장되었다. 사용자 프로젝트에는 `tests.yml` 이 설치되지 않는다 (rein-dev 전용).

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
- **AGENTS.md `/codex` fallback 체인**: `superpowers:code-reviewer` → rein 자체 `code-reviewer` 스킬 (외부 플러그인 미의존).

### Added

- `.claude/skills/writing-plans/` — rein 자체 plan 작성 스킬 (superpowers:writing-plans 대체).
- `.claude/skills/code-reviewer/` — rein 자체 코드 리뷰어 스킬 (/codex 장애 시 fallback).
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
