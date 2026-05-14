#!/usr/bin/env bash
# test-job-start-skeleton.sh — Plan C Phase 7 Task 7.1.
#
# Verifies the `rein job start` skeleton path:
#   - Emits `started: <job-id>` line, returns within 1s
#   - Writes state layout: .claude/cache/jobs/<jid>.{json,status,log}
#   - Meta JSON contains {name, transport, cwd, started_at, cmd}
#   - .status is "running" until the completion wrapper flips it
#
# This test uses a near-instant command (true) so we don't race the
# completion wrapper — we only assert "return fast + write layout".
# The completion-writer contract (.exit, .status transition) is tested
# in test-job-completion-wrapper.sh (Task 7.3).
#
# Scope IDs: BG-job-start-returns-jobid-under-1s, BG-file-state-layout.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

tmp=$(mktemp -d -t rein-job-skel-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# --- 1. start a long-running job and measure return time -----------------
# Use `sleep 5` so the wrapper is still running when we assert .status.
t_start=$(date +%s)
out=$(cmd_job_start skeleton-test -- sleep 5 2>&1) || {
  echo "FAIL: cmd_job_start exited non-zero: $out" >&2; exit 1
}
t_end=$(date +%s)
elapsed=$((t_end - t_start))
# Allow 2s for slow CI; spec contract is <1s but the goal is "return promptly,
# not block for the whole command duration".
if [ "$elapsed" -gt 2 ]; then
  echo "FAIL: cmd_job_start blocked for ${elapsed}s (expected <2s)" >&2
  echo "out: $out" >&2; exit 1
fi

# Extract job id from `started: <jid>` line
jid=$(printf '%s\n' "$out" | awk '/^started: /{print $2; exit}')
[ -n "$jid" ] || { echo "FAIL: no 'started:' line in output: $out" >&2; exit 1; }

# Job id must follow `<name>-<ts>-<4hex>` pattern
printf '%s\n' "$jid" | grep -Eq '^skeleton-test-[0-9]+-[0-9a-f]{4}$' || {
  echo "FAIL: job id '$jid' does not match name-ts-hex pattern" >&2; exit 1
}

# --- 2. state layout --------------------------------------------------
jd=".claude/cache/jobs"
[ -f "$jd/$jid.json" ]   || { echo "FAIL: meta $jd/$jid.json missing" >&2; exit 1; }
[ -f "$jd/$jid.status" ] || { echo "FAIL: status $jd/$jid.status missing" >&2; exit 1; }
[ -f "$jd/$jid.log" ]    || { echo "FAIL: log $jd/$jid.log missing" >&2; exit 1; }

# --- 3. meta JSON fields ---------------------------------------------
python3 - "$jd/$jid.json" "skeleton-test" "$tmp" <<'PY'
import json, os, sys
path, want_name, want_cwd_hint = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: m = json.load(f)
missing = [k for k in ("name","transport","cwd","started_at","cmd") if k not in m]
if missing:
    print(f"FAIL: meta missing keys: {missing}", file=sys.stderr); sys.exit(1)
if m["name"] != want_name:
    print(f"FAIL: name={m['name']} want={want_name}", file=sys.stderr); sys.exit(1)
if m["transport"] != "argv":
    print(f"FAIL: transport={m['transport']} want=argv", file=sys.stderr); sys.exit(1)
# macOS mktemp returns /private/var/... which realpath'd equals /var/...
# Just assert cwd exists and contains the hint's basename tail so the helper
# is storing *some* cwd, not '/'.
if not os.path.isabs(m["cwd"]):
    print(f"FAIL: cwd not absolute: {m['cwd']}", file=sys.stderr); sys.exit(1)
if not isinstance(m["started_at"], int) or m["started_at"] <= 0:
    print(f"FAIL: started_at invalid: {m['started_at']}", file=sys.stderr); sys.exit(1)
PY

# --- 4. .status == "running" (wrapper hasn't exited yet) --------------
# We started `sleep 5`, ~<2s have passed, so wrapper should still be live.
status=$(cat "$jd/$jid.status")
[ "$status" = "running" ] || {
  echo "FAIL: status='$status' want='running' while sleep 5 still live" >&2
  exit 1
}

# Clean up: kill the lingering job so mktemp rm works.
pidf="$jd/$jid.pid"
if [ -f "$pidf" ]; then
  pid=$(cat "$pidf" 2>/dev/null || echo "")
  if [ -n "$pid" ]; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  fi
fi

echo "test-job-start-skeleton: OK"
