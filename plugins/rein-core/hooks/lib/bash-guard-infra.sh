# Shared infra for the PreToolUse(Bash) guard pair.
#
# Sourced (NOT exec'd) by:
#   - pre-bash-safety-guard.sh      (always-on safety guard)
#   - pre-bash-test-commit-gate.sh  (if-gated test/commit gate)
#
# Why a shared lib (HK-2, docs/specs/2026-05-19-cc-feature-adoption.md §HK-2):
#   The former single Bash guard was split into two hooks so the always-on safety checks
#   (pipe-to-shell, .env reads, destructive git) do NOT spawn the heavier
#   test/commit gate on every Bash call. Three infra-integrity points are
#   COMMON to both scripts and must fail-closed identically in each:
#     [I1] python3 resolver failure
#     [I2] hook input JSON parse failure
#     [I6] JSON deny emitter unavailable/corrupt
#   They live here so both scripts share one implementation and one message
#   set. Each script sources this file and is responsible for fail-closing on
#   its own infra (the source itself is checked by the caller — see
#   bg_infra_init below).
#
# Exit code protocol (inherited from the former single Bash guard, 2-tier):
#   정책 차단 [P*]: exit 0 + JSON deny  (deny_emit via json-deny-emitter.sh)
#   인프라 무결성 [I*]: exit 2 + stderr  (fail-closed infra errors, NOT converted)
#   분류 근거: docs/specs/2026-05-17-hook-message-assistant-tone.md §1
#
# Contract for callers:
#   1. Set BG_GUARD_NAME to the caller's own hook identity string BEFORE
#      sourcing — used as the `hook` field in blocks.jsonl and the THRESHOLD
#      counting key. Falls back to "pre-bash-guard" if unset (preserves the
#      historical aggregate key so existing incident history keeps matching).
#   2. Source lib/portable.sh, lib/python-runner.sh, lib/project-dir.sh and
#      resolve PROJECT_DIR before sourcing this file (this file does NOT
#      re-source them — it uses PYTHON_RUNNER / PROJECT_DIR).
#   3. Source this file with the `if !` form so a parse error fail-closes:
#        if ! . "$SCRIPT_DIR/lib/bash-guard-infra.sh"; then ... exit 2; fi
#   4. After sourcing, call: bg_infra_init "$SCRIPT_DIR"
#      which loads the deny emitter ([I6]) and exits 2 on failure.
#   5. Then call: bg_resolve_python_or_die   ([I1])
#      and:        COMMAND=$(bg_extract_command "$SCRIPT_DIR" "$INPUT")  ([I2])

# BG_GUARD_NAME — caller identity. Historical default keeps incident history
# (pattern_hash) stable for callers that do not override it.
: "${BG_GUARD_NAME:=pre-bash-guard}"

BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"

# log_block REASON TARGET
#   Append a JSONL block record and warn when the same (hook, reason) pair
#   recurs. THRESHOLD counting is per (hook, reason) — not whole-hook — so it
#   measures a repeating *violation pattern*, matching the aggregate logic.
log_block() {
  local reason="$1"
  local target="$2"
  # Guard: avoid a raw python3 re-invocation on the resolver-failure path
  # (stderr noise). Skip logging if PYTHON_RUNNER is unset or empty.
  if [ -z "${PYTHON_RUNNER+x}" ] || [ "${#PYTHON_RUNNER[@]}" -eq 0 ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  "${PYTHON_RUNNER[@]}" - "$BG_GUARD_NAME" "$reason" "$target" <<'PY' >> "$BLOCKS_LOG_JSONL" 2>/dev/null || true
import json, sys
from datetime import datetime, timezone
print(json.dumps({
  "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
  "hook": sys.argv[1],
  "reason": sys.argv[2],
  "target": sys.argv[3],
}, ensure_ascii=False))
PY

  local count
  count=$("${PYTHON_RUNNER[@]}" -c "
import json, sys
target_hook = sys.argv[1]
target_reason = sys.argv[2]
n = 0
try:
    with open(sys.argv[3]) as f:
        for line in f:
            try:
                e = json.loads(line)
                if e.get('hook') == target_hook and e.get('reason') == target_reason:
                    n += 1
            except Exception:
                continue
except OSError:
    pass
print(n)
" "$BG_GUARD_NAME" "$reason" "$BLOCKS_LOG_JSONL" 2>/dev/null || echo 0)
  if [ "$count" -ge 3 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

# bg_infra_init SCRIPT_DIR
#   [I6] infra integrity — load lib/json-deny-emitter.sh and require it to
#   define deny_emit as a shell FUNCTION. Using `declare -F deny_emit` (not
#   `command -v`) is deliberate: command -v matches PATH executables, builtins
#   and aliases — any stray `deny_emit` binary on PATH would falsely pass and
#   then fail silently when called (rc=127, fail-open). declare -F only
#   succeeds for shell functions defined in the current process.
#   The source is NOT masked with `|| true`: a missing file or parse error
#   produces a non-zero exit that the `if !` condition catches directly.
#   On failure: exit 2.
bg_infra_init() {
  local script_dir="$1"
  # shellcheck source=./json-deny-emitter.sh
  if ! . "$script_dir/lib/json-deny-emitter.sh" 2>/dev/null \
     || ! declare -F deny_emit >/dev/null 2>&1; then
    echo "[rein] The Bash guard cannot run because the JSON deny emitter (lib/json-deny-emitter.sh) could not be loaded — it may be missing or corrupt. All policy checks are paused until the emitter is restored. Run 'rein update' to repair the installation." >&2
    exit 2
  fi
}

# bg_resolve_python_or_die
#   [I1] infra integrity — resolve a real python3 interpreter. python3 is
#   required for JSON parsing; without it the Bash gate is fully disabled, so
#   this fail-closes (exit 2). Calls resolve_python from lib/python-runner.sh.
#   NOTE: bash `!` prefix resets $? to 0 after evaluation — capture $?
#   immediately after the call to preserve the resolver's diagnostic code
#   (10/11/12).
bg_resolve_python_or_die() {
  resolve_python
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      10) echo "[rein] The Bash guard cannot run because Python is not installed. Install Python 3 to restore all policy checks." >&2 ;;
      11) echo "[rein] The Bash guard cannot run because the Windows App Execution Alias Python stub was detected instead of a real Python installation. Install Python 3 from python.org or the Microsoft Store to proceed." >&2 ;;
      12) echo "[rein] The Bash guard cannot run because Python failed to launch (exit 9009 family) — this is common in Windows Git Bash or MSYS, or when REIN_PYTHON points to an invalid interpreter. Check your Python installation or unset REIN_PYTHON." >&2 ;;
    esac
    print_windows_diagnostics_if_applicable >&2
    log_block "python runtime unavailable" "unknown"
    exit 2
  fi
}

# bg_extract_command SCRIPT_DIR INPUT
#   [I2] infra integrity — parse tool_input.command out of the hook input
#   JSON via lib/extract-hook-json.py. On parse failure: print the [I2]
#   diagnostic to stderr and return 2 (fail-closed, NOT converted to JSON
#   deny). On success: set the global COMMAND variable and return 0.
#
#   WHY a global instead of stdout: the caller MUST be able to fail-close at
#   top level. If this helper ran inside `COMMAND=$(bg_extract_command ...)`,
#   any `exit 2` inside it would only kill the `$()` subshell, not the hook —
#   the script would silently continue with an empty COMMAND. So the caller
#   invokes this WITHOUT command substitution and checks the return code:
#       bg_extract_command "$SCRIPT_DIR" "$INPUT" || exit 2
#   after which $COMMAND holds the parsed command.
bg_extract_command() {
  local script_dir="$1"
  local input="$2"
  local cmd rc
  cmd=$(printf '%s' "$input" | "${PYTHON_RUNNER[@]}" "$script_dir/lib/extract-hook-json.py" --field tool_input.command --default '')
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[rein] The Bash guard cannot read the tool input because the hook JSON could not be parsed (extract-hook-json.py exited $rc). This is an installation issue — run 'rein update' to repair." >&2
    log_block "json parse failure" "unknown"
    return 2
  fi
  COMMAND="$cmd"
  return 0
}

# command_invokes PATTERN
#   Return 0 if PATTERN (an ERE alternation of command tokens) appears at a
#   command-clause start in $COMMAND, else 1. Clause start = string/line start
#   or right after a shell separator (`;` `&` `|` `(`, including the last char
#   of `&&`/`||`). Leading `VAR=value` env assignments and command wrappers
#   (`env`/`sudo`/`command`/`nohup`/`time`/`exec`) are allowed.
#
#   Why clause anchoring: an un-anchored substring match would classify
#   commands that merely mention a keyword as an arg/value/text — `grep
#   "pytest"`, `npm pkg set scripts.test=vitest`, `echo "git reset --hard"`
#   (FU-4). The clause-start anchor separates real invocation from mention.
#
#   Known limitation (codex R1): shell quoting is not understood — `;`/`&&`
#   inside quotes are still treated as separators. Full resolution needs a
#   shell parser, out of scope for a regex classifier.
#
#   Reads $COMMAND from the caller's scope.
command_invokes() {
  local pattern="$1"
  printf '%s' "$COMMAND" | grep -qE \
    "(^|[;&|(])[[:space:]]*((env|sudo|command|nohup|time|exec)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*($pattern)"
}
