#!/usr/bin/env bash
# test-post-edit-review-gate-external-paths.sh
#
# Regression test for incident bash-guard-2fbe7edae5a10b1f (declined as
# bug, fixed at the hook source). post-edit-review-gate.sh used to create
# trail/dod/.review-pending even when subagent-driven codex/security review
# wrote temp .sh fixtures via mktemp -d (typically under /var/folders/ on
# macOS or /tmp/* on Linux). The fix exempts paths outside PROJECT_DIR so
# external absolute paths no longer mark the gate dirty.
#
# Assertions:
#   (a) Hook with tool_input.file_path = "/tmp/foo.sh" (outside PROJECT_DIR)
#       MUST NOT create or update .review-pending.
#   (b) Hook with tool_input.file_path = "/var/folders/AB/foo.sh" (macOS
#       mktemp -d default location, outside PROJECT_DIR) MUST NOT create or
#       update .review-pending.
#   (c) Hook with tool_input.file_path = "$PROJECT_DIR/scripts/foo.sh"
#       (in-project absolute path, .sh source extension) MUST create or
#       refresh .review-pending.
#   (d) Hook with tool_input.file_path = "scripts/foo.sh" (in-project
#       relative path) MUST create or refresh .review-pending.
#
# The test snapshots the original .review-pending state and restores it at
# the end (trap), so running this test does not perturb the gate in the
# parent session.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-review-gate.sh"
PENDING="$PROJECT_DIR/trail/dod/.review-pending"

[ -f "$HOOK" ] || { echo "FAIL: hook missing at $HOOK" >&2; exit 1; }

# --- snapshot + restore .review-pending around assertions ---------------
SNAP_DIR="$(mktemp -d -t review-gate-snap-XXXXXX)"
SNAP_FILE="$SNAP_DIR/snap"
trap 'set +e; if [ -f "$SNAP_FILE.exists" ]; then cp "$SNAP_DIR/saved-pending" "$PENDING" 2>/dev/null; touch -r "$SNAP_DIR/saved-pending" "$PENDING" 2>/dev/null; else rm -f "$PENDING" 2>/dev/null; fi; rm -rf "$SNAP_DIR"' EXIT

if [ -f "$PENDING" ]; then
  cp "$PENDING" "$SNAP_DIR/saved-pending"
  touch -r "$PENDING" "$SNAP_DIR/saved-pending"
  : > "$SNAP_FILE.exists"
fi

# --- helper: invoke hook with synthetic Edit tool_input.file_path -------
run_hook_assert_pending() {
  local file_path="$1"
  local expect="$2"  # "created" or "untouched"
  local before_mtime="absent"
  local before_size="absent"
  if [ -f "$PENDING" ]; then
    before_mtime="$(stat -f '%m' "$PENDING" 2>/dev/null || stat -c '%Y' "$PENDING" 2>/dev/null || echo "$before_mtime")"
    before_size="$(stat -f '%z' "$PENDING" 2>/dev/null || stat -c '%s' "$PENDING" 2>/dev/null || echo "$before_size")"
  fi

  # Sleep 1s so mtime resolution catches a refresh-touch reliably.
  sleep 1

  local input
  input="$(printf '{"tool_input":{"file_path":"%s"}}' "$file_path")"
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1 || true

  local after_mtime="absent"
  local after_size="absent"
  if [ -f "$PENDING" ]; then
    after_mtime="$(stat -f '%m' "$PENDING" 2>/dev/null || stat -c '%Y' "$PENDING" 2>/dev/null || echo "$after_mtime")"
    after_size="$(stat -f '%z' "$PENDING" 2>/dev/null || stat -c '%s' "$PENDING" 2>/dev/null || echo "$after_size")"
  fi

  local changed="no"
  if [ "$before_mtime" != "$after_mtime" ] || [ "$before_size" != "$after_size" ]; then
    changed="yes"
  fi

  case "$expect" in
    created)
      if [ "$changed" = "no" ]; then
        echo "FAIL[$file_path]: expected .review-pending to be created/refreshed but unchanged ($before_mtime → $after_mtime)" >&2
        return 1
      fi
      ;;
    untouched)
      if [ "$changed" = "yes" ]; then
        echo "FAIL[$file_path]: expected .review-pending to be untouched but changed ($before_mtime → $after_mtime)" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# --- (a) /tmp/foo.sh exempt -------------------------------------------
rm -f "$PENDING"
run_hook_assert_pending "/tmp/foo.sh" "untouched"

# --- (b) /var/folders/AB/foo.sh exempt --------------------------------
rm -f "$PENDING"
run_hook_assert_pending "/var/folders/AB/foo.sh" "untouched"

# --- (c) in-project absolute path triggers ----------------------------
rm -f "$PENDING"
run_hook_assert_pending "$PROJECT_DIR/scripts/foo.sh" "created"

# --- (d) in-project relative path triggers ----------------------------
rm -f "$PENDING"
run_hook_assert_pending "scripts/foo.sh" "created"

echo "test-post-edit-review-gate-external-paths: OK (4/4 assertions)"
