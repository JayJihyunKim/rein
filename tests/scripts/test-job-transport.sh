#!/usr/bin/env bash
# test-job-transport.sh — Plan C Phase 7 Task 7.2.
#
# Verifies `rein job start` transport behavior:
#   (a) argv default: shell metachars stay literal
#   (b) argv default: word splitting preserved (quoted args stay intact)
#   (c) --shell opt-in: `$VAR` expansion happens
#   (d) stdin is closed (BG-no-interactive-jobs): `read x` returns immediately
#
# Scope IDs: BG-job-start-default-argv-transport,
#            BG-job-start-shell-opt-in,
#            BG-no-interactive-jobs.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-transport-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# Wait helper — polls for .status to flip off "running", capped at 5s.
wait_done() {
  local jid="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local s
    s=$(cat ".claude/cache/jobs/$jid.status" 2>/dev/null || echo "")
    case "$s" in
      success|failed|unknown_dead) return 0 ;;
    esac
    sleep 0.5
  done
  echo "wait_done: timed out for $jid" >&2
  return 1
}

# --- (a) argv default: multi-word echo stays coherent ---------------------
out=$(cmd_job_start echo-words -- echo "hello world")
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1
log=$(cat ".claude/cache/jobs/$jid.log")
[ "$log" = "hello world" ] || {
  echo "FAIL[a]: log='$log' want='hello world'" >&2; exit 1
}

# --- (b) argv default: shell metachars are literal -----------------------
# With argv transport, `$HOME` should print literally — echo receives the
# 5-character string `$HOME`, not the expanded path.
out=$(cmd_job_start echo-literal -- echo '$HOME')
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1
log=$(cat ".claude/cache/jobs/$jid.log")
[ "$log" = '$HOME' ] || {
  echo "FAIL[b]: log='$log' want='\$HOME' (argv should not expand)" >&2; exit 1
}

# --- (c) --shell opt-in: $HOME expands ----------------------------------
out=$(cmd_job_start echo-expand --shell -- 'echo $HOME')
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1
log=$(cat ".claude/cache/jobs/$jid.log")
# $HOME is always an absolute path that starts with '/'. Asserting exact
# equality would couple the test to the CI user's home; presence is
# sufficient evidence of expansion.
case "$log" in
  /*) : ;;
  *) echo "FAIL[c]: --shell did not expand \$HOME; log='$log'" >&2; exit 1 ;;
esac

# --- (d) stdin is closed ---------------------------------------------------
# `read x` on a closed stdin returns non-zero immediately and x stays empty,
# so `got=` is what the log must contain. If stdin were left open the
# wrapper would block forever and our wait_done poll would time out.
out=$(cmd_job_start read-stdin -- bash -c 'read x; echo got=$x')
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
wait_done "$jid" || exit 1
log=$(cat ".claude/cache/jobs/$jid.log")
[ "$log" = "got=" ] || {
  echo "FAIL[d]: log='$log' want='got=' (stdin should be closed)" >&2; exit 1
}

# --- (e) meta.transport reflects the --shell flag ------------------------
argv_meta=".claude/cache/jobs/$(ls .claude/cache/jobs/*.json | head -1 | xargs basename -s .json).json"
# Spot-check one argv job + one shell job from this test run.
grep -l '"transport": "argv"' .claude/cache/jobs/*.json >/dev/null || {
  echo "FAIL[e]: no argv-transport job meta found" >&2; exit 1
}
grep -l '"transport": "shell"' .claude/cache/jobs/*.json >/dev/null || {
  echo "FAIL[e]: --shell opt-in did not record transport=shell in meta" >&2; exit 1
}

echo "test-job-transport: OK"
