#!/usr/bin/env bash
set -euo pipefail

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

info()  { echo -e "${GREEN}$*${NC}" >&2; }
warn()  { echo -e "${YELLOW}$*${NC}" >&2; }
error() { echo -e "${RED}Error: $*${NC}" >&2; }
fatal() { echo -e "${RED}Fatal: $*${NC}" >&2; exit 1; }

VERSION="1.3.0"
TEMPLATE_REPO="${REIN_TEMPLATE_REPO:-${CLAUDE_TEMPLATE_REPO:-git@github.com:JayJihyunKim/rein.git}}"

# ---------------------------------------------------------------------------
# detect_platform()
# Returns "posix" on Linux/Darwin, "windows_git_bash" on MINGW*/MSYS*.
# Exits 1 (prints error to stderr) on unsupported platforms.
# Plan C Task 1.1.
# ---------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Linux|Darwin) echo "posix" ;;
    MINGW*|MSYS*) echo "windows_git_bash" ;;
    *) echo "unsupported: $(uname -s)" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# write_atomic <path> <content>
# Writes <content> to <path> via temp-file + rename, so a concurrent reader
# never sees a partial write. Plan C Task 1.2 (BG-file-state-atomic-write).
#
# The temp-file name combines PID + shell-level-random so concurrent writers
# (running as subshells that inherit $$) don't collide on the staging name.
# ---------------------------------------------------------------------------
write_atomic() {
  local path="$1" content="$2"
  # BASHPID differs in subshells; RANDOM adds extra entropy so parallel
  # invocations inside ( ... ) & ( ... ) & never pick the same tmp path.
  local tmp="${path}.tmp.${BASHPID:-$$}.${RANDOM}${RANDOM}"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$path"
}

# ---------------------------------------------------------------------------
# State / jobs dir helpers — fixed paths, relative to project root.
# Plan C Task 1.2 (BG-file-state-layout).
# ---------------------------------------------------------------------------
rein_jobs_dir() {
  local resolver=""
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/rein-state-paths.py" ]; then
    resolver="$CLAUDE_PLUGIN_ROOT/scripts/rein-state-paths.py"
  fi
  if [ -z "$resolver" ] && [ -f ".rein/project.json" ] && [ -f "plugins/rein-core/scripts/rein-state-paths.py" ]; then
    resolver="plugins/rein-core/scripts/rein-state-paths.py"
  fi
  if [ -z "$resolver" ] && [ -d ".rein/cache" ] && [ -f "plugins/rein-core/scripts/rein-state-paths.py" ]; then
    resolver="plugins/rein-core/scripts/rein-state-paths.py"
  fi
  if [ -n "$resolver" ]; then
    local resolved
    resolved=$(python3 "$resolver" jobs 2>/dev/null || true)
    if [ -n "$resolved" ]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi
  echo ".claude/cache/jobs"
}

# ---------------------------------------------------------------------------
# is_text_file <path>
# Returns 0 if the extension matches rein's snapshot-eligible text set,
# 1 otherwise. Extension match is case-sensitive on purpose — rein's own
# template files always use lowercase extensions, and treating README.MD
# as snapshot-eligible would imply a policy we don't guarantee.
# Plan C Task 2.1 (RU-snapshot-textfile-only).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# usage()
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  rein update                       Show plugin update pointer (use 'claude plugin update rein')
  rein job <subcmd>                 Background job (start|status|stop|tail|list|gc)
  rein --version                    Show version
  rein --help                       Show this help

Environment:
  REIN_TEMPLATE_REPO                Override template repository URL
  CLAUDE_TEMPLATE_REPO              (deprecated) Alias for REIN_TEMPLATE_REPO
EOF
}

# ---------------------------------------------------------------------------
# rein_job_wrapper — completion writer (Task 7.3, BG-job-completion-writer).
# Must be defined at the top so `declare -f rein_job_wrapper` can capture
# its body and hand it to the detached child. The detach paths (POSIX
# setsid / MINGW subshell) re-source this definition inside the child so
# no process-local state is shared with the caller's shell.
#
# Args: pidf exitf statf metaf log -- <command argv...>
# Contract:
#   - writes pid atomically
#   - runs command with stdin redirected to /dev/null (BG-no-interactive-jobs)
#   - writes exit code atomically
#   - flips .status to success|failed
#   - updates meta with finished_at + exit_code
#   - removes .pid on the way out
# ---------------------------------------------------------------------------
rein_job_wrapper() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5"
  shift 5
  # Atomic write: own pid.
  printf '%s' "$$" > "${pidf}.tmp.$$" && mv -f "${pidf}.tmp.$$" "$pidf"
  printf '%s' "running" > "${statf}.tmp.$$" && mv -f "${statf}.tmp.$$" "$statf"
  # Run the command. stdin closed per no-interactive contract. We swallow
  # errexit failure from the command itself — the rc is the signal.
  local rc=0
  "$@" >"$log" 2>&1 </dev/null || rc=$?
  printf '%s' "$rc" > "${exitf}.tmp.$$" && mv -f "${exitf}.tmp.$$" "$exitf"
  local final
  if [ "$rc" -eq 0 ]; then final=success; else final=failed; fi
  printf '%s' "$final" > "${statf}.tmp.$$" && mv -f "${statf}.tmp.$$" "$statf"
  python3 - "$metaf" "$rc" <<'PY' 2>/dev/null || true
import json, os, sys, time
meta_path, rc = sys.argv[1], int(sys.argv[2])
try:
    with open(meta_path) as f:
        m = json.load(f)
except Exception:
    m = {}
m["finished_at"] = int(time.time())
m["exit_code"] = rc
tmp = meta_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(m, f)
os.replace(tmp, meta_path)
PY
  rm -f "$pidf"
}

# ---------------------------------------------------------------------------
# _rein_job_launch — dispatch detach to the platform-specific helper.
# Task 7.2 shell_mode transform happens HERE (plan says: "맨 앞에서 transform
# 먼저 수행") so wrapper remains argv-only and platform paths share the
# already-transformed "$@".
# ---------------------------------------------------------------------------
_rein_job_launch() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5" shell_mode="$6"
  shift 6

  # Task 7.2 (BG-job-start-shell-opt-in): wrap argv in `bash -c <expr>` when
  # the caller passed --shell. Default path is argv-only so shell metachars
  # are literal (BG-job-start-default-argv-transport).
  if [ "$shell_mode" = "1" ]; then
    # Join with a single space. If the caller passed multiple argv after
    # --shell (e.g. `--shell -- foo 'bar baz'`), join them and hand the
    # joined string to bash -c as a single expression. This is lossy for
    # multi-token arrays; callers should supply exactly one expression
    # after --, matching the design.
    local expr="$*"
    set -- bash -c "$expr"
  fi

  local platform
  platform=$(detect_platform) || return $?
  case "$platform" in
    posix)           _rein_job_launch_posix "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" ;;
    windows_git_bash) _rein_job_launch_mingw "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" ;;
    *) echo "unsupported platform: $platform" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _rein_wrapper_script_path — absolute path to the standalone wrapper script.
# Resolves next to rein.sh so it is shippable via COPY_TARGETS and can be
# invoked without re-embedding the wrapper body inside `bash -c "$(declare
# -f …)"` (the heredoc-in-bash-c path runs into nested-quote pitfalls).
# Cached per process.
# ---------------------------------------------------------------------------
_REIN_WRAPPER_SCRIPT=""
_rein_wrapper_script_path() {
  if [ -z "$_REIN_WRAPPER_SCRIPT" ]; then
    local src="${BASH_SOURCE[0]:-$0}"
    local dir
    dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)
    _REIN_WRAPPER_SCRIPT="$dir/rein-job-wrapper.sh"
  fi
  echo "$_REIN_WRAPPER_SCRIPT"
}

# ---------------------------------------------------------------------------
# _rein_job_launch_posix — Task 7.4 (BG-job-detach-posix-setsid-with-pid).
# Uses setsid when available so the child becomes a session leader and the
# recorded pid doubles as the process-group id for cmd_job_stop. Falls back
# to nohup when setsid is missing (rare on modern Linux/Darwin but possible
# in minimal containers).
# ---------------------------------------------------------------------------
_rein_job_launch_posix() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5"
  shift 5
  local wrapper
  wrapper="$(_rein_wrapper_script_path)"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
      </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
      </dev/null >/dev/null 2>&1 &
  fi
  disown "$!" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _rein_job_launch_mingw — Task 7.5 (BG-job-detach-windows-git-bash-subshell-pid).
# MINGW64 / MSYS2 Git Bash usually does not ship setsid. Prefer it when
# present (some installs have it via coreutils); otherwise detach via a
# `( ... & )` subshell so the child reparents off the interactive shell.
# ---------------------------------------------------------------------------
_rein_job_launch_mingw() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5"
  shift 5
  local wrapper
  wrapper="$(_rein_wrapper_script_path)"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
      </dev/null >/dev/null 2>&1 &
  else
    ( bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
        </dev/null >/dev/null 2>&1 & )
  fi
}

# ---------------------------------------------------------------------------
# cmd_job_start — Task 7.1 / 7.2.
# CLI: rein job start <name> [--shell] -- <cmd argv...>
# Returns within ~1s by detaching the job and emitting the id. Argv path
# keeps shell metachars literal; --shell wraps in `bash -c <expr>`.
# ---------------------------------------------------------------------------
cmd_job_start() {
  local name="" shell_mode=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --shell) shell_mode=1; shift ;;
      --)      shift; break ;;
      -*)      echo "unknown flag: $1" >&2; return 2 ;;
      *)       if [ -z "$name" ]; then name="$1"; shift
               else break; fi ;;
    esac
  done
  [ -n "$name" ] || { echo "usage: rein job start <name> [--shell] -- <cmd...>" >&2; return 2; }
  [ $# -gt 0 ]   || { echo "usage: rein job start <name> [--shell] -- <cmd...>" >&2; return 2; }

  local ts hex jid jd
  ts=$(date +%s)
  hex=$(printf '%04x' $((RANDOM & 0xFFFF)))
  jid="${name}-${ts}-${hex}"
  jd="$(rein_jobs_dir)"
  mkdir -p "$jd"

  local metaf="$jd/$jid.json"
  local pidf="$jd/$jid.pid"
  local statf="$jd/$jid.status"
  local exitf="$jd/$jid.exit"
  local log="$jd/$jid.log"

  local transport="argv"
  [ "$shell_mode" = "1" ] && transport="shell"

  local cwd joined_cmd
  cwd="$(pwd)"
  # Join cmd argv into a single representational string for the meta file.
  # This is informational (display in `rein job list`); the real execution
  # always uses the argv vector directly.
  joined_cmd="$*"

  python3 - "$metaf" "$name" "$transport" "$cwd" "$ts" "$joined_cmd" <<'PY'
import json, os, sys
metaf, name, transport, cwd, ts, cmd = sys.argv[1:7]
m = {
    "name": name,
    "transport": transport,
    "cwd": cwd,
    "started_at": int(ts),
    "cmd": cmd,
}
tmp = metaf + ".tmp"
with open(tmp, "w") as f:
    json.dump(m, f)
os.replace(tmp, metaf)
PY

  # Initialise status + log so status probe + tail never hit ENOENT before
  # the wrapper writes its first atomic update.
  write_atomic "$statf" "running"
  : > "$log"

  _rein_job_launch "$pidf" "$exitf" "$statf" "$metaf" "$log" "$shell_mode" "$@"

  echo "started: $jid"
  echo "log: $log"

  # Best-effort async GC so long-lived repos don't accumulate stale logs.
  # Failures (missing python3, concurrent GC, etc.) are swallowed because
  # GC is a hygiene task, not a correctness one.
  ( cmd_job_gc >/dev/null 2>&1 & ) 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# _probe_pid_alive <pid> — Task 8.1.
# Platform-aware liveness probe:
#   POSIX → `kill -0 <pid>` is the canonical "is this pid alive" check.
#   MINGW → `tasklist /FI "PID eq <pid>" /NH /FO CSV` with MSYS2_ARG_CONV_EXCL
#           to stop MSYS rewriting `/FI` into a POSIX path.
# Returns 0 if alive, 1 if not, 2 on unsupported platform.
# ---------------------------------------------------------------------------
_probe_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  local platform
  platform=$(detect_platform) || return 2
  case "$platform" in
    posix)
      kill -0 "$pid" 2>/dev/null
      ;;
    windows_git_bash)
      MSYS2_ARG_CONV_EXCL="*" tasklist /FI "PID eq $pid" /NH /FO CSV 2>/dev/null \
        | grep -q ",\"$pid\","
      ;;
    *) return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_job_status <jid> — Task 8.1 (BG-job-status-running-check).
# Prints status + (for settled jobs) exit + duration. Detects stale jobs
# whose .status is still "running" but whose recorded pid is no longer alive;
# rewrites state files to "unknown_dead" and reports that.
# ---------------------------------------------------------------------------
cmd_job_status() {
  local jid="${1:-}"
  [ -n "$jid" ] || { echo "usage: rein job status <job-id>" >&2; return 2; }
  local jd; jd="$(rein_jobs_dir)"
  local metaf="$jd/$jid.json"
  local statf="$jd/$jid.status"
  local pidf="$jd/$jid.pid"
  local exitf="$jd/$jid.exit"
  [ -f "$metaf" ] || { echo "unknown job: $jid" >&2; return 2; }

  local status
  status=$(cat "$statf" 2>/dev/null || echo "unknown")

  # Stale detection — .status claims running but no live pid behind it.
  if [ "$status" = "running" ]; then
    local pid
    pid=$(cat "$pidf" 2>/dev/null || echo "")
    if [ -n "$pid" ] && ! _probe_pid_alive "$pid"; then
      write_atomic "$statf" "unknown_dead"
      write_atomic "$exitf" "-1"
      status="unknown_dead"
    elif [ -z "$pid" ] && [ ! -f "$pidf" ]; then
      # .pid missing but .status=running — wrapper exited between our reads
      # or a partial start. Trust the .exit if present; otherwise mark dead.
      if [ -f "$exitf" ]; then
        local ec
        ec=$(cat "$exitf")
        if [ "$ec" = "0" ]; then
          write_atomic "$statf" "success"; status="success"
        else
          write_atomic "$statf" "failed"; status="failed"
        fi
      else
        write_atomic "$statf" "unknown_dead"
        write_atomic "$exitf" "-1"
        status="unknown_dead"
      fi
    fi
  fi

  python3 - "$metaf" "$status" "$exitf" <<'PY'
import json, os, sys, time
metaf, status, exitf = sys.argv[1:4]
try:
    with open(metaf) as f: m = json.load(f)
except Exception:
    m = {}
started = m.get("started_at", 0)
finished = m.get("finished_at")
print(f"status: {status}")
if status == "running":
    age = int(time.time()) - started if started else 0
    print(f"  (started {age}s ago)")
else:
    ec = m.get("exit_code")
    if ec is None and os.path.exists(exitf):
        try: ec = open(exitf).read().strip()
        except Exception: ec = "?"
    if ec is None: ec = "?"
    print(f"exit: {ec}")
    if finished and started:
        print(f"duration: {int(finished) - int(started)}s")
PY
  return 0
}

# ---------------------------------------------------------------------------
# cmd_job_stop_posix <pid> — Task 8.2 (BG-job-stop-posix-process-group).
# Sends SIGTERM to the process group (`kill -TERM -<pid>`), waits briefly
# for graceful shutdown, escalates to SIGKILL if still alive. When the
# pgroup signal fails (job started without setsid — pid is not a pgid),
# falls back to single-pid kill and warns once on stderr.
# ---------------------------------------------------------------------------
cmd_job_stop_posix() {
  local pid="$1"
  local target
  if kill -TERM "-$pid" 2>/dev/null; then
    echo "sent SIGTERM to process group $pid"
    target="-$pid"
  else
    echo "warning: job started without setsid; killing single PID only" >&2
    kill -TERM "$pid" 2>/dev/null || true
    target="$pid"
  fi

  local i
  for i in 1 2 3 4 5 6 7 8; do
    if ! _probe_pid_alive "$pid"; then
      echo "pid $pid exited gracefully"
      return 0
    fi
    sleep 0.25
  done

  # Escalate.
  if kill -KILL "$target" 2>/dev/null; then
    echo "escalated to SIGKILL"
  else
    # Target gone on its own between the wait and the escalate — still OK.
    :
  fi
  for i in 1 2 3 4; do
    _probe_pid_alive "$pid" || return 0
    sleep 0.25
  done
  echo "warning: pid $pid still alive after SIGKILL" >&2
  return 1
}

# ---------------------------------------------------------------------------
# cmd_job_stop_mingw <pid> — Task 8.3 (BG-job-stop-windows-git-bash-tree).
# SIGTERM first (respected on MINGW by processes spawned via Git Bash),
# then `taskkill /F /T /PID` to tree-kill on Windows if the pid is still
# alive. /T walks the child tree; /F forces termination.
# ---------------------------------------------------------------------------
cmd_job_stop_mingw() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if ! _probe_pid_alive "$pid"; then
      echo "pid $pid exited gracefully"
      return 0
    fi
    sleep 0.25
  done
  if MSYS2_ARG_CONV_EXCL="*" taskkill /F /T /PID "$pid" >/dev/null 2>&1; then
    echo "escalated to taskkill /F /T"
  fi
  for i in 1 2 3 4; do
    _probe_pid_alive "$pid" || return 0
    sleep 0.25
  done
  echo "warning: pid $pid still alive after taskkill" >&2
  return 1
}

# ---------------------------------------------------------------------------
# cmd_job_stop <jid> — dispatcher (Task 8.2/8.3).
# ---------------------------------------------------------------------------
cmd_job_stop() {
  local jid="${1:-}"
  [ -n "$jid" ] || { echo "usage: rein job stop <job-id>" >&2; return 2; }
  local jd; jd="$(rein_jobs_dir)"
  local pidf="$jd/$jid.pid"
  local metaf="$jd/$jid.json"
  if [ ! -f "$metaf" ]; then
    echo "unknown job: $jid" >&2; return 2
  fi
  if [ ! -f "$pidf" ]; then
    echo "job not running or already finished: $jid" >&2; return 2
  fi
  local pid
  pid=$(cat "$pidf" 2>/dev/null || echo "")
  [ -n "$pid" ] || { echo "pid file empty for $jid" >&2; return 2; }

  local platform
  platform=$(detect_platform) || return 2
  case "$platform" in
    posix)           cmd_job_stop_posix "$pid" ;;
    windows_git_bash) cmd_job_stop_mingw "$pid" ;;
    *) echo "unsupported platform for stop" >&2; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_job_tail <jid> [--lines N] — Task 8.4 (BG-job-tail-default-50-lines).
# Prints the last N lines of the job log (default 50). Shorter logs are
# printed in full; no error on jobs still writing.
# ---------------------------------------------------------------------------
cmd_job_tail() {
  local jid="" n=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) n="${2:-}"; shift 2 ;;
      -*) echo "unknown flag: $1" >&2; return 2 ;;
      *)  if [ -z "$jid" ]; then jid="$1"; shift
          else echo "unexpected arg: $1" >&2; return 2; fi ;;
    esac
  done
  [ -n "$jid" ] || { echo "usage: rein job tail <job-id> [--lines N]" >&2; return 2; }
  case "$n" in ''|*[!0-9]*) echo "--lines must be a positive integer" >&2; return 2 ;; esac
  local log; log="$(rein_jobs_dir)/$jid.log"
  [ -f "$log" ] || { echo "no log for job: $jid" >&2; return 2; }
  tail -n "$n" "$log"
}

# ---------------------------------------------------------------------------
# cmd_job_list — Task 8.5 (BG-job-list-split-running-recent).
# Two-section output: RUNNING (currently live jobs) + RECENT (last 10
# finished, most recently started first). Empty sections still print their
# headers so downstream tools can pipe safely.
# ---------------------------------------------------------------------------
cmd_job_list() {
  local jd; jd="$(rein_jobs_dir)"
  if [ ! -d "$jd" ]; then
    echo "RUNNING:"
    echo "RECENT:"
    return 0
  fi
  python3 - "$jd" <<'PY'
import json, os, sys, glob
jd = sys.argv[1]
jobs = []
for metaf in sorted(glob.glob(os.path.join(jd, "*.json"))):
    try:
        with open(metaf) as f: m = json.load(f)
    except Exception:
        continue
    base = os.path.basename(metaf)
    jid = base[:-5] if base.endswith(".json") else base
    statf = metaf[:-5] + ".status"
    status = "unknown"
    if os.path.exists(statf):
        try: status = open(statf).read().strip()
        except Exception: pass
    jobs.append({"jid": jid, "status": status, **m})
running = [j for j in jobs if j.get("status") == "running"]
recent  = [j for j in jobs if j.get("status") != "running"]
recent.sort(key=lambda x: -x.get("started_at", 0))
recent = recent[:10]
print("RUNNING:")
for j in running:
    print(f"  {j['jid']}  (started {j.get('started_at','?')})")
print("RECENT:")
for j in recent:
    ec = j.get("exit_code", "?")
    print(f"  {j['jid']}  {j.get('status','?')}({ec})")
PY
}

# ---------------------------------------------------------------------------
# cmd_job_gc — Task 8.6 (BG-cleanup-gc).
# Two-tier retention:
#   - .log    kept for 7 days after finished_at
#   - .json / .exit / .status kept for 30 days
# .pid is always absent by the time we run (wrapper removes it), so this
# function does not try to touch it. Silently skips still-running jobs.
#
# Called both via `rein job gc` and asynchronously from `rein job start`
# so long-lived repos don't accumulate stale logs.
# ---------------------------------------------------------------------------
cmd_job_gc() {
  local jd; jd="$(rein_jobs_dir)"
  [ -d "$jd" ] || return 0
  python3 - "$jd" <<'PY'
import json, os, sys, time, glob
jd = sys.argv[1]
now = time.time()
for metaf in glob.glob(os.path.join(jd, "*.json")):
    try:
        with open(metaf) as f: m = json.load(f)
    except Exception:
        continue
    finished = m.get("finished_at")
    if not finished:
        continue  # still running — skip
    age_days = (now - float(finished)) / 86400.0
    base = metaf[:-5]  # strip .json
    if age_days > 7:
        for ext in (".log",):
            p = base + ext
            if os.path.exists(p):
                try: os.remove(p)
                except OSError: pass
    if age_days > 30:
        for ext in (".json", ".exit", ".status"):
            p = base + ext
            if os.path.exists(p):
                try: os.remove(p)
                except OSError: pass
PY
}

# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------
main() {
  # Preserve original argv for potential exec re-run after self-update
  ORIGINAL_ARGV=("$@")

  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    merge|update)
      echo 'plugin 모드는 `claude plugin update rein` 를 사용하세요. 자세한 내용: https://github.com/JayJihyunKim/rein'
      exit 0
      ;;
    job)
      shift
      if [[ $# -eq 0 ]]; then
        error "rein job requires a subcommand (start|status|stop|tail|list|gc)"
        exit 1
      fi
      local subcmd="$1"; shift
      case "$subcmd" in
        start)  cmd_job_start "$@" ;;
        status) cmd_job_status "$@" ;;
        stop)   cmd_job_stop "$@" ;;
        tail)   cmd_job_tail "$@" ;;
        list)   cmd_job_list "$@" ;;
        gc)     cmd_job_gc "$@" ;;
        *)
          error "unknown job subcommand '$subcmd' (want: start|status|stop|tail|list|gc)"
          exit 1
          ;;
      esac
      ;;
    --version|-v)
      echo "rein $VERSION"
      ;;
    --help|-h)
      usage
      ;;
    *)
      error "unknown command '$1'"
      usage
      exit 1
      ;;
  esac
}

# --source-only mode — tests source this file to load functions without running main.
# Example: `source scripts/rein.sh --source-only` then invoke detect_platform etc.
# Plan C Task 1.1.
if [[ "${1:-}" == "--source-only" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Only invoke main when executed directly. Tests can source this file with
# REIN_SOURCED=1 to load all functions without triggering main.
if [[ "${REIN_SOURCED:-0}" != "1" ]]; then
  main "$@"
fi
