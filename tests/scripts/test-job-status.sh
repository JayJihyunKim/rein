#!/usr/bin/env bash
# test-job-status.sh — Plan C Phase 8 Task 8.1.
#
# Verifies `rein job status <jid>` output + stale PID detection:
#   (a) completed success job → "status: success", "exit: 0", duration line
#   (b) completed failure job → "status: failed", "exit: N"
#   (c) unknown job id → exit != 0 with "unknown job" stderr
#   (d) stale: .status=running but no live pid → .status rewritten to
#       "unknown_dead", .exit set to -1, output reports "unknown_dead"
#
# Scope ID: BG-job-status-running-check.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-status-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

wait_done() {
  local jid="$1" i s
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s=$(cat ".claude/cache/jobs/$jid.status" 2>/dev/null || echo "")
    case "$s" in success|failed|unknown_dead) return 0 ;; esac
    sleep 0.3
  done
  return 1
}

# --- (a) success path ------------------------------------------------------
out=$(cmd_job_start ok -- true)
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || { echo "FAIL[a-setup]: job did not complete" >&2; exit 1; }

s_out=$(cmd_job_status "$jid" 2>&1) || {
  echo "FAIL[a]: cmd_job_status rc != 0: $s_out" >&2; exit 1
}
printf '%s\n' "$s_out" | grep -q 'status: success' || {
  echo "FAIL[a]: missing 'status: success' in output: $s_out" >&2; exit 1
}
printf '%s\n' "$s_out" | grep -q 'exit: 0' || {
  echo "FAIL[a]: missing 'exit: 0' in output: $s_out" >&2; exit 1
}

# --- (b) failure path -----------------------------------------------------
out=$(cmd_job_start fail -- false)
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1

s_out=$(cmd_job_status "$jid" 2>&1)
printf '%s\n' "$s_out" | grep -q 'status: failed' || {
  echo "FAIL[b]: missing 'status: failed': $s_out" >&2; exit 1
}
printf '%s\n' "$s_out" | grep -q 'exit: 1' || {
  echo "FAIL[b]: missing 'exit: 1': $s_out" >&2; exit 1
}

# --- (c) unknown job id ---------------------------------------------------
rc=0
out=$(cmd_job_status this-is-not-a-real-job 2>&1) || rc=$?
[ "$rc" != "0" ] || { echo "FAIL[c]: unknown job returned rc=0" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'unknown job' || {
  echo "FAIL[c]: expected 'unknown job' in stderr: $out" >&2; exit 1
}

# --- (d) stale PID detection ---------------------------------------------
# Fabricate a stale job: meta + status=running + pid pointing at a dead
# process (use a PID recycled from a short-lived subshell so `kill -0` fails).
dead_pid=$( (sleep 0.01 & echo $!) )
# Give that sleep time to exit so we know the pid is gone by the time
# cmd_job_status probes it.
sleep 0.3
# PID may have been recycled — retry a couple of times if it's somehow alive.
for attempt in 1 2 3; do
  if kill -0 "$dead_pid" 2>/dev/null; then
    dead_pid=$( (sleep 0.01 & echo $!) )
    sleep 0.3
  else
    break
  fi
done
kill -0 "$dead_pid" 2>/dev/null && {
  echo "FAIL[d-setup]: could not synthesize a dead pid" >&2
  exit 1
}

jd=".claude/cache/jobs"
mkdir -p "$jd"
stale_jid="stale-9999-beef"
cat > "$jd/$stale_jid.json" <<JSON
{"name":"stale","transport":"argv","cwd":"$tmp","started_at":$(( $(date +%s) - 30 )),"cmd":"mocked"}
JSON
printf '%s' "running" > "$jd/$stale_jid.status"
printf '%s' "$dead_pid" > "$jd/$stale_jid.pid"

s_out=$(cmd_job_status "$stale_jid" 2>&1) || true
printf '%s\n' "$s_out" | grep -q 'unknown_dead' || {
  echo "FAIL[d]: expected 'unknown_dead' in output: $s_out" >&2; exit 1
}
[ "$(cat $jd/$stale_jid.status)" = "unknown_dead" ] || {
  echo "FAIL[d]: .status not updated to unknown_dead: $(cat $jd/$stale_jid.status)" >&2
  exit 1
}
[ "$(cat $jd/$stale_jid.exit)" = "-1" ] || {
  echo "FAIL[d]: .exit not set to -1: $(cat $jd/$stale_jid.exit)" >&2
  exit 1
}

echo "test-job-status: OK"
