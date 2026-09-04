#!/usr/bin/env bash
# Verify bootstrap registers rein runtime state dirs in the project .gitignore
# (v2 release-gate self-invalidation fix, 2026-08-27; extended 2026-09-04 for
# the .rein/state.json / .rein/.onboarded review-digest self-invalidation
# fix — see trail/dod/dod-2026-09-04-rein-state-gitignore-digest.md).
#
# Without these patterns, `.rein/state/` (the evidence ledger) is untracked and
# gets swept into worktree_changeset (git status --untracked-files=all), so the
# first evidence issuance changes its own review subject and self-invalidates —
# the gate fails closed and locks the user out. Contracts:
#   (A) fresh project (no .gitignore) → all 6 runtime patterns registered
#   (B) existing .gitignore → content preserved + rein patterns appended
#   (B-idem) re-run → no duplicates
#   (seal) after patterns exist, .rein/state is excluded from git status
#   (seal-file) same, for the file-shaped runtime patterns (state.json /
#     state-pending-*.log / .onboarded)
#   Item 2 (i)-(iv) — `--ensure-gitignore --project-dir <dir>` sub-mode:
#     (i)   already-bootstrapped project (.rein/project.json present) whose
#           .gitignore lacks the patterns → they get appended, nothing else
#           is created, stdout prints a one-line notice
#     (ii)  re-run → byte-identical .gitignore, silent stdout
#     (iii) non-git dir with .rein/project.json → no .gitignore written
#     (iv)  git dir without .rein/project.json → no .gitignore written
set -u

RUNTIME_PATTERNS='/.rein/state/ /.rein/cache/ /.rein/logs/ /.rein/state.json /.rein/state-pending-*.log /.rein/.onboarded'

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

# --- (A) fresh project, no .gitignore → 6 runtime patterns registered --------
( cd "$A" && git init -q )
python3 "$BOOTSTRAP" --project-dir "$A" >/dev/null 2>&1 || bad "(A) bootstrap exited non-zero"
for p in $RUNTIME_PATTERNS; do
  if grep -qF "$p" "$A/.gitignore" 2>/dev/null; then ok "(A) $p registered"; else bad "(A) $p missing"; fi
done

# --- (B) existing .gitignore preserved + rein patterns appended --------------
( cd "$B" && git init -q )
printf 'node_modules/\n*.log\n' > "$B/.gitignore"
python3 "$BOOTSTRAP" --project-dir "$B" >/dev/null 2>&1 || bad "(B) bootstrap exited non-zero"
if grep -qxF 'node_modules/' "$B/.gitignore"; then ok "(B) existing content preserved"; else bad "(B) existing content lost"; fi
for p in $RUNTIME_PATTERNS; do
  if grep -qF "$p" "$B/.gitignore"; then ok "(B) $p appended"; else bad "(B) $p missing"; fi
done

# --- (B-idem) re-run twice → still exactly one occurrence per pattern --------
python3 "$BOOTSTRAP" --project-dir "$B" >/dev/null 2>&1
python3 "$BOOTSTRAP" --project-dir "$B" >/dev/null 2>&1
for p in $RUNTIME_PATTERNS; do
  CNT=$(grep -cF "$p" "$B/.gitignore")
  if [ "$CNT" = "1" ]; then ok "(B-idem) $p — 1 occurrence after 3 runs"; else bad "(B-idem) $p duplicated: $CNT occurrences"; fi
done

# --- (seal) .rein/state excluded from git status (self-invalidation gone) ----
mkdir -p "$A/.rein/state" && echo '{"evidence":1}' > "$A/.rein/state/evidence.jsonl"
if ( cd "$A" && git status --porcelain --untracked-files=all | grep -q '\.rein/state' ); then
  bad "(seal) .rein/state still swept into git status — self-invalidation reopens"
else
  ok "(seal) .rein/state excluded from git status — digest contamination gone"
fi

# --- (seal-file) the file-shaped runtime patterns (state.json / state-
#     pending-*.log / .onboarded) are excluded from git status too — this is
#     the actual defect this DoD fixes (rein rewrites .rein/state.json on
#     every hook call; if it is tracked, every tool call dirties the review
#     subject digest out from under an in-flight review).
echo '{"updated_at":1}' > "$A/.rein/state.json"
echo 'pending' > "$A/.rein/state-pending-abc.log"
printf 'onboarded=2026-01-01T00:00:00\n' > "$A/.rein/.onboarded"
SEAL_FILE_LEAK=$(cd "$A" && git status --porcelain --untracked-files=all -- .rein/state.json '.rein/state-pending-abc.log' .rein/.onboarded)
if [ -z "$SEAL_FILE_LEAK" ]; then
  ok "(seal-file) .rein/state.json, state-pending-*.log, .onboarded excluded from git status"
else
  bad "(seal-file) runtime files still swept into git status: $SEAL_FILE_LEAK"
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

# --- Item 2: `--ensure-gitignore --project-dir <dir>` heal-existing-project
#     sub-mode (session-start-bootstrap.sh's rc=0 branch calls this). -------

# (i) already-bootstrapped project (.rein/project.json present, no trail/ —
#     the sub-mode's own trigger condition is project.json alone) whose
#     .gitignore lacks the patterns → they get appended, nothing else is
#     created (no trail/, no .rein/policy, no git index mutation), and
#     stdout carries exactly one notice line because something changed.
H=$(mktemp -d "/tmp/bootstrap-gitignore-H-XXXXXX")
( cd "$H" && git init -q )
mkdir -p "$H/.rein"
printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$H/.rein/project.json"
H_OUT1="$H.out1"
H_ERR1="$H.err1"
python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$H" >"$H_OUT1" 2>"$H_ERR1"
H_RC1=$?
if [ "$H_RC1" = "0" ]; then ok "(i) --ensure-gitignore on bootstrapped project exits 0"; else bad "(i) exited $H_RC1"; fi
for p in $RUNTIME_PATTERNS; do
  if grep -qF "$p" "$H/.gitignore" 2>/dev/null; then ok "(i) $p appended"; else bad "(i) $p missing after --ensure-gitignore"; fi
done
H_OUT1_LINES=$(wc -l < "$H_OUT1" | tr -d ' ')
if [ "$H_OUT1_LINES" = "1" ]; then ok "(i) prints exactly one notice line when it appended something"; else bad "(i) expected exactly 1 stdout line, got $H_OUT1_LINES"; fi
if [ -s "$H_ERR1" ]; then bad "(i) stderr not empty: $(head -c 200 "$H_ERR1")"; else ok "(i) stderr empty"; fi
if [ -d "$H/trail" ]; then bad "(i) trail/ created — --ensure-gitignore must not create it"; else ok "(i) trail/ not created"; fi
if [ -e "$H/.rein/policy" ]; then bad "(i) .rein/policy created — --ensure-gitignore must not create it"; else ok "(i) .rein/policy not created"; fi
H_STAGED=$(cd "$H" && git diff --cached --name-only | wc -l | tr -d ' ')
if [ "$H_STAGED" = "0" ]; then ok "(i) no git index mutation (no staged changes)"; else bad "(i) git index mutated ($H_STAGED staged)"; fi

# (ii) re-run → byte-identical .gitignore, silent stdout (nothing to append).
H_HASH1=$(shasum -a 256 "$H/.gitignore" | awk '{print $1}')
H_OUT2="$H.out2"
python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$H" >"$H_OUT2" 2>/dev/null
H_HASH2=$(shasum -a 256 "$H/.gitignore" | awk '{print $1}')
if [ "$H_HASH1" = "$H_HASH2" ]; then ok "(ii) re-run leaves .gitignore byte-identical"; else bad "(ii) re-run modified .gitignore"; fi
if [ ! -s "$H_OUT2" ]; then ok "(ii) re-run is silent (nothing appended)"; else bad "(ii) re-run printed output despite no change"; fi
rm -rf "$H" "$H_OUT1" "$H_ERR1" "$H_OUT2"

# (v) project path containing a newline → the notice is still exactly one
#     stdout line (the path is not echoed), stderr empty, exit 0.
NL_BASE=$(mktemp -d "/tmp/bootstrap-gitignore-NL-XXXXXX")
NL="$NL_BASE/line1
line2"
mkdir -p "$NL/.rein"
( cd "$NL" && git init -q )
printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$NL/.rein/project.json"
NL_OUT="$NL_BASE.out"
NL_ERR="$NL_BASE.err"
python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$NL" >"$NL_OUT" 2>"$NL_ERR"
NL_RC=$?
if [ "$NL_RC" = "0" ]; then ok "(v) newline path exits 0"; else bad "(v) newline path exited $NL_RC"; fi
NL_LINES=$(wc -l < "$NL_OUT" | tr -d ' ')
if [ "$NL_LINES" = "1" ]; then ok "(v) newline path still prints exactly one stdout line"; else bad "(v) newline path printed $NL_LINES lines"; fi
if [ -s "$NL_ERR" ]; then bad "(v) newline path stderr not empty"; else ok "(v) newline path stderr empty"; fi
if grep -qF '/.rein/state.json' "$NL/.gitignore" 2>/dev/null; then ok "(v) newline path .gitignore healed"; else bad "(v) newline path .gitignore not healed"; fi
rm -rf "$NL_BASE" "$NL_OUT" "$NL_ERR"

# (vi) .gitignore is a FIFO (named pipe) with no writer → the sub-mode must
#      NOT block in open(2) (the SessionStart hook waits on it synchronously):
#      it exits within a bound, non-zero (refused, not a regular file), and
#      leaves the FIFO untouched.
FI=$(mktemp -d "/tmp/bootstrap-gitignore-FI-XXXXXX")
( cd "$FI" && git init -q )
mkdir -p "$FI/.rein"
printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$FI/.rein/project.json"
mkfifo "$FI/.gitignore"
FI_OUT="$FI.out"; FI_ERR="$FI.err"; FI_RCF="$FI.rc"
( python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$FI" >"$FI_OUT" 2>"$FI_ERR"; echo "$?" > "$FI_RCF" ) &
FI_PID=$!
FI_WAITED=0
while kill -0 "$FI_PID" 2>/dev/null && [ "$FI_WAITED" -lt 40 ]; do sleep 0.25; FI_WAITED=$((FI_WAITED+1)); done
if kill -0 "$FI_PID" 2>/dev/null; then
  kill "$FI_PID" 2>/dev/null; pkill -P "$FI_PID" 2>/dev/null
  bad "(vi) FIFO .gitignore: --ensure-gitignore still running after 10s (blocked in open)"
else
  ok "(vi) FIFO .gitignore: --ensure-gitignore completed within bound"
  FI_RC=$(cat "$FI_RCF" 2>/dev/null)
  if [ "$FI_RC" != "0" ] && [ -n "$FI_RC" ]; then ok "(vi) FIFO .gitignore refused (rc=$FI_RC)"; else bad "(vi) FIFO .gitignore was not refused (rc=$FI_RC)"; fi
  if grep -q 'not a regular file' "$FI_ERR" 2>/dev/null; then ok "(vi) refusal names the reason"; else bad "(vi) stderr lacks the not-a-regular-file reason: $(head -c 200 "$FI_ERR")"; fi
fi
if [ -p "$FI/.gitignore" ]; then ok "(vi) FIFO left untouched"; else bad "(vi) FIFO was replaced or removed"; fi
rm -rf "$FI" "$FI_OUT" "$FI_ERR" "$FI_RCF"

# (vii) two concurrent `--ensure-gitignore` calls on the same fresh repo
#       (parallel SessionStart hooks) → each pattern lands exactly once:
#       the read → compute → append sequence runs under an exclusive lock.
CC_DUPES=0
CC_ROUNDS=12
CC_I=0
while [ "$CC_I" -lt "$CC_ROUNDS" ]; do
  CC=$(mktemp -d "/tmp/bootstrap-gitignore-CC-XXXXXX")
  ( cd "$CC" && git init -q )
  mkdir -p "$CC/.rein"
  printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$CC/.rein/project.json"
  python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$CC" >/dev/null 2>&1 &
  CC_P1=$!
  python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$CC" >/dev/null 2>&1 &
  CC_P2=$!
  wait "$CC_P1" "$CC_P2"
  for p in $RUNTIME_PATTERNS; do
    CC_N=$(grep -c -x -F -- "$p" "$CC/.gitignore" 2>/dev/null || true)
    if [ "$CC_N" != "1" ]; then CC_DUPES=$((CC_DUPES+1)); fi
  done
  rm -rf "$CC"
  CC_I=$((CC_I+1))
done
if [ "$CC_DUPES" = "0" ]; then ok "(vii) concurrent --ensure-gitignore: every pattern appended exactly once across $CC_ROUNDS rounds"; else bad "(vii) concurrent --ensure-gitignore duplicated/missed patterns ($CC_DUPES pattern-rounds)"; fi

# (viii) .gitignore is a DIRECTORY → refused like any non-regular file:
#        exit 2, reason on stderr, no traceback, directory left in place.
DD=$(mktemp -d "/tmp/bootstrap-gitignore-DD-XXXXXX")
( cd "$DD" && git init -q )
mkdir -p "$DD/.rein" "$DD/.gitignore"
printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$DD/.rein/project.json"
DD_ERR="$DD.err"
python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$DD" >/dev/null 2>"$DD_ERR"
DD_RC=$?
if [ "$DD_RC" = "2" ]; then ok "(viii) directory .gitignore refused with exit 2"; else bad "(viii) directory .gitignore exited $DD_RC (expected 2)"; fi
if grep -q 'not a regular file' "$DD_ERR" 2>/dev/null; then ok "(viii) refusal names the reason"; else bad "(viii) stderr lacks the not-a-regular-file reason"; fi
if grep -q 'Traceback' "$DD_ERR" 2>/dev/null; then bad "(viii) traceback leaked to stderr"; else ok "(viii) no traceback"; fi
if [ -d "$DD/.gitignore" ]; then ok "(viii) directory left in place"; else bad "(viii) directory .gitignore was replaced"; fi
rm -rf "$DD" "$DD_ERR"

# (ix) the sub-mode's SIGALRM watchdog is cancelled on return — an in-process
#      caller must not be killed later. Call the function directly and read
#      the remaining timer (0 expected) on both the heal path and the no-op path.
IX=$(mktemp -d "/tmp/bootstrap-gitignore-IX-XXXXXX")
( cd "$IX" && git init -q )
mkdir -p "$IX/.rein"
printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$IX/.rein/project.json"
IX_OUT=$(python3 - "$BOOTSTRAP" "$IX" <<'PY' 2>&1
import importlib.util, signal, sys, io, contextlib
from pathlib import Path
spec = importlib.util.spec_from_file_location("bp", sys.argv[1])
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)
d = Path(sys.argv[2])
with contextlib.redirect_stdout(io.StringIO()):
    rc1 = bp.ensure_gitignore_only(d)   # heals → appended
left1 = signal.alarm(0)
with contextlib.redirect_stdout(io.StringIO()):
    rc2 = bp.ensure_gitignore_only(d)   # no-op path
left2 = signal.alarm(0)
print(f"rc1={rc1} left1={left1} rc2={rc2} left2={left2}")
PY
)
if [ "$IX_OUT" = "rc1=0 left1=0 rc2=0 left2=0" ]; then ok "(ix) alarm cancelled on both heal and no-op returns"; else bad "(ix) alarm state after return: $IX_OUT"; fi
rm -rf "$IX"

# (iii) non-git dir with .rein/project.json present → nothing written, exit 0.
F=$(mktemp -d "/tmp/bootstrap-gitignore-F-XXXXXX")
mkdir -p "$F/.rein"
printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$F/.rein/project.json"
F_OUT="$F.out"
python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$F" >"$F_OUT" 2>&1
F_RC=$?
if [ "$F_RC" = "0" ]; then ok "(iii) non-git dir exits 0"; else bad "(iii) non-git dir exited $F_RC"; fi
if [ -e "$F/.gitignore" ]; then bad "(iii) .gitignore created in non-git dir"; else ok "(iii) no .gitignore created in non-git dir"; fi
if [ -s "$F_OUT" ]; then bad "(iii) unexpected stdout for a no-op run"; else ok "(iii) silent no-op"; fi
rm -rf "$F" "$F_OUT"

# (iv) git dir WITHOUT .rein/project.json → nothing written, exit 0.
G=$(mktemp -d "/tmp/bootstrap-gitignore-G-XXXXXX")
( cd "$G" && git init -q )
G_OUT="$G.out"
python3 "$BOOTSTRAP" --ensure-gitignore --project-dir "$G" >"$G_OUT" 2>&1
G_RC=$?
if [ "$G_RC" = "0" ]; then ok "(iv) uninitialized git dir exits 0"; else bad "(iv) uninitialized git dir exited $G_RC"; fi
if [ -e "$G/.gitignore" ]; then bad "(iv) .gitignore created without .rein/project.json"; else ok "(iv) no .gitignore created without .rein/project.json"; fi
if [ -s "$G_OUT" ]; then bad "(iv) unexpected stdout for a no-op run"; else ok "(iv) silent no-op"; fi
rm -rf "$G" "$G_OUT"

echo ""
echo "test-bootstrap-gitignore: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
