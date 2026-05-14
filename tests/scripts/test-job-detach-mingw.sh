#!/usr/bin/env bash
# test-job-detach-mingw.sh — Plan C Phase 7 Task 7.5.
#
# Windows Git Bash (MINGW64 / MSYS2) detach verification:
#   (a) cmd_job_start returns quickly and writes a live pid file
#   (b) the pid is alive per `tasklist /FI "PID eq ..." /NH /FO CSV`
#
# Skipped on POSIX — the setsid/nohup path is covered by
# test-job-detach-posix.sh.
#
# Scope ID: BG-job-detach-windows-git-bash-subshell-pid.
set -e

case "$(uname -s)" in
  MINGW*|MSYS*) : ;;
  *) echo "test-job-detach-mingw: SKIP on POSIX"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-detach-mingw-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

out=$(cmd_job_start long-sleep -- sleep 15)
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
pidf=".claude/cache/jobs/$jid.pid"

# Allow the wrapper to atomically publish its pid.
for i in 1 2 3 4 5 6 7 8; do
  if [ -s "$pidf" ]; then break; fi
  sleep 0.25
done
pid=$(cat "$pidf" 2>/dev/null || echo "")
[ -n "$pid" ] || { echo "FAIL: pid file never populated" >&2; exit 1; }

# Probe via tasklist. `MSYS2_ARG_CONV_EXCL=*` stops MSYS from rewriting the
# `/FI` Windows-style switch into a POSIX path.
if ! MSYS2_ARG_CONV_EXCL="*" tasklist /FI "PID eq $pid" /NH /FO CSV 2>/dev/null \
     | grep -q ",\"$pid\","; then
  echo "FAIL: pid $pid not reported live by tasklist" >&2
  exit 1
fi

# Cleanup — taskkill /T to kill the tree.
MSYS2_ARG_CONV_EXCL="*" taskkill /F /T /PID "$pid" >/dev/null 2>&1 || true

echo "test-job-detach-mingw: OK"
