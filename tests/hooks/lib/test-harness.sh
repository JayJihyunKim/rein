#!/bin/bash
# tests/hooks/lib/test-harness.sh
#
# DoD 회전 훅 테스트용 샌드박스 하네스.
# 사용법: 테스트 스크립트 상단에서 source 한 뒤 test_* 함수를 정의하고
#         main 에서 run_test test_foo 를 호출. 마지막에 summary 호출.

REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

# v1 안전 소릴리스 ①: 하니스 경유 훅 실행은 차단 로그에 source=test 로 태깅되어
# 반복 경고 카운트·incident 집계에서 제외된다 (샌드박스 격리에 더한 이중 방어).
# live 경로를 검증하는 테스트는 호출 시 REIN_TEST_MODE=0 으로 명시 override.
export REIN_TEST_MODE=1

SANDBOX=""
HOOK_STDOUT=""
HOOK_STDERR=""
HOOK_EXIT=0
TEST_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
CURRENT_FAILS=0

sandbox_setup() {
  SANDBOX=$(mktemp -d "/tmp/dod-test-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/trail/inbox"
  mkdir -p "$SANDBOX/trail/daily"
  mkdir -p "$SANDBOX/trail/weekly"
  mkdir -p "$SANDBOX/trail/incidents"
  # 훅이 공용으로 source 하는 lib/ 를 먼저 복사 (portable.sh 등)
  # Phase 3 후 dev overlay `.claude/hooks/lib` 부재 → plugin SSOT 사용
  if [ -d "$REAL_PROJECT_DIR/.claude/hooks/lib" ]; then
    mkdir -p "$SANDBOX/.claude/hooks/lib"
    cp -R "$REAL_PROJECT_DIR/.claude/hooks/lib/." "$SANDBOX/.claude/hooks/lib/"
  elif [ -d "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib" ]; then
    mkdir -p "$SANDBOX/.claude/hooks/lib"
    cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/." "$SANDBOX/.claude/hooks/lib/"
  fi
  # 호출자가 전달한 훅 파일들을 샌드박스로 복사 (누락 시 fail-fast)
  # Option C Phase 3 후 dev overlay `.claude/hooks/` 폐기 — 플러그인 SSOT
  # (`plugins/rein-core/hooks/`) 가 단일 소스. fallback 우선순위는
  # (1) dev overlay (메인테이너 환경에 잔존할 수도 있는 ad-hoc 훅 위치)
  # (2) 플러그인 SSOT (Phase 3 후 실제 본체)
  # (3) scripts/ (helper 스크립트)
  for h in "$@"; do
    # (1) dev overlay 훅 (legacy / Phase 3 이후 통상 부재)
    local src="$REAL_PROJECT_DIR/.claude/hooks/$h"
    if [ -f "$src" ]; then
      cp "$src" "$SANDBOX/.claude/hooks/$h"
      chmod +x "$SANDBOX/.claude/hooks/$h"
      continue
    fi
    # (2) 플러그인 SSOT 훅 (Phase 3 후 단일 진실 소스)
    src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/$h"
    if [ -f "$src" ]; then
      cp "$src" "$SANDBOX/.claude/hooks/$h"
      chmod +x "$SANDBOX/.claude/hooks/$h"
      continue
    fi
    # (3) 스크립트 파일 시도
    src="$REAL_PROJECT_DIR/scripts/$h"
    if [ -f "$src" ]; then
      cp "$src" "$SANDBOX/scripts/$h"
      chmod +x "$SANDBOX/scripts/$h"
      continue
    fi
    # 모두 없으면 실패
    echo "sandbox_setup: file not found: $h (checked .claude/hooks, plugins/rein-core/hooks, scripts)" >&2
    sandbox_teardown
    return 1
  done
}

sandbox_teardown() {
  # Bounded retry (Phase 7 wave 3 ③-b code review round 3, Medium —
  # 재현 완료: `bash tests/hooks/run-all.sh` 1회 실행에서 "Directory not
  # empty" 9건 + `/tmp/dod-test-*` 신규 잔존 7건 관측). 원인: 몇몇
  # tests/hooks/*.sh (예: test-active-task-authority-switch.sh) 는 실제
  # rein 파이썬 패키지를 샌드박스에 심볼릭 링크한다(`$SANDBOX/.claude/rein`
  # → plugins/rein-core/rein). 그 상태에서 훅이 hooks/lib/shadow-capture.sh
  # 의 fire-and-forget 배경 서브셸(disown 된 python)을 태우면, 그
  # 프로세스는 훅 자신이 exit 한 뒤에도 살아남아 `$SANDBOX/.rein/...` 에
  # corpus 기록을 계속 시도한다 — 바로 다음의 즉시 `rm -rf` 와 경쟁한다.
  #
  # 이 지연은 훅 자신의 exit code/판정과 무관한 순수 관측 지연이다(shadow
  # capture 계약: 실패/지연이 훅 판정에 영향을 주지 않는다 — hooks/lib/
  # shadow-capture.sh 헤더 참조). 그래서 수리는 판정 로직이나 shadow-
  # capture.sh 자체를 건드리지 않고, teardown 만 몇 차례 짧게 재시도해
  # 그 비동기 기록의 꼬리를 흡수한다. 총 상한 ~2초(0.1초 × 최대 20회) —
  # 어떤 테스트 단언도 이 타이밍에 의존하지 않는다(teardown 인프라 한정,
  # tests/hooks/test-sandbox-teardown-retry.sh 가 재시도 로직 자체를
  # 결정론적으로 고정한다). 상한을 다 써도 지우지 못하면 stderr 로만
  # 알리고 넘어간다 — teardown 실패가 테스트 판정 자체를 흔들면 안 된다.
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    local _attempt=0
    while [ "$_attempt" -lt 20 ]; do
      rm -rf "$SANDBOX" 2>/dev/null
      [ -d "$SANDBOX" ] || break
      _attempt=$((_attempt + 1))
      sleep 0.1
    done
    if [ -d "$SANDBOX" ]; then
      echo "sandbox_teardown: could not fully remove $SANDBOX after retrying (leaked background writer?)" >&2
    fi
  fi
  SANDBOX=""
}

seed_dod() {
  # $1=filename, $2=content(optional)
  local fname="$1"
  local content="${2:-# DoD: ${fname%.md}
- placeholder}"
  printf '%s\n' "$content" > "$SANDBOX/trail/dod/$fname"
}

seed_inbox() {
  local fname="$1"
  local content="${2:-# Inbox: ${fname%.md}
- placeholder}"
  printf '%s\n' "$content" > "$SANDBOX/trail/inbox/$fname"
}

seed_daily() {
  local fname="$1"
  local content="${2:-# Daily Summary: ${fname%.md}}"
  printf '%s\n' "$content" > "$SANDBOX/trail/daily/$fname"
}

set_file_mtime() {
  # $1=relative path inside sandbox, $2=YYYY-MM-DD
  local path="$SANDBOX/$1"
  local date="$2"
  touch -t "${date//-/}0000" "$path" 2>/dev/null \
    || touch -d "$date" "$path" 2>/dev/null
}

run_hook() {
  # $1=hook name, $2=stdin JSON(optional, default "{}")
  # REIN_PROJECT_DIR_OVERRIDE pins PROJECT_DIR resolution to the sandbox so
  # the project-dir.sh helper does not fall back to `git rev-parse` against
  # the test runner's cwd (which is rein-dev itself).
  local hook_name="$1"
  local stdin_json="${2-}"
  [ -z "$stdin_json" ] && stdin_json='{}'
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "$stdin_json" | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
    bash "$SANDBOX/.claude/hooks/$hook_name" \
    > "$tmp_stdout" 2> "$tmp_stderr"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_stdout")
  HOOK_STDERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr"
  return 0
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

assert_exit() {
  # $1=expected exit code, $2=message
  [ "$HOOK_EXIT" = "$1" ] || fail "${2:-exit code} (expected: $1, got: $HOOK_EXIT)"
}

assert_file_exists() {
  [ -f "$SANDBOX/$1" ] || fail "file missing: $1"
}

assert_file_missing() {
  [ ! -e "$SANDBOX/$1" ] || fail "file should not exist: $1"
}

assert_file_contains() {
  # $1=path, $2=literal pattern
  if [ ! -f "$SANDBOX/$1" ]; then
    fail "assert_file_contains: file missing: $1"
    return
  fi
  grep -qF "$2" "$SANDBOX/$1" || fail "file $1 missing pattern: $2"
}

assert_file_not_contains() {
  if [ ! -f "$SANDBOX/$1" ]; then
    return  # missing file trivially does not contain
  fi
  ! grep -qF "$2" "$SANDBOX/$1" || fail "file $1 has unexpected pattern: $2"
}

assert_stderr_contains() {
  echo "$HOOK_STDERR" | grep -qF "$1" || fail "stderr missing: $1"
}

assert_eq() {
  # $1=expected, $2=actual, $3=message
  [ "$1" = "$2" ] || fail "${3:-assert_eq} (expected: '$1', got: '$2')"
}

# assert_true: evaluate a bash condition string. Uses eval intentionally to allow
# test-shaped conditions like "[ -f \"$path\" ]". Internal to the test harness —
# never call with user-supplied input.
assert_true() {
  # $1=bash condition string, $2=message
  eval "$1" || fail "${2:-assert_true}: condition false: $1"
}

run_test() {
  # $1=test function name, $2...=hook files to copy into sandbox
  local fn="$1"
  shift
  CURRENT_TEST="$fn"
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  if ! sandbox_setup "$@"; then
    fail "sandbox_setup failed"
    CURRENT_TEST=""
    return
  fi
  # 비정상 종료에도 샌드박스 정리 보장
  trap 'sandbox_teardown' RETURN
  echo "RUN $fn"
  "$fn"
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
  trap - RETURN
  sandbox_teardown
  CURRENT_TEST=""
}

summary() {
  local pass=$((TEST_COUNT - FAIL_COUNT))
  echo ""
  echo "================================"
  echo "Tests run: $TEST_COUNT"
  echo "Passed:    $pass"
  echo "Failed:    $FAIL_COUNT"
  echo "================================"
  [ "$FAIL_COUNT" -eq 0 ]
}

# ============================================================
# Fake command helpers (test-python-runner.sh and friends)
#
# These helpers construct temporary directories containing fake
# executables and prepend them to $PATH in the current shell.
# They are designed for isolated use inside a subshell: spawn a
# subshell, call the fakes, run resolver logic, then let the
# subshell exit (or call cleanup_fakes explicitly).
#
# Contract:
#   * Each helper mktemp -d's a fresh directory so multiple fakes
#     can be stacked (later calls win thanks to PATH order).
#   * The first helper call snapshots $PATH into _ORIG_PATH so that
#     cleanup_fakes can restore it. Nested calls reuse the snapshot.
#   * cleanup_fakes removes every registered tmpdir and restores
#     PATH. Idempotent. Safe to call from a RETURN trap.
#
# IMPORTANT: these mutate PATH of the current shell — callers that
# need isolation between tests should wrap the sequence inside
# `( ... )` subshells or ensure cleanup_fakes runs between tests.
# ============================================================

_FAKE_DIRS=()
_ORIG_PATH=""

# with_fake_python EXIT_CODE [STDOUT_OUTPUT]
#   Drop fake python3/python executables into a fresh tmpdir and
#   prepend it to PATH. Both binaries ignore arguments and stdin,
#   print the optional STDOUT_OUTPUT, then exit with EXIT_CODE.
#   Use exit 49 to simulate Windows 9009 truncation.
with_fake_python() {
  local exit_code="${1:-0}"
  local stdout_output="${2:-}"
  local d
  d=$(mktemp -d "/tmp/fake-python-XXXXXX") || return 1
  # Use printf %q-safe heredoc — stdout_output may contain arbitrary
  # characters. We inline it as a bash string literal; callers should
  # avoid embedding single quotes.
  cat > "$d/python3" <<EOF
#!/usr/bin/env bash
# Fake python: ignore all args and stdin.
cat >/dev/null 2>&1
printf '%s' '${stdout_output//\'/\'\\\'\'}'
exit ${exit_code}
EOF
  cp "$d/python3" "$d/python"
  chmod +x "$d/python3" "$d/python"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$d")
}

# with_fake_python_custom DIRNAME EXIT_CODE
#   Like with_fake_python but places the fake under a specific
#   parent directory name (useful for testing WindowsApps-style
#   paths or paths-with-spaces). DIRNAME is appended under a fresh
#   mktemp -d; the resulting python3 path becomes
#   $parent/$DIRNAME/python3.
with_fake_python_custom() {
  local dirname="$1"
  local exit_code="${2:-0}"
  local parent d
  parent=$(mktemp -d "/tmp/fake-python-parent-XXXXXX") || return 1
  d="$parent/$dirname"
  mkdir -p "$d" || return 1
  cat > "$d/python3" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1
exit ${exit_code}
EOF
  cp "$d/python3" "$d/python"
  chmod +x "$d/python3" "$d/python"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$parent")
  printf '%s\n' "$d/python3"
}

# with_fake_py_launcher REAL_PYTHON_PATH
#   Inject a fake `py` launcher that accepts `-3 ...` and
#   forwards the remaining args to REAL_PYTHON_PATH. Used to
#   simulate the MSYS/Cygwin `py -3` fallback.
with_fake_py_launcher() {
  local real_python="$1"
  local d
  d=$(mktemp -d "/tmp/fake-py-XXXXXX") || return 1
  cat > "$d/py" <<EOF
#!/usr/bin/env bash
# Fake py launcher: recognise -3 then delegate.
if [ "\$1" = "-3" ]; then
  shift
fi
exec '${real_python//\'/\'\\\'\'}' "\$@"
EOF
  chmod +x "$d/py"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$d")
}

# with_fake_py_launcher_failing
#   Inject a fake `py` launcher that always fails (exit 49) to
#   simulate a broken WindowsApps-backed py launcher.
with_fake_py_launcher_failing() {
  local d
  d=$(mktemp -d "/tmp/fake-py-fail-XXXXXX") || return 1
  cat > "$d/py" <<'EOF'
#!/usr/bin/env bash
exit 49
EOF
  chmod +x "$d/py"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$d")
}

# with_fake_uname UNAME_STRING
#   Inject a fake `uname` that prints UNAME_STRING for any args
#   (covers `uname -s`). Used to simulate MINGW/MSYS/CYGWIN/Darwin.
with_fake_uname() {
  local uname_str="$1"
  local d
  d=$(mktemp -d "/tmp/fake-uname-XXXXXX") || return 1
  cat > "$d/uname" <<EOF
#!/usr/bin/env bash
echo '${uname_str//\'/\'\\\'\'}'
EOF
  chmod +x "$d/uname"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$d")
}

# with_empty_path
#   Minimal PATH narrowing: prepends a fresh (empty) tmpdir in front
#   of the standard coreutils dirs (/usr/bin:/bin:/usr/sbin:/sbin).
#   The tmpdir is empty, so on its own this helper does NOT hide the
#   host's real python3 — `command -v python3` will happily find
#   /usr/bin/python3 via the trailer dirs.
#
#   Intended use: as a base for stacked fakes. Callers typically
#   combine this with `with_fake_python` or `with_fake_py_launcher`,
#   which prepend their own tmpdirs containing the python binary the
#   test wants the resolver to see first. The empty tmpdir from
#   with_empty_path then sits between the fakes and the real
#   coreutils, providing a stable known-good PATH layout without
#   accidentally leaking a different host python3 from e.g.
#   /opt/homebrew/bin.
#
#   If you need the resolver to see NO python at all (rc=10), call
#   `with_missing_python` instead — it curates a coreutils-only PATH
#   with no python anywhere.
with_empty_path() {
  local d
  d=$(mktemp -d "/tmp/fake-empty-path-XXXXXX") || return 1
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  # Narrow PATH to the standard system dirs. This intentionally keeps
  # /usr/bin so the real python3 is reachable — stacked `with_fake_*`
  # helpers are responsible for prepending fakes when the test needs
  # a different python visible first.
  export PATH="$d:/usr/bin:/bin:/usr/sbin:/sbin"
  _FAKE_DIRS+=("$d")
}

# with_missing_python
#   Creates a curated PATH that (a) contains symlinks to essential
#   coreutils needed by python-runner.sh (uname, tr, mktemp, cat, ...)
#   and (b) contains NO python3/python/py at all. The resolver's
#   `command -v python3` genuinely fails, forcing the missing-candidate
#   branch (rc=10).
#
#   Why not just "exclude /usr/bin"? On macOS /usr/bin holds tr, uname,
#   mktemp, awk, sed — all of which python-runner.sh invokes. Excluding
#   /usr/bin breaks the resolver itself (e.g. `tr: command not found`
#   inside the WindowsApps detection). The symlink-curated approach
#   keeps coreutils reachable while guaranteeing no python binary is
#   findable.
#
#   Also issues `hash -r` so any cached python3 lookup from earlier in
#   the test is flushed.
with_missing_python() {
  local d tool src
  d=$(mktemp -d "/tmp/fake-missing-XXXXXX") || return 1
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  # Symlink the coreutils python-runner.sh (or any neighbouring hook
  # boilerplate) might need. Resolve them via the *current* PATH,
  # before we clobber it. Any tool not on the host is simply skipped —
  # the resolver only hard-requires uname + tr, everything else is
  # defensive.
  for tool in uname tr mktemp cat chmod cp rm grep printf awk sed \
              head tail cut env dirname basename find ls touch mv \
              date readlink realpath bash sh sleep sort wc; do
    src=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$src" ] && ln -sf "$src" "$d/$tool"
  done
  # ONLY the curated dir — no /bin. On Ubuntu /bin → /usr/bin, so
  # including /bin un-hides python3 and defeats "no python in PATH"
  # test intent (2026-04-24 7B fix). On macOS /bin is separate but we
  # still drop it for cross-platform parity — all required binaries
  # (bash, sh, coreutils) are symlinked into $d above.
  export PATH="$d"
  # Flush bash's command-lookup cache so a previously-hashed python3
  # path (e.g. from a prior assertion) doesn't leak through.
  hash -r 2>/dev/null || true
  _FAKE_DIRS+=("$d")
}

# with_mktemp_tracker LOGFILE
#   Wrap `mktemp` so every path it hands back is (a) still created for real
#   (delegates to the real system mktemp, resolved via `command -v` BEFORE
#   this helper's own tmpdir is prepended to PATH, so there is no recursion)
#   and (b) appended to LOGFILE, one path per line. The wrapper is
#   argument-transparent — it forwards "$@" untouched — so a caller that
#   passes a template (e.g. `mktemp "$dir/.foo.XXXXXX"`) behaves exactly as
#   it would against the real binary; only bare `mktemp` (no args) is
#   platform-dependent, same as without this wrapper.
#
#   Use this to catch a caller that creates a temp file/dir via mktemp but
#   forgets to remove it on some code path (e.g. an early `exit` before the
#   function's own cleanup line runs) — a resource leak that a plain
#   assert_exit/assert_file_* check cannot see, since the leaked path's name
#   is chosen at runtime and never surfaces in the caller's own output.
#   After the code under test has run, read LOGFILE and check each recorded
#   path with `[ -e "$path" ]`: still present = leaked (fail), gone = it was
#   consumed and cleaned up as expected (a file that a caller legitimately
#   `mv`s to a final destination also counts as "gone", not a leak).
#
#   Composes with the other with_fake_* helpers (same _ORIG_PATH/_FAKE_DIRS
#   bookkeeping, restored together by a single cleanup_fakes call).
with_mktemp_tracker() {
  local logfile="$1"
  local real_mktemp d
  real_mktemp=$(command -v mktemp) || return 1
  : > "$logfile" || return 1
  d=$(mktemp -d "/tmp/fake-mktemp-XXXXXX") || return 1
  cat > "$d/mktemp" <<EOF
#!/usr/bin/env bash
out=\$('$real_mktemp' "\$@") || exit \$?
printf '%s\n' "\$out" >> '$logfile'
printf '%s\n' "\$out"
EOF
  chmod +x "$d/mktemp"
  [ -z "$_ORIG_PATH" ] && _ORIG_PATH="$PATH"
  export PATH="$d:$PATH"
  _FAKE_DIRS+=("$d")
}

# with_fake_mktemp_failing
#   Build a tmpdir containing a `mktemp` executable that ALWAYS fails
#   (prints nothing, exits 1) — simulates a broken `mktemp` (full disk,
#   unwritable TMPDIR, missing coreutils) for a test that needs to verify
#   a caller fails closed rather than silently treating the empty `$(mktemp)`
#   capture as success.
#
#   Unlike the other with_fake_* helpers above, this one does NOT export
#   PATH itself and does NOT register with _FAKE_DIRS/_ORIG_PATH. Reason:
#   this repo's own test harness (run_hook's `tmp_stdout=$(mktemp)` /
#   `tmp_stderr=$(mktemp)`) and the hook code under test both call bare
#   `mktemp` with no distinguishing template argument — a global PATH
#   override would break run_hook's own bookkeeping calls in the SAME
#   shell, not just the hook subprocess being exercised. Instead this
#   helper only creates the fake dir and prints its path on stdout so the
#   caller can scope the override to a single subprocess invocation, e.g.:
#     local fakedir; fakedir=$(with_fake_mktemp_failing)
#     PATH="$fakedir:$PATH" bash "$SANDBOX/.claude/hooks/some-hook.sh" ...
#   The caller is responsible for `rm -rf "$fakedir"` when done (no
#   cleanup_fakes hookup, since it was never added to _FAKE_DIRS).
with_fake_mktemp_failing() {
  local d
  d=$(mktemp -d "/tmp/fake-mktemp-fail-XXXXXX") || return 1
  cat > "$d/mktemp" <<'EOF'
#!/usr/bin/env bash
# Always fail, no output — simulates mktemp exhaustion/unwritable TMPDIR.
exit 1
EOF
  chmod +x "$d/mktemp"
  printf '%s\n' "$d"
}

# with_fake_mktemp_succeeding_readonly
#   Build a tmpdir containing a `mktemp` executable that ALWAYS "succeeds"
#   (exit 0, prints a path) but the path it hands back cannot be written to
#   (chmod 400) — simulates the fault class mktemp exhaustion/unwritable-
#   TMPDIR fakes above do NOT cover: mktemp itself works fine (the create
#   syscall it does succeeds), yet whatever the caller does with the
#   returned path next (append data into it, for example) silently fails.
#   A caller that only checks "did mktemp exit 0 and does the path exist"
#   treats this as a healthy temp file and never notices the fault unless
#   it also checks the *next* operation on that path.
#
#   Every file this fixture hands out lives inside its own returned
#   directory (never system /tmp directly), so a single
#   `chmod -R u+w "$d" && rm -rf "$d"` after the test cleans up everything
#   it created — no strays outside the fixture's own tmpdir. Ignores its
#   arguments (like with_fake_mktemp_failing above) rather than delegating
#   to the real mktemp, since the fault being simulated is independent of
#   whatever template the caller passed.
#
#   Same non-global-PATH contract as with_fake_mktemp_failing above (see
#   its header for the full rationale) — the caller must scope this to a
#   single subprocess invocation (e.g. via _run_hook_with_fake_mktemp) and
#   is responsible for restoring write permission before `rm -rf` (a
#   caller relying on cleanup_fakes/_FAKE_DIRS won't get that for free,
#   since this helper — like with_fake_mktemp_failing — never registers
#   itself there).
with_fake_mktemp_succeeding_readonly() {
  local d
  d=$(mktemp -d "/tmp/fake-mktemp-ro-XXXXXX") || return 1
  mkdir -p "$d/out" || return 1
  cat > "$d/mktemp" <<EOF
#!/usr/bin/env bash
# Always "succeed": hand back a path to a real, existing file that has no
# write permission — mktemp's own job (allocate a unique path, create it)
# looks like it worked; only a later write into that path fails.
out="$d/out/ro-\$\$-\$RANDOM"
: > "\$out" || exit 1
chmod 400 "\$out" 2>/dev/null
printf '%s\n' "\$out"
EOF
  chmod +x "$d/mktemp"
  printf '%s\n' "$d"
}

# cleanup_fakes
#   Remove every registered fake tmpdir and restore the original PATH.
#   Safe to call multiple times. Idempotent.
cleanup_fakes() {
  local d
  for d in "${_FAKE_DIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  _FAKE_DIRS=()
  if [ -n "$_ORIG_PATH" ]; then
    export PATH="$_ORIG_PATH"
    _ORIG_PATH=""
  fi
}
