#!/bin/bash
# tests/hooks/test-python-runner.sh
#
# Regression + unit tests for .claude/hooks/lib/python-runner.sh.
#
# Contract under test:
#   resolve_python() populates PYTHON_RUNNER (bash array) with the first
#   healthy interpreter in the order
#     REIN_PYTHON → $VIRTUAL_ENV/bin/python → python3 → python
#     → (MSYS/MINGW/CYGWIN only) py -3
#   Exit codes:
#     0  success (PYTHON_RUNNER populated)
#     10 no candidate interpreter found
#     11 all resolved candidates are WindowsApps stubs
#     12 launch failure (health_check fails) OR REIN_PYTHON invalid
#
# Test strategy:
#   Each test runs inside a subshell `( ... )` so PATH/env/traps are
#   scoped. The python-runner lib is sourced in that subshell, fake
#   helpers (test-harness with_fake_*) inject controlled python/py/uname
#   into the front of PATH, then resolve_python is invoked directly to
#   capture both rc and ${PYTHON_RUNNER[@]}. Stderr is captured via
#   file descriptor redirection where needed for diagnostics tests.
#
# Failure protocol: each test increments FAIL_COUNT on any assertion
# miss. Summary at the bottom exits non-zero if any test failed.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
. "$SCRIPT_DIR/lib/test-harness.sh"

PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_RUNNER_LIB="$PROJECT_DIR/.claude/hooks/lib/python-runner.sh"

# real_host_python: CI 가 fake stub 을 PATH 앞에 주입한 상태로 이 스크립트를
# 부를 때, 테스트 내부에서 실제 python 경로가 필요하면 REIN_TEST_REAL_PY env 를
# 먼저 참조하도록 해서 stub 오염에도 불구하고 real python 을 확보할 수 있게 한다.
# (Codex final review C3 반영)
real_host_python() {
  printf '%s\n' "${REIN_TEST_REAL_PY:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)}"
}

if [ ! -f "$PYTHON_RUNNER_LIB" ]; then
  echo "FATAL: $PYTHON_RUNNER_LIB not found" >&2
  exit 1
fi

# ------------------------------------------------------------
# Local test scaffolding. We bypass the sandbox machinery in
# test-harness.sh because these tests need to source python-runner.sh
# directly (to inspect ${PYTHON_RUNNER[@]}) rather than invoke a hook.
# We still reuse TEST_COUNT / FAIL_COUNT / fail() for consistent
# output.
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
# Prints 3 marker lines to stdout so callers can parse the outcome:
#   RC=<rc>
#   RUNNER_LEN=<n>
#   RUNNER_0=<first array element>
#   RUNNER_1=<second array element>          (if present)
#   RUNNER_JOIN=<space-joined elements>
# Arguments to run_resolver are executed *inside* the subshell
# before resolve_python, so callers can stage fakes and set env
# (REIN_PYTHON, VIRTUAL_ENV). Stderr of resolve_python is preserved.
run_resolver() {
  # Run in subshell so PATH fakes are isolated.
  (
    # Ensure clean env by default. Callers can re-export as needed
    # by passing commands in $@.
    unset REIN_PYTHON VIRTUAL_ENV
    # Execute setup commands.
    for cmd in "$@"; do
      eval "$cmd"
    done
    # shellcheck source=/dev/null
    . "$PYTHON_RUNNER_LIB"
    resolve_python
    local rc=$?
    echo "RC=$rc"
    # `set -u` + empty array: `${arr[@]}` is technically unbound.
    # Guard by skipping the loop when length is zero; ${#arr[@]} is
    # safe on an empty/unset declared array.
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

# parse helpers for run_resolver output
parse_rc() {
  echo "$1" | awk -F= '/^RC=/{print $2; exit}'
}
parse_runner_len() {
  echo "$1" | awk -F= '/^RUNNER_LEN=/{print $2; exit}'
}
parse_runner_elem() {
  # $1=output, $2=index
  echo "$1" | awk -F= -v idx="$2" '$1=="RUNNER_"idx{sub(/^RUNNER_[0-9]+=/,""); print; exit}'
}

# ============================================================
# Test 1: REIN_PYTHON override (valid path → 1순위)
# ============================================================
test_resolver_rein_python_override() {
  begin "test_resolver_rein_python_override"
  local real_py out rc first
  real_py=$(real_host_python)
  if [ -z "$real_py" ]; then
    echo "  SKIP: no real python3/python on host" >&2
    end
    return
  fi
  out=$(run_resolver "export REIN_PYTHON='$real_py'")
  rc=$(parse_rc "$out")
  first=$(parse_runner_elem "$out" 0)
  [ "$rc" = "0" ] || fail "expected rc=0, got rc='$rc' (out=$out)"
  [ "$first" = "$real_py" ] || fail "expected RUNNER_0='$real_py', got '$first'"
  end
}

# ============================================================
# Test 2: REIN_PYTHON injection reject → hard-fail rc=12
# ============================================================
test_resolver_rein_python_injection_reject() {
  begin "test_resolver_rein_python_injection_reject"
  local out rc len
  # Each metachar variant should be rejected. Test the primary one
  # (semicolon + rm -rf) plus a shell-expansion attempt.
  out=$(run_resolver "export REIN_PYTHON='python; rm -rf /'")
  rc=$(parse_rc "$out")
  len=$(parse_runner_len "$out")
  [ "$rc" = "12" ] || fail "semicolon: expected rc=12, got '$rc'"
  [ "$len" = "0" ] || fail "semicolon: expected empty PYTHON_RUNNER, got len=$len"

  # ANSI-C quoting ($'...') preserves the backtick literally when the
  # string is passed through `eval` inside run_resolver. Plain double
  # quotes would let the backtick fire as command substitution during
  # eval, which would strip the metachar BEFORE validate_runner_override
  # sees it and mask the injection. Keeping the backtick literal is the
  # whole point of this subcase.
  out=$(run_resolver $'export REIN_PYTHON=\'python`whoami`\'')
  rc=$(parse_rc "$out")
  [ "$rc" = "12" ] || fail "backtick: expected rc=12, got '$rc'"

  out=$(run_resolver 'export REIN_PYTHON="python\$(whoami)"')
  rc=$(parse_rc "$out")
  [ "$rc" = "12" ] || fail "dollar-paren: expected rc=12, got '$rc'"
  end
}

# ============================================================
# Test 3: venv priority over `py -3`
#   Even on MSYS, an active venv with a working python MUST be
#   chosen before the `py -3` fallback.
# ============================================================
test_resolver_venv_priority_over_py3() {
  begin "test_resolver_venv_priority_over_py3"
  local venv_dir venv_py out rc first
  venv_dir=$(mktemp -d "/tmp/fake-venv-XXXXXX")
  mkdir -p "$venv_dir/bin"
  # The venv python must be executable AND pass health_check
  # (`python -c 'import sys; sys.exit(0)'`). We delegate to the real
  # host python to achieve that.
  local host_py
  host_py=$(real_host_python)
  if [ -z "$host_py" ]; then
    echo "  SKIP: no real python3/python on host" >&2
    rm -rf "$venv_dir"
    end
    return
  fi
  cat > "$venv_dir/bin/python" <<EOF
#!/usr/bin/env bash
exec '$host_py' "\$@"
EOF
  chmod +x "$venv_dir/bin/python"
  # Simulate MSYS uname so the `py -3` branch would be added. The
  # venv must still win because it precedes py3 in the candidate
  # order.
  out=$(run_resolver \
    "export VIRTUAL_ENV='$venv_dir'" \
    "with_fake_uname 'MINGW64_NT-10.0-22000'")
  rc=$(parse_rc "$out")
  first=$(parse_runner_elem "$out" 0)
  [ "$rc" = "0" ] || fail "expected rc=0, got '$rc' (out=$out)"
  [ "$first" = "$venv_dir/bin/python" ] \
    || fail "expected venv python first, got '$first'"
  rm -rf "$venv_dir"
  end
}

# ============================================================
# Test 4: MSYS → py -3 fallback when python3/python fail
# ============================================================
test_resolver_msys_py3_fallback() {
  begin "test_resolver_msys_py3_fallback"
  local host_py out rc first second
  host_py=$(real_host_python)
  if [ -z "$host_py" ]; then
    echo "  SKIP: no real python3/python on host to back fake py launcher" >&2
    end
    return
  fi
  # Strategy: fake python3/python return exit 49 (simulating Windows
  # 9009 truncation). Fake py launcher delegates to the real host
  # python so health_check passes. Fake uname says MINGW so the py
  # branch is added.
  out=$(run_resolver \
    "with_empty_path" \
    "with_fake_uname 'MINGW64_NT-10.0-22000'" \
    "with_fake_python 49" \
    "with_fake_py_launcher '$host_py'")
  rc=$(parse_rc "$out")
  first=$(parse_runner_elem "$out" 0)
  second=$(parse_runner_elem "$out" 1)
  [ "$rc" = "0" ] || fail "expected rc=0, got '$rc' (out=$out)"
  # PYTHON_RUNNER should be ("py" "-3").
  [ "$first" = "py" ] || fail "expected RUNNER_0=py, got '$first'"
  [ "$second" = "-3" ] || fail "expected RUNNER_1=-3, got '$second'"
  end
}

# ============================================================
# Test 5: WindowsApps detection — mixed case path
#   `command -v python3` returns an absolute path containing
#   `WindowsApps` in mixed casing. Resolver must still detect
#   the stub via case-insensitive match.
# ============================================================
test_resolver_windowsapps_detection_case_mixed() {
  begin "test_resolver_windowsapps_detection_case_mixed"
  # Build a fake dir structure whose path literally contains
  # WINDOWSAPPS (uppercase) so the case-insensitive check in
  # resolve_python triggers. The fake python there would otherwise
  # exit 49 (stub), but stub detection happens *before* health_check
  # so the exit code is still 11.
  local parent stub_dir out rc len
  parent=$(mktemp -d "/tmp/fake-wa-XXXXXX")
  # Mixed-case folder name — the resolver lowercases the whole path
  # so this is the key assertion.
  stub_dir="$parent/AppData/Local/Microsoft/WINDOWSAPPS"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/python3" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1
exit 49
EOF
  chmod +x "$stub_dir/python3"
  # `with_missing_python` gives us a curated PATH containing only
  # coreutils (tr, uname, mktemp, ...) and NO python at all. Prepending
  # $stub_dir then makes the stub's python3 the ONLY python-named
  # executable resolver can find. Two subtle details:
  #   1. PATH is interpolated via double quotes so $PATH expands at
  #      eval time (single-quoted '$PATH' would stay literal and mask
  #      the coreutils symlinks → 'tr: command not found').
  #   2. `hash -r` flushes any cached python3 path from earlier runs
  #      — critical because bash hashes command lookups per shell.
  out=$(run_resolver \
    "with_missing_python" \
    "export PATH=\"$stub_dir:\$PATH\"" \
    "hash -r")
  rc=$(parse_rc "$out")
  len=$(parse_runner_len "$out")
  [ "$rc" = "11" ] || fail "expected rc=11 (stub detected), got '$rc' (out=$out)"
  [ "$len" = "0" ] || fail "expected empty PYTHON_RUNNER, got len=$len"
  rm -rf "$parent"
  end
}

# ============================================================
# Test 6: all candidates fail → rc=10 (missing)
# ============================================================
test_resolver_all_candidates_fail() {
  begin "test_resolver_all_candidates_fail"
  local out rc len
  # Use `with_missing_python` (not `with_empty_path`): it curates PATH
  # so coreutils (tr/uname/mktemp) stay reachable but NO python3/
  # python/py exists anywhere on PATH. `command -v python3` genuinely
  # fails → found_missing=1, no stub, no launch-fail → rc=10.
  # `with_empty_path` would NOT work here: on macOS /usr/bin/python3
  # is still reachable via the default trailer dirs, so the resolver
  # would happily return rc=0 with the real host python3.
  # Darwin uname prevents the `py -3` branch from ever being added.
  out=$(run_resolver \
    "with_missing_python" \
    "with_fake_uname 'Darwin'")
  rc=$(parse_rc "$out")
  len=$(parse_runner_len "$out")
  [ "$rc" = "10" ] || fail "expected rc=10, got '$rc' (out=$out)"
  [ "$len" = "0" ] || fail "expected empty PYTHON_RUNNER, got len=$len"
  end
}

# ============================================================
# Test 7: stub only → rc=11
#   A stub is present but no other candidates exist. rc MUST be 11
#   (not 10) because the stub was detected.
# ============================================================
test_resolver_stub_only() {
  begin "test_resolver_stub_only"
  local parent stub_dir out rc
  parent=$(mktemp -d "/tmp/fake-stub-XXXXXX")
  stub_dir="$parent/WindowsApps"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/python3" <<'EOF'
#!/usr/bin/env bash
exit 49
EOF
  chmod +x "$stub_dir/python3"
  # Same PATH-curation strategy as the WindowsApps case-mixed test:
  # `with_missing_python` hides every real python on PATH while
  # preserving coreutils; prepending $stub_dir then makes the stub
  # the sole candidate. Double-quoted "$PATH" so it expands at eval
  # time (a literal '$PATH' would shadow the coreutils symlinks).
  out=$(run_resolver \
    "with_fake_uname 'Darwin'" \
    "with_missing_python" \
    "export PATH=\"$stub_dir:\$PATH\"" \
    "hash -r")
  rc=$(parse_rc "$out")
  [ "$rc" = "11" ] || fail "expected rc=11, got '$rc' (out=$out)"
  rm -rf "$parent"
  end
}

# ============================================================
# Test 8: launch fail, non-stub → rc=12
#   python3 exists on a non-WindowsApps path but exits 49 when
#   invoked → health_check fails → rc=12.
# ============================================================
test_resolver_launch_fail_non_stub() {
  begin "test_resolver_launch_fail_non_stub"
  local out rc
  # with_fake_python plants python3/python in a tmp dir whose path
  # does NOT contain "windowsapps". Both will fail health_check with
  # exit 49. uname=Darwin so no `py -3` branch is added.
  out=$(run_resolver \
    "with_fake_uname 'Darwin'" \
    "with_empty_path" \
    "with_fake_python 49")
  rc=$(parse_rc "$out")
  [ "$rc" = "12" ] || fail "expected rc=12 (launch fail), got '$rc' (out=$out)"
  end
}

# ============================================================
# Test 9: array safety — path with embedded space is preserved
#   as a single PYTHON_RUNNER[0] element (no injection / word split).
# ============================================================
test_python_runner_array_safety() {
  begin "test_python_runner_array_safety"
  local host_py spaced_dir spaced_py out rc first len
  host_py=$(real_host_python)
  if [ -z "$host_py" ]; then
    echo "  SKIP: no real python3/python on host" >&2
    end
    return
  fi
  # Build a python executable whose path has a space.
  spaced_dir=$(mktemp -d "/tmp/fake py dir XXXXXX")
  spaced_py="$spaced_dir/python3"
  cat > "$spaced_py" <<EOF
#!/usr/bin/env bash
exec '$host_py' "\$@"
EOF
  chmod +x "$spaced_py"
  # Feed this path via REIN_PYTHON (single-token, ntok=1) — the
  # resolver must preserve the space.
  out=$(run_resolver "export REIN_PYTHON='$spaced_py'")
  rc=$(parse_rc "$out")
  len=$(parse_runner_len "$out")
  first=$(parse_runner_elem "$out" 0)
  [ "$rc" = "0" ] || fail "expected rc=0, got '$rc' (out=$out)"
  [ "$len" = "1" ] || fail "expected RUNNER_LEN=1 (no word-split), got $len"
  [ "$first" = "$spaced_py" ] \
    || fail "expected RUNNER_0='$spaced_py', got '$first'"
  rm -rf "$spaced_dir"
  end
}

# ============================================================
# Test 10: diagnostics print on MSYS (contains 9009 / WSL2 /
# App execution alias keywords).
# ============================================================
test_diagnostics_print_on_msys() {
  begin "test_diagnostics_print_on_msys"
  local diag
  # Capture stdout of print_windows_diagnostics_if_applicable under
  # fake uname = MINGW. The function emits to stdout (callers
  # redirect to stderr themselves).
  diag=$(
    # shellcheck disable=SC2030
    (
      unset REIN_PYTHON VIRTUAL_ENV
      # shellcheck source=/dev/null
      . "$SCRIPT_DIR/lib/test-harness.sh"
      with_fake_uname "MINGW64_NT-10.0-22000"
      # shellcheck source=/dev/null
      . "$PYTHON_RUNNER_LIB"
      print_windows_diagnostics_if_applicable
    )
  )
  echo "$diag" | grep -q "9009" \
    || fail "diagnostics missing '9009' keyword (got: $(echo "$diag" | head -3 | tr '\n' ' '))"
  echo "$diag" | grep -q "WSL2" \
    || fail "diagnostics missing 'WSL2' keyword"
  # The heredoc uses "App execution aliases" (plural, spelling from
  # the source). Accept either the exact phrase or the substring
  # "App execution alias".
  echo "$diag" | grep -q "App execution alias" \
    || fail "diagnostics missing 'App execution alias' keyword"
  end
}

# ============================================================
# Test 11: diagnostics silent on POSIX (Darwin/Linux)
# ============================================================
test_diagnostics_silent_on_posix() {
  begin "test_diagnostics_silent_on_posix"
  local diag_darwin diag_linux
  diag_darwin=$(
    (
      unset REIN_PYTHON VIRTUAL_ENV
      # shellcheck source=/dev/null
      . "$SCRIPT_DIR/lib/test-harness.sh"
      with_fake_uname "Darwin"
      # shellcheck source=/dev/null
      . "$PYTHON_RUNNER_LIB"
      print_windows_diagnostics_if_applicable
    )
  )
  [ -z "$diag_darwin" ] \
    || fail "Darwin should be silent, got: $(echo "$diag_darwin" | head -1)"

  diag_linux=$(
    (
      unset REIN_PYTHON VIRTUAL_ENV
      # shellcheck source=/dev/null
      . "$SCRIPT_DIR/lib/test-harness.sh"
      with_fake_uname "Linux"
      # shellcheck source=/dev/null
      . "$PYTHON_RUNNER_LIB"
      print_windows_diagnostics_if_applicable
    )
  )
  [ -z "$diag_linux" ] \
    || fail "Linux should be silent, got: $(echo "$diag_linux" | head -1)"
  end
}

# ============================================================
# Test 12: parse check — ensure python-runner.sh itself parses
# under `bash -n`. A syntax regression here would break every
# hook that sources it.
# ============================================================
test_python_runner_lib_parse_check() {
  begin "test_python_runner_lib_parse_check"
  bash -n "$PYTHON_RUNNER_LIB" \
    || fail "bash -n failed on $PYTHON_RUNNER_LIB"
  end
}

# ------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------
test_resolver_rein_python_override
test_resolver_rein_python_injection_reject
test_resolver_venv_priority_over_py3
test_resolver_msys_py3_fallback
test_resolver_windowsapps_detection_case_mixed
test_resolver_all_candidates_fail
test_resolver_stub_only
test_resolver_launch_fail_non_stub
test_python_runner_array_safety
test_diagnostics_print_on_msys
test_diagnostics_silent_on_posix
test_python_runner_lib_parse_check

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
