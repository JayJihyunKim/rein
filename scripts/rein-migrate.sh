#!/usr/bin/env bash
# scripts/rein-migrate.sh — top-level orchestrator for `rein migrate`.
#
# Plugin-First Restructure Phase 4 (Plan §869-1166, Spec §3.2 / §3.3).
#
# Ordered execution contract (lock outermost, project.json write-last):
#
#   step 1  — lock acquire           (Task 4.1)
#   step 2  — manifest 처리          (Task 4.2 + 4.3 + 4.7 CLAUDE.md guard)
#   step 3  — plugin install         (Task 4.8)
#   step 4  — router git mv          (Task 4.4)
#   step 5  — runtime/ initialize    (Task 4.9)
#   step 6  — project.json write     (Task 4.10) — write-last invariant
#   step 7  — lock release           (Task 4.1 release)
#
# Pre-flight (Task 4.5 + 4.6):
#   * `.rein/project.json` mode=plugin + manifest absent + lock absent
#       -> "Already migrated. No changes." exit 0
#   * lock present but project.json absent (incomplete state)
#       -> "Migration in progress. Run 'rein migrate --resume'." exit 1
#
# This wrapper does NOT touch CLAUDE.md / .claude/CLAUDE.md unless they are
# explicitly tracked by manifest-v2 with sha256 (handled by Task 4.2 with the
# Task 4.7 sha256 untouched-guard around it).

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory so we can find sibling helper scripts even when
# invoked from a different cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_PY="$SCRIPT_DIR/rein-migrate-lock.py"
MANIFEST_PY="$SCRIPT_DIR/rein-migrate-process-manifest.py"
ROUTER_SH="$SCRIPT_DIR/rein-migrate-router.sh"
INSTALL_PLUGIN_PY="$SCRIPT_DIR/rein-install-plugin-to-settings.py"
RUNTIME_INIT_PY="$SCRIPT_DIR/rein-runtime-init.py"
PROJECT_JSON_PY="$SCRIPT_DIR/rein-write-project-json.py"

REIN_PLUGIN_VERSION_DEFAULT="^1.0.0"

# ---------------------------------------------------------------------------
# Pre-flight: idempotency + incomplete-state detection
# ---------------------------------------------------------------------------
if [ -f ".rein/.migration-in-progress" ]; then
  echo "Migration in progress detected. Run 'rein migrate --resume'." >&2
  echo "--- lock metadata ---" >&2
  cat ".rein/.migration-in-progress" >&2 || true
  exit 1
fi

if [ -f ".rein/project.json" ] && [ ! -f ".claude/.rein-manifest.json" ]; then
  MODE="$(python3 -c 'import json,sys; \
    print(json.load(open(".rein/project.json")).get("mode",""))' \
    2>/dev/null || echo "")"
  if [ "$MODE" = "plugin" ]; then
    # Spec §3.3 requires "plugin enabled" before declaring already-migrated —
    # i.e. the rein entry exists in some scope's settings.json plugins
    # key. Inspect project + local + user scopes (managed is rare); ANY of
    # them carrying rein counts as enabled.
    PLUGIN_ENABLED="$(python3 - <<'PY'
import json
import os
from pathlib import Path

candidates = [
    Path(".claude/settings.json"),
    Path(".claude/settings.local.json"),
    Path(".claude/managed-settings.json"),
    Path.home() / ".claude" / "settings.json",
]
for p in candidates:
    if not p.is_file():
        continue
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    plugins = data.get("plugins", {})
    if isinstance(plugins, dict) and "rein" in plugins:
        print("yes")
        break
else:
    print("no")
PY
    )"
    if [ "$PLUGIN_ENABLED" = "yes" ]; then
      echo "Already migrated. No changes."
      exit 0
    fi
    # mode=plugin but plugin not enabled in any scope — treat as incomplete
    # and fall through to step 3 to install the entry. Lock + write-last
    # remain the transactional boundary.
  fi
fi

# ---------------------------------------------------------------------------
# step 1 — lock acquire (atomic O_CREAT|O_EXCL)
# ---------------------------------------------------------------------------
python3 "$LOCK_PY" acquire

# Ensure lock is released even on script crash (best-effort — POSIX trap).
# If user wants explicit incomplete-state for resume, the release step is
# only run after step 6 (project.json write) succeeds.
cleanup_on_error() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "rein-migrate: aborted with exit $rc; lock left at .rein/.migration-in-progress" >&2
    echo "rein-migrate: re-run 'rein migrate' to retry (idempotent if already partially applied)." >&2
  fi
}
trap cleanup_on_error EXIT

# ---------------------------------------------------------------------------
# step 2 — manifest processing (sha256 unmodified -> remove,
#                              mismatch -> backup, CLAUDE.md guarded)
# ---------------------------------------------------------------------------
if [ -f ".claude/.rein-manifest.json" ]; then
  python3 "$MANIFEST_PY"
fi

# ---------------------------------------------------------------------------
# step 3 — plugin install via settings mutation (Task 4.8)
# Allow caller to override scope via REIN_MIGRATE_SCOPE (default: project).
# ---------------------------------------------------------------------------
SCOPE="${REIN_MIGRATE_SCOPE:-project}"
python3 "$INSTALL_PLUGIN_PY" \
  --scope "$SCOPE" \
  --plugin "rein=$REIN_PLUGIN_VERSION_DEFAULT"

# ---------------------------------------------------------------------------
# step 4 — router data git mv to .rein/policy/router/
# ---------------------------------------------------------------------------
bash "$ROUTER_SH"

# ---------------------------------------------------------------------------
# step 5 — runtime/ initialize under ${CLAUDE_PLUGIN_DATA}
# ---------------------------------------------------------------------------
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/rein}" \
  python3 "$RUNTIME_INIT_PY"

# ---------------------------------------------------------------------------
# step 6 — project.json atomic write-last (single source of truth for
# completion).  Task 4.10 guarantees temp+rename + fsync.
# ---------------------------------------------------------------------------
VERSION="${REIN_MIGRATE_VERSION:-1.0.0}"
python3 "$PROJECT_JSON_PY" \
  --mode plugin \
  --scope "$SCOPE" \
  --version "$VERSION"

# ---------------------------------------------------------------------------
# step 7 — lock release (atomic delete)
# ---------------------------------------------------------------------------
python3 "$LOCK_PY" release

# Disarm the trap; we exited cleanly.
trap - EXIT

echo "rein-migrate: completed (mode=plugin scope=$SCOPE version=$VERSION)"
