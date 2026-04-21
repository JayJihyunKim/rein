#!/usr/bin/env bash
# scripts/rein-test-oracle-promotion-check.sh
#
# Compute the test-oracle promotion metric from the detection log and
# print key=value pairs to stdout. Exit 0 if promotion criteria are met
# (ratio ≥ 0.5 AND confirmed_true ≥ 3 within the window), exit 1 otherwise.
#
# Scope IDs:
#   - TO-rollout-promotion-metric-quality
#
# Usage:
#   bash scripts/rein-test-oracle-promotion-check.sh [--weeks N]
#     --weeks N   Window size in weeks (default 4).

set -euo pipefail

WEEKS=4
LOG_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --weeks)
      WEEKS="${2:-4}"
      shift 2
      ;;
    --log)
      LOG_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '1,25p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

# Resolve log path.
if [ -z "$LOG_PATH" ]; then
  if [ -n "${PROJECT_DIR:-}" ]; then
    LOG_PATH="$PROJECT_DIR/trail/incidents/bad-test-candidates.log"
  else
    LOG_PATH="$(pwd)/trail/incidents/bad-test-candidates.log"
  fi
fi

if [ ! -f "$LOG_PATH" ]; then
  echo "ERROR: detection log not found: $LOG_PATH" >&2
  exit 2
fi

# Compute metrics via python3 for portable date math.
python3 - "$LOG_PATH" "$WEEKS" <<'PYEOF'
import sys
from datetime import datetime, timedelta, timezone

log_path = sys.argv[1]
weeks = int(sys.argv[2])

threshold = datetime.now(timezone.utc) - timedelta(weeks=weeks)

confirmed_true = 0
confirmed_false = 0
confirmed_unknown = 0

with open(log_path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if not parts:
            continue
        ts_str = parts[0]
        try:
            ts = datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            continue
        if ts < threshold:
            continue
        # Look for confirmed=... field.
        confirmed = None
        for p in parts[1:]:
            if p.startswith("confirmed="):
                confirmed = p.split("=", 1)[1].strip().lower()
                break
        if confirmed == "true":
            confirmed_true += 1
        elif confirmed == "false":
            confirmed_false += 1
        else:
            confirmed_unknown += 1

# Ratio uses true / (true + false), excluding unknown.
denom = confirmed_true + confirmed_false
ratio = (confirmed_true / denom) if denom > 0 else 0.0

print(f"weeks={weeks}")
print(f"confirmed_true_count={confirmed_true}")
print(f"confirmed_false_count={confirmed_false}")
print(f"confirmed_unknown_count={confirmed_unknown}")
print(f"confirmed_true_ratio={ratio:.3f}")

ok = (ratio >= 0.5) and (confirmed_true >= 3)
if ok:
    print("[PASS] promotion criteria met (ratio >= 0.5 AND count >= 3)")
    sys.exit(0)
reasons = []
if ratio < 0.5:
    reasons.append(f"ratio {ratio:.3f} < 0.5")
if confirmed_true < 3:
    reasons.append(f"count {confirmed_true} < 3")
print(f"[FAIL] promotion criteria NOT met: {', '.join(reasons)}", file=sys.stderr)
sys.exit(1)
PYEOF
