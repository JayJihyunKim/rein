#!/usr/bin/env bash
# S1 contract: rein init (with or without --mode=scaffold) is unknown command + exit ≠ 0
# S27 contract: init subcommand removed from rein.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

run_capture() {
  set +e; out=$(bash "$ROOT/scripts/rein.sh" "$@" 2>&1); rc=$?; set -e
  printf '%s\n' "$out"; return "$rc"
}

for args in 'init' 'init --mode=scaffold' 'init --mode=plugin' 'init --mode=foo'; do
  set +e; out=$(run_capture $args); rc=$?; set -e
  echo "$out" | grep -qE "unknown command 'init'" \
    || { echo "FAIL [$args]: should print unknown command 'init', got: $out"; exit 1; }
  [ "$rc" -ne 0 ] \
    || { echo "FAIL [$args]: should exit non-zero, got rc=$rc"; exit 1; }
done
echo "PASS: tests/scripts/test-rein-init-unknown.sh (S1, S27)"
