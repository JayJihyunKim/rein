#!/usr/bin/env bash
# Verify the git-required contract in rein-bootstrap-project.py
# (git-required-onboarding DoD, superseding the v1.1.1 non-git-by-default
# fallback — Task 2.3's silent non-git support was exactly the source of the
# SessionStart-vs-bootstrap-script contradiction the field report surfaced).
#
# Contracts under test:
#   A — DEFAULT (no --allow-non-git) on a non-git project_dir: refused with
#       a distinct non-zero exit code, stderr names `git init` AND
#       `--allow-non-git`, creates nothing (no trail/, no .rein/).
#   B — `--allow-non-git` on a non-git project_dir: previous v1.1.1 fallback
#       behaviour unchanged (trail/ + .rein/ created in place, exit 0,
#       stdout "Non-git project" marker).
#   C — no mutating git command is invoked in the --allow-non-git path.
#   D — git-root project_dir: unchanged regardless of the new flag (regression).
#   E/F/G — sensitive-path / $HOME / plugin-cache refusals: unchanged
#       (these fire before the git-required check, so they stay exit-2
#       "refusing to bootstrap", never the new git-required exit code).
#   H — degraded marker removed after a successful run, both for the git
#       path and the --allow-non-git path (governance resumes the same
#       session without a restart).
#   I — GIT_DIR pointing at an unrelated repo's .git must not bypass the
#       non-git refusal for a plain non-git --project-dir (git subprocess
#       env stripped, mirroring bootstrap-check.sh's own sanitization).
#   J — a stale degraded marker under an unwritable .claude/cache cannot be
#       removed: bootstrap must report this distinctly (a new exit code)
#       rather than the marker silently surviving under a reported success.
#   K — unit check: a marker that vanishes between exists() and unlink()
#       (FileNotFoundError, a process race) counts as success, not failure.
#   L — a git root whose directory name ends with a literal LF byte
#       bootstraps successfully (git_root_for must strip only git's own
#       terminator newline, not a trailing newline that is part of the name).
#   M — a git root whose directory name ends with a single trailing space
#       bootstraps successfully (same contract, non-newline whitespace).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }

# Documented in rein-bootstrap-project.py's module docstring as
# NON_GIT_REFUSED_EXIT — distinct from fail()'s generic safety-refusal exit
# code (2) and from lib/bootstrap-check.sh's bash-side codes (0/10/11), so
# callers/tests can tell "not a git repository" apart from every other
# refusal class.
# Documented in rein-bootstrap-project.py's module docstring as
# DEGRADED_MARKER_STUCK_EXIT — bootstrap itself succeeded (trail/, .rein/
# written) but the stale SessionStart degraded marker could not be removed.
EXPECTED_NON_GIT_EXIT=3
EXPECTED_DEGRADED_MARKER_STUCK_EXIT=4

A_DIR=$(mktemp -d "/tmp/bootstrap-A-XXXXXX")
B_DIR=$(mktemp -d "/tmp/bootstrap-B-XXXXXX")
C_DIR=$(mktemp -d "/tmp/bootstrap-C-XXXXXX")
D_DIR=$(mktemp -d "/tmp/bootstrap-D-XXXXXX")
F_DIR=$(mktemp -d "/tmp/bootstrap-F-XXXXXX")
H1_DIR=$(mktemp -d "/tmp/bootstrap-H1-XXXXXX")
H2_DIR=$(mktemp -d "/tmp/bootstrap-H2-XXXXXX")
I_DIR=$(mktemp -d "/tmp/bootstrap-I-XXXXXX")
I_DECOY_DIR=$(mktemp -d "/tmp/bootstrap-Idecoy-XXXXXX")
GIT_TRACE_DIR=$(mktemp -d "/tmp/git-trace-bootstrap-XXXXXX")
J_DIR=$(mktemp -d "/tmp/bootstrap-J-XXXXXX")
L_PARENT=$(mktemp -d "/tmp/bootstrap-L-XXXXXX")
M_PARENT=$(mktemp -d "/tmp/bootstrap-M-XXXXXX")
trap 'chmod -R u+w "$J_DIR" 2>/dev/null || true; rm -rf "$A_DIR" "$B_DIR" "$C_DIR" "$D_DIR" "$F_DIR" "$H1_DIR" "$H2_DIR" "$I_DIR" "$I_DECOY_DIR" "$GIT_TRACE_DIR" "$J_DIR" "$L_PARENT" "$M_PARENT" 2>/dev/null || true' EXIT

# --- Fixture A: DEFAULT refusal on non-git project_dir ------------------------
A_OUT=$(mktemp)
A_ERR=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$A_DIR" >"$A_OUT" 2>"$A_ERR"
A_RC=$?
set -e

if [ "$A_RC" != "$EXPECTED_NON_GIT_EXIT" ]; then
  echo "FAIL (A): expected exit $EXPECTED_NON_GIT_EXIT (git-required refusal), got $A_RC" >&2
  echo "--- stdout ---" >&2; cat "$A_OUT" >&2
  echo "--- stderr ---" >&2; cat "$A_ERR" >&2
  exit 1
fi
grep -q "git init" "$A_ERR" || {
  echo "FAIL (A): stderr missing 'git init' recovery instruction" >&2
  cat "$A_ERR" >&2
  exit 1
}
grep -q -- "--allow-non-git" "$A_ERR" || {
  echo "FAIL (A): stderr missing '--allow-non-git' escape hatch" >&2
  cat "$A_ERR" >&2
  exit 1
}
[ ! -e "$A_DIR/trail" ] || { echo "FAIL (A): trail/ created despite refusal" >&2; exit 1; }
[ ! -e "$A_DIR/.rein" ] || { echo "FAIL (A): .rein/ created despite refusal" >&2; exit 1; }
rm -f "$A_OUT" "$A_ERR"
echo "PASS (A): default refusal on non-git dir (exit $EXPECTED_NON_GIT_EXIT, git-init + --allow-non-git in stderr, nothing created)"

# --- Fixture B: --allow-non-git restores the v1.1.1 fallback ------------------
B_OUT=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$B_DIR" --allow-non-git >"$B_OUT" 2>&1
B_RC=$?
set -e

if [ "$B_RC" != "0" ]; then
  echo "FAIL (B): expected exit 0 with --allow-non-git, got $B_RC" >&2
  cat "$B_OUT" >&2
  exit 1
fi
[ -d "$B_DIR/trail" ] || { echo "FAIL (B): trail/ not created" >&2; exit 1; }
[ -d "$B_DIR/.rein" ] || { echo "FAIL (B): .rein/ not created" >&2; exit 1; }
grep -q "Non-git project" "$B_OUT" || {
  echo "FAIL (B): stdout missing 'Non-git project' marker" >&2
  cat "$B_OUT" >&2
  exit 1
}
for sub in inbox daily weekly decisions dod incidents agent-candidates; do
  [ -d "$B_DIR/trail/$sub" ] || {
    echo "FAIL (B): trail/$sub not created" >&2; exit 1;
  }
done
rm -f "$B_OUT"
echo "PASS (B): --allow-non-git restores previous non-git fallback"

# --- Fixture C: no mutating git command invoked in the --allow-non-git path ---
GIT_TRACE_LOG="$GIT_TRACE_DIR/git-calls.log"
REAL_GIT="$(command -v git 2>/dev/null || true)"
[ -n "$REAL_GIT" ] || { echo "FAIL (C): real git not found in PATH" >&2; exit 1; }

cat > "$GIT_TRACE_DIR/git" <<WRAP
#!/usr/bin/env bash
echo "\$@" >> "$GIT_TRACE_LOG"
exec "$REAL_GIT" "\$@"
WRAP
chmod +x "$GIT_TRACE_DIR/git"

C_TRACE_TARGET=$(mktemp -d "/tmp/bootstrap-Ctrace-XXXXXX")
set +e
PATH="$GIT_TRACE_DIR:$PATH" python3 "$SCRIPT" --project-dir "$C_TRACE_TARGET" --allow-non-git >/dev/null 2>&1
C_TRACE_RC=$?
set -e

if [ "$C_TRACE_RC" != "0" ]; then
  echo "FAIL (C): expected exit 0 on --allow-non-git, got $C_TRACE_RC" >&2
  [ -f "$GIT_TRACE_LOG" ] && { echo "--- git trace ---" >&2; cat "$GIT_TRACE_LOG" >&2; }
  exit 1
fi
if [ -f "$GIT_TRACE_LOG" ]; then
  if grep -qE '(^|[[:space:]])(init|add|commit|push|checkout|reset|merge|rebase|clean|branch|tag|stash)([[:space:]]|$)' "$GIT_TRACE_LOG"; then
    echo "FAIL (C): mutating git command detected in --allow-non-git fallback:" >&2
    cat "$GIT_TRACE_LOG" >&2
    exit 1
  fi
fi
rm -rf "$C_TRACE_TARGET"
echo "PASS (C): no mutating git command in --allow-non-git fallback"

# --- Fixture D: git repo regression (unchanged, no flag needed) ---------------
( cd "$D_DIR" && git init -q )
D_OUT=$(mktemp)
D_ERR=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$D_DIR" >"$D_OUT" 2>"$D_ERR"
D_RC=$?
set -e

if [ "$D_RC" != "0" ]; then
  echo "FAIL (D): git repo regression, expected 0 got $D_RC" >&2
  echo "--- stdout ---" >&2; cat "$D_OUT" >&2
  echo "--- stderr ---" >&2; cat "$D_ERR" >&2
  exit 1
fi
if grep -q "Non-git" "$D_OUT"; then
  echo "FAIL (D): git repo case incorrectly emitted 'Non-git' marker" >&2
  cat "$D_OUT" >&2
  exit 1
fi
[ -d "$D_DIR/trail" ] || { echo "FAIL (D): trail/ not created in git case" >&2; exit 1; }
[ -d "$D_DIR/.rein" ] || { echo "FAIL (D): .rein/ not created in git case" >&2; exit 1; }
rm -f "$D_OUT" "$D_ERR"
echo "PASS (D): git-root project_dir unaffected by the new flag"

# --- Fixture E: sensitive path / (filesystem root) refused --------------------
set +e
python3 "$SCRIPT" --project-dir / >/dev/null 2>&1
E_RC=$?
set -e
[ "$E_RC" != "0" ] || {
  echo "FAIL (E): expected refusal for /, got exit 0" >&2
  exit 1
}
echo "PASS (E): / refused (rc=$E_RC)"

# --- Fixture F: sensitive path $HOME refused ----------------------------------
set +e
python3 "$SCRIPT" --project-dir "$HOME" >/dev/null 2>&1
F_RC=$?
set -e
[ "$F_RC" != "0" ] || {
  echo "FAIL (F): expected refusal for \$HOME, got exit 0" >&2
  exit 1
}
echo "PASS (F): \$HOME refused (rc=$F_RC)"

# --- Fixture G: plugin cache path refused -------------------------------------
mkdir -p "$F_DIR/home/.claude/plugins/cache/fake-plugin"
set +e
HOME="$F_DIR/home" python3 "$SCRIPT" --project-dir "$F_DIR/home/.claude/plugins/cache/fake-plugin" >/dev/null 2>&1
G_RC=$?
set -e
[ "$G_RC" != "0" ] || {
  echo "FAIL (G): expected refusal for plugin cache, got exit 0" >&2
  exit 1
}
echo "PASS (G): plugin cache path refused (rc=$G_RC)"

# --- Fixture H: degraded marker removed after a successful run ---------------
# H1: git-repo path.
( cd "$H1_DIR" && git init -q )
mkdir -p "$H1_DIR/.claude/cache"
printf 'non-git-dir\n' > "$H1_DIR/.claude/cache/.rein-session-degraded"
H1_OUT=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$H1_DIR" >"$H1_OUT" 2>&1
H1_RC=$?
set -e
[ "$H1_RC" = "0" ] || { echo "FAIL (H1): expected exit 0, got $H1_RC" >&2; cat "$H1_OUT" >&2; exit 1; }
[ ! -f "$H1_DIR/.claude/cache/.rein-session-degraded" ] || {
  echo "FAIL (H1): degraded marker survived a successful git-path bootstrap" >&2
  exit 1
}
rm -f "$H1_OUT"
echo "PASS (H1): successful git-path bootstrap clears the degraded marker"

# H2: --allow-non-git path.
mkdir -p "$H2_DIR/.claude/cache"
printf 'git-missing\n' > "$H2_DIR/.claude/cache/.rein-session-degraded"
H2_OUT=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$H2_DIR" --allow-non-git >"$H2_OUT" 2>&1
H2_RC=$?
set -e
[ "$H2_RC" = "0" ] || { echo "FAIL (H2): expected exit 0, got $H2_RC" >&2; cat "$H2_OUT" >&2; exit 1; }
[ ! -f "$H2_DIR/.claude/cache/.rein-session-degraded" ] || {
  echo "FAIL (H2): degraded marker survived a successful --allow-non-git bootstrap" >&2
  exit 1
}
rm -f "$H2_OUT"
echo "PASS (H2): successful --allow-non-git bootstrap clears the degraded marker"

# --- Fixture I: GIT_DIR poisoning must not fool the non-git refusal -----
# GIT_DIR points at an unrelated repo's .git; --project-dir is a plain non-git
# directory. Without env-stripping, git_root_for's `git -C $I_DIR rev-parse`
# would honor the poisoned GIT_DIR and report the DECOY's root, making
# bootstrap() treat I_DIR as if it were (part of) that other git repository —
# either silently adopting the decoy's root or failing the "project-dir must
# be the git root" check with the wrong diagnosis. Either way it is NOT the
# git-required refusal I_DIR actually deserves. With env-stripping, git
# discovery from I_DIR finds no enclosing repo → the default non-git refusal
# fires (exit 3), and nothing is created in either directory.
( cd "$I_DECOY_DIR" && git init -q )
I_OUT=$(mktemp)
I_ERR=$(mktemp)
set +e
GIT_DIR="$I_DECOY_DIR/.git" python3 "$SCRIPT" --project-dir "$I_DIR" >"$I_OUT" 2>"$I_ERR"
I_RC=$?
set -e
if [ "$I_RC" != "$EXPECTED_NON_GIT_EXIT" ]; then
  echo "FAIL (I): expected exit $EXPECTED_NON_GIT_EXIT (GIT_DIR poisoning must not bypass the non-git refusal), got $I_RC" >&2
  echo "--- stdout ---" >&2; cat "$I_OUT" >&2
  echo "--- stderr ---" >&2; cat "$I_ERR" >&2
  exit 1
fi
grep -q "git init" "$I_ERR" || {
  echo "FAIL (I): stderr missing 'git init' recovery instruction" >&2
  cat "$I_ERR" >&2
  exit 1
}
[ ! -e "$I_DIR/trail" ] || { echo "FAIL (I): trail/ created in \$I_DIR despite GIT_DIR poisoning" >&2; exit 1; }
[ ! -e "$I_DIR/.rein" ] || { echo "FAIL (I): .rein/ created in \$I_DIR despite GIT_DIR poisoning" >&2; exit 1; }
[ ! -e "$I_DECOY_DIR/trail" ] || { echo "FAIL (I): trail/ created in the DECOY repo (GIT_DIR target)" >&2; exit 1; }
rm -f "$I_OUT" "$I_ERR"
echo "PASS (I): GIT_DIR pointing at another repo's .git does not bypass the non-git refusal (exit $EXPECTED_NON_GIT_EXIT, nothing created in either dir)"

# --- Fixture J: stale degraded marker under an unwritable cache dir -----------
# `.claude/cache` is chmod 555 (read + execute, no write) so unlink() on the
# marker file inside it fails with EACCES/EPERM regardless of the marker
# file's own mode — POSIX requires write permission on the PARENT directory
# to remove a directory entry. Root can unlink regardless of permission bits,
# so this fixture is meaningless (and would false-FAIL) when run as root.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP (J): running as root — chmod 555 does not block root's unlink"
else
  ( cd "$J_DIR" && git init -q )
  mkdir -p "$J_DIR/.claude/cache"
  MARKER_J="$J_DIR/.claude/cache/.rein-session-degraded"
  printf 'non-git-dir\n' > "$MARKER_J"
  chmod 555 "$J_DIR/.claude/cache"
  J_OUT=$(mktemp)
  J_ERR=$(mktemp)
  set +e
  python3 "$SCRIPT" --project-dir "$J_DIR" >"$J_OUT" 2>"$J_ERR"
  J_RC=$?
  set -e
  chmod u+w "$J_DIR/.claude/cache"
  if [ "$J_RC" != "$EXPECTED_DEGRADED_MARKER_STUCK_EXIT" ]; then
    echo "FAIL (J): expected exit $EXPECTED_DEGRADED_MARKER_STUCK_EXIT (stuck degraded marker), got $J_RC" >&2
    echo "--- stdout ---" >&2; cat "$J_OUT" >&2
    echo "--- stderr ---" >&2; cat "$J_ERR" >&2
    exit 1
  fi
  grep -qF "$MARKER_J" "$J_ERR" || {
    echo "FAIL (J): stderr does not name the stuck marker path (got:" >&2
    cat "$J_ERR" >&2
    exit 1
  }
  [ -f "$MARKER_J" ] || {
    echo "FAIL (J): stuck marker was unexpectedly removed despite the unwritable cache dir" >&2
    exit 1
  }
  rm -f "$J_OUT" "$J_ERR"
  echo "PASS (J): stuck degraded marker under unwritable .claude/cache → exit $EXPECTED_DEGRADED_MARKER_STUCK_EXIT, marker survives, path named in stderr"
fi

# --- Fixture K: unit check — a marker that vanishes between exists() and ---
# --- unlink() (a process race — another session's cleanup, a concurrent  ---
# --- SessionStart) must count as success, not the stuck-marker failure  ---
# --- path. exists()=True, unlink() raises FileNotFoundError.            ---
K_OUT=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('rbp', '$SCRIPT')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
import pathlib
pathlib.Path.exists = lambda self: True
pathlib.Path.unlink = lambda self, *a, **k: (_ for _ in ()).throw(FileNotFoundError())
print(mod._clear_degraded_marker(pathlib.Path('/tmp/does-not-matter-K')))
")
if [ "$K_OUT" != "True" ]; then
  echo "FAIL (K): _clear_degraded_marker must return True when unlink() races to FileNotFoundError (exists()=True), got: $K_OUT" >&2
  exit 1
fi
echo "PASS (K): marker vanishing between exists() and unlink() (FileNotFoundError) counts as success"

# --- Fixture L: git root directory name ending in a literal LF byte ----------
L_NAME=$'repo\n'
L_DIR="$L_PARENT/$L_NAME"
mkdir "$L_DIR"
( cd "$L_DIR" && git init -q )
L_OUT=$(mktemp)
L_ERR=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$L_DIR" >"$L_OUT" 2>"$L_ERR"
L_RC=$?
set -e
if [ "$L_RC" != "0" ]; then
  echo "FAIL (L): git root ending in a literal LF byte must bootstrap successfully, got exit $L_RC" >&2
  echo "--- stdout ---" >&2; cat "$L_OUT" >&2
  echo "--- stderr ---" >&2; cat "$L_ERR" >&2
  exit 1
fi
[ -f "$L_DIR/trail/index.md" ] || {
  echo "FAIL (L): trail/index.md not created inside the LF-suffixed git root" >&2
  exit 1
}
[ -f "$L_DIR/.rein/project.json" ] || {
  echo "FAIL (L): .rein/project.json not created inside the LF-suffixed git root" >&2
  exit 1
}
rm -f "$L_OUT" "$L_ERR"
echo "PASS (L): git root directory name ending in a literal LF byte bootstraps successfully"

# --- Fixture M: git root directory name ending in a single trailing space ----
M_NAME=$'repo '
M_DIR="$M_PARENT/$M_NAME"
mkdir "$M_DIR"
( cd "$M_DIR" && git init -q )
M_OUT=$(mktemp)
M_ERR=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$M_DIR" >"$M_OUT" 2>"$M_ERR"
M_RC=$?
set -e
if [ "$M_RC" != "0" ]; then
  echo "FAIL (M): git root ending in a single trailing space must bootstrap successfully, got exit $M_RC" >&2
  echo "--- stdout ---" >&2; cat "$M_OUT" >&2
  echo "--- stderr ---" >&2; cat "$M_ERR" >&2
  exit 1
fi
[ -f "$M_DIR/trail/index.md" ] || {
  echo "FAIL (M): trail/index.md not created inside the space-suffixed git root" >&2
  exit 1
}
[ -f "$M_DIR/.rein/project.json" ] || {
  echo "FAIL (M): .rein/project.json not created inside the space-suffixed git root" >&2
  exit 1
}
rm -f "$M_OUT" "$M_ERR"
echo "PASS (M): git root directory name ending in a single trailing space bootstraps successfully"

echo "test-rein-bootstrap-project-non-git: OK (A default-refused + B allow-flag + C no-git-mutate + D git-regression + E/F/G sensitive-refused + H1/H2 degraded-cleared + I git-env-poisoning-refused + J degraded-marker-stuck + K unlink-race-success + L lf-suffixed-root + M space-suffixed-root)"
