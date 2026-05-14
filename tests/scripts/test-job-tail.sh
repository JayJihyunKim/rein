#!/usr/bin/env bash
# test-job-tail.sh — Plan C Phase 8 Task 8.4.
#
# Verifies `rein job tail` (default 50 lines, --lines N override):
#   (a) 100-line log → tail default → 50 lines, last 50 in order
#   (b) --lines 30 → 30 lines
#   (c) --lines 10 on a 5-line log → 5 lines (no padding)
#   (d) unknown job → non-zero with 'no log' message
#   (e) invalid --lines → non-zero
#
# Scope ID: BG-job-tail-default-50-lines.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-tail-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

wait_done() {
  local jid="$1" i s
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    s=$(cat ".claude/cache/jobs/$jid.status" 2>/dev/null || echo "")
    case "$s" in success|failed|unknown_dead) return 0 ;; esac
    sleep 0.3
  done
  return 1
}

# --- (a) 100-line job, default tail ------------------------------------
out=$(cmd_job_start tail-big --shell -- 'for i in $(seq 1 100); do echo line-$i; done')
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || { echo "FAIL[a-setup]: job did not finish" >&2; exit 1; }

lines=$(cmd_job_tail "$jid" | wc -l | awk '{print $1}')
[ "$lines" = "50" ] || {
  echo "FAIL[a]: tail default produced $lines lines (want 50)" >&2; exit 1
}
first=$(cmd_job_tail "$jid" | head -1)
last=$(cmd_job_tail "$jid" | tail -1)
[ "$first" = "line-51" ] || { echo "FAIL[a]: first line '$first' want 'line-51'" >&2; exit 1; }
[ "$last" = "line-100" ] || { echo "FAIL[a]: last line '$last' want 'line-100'" >&2; exit 1; }

# --- (b) --lines 30 ----------------------------------------------------
lines=$(cmd_job_tail "$jid" --lines 30 | wc -l | awk '{print $1}')
[ "$lines" = "30" ] || {
  echo "FAIL[b]: --lines 30 produced $lines lines" >&2; exit 1
}

# --- (c) small log + --lines 10 ---------------------------------------
out=$(cmd_job_start tail-small --shell -- 'for i in 1 2 3 4 5; do echo small-$i; done')
jid2=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid2" || exit 1
lines=$(cmd_job_tail "$jid2" --lines 10 | wc -l | awk '{print $1}')
[ "$lines" = "5" ] || {
  echo "FAIL[c]: --lines 10 on 5-line log produced $lines" >&2; exit 1
}

# --- (d) unknown job ---------------------------------------------------
rc=0
out=$(cmd_job_tail nope 2>&1) || rc=$?
[ "$rc" != "0" ] || { echo "FAIL[d]: unknown job returned rc=0" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'no log' || {
  echo "FAIL[d]: expected 'no log' message: $out" >&2; exit 1
}

# --- (e) invalid --lines ----------------------------------------------
rc=0
out=$(cmd_job_tail "$jid" --lines abc 2>&1) || rc=$?
[ "$rc" != "0" ] || { echo "FAIL[e]: invalid --lines returned rc=0" >&2; exit 1; }

echo "test-job-tail: OK"
