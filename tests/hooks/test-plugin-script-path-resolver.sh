#!/usr/bin/env bash
# Test: plugin-script-path.sh — resolve_helper_script (RES-1).
#
# Cases:
#   1. plugin-priority — CLAUDE_PLUGIN_ROOT/scripts/<name> exists → returned
#   2. repo-fallback   — CLAUDE_PLUGIN_ROOT/scripts absent, PROJECT_DIR/scripts/<name>
#                        exists → returned
#   3. not-found       — neither exists → exit 1
#   4. empty-arg       — empty script name → exit 1
#   5. trace-on        — REIN_RESOLVER_TRACE=1 → log file appended w/ valid format
#   6. trace-off       — REIN_RESOLVER_TRACE unset/0 → log file not created
#
# Exit code: 0 on all PASS, 1 on any FAIL.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_DIR_ROOT/plugins/rein-core/hooks/lib/plugin-script-path.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB missing" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0

SCRATCH_ROOT=$(mktemp -d "/tmp/test-resolver-XXXXXX")
trap 'rm -rf "$SCRATCH_ROOT"' EXIT

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1" >&2; }

# Each case runs in a sub-bash to avoid cross-case env leakage and the
# library's double-source guard.

# ---------------------------------------------------------------------------
# Case 1 — plugin priority
# ---------------------------------------------------------------------------
case_1_plugin_priority() {
  local dir="$SCRATCH_ROOT/case1"
  mkdir -p "$dir/plugin/scripts" "$dir/repo/scripts"
  echo '#!/bin/sh' > "$dir/plugin/scripts/foo.sh"
  echo '#!/bin/sh' > "$dir/repo/scripts/foo.sh"  # both exist; plugin should win

  local out rc
  out=$(env -i \
        HOME="$HOME" PATH="$PATH" \
        CLAUDE_PLUGIN_ROOT="$dir/plugin" \
        PROJECT_DIR="$dir/repo" \
        bash -c ". '$LIB'; resolve_helper_script foo.sh" 2>&1)
  rc=$?

  if [ "$rc" -ne 0 ]; then
    record_fail "case 1: expected exit 0, got $rc (output: $out)"
    return
  fi
  if [ "$out" != "$dir/plugin/scripts/foo.sh" ]; then
    record_fail "case 1: expected plugin path, got: $out"
    return
  fi
  record_pass "case 1: plugin-priority"
}

# ---------------------------------------------------------------------------
# Case 2 — repo fallback
# ---------------------------------------------------------------------------
case_2_repo_fallback() {
  local dir="$SCRATCH_ROOT/case2"
  # CLAUDE_PLUGIN_ROOT exists but lacks the script (typical maintainer dogfood).
  mkdir -p "$dir/plugin" "$dir/repo/scripts"
  echo '#!/bin/sh' > "$dir/repo/scripts/bar.sh"

  local out rc
  out=$(env -i \
        HOME="$HOME" PATH="$PATH" \
        CLAUDE_PLUGIN_ROOT="$dir/plugin" \
        PROJECT_DIR="$dir/repo" \
        bash -c ". '$LIB'; resolve_helper_script bar.sh" 2>&1)
  rc=$?

  if [ "$rc" -ne 0 ]; then
    record_fail "case 2: expected exit 0, got $rc (output: $out)"
    return
  fi
  if [ "$out" != "$dir/repo/scripts/bar.sh" ]; then
    record_fail "case 2: expected repo path, got: $out"
    return
  fi
  record_pass "case 2: repo-fallback"
}

# ---------------------------------------------------------------------------
# Case 3 — not found in either location
# ---------------------------------------------------------------------------
case_3_not_found() {
  local dir="$SCRATCH_ROOT/case3"
  mkdir -p "$dir/plugin/scripts" "$dir/repo/scripts"
  # neither has the requested script

  local out rc
  out=$(env -i \
        HOME="$HOME" PATH="$PATH" \
        CLAUDE_PLUGIN_ROOT="$dir/plugin" \
        PROJECT_DIR="$dir/repo" \
        bash -c ". '$LIB'; resolve_helper_script missing.sh" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    record_fail "case 3: expected non-zero exit, got 0 (output: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -q 'not found'; then
    record_fail "case 3: expected 'not found' message, got: $out"
    return
  fi
  record_pass "case 3: not-found"
}

# ---------------------------------------------------------------------------
# Case 4 — empty argument
# ---------------------------------------------------------------------------
case_4_empty_arg() {
  local dir="$SCRATCH_ROOT/case4"
  mkdir -p "$dir/plugin/scripts" "$dir/repo/scripts"

  local out rc
  out=$(env -i \
        HOME="$HOME" PATH="$PATH" \
        CLAUDE_PLUGIN_ROOT="$dir/plugin" \
        PROJECT_DIR="$dir/repo" \
        bash -c ". '$LIB'; resolve_helper_script ''" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    record_fail "case 4: expected non-zero exit on empty arg, got 0 (output: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -q 'empty argument'; then
    record_fail "case 4: expected 'empty argument' message, got: $out"
    return
  fi
  record_pass "case 4: empty-arg"
}

# ---------------------------------------------------------------------------
# Case 5 — REIN_RESOLVER_TRACE=1 produces a log line in expected format
# ---------------------------------------------------------------------------
case_5_trace_on() {
  local dir="$SCRATCH_ROOT/case5"
  mkdir -p "$dir/plugin/scripts" "$dir/repo/scripts" "$dir/tmp"
  echo '#!/bin/sh' > "$dir/plugin/scripts/baz.sh"
  local trace_log="$dir/tmp/rein-resolver-trace.log"

  # caller hook is a real file (even just a stub) so BASH_SOURCE[1] is meaningful.
  local caller="$dir/fake-caller-hook.sh"
  cat > "$caller" <<EOF
#!/bin/bash
. "$LIB"
resolve_helper_script baz.sh >/dev/null
resolve_helper_script does-not-exist 2>/dev/null
exit 0
EOF

  env -i \
    HOME="$HOME" PATH="$PATH" \
    CLAUDE_PLUGIN_ROOT="$dir/plugin" \
    PROJECT_DIR="$dir/repo" \
    TMPDIR="$dir/tmp" \
    REIN_RESOLVER_TRACE=1 \
    bash "$caller" >/dev/null 2>&1

  if [ ! -f "$trace_log" ]; then
    record_fail "case 5: expected trace log at $trace_log, not created"
    return
  fi

  local lines
  lines=$(wc -l < "$trace_log" | tr -d ' ')
  if [ "$lines" -lt 2 ]; then
    record_fail "case 5: expected ≥2 trace lines, got $lines"
    return
  fi

  # Line 1: hit. Tab-separated, 4 fields.
  local first
  first=$(head -1 "$trace_log")
  # field count check via awk
  local nf
  nf=$(printf '%s' "$first" | awk -F'\t' '{print NF}')
  if [ "$nf" -ne 4 ]; then
    record_fail "case 5: expected 4 tab-separated fields, got $nf (line: $first)"
    return
  fi

  # Field 1: ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SS)
  local ts caller_field name_field path_field
  ts=$(printf '%s' "$first" | awk -F'\t' '{print $1}')
  caller_field=$(printf '%s' "$first" | awk -F'\t' '{print $2}')
  name_field=$(printf '%s' "$first" | awk -F'\t' '{print $3}')
  path_field=$(printf '%s' "$first" | awk -F'\t' '{print $4}')

  if ! printf '%s' "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
    record_fail "case 5: timestamp format invalid: $ts"
    return
  fi
  if [ "$caller_field" != "fake-caller-hook.sh" ]; then
    record_fail "case 5: expected caller=fake-caller-hook.sh, got: $caller_field"
    return
  fi
  if [ "$name_field" != "baz.sh" ]; then
    record_fail "case 5: expected name=baz.sh, got: $name_field"
    return
  fi
  if [ "$path_field" != "$dir/plugin/scripts/baz.sh" ]; then
    record_fail "case 5: expected resolved path, got: $path_field"
    return
  fi

  # Line 2: NOT_FOUND case
  local second second_path
  second=$(sed -n '2p' "$trace_log")
  second_path=$(printf '%s' "$second" | awk -F'\t' '{print $4}')
  if [ "$second_path" != "NOT_FOUND" ]; then
    record_fail "case 5: expected NOT_FOUND on line 2, got: $second_path"
    return
  fi

  record_pass "case 5: trace-on (format + NOT_FOUND marker)"
}

# ---------------------------------------------------------------------------
# Case 6 — trace off (env unset / 0) produces no log file
# ---------------------------------------------------------------------------
case_6_trace_off() {
  local dir="$SCRATCH_ROOT/case6"
  mkdir -p "$dir/plugin/scripts" "$dir/repo/scripts" "$dir/tmp"
  echo '#!/bin/sh' > "$dir/plugin/scripts/qux.sh"
  local trace_log="$dir/tmp/rein-resolver-trace.log"

  # 6a: REIN_RESOLVER_TRACE unset (env -i wipes it)
  env -i \
    HOME="$HOME" PATH="$PATH" \
    CLAUDE_PLUGIN_ROOT="$dir/plugin" \
    PROJECT_DIR="$dir/repo" \
    TMPDIR="$dir/tmp" \
    bash -c ". '$LIB'; resolve_helper_script qux.sh" >/dev/null 2>&1

  if [ -f "$trace_log" ]; then
    record_fail "case 6a: trace log created when REIN_RESOLVER_TRACE was unset"
    return
  fi

  # 6b: REIN_RESOLVER_TRACE=0
  env -i \
    HOME="$HOME" PATH="$PATH" \
    CLAUDE_PLUGIN_ROOT="$dir/plugin" \
    PROJECT_DIR="$dir/repo" \
    TMPDIR="$dir/tmp" \
    REIN_RESOLVER_TRACE=0 \
    bash -c ". '$LIB'; resolve_helper_script qux.sh" >/dev/null 2>&1

  if [ -f "$trace_log" ]; then
    record_fail "case 6b: trace log created when REIN_RESOLVER_TRACE=0"
    return
  fi

  record_pass "case 6: trace-off (unset and =0)"
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------
case_1_plugin_priority
case_2_repo_fallback
case_3_not_found
case_4_empty_arg
case_5_trace_on
case_6_trace_off

echo
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[ "$FAIL_COUNT" -eq 0 ]
