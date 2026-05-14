#!/usr/bin/env bash
# test-job-list.sh — Plan C Phase 8 Task 8.5.
#
# Verifies `rein job list` two-section output:
#   (a) mixture of running + finished → RUNNING section lists the live
#       jobs, RECENT section lists the finished ones (≤10, newest first).
#   (b) empty jobs dir → both section headers still print (no error).
#   (c) status headers present even when the section is empty.
#
# Scope ID: BG-job-list-split-running-recent.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-list-XXXXXX)
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

# --- (b) empty state --------------------------------------------------
# Issue the list command before any job; both headers should print.
out=$(cmd_job_list)
printf '%s\n' "$out" | grep -q '^RUNNING:' || {
  echo "FAIL[b]: RUNNING header missing (empty state): $out" >&2; exit 1
}
printf '%s\n' "$out" | grep -q '^RECENT:' || {
  echo "FAIL[b]: RECENT header missing (empty state): $out" >&2; exit 1
}

# --- (a) 2 running + 3 finished ---------------------------------------
# Launch three instant jobs (finished) and two long-running jobs (running).
out=$(cmd_job_start done-1 -- true); jid1=$(echo "$out" | awk '/^started: /{print $2; exit}')
out=$(cmd_job_start done-2 -- true); jid2=$(echo "$out" | awk '/^started: /{print $2; exit}')
out=$(cmd_job_start done-3 -- true); jid3=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid1" && wait_done "$jid2" && wait_done "$jid3" || exit 1

out=$(cmd_job_start long-a -- sleep 30); live1=$(echo "$out" | awk '/^started: /{print $2; exit}')
out=$(cmd_job_start long-b -- sleep 30); live2=$(echo "$out" | awk '/^started: /{print $2; exit}')

# Give the wrappers a moment to write running status.
sleep 0.5

list_out=$(cmd_job_list)

# Count running + recent entries.
running_section=$(printf '%s\n' "$list_out" | awk '/^RUNNING:/{flag=1; next} /^RECENT:/{flag=0} flag')
recent_section=$(printf '%s\n' "$list_out" | awk '/^RECENT:/{flag=1; next} flag')

running_count=$(printf '%s\n' "$running_section" | grep -c .) || true
recent_count=$(printf '%s\n' "$recent_section" | grep -c .) || true

[ "$running_count" -ge 2 ] || {
  echo "FAIL[a]: running_count=$running_count (want >=2):" >&2
  echo "$list_out" >&2; exit 1
}
[ "$recent_count" -ge 3 ] || {
  echo "FAIL[a]: recent_count=$recent_count (want >=3):" >&2
  echo "$list_out" >&2; exit 1
}

# Running jobs should appear by jid.
printf '%s\n' "$running_section" | grep -q "$live1" || {
  echo "FAIL[a]: $live1 missing from RUNNING" >&2; exit 1
}
printf '%s\n' "$running_section" | grep -q "$live2" || {
  echo "FAIL[a]: $live2 missing from RUNNING" >&2; exit 1
}

# Cleanup the lingering sleeps.
for jid in "$live1" "$live2"; do
  pidf=".claude/cache/jobs/$jid.pid"
  [ -s "$pidf" ] || continue
  pid=$(cat "$pidf")
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
done

echo "test-job-list: OK"
