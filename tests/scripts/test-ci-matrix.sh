#!/usr/bin/env bash
# test-ci-matrix.sh — Plan C Phase 10 Task 10.1.
#
# Guards the CI matrix workflow definition. Does NOT run CI — just asserts
# that the workflow file enumerates the three platforms rein claims to
# support (POSIX Linux, macOS, Windows Git Bash via MINGW).
#
# If a future refactor drops one of these, Spec C Windows-first-class
# guarantee silently erodes; this test turns the regression into a
# red test instead of a production surprise.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$PROJECT_DIR/.github/workflows/tests.yml"

[ -f "$WF" ] || { echo "FAIL: $WF missing" >&2; exit 1; }

for os in ubuntu-latest macos-latest windows-latest; do
  grep -q "$os" "$WF" || {
    echo "FAIL: $os not listed in $WF" >&2
    exit 1
  }
done

# Workflow must invoke both test runners so Phase 7-8 background-job tests
# actually execute on Windows (their MINGW-only assertions are gated by
# uname -s so they SKIP on POSIX, but they MUST be reachable on Windows).
grep -q 'tests/scripts/run-all.sh' "$WF" || {
  echo "FAIL: tests/scripts/run-all.sh not invoked by workflow" >&2; exit 1
}
grep -q 'tests/hooks/run-all.sh' "$WF" || {
  echo "FAIL: tests/hooks/run-all.sh not invoked by workflow" >&2; exit 1
}

# Windows-latest job must use `shell: bash` so Git Bash (MINGW64) is active
# — otherwise tests run under PowerShell and the detach/taskkill paths
# never get exercised.
if grep -q 'windows-latest' "$WF"; then
  grep -q 'shell: bash' "$WF" || {
    echo "FAIL: windows-latest job does not set shell: bash" >&2; exit 1
  }
fi

echo "test-ci-matrix: OK"
