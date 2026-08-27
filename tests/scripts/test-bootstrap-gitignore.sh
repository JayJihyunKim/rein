#!/usr/bin/env bash
# Verify bootstrap registers rein runtime state dirs in the project .gitignore
# (v2 release-gate self-invalidation fix, 2026-08-27).
#
# Without these patterns, `.rein/state/` (the evidence ledger) is untracked and
# gets swept into worktree_changeset (git status --untracked-files=all), so the
# first evidence issuance changes its own review subject and self-invalidates —
# the gate fails closed and locks the user out. Contracts:
#   (A) fresh project (no .gitignore) → all 3 runtime patterns registered
#   (B) existing .gitignore → content preserved + rein patterns appended
#   (B-idem) re-run → no duplicates
#   (seal) after patterns exist, .rein/state is excluded from git status
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"
[ -f "$BOOTSTRAP" ] || { echo "FAIL: $BOOTSTRAP missing" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

A=$(mktemp -d "/tmp/bootstrap-gitignore-A-XXXXXX")
B=$(mktemp -d "/tmp/bootstrap-gitignore-B-XXXXXX")
trap 'rm -rf "$A" "$B" 2>/dev/null || true' EXIT

# --- (A) fresh project, no .gitignore → 3 runtime patterns registered --------
( cd "$A" && git init -q )
python3 "$BOOTSTRAP" --project-dir "$A" >/dev/null 2>&1 || bad "(A) bootstrap exited non-zero"
for p in '/.rein/state/' '/.rein/cache/' '/.rein/logs/'; do
  if grep -qF "$p" "$A/.gitignore" 2>/dev/null; then ok "(A) $p registered"; else bad "(A) $p missing"; fi
done

# --- (B) existing .gitignore preserved + rein patterns appended --------------
( cd "$B" && git init -q )
printf 'node_modules/\n*.log\n' > "$B/.gitignore"
python3 "$BOOTSTRAP" --project-dir "$B" >/dev/null 2>&1 || bad "(B) bootstrap exited non-zero"
if grep -qxF 'node_modules/' "$B/.gitignore"; then ok "(B) existing content preserved"; else bad "(B) existing content lost"; fi
if grep -qF '/.rein/state/' "$B/.gitignore"; then ok "(B) rein pattern appended"; else bad "(B) rein pattern missing"; fi

# --- (B-idem) re-run twice → still exactly one occurrence --------------------
python3 "$BOOTSTRAP" --project-dir "$B" >/dev/null 2>&1
python3 "$BOOTSTRAP" --project-dir "$B" >/dev/null 2>&1
CNT=$(grep -cF '/.rein/state/' "$B/.gitignore")
if [ "$CNT" = "1" ]; then ok "(B-idem) idempotent — 1 occurrence after 3 runs"; else bad "(B-idem) duplicated: $CNT occurrences"; fi

# --- (seal) .rein/state excluded from git status (self-invalidation gone) ----
mkdir -p "$A/.rein/state" && echo '{"evidence":1}' > "$A/.rein/state/evidence.jsonl"
if ( cd "$A" && git status --porcelain --untracked-files=all | grep -q '\.rein/state' ); then
  bad "(seal) .rein/state still swept into git status — self-invalidation reopens"
else
  ok "(seal) .rein/state excluded from git status — digest contamination gone"
fi

# --- (C) leading-space false-positive: git treats " /.rein/state/" as a
#     DIFFERENT pattern that does NOT ignore .rein/state/; bootstrap must still
#     append the canonical line so the seal holds (codex round 1 High) --------
C=$(mktemp -d "/tmp/bootstrap-gitignore-C-XXXXXX")
( cd "$C" && git init -q )
printf ' /.rein/state/\n' > "$C/.gitignore"   # leading space — does NOT ignore
python3 "$BOOTSTRAP" --project-dir "$C" >/dev/null 2>&1
mkdir -p "$C/.rein/state" && echo '{"e":1}' > "$C/.rein/state/evidence.jsonl"
if ( cd "$C" && git status --porcelain --untracked-files=all | grep -q '\.rein/state' ); then
  bad "(C) leading-space .gitignore still leaks .rein/state — seal reopens"
else
  ok "(C) canonical pattern appended despite leading-space false-positive"
fi
rm -rf "$C"

# --- (D) symlink .gitignore: bootstrap must FAIL safely — no external write,
#     no completion sentinel, external target byte-unchanged (round 2 High) ---
D=$(mktemp -d "/tmp/bootstrap-gitignore-D-XXXXXX")
EXT=$(mktemp "/tmp/bootstrap-gitignore-EXT-XXXXXX")
( cd "$D" && git init -q )
printf 'external-original\n' > "$EXT"
EXT_ORIG=$(mktemp "/tmp/bootstrap-gitignore-EXTORIG-XXXXXX")
cp "$EXT" "$EXT_ORIG"   # byte-exact baseline for cmp
ln -s "$EXT" "$D/.gitignore"
python3 "$BOOTSTRAP" --project-dir "$D" >/dev/null 2>&1
D_RC=$?
if [ "$D_RC" != "0" ]; then ok "(D) bootstrap failed on symlink .gitignore (rc=$D_RC)"; else bad "(D) bootstrap succeeded despite symlink .gitignore"; fi
if [ ! -e "$D/.rein/project.json" ]; then ok "(D) no completion sentinel written"; else bad "(D) completion sentinel written despite unsealed state"; fi
if grep -q '/.rein/state/' "$EXT"; then bad "(D) wrote rein block through symlink into external file"; else ok "(D) symlink target not written"; fi
if cmp -s "$EXT" "$EXT_ORIG"; then ok "(D) external target byte-unchanged (cmp)"; else bad "(D) external target modified"; fi
rm -rf "$D"; rm -f "$EXT" "$EXT_ORIG"

echo ""
echo "test-bootstrap-gitignore: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
