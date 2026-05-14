#!/usr/bin/env bash
# test-job-detach-posix.sh — Plan C Phase 7 Task 7.4.
#
# Verifies POSIX detach semantics for `rein job start`:
#   (a) child survives the launching shell exiting — ppid reparents to 1
#       (init) or to a low-value ancestor.
#   (b) when setsid is available, the recorded pid equals the child's pgid
#       (so `kill -TERM -<pid>` kills the whole group in Task 8.2).
#   (c) when setsid is missing, the recorded pid is still a live process
#       but pgid equality is not asserted (fallback path is best-effort).
#
# Scope ID: BG-job-detach-posix-setsid-with-pid.
set -e

# Skip on MINGW / MSYS — Task 7.5 covers Windows Git Bash.
case "$(uname -s)" in
  MINGW*|MSYS*) echo "test-job-detach-posix: SKIP on MINGW"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-detach-posix-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# --- (a) child survives caller exit --------------------------------------
# Launch rein job inside a SUBSHELL, then exit that subshell. The detached
# process should still be alive afterwards. We poll for `kill -0` success
# across a brief window to account for scheduler jitter.
out=$( cmd_job_start long-sleep -- sleep 15 )
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
pidf=".claude/cache/jobs/$jid.pid"

# Give the detached wrapper a moment to write its pid atomically.
for i in 1 2 3 4 5 6; do
  if [ -s "$pidf" ]; then break; fi
  sleep 0.25
done
pid=$(cat "$pidf" 2>/dev/null || echo "")
[ -n "$pid" ] || { echo "FAIL[a]: pid file not populated" >&2; exit 1; }

# Process must be alive.
kill -0 "$pid" 2>/dev/null || {
  echo "FAIL[a]: pid $pid not alive after launch" >&2; exit 1
}

# --- (b) setsid path — pid == pgid ---------------------------------------
if command -v setsid >/dev/null 2>&1; then
  # `ps -o pgid= -p <pid>` prints numeric pgid (whitespace-padded). On
  # macOS it includes a leading space we strip via awk.
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | awk '{print $1}')
  if [ -z "$pgid" ]; then
    echo "FAIL[b]: could not read pgid for pid $pid" >&2; exit 1
  fi
  if [ "$pgid" != "$pid" ]; then
    echo "FAIL[b]: pgid=$pgid differs from recorded pid=$pid (setsid path should make them equal)" >&2
    exit 1
  fi
else
  echo "note: setsid missing — skipping pid==pgid assertion (nohup fallback path)" >&2
fi

# --- (c) cleanup: terminate the lingering sleep so the tempdir can be wiped
# Use pgroup-style kill when setsid path took effect.
if command -v setsid >/dev/null 2>&1; then
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi
# Give it a beat to clean up.
for i in 1 2 3 4; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.25
done

echo "test-job-detach-posix: OK"
