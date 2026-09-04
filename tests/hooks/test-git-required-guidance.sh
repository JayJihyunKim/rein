#!/usr/bin/env bash
# Verify hooks/lib/git-required-guidance.sh — the single source of truth for
# git-required onboarding guidance shared by session-start-bootstrap.sh and
# lib/bootstrap-check.sh (git-required-onboarding DoD).
#
#   A — non-git-dir: approval instruction + `git init` + absolute script path
#   B — git-missing: approval instruction + an install command + absolute
#       script path
#   C — unknown reason: no output, return code 1
#   D — no literal "${CLAUDE_PLUGIN_ROOT}" in either reason's output (BG-E)
#   E — size budget: each reason's output <= 1200 bytes with a realistic path
#   F — safe under `set -u` with no arguments
#   G — no command substitution on untrusted project_dir / script path
#       (dependency-free lib — never eval / never exec its arguments)
#   H — a hostile project_dir (", ;, $(, backtick, spaces) renders as ONE
#       safe argument via `printf %q` — the rendered command round-trips to
#       the exact hostile path and never executes extra shell code when
#       copy-pasted.
#   I — rein_git_required_reminder: shorter, no approval-question wording,
#       still names the git-required reason and the recovery command.
#   J — session "already shown" flag helpers round-trip.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/git-required-guidance.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB missing" >&2; exit 1; }

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1090
source "$LIB"

# Realistic-length fixtures (mirrors the field report's paths) so the size
# budget (E) is measured against something representative, not a toy path.
DEMO_DIR="/Users/jihyun/Local_Projects/study_eng"
DEMO_SCRIPT="/Users/jihyun/.claude/plugins/cache/rein/rein/2.0.2/scripts/rein-bootstrap-project.py"
BUDGET_BYTES=1200

# ---------------------------------------------------------------------------
# A: non-git-dir
# ---------------------------------------------------------------------------
OUT_A="$(rein_git_required_guidance non-git-dir "$DEMO_DIR" "$DEMO_SCRIPT")"
[ -n "$OUT_A" ] || fail "A: empty output"
case "$OUT_A" in *"FIRST"*) pass "A: contains approval instruction (FIRST)";; *) fail "A: missing approval instruction";; esac
case "$OUT_A" in *"approval"*) pass "A: mentions approval explicitly";; *) fail "A: missing the word 'approval'";; esac
case "$OUT_A" in *"git init"*) pass "A: mentions git init";; *) fail "A: missing 'git init'";; esac
case "$OUT_A" in *"$DEMO_SCRIPT"*) pass "A: contains absolute bootstrap script path";; *) fail "A: missing absolute script path";; esac
case "$OUT_A" in *"$DEMO_DIR"*) pass "A: contains absolute project dir";; *) fail "A: missing absolute project dir";; esac
case "$OUT_A" in *"Never run"*|*"do not run"*|*"without that approval"*) pass "A: contains a never-run-without-approval instruction";; *) fail "A: missing never-run-without-approval instruction";; esac

# ---------------------------------------------------------------------------
# B: git-missing
# ---------------------------------------------------------------------------
OUT_B="$(rein_git_required_guidance git-missing "$DEMO_DIR" "$DEMO_SCRIPT")"
[ -n "$OUT_B" ] || fail "B: empty output"
case "$OUT_B" in *"FIRST"*) pass "B: contains approval instruction (FIRST)";; *) fail "B: missing approval instruction";; esac
case "$OUT_B" in *"approval"*) pass "B: mentions approval explicitly";; *) fail "B: missing the word 'approval'";; esac
case "$OUT_B" in *"apt install git"*) pass "B: contains an install command (apt)";; *) fail "B: missing an install command";; esac
case "$OUT_B" in *"macOS"*) pass "B: mentions macOS install path";; *) fail "B: missing macOS install guidance";; esac
case "$OUT_B" in *"$DEMO_SCRIPT"*) pass "B: contains absolute bootstrap script path";; *) fail "B: missing absolute script path";; esac
case "$OUT_B" in *"git init"*) pass "B: still mentions git init after installing";; *) fail "B: missing git init step after install";; esac

# ---------------------------------------------------------------------------
# C: unknown reason → no output, rc=1
# ---------------------------------------------------------------------------
OUT_C="$(rein_git_required_guidance some-other-reason "$DEMO_DIR" "$DEMO_SCRIPT")"
RC_C=$?
[ -z "$OUT_C" ] && pass "C: unknown reason produces no output" || fail "C: unknown reason produced output: $OUT_C"
[ "$RC_C" = "1" ] && pass "C: unknown reason returns 1" || fail "C: unknown reason rc=$RC_C (want 1)"

# ---------------------------------------------------------------------------
# D: no literal "${CLAUDE_PLUGIN_ROOT}" leaks into either reason's output
# (BG-E class regression — an unexpanded placeholder is uncopy-pasteable).
# ---------------------------------------------------------------------------
case "$OUT_A$OUT_B" in
  *'CLAUDE_PLUGIN_ROOT'*) fail "D: literal CLAUDE_PLUGIN_ROOT leaked into guidance" ;;
  *) pass "D: no literal CLAUDE_PLUGIN_ROOT in either reason" ;;
esac

# ---------------------------------------------------------------------------
# E: size budget — each reason <= 1200 bytes with a realistic path
# ---------------------------------------------------------------------------
SIZE_A=$(printf '%s' "$OUT_A" | wc -c | tr -d ' ')
SIZE_B=$(printf '%s' "$OUT_B" | wc -c | tr -d ' ')
[ "$SIZE_A" -le "$BUDGET_BYTES" ] && pass "A: guidance size ${SIZE_A}B <= ${BUDGET_BYTES}B" || fail "A: guidance size ${SIZE_A}B exceeds ${BUDGET_BYTES}B"
[ "$SIZE_B" -le "$BUDGET_BYTES" ] && pass "B: guidance size ${SIZE_B}B <= ${BUDGET_BYTES}B" || fail "B: guidance size ${SIZE_B}B exceeds ${BUDGET_BYTES}B"

# ---------------------------------------------------------------------------
# F: safe under `set -u` with no arguments at all
# ---------------------------------------------------------------------------
F_OUT=$(bash -c '
set -u
source "'"$LIB"'"
rein_git_required_guidance
' 2>&1)
F_RC=$?
if [ "$F_RC" = "1" ] && [ -z "$F_OUT" ]; then
  pass "F: no-arguments call is safe under set -u (rc=1, no output, no unbound-variable error)"
else
  fail "F: no-arguments call under set -u: rc=$F_RC out='$F_OUT'"
fi

# ---------------------------------------------------------------------------
# G: no command substitution / exec on untrusted project_dir or script path.
# A payload embedding `$(...)` / backticks must appear (in %q-escaped form)
# in the output and must NOT actually execute (no side-effect file created).
# %q escapes `$`, `(`, `)` with backslashes, so we assert on the sentinel
# PATH substring (untouched by escaping) rather than the raw `$(touch`
# token (which %q necessarily mangles — that mangling IS the fix under
# test, see fixture H for the full round-trip assertion).
# ---------------------------------------------------------------------------
SENTINEL="$SCRIPT_DIR/.git-required-guidance-sentinel-$$"
rm -f "$SENTINEL"
PAYLOAD_DIR="/tmp/\$(touch $SENTINEL)"
OUT_G="$(rein_git_required_guidance non-git-dir "$PAYLOAD_DIR" "$DEMO_SCRIPT")"
if [ -f "$SENTINEL" ]; then
  fail "G: command substitution in project_dir was EXECUTED (sentinel file created)"
  rm -f "$SENTINEL"
else
  pass "G: command substitution in project_dir was NOT executed"
fi
case "$OUT_G" in *"$SENTINEL"*) pass "G: payload's path portion appears in the (escaped) output";; *) fail "G: payload not found in output at all";; esac

# ---------------------------------------------------------------------------
# H: a hostile project_dir containing a double quote, a semicolon,
# `$(...)`, a backtick, and spaces renders as ONE safe argument. Extract the
# rendered `python3 ... --project-dir ...` command and evaluate it with
# `python3` replaced by a canary-reporting function: the reconstructed argv
# must equal the exact hostile string, and no shell metacharacter inside it
# may execute.
# ---------------------------------------------------------------------------
H_CANARY="$SCRIPT_DIR/.git-required-guidance-hostile-canary-$$"
rm -f "$H_CANARY"
HOSTILE_DIR='/tmp/rein-"; touch '"$H_CANARY"'; echo pwned `id` $(id) spaced dir'
OUT_H="$(rein_git_required_guidance non-git-dir "$HOSTILE_DIR" "/usr/bin/python3-script.py")"
H_LINE="$(printf '%s\n' "$OUT_H" | grep -F '(2) python3')"
if [ -z "$H_LINE" ]; then
  fail "H: setup error — could not find the rendered python3 line in guidance"
else
  # Isolate "python3 <script> --project-dir <dir>" from the surrounding
  # sentence ("If yes, run in order: (1) git init  (2) ... — then tell ...").
  H_CMD="${H_LINE#*(2) }"
  H_CMD="${H_CMD% — then*}"
  H_SCRIPT_FILE="$(mktemp)"
  cat > "$H_SCRIPT_FILE" <<'FUNC'
python3() {
  printf 'ARGC=%s\n' "$#"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    printf 'ARGV_%s=%s\n' "$i" "$a"
  done
}
FUNC
  printf '%s\n' "$H_CMD" >> "$H_SCRIPT_FILE"
  H_RESULT="$(bash "$H_SCRIPT_FILE" 2>&1)"
  rm -f "$H_SCRIPT_FILE"
  # argv layout: ARGV_1=<script> ARGV_2=--project-dir ARGV_3=<dir> (the
  # canary `python3` function's own name/invocation is not itself an arg).
  H_ARGC="$(printf '%s\n' "$H_RESULT" | sed -n 's/^ARGC=//p')"
  H_ARGV3="$(printf '%s\n' "$H_RESULT" | sed -n 's/^ARGV_3=//p')"
  if [ -f "$H_CANARY" ]; then
    fail "H: hostile project_dir EXECUTED extra shell code (canary file created)"
    rm -f "$H_CANARY"
  else
    pass "H: hostile project_dir did not execute as shell code (no canary file)"
  fi
  if [ "$H_ARGC" = "3" ]; then
    pass "H: rendered command reconstructs to exactly 3 arguments (no injected extra args)"
  else
    fail "H: expected ARGC=3, got '$H_ARGC' (rendered: $H_CMD)"
  fi
  if [ "$H_ARGV3" = "$HOSTILE_DIR" ]; then
    pass "H: rendered --project-dir value round-trips to the exact hostile path"
  else
    fail "H: rendered --project-dir value mismatch (got '$H_ARGV3', want '$HOSTILE_DIR')"
  fi
fi

# ---------------------------------------------------------------------------
# I: rein_git_required_reminder — short, no approval-question wording, still
# names the git-required core message and the recovery command.
# ---------------------------------------------------------------------------
OUT_I_NONGIT="$(rein_git_required_reminder non-git-dir "$DEMO_DIR" "$DEMO_SCRIPT")"
OUT_I_GITMISS="$(rein_git_required_reminder git-missing "$DEMO_DIR" "$DEMO_SCRIPT")"
[ -n "$OUT_I_NONGIT" ] && [ -n "$OUT_I_GITMISS" ] || fail "I: reminder produced empty output"
case "$OUT_I_NONGIT" in *"FIRST"*|*"approval"*) fail "I: non-git-dir reminder still asks for approval (should not)";; *) pass "I: non-git-dir reminder has no approval-question wording";; esac
case "$OUT_I_NONGIT" in *"git init"*) pass "I: non-git-dir reminder still names git init";; *) fail "I: non-git-dir reminder missing git init";; esac
case "$OUT_I_NONGIT" in *"$DEMO_SCRIPT"*) pass "I: non-git-dir reminder contains absolute script path";; *) fail "I: non-git-dir reminder missing script path";; esac
case "$OUT_I_GITMISS" in *"FIRST"*|*"approval"*) fail "I: git-missing reminder still asks for approval (should not)";; *) pass "I: git-missing reminder has no approval-question wording";; esac
case "$OUT_I_GITMISS" in *"install"*|*"설치"*) pass "I: git-missing reminder still mentions installing git";; *) fail "I: git-missing reminder missing install mention";; esac
REM_SIZE_NONGIT=$(printf '%s' "$OUT_I_NONGIT" | wc -c | tr -d ' ')
REM_SIZE_GITMISS=$(printf '%s' "$OUT_I_GITMISS" | wc -c | tr -d ' ')
[ "$REM_SIZE_NONGIT" -lt "$SIZE_A" ] && pass "I: non-git-dir reminder (${REM_SIZE_NONGIT}B) is shorter than the full guidance (${SIZE_A}B)" || fail "I: non-git-dir reminder is not shorter than full guidance"
[ "$REM_SIZE_GITMISS" -lt "$SIZE_B" ] && pass "I: git-missing reminder (${REM_SIZE_GITMISS}B) is shorter than the full guidance (${SIZE_B}B)" || fail "I: git-missing reminder is not shorter than full guidance"

# ---------------------------------------------------------------------------
# J: session "already shown" flag helpers round-trip.
# ---------------------------------------------------------------------------
J_DIR="$(mktemp -d "/tmp/git-guidance-flag-J-XXXXXX")"
if rein_git_guidance_already_shown "$J_DIR"; then
  fail "J: flag reported shown before it was ever marked"
else
  pass "J: flag absent before first mark"
fi
rein_git_guidance_mark_shown "$J_DIR"
if rein_git_guidance_already_shown "$J_DIR"; then
  pass "J: flag present after mark"
else
  fail "J: flag still absent after rein_git_guidance_mark_shown"
fi
[ -f "$(rein_git_guidance_flag_path "$J_DIR")" ] && pass "J: flag path helper matches the actual file on disk" || fail "J: flag path helper does not match the file it created"
rm -rf "$J_DIR"

# ---------------------------------------------------------------------------
# N: rein_git_guidance_mark_shown on a READ-ONLY cache dir under bash POSIX
# mode (POSIXLY_CORRECT=1) must fail softly — the caller shell stays alive
# and the function returns 0. `:` is a POSIX special builtin: a redirection
# error on it makes a non-interactive POSIX-mode shell (bash 5) exit, which
# killed the whole SessionStart helper on Linux CI (2026-09-04, fixture S of
# test-session-start-bootstrap.sh). The flag writer must use a regular
# builtin (printf) so the failure is just a failed command.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP: N (read-only cache under POSIXLY_CORRECT=1) — running as root, chmod 555 ineffective"
else
  N_DIR="$(mktemp -d "/tmp/git-guidance-flag-N-XXXXXX")"
  mkdir -p "$N_DIR/.claude/cache"
  chmod 555 "$N_DIR/.claude/cache"
  N_OUT="$(POSIXLY_CORRECT=1 bash -c 'source "$1" && rein_git_guidance_mark_shown "$2"; rc=$?; printf "alive rc=%s\n" "$rc"' _ "$LIB" "$N_DIR" 2>&1)"
  case "$N_OUT" in
    *"alive rc=0"*) pass "N: mark_shown on a read-only cache under POSIXLY_CORRECT=1 returns 0 and leaves the caller shell alive" ;;
    *) fail "N: caller shell died or mark_shown returned non-zero under POSIXLY_CORRECT=1 with a read-only cache (got: $N_OUT)" ;;
  esac
  case "$N_OUT" in
    *"Permission denied"*) fail "N: Permission-denied diagnostic leaked to stderr (got: $N_OUT)" ;;
    *) pass "N: no Permission-denied leak on stderr" ;;
  esac
  chmod 755 "$N_DIR/.claude/cache" 2>/dev/null || true
  rm -rf "$N_DIR"
fi

# ---------------------------------------------------------------------------
# K: a project_dir containing a space (and other regex-hostile characters,
# but no literal single quote) renders via the shared quoting helper's
# preferred branch — a plain single-quoted wrap.
# ---------------------------------------------------------------------------
SPACE_DIR='/tmp/rein test dir; echo pwned `id` $(id)'
OUT_K="$(rein_git_required_guidance non-git-dir "$SPACE_DIR" "$DEMO_SCRIPT")"
case "$OUT_K" in
  *"'$SPACE_DIR'"*) pass "K: space/metachar project_dir renders single-quoted" ;;
  *) fail "K: space/metachar project_dir did not render single-quoted (got: $OUT_K)" ;;
esac

# ---------------------------------------------------------------------------
# L: a project_dir containing a literal single quote falls back to the
# `printf %q` form (hooks/lib/shell-quote.sh's documented limit) instead of
# being wrapped naively in single quotes (which would break on the embedded
# quote).
# ---------------------------------------------------------------------------
APOSTROPHE_DIR="/tmp/rein's test dir"
OUT_L="$(rein_git_required_guidance non-git-dir "$APOSTROPHE_DIR" "$DEMO_SCRIPT")"
EXPECT_L_Q="$(printf '%q' "$APOSTROPHE_DIR")"
case "$OUT_L" in
  *"$EXPECT_L_Q"*) pass "L: apostrophe project_dir falls back to the %q form" ;;
  *) fail "L: apostrophe project_dir did not fall back to the %q form (got: $OUT_L)" ;;
esac
case "$OUT_L" in
  *"'$APOSTROPHE_DIR'"*) fail "L: apostrophe project_dir must NOT render as a naive single-quoted wrap" ;;
  *) pass "L: apostrophe project_dir is not naively single-quoted" ;;
esac

# ---------------------------------------------------------------------------
# M: argv round-trip for both K's space/metachar dir and L's apostrophe dir —
# exactly one --project-dir argument, equal to the raw path, for either
# quoting branch.
# ---------------------------------------------------------------------------
assert_argv_roundtrip() {
  local label="$1" dir="$2" out="$3"
  local line
  line="$(printf '%s\n' "$out" | grep -F '(2) python3')"
  if [ -z "$line" ]; then
    fail "$label: could not find the rendered python3 line in guidance"
    return
  fi
  local cmd="${line#*(2) }"
  cmd="${cmd% — then*}"
  local script_file
  script_file="$(mktemp)"
  cat > "$script_file" <<'FUNC'
python3() {
  printf 'ARGC=%s\n' "$#"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    printf 'ARGV_%s=%s\n' "$i" "$a"
  done
}
FUNC
  printf '%s\n' "$cmd" >> "$script_file"
  local result
  result="$(bash "$script_file" 2>&1)"
  rm -f "$script_file"
  local argc argv3
  argc="$(printf '%s\n' "$result" | sed -n 's/^ARGC=//p')"
  argv3="$(printf '%s\n' "$result" | sed -n 's/^ARGV_3=//p')"
  if [ "$argc" = "3" ]; then
    pass "$label: exactly one --project-dir argument (argc=3)"
  else
    fail "$label: expected argc=3, got '$argc' (cmd: $cmd)"
  fi
  if [ "$argv3" = "$dir" ]; then
    pass "$label: --project-dir value round-trips to the exact raw path"
  else
    fail "$label: --project-dir mismatch (got '$argv3', want '$dir')"
  fi
}
assert_argv_roundtrip "M(space)" "$SPACE_DIR" "$OUT_K"
assert_argv_roundtrip "M(apostrophe)" "$APOSTROPHE_DIR" "$OUT_L"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-git-required-guidance: OK"
  exit 0
else
  echo "test-git-required-guidance: $FAIL assertion(s) FAILED" >&2
  exit 1
fi
