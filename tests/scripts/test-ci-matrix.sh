#!/usr/bin/env bash
# test-ci-matrix.sh — Plan C Phase 10 Task 10.1.
#
# Guards the CI matrix workflow definition. Does NOT run CI — just asserts
# that the workflow enumerates the platforms rein officially supports
# (Linux — which also stands in for Windows WSL2 — and macOS) and invokes
# both test runners. Windows native (Git Bash) is best-effort and has no
# CI job.
#
# The check reads the parsed YAML (matrix expression and step `run:` lines),
# not the raw file, so a platform name left in a comment cannot mask its
# removal from the matrix. A mutated copy proves the negative path.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$PROJECT_DIR/.github/workflows/tests.yml"

[ -f "$WF" ] || { echo "FAIL: $WF missing" >&2; exit 1; }

check_workflow() {
  python3 - "$1" <<'PY'
import json, re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
job = (wf.get("jobs") or {}).get("tests") or {}
matrix_os = ((job.get("strategy") or {}).get("matrix") or {}).get("os", "")
# matrix.os is either a literal list or an expression whose last fromJSON()
# list is the full set used for PR / dispatch / release tags.
if isinstance(matrix_os, str):
    lists = re.findall(r"fromJSON\('(\[[^']*\])'\)", matrix_os)
    matrix_os = json.loads(lists[-1]) if lists else []
# A runner counts only when a run line executes it (not a comment or echo).
run_lines = [l.strip() for st in job.get("steps") or []
             for l in str(st.get("run", "")).splitlines()]
missing = [o for o in ("ubuntu-latest", "macos-latest") if o not in matrix_os]
missing += [r for r in ("tests/scripts/run-all.sh", "tests/hooks/run-all.sh")
            if not any(re.match(r"bash\s+" + re.escape(r) + r"(\s|$)", l) for l in run_lines)]
if missing:
    print("FAIL: tests job lacks " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PY
}

# The structural check needs PyYAML. CI installs it before the suites run;
# a local machine without it skips with a notice (same as the mirror test).
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "test-ci-matrix: SKIP (PyYAML absent — structural check runs in CI)"
  exit 0
fi

check_workflow "$WF"

# Negative paths: each mutation keeps the name elsewhere in the file.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
expect_reject() {
  if check_workflow "$TMP/tests.yml" 2>/dev/null; then
    echo "FAIL: guard did not detect $1" >&2
    exit 1
  fi
}
sed '/^ *os: /s/"ubuntu-latest", //' "$WF" > "$TMP/tests.yml"
grep -q 'ubuntu-latest' "$TMP/tests.yml"
expect_reject "ubuntu-latest removed from the full matrix"
sed 's|run: bash tests/scripts/run-all.sh|run: echo tests/scripts/run-all.sh|' "$WF" > "$TMP/tests.yml"
grep -q 'run: echo tests/scripts/run-all.sh' "$TMP/tests.yml"
expect_reject "scripts runner replaced by echo"
sed 's|run: bash tests/hooks/run-all.sh|run: "# tests/hooks/run-all.sh"|' "$WF" > "$TMP/tests.yml"
grep -q '# tests/hooks/run-all.sh"' "$TMP/tests.yml"
expect_reject "hooks runner commented out"

echo "test-ci-matrix: OK"
