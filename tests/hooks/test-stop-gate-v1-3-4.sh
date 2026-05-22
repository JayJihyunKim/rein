#!/bin/bash
# tests/hooks/test-stop-gate-v1-3-4.sh
#
# v1.3.4 stop-session-gate changes:
#   B3 — resolver-cache GC (.rein/cache/hook-resolver/*.json older than 24h).
#        Fail-closed deletion: fresh / unknown-mtime entries are preserved.
#        Runs BEFORE the no-src-edit early exit.
#   B7 — stale-DoD warning excludes completed DoDs (inbox slug match).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="stop-session-gate.sh"
TODAY=$(date +%Y-%m-%d)

_seed_bootstrap() {
  mkdir -p "$SANDBOX/.rein"
  printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' \
    > "$SANDBOX/.rein/project.json"
}

# Reach the stale-DoD loop: requires a finished session (inbox today + valid
# index.md) and a source edit so the gate is not skipped.
_seed_valid_session() {
  _seed_bootstrap
  seed_inbox "${TODAY}-session.md" "# session marker"
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: stop gate v1.3.4
- next: verify
- note: fixture
EOF
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
}

# ============================================================
# B3: resolver-cache GC
# ============================================================

# 24h+ stale entry is deleted; a fresh entry is preserved.
test_b3_gc_deletes_stale_keeps_fresh() {
  _seed_bootstrap
  mkdir -p "$SANDBOX/.rein/cache/hook-resolver"
  printf '{}' > "$SANDBOX/.rein/cache/hook-resolver/toolu_old.json"
  printf '{}' > "$SANDBOX/.rein/cache/hook-resolver/toolu_fresh.json"
  # Age the stale entry well past 24h (touch to an old date).
  set_file_mtime ".rein/cache/hook-resolver/toolu_old.json" "2020-01-01"
  # No .session-has-src-edit → hook exits 0 early, but GC runs BEFORE that exit.
  run_hook "$HOOK"
  assert_exit 0 "B3: no-src-edit session exits 0"
  assert_file_missing ".rein/cache/hook-resolver/toolu_old.json" \
    "B3: 24h+ stale resolver-cache entry should be GC'd"
  assert_file_exists ".rein/cache/hook-resolver/toolu_fresh.json" \
    "B3: fresh resolver-cache entry must be preserved (no fail-open wipe)"
}

# GC runs even when there was no source edit (leak path: blocked pre-edit never
# sets SRC_EDIT_MARKER) — covered by the test above running without the marker.

# GC is scoped to *.json — a non-json file (even if old) is never touched.
# This guards against an over-broad sweep (fail-closed scoping).
test_b3_gc_only_touches_json() {
  _seed_bootstrap
  mkdir -p "$SANDBOX/.rein/cache/hook-resolver"
  printf 'not json' > "$SANDBOX/.rein/cache/hook-resolver/keepme.txt"
  set_file_mtime ".rein/cache/hook-resolver/keepme.txt" "2020-01-01"
  run_hook "$HOOK"
  assert_exit 0 "B3: no-src-edit session exits 0"
  assert_file_exists ".rein/cache/hook-resolver/keepme.txt" \
    "B3: GC must only sweep *.json — non-json files are never deleted"
}

# ============================================================
# B7: stale-DoD warning excludes completed (inbox-matched) DoDs
# ============================================================

# A stale DoD whose slug matches a trail/inbox entry is COMPLETED → no warning.
test_b7_completed_stale_dod_no_warning() {
  _seed_valid_session
  # Stale DoD (>14d old by filename date) with slug "donework".
  seed_dod "dod-2020-01-01-donework.md" "# DoD donework"
  # Matching inbox entry (slug "donework") → completed.
  seed_inbox "${TODAY}-donework.md" "# done"
  run_hook "$HOOK"
  echo "$HOOK_STDERR" | grep -qF "dod-2020-01-01-donework.md" \
    && fail "B7: completed (inbox-matched) stale DoD must NOT warn"
  return 0
}

# A stale DoD with no matching inbox entry is UNFINISHED → warning fires.
test_b7_uncompleted_stale_dod_warns() {
  _seed_valid_session
  seed_dod "dod-2020-01-01-orphan.md" "# DoD orphan"
  # No inbox entry with slug "orphan".
  run_hook "$HOOK"
  assert_stderr_contains "dod-2020-01-01-orphan.md"
}

main() {
  run_test test_b3_gc_deletes_stale_keeps_fresh   "$HOOK"
  run_test test_b3_gc_only_touches_json           "$HOOK"
  run_test test_b7_completed_stale_dod_no_warning "$HOOK"
  run_test test_b7_uncompleted_stale_dod_warns    "$HOOK"
  summary
}

main "$@"
