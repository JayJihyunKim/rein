#!/bin/bash
# Hook: PreToolUse(Bash) — always-on safety guard.
#
# HK-2 (docs/specs/2026-05-19-cc-feature-adoption.md §HK-2): this script is the
# safety half of the former single Bash guard. It runs UNCONDITIONALLY on every
# Bash call and enforces the policy checks that must never be skipped:
#   [P1]  pipe-to-shell        — piping a script into bash/sh
#   [P8]  .env read            — cat/head/python ... .env
#   [P9]  .env stage           — git add that would stage a .env file
#   [P10] .env commit -am      — git commit -am with a .env present
#   [P11] destructive git      — git reset --hard / push --force / checkout --
#
# The test/commit-specific checks (P2-P7, I3-I5) moved to
# pre-bash-test-commit-gate.sh, which hooks.json gates with `if` so it only
# spawns on test/commit command patterns. Three infra-integrity points
# (I1·I2·I6) are common to both halves and live in lib/bash-guard-infra.sh.
#
# Exit code protocol (2-tier):
#   정책 차단 [P1]/[P8]/[P9]/[P10]/[P11]: exit 0 + JSON deny (deny_emit)
#   인프라 무결성 [I1]/[I2]/[I6]:         exit 2 + stderr   (fail-closed)
# 분류 근거: docs/specs/2026-05-17-hook-message-assistant-tone.md §1
# 주의: exit 1 은 non-blocking error (통과됨). 차단은 exit 0+JSON deny 또는 exit 2

# --- Policy toggle moved below the python resolver (GMF-4) ---
# The policy-toggle block used to live HERE (top of file) and hard-coded
# `python3`. When python3 was absent (127) or a Windows stub (49), the
# `if ! python3 <loader>; then exit 0` form treated interpreter-absence as a
# user policy disable and silently turned this always-on safety guard OFF
# (fail-open). GMF-4 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4) moves
# the policy check to AFTER bg_resolve_python_or_die (which already exit-2s on
# interpreter absence) and calls the loader via "${PYTHON_RUNNER[@]}", so a
# missing interpreter never disables the guard. See the policy block after [I1].

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Identity for blocks.jsonl + THRESHOLD counting. Must be set BEFORE sourcing
# bash-guard-infra.sh.
BG_GUARD_NAME="pre-bash-safety-guard"

# shellcheck source=./lib/bash-guard-infra.sh
# Shared infra (I1·I2·I6 + log_block + command_invokes). Sourced with the
# `if !` form so a parse error in the lib fail-closes (exit 2) — same fail-
# closed posture the [I6] emitter check uses.
if ! . "$SCRIPT_DIR/lib/bash-guard-infra.sh" 2>/dev/null; then
  echo "[rein] The Bash guard cannot run because its shared infrastructure (lib/bash-guard-infra.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# [I6] infra integrity — load + verify the JSON deny emitter (exit 2 on fail).
bg_infra_init "$SCRIPT_DIR"

INPUT=$(cat)

# [I1] infra integrity — resolve python3 (exit 2 on fail).
bg_resolve_python_or_die

# --- Policy toggle (plugin mode only) — GMF-4 resolver-after form ---
# .rein/policy/hooks.yaml can disable this hook via `<hook-name>: false` or
# `{ <hook-name>: { enabled: false } }`. The loader also honours the legacy
# umbrella key `pre-bash-guard` (rein-policy-loader.py UMBRELLA_KEYS) so a
# project that disabled the old single hook keeps both halves disabled.
# Requires plugin mode (${CLAUDE_PLUGIN_ROOT} set). Skipped otherwise.
#
# GMF-4 contract: bg_resolve_python_or_die above already exit-2s (fail-closed)
# when the interpreter is absent, so reaching here means PYTHON_RUNNER is a
# real interpreter. We call the loader through it and distinguish:
#   rc == 1        → loader ran cleanly + reported "disabled" → exit 0 (OFF)
#   rc == 0        → enabled → fall through to the guard body (active)
#   rc ∉ {0,1}     → loader crash / OS fault → fail-closed (guard active)
# Interpreter-absence can no longer reach this block, so it never disables
# the always-on safety guard.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-bash-safety-guard"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 1 ]; then
    exit 0  # loader ran cleanly + disabled by user policy
  fi
  # rc 0 = enabled (continue); rc ∉ {0,1} = loader call failure → fail-closed.
fi

# [I2] infra integrity — parse tool_input.command (exit 2 on parse failure).
# Called WITHOUT command substitution so its fail-close reaches the top level;
# bg_extract_command sets the global COMMAND on success.
COMMAND=""
bg_extract_command "$SCRIPT_DIR" "$INPUT" || exit 2

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- [P1] 즉시 차단: 파이프로 쉘 스크립트 실행 ---
# 정규식 의도:
#   - 파이프(`|`) **앞** 에 word-boundary (line 시작 또는 공백) → quote 안 substring
#     (`grep "x|bash y"`, `grep "x\\|bash y"`) false-positive 회피
#   - 파이프 뒤 bash/sh 토큰 + 공백 또는 라인 끝 → 'shadcn' 같이 sh-/bash- 로
#     시작하는 substring false-positive 회피 (기존 fix 유지)
# 차단 사유는 pipe 가 stdin 으로 임의 명령을 흘려넣어 hook 검증을 우회하는 경로이기 때문.
# 우회 (정상 패턴): file redirect 으로 명령 source 를 명시 — 'bash X.sh < /tmp/input.txt'.
if echo "$COMMAND" | grep -qE '(^|[[:space:]])\| *(bash|sh)( |$)'; then
  # [P1] policy block — JSON deny
  deny_emit "Piping a script into a shell was blocked because rein cannot verify where the piped command comes from. Use a file redirect instead: bash <script> < /tmp/<input>.txt" "PIPE_SHELL_BLOCKED" "$COMMAND"; rc=$?
  log_block "파이프 쉘 실행" "$COMMAND"
  exit "$rc"
fi

# --- [P8] .env 파일 읽기 차단 (cat, python 등으로 우회 방지) ---
# 분류기 clause-앵커링 + fail-closed (FU-4, codex R1): read verb 가 clause
# 시작에 있고 같은 clause 안에서 .env 계열 파일 (.env / .env.<무엇이든> /
# .envrc) 을 가리키면 차단한다. 단 키만 담은 안전한 템플릿
# (.env.example/.sample/.template/.dist — security rules §환경변수 관리) 만
# 참조하면 통과 — 안전 접미사 토큰을 명시 제거한 뒤에도 .env 계열이 남으면
# 시크릿 파일로 본다 (allow-by-omission 이 아니라 deny-by-default —
# .env.secret/.env.bak 같은 미등록 변형도 fail-closed 로 차단).
# strip 은 안전 접미사 **뒤에 token 경계** (`[^[:alnum:]._-]` 또는 행 끝) 를
# 요구한다 (codex R2): `.env.example.secret`·`.env.examples`·`.env.dist.bak`
# 처럼 안전 토큰을 prefix 로만 가진 더 긴 파일명은 제거되지 않아 차단된다.
if command_invokes "(cat|head|tail|less|more|python[23]?|node|grep|awk|sed|jq|cut)[[:space:]]+[^;&|]*(\.envrc|\.env([^[:alnum:]._-]|\$|\.))"; then
  ENV_RESIDUAL=$(printf '%s' "$COMMAND" | sed -E 's/\.env\.(example|sample|template|dist)([^[:alnum:]._-]|$)/\2/g')
  # B2 (v1.3.4): search-verb extension (grep/awk/sed/jq/cut added to the verb
  # list above). The residual check stays deny-by-default — ANY .env reference
  # that survives the safe-template strip blocks, INCLUDING quoted forms
  # (`cat ".env"`, `grep KEY ".env"`). Quoting must not be a bypass:
  # distinguishing a quoted search pattern (`grep ".env" README.md`, allowed in
  # spirit) from a quoted file argument (`grep KEY ".env"`, a real secret read)
  # needs positional shell parsing, which this regex classifier deliberately
  # does not do — so we fail closed. A quote-aware exemption was tried and
  # reverted: it opened a real secret-read bypass (codex review 2026-05-22).
  if printf '%s' "$ENV_RESIDUAL" | grep -qE '\.envrc|\.env([^[:alnum:]._-]|$|\.)'; then
    # [P8] policy block — JSON deny
    deny_emit "Reading a .env file with a shell command was blocked to prevent secrets from leaking into the session. Access environment variables through your application's config loader instead." "ENV_READ_BLOCKED" "$COMMAND"; rc=$?
    log_block ".env Bash 읽기 시도" "$COMMAND"
    exit "$rc"
  fi
fi

# --- [P9] .env 파일 커밋 방지 ---
if echo "$COMMAND" | grep -qE "git add"; then
  if echo "$COMMAND" | grep -qE "git add (-A|\.(\s|$|\|)|\.env)"; then
    if [ -f "$PROJECT_DIR/.env" ] || ls "$PROJECT_DIR"/.env.* 1>/dev/null 2>&1; then
      # [P9] policy block — JSON deny
      deny_emit "A .env file exists in the repo root and this git add command would stage it. Stage files individually by name to avoid committing secrets." "ENV_STAGE_BLOCKED" "$COMMAND"; rc=$?
      log_block ".env 스테이징 시도" "$COMMAND"
      exit "$rc"
    fi
  fi
fi

# --- [P10] git commit -am ---
# 위협 모델: P10 은 "실수로 `.env` 를 `git commit -am` (auto-add) 으로 커밋하는
# 것" 을 막는 mistake-prevention 가드다. 작정한 적대적 우회 (따옴표 중첩 전역옵션
# 값 등) 를 막는 장벽이 아니다 — 그건 명시적 비목표 (아래 "수용하는 한계").
#
# 정규식 의도 (SIMPLIFY, codex Round 2 권고 + 사용자 승인, 2026-05-29):
#   이전 R5/v6 의 git-argument-grammar (CHUNK matcher: double/single-quote span +
#   escape 모델링) 를 폐기하고 단순형으로 교체. 이전 모델은 mistake-prevention
#   위협 표면에 과했고, 그 복잡도에도 attached `-mfoo` 미포착 + quoted-message
#   오탐이 남았다.
#   command_invokes 로 실제 git invocation 만 매치 (clause 앵커링 — echo/grep 의
#   텍스트 언급 제외). PREFIX 가 git 과 commit 사이의 전역 옵션을 흡수한다:
#     PREFIX = git ( 옵션 )* [[:space:]]+ commit
#     옵션 = value-taking opt + bare value 토큰 (-C/-c/--git-dir/--work-tree)
#            | 그 외 dash-led 자기완결 flag (`-[^;&|[:space:]]*` — --no-pager,
#              --paginate, -p, --config-env=X 등 전부)
#   bare value 토큰을 소비하는 건 4개 known value-taking opt 뿐 → value-less
#   flag 뒤의 bare 단어 (예: `git --no-pager log` 의 log) 는 subcommand 로 남아
#   `git --no-pager log commit -am` 은 비차단. `--amend` 는 a/m bundle 도 아니고
#   message/all 쌍도 아니라 비차단.
#   3 arm (auto-add = `-a`/`--all` AND message):
#     arm1 = combined short bundle: `-am` / `-ma` (한 single-dash 번들 안 a+m).
#            alpha-run 종료 토큰 = 공백 / 끝 / 따옴표 시작 (`"` 또는 `'`) —
#            따옴표 종료 허용은 attached 메시지 (`-am"msg"` / `-ma'msg'`) 를
#            포착하기 위함 (BUG-P10-ATTACHED-QUOTE, 보안 리뷰 MEDIUM, 2026-05-29).
#            SIMPLIFY 직후 종료가 공백/끝뿐이라 `m` 다음 따옴표에서 매치가 끊겨
#            attached 메시지 번들이 미포착되던 회귀를 닫는다. (이전 단순 정규식
#            `git commit.*-[a-z]*a[a-z]*m` 은 이를 차단했었음.) `a` 없는 단독
#            attached 메시지 (`-m"msg"`) 는 arm1 의 a+m 동반 요구 때문에 비매치 →
#            정상 통과.
#     arm2 = all → message (attached `-mfoo`, `--message=foo` 포함)
#     arm3 = message → all (좌우 대칭)
#
# 수용하는 한계 (비목표 — 단순 버전은 의도적으로 처리하지 않는다):
#   1. False NEGATIVE — 적대적 따옴표 중첩 전역옵션 값: `git -c "u=J K" commit -am`
#      류. bare value matcher (`[^;&|[:space:]]+`) 가 공백에서 멈춰 따옴표 안
#      공백을 흡수하지 못하므로 trailing commit -am 을 차단하지 못한다.
#      mistake-prevention 범위 밖 (작정한 우회) — 막지 않는다.
#   2. False POSITIVE — quoted 메시지 안 standalone `-a` 토큰:
#      `git commit -m "use -a flag"` 류. command_invokes 는 따옴표를 인식하지
#      못하는 분류기라 arm3 (message → all) 가 `-m` 뒤 `[^;&|]*` 로 따옴표 안을
#      스캔하다 메시지 텍스트의 ` -a ` 를 ALL 토큰으로 오인해 차단한다. 이전
#      단순 정규식 (`git commit.*-[a-z]*a[a-z]*m`) 대비 신규 over-block 이지만,
#      mistake-prevention 가드의 보수적 방향 (의심스러우면 차단) 으로 수용한다.
#      사용자는 `git add` + 별도 `-m` 으로 우회 가능. 따옴표 인식 분류기 (별도
#      트랙) 가 도입되면 해소.
GIT_COMMIT_PREFIX='git([[:space:]]+(-C[[:space:]]+[^;&|[:space:]]+|-c[[:space:]]+[^;&|[:space:]]+|--git-dir(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|--work-tree(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|-[^;&|[:space:]]*))*[[:space:]]+commit'
GIT_AM_ALL='(-a|--all)'
GIT_AM_MSG='(-m([^;&|[:space:]]+)?|--message(=[^;&|[:space:]]+)?)'
if command_invokes "${GIT_COMMIT_PREFIX}[^;&|]*(^|[[:space:]])-[[:alpha:]]*(a[[:alpha:]]*m|m[[:alpha:]]*a)[[:alpha:]]*([[:space:]]|[\"']|\$)" \
   || command_invokes "${GIT_COMMIT_PREFIX}[^;&|]*(^|[[:space:]])${GIT_AM_ALL}[[:space:]][^;&|]*${GIT_AM_MSG}([[:space:]]|\$)" \
   || command_invokes "${GIT_COMMIT_PREFIX}[^;&|]*(^|[[:space:]])${GIT_AM_MSG}[[:space:]][^;&|]*${GIT_AM_ALL}([[:space:]]|\$)"; then
  if [ -f "$PROJECT_DIR/.env" ] || ls "$PROJECT_DIR"/.env.* 1>/dev/null 2>&1; then
    # [P10] policy block — JSON deny
    deny_emit "A .env file exists in the repo root and git commit -am would include it. Use git add <files> to stage only the files you intend to commit." "ENV_COMMIT_AM_BLOCKED" "$COMMAND"; rc=$?
    log_block ".env 포함 commit -am" "$COMMAND"
    exit "$rc"
  fi
fi

# --- [P11] 확인 요청: 파괴적 git 명령어 ---
# 분류기 clause-앵커링 (FU-4): 실제 git 명령 invocation 만 매치한다 — echo/grep
# 등에 텍스트로 들어간 "git reset --hard" 언급은 제외. push.*-f 의 `.*` 는
# clause 를 넘지 않도록 `[^;&|]*` 로 좁힌다 (다른 clause 의 `rm -rf` 오매치 방지).
if command_invokes "git (reset --hard|push --force|push[^;&|]*-f( |\$)|checkout -- |restore )"; then
  # [P11] policy block — JSON deny
  deny_emit "This git command permanently discards work and cannot be undone after it runs. Before proceeding, confirm with the user that the intention is clear: what will be lost and why that is acceptable. If the user confirms, re-issue the command." "DESTRUCTIVE_GIT_CONFIRM" "$COMMAND"; rc=$?
  log_block "파괴적 git 명령" "$COMMAND"
  exit "$rc"
fi

exit 0
