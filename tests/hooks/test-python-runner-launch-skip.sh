#!/bin/bash
# tests/hooks/test-python-runner-launch-skip.sh
#
# PERF-A-LAUNCH-SKIP / PERF-A-EXIT-PARITY parity fixtures for
# plugins/rein-core/hooks/lib/python-runner.sh::resolve_python().
#
# design ref : docs/specs/2026-06-02-hook-hotpath-perf.md
# plan  ref  : docs/plans/2026-06-02-hook-hotpath-perf-implementation.md (Task 1.2)
#
# -----------------------------------------------------------------------------
# What is under test
# -----------------------------------------------------------------------------
# resolve_python() now SKIPS the launch-based health_check ONLY for the bare
# `python3` / `python` candidates (label == python3|python) on a NON-Windows
# uname (uname -s not MINGW*/MSYS*/CYGWIN*). The candidate is accepted purely on
#   command -v success  +  non-WindowsApps path.
# REIN_PYTHON and VENV candidates carry labels REIN_PYTHON / VENV, so they do
# NOT match the skip branch and KEEP their health_check launch (broken-candidate
# guard preserved). The WindowsApps stub `continue` and the REIN_PYTHON metachar
# `return 12` both happen BEFORE the launch-skip branch, so they are unaffected.
#
# Exit codes (resolve_python):
#   0   success (PYTHON_RUNNER populated)
#   10  no candidate interpreter found
#   11  a candidate resolved to a WindowsApps stub
#   12  REIN_PYTHON metachar (immediate) OR launch-fail with no healthy fallback
#
# -----------------------------------------------------------------------------
# Marker observation
# -----------------------------------------------------------------------------
# To OBSERVE whether health_check actually launched an interpreter, the fake
# python binaries planted here append their PID to a per-test MARKER file the
# moment they are invoked. Therefore:
#   * MARKER absent  => the interpreter was NEVER launched => health_check was
#                       skipped (launch-skip branch taken, or rejected earlier).
#   * MARKER present => the interpreter WAS launched => health_check ran.
# health_check runs `<cand> -c "import sys; sys.exit(0)"`; the fakes ignore args
# and stdin, append to MARKER, then exit with the requested code — so any launch
# (health_check OR a downstream caller) leaves a trace.
#
# -----------------------------------------------------------------------------
# Before / after matrix  (BEFORE = pre-Track-A, AFTER = current launch-skip)
# -----------------------------------------------------------------------------
#  #  scenario                                            BEFORE rc  AFTER rc  marker
#  1  healthy bare python3 only (Darwin)                       0         0     ABSENT (skip)
#  2  broken venv, no python3/python fallback (Darwin)        12        12     PRESENT (venv launched)
#  3  broken venv + healthy bare python3 (Darwin)              0         0     venv PRESENT, py3 skip
#  4  metachar REIN_PYTHON 'a;b'                               12        12     ABSENT (validate reject)
#  5  nonexistent REIN_PYTHON + healthy python3 (Darwin)       0         0     ABSENT (cmd-v fail -> fall)
#  6  exec-but-failing REIN_PYTHON(49), no fallback (Darwin)  12        12     PRESENT (REIN_PYTHON launched)
#  7  MSYS uname + bare python3                                0         0     PRESENT (Windows keeps launch)
#  8  WindowsApps stub bare python3                            11        11     ABSENT (path check, pre-launch)
#  9  DEVIATION: broken bare python3 only (49) (Darwin)       12 -> 0    0     ABSENT (skip accepts pre-launch)
#
#  ^ The TWO behaviour-relevant rows to note:
#      #9 : the single intended deviation — was rc 12 (launch-fail) BEFORE the
#           cycle, is rc 0 NOW because the bare python3 is accepted before any
#           launch; the breakage is deferred downstream (extract time).
#      #5 : a nonexistent REIN_PYTHON is NOT a metachar reject — command -v
#           fails, so the override is treated as a missing candidate and the
#           resolver falls through to the healthy bare python3 (rc 0, NOT 12).
#
# -----------------------------------------------------------------------------
# Test strategy
# -----------------------------------------------------------------------------
# Each fixture FULLY controls PATH / REIN_PYTHON / VIRTUAL_ENV / uname so the
# outcome is deterministic regardless of host. We reuse the test-harness fake
# planters (with_missing_python / with_fake_uname) where they fit, plus local
# marker-aware planters. resolve_python is sourced and run inside a subshell via
# run_resolver (copied idiom from test-python-runner.sh) so PATH/env are scoped.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
. "$SCRIPT_DIR/lib/test-harness.sh"

PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_RUNNER_LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/python-runner.sh"

if [ ! -f "$PYTHON_RUNNER_LIB" ]; then
  echo "FATAL: $PYTHON_RUNNER_LIB not found" >&2
  exit 1
fi

# ------------------------------------------------------------
# Local test scaffolding (mirrors test-python-runner.sh begin/end + run_resolver).
# We bypass the sandbox machinery because these tests must source python-runner.sh
# directly to inspect rc / ${PYTHON_RUNNER[@]}.
# ------------------------------------------------------------
begin() {
  CURRENT_TEST="$1"
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $1"
}

end() {
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
}

# run_resolver: executes resolve_python inside a fresh subshell.
# Setup commands in "$@" are eval'd inside the subshell BEFORE the lib is sourced
# and resolve_python runs, so callers stage fakes / env there. Prints:
#   RC=<rc>
#   RUNNER_LEN=<n>
#   RUNNER_<i>=<element>   (per element)
#   RUNNER_JOIN=<space-joined>
run_resolver() {
  (
    unset REIN_PYTHON VIRTUAL_ENV
    for cmd in "$@"; do
      eval "$cmd"
    done
    # shellcheck source=/dev/null
    . "$PYTHON_RUNNER_LIB"
    resolve_python
    local rc=$?
    echo "RC=$rc"
    local len=${#PYTHON_RUNNER[@]}
    echo "RUNNER_LEN=$len"
    if [ "$len" -gt 0 ]; then
      local i=0
      for elem in "${PYTHON_RUNNER[@]}"; do
        echo "RUNNER_$i=$elem"
        i=$((i + 1))
      done
    fi
    echo "RUNNER_JOIN=${PYTHON_RUNNER[*]:-}"
  )
}

parse_rc() {
  echo "$1" | awk -F= '/^RC=/{print $2; exit}'
}
parse_runner_len() {
  echo "$1" | awk -F= '/^RUNNER_LEN=/{print $2; exit}'
}

# ------------------------------------------------------------
# Marker-aware fake interpreter planters.
#
# Unlike the harness with_fake_python (which discards invocation evidence),
# these plant a python3/python that records EVERY launch into $MARKER. The
# resolver only ever runs the interpreter via health_check (or never, when the
# launch-skip branch fires), so $MARKER existence is a faithful launch probe.
#
# Each planter mints its own tmpdir, prepends it to PATH, and registers the dir
# with the harness so cleanup_fakes (or subshell exit) reclaims it.
# ------------------------------------------------------------

# plant_marker_python EXIT_CODE MARKER
#   Drop bare python3/python on a fresh (non-WindowsApps) tmpdir at the FRONT
#   of PATH. On every invocation the fake appends its PID to MARKER, then exits
#   EXIT_CODE. Use EXIT_CODE 0 for "healthy", 49 for "broken / 9009-truncated".
plant_marker_python() {
  local exit_code="${1:-0}"
  local marker="$2"
  local d
  d=$(mktemp -d "/tmp/marker-python-XXXXXX") || return 1
  cat > "$d/python3" <<EOF
#!/usr/bin/env bash
# Drain stdin from /dev/null (never block on an inherited terminal).
cat </dev/null >/dev/null 2>&1
echo "\$\$" >> '${marker//\'/\'\\\'\'}'
exit ${exit_code}
EOF
  cp "$d/python3" "$d/python"
  chmod +x "$d/python3" "$d/python"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$d")
}

# plant_marker_venv EXIT_CODE MARKER
#   Build a fake $VIRTUAL_ENV whose bin/python appends to MARKER then exits
#   EXIT_CODE. Echoes the venv root so the caller can `export VIRTUAL_ENV=...`.
#   The venv carries label VENV (not python3/python), so it always health_checks.
plant_marker_venv() {
  local exit_code="${1:-0}"
  local marker="$2"
  local venv
  venv=$(mktemp -d "/tmp/marker-venv-XXXXXX") || return 1
  mkdir -p "$venv/bin"
  cat > "$venv/bin/python" <<EOF
#!/usr/bin/env bash
cat </dev/null >/dev/null 2>&1
echo "\$\$" >> '${marker//\'/\'\\\'\'}'
exit ${exit_code}
EOF
  chmod +x "$venv/bin/python"
  _FAKE_DIRS+=("$venv")
  printf '%s\n' "$venv"
}

# plant_marker_rein_python EXIT_CODE MARKER
#   Create a standalone executable (NOT named python3/python — so it carries
#   label REIN_PYTHON and is health_checked) that appends to MARKER then exits
#   EXIT_CODE. Echoes its absolute path for `export REIN_PYTHON=...`.
plant_marker_rein_python() {
  local exit_code="${1:-0}"
  local marker="$2"
  local d
  d=$(mktemp -d "/tmp/marker-rein-XXXXXX") || return 1
  cat > "$d/my-python" <<EOF
#!/usr/bin/env bash
cat </dev/null >/dev/null 2>&1
echo "\$\$" >> '${marker//\'/\'\\\'\'}'
exit ${exit_code}
EOF
  chmod +x "$d/my-python"
  _FAKE_DIRS+=("$d")
  printf '%s\n' "$d/my-python"
}

# plant_marker_windowsapps_python MARKER
#   Drop a python3 under a path literally containing 'WindowsApps' (mixed case
#   to also exercise the case-insensitive match), at the FRONT of a curated
#   no-python PATH. The fake appends to MARKER if ever launched — but the
#   WindowsApps path check fires BEFORE the launch branch, so the marker MUST
#   stay absent. Echoes the stub dir so the caller can prepend it to PATH.
plant_marker_windowsapps_python() {
  local marker="$1"
  local parent stub_dir
  parent=$(mktemp -d "/tmp/marker-wa-XXXXXX") || return 1
  stub_dir="$parent/AppData/Local/Microsoft/WindowsApps"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/python3" <<EOF
#!/usr/bin/env bash
cat </dev/null >/dev/null 2>&1
echo "\$\$" >> '${marker//\'/\'\\\'\'}'
exit 49
EOF
  chmod +x "$stub_dir/python3"
  _FAKE_DIRS+=("$parent")
  printf '%s\n' "$stub_dir"
}

# new_marker: mint a fresh, guaranteed-absent marker PATH (file not created).
new_marker() {
  local m
  m=$(mktemp -u "/tmp/launch-marker-XXXXXX") || return 1
  printf '%s\n' "$m"
}

# assert_marker_absent / assert_marker_present: launch-probe assertions.
assert_marker_absent() {
  # $1=marker path, $2=context
  if [ -e "$1" ]; then
    fail "${2:-marker} should be ABSENT (launch skipped) but exists: $(cat "$1" 2>/dev/null | tr '\n' ' ')"
  fi
}
assert_marker_present() {
  # $1=marker path, $2=context
  if [ ! -e "$1" ]; then
    fail "${2:-marker} should be PRESENT (interpreter launched) but is missing"
  fi
}

# ============================================================
# Fixture 1: healthy bare python3 only (Darwin) → rc 0, marker ABSENT.
#   Launch-skip branch fires: command -v succeeds, non-WindowsApps, label
#   python3 on non-Windows uname → accepted WITHOUT health_check.
# ============================================================
test_fix1_healthy_bare_python3() {
  begin "fix1_healthy_bare_python3 (rc 0, marker ABSENT)"
  local marker out rc
  marker=$(new_marker)
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "plant_marker_python 0 '$marker'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "0" ] || fail "expected rc=0, got '$rc' (out=$out)"
  assert_marker_absent "$marker" "fix1 python3 launch"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 2: broken venv + NO python3/python fallback (Darwin) → rc 12,
#   marker PRESENT. The VENV candidate is health_checked (label VENV does NOT
#   match the skip branch); it launch-fails, and with no fallback python the
#   resolver returns 12.
# ============================================================
test_fix2_broken_venv_no_fallback() {
  begin "fix2_broken_venv_no_fallback (rc 12, marker PRESENT)"
  local marker venv out rc
  marker=$(new_marker)
  # with_missing_python curates a coreutils-only PATH (no python3/python/py).
  # The broken venv is the ONLY candidate that resolves; it must be launched.
  venv=$(plant_marker_venv 49 "$marker")
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "export VIRTUAL_ENV='$venv'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "12" ] || fail "expected rc=12 (venv launch-fail, no fallback), got '$rc' (out=$out)"
  assert_marker_present "$marker" "fix2 venv launch"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 3: broken venv + healthy bare python3 fallback (Darwin) → rc 0.
#   venv marker PRESENT (venv launch attempted, health_check ran and FAILED),
#   then the bare python3 fallthrough is skip-accepted (no python3 launch).
#   We give the venv and python3 SEPARATE markers so we can assert the venv
#   launched but the python3 did NOT.
# ============================================================
test_fix3_broken_venv_then_healthy_python3() {
  begin "fix3_broken_venv_then_healthy_python3 (rc 0, venv PRESENT, py3 ABSENT)"
  local venv_marker py3_marker venv out rc
  venv_marker=$(new_marker)
  py3_marker=$(new_marker)
  venv=$(plant_marker_venv 49 "$venv_marker")
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "plant_marker_python 0 '$py3_marker'" \
    "export VIRTUAL_ENV='$venv'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "0" ] || fail "expected rc=0 (python3 fallthrough), got '$rc' (out=$out)"
  assert_marker_present "$venv_marker" "fix3 venv launch (health_check ran)"
  assert_marker_absent  "$py3_marker"  "fix3 python3 launch (must be skipped)"
  rm -f "$venv_marker" "$py3_marker"
  end
}

# ============================================================
# Fixture 4: metachar REIN_PYTHON ('a;b') → rc 12, marker ABSENT.
#   validate_runner_override rejects the value and resolve_python returns 12
#   BEFORE the candidate loop — nothing is ever launched.
# ============================================================
test_fix4_metachar_rein_python() {
  begin "fix4_metachar_rein_python (rc 12, marker ABSENT)"
  local marker out rc
  marker=$(new_marker)
  # A healthy python3 is also present to prove the reject is immediate (we do
  # NOT fall through to it) — but it must never launch either.
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "plant_marker_python 0 '$marker'" \
    "export REIN_PYTHON='a;b'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "12" ] || fail "expected rc=12 (metachar reject), got '$rc' (out=$out)"
  assert_marker_absent "$marker" "fix4 any launch"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 5: nonexistent REIN_PYTHON=/nonexistent + healthy bare python3
#   (Darwin) → rc 0, marker ABSENT.
#   The override is NOT a metachar, so it passes validate; but command -v
#   /nonexistent fails → treated as missing → fallthrough to bare python3,
#   which is skip-accepted (no launch). KEY: nonexistent != rc 12.
# ============================================================
test_fix5_nonexistent_rein_python_falls_through() {
  begin "fix5_nonexistent_rein_python_falls_through (rc 0, marker ABSENT)"
  local marker out rc
  marker=$(new_marker)
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "plant_marker_python 0 '$marker'" \
    "export REIN_PYTHON='/nonexistent'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "0" ] || fail "expected rc=0 (nonexistent override falls through, NOT 12), got '$rc' (out=$out)"
  assert_marker_absent "$marker" "fix5 python3 launch"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 6: executable-but-failing REIN_PYTHON (exit 49) + NO python3/python
#   fallback (Darwin) → rc 12, marker PRESENT.
#   REIN_PYTHON carries label REIN_PYTHON → it IS health_checked → launch
#   recorded → launch-fail → no fallback → rc 12.
# ============================================================
test_fix6_failing_rein_python_no_fallback() {
  begin "fix6_failing_rein_python_no_fallback (rc 12, marker PRESENT)"
  local marker rein_py out rc
  marker=$(new_marker)
  rein_py=$(plant_marker_rein_python 49 "$marker")
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "export REIN_PYTHON='$rein_py'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "12" ] || fail "expected rc=12 (REIN_PYTHON launch-fail, no fallback), got '$rc' (out=$out)"
  assert_marker_present "$marker" "fix6 REIN_PYTHON launch (health_check ran)"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 7: MSYS uname + bare python3 → rc 0, marker PRESENT.
#   On the Windows family (MSYS_NT) the launch-skip branch is intentionally
#   bypassed (`MINGW*|MSYS*|CYGWIN*) :`), so the bare python3 is still
#   health_checked. The fake exits 0, so it's accepted (rc 0) AND launched.
# ============================================================
test_fix7_msys_keeps_launch() {
  begin "fix7_msys_keeps_launch (rc 0, marker PRESENT)"
  local marker out rc
  marker=$(new_marker)
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'MSYS_NT-10.0'" \
    "plant_marker_python 0 '$marker'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "0" ] || fail "expected rc=0 (MSYS healthy python3), got '$rc' (out=$out)"
  assert_marker_present "$marker" "fix7 python3 launch (Windows family keeps launch)"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 8: WindowsApps stub bare python3 → rc 11, marker ABSENT.
#   command -v resolves python3 to a path containing 'WindowsApps'; the
#   case-insensitive path check fires BEFORE the launch branch → found_stub=1
#   → continue → no launch → rc 11. (Mirrors test-python-runner.sh's stub_only
#   setup: with_missing_python + prepend stub_dir + hash -r.)
# ============================================================
test_fix8_windowsapps_stub() {
  begin "fix8_windowsapps_stub (rc 11, marker ABSENT)"
  local marker stub_dir out rc len
  marker=$(new_marker)
  stub_dir=$(plant_marker_windowsapps_python "$marker")
  out=$(run_resolver \
    "with_fake_uname 'Darwin'" \
    "with_missing_python" \
    "export PATH=\"$stub_dir:\$PATH\"" \
    "hash -r")
  rc=$(parse_rc "$out")
  len=$(parse_runner_len "$out")
  [ "$rc" = "11" ] || fail "expected rc=11 (WindowsApps stub), got '$rc' (out=$out)"
  [ "$len" = "0" ] || fail "expected empty PYTHON_RUNNER, got len=$len"
  assert_marker_absent "$marker" "fix8 stub launch (path check is pre-launch)"
  rm -f "$marker"
  end
}

# ============================================================
# Fixture 9: DEVIATION — broken bare python3 only (exit 49), no REIN_PYTHON /
#   venv (Darwin) → rc 0, marker ABSENT.
#   This is the single intended behaviour change (PERF-A-EXIT-PARITY vi):
#   BEFORE the cycle this returned rc 12 (launch-fail). NOW the bare python3 is
#   accepted by the launch-skip branch BEFORE any launch, so rc 0 and the
#   breakage is deferred downstream (extract time). The marker proves no launch
#   happened.
# ============================================================
test_fix9_deviation_broken_bare_python3() {
  begin "fix9_deviation_broken_bare_python3 (rc 0 [was 12], marker ABSENT)"
  local marker out rc
  marker=$(new_marker)
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'" \
    "plant_marker_python 49 '$marker'" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "0" ] || fail "expected rc=0 (launch-skip accepts before launch; was 12 BEFORE cycle), got '$rc' (out=$out)"
  assert_marker_absent "$marker" "fix9 python3 launch (skip branch accepts pre-launch)"
  rm -f "$marker"
  end
}

# ------------------------------------------------------------
# Dispatch. Each fixture cleans up its fakes so PATH/env never leak between
# tests (run_resolver isolates via subshell; cleanup_fakes reclaims tmpdirs and
# restores PATH in THIS shell).
# ------------------------------------------------------------
test_fix1_healthy_bare_python3                 ; cleanup_fakes
test_fix2_broken_venv_no_fallback              ; cleanup_fakes
test_fix3_broken_venv_then_healthy_python3     ; cleanup_fakes
test_fix4_metachar_rein_python                 ; cleanup_fakes
test_fix5_nonexistent_rein_python_falls_through; cleanup_fakes
test_fix6_failing_rein_python_no_fallback      ; cleanup_fakes
test_fix7_msys_keeps_launch                    ; cleanup_fakes
test_fix8_windowsapps_stub                     ; cleanup_fakes
test_fix9_deviation_broken_bare_python3        ; cleanup_fakes

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
