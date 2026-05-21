#!/bin/bash
# tests/hooks/test-state-machine-integration.sh — Cycle X4.C.2
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md
#   §8.3 adversarial test (a~d):
#     T1 (a) Edit → Bash → drain → state.json.mode == "source_edit"
#     T2 (b) commit class Bash exit 0 → drain → mode == "answer" + dirty_files == []
#     T3 (c) commit class Bash exit != 0 → drain → mode == "source_edit" + dirty_files 보존
#     T4 (d) Edit + Bash 50x concurrent → journal 합산 100 entries (cross-hook race-free)

set -u

REAL_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/state-machine.sh"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
CURRENT_FAILS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && return 0
  echo "  FAIL [$label]: expected='$expected' actual='$actual'" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}
start_test() { CURRENT_TEST="$1"; CURRENT_FAILS=0; echo "TEST: $CURRENT_TEST"; }
end_test() {
  if [ "$CURRENT_FAILS" -eq 0 ]; then PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS"
  else FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
mk_sandbox() {
  SANDBOX=$(mktemp -d "/tmp/state-int-XXXXXX")
  export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
}
rm_sandbox() {
  unset REIN_PROJECT_DIR_OVERRIDE
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# Read state.json.mode (default answer if absent).
state_mode() {
  local f="$SANDBOX/.rein/state.json"
  [ -f "$f" ] || { echo "answer"; return; }
  python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]));print(d.get("mode","answer"))
except Exception: print("answer")' "$f"
}

state_dirty_count() {
  local f="$SANDBOX/.rein/state.json"
  [ -f "$f" ] || { echo "0"; return; }
  python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]));print(len(d.get("dirty_files",[])))
except Exception: print("0")' "$f"
}

# T1: Edit then drain → mode=source_edit
t1_edit_then_drain() {
  start_test "T1: Edit append + drain → state.mode == source_edit"
  mk_sandbox
  (
    source "$LIB"
    append_journal edits "edit	/tmp/file.py	source"
    drain_state
  )
  assert_eq "mode" "source_edit" "$(state_mode)"
  end_test
  rm_sandbox
}

# T2: commit class + exit 0 → mode=answer + dirty cleared
t2_commit_success_clears_dirty() {
  start_test "T2: commit class + exit 0 → drain → mode=answer + dirty_files==[]"
  mk_sandbox
  (
    source "$LIB"
    # seed state with dirty source_edit
    append_journal edits "edit	/tmp/a.py	source"
    drain_state
    append_journal bash "bash-result	0	commit"
    drain_state
  )
  assert_eq "mode" "answer" "$(state_mode)"
  assert_eq "dirty_count" "0" "$(state_dirty_count)"
  end_test
  rm_sandbox
}

# T3: commit class + exit != 0 → mode=source_edit + dirty preserved
t3_commit_fail_preserves_dirty() {
  start_test "T3: commit class + exit != 0 → drain → mode=source_edit + dirty preserved"
  mk_sandbox
  (
    source "$LIB"
    append_journal edits "edit	/tmp/a.py	source"
    drain_state
    append_journal bash "bash-result	1	commit"
    drain_state
  )
  assert_eq "mode" "source_edit" "$(state_mode)"
  # dirty file 1 보존
  count=$(state_dirty_count)
  if [ "$count" -lt 1 ]; then
    echo "  FAIL [dirty_preserved]: expected >=1 dirty, got $count" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# T4: Edit + Bash 50x concurrent → 100 entries (cross-hook race-free)
t4_cross_hook_race_free() {
  start_test "T4: 50x Edit + 50x Bash concurrent → 100 entries, all seqs distinct"
  mk_sandbox
  (
    source "$LIB"
    pids=""
    for i in $(seq 1 50); do
      ( append_journal edits "edit	/tmp/file-$i.py	source" >/dev/null 2>&1 ) &
      pids="$pids $!"
      ( append_journal bash "bash-result	0	safe" >/dev/null 2>&1 ) &
      pids="$pids $!"
    done
    for p in $pids; do wait "$p"; done
  )
  edits=$(wc -l < "$SANDBOX/.rein/state-pending-edits.log" 2>/dev/null | tr -d ' ')
  bashes=$(wc -l < "$SANDBOX/.rein/state-pending-bash.log" 2>/dev/null | tr -d ' ')
  total=$((edits + bashes))
  assert_eq "total_entries" "100" "$total"
  # Cross-file seq uniqueness:
  uniq_seqs=$(cat "$SANDBOX/.rein/state-pending-edits.log" "$SANDBOX/.rein/state-pending-bash.log" 2>/dev/null \
    | awk -F '\t' '{print $1}' | sort -u | wc -l | tr -d ' ')
  assert_eq "all_seqs_distinct" "100" "$uniq_seqs"
  end_test
  rm_sandbox
}

# T5 — codex Round 1 X4.C.2 HIGH regression: drain_state with current_class
# parameter applies the about-to-execute Bash transition (design memo §4.3 step 6).
# Before journal entries exist, dispatcher passes class=commit → state.mode==commit.
t5_current_class_transitions_before_journal() {
  start_test "T5: drain_state class=commit (no prior journals) → state.mode == commit"
  mk_sandbox
  (
    source "$LIB"
    drain_state "commit"
  )
  assert_eq "mode_after_class_commit" "commit" "$(state_mode)"

  # Reset; class=test from answer → mode=commit (test class maps to commit
  # mode entry per design §3.2 — commit mode includes test class for flush).
  mk_sandbox
  (
    source "$LIB"
    drain_state "test"
  )
  assert_eq "mode_after_class_test" "commit" "$(state_mode)"

  # safe from answer → mode=explore.
  mk_sandbox
  (
    source "$LIB"
    drain_state "safe"
  )
  assert_eq "mode_after_class_safe" "explore" "$(state_mode)"
  end_test
  rm_sandbox
}

# T7 — codex Round 2 HIGH regression: `git  commit` with repeated whitespace
# must still classify as commit (no reliance on bash-classifier.sh).
t7_git_commit_whitespace_classified() {
  start_test 'T7: git  commit (extra whitespace) via post-bash-state-journal → bash-result EXIT commit'
  mk_sandbox
  local input='{"tool_input":{"command":"git  commit -m test"},"tool_response":{"exit_code":0}}'
  ( printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$REAL_PROJECT_DIR/plugins/rein-core" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-bash-state-journal.sh" >/dev/null 2>&1
  )
  if [ -f "$SANDBOX/.rein/state-pending-bash.log" ]; then
    klass=$(awk -F '\t' '{print $5}' "$SANDBOX/.rein/state-pending-bash.log" | tail -1)
    assert_eq "git_dbl_space_commit_class" "commit" "$klass"
  else
    echo "  FAIL [journal_exists]: state-pending-bash.log not created" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# T8 — codex Round 2 Medium regression: `trail/dod/dod-foo.md` must classify
# as `dod`, NOT `trail` (specific-before-general case ordering).
t8_trail_dod_specific_classification() {
  start_test "T8: trail/dod/dod-foo.md → kind=dod (not trail), entry appended"
  mk_sandbox
  local input='{"tool_input":{"file_path":"trail/dod/dod-2026-05-21-foo.md"},"tool_response":{}}'
  ( printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$REAL_PROJECT_DIR/plugins/rein-core" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-edit-state-journal.sh" >/dev/null 2>&1
  )
  if [ -f "$SANDBOX/.rein/state-pending-edits.log" ]; then
    kind=$(awk -F '\t' '{print $5}' "$SANDBOX/.rein/state-pending-edits.log" | tail -1)
    assert_eq "dod_kind_specific" "dod" "$kind"
  else
    echo "  FAIL [journal_exists]: state-pending-edits.log missing (trail/dod should NOT be skipped)" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# T6 — Scope ID 4 regression: with state-machine.sh ABSENT (or lib source fails),
# the 3 new hooks must exit 0 (fail-soft) and not disrupt the chain.
t6_hooks_fail_soft_when_lib_absent() {
  start_test "T6: 3 hooks fail-soft when state-machine.sh absent"
  mk_sandbox
  # Construct minimal hook test env without state-machine.sh (cp hooks dir into
  # sandbox without lib/state-machine.sh).
  mkdir -p "$SANDBOX/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-edit-state-journal.sh" "$SANDBOX/hooks/"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-bash-state-journal.sh" "$SANDBOX/hooks/"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/stop-state-journal.sh" "$SANDBOX/hooks/"
  cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/"*.sh "$SANDBOX/hooks/lib/" 2>/dev/null || true
  cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/"*.py "$SANDBOX/hooks/lib/" 2>/dev/null || true
  # Explicitly remove state-machine.sh
  rm -f "$SANDBOX/hooks/lib/state-machine.sh"

  for h in post-edit-state-journal.sh post-bash-state-journal.sh stop-state-journal.sh; do
    out=$(printf '{"tool_input":{"file_path":"/tmp/a.py","command":"ls"},"tool_response":{"exit_code":0}}' \
      | env CLAUDE_PLUGIN_ROOT="$SANDBOX" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/hooks/$h" 2>&1; echo "rc=$?")
    rc=$(echo "$out" | tail -1 | sed 's/^rc=//')
    if [ "$rc" != "0" ]; then
      echo "  FAIL [$h]: expected exit 0 when lib absent, got rc=$rc" >&2
      echo "    output: $out" >&2
      CURRENT_FAILS=$((CURRENT_FAILS + 1))
    fi
  done
  end_test
  rm_sandbox
}

# T9 — codex Round 3 HIGH regression: post-bash-state-journal must NOT
# depend on bash-classifier.sh. Remove classifier from sandbox and verify
# `git commit` is still journaled with class=commit.
t9_post_bash_classifier_independent() {
  start_test "T9: post-bash hook classifier-independent — class=commit when bash-classifier.sh absent"
  mk_sandbox
  # Build sandbox WITHOUT bash-classifier.sh
  mkdir -p "$SANDBOX/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-bash-state-journal.sh" "$SANDBOX/hooks/"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/state-machine.sh" "$SANDBOX/hooks/lib/"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/python-runner.sh" "$SANDBOX/hooks/lib/"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/extract-hook-json.py" "$SANDBOX/hooks/lib/"
  # Explicitly NOT copying bash-classifier.sh
  local input='{"tool_input":{"command":"git commit -m test"},"tool_response":{"exit_code":0}}'
  ( printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$SANDBOX" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/hooks/post-bash-state-journal.sh" >/dev/null 2>&1
  )
  if [ ! -f "$SANDBOX/.rein/state-pending-bash.log" ]; then
    echo "  FAIL [journal_exists]: state-pending-bash.log missing (hook bailed early due to classifier absence)" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  else
    klass=$(awk -F '\t' '{print $5}' "$SANDBOX/.rein/state-pending-bash.log" | tail -1)
    assert_eq "class_without_classifier" "commit" "$klass"
  fi
  end_test
  rm_sandbox
}

run_all() {
  t1_edit_then_drain
  t2_commit_success_clears_dirty
  t3_commit_fail_preserves_dirty
  t4_cross_hook_race_free
  t5_current_class_transitions_before_journal
  t6_hooks_fail_soft_when_lib_absent
  t7_git_commit_whitespace_classified
  t8_trail_dod_specific_classification
  t9_post_bash_classifier_independent
}

run_all

echo ""
echo "================================"
echo "Tests run: $((PASS_COUNT + FAIL_COUNT))"
echo "Passed:    $PASS_COUNT"
echo "Failed:    $FAIL_COUNT"
echo "================================"
