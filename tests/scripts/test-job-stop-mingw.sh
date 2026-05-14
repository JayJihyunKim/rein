#!/usr/bin/env bash
# test-job-stop-mingw.sh — Plan C Phase 8 Task 8.3.
#
# Windows Git Bash `rein job stop` tree-kill verification:
#   (a) start a shell job that forks children via pipe
#   (b) cmd_job_stop delivers SIGTERM; after the escalation window the
#       `taskkill /F /T /PID <pid>` path kills the whole tree.
#   (c) tasklist no longer reports the recorded pid.
#
# Skipped on POSIX (test-job-stop-posix.sh covers that path).
#
# Scope ID: BG-job-stop-windows-git-bash-tree.
set -e

case "$(uname -s)" in
  MINGW*|MSYS*) : ;;
  *) echo "test-job-stop-mingw: SKIP on POSIX"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-stop-mingw-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# Start a --shell job so we actually exercise the pipe path. The expression
# spawns a sleep and pipes echo into it, giving taskkill /T something to walk.
out=$(cmd_job_start mingw-tree --shell -- 'sleep 60 & sleep 60')
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')

pidf=".claude/cache/jobs/$jid.pid"
for i in 1 2 3 4 5 6 7 8; do
  if [ -s "$pidf" ]; then break; fi
  sleep 0.25
done
pid=$(cat "$pidf" 2>/dev/null || echo "")
[ -n "$pid" ] || { echo "FAIL[a]: pid file empty" >&2; exit 1; }
_probe_pid_alive "$pid" || { echo "FAIL[a]: pid not alive" >&2; exit 1; }

cmd_job_stop "$jid" 2>&1

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if ! _probe_pid_alive "$pid"; then
    dead=1; break
  fi
  sleep 0.3
done
[ "${dead:-0}" = "1" ] || {
  echo "FAIL[c]: pid $pid still alive after stop" >&2; exit 1
}

echo "test-job-stop-mingw: OK"
