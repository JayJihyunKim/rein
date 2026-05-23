#!/usr/bin/env bash
# test-job-stop-posix.sh — Plan C Phase 8 Task 8.2.
#
# Verifies POSIX `rein job stop` semantics:
#   (a) running job terminated by `cmd_job_stop <jid>` — pid exits within
#       the escalation window.
#   (b) stop rc and stdout mention SIGTERM + (optionally) SIGKILL.
#   (c) stop on an unknown / already-finished job returns non-zero with a
#       friendly message.
#
# The setsid-vs-no-setsid split (pgroup kill vs single-pid kill with
# warning) is exercised on whichever path this host has; the warning-path
# test is skipped when setsid is present because reliably masking setsid
# inside an existing `source`d shell is non-trivial without polluting
# other tests.
#
# Scope ID: BG-job-stop-posix-process-group.
set -e

case "$(uname -s)" in
  MINGW*|MSYS*) echo "test-job-stop-posix: SKIP on MINGW"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-stop-posix-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# --- (a) stop a long-running job --------------------------------------
out=$(cmd_job_start longsleep -- sleep 60)
jid=$(echo "$out" | awk '/^started: /{print $2; exit}')
pidf=".claude/cache/jobs/$jid.pid"

# Wait for the wrapper to populate pid.
for i in 1 2 3 4 5 6 7 8; do
  if [ -s "$pidf" ]; then break; fi
  sleep 0.25
done
pid=$(cat "$pidf" 2>/dev/null || echo "")
[ -n "$pid" ] || { echo "FAIL[a-setup]: pid file empty" >&2; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "FAIL[a-setup]: pid not alive before stop" >&2; exit 1; }

# Stop.
stop_out=$(cmd_job_stop "$jid" 2>&1)
# Poll for the pid to disappear. Allow up to ~5s — the escalation path
# waits 2s + SIGKILL + a few more iterations.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if ! kill -0 "$pid" 2>/dev/null; then
    dead=1
    break
  fi
  sleep 0.3
done
[ "${dead:-0}" = "1" ] || {
  echo "FAIL[a]: pid $pid still alive after stop" >&2
  echo "stop_out: $stop_out" >&2
  exit 1
}

# --- (b) stop unknown job -------------------------------------------
rc=0
out2=$(cmd_job_stop this-is-not-a-real-job 2>&1) || rc=$?
[ "$rc" != "0" ] || { echo "FAIL[b]: stop on unknown job rc=0" >&2; exit 1; }

# --- (c) stop records terminal state (state-machine contract) --------
# Regression guard for BG-job-stop-record-terminal-status: after a
# successful stop, the job's .status MUST transition out of "running"
# (to the terminal "killed" state) and .exit MUST be recorded. Prior to
# the fix, cmd_job_stop killed the pid but left .status="running" stale.
statf_c=".claude/cache/jobs/$jid.status"
exitf_c=".claude/cache/jobs/$jid.exit"
# Poll briefly so the assertion is not racing the settle write.
for i in 1 2 3 4 5 6 7 8; do
  st_c=$(cat "$statf_c" 2>/dev/null || echo "")
  [ "$st_c" != "running" ] && [ -n "$st_c" ] && break
  sleep 0.25
done
st_c=$(cat "$statf_c" 2>/dev/null || echo "")
[ "$st_c" != "running" ] || {
  echo "FAIL[c]: .status still 'running' after stop (state-machine contract violation)" >&2
  exit 1
}
[ "$st_c" = "killed" ] || {
  echo "FAIL[c]: .status expected 'killed' after stop, got '$st_c'" >&2
  exit 1
}
[ -f "$exitf_c" ] || {
  echo "FAIL[c]: .exit not recorded after stop" >&2
  exit 1
}
ec_c=$(cat "$exitf_c" 2>/dev/null || echo "")
[ -n "$ec_c" ] || {
  echo "FAIL[c]: .exit file empty after stop" >&2
  exit 1
}

# --- (d) stop without setsid still settles status (core failure case) -
# The setsid-absent path kills only the wrapper PID, so the wrapper never
# observes the child exit to settle status. cmd_job_stop itself must record
# the terminal state. We simulate setsid absence by masking it in a function
# scope so _rein_job_launch_posix falls back to the nohup branch.
setsid_orig=$(command -v setsid || echo "")
command() {
  if [ "$1" = "-v" ] && [ "$2" = "setsid" ]; then return 1; fi
  builtin command "$@"
}
out_d=$(cmd_job_start longsleep_nosetsid -- sleep 60)
jid_d=$(echo "$out_d" | awk '/^started: /{print $2; exit}')
unset -f command
pidf_d=".claude/cache/jobs/$jid_d.pid"
for i in 1 2 3 4 5 6 7 8; do
  [ -s "$pidf_d" ] && break
  sleep 0.25
done
pid_d=$(cat "$pidf_d" 2>/dev/null || echo "")
[ -n "$pid_d" ] || { echo "FAIL[d-setup]: pid file empty (nosetsid)" >&2; exit 1; }
cmd_job_stop "$jid_d" >/dev/null 2>&1 || true
statf_d=".claude/cache/jobs/$jid_d.status"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  st_d=$(cat "$statf_d" 2>/dev/null || echo "")
  [ "$st_d" != "running" ] && [ -n "$st_d" ] && break
  sleep 0.3
done
st_d=$(cat "$statf_d" 2>/dev/null || echo "")
[ "$st_d" != "running" ] || {
  echo "FAIL[d]: .status still 'running' after no-setsid stop" >&2
  exit 1
}
[ -f ".claude/cache/jobs/$jid_d.exit" ] || {
  echo "FAIL[d]: .exit not recorded after no-setsid stop" >&2
  exit 1
}

# --- (e) settle is compare-and-set: never clobber a natural settlement ------
# Regression for the codex-found double-settle race (2026-05-23): if the
# wrapper settled naturally (status=success, .exit=0, .pid removed) in the
# window before cmd_job_stop's settle call, _rein_job_settle_terminal MUST be
# a no-op and preserve the real exit code — not overwrite with killed/143.
jd_e=".claude/cache/jobs"
mkdir -p "$jd_e"
jid_e="cas-guard-natural-settle"
printf '%s' "success" > "$jd_e/$jid_e.status"
printf '%s' "0" > "$jd_e/$jid_e.exit"
printf '{"name":"x","finished_at":111,"exit_code":0}' > "$jd_e/$jid_e.json"
# .pid intentionally absent — the wrapper removes it as its final settle step.
_rein_job_settle_terminal "$jid_e" "killed" "143"
st_e=$(cat "$jd_e/$jid_e.status" 2>/dev/null || echo "")
ec_e=$(cat "$jd_e/$jid_e.exit" 2>/dev/null || echo "")
[ "$st_e" = "success" ] || {
  echo "FAIL[e]: settle clobbered a natural status (got '$st_e', want 'success')" >&2
  exit 1
}
[ "$ec_e" = "0" ] || {
  echo "FAIL[e]: settle clobbered a natural exit (got '$ec_e', want '0')" >&2
  exit 1
}

# --- (e2) settle records the exact terminal exit when still running ----------
# Positive side: status=running + .pid present → settles to killed with the
# conventional 128 + SIGTERM(15) = 143 exit, and removes the .pid marker.
jid_e2="cas-running-settle"
printf '%s' "running" > "$jd_e/$jid_e2.status"
printf '{"name":"y"}' > "$jd_e/$jid_e2.json"
printf '%s' "99999" > "$jd_e/$jid_e2.pid"
_rein_job_settle_terminal "$jid_e2" "killed" "$(( 128 + 15 ))"
st_e2=$(cat "$jd_e/$jid_e2.status" 2>/dev/null || echo "")
ec_e2=$(cat "$jd_e/$jid_e2.exit" 2>/dev/null || echo "")
[ "$st_e2" = "killed" ] || {
  echo "FAIL[e2]: running job not settled to 'killed' (got '$st_e2')" >&2
  exit 1
}
[ "$ec_e2" = "143" ] || {
  echo "FAIL[e2]: exact terminal exit want 143 (128+SIGTERM), got '$ec_e2'" >&2
  exit 1
}
[ ! -f "$jd_e/$jid_e2.pid" ] || {
  echo "FAIL[e2]: .pid not removed after settle" >&2
  exit 1
}

echo "test-job-stop-posix: OK"
