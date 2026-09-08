#!/usr/bin/env bash
# tests/scripts/test-run-all-failure-listing.sh
# Behavioral test for the failing-suite listing that
# tests/{scripts,hooks,skills,agents,integration,rules}/run-all.sh print on
# failure.
#
# Each runner's for-loop accumulates failing suite basenames in
# FAILED_SUITES and, when TOTAL_FAIL > 0, prints "N SUITE(S) FAILED"
# followed by one "  - <basename>" line per failed suite (including for the
# MISSING-file branch). Success output is unchanged ("ALL SUITES PASSED",
# no "  - " lines).
#
# This test never runs a real runner (each takes minutes) — for every one
# of the six runners it builds a throwaway sandbox mirroring the runner's
# real directory layout (extracted from the runner's own
# "$SCRIPT_DIR/<relative path>" entries, so sibling paths like
# "../hooks/..." land in the right place too), fills every enumerated path
# with a trivial `exit 0` stub, flips exactly one (the 2nd entry, to avoid
# first/last edge effects) to `exit 1`, and runs the REAL, unmodified
# run-all.sh copy against that sandbox — verifying the runner's actual
# for-loop logic, not a re-implementation of it.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

SANDBOXES=""
cleanup() {
  for _sb in $SANDBOXES; do
    rm -rf "$_sb" 2>/dev/null || true
  done
}
trap cleanup EXIT

# check_runner <dir-name>
# <dir-name> is one of scripts/hooks/skills/agents/integration/rules —
# matches tests/<dir-name>/run-all.sh.
check_runner() {
  local runner_dir real_runner entries sb i entry target
  local chosen_target chosen_basename
  local out1 rc1 out2 rc2 out3 rc3 dash_count1 dash_count2

  runner_dir="$1"
  real_runner="$PROJECT_DIR/tests/$runner_dir/run-all.sh"
  if [ ! -f "$real_runner" ]; then
    bad "($runner_dir) real run-all.sh missing at $real_runner"
    return
  fi

  entries=$(grep -oE '"\$SCRIPT_DIR/[^"]+"' "$real_runner" | sed 's/"//g' | sed 's#\$SCRIPT_DIR/##')
  if [ -z "$entries" ]; then
    bad "($runner_dir) could not extract any suite entries from $real_runner"
    return
  fi

  sb=$(mktemp -d "/tmp/run-all-failure-listing-$runner_dir-XXXXXX")
  SANDBOXES="$SANDBOXES $sb"
  mkdir -p "$sb/tests/$runner_dir"
  cp "$real_runner" "$sb/tests/$runner_dir/run-all.sh"

  i=0
  chosen_target=""
  chosen_basename=""
  for entry in $entries; do
    i=$((i + 1))
    target="$sb/tests/$runner_dir/$entry"
    mkdir -p "$(dirname "$target")"
    if [ "$i" -eq 2 ]; then
      printf '#!/bin/bash\nexit 1\n' > "$target"
      chosen_target="$target"
      chosen_basename="$(basename "$entry")"
    else
      printf '#!/bin/bash\nexit 0\n' > "$target"
    fi
  done

  if [ -z "$chosen_target" ]; then
    bad "($runner_dir) fewer than 2 entries — cannot pick a 2nd-entry stub"
    return
  fi

  # --- run 1: 2nd stub exits 1 → failure listing names it, and only it ----
  out1=$(bash "$sb/tests/$runner_dir/run-all.sh" </dev/null 2>&1)
  rc1=$?
  if [ "$rc1" = "1" ]; then ok "($runner_dir) fail-run exits 1"; else bad "($runner_dir) fail-run exited $rc1 (want 1)"; fi
  if printf '%s\n' "$out1" | grep -qF '1 SUITE(S) FAILED'; then ok "($runner_dir) fail-run prints '1 SUITE(S) FAILED'"; else bad "($runner_dir) fail-run missing '1 SUITE(S) FAILED'"; fi
  dash_count1=$(printf '%s\n' "$out1" | grep -c '^  - ')
  if [ "$dash_count1" = "1" ]; then ok "($runner_dir) fail-run lists exactly one suite"; else bad "($runner_dir) fail-run listed $dash_count1 '  - ' lines (want 1)"; fi
  if printf '%s\n' "$out1" | grep -qxF "  - $chosen_basename"; then ok "($runner_dir) fail-run lists '$chosen_basename'"; else bad "($runner_dir) fail-run does not list '$chosen_basename'"; fi

  # --- run 2: chosen stub flipped back to exit 0 → all pass, no listing ---
  printf '#!/bin/bash\nexit 0\n' > "$chosen_target"
  out2=$(bash "$sb/tests/$runner_dir/run-all.sh" </dev/null 2>&1)
  rc2=$?
  if [ "$rc2" = "0" ]; then ok "($runner_dir) pass-run exits 0"; else bad "($runner_dir) pass-run exited $rc2 (want 0)"; fi
  if printf '%s\n' "$out2" | grep -qF 'ALL SUITES PASSED'; then ok "($runner_dir) pass-run prints ALL SUITES PASSED"; else bad "($runner_dir) pass-run missing ALL SUITES PASSED"; fi
  dash_count2=$(printf '%s\n' "$out2" | grep -c '^  - ')
  if [ "$dash_count2" = "0" ]; then ok "($runner_dir) pass-run lists no suites"; else bad "($runner_dir) pass-run unexpectedly printed $dash_count2 '  - ' lines"; fi

  # --- run 3: chosen stub file DELETED (MISSING branch) → still listed ---
  rm -f "$chosen_target"
  out3=$(bash "$sb/tests/$runner_dir/run-all.sh" </dev/null 2>&1)
  rc3=$?
  if [ "$rc3" = "1" ]; then ok "($runner_dir) missing-run exits 1"; else bad "($runner_dir) missing-run exited $rc3 (want 1)"; fi
  if printf '%s\n' "$out3" | grep -qxF "  - $chosen_basename"; then ok "($runner_dir) missing-run lists '$chosen_basename'"; else bad "($runner_dir) missing-run does not list '$chosen_basename'"; fi
}

for _d in scripts hooks skills agents integration rules; do
  check_runner "$_d"
done

echo ""
echo "test-run-all-failure-listing: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
