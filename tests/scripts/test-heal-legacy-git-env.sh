#!/usr/bin/env bash
# test-heal-legacy-git-env.sh — BC-INFO1-siblings-3 regression.
#
# rein-heal-legacy-pending.py's run_git() must scrub inherited git env vars
# (GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE) so a poisoned
# environment cannot redirect `git rev-parse --show-toplevel` discovery to a
# decoy repo. Without the scrub, run_git from a non-git cwd with GIT_DIR
# pointing at a decoy returns the decoy toplevel (latched); with the scrub it
# returns non-zero/empty and the caller falls through to its error path.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEALER="$PROJECT_DIR/plugins/rein-core/scripts/rein-heal-legacy-pending.py"

[ -f "$HEALER" ] || { echo "FAIL: $HEALER missing" >&2; exit 1; }

scratch=$(mktemp -d "/tmp/test-heal-git-env-XXXXXX")
trap 'rm -rf "$scratch"' EXIT

decoy="$scratch/decoy"
nongit="$scratch/nongit"
mkdir -p "$decoy" "$nongit"
git -C "$decoy" init -q >/dev/null 2>&1

# Invoke run_git() directly with a poisoned env from a non-git cwd.
out=$(
  GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" \
  GIT_CEILING_DIRECTORIES="$scratch" \
  python3 - "$HEALER" "$nongit" "$decoy" <<'PY'
import importlib.util
import sys
from pathlib import Path

healer_path, nongit, decoy = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("heal", healer_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
rc, top = m.run_git(["rev-parse", "--show-toplevel"], Path(nongit))
# Print a verdict line the shell can assert on.
print("LATCHED" if (decoy in top) else "CLEAN")
PY
)

if [ "$out" = "LATCHED" ]; then
  echo "FAIL: run_git latched the decoy under poisoned GIT_DIR (BC-INFO1-siblings-3)" >&2
  exit 1
fi
if [ "$out" != "CLEAN" ]; then
  echo "FAIL: unexpected run_git verdict: '$out'" >&2
  exit 1
fi

echo "test-heal-legacy-git-env: OK (run_git scrubs git env — decoy not latched)"
