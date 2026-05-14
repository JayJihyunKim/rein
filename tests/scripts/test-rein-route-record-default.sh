#!/usr/bin/env bash
# S21 contract: when .rein/project.json is missing, rein-route-record defaults to
# plugin mode — i.e. resolves to .rein/policy/router/ (never .claude/router/).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"

# Setup: no .rein/project.json, no .claude/router/, no .rein/policy/router/
[ -e .rein/project.json ] && { echo "FAIL: precondition project.json should be absent"; exit 1; }

# Import resolve_router_dir + invoke directly. Default mode (plugin) implies
# .rein/policy/router/ creation.
out=$(REIN_ROUTER_DIR="" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', '$ROOT/scripts/rein-route-record.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.resolve_router_dir()
print(str(d))
" 2>&1)

[ "$out" = ".rein/policy/router" ] \
  || { echo "FAIL [S21 default mode]: resolve_router_dir returned '$out', expected '.rein/policy/router'"; exit 1; }

[ -d .rein/policy/router ] \
  || { echo "FAIL [S21 mkdir]: .rein/policy/router not created"; exit 1; }

echo "PASS: tests/scripts/test-rein-route-record-default.sh (S21 — default mode plugin → .rein/policy/router)"
