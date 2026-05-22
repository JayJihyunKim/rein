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

# --- Policy toggle (plugin mode only) ---
# .rein/policy/hooks.yaml can disable this hook via `<hook-name>: false` or
# `{ <hook-name>: { enabled: false } }`. The loader also honours the legacy
# umbrella key `pre-bash-guard` (rein-policy-loader.py UMBRELLA_KEYS) so a
# project that disabled the old single hook keeps both halves disabled.
# Requires plugin mode (${CLAUDE_PLUGIN_ROOT} set). Skipped otherwise.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  if ! python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-bash-safety-guard"; then
    exit 0  # disabled by user policy
  fi
fi

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
if echo "$COMMAND" | grep -qE "git commit.*-[a-z]*a[a-z]*m"; then
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
