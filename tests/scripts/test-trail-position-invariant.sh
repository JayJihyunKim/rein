#!/usr/bin/env bash
# test-trail-position-invariant.sh — Phase 3 Task 3.10.
#
# Verifies that trail/ is referenced as repo-root regardless of mode (Plan
# §854-865). The plugin-first restructure introduces mode-aware path
# resolution for governance / jobs / inventory / active-dod-choice-log,
# but trail/ MUST remain at repo root in both plugin and scaffold mode —
# trail records are workflow logs the user reads in-tree, not runtime
# cache.
#
# Contract:
#   * No plugin/scaffold source file uses ${CLAUDE_PLUGIN_DATA}/trail
#     or .rein/cache/trail anywhere — these would imply mode-aware
#     branching of trail/.
#   * Resolver does not handle "trail" as a state name (resolver fails
#     with non-zero rc when asked).
#
# Scope ID: trail-stays-in-repo-root-on-both-modes

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER="$PROJECT_DIR/plugins/rein-core/scripts/rein-state-paths.py"

[ -f "$RESOLVER" ] || { echo "FAIL: resolver missing: $RESOLVER" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# ---------------------------------------------------------------------------
# A: grep for mode-aware trail/ branching.
#
# Pattern 1: literal ``${CLAUDE_PLUGIN_DATA}/trail`` (any quoting)
# Pattern 2: literal ``.rein/cache/trail`` — would mean trail was put under
#            the per-environment cache, contradicting the invariant.
#
# We exclude tests/ (this very test contains the patterns as strings) and
# trail/ itself (incident logs may quote prior bad attempts).
# ---------------------------------------------------------------------------
search_dirs=(
  "$PROJECT_DIR/plugins/rein-core/hooks"
  "$PROJECT_DIR/plugins/rein-core/scripts"
  "$PROJECT_DIR/scripts"
  "$PROJECT_DIR/.claude/hooks"
)

for d in "${search_dirs[@]}"; do
  [ -d "$d" ] || continue
  # CLAUDE_PLUGIN_DATA + trail concatenation
  hits=$(grep -rEn '\$\{CLAUDE_PLUGIN_DATA[^}]*\}/trail' "$d" || true)
  if [ -n "$hits" ]; then
    echo "FAIL: mode-aware trail under CLAUDE_PLUGIN_DATA found in $d:" >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
  # .rein/cache/trail
  hits=$(grep -rEn '\.rein/cache/trail' "$d" || true)
  if [ -n "$hits" ]; then
    echo "FAIL: mode-aware trail under .rein/cache/ found in $d:" >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
done
ok "A: no mode-aware trail/ references in hooks / scripts / plugins"

# ---------------------------------------------------------------------------
# B: rein-state-paths.py rejects "trail" as a state name (it is not in
#    STATE_FILES).
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

set +e
( cd "$TMP_DIR" && python3 "$RESOLVER" trail </dev/null \
    >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" )
B_RC=$?
set -e
[ "$B_RC" != "0" ] || fail "B: resolver accepted 'trail' (state name leak)"
ok "B: resolver rejects 'trail' as a state name (rc=$B_RC)"

# ---------------------------------------------------------------------------
# C: hooks reference trail/ at repo root only — sample literal forms used
#    in pre-edit-dod-gate.sh + select-active-dod.sh stay relative.
# ---------------------------------------------------------------------------
sample_files=(
  "$PROJECT_DIR/plugins/rein-core/hooks/pre-edit-dod-gate.sh"
  "$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  "$PROJECT_DIR/.claude/hooks/pre-edit-dod-gate.sh"
  "$PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
)
for f in "${sample_files[@]}"; do
  [ -f "$f" ] || continue
  # Anything like ``trail/dod`` or ``trail/incidents`` is fine — we just
  # need to confirm the trail prefix appears un-prefixed (no ``$VAR/trail``
  # substitution that could redirect away from repo root).
  raw=$(grep -nE '\$[A-Za-z_]+/trail/' "$f" 2>/dev/null || true)
  if [ -n "$raw" ]; then
    suspect=$(printf '%s\n' "$raw" | grep -vE 'PROJECT_DIR/trail|REPO_ROOT/trail|HOME/trail' || true)
    if [ -n "$suspect" ]; then
      echo "FAIL: $f contains \$VAR/trail/ that may redirect trail away from repo root:" >&2
      printf '%s\n' "$suspect" >&2
      exit 1
    fi
  fi
done
ok "C: sample hooks reference trail/ at repo root only ($PROJECT_DIR/trail or relative)"

echo "test-trail-position-invariant: OK (3/3 assertions)"
