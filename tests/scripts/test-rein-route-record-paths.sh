#!/usr/bin/env bash
# S25 contract: legacy .claude/router/ is NOT accepted as fallback.
# rein-route-record must hard-fail with an error referencing the new
# .rein/policy/router/ path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"

# Setup: legacy .claude/router/ present + .rein/policy/router/ absent
mkdir -p .claude/router
echo '{}' > .claude/router/overrides.yaml

# rein-route-record override should hard-fail (no legacy fallback)
set +e
out=$(python3 "$ROOT/scripts/rein-route-record.py" override \
  --dod /tmp/test.md \
  --removed "skill:foo" \
  --added "skill:bar" \
  --reason "S25 path test" 2>&1)
rc=$?
set -e

[ "$rc" -ne 0 ] \
  || { echo "FAIL [S25 fallback-negative]: legacy .claude/router/ accepted as fallback (rc=0), should hard-fail"; exit 1; }

echo "$out" | grep -qE '\.rein/policy/router' \
  || { echo "FAIL [S25 error message]: should reference .rein/policy/router, got: $out"; exit 1; }

# Legacy .claude/router/overrides.yaml should still be empty {} (not appended)
legacy_size=$(wc -c < .claude/router/overrides.yaml)
[ "$legacy_size" -lt 10 ] \
  || { echo "FAIL: legacy .claude/router/overrides.yaml unexpectedly modified ($legacy_size bytes)"; exit 1; }

echo "PASS: tests/scripts/test-rein-route-record-paths.sh (S25 fallback-negative — legacy .claude/router/ hard-fail)"
