#!/usr/bin/env bash
# test-job-gc.sh — Plan C Phase 8 Task 8.6.
#
# Verifies `rein job gc` retention policy:
#   (a) 8 days old → .log deleted, meta/status/exit preserved
#   (b) 31 days old → all state files deleted
#   (c) running job (no finished_at) → untouched
#   (d) auto-GC on `rein job start` does not block the returning shell
#       (implicit: start should stay <2s even with pre-seeded old jobs)
#
# Scope ID: BG-cleanup-gc.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-gc-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

jd=".claude/cache/jobs"
mkdir -p "$jd"
now=$(date +%s)

# --- (a) seed an 8-day-old finished job ---------------------------------
eight_days_ago=$(( now - 8 * 86400 ))
old8="stale8-42-abcd"
cat > "$jd/$old8.json" <<JSON
{"name":"stale8","cwd":"$tmp","started_at":$(( eight_days_ago - 10 )),"finished_at":$eight_days_ago,"transport":"argv","cmd":"true","exit_code":0}
JSON
printf '%s' "success" > "$jd/$old8.status"
printf '%s' "0" > "$jd/$old8.exit"
printf '%s\n' "old log line" > "$jd/$old8.log"

# --- (b) seed a 31-day-old finished job --------------------------------
thirtyone_days_ago=$(( now - 31 * 86400 ))
old31="stale31-42-cafe"
cat > "$jd/$old31.json" <<JSON
{"name":"stale31","cwd":"$tmp","started_at":$(( thirtyone_days_ago - 10 )),"finished_at":$thirtyone_days_ago,"transport":"argv","cmd":"true","exit_code":0}
JSON
printf '%s' "success" > "$jd/$old31.status"
printf '%s' "0" > "$jd/$old31.exit"
printf '%s\n' "ancient log line" > "$jd/$old31.log"

# --- (c) seed a running job (no finished_at) ---------------------------
run_jid="running-42-feed"
cat > "$jd/$run_jid.json" <<JSON
{"name":"running","cwd":"$tmp","started_at":$(( now - 10 )),"transport":"argv","cmd":"sleep 999"}
JSON
printf '%s' "running" > "$jd/$run_jid.status"
# No .exit, no .pid (or a stale one) — the GC should not touch running jobs.

# Run GC.
cmd_job_gc

# --- assertions -------------------------------------------------------
# 8-day-old: .log gone, other state preserved.
[ ! -f "$jd/$old8.log" ] || {
  echo "FAIL[a]: 8-day-old log should be deleted" >&2; exit 1
}
[ -f "$jd/$old8.json" ] || {
  echo "FAIL[a]: 8-day-old meta should survive" >&2; exit 1
}
[ -f "$jd/$old8.status" ] || {
  echo "FAIL[a]: 8-day-old .status should survive" >&2; exit 1
}

# 31-day-old: everything gone.
[ ! -f "$jd/$old31.json" ] || {
  echo "FAIL[b]: 31-day-old meta should be deleted" >&2; exit 1
}
[ ! -f "$jd/$old31.status" ] || {
  echo "FAIL[b]: 31-day-old .status should be deleted" >&2; exit 1
}
[ ! -f "$jd/$old31.log" ] || {
  echo "FAIL[b]: 31-day-old .log should be deleted" >&2; exit 1
}

# Running job untouched.
[ -f "$jd/$run_jid.json" ] || {
  echo "FAIL[c]: running job meta was deleted" >&2; exit 1
}
[ -f "$jd/$run_jid.status" ] || {
  echo "FAIL[c]: running job status was deleted" >&2; exit 1
}

# --- (d) auto-GC on start: launching a new job does not error and is fast -
t_start=$(date +%s)
out=$(cmd_job_start auto-gc-check -- true)
t_end=$(date +%s)
elapsed=$(( t_end - t_start ))
[ "$elapsed" -le 2 ] || {
  echo "FAIL[d]: cmd_job_start took ${elapsed}s with auto-GC (want <=2s)" >&2
  exit 1
}
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
[ -n "$jid" ] || { echo "FAIL[d]: start returned without jid" >&2; exit 1; }

# Wait briefly for any async GC children spawned by cmd_job_start to exit
# before the trap tries to rm -rf our tempdir. Without this the trap hits
# "Directory not empty" intermittently and the surrounding test harness
# sometimes inherits a non-zero exit from the rm. Poll cheaply rather than
# sleep unconditionally.
for i in 1 2 3 4 5 6 7 8; do
  pending=$(find "$tmp" -name '*.tmp.*' 2>/dev/null | wc -l | awk '{print $1}')
  [ "$pending" = "0" ] && break
  sleep 0.25
done

echo "test-job-gc: OK"
