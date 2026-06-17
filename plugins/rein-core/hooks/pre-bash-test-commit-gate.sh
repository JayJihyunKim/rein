#!/bin/bash
# Hook: PreToolUse(Bash) — test/commit review gate (if-gated).
#
# HK-2 (docs/specs/2026-05-19-cc-feature-adoption.md §HK-2): this script is the
# test/commit half of the former single Bash guard. hooks.json registers it
# with `if` permission-rule filters so it only spawns on test-runner / commit
# command patterns — the always-on safety checks live in
# pre-bash-safety-guard.sh. On older Claude Code that ignores `if`, this hook
# runs unconditionally and degrades to the legacy always-spawn behavior (spec
# R6) — still correct, just less lean.
#
# Block points enforced here:
#   [P2]  coverage matrix mismatch  — plan/DoD `covers` list out of date
#   [P3]  review pending, no stamp  — code edited, codex review not run
#   [P4]  code edited after review  — stamp older than .review-pending
#   [P5]  codex review stamp missing
#   [P6]  security review stamp missing
#   [P7]  commit message format     — not Conventional Commits
# Infra integrity (paired with the policy points above):
#   [I3]  coverage marker target unidentifiable (pairs with P2)
#   [I4]  commit-msg helper absent  (pairs with P7)
#   [I5]  commit-msg helper exec failure (pairs with P7)
# Common infra (shared with pre-bash-safety-guard.sh via lib/bash-guard-infra.sh):
#   [I1]  python3 resolver failure
#   [I2]  hook input JSON parse failure
#   [I6]  JSON deny emitter unavailable/corrupt
#
# Exit code protocol (2-tier):
#   정책 차단 [P2]/[P3]/[P4]/[P5]/[P6]/[P7]: exit 0 + JSON deny (deny_emit)
#   인프라 무결성 [I1]~[I6]:                 exit 2 + stderr   (fail-closed)
# 분류 근거: docs/specs/2026-05-17-hook-message-assistant-tone.md §1
# 주의: exit 1 은 non-blocking error (통과됨). 차단은 exit 0+JSON deny 또는 exit 2

# --- Policy toggle moved below the python resolver (GMF-4) ---
# The policy-toggle block used to live HERE (top of file) and hard-coded
# `python3`. When python3 was absent (127) or a Windows stub (49), the
# `if ! python3 <loader>; then exit 0` form treated interpreter-absence as a
# user policy disable and silently turned the gate OFF (fail-open). GMF-4
# (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4) moves the policy check
# to AFTER bg_resolve_python_or_die (which already exit-2s on interpreter
# absence) and calls the loader via "${PYTHON_RUNNER[@]}", so a missing
# interpreter never disables the gate. See the policy block after [I1].

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Optional libs for consumer-side coverage marker self-heal (DoD:
# dod-2026-05-15-marker-self-heal). Source soft — if either is
# missing the revalidate helper falls back to "cannot revalidate" (rc=2),
# which preserves the legacy conservative block behavior.
. "$SCRIPT_DIR/lib/select-active-dod.sh" 2>/dev/null || true
. "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null || true

# Identity for blocks.jsonl + THRESHOLD counting. Must be set BEFORE sourcing
# bash-guard-infra.sh.
BG_GUARD_NAME="pre-bash-test-commit-gate"

# shellcheck source=./lib/bash-guard-infra.sh
# Shared infra (I1·I2·I6 + log_block + command_invokes). Sourced with the
# `if !` form so a parse error in the lib fail-closes (exit 2) — same fail-
# closed posture the [I6] emitter check uses.
if ! . "$SCRIPT_DIR/lib/bash-guard-infra.sh" 2>/dev/null; then
  echo "[rein] The Bash guard cannot run because its shared infrastructure (lib/bash-guard-infra.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# canonical git subcommand token model (SSOT) — GMF-1/GMF-2. Of the three
# model consumers (classifier / dispatcher / this gate) this gate is the only
# HARD-FAIL consumer: a missing/corrupt lib or empty $GIT_COMMIT_ERE/
# $GIT_MERGE_ERE is an integrity defect → exit 2 (fail-closed). Passing an
# empty ERE to command_invokes makes the matcher untrustworthy (per-environment
# error / match-all / misclassification) — an empty $GIT_MERGE_ERE could exempt
# EVERY command (fail-open) and an empty $GIT_COMMIT_ERE could drop the commit
# check. So we hard-fail before any empty ERE reaches the body below.
# (bash-guard-infra / safety-guard are NOT touched: safety-guard does not use
# these ERE constants — its P10 GIT_COMMIT_PREFIX is out of scope — so sourcing
# the model there would couple safety-guard to a lib it never reads.)
if ! { [ -f "$SCRIPT_DIR/lib/git-subcommand-model.sh" ] \
       && . "$SCRIPT_DIR/lib/git-subcommand-model.sh" \
       && [ -n "${GIT_COMMIT_ERE:-}" ] && [ -n "${GIT_MERGE_ERE:-}" ]; }; then
  echo "[rein] The commit gate cannot run because its git-subcommand token model (lib/git-subcommand-model.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# --- Review-stamp parser + ISO normalize helpers (M2/M3, spec 2026-06-16) ---
# These are pure, side-effect-free helpers consumed by check_review_stamp()'s
# P5 (M3 code-stamp dual-read) and P6 (M2 security-stamp freshness) areas. They
# are defined HERE — before the body's stdin read / resolver calls — so the
# REIN_GATE_SOURCE_ONLY guard below can expose them to unit tests without
# running the gate. The schema divergence is deliberate (spec §2.3): the code
# stamp uses `: ` separators, the security stamp uses `=` — so the separator is
# a parameter rather than a hard-coded assumption.

# _parse_stamp_field FILE KEY SEP
#   Extract the value of KEY<SEP>... from FILE's first matching line.
#   SEP is the literal separator after the key (": " for the code stamp,
#   "=" for the security stamp). Trailing whitespace is stripped. Prints the
#   value to stdout; prints nothing (empty = fail-closed sentinel) when the
#   file is absent, the key is absent, or the value is empty. Always rc 0 —
#   callers treat an empty result as the fail-closed condition (§6.3).
_parse_stamp_field() {
  local file="$1" key="$2" sep="$3"
  [ -f "$file" ] || return 0
  # Anchor the key at line start; match the literal separator; capture the rest.
  # `head -1` keeps only the first occurrence. sed strips the "key+sep" prefix
  # and any trailing whitespace. The separator may contain a space (": "), so we
  # match the key followed by optional spaces + the separator's non-space core.
  local line val
  line=$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*${sep%% *}" "$file" 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  # Remove everything up to and including the first separator occurrence.
  case "$sep" in
    ": ")
      val=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//")
      ;;
    "=")
      val=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//")
      ;;
    *)
      val=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*${sep}[[:space:]]*//")
      ;;
  esac
  # Strip trailing whitespace.
  val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+$//')
  printf '%s' "$val"
}

# _normalize_iso TS
#   Normalize an ISO-8601 UTC timestamp for lexicographic comparison: unify the
#   trailing `Z` (the security stamp may use a `Z`-less +%Y-%m-%dT%H:%M:%S
#   variant, spec §6.2) by stripping it, so `...T02:00:00Z` and `...T02:00:00`
#   compare equal. Validates the shape `YYYY-MM-DDTHH:MM:SS` (with optional
#   trailing Z); non-ISO input → no stdout + rc 1 (fail-closed sentinel) so a
#   garbage value can never produce a comparable string that passes freshness.
_normalize_iso() {
  local ts="$1"
  # Strip a single trailing Z if present.
  ts="${ts%Z}"
  # Must match YYYY-MM-DDTHH:MM:SS exactly (date + 'T' + time, second res).
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9])
      printf '%s' "$ts"
      return 0
      ;;
    *)
      # Fail-closed: non-ISO → no comparable value.
      return 1
      ;;
  esac
}

# REIN_GATE_SOURCE_ONLY — when set, expose the helper functions to a sourcing
# test harness WITHOUT running the gate body (no stdin read, no resolver, no
# deny). Unit tests for the pure helpers above (Task 1.1) use this; production
# never sets it. `return` is valid because the hook is being sourced.
if [ -n "${REIN_GATE_SOURCE_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
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
#   rc == 0        → enabled → fall through to the gate body (active)
#   rc ∉ {0,1}     → loader crash / OS fault → fail-closed (gate active)
# Interpreter-absence can no longer reach this block, so it never disables
# the gate.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-bash-test-commit-gate"
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

# --- merge/rebase/am commit 은 메시지 포맷 검증에서 면제 ---
# merge/rebase 는 메시지를 자동 생성하므로 Conventional Commits 검증 대상이
# 아니다. 면제는 stamp/coverage gate 보다 앞서야 한다 — 그 commit 들도 통과.
# GMF-2 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.2): 이전의 비앵커
# substring grep (`echo "$COMMAND" | grep -qE "git (merge|rebase|am)"`) 은
# 커밋 *메시지* 안에 든 리터럴 `git merge`/`git rebase`/`git am` substring 까지
# 매칭해, 그 *일반 커밋* 을 진짜 merge 로 오인하고 전 검사를 통째로 면제했다
# (false-negative). canonical $GIT_MERGE_ERE 를 command_invokes 로 소비하면
# clause-start 앵커가 첫 서브커맨드만 본다 — 글로벌 옵션 skip 후 첫 non-옵션
# 토큰이 merge/rebase/am 일 때만 면제. `-m "...git merge..."` 의 메시지 본문
# substring 은 비매칭(첫 서브커맨드는 commit). $GIT_MERGE_ERE 는 GMF-1 신설
# lib (git-subcommand-model.sh, 위에서 hard-fail source 됨) 의 SSOT 정의를
# 소비만 한다 — 여기서 재정의하지 않는다.
if command_invokes "$GIT_MERGE_ERE"; then
  exit 0
fi

# --- 보안-surface 면제 helper (spec 2026-06-16-commit-gate-security-surface-exempt) ---
# check_review_stamp() 의 P6/M2 진입 전 두 번째 면제 경로(§4). 단독 `git commit`
# (staging 동반 없음 + allowlist 옵션만) + staged diff 가 전부 허용목록
# (문서/trail/버전 문자열-only)일 때 P6+M2 를 둘 다 skip 한다. 그 외 전부
# fail-closed(현행 보안 요구 유지) — M2 구멍 재개방 금지. 위협모델은
# "정직한 에이전트 규율"(spec §7). 아래 helper 는 PROJECT_DIR / PYTHON_RUNNER /
# COMMAND (gate-body 글로벌) 를 호출 시점에 읽는다.

# _sx_tokenize CMD
#   따옴표 인식 토크나이저 (spec step 2; codex plan-review R1 Med — IFS
#   word-split 금지). 결과 토큰을 글로벌 배열 _SX_TOKENS 에 채운다.
#   상태 머신: 작은/큰 따옴표 안의 공백·separator 는 토큰 경계가 아니다 —
#   `-m "여러 단어 메시지"` 가 `-m` + `여러 단어 메시지`(한 토큰)로 보존돼야
#   정상 릴리스 커밋의 메시지 공백이 pathspec 으로 오인되지 않는다.
#   separator(`&&`/`||`/`;`/`|`)는 따옴표 밖에서만 별도 토큰으로 분리한다
#   (clause 분할은 _sx_command_form_ok 가 이 토큰열을 보고 수행).
_sx_tokenize() {
  local cmd="$1"
  _SX_TOKENS=()
  local n=${#cmd}
  local i=0 ch nxt
  local cur=""        # 현재 누적 중인 토큰
  local have=0        # 현재 토큰에 내용이 있는지 (빈 따옴표 "" 도 토큰)
  local state=plain   # plain | sq(작은따옴표) | dq(큰따옴표)
  while [ "$i" -lt "$n" ]; do
    ch="${cmd:i:1}"
    case "$state" in
      sq)
        if [ "$ch" = "'" ]; then
          state=plain
        else
          cur="$cur$ch"; have=1
        fi
        i=$((i + 1))
        continue
        ;;
      dq)
        if [ "$ch" = '"' ]; then
          state=plain
        else
          cur="$cur$ch"; have=1
        fi
        i=$((i + 1))
        continue
        ;;
    esac
    # state == plain
    case "$ch" in
      "'")
        state=sq; have=1; i=$((i + 1)); continue
        ;;
      '"')
        state=dq; have=1; i=$((i + 1)); continue
        ;;
      ' '|$'\t'|$'\n')
        if [ "$have" = 1 ]; then
          _SX_TOKENS+=("$cur"); cur=""; have=0
        fi
        i=$((i + 1)); continue
        ;;
      ';')
        if [ "$have" = 1 ]; then _SX_TOKENS+=("$cur"); cur=""; have=0; fi
        _SX_TOKENS+=(";"); i=$((i + 1)); continue
        ;;
      '&')
        if [ "$have" = 1 ]; then _SX_TOKENS+=("$cur"); cur=""; have=0; fi
        nxt="${cmd:i+1:1}"
        if [ "$nxt" = "&" ]; then
          _SX_TOKENS+=("&&"); i=$((i + 2))
        else
          _SX_TOKENS+=("&"); i=$((i + 1))
        fi
        continue
        ;;
      '|')
        if [ "$have" = 1 ]; then _SX_TOKENS+=("$cur"); cur=""; have=0; fi
        nxt="${cmd:i+1:1}"
        if [ "$nxt" = "|" ]; then
          _SX_TOKENS+=("||"); i=$((i + 2))
        else
          _SX_TOKENS+=("|"); i=$((i + 1))
        fi
        continue
        ;;
      *)
        cur="$cur$ch"; have=1; i=$((i + 1)); continue
        ;;
    esac
  done
  # 미닫힌 따옴표(state != plain) → 토큰화 신뢰 불가. 호출자는 _SX_FORM_OK
  # 를 false 로 강제한다(아래). 닫힌 경우 마지막 토큰 flush.
  if [ "$state" != "plain" ]; then
    _SX_TOKENIZE_OK=false
    return 0
  fi
  _SX_TOKENIZE_OK=true
  if [ "$have" = 1 ]; then
    _SX_TOKENS+=("$cur")
  fi
  return 0
}

# _sx_is_separator TOKEN  →  rc 0 if TOKEN is a clause separator.
_sx_is_separator() {
  case "$1" in
    "&&"|"||"|";"|"|"|"&") return 0 ;;
    *) return 1 ;;
  esac
}

# _sx_command_has_eval_or_subshell CMD
#   FAIL-OPEN HOLE FIX (codex integration review, 2026-06-16). The tokenizer
#   (_sx_tokenize) strips quotes and keeps `$(...)`/backtick inside a `-m`
#   message token, and glues `(git` into one token — so a TOCTOU command
#   substitution (`git commit -m "x $(git add src.py)"`) or a subshell group
#   (`(git add src.py); git commit`) slipped past _sx_command_form_ok and was
#   wrongly exempted: the embedded `git add` runs at REAL shell execution time
#   (before the gated `git commit`), staging source under a docs-only snapshot.
#
#   This guard scans the RAW command for any shell evaluation or grouping that
#   could run an arbitrary command (esp. an index-mutating `git add`) around the
#   commit. It is QUOTE-AWARE only where the shell itself is:
#     - single quotes ('...')  → fully inert; nothing inside fires.
#     - double quotes ("...")  → command substitution `$(`, backtick, and
#       parameter/command expansion `${` ARE STILL ACTIVE (the shell evaluates
#       them inside "..."), so they fail-closed even inside double quotes.
#       Grouping/subshell metachars ( ) { } and separators are inert in "...".
#     - unquoted                → `$(`, backtick, `${`, process substitution
#       `<(`/`>(`, and subshell/group `(` `)` `{` `}` all fail-closed.
#   rc 0  = an eval/subshell/process-substitution construct is present → caller
#           must NOT attempt exemption (fail-closed).
#   rc 1  = none found (plain command).
#   Principle: 모호하면 fail-closed. A plain version-bump / docs commit message
#   never contains these; an honest mis-classification only costs a normal
#   security review, never a bypass.
_sx_command_has_eval_or_subshell() {
  local cmd="$1"
  local n=${#cmd}
  local i=0 ch nxt
  local state=plain   # plain | sq | dq
  while [ "$i" -lt "$n" ]; do
    ch="${cmd:i:1}"
    case "$state" in
      sq)
        [ "$ch" = "'" ] && state=plain
        i=$((i + 1)); continue
        ;;
      dq)
        # Double quotes do NOT disable command substitution / expansion.
        case "$ch" in
          '"')
            state=plain; i=$((i + 1)); continue ;;
          '`')
            return 0 ;;                      # backtick command substitution
          '$')
            nxt="${cmd:i+1:1}"
            case "$nxt" in
              '('|'{') return 0 ;;           # $( ... )  or  ${ ... }
            esac
            i=$((i + 1)); continue ;;
          *)
            i=$((i + 1)); continue ;;
        esac
        ;;
    esac
    # state == plain (unquoted)
    case "$ch" in
      "'")
        state=sq; i=$((i + 1)); continue ;;
      '"')
        state=dq; i=$((i + 1)); continue ;;
      '`')
        return 0 ;;                          # backtick command substitution
      '$')
        nxt="${cmd:i+1:1}"
        case "$nxt" in
          '('|'{') return 0 ;;               # $( ... )  or  ${ ... }
        esac
        i=$((i + 1)); continue ;;
      '<'|'>')
        nxt="${cmd:i+1:1}"
        [ "$nxt" = "(" ] && return 0          # process substitution <( / >(
        i=$((i + 1)); continue ;;
      '('|')'|'{'|'}')
        # Unquoted subshell / brace group — can run extra commands.
        return 0 ;;
      *)
        i=$((i + 1)); continue ;;
    esac
  done
  return 1
}

# _sx_command_form_ok
#   spec §4.2 / step 2 — 단일-clause 종착 규칙 (codex integration review R2,
#   2026-06-16). 면제는 **명령 전체 = 비어있지 않은 단일 clause `git commit
#   <allowlist-opts>`** 일 때만. 다음 중 하나라도면 _SX_FORM_OK=false (fail-closed):
#   ① 쉘 평가/서브셸/process substitution: 호출 전 _sx_command_has_eval_or_subshell
#      가 이미 전체 명령을 검사한다(호출자 _sx_compute_security_surface_skip).
#   ② 비어있지 않은 clause 가 정확히 1개가 아님 — separator(&&/||/;/|/&)로
#      분할해 비어있지 않은 clause 를 **전부 센다**. 앞뒤에 cd/command/env/true/
#      echo/git add/또 다른 git 등 무엇이든 동반되면 clause 수가 2개 이상이 되어
#      거부된다. ⚠️ 이전 구현은 "git 아닌 clause 는 skip" 해서 `command git add
#      s.py; git commit` / `cd /o && git commit` / `env git add; git commit` /
#      `true; git commit` 가 면제를 통과했다 — clause 를 skip 하지 말고 전부 세어
#      1개 초과면 즉시 거부한다(R2 hole fix).
#   ③ 그 유일 clause 의 첫 토큰이 정확히 `git` 아님 — wrapper(command/env/time/…)
#      또는 env 할당(VAR=val/GIT_*=) prefix 가 앞에 있으면 첫 토큰이 git 아님
#      → fail-closed.
#   ④ `git` 직후 토큰이 정확히 `commit` 아님 — 사이에 글로벌옵션(-C/-c/--git-dir/
#      --work-tree 등 repo/index redirect)이 끼면 fail-closed.
#   ⑤ 그 유일 commit clause 의 옵션이 전부 allowlist (미상 옵션·pathspec → fail).
#   판정 결과를 글로벌 _SX_FORM_OK 에 true/false 로 둔다.
_sx_command_form_ok() {
  _SX_FORM_OK=false
  # 토큰화 실패(미닫힌 따옴표) → fail-closed.
  [ "${_SX_TOKENIZE_OK:-false}" = true ] || return 0

  local total=${#_SX_TOKENS[@]}
  [ "$total" -gt 0 ] || return 0

  # 백그라운드 제어(`&`)는 면제 즉시 실격 (codex integration review R3 High).
  # `git commit -m x &` 는 후행 `&` 가 separator 라 "비어있지 않은 clause 1개 +
  # 빈 후행 clause" 로 줄어 면제를 통과하던 fail-open 이 있었다. 백그라운드 실행은
  # 평범한 전경(in-place terminal) `git commit` 이 아니라 실행 타이밍 모호성을
  # 만들므로 fail-closed. (토크나이저가 `&&` 는 단일 토큰으로 내므로 이 검사는
  # 논리 AND `&&` 가 아닌 백그라운드 단일 `&` 만 잡는다.)
  local t
  for t in "${_SX_TOKENS[@]}"; do
    [ "$t" = "&" ] && return 0       # _SX_FORM_OK 는 false 유지 (fail-closed)
  done

  # 토큰열을 separator 로 분할해 각 clause 의 [cs, ce) 를 순회한다. clause 를
  # skip 하지 않고 비어있지 않은 clause 를 전부 센다(단일-clause 종착 규칙). 유일
  # clause 가 `git commit <allowlist>` 형태인지는 form_clause_ok 에 담는다 —
  # 비어있지 않은 clause 가 정확히 1개일 때만 그 값이 최종 판정에 쓰인다.
  local i=0
  local nonempty_clause_count=0
  local form_clause_ok=false
  while [ "$i" -lt "$total" ]; do
    # clause 시작 = i. clause 끝 = 다음 separator 직전 또는 total.
    local cs=$i
    local ce=$i
    while [ "$ce" -lt "$total" ] && ! _sx_is_separator "${_SX_TOKENS[$ce]}"; do
      ce=$((ce + 1))
    done
    # clause 토큰 범위 [cs, ce). ce 는 separator 또는 total.
    if [ "$cs" -lt "$ce" ]; then
      # --- 비어있지 않은 clause ---
      nonempty_clause_count=$((nonempty_clause_count + 1))
      # 이 clause 가 plain `git commit <allowlist>` 형태인지 판정. count==1 일
      # 때만 form_clause_ok 가 최종 판정에 반영되므로, 여기서 매번 재산정한다.
      form_clause_ok=false
      if [ "${_SX_TOKENS[$cs]}" = "git" ]; then
        # git 직후(글로벌옵션 skip 없이) 바로 commit 인 경우만 면제 형태.
        local k=$((cs + 1))
        if [ "$k" -lt "$ce" ] && [ "${_SX_TOKENS[$k]}" = "commit" ]; then
          # commit 뒤 옵션 allowlist 검사 (commit 토큰 다음부터 clause 끝까지).
          if _sx_commit_opts_ok "$((k + 1))" "$ce"; then
            form_clause_ok=true
          fi
        fi
      fi
    fi
    # 다음 clause 로. ce 가 separator 면 한 칸 더 건너뛴다.
    if [ "$ce" -lt "$total" ]; then
      i=$((ce + 1))
    else
      i=$ce
    fi
  done

  # 면제 시도 조건: 비어있지 않은 clause 정확히 1개 AND 그 clause 가
  # `git commit <allowlist>` 형태.
  if [ "$nonempty_clause_count" -eq 1 ] && [ "$form_clause_ok" = true ]; then
    _SX_FORM_OK=true
  fi
  return 0
}

# _sx_commit_opts_ok START END
#   commit 토큰 다음(START)부터 clause 끝(END, exclusive)까지 옵션을 allowlist
#   스캔. allowlist = -m/--message(다음 1토큰 메시지 소비)/--message=<v>/-s/
#   --signoff/-q/--quiet/-v/--verbose/attached -S<keyid>/--gpg-sign=<v>/
#   무인자 -S·--gpg-sign. -S·--gpg-sign 뒤 분리 토큰은 keyid 로 소비하지 않고
#   일반 토큰으로 재검사(pathspec/미상 옵션이면 fail). 그 외 토큰 → rc 1.
_sx_commit_opts_ok() {
  local p="$1" end="$2"
  while [ "$p" -lt "$end" ]; do
    local tok="${_SX_TOKENS[$p]}"
    case "$tok" in
      -m|--message)
        # 다음 1토큰을 메시지로 소비 (따옴표 파서 덕에 공백 메시지가 1토큰).
        # 인자 부재(다음이 clause 끝)면 git 자체가 거부하지만, 면제 관점에선
        # 소비할 토큰이 없으니 그대로 진행(추가 토큰 없음).
        p=$((p + 2)); continue ;;
      --message=*)
        p=$((p + 1)); continue ;;
      -s|--signoff|-q|--quiet|-v|--verbose)
        p=$((p + 1)); continue ;;
      --gpg-sign=*)
        p=$((p + 1)); continue ;;
      -S|--gpg-sign)
        # 무인자 서명. 다음 분리 토큰은 keyid 로 소비하지 않는다 — 일반 토큰으로
        # 재검사되도록 1칸만 전진.
        p=$((p + 1)); continue ;;
      -S?*)
        # attached -S<keyid>.
        p=$((p + 1)); continue ;;
      *)
        # 미상 옵션·pathspec·-a/--all/-am/--amend/--only/--include/-p/--patch/
        # -i/-C/-c/-F 등 전부 → fail-closed.
        return 1 ;;
    esac
  done
  return 0
}

# _sx_acquire_staged_paths
#   spec §4.1 / step 4. `git -C "$PROJECT_DIR" diff --cached --name-status -M`
#   출력을 파싱해 글로벌 배열 _SX_PATHS 에 변경 경로를 채운다. rename(R)/copy(C)
#   는 신·구 경로 둘 다 추가. 비0 종료 / 빈 출력(staged 없음) / status 라인
#   파싱 실패 → _SX_DIFF_OK=false (fail-closed). 성공 시 _SX_DIFF_OK=true.
_sx_acquire_staged_paths() {
  _SX_PATHS=()
  _SX_DIFF_OK=false
  local out rc
  out=$(git -C "$PROJECT_DIR" diff --cached --name-status -M 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 0           # 비0 종료 (git 부재 / 비-repo) → fail-closed
  [ -n "$out" ] || return 0             # 빈 출력 (staged 없음) → fail-closed

  local line status f1 f2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # 첫 필드 = status (탭 구분). status 와 경로 사이는 탭.
    status="${line%%$'\t'*}"
    case "$status" in
      R*|C*)
        # R<score>\t<old>\t<new> — 신·구 둘 다.
        local rest="${line#*$'\t'}"      # old\tnew
        f1="${rest%%$'\t'*}"
        f2="${rest#*$'\t'}"
        # f2 가 f1 과 같으면(탭 1개뿐) 경로 1개만 = 파싱 실패 → fail-closed.
        if [ "$f2" = "$rest" ] || [ -z "$f1" ] || [ -z "$f2" ]; then
          _SX_PATHS=(); return 0
        fi
        _SX_PATHS+=("$f1" "$f2")
        ;;
      A|M|D|T)
        # <status>\t<path> — 단일 경로.
        f1="${line#*$'\t'}"
        if [ "$f1" = "$line" ] || [ -z "$f1" ]; then
          _SX_PATHS=(); return 0          # 탭 없음 → 파싱 실패 → fail-closed
        fi
        _SX_PATHS+=("$f1")
        ;;
      *)
        # 예상 외 status (모호) → fail-closed.
        _SX_PATHS=(); return 0
        ;;
    esac
  done <<< "$out"

  # 한 경로도 못 모았으면 fail-closed.
  [ "${#_SX_PATHS[@]}" -gt 0 ] || return 0
  _SX_DIFF_OK=true
  return 0
}

# _sx_path_is_doc_or_trail PATH  →  rc 0 if PATH is docs(ⓐ) or trail(ⓑ).
#   ⓐ 문서: *.md (저장소 어디든) 또는 docs/** (docs/ prefix).
#   ⓑ trail: trail/** (trail/ prefix — 리뷰표식 .codex-reviewed 등 포함).
_sx_path_is_doc_or_trail() {
  case "$1" in
    *.md) return 0 ;;
    docs/*) return 0 ;;
    trail/*) return 0 ;;
  esac
  return 1
}

# _sx_version_only_rein_sh
#   spec §4.3 ⓒ / step 8. scripts/rein.sh 의 staged diff 추가/삭제 라인이 전부
#   VERSION="..." 라인 정규식이면 rc 0, 아니면 rc 1. 추가/삭제 라인 0개(빈 diff)
#   → rc 1 (fail-closed). git diff 비0 종료 → rc 1.
_sx_version_only_rein_sh() {
  local diff rc
  diff=$(git -C "$PROJECT_DIR" diff --cached -- scripts/rein.sh 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$diff" ] || return 1
  local line body changed=0
  while IFS= read -r line; do
    case "$line" in
      '+++ '*|'--- '*) continue ;;        # 파일 헤더 제외
      '+'*|'-'*) ;;                        # 변경 라인
      *) continue ;;                       # context / @@ hunk / 기타
    esac
    changed=$((changed + 1))
    body="${line:1}"                        # +/- prefix 제거
    # ^[[:space:]]*VERSION="[^"]*"[[:space:]]*$ 패턴인지 검사.
    if ! printf '%s' "$body" | grep -qE '^[[:space:]]*VERSION="[^"]*"[[:space:]]*$'; then
      return 1
    fi
  done <<< "$diff"
  [ "$changed" -gt 0 ] || return 1          # 변경 라인 0개 → fail-closed
  return 0
}

# _sx_version_only_plugin_json
#   spec §4.3 ⓒ / step 8. plugin.json 의 staged 와 HEAD 를 각각 json.load 로
#   파싱해 dict 비교 — 오직 top-level "version" 키 값에서만 다르고 그 외 모든
#   키·값(중첩 포함) 동일할 때만 rc 0. git show 비0 / json 파싱 실패 / 다른 키
#   차이 → rc 1 (fail-closed). key 순서·whitespace 차이는 dict 비교가 의미-동일로
#   본다(허용).
_sx_version_only_plugin_json() {
  local pj="plugins/rein-core/.claude-plugin/plugin.json"
  local staged head src rc
  staged=$(git -C "$PROJECT_DIR" show ":$pj" 2>/dev/null) || return 1
  head=$(git -C "$PROJECT_DIR" show "HEAD:$pj" 2>/dev/null) || return 1
  [ -n "$staged" ] && [ -n "$head" ] || return 1
  # python: 두 JSON 을 dict 로 파싱 → top-level version 키만 차이일 때 exit 0.
  # staged/head 는 argv 로 전달한다 (NUL 구분 stdin 은 일부 printf 가 \0 을
  # 흘려 1-part 로 깨지므로 금지 — 인자는 임의 텍스트를 손실 없이 보존).
  "${PYTHON_RUNNER[@]}" - "$staged" "$head" <<'PY'
import json, sys
try:
    staged = json.loads(sys.argv[1])
    head = json.loads(sys.argv[2])
except Exception:
    sys.exit(1)
if not isinstance(staged, dict) or not isinstance(head, dict):
    sys.exit(1)
# top-level 키 집합 동일해야 함 (키 추가/삭제 → deny).
if set(staged.keys()) != set(head.keys()):
    sys.exit(1)
# 'version' 외 모든 키 값은 의미적으로 동일해야 함 (중첩 dict/list 포함).
for k in head.keys():
    if k == 'version':
        continue
    if staged.get(k) != head.get(k):
        sys.exit(1)
# version 키는 존재해야 하고(둘 다), 값이 달라도 허용(범프). 같아도 허용.
if 'version' not in staged or 'version' not in head:
    sys.exit(1)
sys.exit(0)
PY
  rc=$?
  return "$rc"
}

# _sx_classify_paths
#   spec §4.3 / step 6+8. _SX_PATHS 의 모든 경로를 분류한다. 하나라도 비허용이면
#   즉시 _SX_ALLOW=false. 전부 허용이면 _SX_ALLOW=true + 분류 카운트
#   (_SX_DOCS/_SX_TRAIL/_SX_VERSION) 를 채운다(audit 용). version 파일 2개는
#   content-level 검사를 호출 시점에 1회씩만 캐시한다.
_sx_classify_paths() {
  _SX_ALLOW=false
  _SX_DOCS=0; _SX_TRAIL=0; _SX_VERSION=0
  local rein_sh_checked="" rein_sh_ok="" plugin_json_checked="" plugin_json_ok=""
  local p
  for p in "${_SX_PATHS[@]}"; do
    case "$p" in
      *.md)
        _SX_DOCS=$((_SX_DOCS + 1)); continue ;;
      docs/*)
        _SX_DOCS=$((_SX_DOCS + 1)); continue ;;
      trail/*)
        _SX_TRAIL=$((_SX_TRAIL + 1)); continue ;;
    esac
    # 문서/trail 아님 → 버전 파일 2개만 ⓒ 대상.
    case "$p" in
      scripts/rein.sh)
        if [ -z "$rein_sh_checked" ]; then
          rein_sh_checked=1
          if _sx_version_only_rein_sh; then rein_sh_ok=1; else rein_sh_ok=0; fi
        fi
        if [ "$rein_sh_ok" = 1 ]; then
          _SX_VERSION=$((_SX_VERSION + 1)); continue
        fi
        return 0                                   # 비허용 → _SX_ALLOW=false
        ;;
      plugins/rein-core/.claude-plugin/plugin.json)
        if [ -z "$plugin_json_checked" ]; then
          plugin_json_checked=1
          if _sx_version_only_plugin_json; then plugin_json_ok=1; else plugin_json_ok=0; fi
        fi
        if [ "$plugin_json_ok" = 1 ]; then
          _SX_VERSION=$((_SX_VERSION + 1)); continue
        fi
        return 0                                   # 비허용 → _SX_ALLOW=false
        ;;
      *)
        return 0                                   # 그 외 .sh/.json/.yaml/소스 → 비허용
        ;;
    esac
  done
  _SX_ALLOW=true
  return 0
}

# _sx_audit_exempt
#   spec §4.6 / step 14. 보안-surface 면제가 실제 결정한 경우에만 호출된다
#   (light-tier 가 아닌 경로). trail/incidents/security-surface-exempt.log 에
#   append-only 1줄. 디렉토리 부재/쓰기 실패는 2>/dev/null || true 로 비차단.
#   커밋 메시지 전문은 기록하지 않는다.
_sx_audit_exempt() {
  local logf="$PROJECT_DIR/trail/incidents/security-surface-exempt.log"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  {
    printf '%s\treason=security-surface-exempt\tstaged_files=%s\tdocs=%s trail=%s version=%s\n' \
      "$ts" "${#_SX_PATHS[@]}" "$_SX_DOCS" "$_SX_TRAIL" "$_SX_VERSION" \
      >> "$logf"
  } 2>/dev/null || true
  return 0
}

# _sx_compute_security_surface_skip
#   면제 종합 판정 (§4.4). 명령형태 OK + staged diff 취득 OK + 전 파일 허용일 때
#   _security_surface_skip=true. 어느 단계든 실패 시 false (fail-closed). gate
#   본문이 이 함수를 light-tier 계산 직후 호출한다.
_sx_compute_security_surface_skip() {
  _security_surface_skip=false
  # HOLE FIX (codex integration review, 2026-06-16) — entry guard. Before any
  # tokenized form analysis, reject the whole command if it contains shell
  # evaluation / subshell / process substitution (`$(`/backtick/`${`/`<(`/`>(`/
  # `(`/`)`/`{`/`}`). Those can run an index-mutating `git add` (TOCTOU) around
  # the gated commit, which the quote-stripping tokenizer cannot see. Fail-closed.
  if _sx_command_has_eval_or_subshell "$COMMAND"; then
    return 0
  fi
  _sx_tokenize "$COMMAND"
  _sx_command_form_ok
  [ "$_SX_FORM_OK" = true ] || return 0
  _sx_acquire_staged_paths
  [ "$_SX_DIFF_OK" = true ] || return 0
  _sx_classify_paths
  [ "$_SX_ALLOW" = true ] || return 0
  _security_surface_skip=true
  return 0
}

# --- Codex 리뷰 + 보안 리뷰 stamp 공통 검사 함수 ([P3]~[P6]) ---
check_review_stamp() {
  local context="$1"  # "test" 또는 "commit"
  REVIEW_STAMP="$PROJECT_DIR/trail/dod/.codex-reviewed"
  SECURITY_STAMP="$PROJECT_DIR/trail/dod/.security-reviewed"
  DOD_DIR="$PROJECT_DIR/trail/dod"

  # DoD 파일이 없으면 (작업 중이 아니면) 검사 스킵
  DOD_EXISTS=false
  if [ -d "$DOD_DIR" ]; then
    for f in "$DOD_DIR"/dod-*.md; do
      [ -f "$f" ] || continue
      DOD_EXISTS=true
      break
    done
  fi
  [ "$DOD_EXISTS" = false ] && return 0

  # --- .review-pending 검증 (코드 편집 후 리뷰 필수) ---
  REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"
  if [ -f "$REVIEW_PENDING" ]; then
    if [ ! -f "$REVIEW_STAMP" ]; then
      # [P3] policy block — JSON deny. HIGH-2: exit directly (not return) so caller
      # cannot mistake "deny emitted (0)" for "stamp pass (0)".
      deny_emit "Source code was edited but the codex review has not been run yet. Run /codex-review to record the review before committing." "REVIEW_PENDING_NO_STAMP" "$COMMAND"; rc=$?
      log_block "코드 편집 후 리뷰 미실행 (${context})" "$COMMAND"
      exit "$rc"
    fi

    # .codex-reviewed가 .review-pending보다 최신인지 검증
    PENDING_TIME=$(portable_mtime_epoch "$REVIEW_PENDING")
    REVIEW_TIME=$(portable_mtime_epoch "$REVIEW_STAMP")
    if [ "$REVIEW_TIME" -lt "$PENDING_TIME" ]; then
      # [P4] policy block — JSON deny. HIGH-2: exit directly.
      deny_emit "Code was edited after the last codex review. Re-run /codex-review to record a fresh review before committing." "CODE_EDITED_AFTER_REVIEW" "$COMMAND"; rc=$?
      log_block "리뷰 후 코드 재수정 (${context})" "$COMMAND"
      exit "$rc"
    fi
  fi

  # --- Codex 리뷰 stamp 검사 ---
  # 시간 기반 TTL 은 제거 — .review-pending 비교가 "코드 변경 후 재리뷰" 를 정확히 담당한다
  if [ ! -f "$REVIEW_STAMP" ]; then
    # [P5] policy block — JSON deny. HIGH-2: exit directly.
    deny_emit "The codex review has not been recorded yet. Run /codex-review before ${context} — this creates the review record that rein requires before commits." "CODEX_STAMP_MISSING" "$COMMAND"; rc=$?
    log_block "Codex 리뷰 미실행 (${context})" "$COMMAND"
    exit "$rc"
  fi

  # --- M3: 코드 표식 통과 판정 dual-read (spec 2026-06-16 §4.2) ---
  # 존재 검사(P5)만으로는 NEEDS-FIX / escalated_to_human / 손삽입 표식이 통과한다.
  # 통과 판정을 dual-read 로 검증한다:
  #   verdict: 라인이 있으면 그 값으로 판정 (PASS 만 통과).
  #   verdict: 부재 시 legacy resolution: 으로 판정 (passed 만 통과).
  #   둘 다 부재 / 파싱 불가 → fail-closed(차단).
  # 시각도 reviewed_at:(신) 또는 legacy timestamp:(구) 중 하나 파싱 가능해야 한다.
  # 둘 다 파싱 불가 → fail-closed(차단). 기존 escalated 경고(차단 안 함)는 dual-read
  # 의 fail-closed 와 모순이므로 차단으로 격상된다 (escalated_to_human 는 verdict 없고
  # resolution≠passed → 자동 차단). 기존 .review-pending 신선도 비교는 위에서 유지된다.
  _codex_verdict=$(_parse_stamp_field "$REVIEW_STAMP" "verdict" ": ")
  _codex_resolution=$(_parse_stamp_field "$REVIEW_STAMP" "resolution" ": ")
  _code_pass=false
  if [ -n "$_codex_verdict" ]; then
    # verdict: present — sole authority. PASS only.
    [ "$_codex_verdict" = "PASS" ] && _code_pass=true
  elif [ -n "$_codex_resolution" ]; then
    # legacy resolution: fallback (verdict absent). passed only.
    [ "$_codex_resolution" = "passed" ] && _code_pass=true
  fi
  # 시각 파싱 가능성: reviewed_at:(신) 또는 legacy timestamp:(구) 중 하나라도
  # ISO 정규화 통과해야 한다. 둘 다 파싱 불가 → fail-closed.
  _codex_reviewed_raw=$(_parse_stamp_field "$REVIEW_STAMP" "reviewed_at" ": ")
  _codex_ts_legacy=$(_parse_stamp_field "$REVIEW_STAMP" "timestamp" ": ")
  _codex_reviewed_norm=""
  if [ -n "$_codex_reviewed_raw" ]; then
    _codex_reviewed_norm=$(_normalize_iso "$_codex_reviewed_raw") || _codex_reviewed_norm=""
  fi
  if [ -z "$_codex_reviewed_norm" ] && [ -n "$_codex_ts_legacy" ]; then
    _codex_reviewed_norm=$(_normalize_iso "$_codex_ts_legacy") || _codex_reviewed_norm=""
  fi
  if [ "$_code_pass" != true ] || [ -z "$_codex_reviewed_norm" ]; then
    # [P5b] policy block — JSON deny. 통과 판정 실패(NEEDS-FIX / escalated /
    # 판정필드 부재) 또는 시각 파싱 불가 → fail-closed.
    deny_emit "The recorded codex review is not a PASS (verdict not PASS / escalated / unreadable). Re-run /codex-review and record a PASS before ${context}." "CODE_REVIEW_NOT_PASSED" "$COMMAND"; rc=$?
    log_block "코드 리뷰 통과 판정 실패 (${context})" "$COMMAND"
    exit "$rc"
  fi

  # --- 보안 리뷰 stamp 검사 ([P6] — RT-1 + M2, spec 2026-06-16 §4.1/§4.4) ---
  # 면제 우선 분기 (§4.4): light-tier+approved (Tier 1 active-dod) 면제가 성립하면
  # M2 신선도/verdict 비교 자체를 skip 하고 P6 부재 차단도 skip 한다. 면제는
  # "이 작업은 보안 표식이 없어도 정상" 을 의미하므로 신선도 비교 대상이 없다.
  #
  # 면제 미성립 시:
  #   보안 표식 부재 → 기존 P6 차단 (SECURITY_STAMP_MISSING).
  #   보안 표식 존재 → M2 비교 (신선도 + cycle 일치 + verdict=PASS).
  #
  # Skip ONLY when the active DoD's ## 라우팅 추천 YAML has BOTH:
  #   security_tier: light   AND   approved_by_user: true
  # Fail-closed: absent DoD, unparseable YAML, Tier 0/2, any other value → require stamp.
  # .codex-reviewed (P5) is NEVER skipped regardless of security_tier.
  #
  # DoD selection uses the canonical select_active_dod resolver (already sourced
  # at the top of this hook via lib/select-active-dod.sh). This prevents the
  # stale-DoD bypass: a glob last-match over dod-*.md could pick an alphabetically-
  # later stale DoD with security_tier:light even when .active-dod marker points at
  # a standard-tier DoD. select_active_dod honours Tier 1 (explicit marker) first,
  # then Tier 2 (mtime-latest with ## 범위 연결). Tier 0/2 → fail-closed (require stamp).
  #
  # NOTE (Task 1.3): the exemption is computed UNCONDITIONALLY (not only when the
  # stamp is absent) so a present-but-stale stamp under a light+approved DoD is
  # also exempted from M2 — the exemption is about the work, not the stamp.
  _security_tier_skip=false
  # Resolve the active DoD via the canonical selector. select_active_dod reads
  # relative paths (trail/dod/.active-dod, trail/dod/*.md) so we must anchor to
  # PROJECT_DIR — same pattern used in the .dod-coverage-mismatch branch above.
  _active_dod=""
  if command -v select_active_dod >/dev/null 2>&1; then
    _sad=$(cd "$PROJECT_DIR" && select_active_dod 2>/dev/null) || _sad=""
    _sad_tier=$(printf '%s' "$_sad" | cut -f1)
    _sad_path=$(printf '%s' "$_sad" | cut -f2)
    # B1 (v1.3.4): accept ONLY Tier 1 (explicit .active-dod marker —
    # "blocking authority" per lib/select-active-dod.sh). Tier 2 is the
    # advisory mtime-latest fallback ("non-blocking authority") and must
    # NOT authorise skipping the security stamp, which is itself a blocking
    # decision. This aligns with the coverage-marker self-heal path below,
    # which already trusts ONLY Tier 1. A real approved DoD always carries an
    # .active-dod marker (auto-written by post-edit-dod-routing-check), so
    # the legitimate light-tier skip stays Tier 1. Tier 0/2, empty path, or
    # missing file → fail-closed (require stamp).
    if [ "$_sad_tier" = "1" ] && [ -n "$_sad_path" ]; then
      # select_active_dod returns repo-relative path; anchor to PROJECT_DIR.
      _sad_abs="$PROJECT_DIR/$_sad_path"
      [ -f "$_sad_abs" ] && _active_dod="$_sad_abs"
    fi
  fi
  # If select_active_dod is unavailable or returned Tier 0 / empty / absent file,
  # _active_dod remains empty and we fall through to the fail-closed deny below.

  if [ -n "$_active_dod" ] && [ -f "$_active_dod" ]; then
    # Section-scoped extraction (codex review R2 HIGH fix): security_tier and
    # approved_by_user MUST be read only from inside the `## 라우팅 추천`
    # section. A global grep also matches an out-of-section `security_tier:
    # light` placed anywhere in the DoD (prose, examples, 비범위 notes, a
    # second section) — a fail-open bypass. awk emits only routing-section
    # body lines; an absent section yields an empty string → both values
    # stay empty → fail-closed (no skip).
    _routing_section=$(awk '
      /^## / { in_routing = ($0 ~ /^## 라우팅 추천/) }
      in_routing { print }
    ' "$_active_dod" 2>/dev/null)
    # Only accept exactly "light" (trimmed); anything else → fail-closed.
    _st_raw=$(printf '%s\n' "$_routing_section" \
              | grep -m1 '^[[:space:]]*security_tier:[[:space:]]*' \
              | sed 's/^[[:space:]]*security_tier:[[:space:]]*//' \
              | tr -d '[:space:]"'"'"'' \
              | head -c 20)
    # Extract approved_by_user: must be exactly "true" (trimmed).
    _approved_raw=$(printf '%s\n' "$_routing_section" \
                    | grep -m1 '^[[:space:]]*approved_by_user:[[:space:]]*' \
                    | sed 's/^[[:space:]]*approved_by_user:[[:space:]]*//' \
                    | tr -d '[:space:]"'"'"'' \
                    | head -c 10)

    if [ "$_st_raw" = "light" ] && [ "$_approved_raw" = "true" ]; then
      _security_tier_skip=true
    fi
  fi

  # --- 보안-surface 면제 계산 (spec 2026-06-16, §4) ---
  # light-tier 면제와 독립한 두 번째 면제 경로. 단독 `git commit`(staging 동반
  # 없음 + allowlist 옵션만) + staged diff 가 전부 허용목록(문서/trail/버전
  # 문자열-only)이면 P6+M2 를 둘 다 skip. 그 외 전부 fail-closed. light-tier 와
  # 무관하게 무조건 계산하되, audit 은 보안-surface 가 실제 결정한 경우만(§4.5/§4.6).
  _security_surface_skip=false
  _sx_compute_security_surface_skip

  # 면제 성립 → M2 비교 + P6 부재 차단 둘 다 skip (§4.4). 두 면제 경로는 OR
  # 관계 — 둘 중 하나만 성립해도 skip. P5(코드리뷰)/M3 dual-read 는 이 분기
  # 위쪽에서 이미 수행됐으므로 어느 면제에서도 skip 되지 않는다(불변).
  if [ "$_security_tier_skip" = true ] || [ "$_security_surface_skip" = true ]; then
    # audit: 보안-surface 가 실제 면제를 결정(light-tier 아님)한 경우만 기록(§4.6).
    if [ "$_security_surface_skip" = true ] && [ "$_security_tier_skip" != true ]; then
      _sx_audit_exempt
    fi
    return 0
  fi

  # 면제 미성립 + 보안 표식 부재 → 기존 P6 차단.
  if [ ! -f "$SECURITY_STAMP" ]; then
    # [P6] policy block — JSON deny. HIGH-2: exit directly.
    deny_emit "The security review has not been recorded yet. Run the security-reviewer agent after codex review — this creates the security review record that rein requires before committing." "SECURITY_STAMP_MISSING" "$COMMAND"; rc=$?
    log_block "보안 리뷰 미실행 (${context})" "$COMMAND"
    exit "$rc"
  fi

  # --- M2: 보안 표식 신선도 + cycle + verdict 비교 (§4.1) ---
  # 면제 미성립 + 보안 표식 존재. 통과 조건 (모두 충족):
  #   security_reviewed >= codex_reviewed (정규화 후 lexicographic)
  #   AND security_cycle == codex_cycle (양쪽 non-empty)
  #   AND security verdict == PASS
  # 차단:
  #   보안이 더 오래됨 / cycle 불일치 / 어느 한쪽 빈 cycle / 시각 파싱불가
  #     → SECURITY_REVIEW_STALE (§6.3 fail-closed 포함)
  #   보안 verdict != PASS → SECURITY_REVIEW_NOT_PASSED
  # 스키마 divergence (§2.3): 보안 표식 `=` 구분자, 코드 표식 `: ` 구분자 — 각자 파싱.
  _sec_reviewed_raw=$(_parse_stamp_field "$SECURITY_STAMP" "reviewed" "=")
  _sec_cycle=$(_parse_stamp_field "$SECURITY_STAMP" "cycle" "=")
  _sec_verdict=$(_parse_stamp_field "$SECURITY_STAMP" "verdict" "=")
  _codex_cycle=$(_parse_stamp_field "$REVIEW_STAMP" "cycle" ": ")
  # 코드 표식 시각: M3 가 이미 _codex_reviewed_norm 으로 정규화/검증함 (PASS 못하면
  # 위에서 이미 차단). 여기서는 보안 표식 시각만 정규화하면 된다.
  _sec_reviewed_norm=""
  if [ -n "$_sec_reviewed_raw" ]; then
    _sec_reviewed_norm=$(_normalize_iso "$_sec_reviewed_raw") || _sec_reviewed_norm=""
  fi

  # verdict 검사 (M3 대칭). 보안 verdict 가 PASS 아니면 NOT_PASSED.
  # 단 verdict 가 빈값/부재이면 fail-closed → STALE 로 분류 (§6.3: verdict 부재 차단).
  if [ -n "$_sec_verdict" ] && [ "$_sec_verdict" != "PASS" ]; then
    # [P6b] policy block — JSON deny.
    deny_emit "The recorded security review is not a PASS (verdict not PASS). Re-run the security-reviewer agent and record a PASS before ${context}." "SECURITY_REVIEW_NOT_PASSED" "$COMMAND"; rc=$?
    log_block "보안 리뷰 통과 판정 실패 (${context})" "$COMMAND"
    exit "$rc"
  fi

  # fail-closed 사유들 (전부 STALE):
  #   - 보안 시각 파싱 불가 (빈 touch / 비-ISO)
  #   - 보안 verdict 빈값/부재 (§6.3)
  #   - 빈 cycle (어느 한쪽) — equality 가 빈값끼리 오통과 방지
  #   - cycle 불일치
  #   - 보안이 코드보다 오래됨
  _stale=false
  if [ -z "$_sec_reviewed_norm" ]; then
    _stale=true                                   # 보안 시각 파싱 불가
  elif [ -z "$_sec_verdict" ]; then
    _stale=true                                   # 보안 verdict 부재/빈값
  elif [ -z "$_sec_cycle" ] || [ -z "$_codex_cycle" ]; then
    _stale=true                                   # 빈 cycle (한쪽이라도)
  elif [ "$_sec_cycle" != "$_codex_cycle" ]; then
    _stale=true                                   # cycle 불일치
  elif [ "$_sec_reviewed_norm" \< "$_codex_reviewed_norm" ]; then
    _stale=true                                   # 보안이 코드보다 오래됨
  fi

  if [ "$_stale" = true ]; then
    # [P6c] policy block — JSON deny: 보안 표식이 코드 표식보다 오래됐거나 cycle
    # 불일치/빈값/파싱불가 → 이전 사이클 통과가 새 코드에 stale-적용되는 것을 차단.
    deny_emit "The recorded security review is stale relative to the codex review (older, different cycle, empty cycle, or unreadable). Re-run the security-reviewer agent after the latest codex review before ${context}." "SECURITY_REVIEW_STALE" "$COMMAND"; rc=$?
    log_block "보안 리뷰 stale (${context})" "$COMMAND"
    exit "$rc"
  fi
  # security >= code + cycle 일치 non-empty + verdict=PASS → P6 통과.

  return 0
}

# --- Coverage matrix gate ([P2] / [I3], 리뷰 stamp 검사보다 선행) ---
# Plan A Phase 5 (GI-dod-mismatch-marker-consumer): BLOCK_MARKERS is an array
# so the gate consumes both the legacy plan-level marker and the new DoD-level
# marker. Advisory (non-blocking) markers like .dod-coverage-advisory must NOT
# be listed here — they are informational only and do not gate commits/tests.
# Iteration order determines which marker's message surfaces first when more
# than one is present; we keep legacy first for message stability.
BLOCK_MARKERS=(
  "$PROJECT_DIR/trail/dod/.coverage-mismatch"
  "$PROJECT_DIR/trail/dod/.dod-coverage-mismatch"
)

# Sanitize a path string read from a marker file before echoing to stderr.
# Defense-in-depth (security review INFO-1): although marker content already
# requires repo trust to modify, a hostile or corrupted marker could embed
# control chars / ANSI escapes / very long strings that pollute stderr +
# blocks.log. Normalize to a printable, length-bounded form before any echo.
#   - Strip non-printable / control chars
#   - Truncate to 200 chars
sanitize_marker_path() {
  printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200
}

# Consumer-side coverage marker self-heal. Returns:
#   0 — validator PASS for marker target(s); marker is stale and can be cleared
#   1 — validator FAIL; first failing target is echoed to stdout (sanitized)
#   2 — cannot revalidate (no target identifiable / lib missing / validator missing);
#       caller must conservatively block (legacy behavior)
# Rationale: prior behavior blocked any test/commit while the marker file existed,
# even when the underlying coverage failure had already been fixed. consumer-side
# revalidate clears stale markers without weakening the discipline (real FAIL
# still blocks with target info).
revalidate_coverage_marker() {
  local marker="$1"
  local marker_basename
  marker_basename=$(basename "$marker")

  # plugin-aware validator resolution. If unavailable, fall back to legacy
  # conservative block.
  if ! command -v resolve_helper_script >/dev/null 2>&1; then
    return 2
  fi
  local validator
  validator=$(resolve_helper_script rein-validate-coverage-matrix.py 2>/dev/null || true)
  if [ -z "$validator" ] || [ ! -f "$validator" ]; then
    return 2
  fi

  case "$marker_basename" in
    .coverage-mismatch)
      # marker content: deduped lines of failed plan paths (post-edit-plan-coverage.sh).
      # Empty marker → cannot revalidate any target → conservative block.
      [ -s "$marker" ] || return 2
      local first_fail=""
      local validated_count=0
      local plan_path
      while IFS= read -r plan_path; do
        [ -z "$plan_path" ] && continue
        # If the plan file has been deleted, skip the validator call but DO NOT
        # treat the marker as healed — we have no positive PASS evidence for
        # this entry. The deleted path cannot block forever though: caller's
        # rc=2 path (returned below if no entry validated) preserves the
        # conservative block until a maintainer cleans up.
        [ -f "$plan_path" ] || continue
        validated_count=$((validated_count + 1))
        if ! "${PYTHON_RUNNER[@]}" "$validator" plan "$plan_path" >/dev/null 2>&1; then
          # Capture only the first failing path; full enumeration would
          # bloat the block message without adding actionable info.
          if [ -z "$first_fail" ]; then
            first_fail="$plan_path"
          fi
        fi
      done < "$marker"
      if [ -n "$first_fail" ]; then
        # INFO-1: sanitize before surfacing to caller (which echoes to stderr).
        sanitize_marker_path "$first_fail"
        return 1
      fi
      # Contract: rc=0 only when at least one validator invocation actually
      # PASSed. If every entry was skipped (all paths deleted), we have no
      # positive evidence and must fall through to conservative block.
      if [ "$validated_count" -eq 0 ]; then
        return 2
      fi
      return 0
      ;;
    .dod-coverage-mismatch)
      # Marker has no content (touch'd by pre-edit-dod-gate). Re-identify
      # active DoD via the shared selector and revalidate it.
      if ! command -v select_active_dod >/dev/null 2>&1; then
        return 2
      fi
      local result tier dod_path
      # selector reads trail/dod/.active-dod and walks trail/dod/ — both are
      # repo-relative, so cwd matters. Anchor to PROJECT_DIR.
      result=$(cd "$PROJECT_DIR" && select_active_dod 2>/dev/null) || return 2
      tier="${result%%$'\t'*}"
      dod_path=$(printf '%s' "$result" | awk -F'\t' '{print $2}')
      # Tier 0: no candidate. Tier 2: advisory fallback (the original Tier 1
      # active DoD that produced the marker may have been deleted/rotated).
      # Trust ONLY Tier 1 for self-heal — clearing the blocking marker based
      # on a Tier 2 fallback DoD risks healing a marker whose true source is
      # no longer identifiable.
      [ "$tier" = "1" ] || return 2
      [ -z "$dod_path" ] && return 2
      # Selector returns repo-relative path — anchor to PROJECT_DIR for
      # the on-disk check + validator invocation.
      local dod_abs="$PROJECT_DIR/$dod_path"
      [ -f "$dod_abs" ] || return 2
      if ! "${PYTHON_RUNNER[@]}" "$validator" dod "$dod_abs" >/dev/null 2>&1; then
        # INFO-1: sanitize before surfacing to caller.
        sanitize_marker_path "$dod_path"
        return 1
      fi
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# X3.B.2: Area B plan-coverage deferral — flush .plan-coverage-dirty *before*
# the legacy BLOCK_MARKERS scan so dirty entries surface as the existing
# .coverage-mismatch marker (which BLOCK_MARKERS then handles via the standard
# P2 path). design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md §5.2
# + §7 Scope ID 2 (commit-gate-flushes-plan-coverage-dirty-list-...).
#
# Returns:
#   0 — all validated entries PASSed, .processing removed
#   1 — at least one FAIL → .coverage-mismatch has the entry, .processing removed
#       (caller falls through to BLOCK_MARKERS which fires the existing P2 deny)
#   2 — cannot validate anything (deleted-only dirty list, or infra failure) →
#       caller MUST block conservatively
#
# Atomic rename protocol (§5.1.r1):
#   1. mv .plan-coverage-dirty → .plan-coverage-dirty.processing (atomic)
#   2. New post-edit appends create a fresh .plan-coverage-dirty (disjoint)
#   3. flush only reads .processing
#   4. On PASS/FAIL terminal state, .processing is removed
#   5. On crash mid-flush, .processing remains stale → next flush detects and
#      retries (no age-based GC; stale data still needs processing)
flush_plan_coverage_dirty() {
  local dirty="$PROJECT_DIR/trail/dod/.plan-coverage-dirty"
  local processing="$PROJECT_DIR/trail/dod/.plan-coverage-dirty.processing"
  local marker="$PROJECT_DIR/trail/dod/.coverage-mismatch"
  local lock_dir="$PROJECT_DIR/trail/dod/.plan-coverage-dirty.lock"
  local lock_timeout_ms=2000
  local lock_held=0

  # codex Round 1 HIGH fix — acquire the same mkdir-based mutex the
  # post-edit hook uses for its append. This serializes our `mv` with
  # concurrent post-edit appends so a writer's open()→write() window
  # cannot land in the just-renamed `.processing` inode and then be
  # removed when flush completes.
  local waited_ms=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$waited_ms" -ge "$lock_timeout_ms" ]; then
      # Lock contended beyond budget — fail-closed. A 2s window is far
      # beyond any legitimate hook execution; persistent contention almost
      # certainly means a stale lock dir from a crashed hook. Manual
      # cleanup (rmdir "$lock_dir") is required.
      echo "[rein] flush: dirty-list lock contended >${lock_timeout_ms}ms ($lock_dir). Possible stale lock from a crashed prior hook — rmdir manually if no other hook is running, then retry." >&2
      return 2
    fi
    sleep 0.05
    waited_ms=$((waited_ms + 50))
  done
  lock_held=1
  # Lock-released-on-return helper — every path below MUST release before
  # returning. We use explicit `rmdir "$lock_dir"` rather than a trap to
  # keep this readable; the few return points are clearly visible.

  # Step 1: stage everything that is currently dirty into `.processing` as a
  # single set. codex Round 2 HIGH fix — a stale `.processing` (crashed
  # prior flush) MUST NOT mask a fresh `.plan-coverage-dirty` from THIS
  # commit's invocations. We hold the lock so no concurrent append can
  # slip between the merge steps.
  #
  # Three input cases:
  #   - dirty present, processing absent          → mv dirty → processing
  #   - dirty absent,  processing present (stale) → use as-is
  #   - both present                              → append dirty into
  #     processing (preserving stale entries) then rm dirty
  #
  # In all three cases, the post-merge `.processing` is the complete set
  # of dirty paths for this flush invocation, and `.plan-coverage-dirty`
  # is absent so subsequent post-edit appends create a brand-new file.
  if [ -f "$dirty" ]; then
    if [ -f "$processing" ]; then
      # Merge fresh dirty into stale processing. Order does not matter —
      # awk dedup at Step 4 produces a unique set regardless.
      if ! cat "$dirty" >> "$processing" 2>/dev/null; then
        echo "[rein] flush: failed to merge .plan-coverage-dirty into .processing (filesystem error). Re-run after checking $DOD_DIR is writable." >&2
        [ "$lock_held" = 1 ] && rmdir "$lock_dir" 2>/dev/null
        return 2
      fi
      rm -f "$dirty"
    else
      if ! mv -f "$dirty" "$processing" 2>/dev/null; then
        # [I-flush] infra failure — fs error. Fail-closed.
        echo "[rein] flush: failed to rename .plan-coverage-dirty to .processing (filesystem error). Re-run after checking $DOD_DIR is writable." >&2
        [ "$lock_held" = 1 ] && rmdir "$lock_dir" 2>/dev/null
        return 2
      fi
    fi
  fi
  # Lock can be released as soon as the merge is complete — subsequent
  # post-edit appends now hit the fresh (recreated) `.plan-coverage-dirty`
  # and cannot interfere with our validator loop. The processing snapshot
  # we hold is closed off from further mutation.
  [ "$lock_held" = 1 ] && rmdir "$lock_dir" 2>/dev/null
  lock_held=0

  # Step 2: nothing to flush.
  [ -f "$processing" ] || return 0

  # Step 3: resolve validator (fail-closed if missing — same posture as the
  # existing revalidate_coverage_marker path).
  local validator=""
  if command -v resolve_helper_script >/dev/null 2>&1; then
    validator=$(resolve_helper_script rein-validate-coverage-matrix.py 2>/dev/null || true)
  fi
  if [ -z "$validator" ] || [ ! -f "$validator" ]; then
    echo "[rein] flush: coverage validator not found — re-run 'rein update' or restore plugin installation." >&2
    return 2
  fi

  # Step 4: read unique paths (dedup at flush time — §7 ID 2 set-equality
  # contract: validated path set == unique dirty path set).
  local unique_paths
  unique_paths=$(awk 'NF && !seen[$0]++' "$processing" 2>/dev/null)

  local first_fail=""
  local validated_count=0
  local fail_count=0
  local runtime_err_count=0
  local first_runtime_err=""
  local first_runtime_rc=""
  local plan_path
  while IFS= read -r plan_path; do
    [ -z "$plan_path" ] && continue
    # Deleted plan → skip (no positive PASS evidence accrued for this entry).
    [ -f "$plan_path" ] || continue
    validated_count=$((validated_count + 1))
    "${PYTHON_RUNNER[@]}" "$validator" "$plan_path" >/dev/null 2>&1
    local v_rc=$?
    # X3.B.5 — validator rc 의 두 부류 분리 (codex Round 1 Advisory 반영):
    #   rc 0 → PASS (validator ran cleanly, matrix valid)
    #   rc 2 → validation FAIL (validator ran cleanly, detected mismatch). 본
    #          분기는 .coverage-mismatch 에 기록 → BLOCK_MARKERS 의 P2 deny.
    #   rc != 0,2 → runtime error (Python import 실패, validator script crash,
    #          OS-level fault). 본 분기는 infra integrity 문제 — flush 전체가
    #          fail-closed (validation discipline 의 false-negative 위험).
    # 동일 flush 내에서 두 부류가 섞이면 runtime error 가 우선 — 단, FAIL 기록은
    # 다음 flush 시도를 위해 .coverage-mismatch 에 보존한다 (evidence 유지).
    case "$v_rc" in
      0)
        :
        ;;
      2)
        fail_count=$((fail_count + 1))
        mkdir -p "$(dirname "$marker")"
        if ! { [ -f "$marker" ] && grep -qxF "$plan_path" "$marker"; }; then
          # Single-line append, O_APPEND atomic (consistent with the post-edit
          # hook's append posture). The legacy revalidate path will then pick
          # this entry up as the first failing target.
          echo "$plan_path" >> "$marker"
        fi
        [ -z "$first_fail" ] && first_fail="$plan_path"
        ;;
      *)
        runtime_err_count=$((runtime_err_count + 1))
        if [ -z "$first_runtime_err" ]; then
          first_runtime_err="$plan_path"
          first_runtime_rc="$v_rc"
        fi
        ;;
    esac
  done <<< "$unique_paths"

  # Step 5: decide terminal state.
  if [ "$runtime_err_count" -gt 0 ]; then
    # X3.B.5 — runtime error 가 발생하면 flush 전체가 infra-broken. .processing
    # 은 retain (다음 commit 시 stale 로 재시도). FAIL 기록도 marker 에 이미
    # 적재돼 evidence 보존. 본 분기는 [I-flush] infra integrity 분류와 일관.
    echo "[rein] flush: validator runtime error (rc=$first_runtime_rc) on $first_runtime_err — validator subprocess failed to complete validation. Re-run 'rein update' or restore plugin installation; the dirty list ($processing) is retained for retry." >&2
    return 2
  fi
  if [ "$fail_count" -gt 0 ]; then
    # At least one FAIL recorded in .coverage-mismatch → terminal for this
    # flush. Remove .processing; the legacy BLOCK_MARKERS scan will pick up
    # .coverage-mismatch and emit P2 deny on the *first* failing target.
    rm -f "$processing"
    return 1
  fi
  if [ "$validated_count" -eq 0 ]; then
    # Conservative block: no validator was actually invoked (all paths
    # deleted). .processing retained so a future flush can retry once the
    # paths exist again (e.g., user un-deletes or fixes path).
    return 2
  fi
  # All PASS.
  rm -f "$processing"
  return 0
}

# Command patterns that gate test/commit checks. This SAME token set is
# mirrored in hooks.json `if` entries (one entry per pattern) so the script
# only spawns on these commands; here it also re-classifies for the in-script
# coverage-marker scan. `git commit` is the hard gate (spec R6).
# GMF-1: `git commit` split out of the alternation into its own canonical
# matcher — embedding the ERE inside the literal alternation would mis-order
# alternation precedence. The canonical $GIT_COMMIT_ERE skips git global
# options + multi-space and closes `commit` on a shell-token boundary.
if command_invokes "pytest|jest|vitest|mocha|npm run test|npm test|yarn test|pnpm test|python -m pytest|npx jest|npx vitest|bash tests/" \
   || command_invokes "$GIT_COMMIT_ERE"; then
  # X3.B.2: flush plan-coverage dirty list BEFORE legacy marker scan.
  flush_plan_coverage_dirty
  flush_rc=$?
  if [ "$flush_rc" -eq 2 ]; then
    # Conservative block (all-deleted dirty list, or infra failure).
    # Cannot revalidate → fail-closed. Use the same I-class exit 2 posture
    # the legacy "cannot revalidate" path uses below.
    echo "[rein] flush: coverage dirty list could not be validated (all paths deleted, infra failure, or similar). Remove stale entries from $PROJECT_DIR/trail/dod/.plan-coverage-dirty.processing manually if no longer relevant." >&2
    log_block "plan-coverage-dirty conservative block" "$COMMAND"
    exit 2
  fi
  # flush_rc == 1 (FAIL) falls through — the BLOCK_MARKERS loop below picks
  # up the newly-created .coverage-mismatch entry and emits P2 deny.
  # flush_rc == 0 (all PASS) falls through — BLOCK_MARKERS finds no marker.

  for marker in "${BLOCK_MARKERS[@]}"; do
    if [ -f "$marker" ]; then
      heal_target=$(revalidate_coverage_marker "$marker" 2>/dev/null)
      heal_rc=$?
      case "$heal_rc" in
        0)
          # Stale marker — validator now passes. Silent self-heal + continue
          # to the next marker (or fall through to remaining gates).
          rm -f "$marker"
          continue
          ;;
        1)
          # [P2] policy block — JSON deny: coverage validator FAIL (rc=1, identifiable target)
          marker_name=$(basename "$marker")
          deny_emit "The coverage check found that a plan or task record does not yet list this command's changes as implemented. Update the 'covers' list in the failing file to match what has actually been done, then re-run to clear the check automatically." "COVERAGE_MISMATCH" "$heal_target"; rc=$?
          log_block "coverage-mismatch" "$COMMAND"
          exit "$rc"
          ;;
        *)
          # [I3] infra integrity — exit 2 유지 (JSON deny 미전환): coverage marker target 식별 불가 (rc=2)
          # Cannot revalidate (no target / lib unavailable). Fall back to the
          # legacy conservative block — better to false-positive than silently
          # bypass coverage discipline.
          echo "[rein] A coverage check failure marker exists ($marker) but the target file inside it could not be identified. Fix the plan or task record so the validator can run, or remove the marker file directly if it is no longer relevant." >&2
          log_block "coverage-mismatch" "$COMMAND"
          exit 2
          ;;
      esac
    fi
  done
fi

# --- 테스트 실행은 리뷰 stamp 게이트 대상이 아님 (GUARD-1, 2026-05-19) ---
# 이전에는 pytest/jest 등 테스트 *실행* 자체를 .codex-reviewed stamp 없으면
# 차단했다. 이는 TDD red-green 루프를 구조적으로 불가능하게 만들었다 — 코드를
# 작성/리뷰하기 전에 실패하는 재현 테스트를 먼저 돌릴 수 없었다. 게이트 대상은
# *커밋/완료 선언* 이며, 그것은 바로 아래 `git commit` 게이트가 강제한다.
# 근거: need-to-confirm.md GUARD-1. coverage-matrix 마커의 pytest 차단은
# 별개 discipline 으로 위에서 그대로 유지된다.

# --- Codex 리뷰 stamp 검사 (git commit 시) ([P3]~[P6]) ---
# GMF-1: canonical $GIT_COMMIT_ERE (was literal "git commit").
if command_invokes "$GIT_COMMIT_ERE"; then
  if ! check_review_stamp "committing"; then
    exit 2
  fi
fi

# --- 커밋 메시지 포맷 검증 ([P7] / [I4] / [I5]) ---
# python3 helper 기반 (복합 명령 + heredoc + scope 지원)
# - 복합 명령에서 첫 "commit" 토큰 이후 구간만 분석 (다음 구분자 &&, ||, ;, | 전까지)
#   → 복합 명령의 tag 쪽 -m 을 오인하지 않음
# - heredoc 본문의 첫 줄을 multiline regex 로 정확히 추출
#   → $(cat <<'EOF' ... EOF) 형태 메시지도 올바로 검사됨
# - conventional commits scope 표기법 허용: type(scope)?: description
# 추출 로직 자체는 lib/extract-commit-msg.py 에 분리 (bash 의
# $(cmd <<HEREDOC) + `|| true` 파서 한계를 피하기 위함).
# GMF-1: canonical $GIT_COMMIT_ERE (was literal "git commit").
if command_invokes "$GIT_COMMIT_ERE"; then
  EXTRACT_SCRIPT="$SCRIPT_DIR/lib/extract-commit-msg.py"
  # Helper 누락은 fail-open 으로 두지 않는다. heredoc 우회와 같은 silent
  # bypass 를 막기 위해, helper 가 없거나 python3 가 동작하지 않으면 BLOCK.
  if [ ! -f "$EXTRACT_SCRIPT" ]; then
    # [I4] infra integrity — exit 2 유지 (JSON deny 미전환): 커밋 메시지 검증 helper 누락
    echo "[rein] The commit message cannot be validated because the helper script is missing (expected at: $EXTRACT_SCRIPT). Run 'rein update' to restore the missing file." >&2
    log_block "commit msg helper 누락" "$EXTRACT_SCRIPT"
    exit 2
  fi
  # python3 존재 여부는 bg_resolve_python_or_die 가 이미 gate 했다. PYTHON_RUNNER
  # 배열은 이 시점에 set 되어 있으며 strict-resolver 통과한 인터프리터이다.
  # 배열 확장 `"${PYTHON_RUNNER[@]}"` 로 token 경계를 보존해야 안전하다.
  COMMIT_MSG=$("${PYTHON_RUNNER[@]}" "$EXTRACT_SCRIPT" "$COMMAND" 2>/dev/null)
  EXTRACT_RC=$?
  if [ "$EXTRACT_RC" -ne 0 ]; then
    # [I5] infra integrity — exit 2 유지 (JSON deny 미전환): 커밋 메시지 helper 실행 실패
    echo "[rein] The commit message could not be extracted because the helper script failed (exit $EXTRACT_RC). Check that Python is working correctly and run 'rein update' if the problem persists." >&2
    log_block "commit msg helper 실패" "$EXTRACT_SCRIPT"
    exit 2
  fi

  if [ -n "$COMMIT_MSG" ]; then
    FIRST_LINE=$(printf '%s' "$COMMIT_MSG" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$FIRST_LINE" ]; then
      if ! echo "$FIRST_LINE" | grep -qE "^(feat|fix|docs|refactor|test|chore)(\([a-zA-Z0-9_-]+\))?: .+"; then
        # Co-Authored-By 라인은 면제
        if ! echo "$FIRST_LINE" | grep -qE "^Co-Authored-By:"; then
          # [P7] policy block — JSON deny
          deny_emit "The commit message does not follow Conventional Commits format. Use: <type>(<scope>)?: <description> — where type is feat|fix|docs|refactor|test|chore and scope uses only letters, digits, underscores, or hyphens." "COMMIT_MSG_FORMAT" "$FIRST_LINE"; rc=$?
          log_block "커밋 메시지 포맷 위반" "$FIRST_LINE"
          exit "$rc"
        fi
      fi
    fi
  fi
fi

exit 0
