#!/usr/bin/env bash
# test-job-completion-wrapper.sh — Plan C Phase 7 Task 7.3.
#
# Verifies the rein-job-wrapper.sh completion contract:
#   (a) success path: .status=success, .exit=0, finished_at+exit_code in meta,
#                     .pid removed.
#   (b) failure path: .status=failed, .exit=1.
#   (c) atomicity:    .status never observed as ".tmp.*" — atomic writes
#                     never leak the staging name to readers.
#
# Scope IDs: BG-job-completion-writer, BG-file-state-atomic-write.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-wrapper-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

wait_done() {
  local jid="$1" i s
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s=$(cat ".claude/cache/jobs/$jid.status" 2>/dev/null || echo "")
    case "$s" in success|failed|unknown_dead) return 0 ;; esac
    sleep 0.3
  done
  echo "wait_done: timed out for $jid" >&2
  return 1
}

# --- (a) success path -----------------------------------------------------
out=$(cmd_job_start ok -- true)
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1

jd=".claude/cache/jobs"
[ "$(cat $jd/$jid.status)" = "success" ] || {
  echo "FAIL[a]: status='$(cat $jd/$jid.status)' want='success'" >&2; exit 1
}
[ "$(cat $jd/$jid.exit)" = "0" ] || {
  echo "FAIL[a]: exit='$(cat $jd/$jid.exit)' want='0'" >&2; exit 1
}
[ ! -f "$jd/$jid.pid" ] || {
  echo "FAIL[a]: .pid should be removed after completion" >&2; exit 1
}
# finished_at + exit_code in meta
python3 - "$jd/$jid.json" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1]))
if "finished_at" not in m:
    print("FAIL[a]: meta lacks finished_at", file=sys.stderr); sys.exit(1)
if m.get("exit_code") != 0:
    print(f"FAIL[a]: meta.exit_code={m.get('exit_code')}", file=sys.stderr); sys.exit(1)
PY

# --- (b) failure path -----------------------------------------------------
out=$(cmd_job_start fail -- false)
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1

[ "$(cat $jd/$jid.status)" = "failed" ] || {
  echo "FAIL[b]: status='$(cat $jd/$jid.status)' want='failed'" >&2; exit 1
}
[ "$(cat $jd/$jid.exit)" = "1" ] || {
  echo "FAIL[b]: exit='$(cat $jd/$jid.exit)' want='1'" >&2; exit 1
}

# --- (c) atomicity: no .tmp.* status leak --------------------------------
# Launch a quick job and poll .status many times; should never see a tmp
# staging filename.
out=$(cmd_job_start atomic -- bash -c 'for i in 1 2 3; do echo $i; done')
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  s=$(cat "$jd/$jid.status" 2>/dev/null || echo "")
  case "$s" in
    *tmp*) echo "FAIL[c]: observed tmp-staged status: '$s'" >&2; exit 1 ;;
  esac
done
wait_done "$jid" || exit 1

echo "test-job-completion-wrapper: OK"
