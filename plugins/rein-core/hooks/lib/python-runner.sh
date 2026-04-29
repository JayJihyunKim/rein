# .claude/hooks/lib/python-runner.sh
#
# Python interpreter resolver for rein hooks. Source this file at the top
# of every hook that shells out to Python (e.g. extract-hook-json.py,
# extract-commit-msg.py):
#
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=./lib/python-runner.sh
#   . "$SCRIPT_DIR/lib/python-runner.sh"
#
#   # Option A: strict (pre-hooks, fail-closed)
#   # WARNING: `if ! resolve_python; then rc=$?` 은 bash `!` 가 exit status 를
#   # 0/1 로 정규화하므로 $? 가 항상 0 이 되어 10/11/12 구분이 사라진다.
#   # 반드시 아래처럼 `!` 없이 rc 를 먼저 캡처하라.
#   resolve_python
#   rc=$?
#   if [ "$rc" -ne 0 ]; then
#     case "$rc" in
#       10) echo "BLOCKED: Python 인터프리터 부재." >&2 ;;
#       11) echo "BLOCKED: WindowsApps Python stub 감지." >&2 ;;
#       12) echo "BLOCKED: Python launch 실패 (9009 계열)." >&2 ;;
#       *)  echo "BLOCKED: Python resolver 알 수 없는 실패 (rc=$rc)." >&2 ;;
#     esac
#     print_windows_diagnostics_if_applicable >&2
#     exit 2
#   fi
#
#   # Option B: soft (post-hooks)
#   resolve_python 2>/dev/null
#   rc=$?
#   if [ "$rc" -ne 0 ]; then
#     exit 0
#   fi
#
#   FILE_PATH=$(printf '%s' "$INPUT" \
#     | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
#         --field tool_input.file_path --default '')
#
# PYTHON_RUNNER contract:
#   PYTHON_RUNNER is a **bash array** populated by resolve_python(). Callers
#   MUST expand with the array form "${PYTHON_RUNNER[@]}" to preserve token
#   boundaries. The legacy "string + unquoted expansion" pattern
#   (`$PYTHON_RUNNER script.py`) is **forbidden**: any shell metachar or
#   whitespace in REIN_PYTHON would become a word-split / injection vector.
#
#   The array holds a verified execution prefix, e.g.
#     ("/abs/path/python3")       # single-token interpreter
#     ("py" "-3")                 # Windows launcher (MSYS/Cygwin only)
#     ("$VIRTUAL_ENV/bin/python") # active venv on POSIX
#   Always prepend to the extractor/helper path:
#     "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" [args...]
#
# Exit codes (resolve_python):
#   0  success. PYTHON_RUNNER is populated and health-checked.
#   10 no candidate interpreter found (missing python3/python/py entirely).
#   11 a candidate resolved to a Windows App Execution Alias / stub
#      (WindowsApps path, case-insensitive). Real Python required.
#   12 launch failure (command -v succeeded but `python -c "import sys"`
#      failed — typically Windows 9009 truncated to `exit 49`), OR
#      REIN_PYTHON was set but rejected by validate_runner_override()
#      (shell metachars / empty string). Hard-fail, no silent fallback.
#
# Platform support:
#   - macOS, Linux, WSL2: first-class. `python3` is expected.
#   - Git Bash / MSYS2 / Cygwin: advisory. Resolver falls back to `py -3`
#     after `python3`/`python` miss; WindowsApps stubs are rejected.
#   - PowerShell / CMD / native Windows bash: unsupported.
#
# Design notes:
#   - candidate encoding: "label:ntok:tokens"
#       label = source marker (REIN_PYTHON/VENV/python3/python/py3)
#       ntok  = 1 → single token (may contain spaces, e.g. venv path).
#               Preserved as one array element via direct assignment.
#       ntok  = 2+ → internal multi-token (only "py -3" today).
#                    Split via `read -ra`. User input never reaches this
#                    path — REIN_PYTHON always uses ntok=1.
#   - REIN_PYTHON hard-fail (Codex 3rd spec-review): if set but invalid,
#     return 12 immediately instead of silently falling through to later
#     candidates. A user who deliberately configures an override deserves
#     to know when that override was rejected.
#   - Safe under `set -u`: every `${var:-}` defaulted, arrays initialised
#     to `()` before use, no unbound reads.

# ------------------------------------------------------------
# validate_runner_override VALUE
#   Reject REIN_PYTHON values that could inject shell syntax.
#   Allowed: any path/token without shell metachars.
#   Rejected: empty string; strings containing ; & | < > $ `
#   Return: 0 accept, 1 reject.
# ------------------------------------------------------------
validate_runner_override() {
  local value="${1:-}"
  case "$value" in
    "") return 1 ;;
    *\;*|*\&*|*\|*|*\<*|*\>*|*\$*|*\`*) return 1 ;;
  esac
  return 0
}

# ------------------------------------------------------------
# health_check CMD [ARGS...]
#   Actually invoke the candidate interpreter to confirm it launches.
#   Silences stdout/stderr. Windows stubs / broken shims will fail here
#   (9009 → exit 49 after 8-bit truncation by Git Bash/MSYS).
#   Return: 0 on `import sys` success, non-zero otherwise.
# ------------------------------------------------------------
health_check() {
  "$@" -c "import sys; sys.exit(0)" >/dev/null 2>&1
}

# ------------------------------------------------------------
# resolve_python
#   Populate PYTHON_RUNNER with the first healthy interpreter, in order:
#     1) $REIN_PYTHON (validated single path; hard-fail on invalid)
#     2) active venv: $VIRTUAL_ENV/bin/python (POSIX)
#                  or $VIRTUAL_ENV/Scripts/python.exe (Windows)
#     3) python3
#     4) python
#     5) MSYS/MINGW/Cygwin only: py -3
#   WindowsApps stub paths are skipped (case-insensitive match on
#   "windowsapps" in the resolved absolute path).
#   See exit code table in the header.
# ------------------------------------------------------------
resolve_python() {
  PYTHON_RUNNER=()
  local -a candidates=()
  local -a cand=()
  local entry label ntok toks head resolved resolved_lc
  local found_stub=0 found_missing=0 found_launch_fail=0

  # 1) REIN_PYTHON override. Hard-fail semantics: set-but-invalid → exit 12.
  if [[ -n "${REIN_PYTHON:-}" ]]; then
    if validate_runner_override "$REIN_PYTHON"; then
      candidates+=("REIN_PYTHON:1:$REIN_PYTHON")
    else
      # Invalid override → fail loudly. Do NOT fall through to other
      # candidates — the user explicitly set this value.
      return 12
    fi
  fi

  # 2) Active venv (POSIX or Windows layout).
  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
      candidates+=("VENV:1:$VIRTUAL_ENV/bin/python")
    elif [[ -x "$VIRTUAL_ENV/Scripts/python.exe" ]]; then
      candidates+=("VENV:1:$VIRTUAL_ENV/Scripts/python.exe")
    fi
  fi

  # 3-4) Standard names.
  candidates+=("python3:1:python3" "python:1:python")

  # 5) Windows launcher — only on MSYS/MINGW/Cygwin.
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      candidates+=("py3:2:py -3")
      ;;
  esac

  for entry in "${candidates[@]}"; do
    # Decode "label:ntok:tokens".
    label="${entry%%:*}"
    entry="${entry#*:}"
    ntok="${entry%%:*}"
    toks="${entry#*:}"

    # ntok=1 → preserve as single token (e.g. "/path with space/python").
    # ntok>=2 → word-split (only for internally-generated "py -3").
    if [[ "$ntok" == "1" ]]; then
      cand=("$toks")
    else
      # shellcheck disable=SC2206
      read -ra cand <<< "$toks"
    fi

    head="${cand[0]}"

    # Candidate must either be an executable path or resolvable via PATH.
    if [[ ! -x "$head" ]] && ! command -v "$head" >/dev/null 2>&1; then
      found_missing=1
      continue
    fi

    # Resolve to absolute path if it came via PATH — needed for WindowsApps
    # detection. If `-x "$head"` already matched, keep as-is (absolute).
    resolved="$head"
    if command -v "$head" >/dev/null 2>&1; then
      resolved=$(command -v "$head" 2>/dev/null)
    fi

    # WindowsApps App Execution Alias stub — case-insensitive.
    resolved_lc=$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]')
    case "$resolved_lc" in
      *windowsapps*)
        found_stub=1
        continue
        ;;
    esac

    # Actually launch it. This is where Windows 9009 stubs that passed
    # `command -v` get caught (exit 49 after 8-bit truncation).
    if ! health_check "${cand[@]}"; then
      found_launch_fail=1
      continue
    fi

    PYTHON_RUNNER=("${cand[@]}")
    # Silence "label unused" static-analysis without relying on shellcheck.
    : "$label" "$found_missing"
    return 0
  done

  if [[ "$found_stub" -eq 1 ]]; then
    return 11
  fi
  if [[ "$found_launch_fail" -eq 1 ]]; then
    return 12
  fi
  return 10
}

# ------------------------------------------------------------
# print_windows_diagnostics_if_applicable
#   Emit a Windows-specific remediation guide to stdout (callers redirect
#   to stderr). No-op on macOS/Linux/WSL2.
# ------------------------------------------------------------
print_windows_diagnostics_if_applicable() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 0 ;;
  esac
  cat <<'MSG'
Windows Git Bash/MSYS 환경에서 Python 런타임을 찾지 못했습니다.

진단:
  command -v python3
  python3 -V
  py -3 -V

해결책 (우선순위 순):
  1) WSL2 로 전환 (README 참조) — rein 의 공식 Windows 지원 경로
  2) Windows Settings → "App execution aliases" 에서 python.exe/python3.exe 끄기
     + 실제 Python (python.org 또는 Python install manager) 설치
  3) PATH 에서 real Python / py launcher 가 WindowsApps 보다 앞서도록 조정
  4) 대안: REIN_PYTHON=/path/to/python3 export 로 명시 지정

참고: python3 exit 49 는 Python JSON 파싱 실패가 아니라 Windows 의 9009
(command/stub 실행 실패) 가 8비트 잘린 값입니다 (9009 mod 256 = 49).
MSG
}
