#!/usr/bin/env bash
# rein-job-wrapper.sh — completion writer for `rein job start` (Plan C Task 7.3,
# BG-job-completion-writer + BG-file-state-atomic-write).
#
# Invoked by the detach path (setsid / nohup / subshell) in rein.sh as:
#   rein-job-wrapper.sh <pidf> <exitf> <statf> <metaf> <log> -- <command argv...>
#
# The "-- " separator is optional and dropped if present; the wrapper is
# happy to take the argv immediately after <log>. Either form works because
# rein.sh always passes positional argv (never flags to us).
#
# Contract:
#   - atomically writes $$ to <pidf>
#   - flips <statf> to "running"
#   - execs the command with stdin=/dev/null, stdout+stderr=<log>
#   - captures rc; atomically writes rc to <exitf>
#   - atomically flips <statf> to "success" (rc=0) or "failed" (rc!=0)
#   - patches <metaf> with {finished_at, exit_code} via python3
#   - removes <pidf> so status probes know the job is settled
#
# The wrapper intentionally avoids `set -e` so a non-zero command rc does
# not abort status propagation. python3 is the only external we rely on
# and its failure is degraded to "still write status/.exit/.pid".

set -u

pidf="$1"; exitf="$2"; statf="$3"; metaf="$4"; log="$5"
shift 5
if [ "${1:-}" = "--" ]; then shift; fi

# 1. Announce liveness.
printf '%s' "$$" > "${pidf}.tmp.$$" 2>/dev/null \
  && mv -f "${pidf}.tmp.$$" "$pidf"
printf '%s' "running" > "${statf}.tmp.$$" \
  && mv -f "${statf}.tmp.$$" "$statf"

# 2. Run.
rc=0
if [ $# -gt 0 ]; then
  "$@" >"$log" 2>&1 </dev/null || rc=$?
else
  rc=2
  printf 'rein-job-wrapper: no command given\n' >"$log"
fi

# 3. Exit + status files.
printf '%s' "$rc" > "${exitf}.tmp.$$" \
  && mv -f "${exitf}.tmp.$$" "$exitf"
if [ "$rc" -eq 0 ]; then final=success; else final=failed; fi
printf '%s' "$final" > "${statf}.tmp.$$" \
  && mv -f "${statf}.tmp.$$" "$statf"

# 4. Meta patch (finished_at + exit_code). Best-effort — if python3 is
#    unavailable the earlier atomic writes still reflect the outcome, and
#    cmd_job_status falls back to the .exit file when meta lacks exit_code.
python3 - "$metaf" "$rc" <<'PY' 2>/dev/null || true
import json, os, sys, time
meta_path, rc = sys.argv[1], int(sys.argv[2])
try:
    with open(meta_path) as f:
        m = json.load(f)
except Exception:
    m = {}
m["finished_at"] = int(time.time())
m["exit_code"] = rc
tmp = meta_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(m, f)
os.replace(tmp, meta_path)
PY

# 5. Drop liveness marker last so readers have a clean transition.
rm -f "$pidf"
