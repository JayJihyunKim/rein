#!/usr/bin/env bash
# Verify non-git fallback in rein-bootstrap-project.py (v1.1.1 / Task 2.3).
#
# Contracts under test:
#   - When git_root_for(project_dir) returns None, the script falls back to
#     using project_dir as the bootstrap root. trail/ and .rein/ are created
#     in place, no git command mutates the directory, exit 0, stdout 1-line
#     diagnostic includes "Non-git project".
#   - Existing git-root behaviour is unchanged (regression).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }

A_DIR=$(mktemp -d "/tmp/bootstrap-A-XXXXXX")
B_DIR=$(mktemp -d "/tmp/bootstrap-B-XXXXXX")
C_DIR=$(mktemp -d "/tmp/bootstrap-C-XXXXXX")
F_DIR=$(mktemp -d "/tmp/bootstrap-F-XXXXXX")
GIT_TRACE_DIR=$(mktemp -d "/tmp/git-trace-bootstrap-XXXXXX")
trap 'rm -rf "$A_DIR" "$B_DIR" "$C_DIR" "$F_DIR" "$GIT_TRACE_DIR" 2>/dev/null || true' EXIT

# --- Fixture A: non-git tmpdir -----------------------------------------------
A_OUT=$(mktemp)
A_ERR=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$A_DIR" >"$A_OUT" 2>"$A_ERR"
A_RC=$?
set -e

if [ "$A_RC" != "0" ]; then
  echo "FAIL (A): expected exit 0 on non-git, got $A_RC" >&2
  echo "--- stdout ---" >&2; cat "$A_OUT" >&2
  echo "--- stderr ---" >&2; cat "$A_ERR" >&2
  exit 1
fi
[ -d "$A_DIR/trail" ] || { echo "FAIL (A): trail/ not created" >&2; exit 1; }
[ -d "$A_DIR/.rein" ] || { echo "FAIL (A): .rein/ not created" >&2; exit 1; }
grep -q "Non-git project" "$A_OUT" || {
  echo "FAIL (A): stdout missing 'Non-git project' marker" >&2
  cat "$A_OUT" >&2
  exit 1
}
for sub in inbox daily weekly decisions dod incidents agent-candidates; do
  [ -d "$A_DIR/trail/$sub" ] || {
    echo "FAIL (A): trail/$sub not created" >&2; exit 1;
  }
done
rm -f "$A_OUT" "$A_ERR"

# --- Fixture B: no mutating git command invoked on non-git path ---------------
GIT_TRACE_LOG="$GIT_TRACE_DIR/git-calls.log"
REAL_GIT="$(command -v git 2>/dev/null || true)"
[ -n "$REAL_GIT" ] || { echo "FAIL (B): real git not found in PATH" >&2; exit 1; }

cat > "$GIT_TRACE_DIR/git" <<WRAP
#!/usr/bin/env bash
echo "\$@" >> "$GIT_TRACE_LOG"
exec "$REAL_GIT" "\$@"
WRAP
chmod +x "$GIT_TRACE_DIR/git"

set +e
PATH="$GIT_TRACE_DIR:$PATH" python3 "$SCRIPT" --project-dir "$B_DIR" >/dev/null 2>&1
B_RC=$?
set -e

if [ "$B_RC" != "0" ]; then
  echo "FAIL (B): expected exit 0 on non-git, got $B_RC" >&2
  [ -f "$GIT_TRACE_LOG" ] && { echo "--- git trace ---" >&2; cat "$GIT_TRACE_LOG" >&2; }
  exit 1
fi

if [ -f "$GIT_TRACE_LOG" ]; then
  if grep -qE '(^|[[:space:]])(init|add|commit|push|checkout|reset|merge|rebase|clean|branch|tag|stash)([[:space:]]|$)' "$GIT_TRACE_LOG"; then
    echo "FAIL (B): mutating git command detected in non-git fallback:" >&2
    cat "$GIT_TRACE_LOG" >&2
    exit 1
  fi
fi

# --- Fixture C: git repo regression (unchanged behaviour) ---------------------
( cd "$C_DIR" && git init -q )
C_OUT=$(mktemp)
C_ERR=$(mktemp)
set +e
python3 "$SCRIPT" --project-dir "$C_DIR" >"$C_OUT" 2>"$C_ERR"
C_RC=$?
set -e

if [ "$C_RC" != "0" ]; then
  echo "FAIL (C): git repo regression, expected 0 got $C_RC" >&2
  echo "--- stdout ---" >&2; cat "$C_OUT" >&2
  echo "--- stderr ---" >&2; cat "$C_ERR" >&2
  exit 1
fi
if grep -q "Non-git" "$C_OUT"; then
  echo "FAIL (C): git repo case incorrectly emitted 'Non-git' marker" >&2
  cat "$C_OUT" >&2
  exit 1
fi
[ -d "$C_DIR/trail" ] || { echo "FAIL (C): trail/ not created in git case" >&2; exit 1; }
[ -d "$C_DIR/.rein" ] || { echo "FAIL (C): .rein/ not created in git case" >&2; exit 1; }
rm -f "$C_OUT" "$C_ERR"

# --- Fixture D: sensitive path / (filesystem root) refused --------------------
set +e
python3 "$SCRIPT" --project-dir / >/dev/null 2>&1
D_RC=$?
set -e
[ "$D_RC" != "0" ] || {
  echo "FAIL (D): expected refusal for /, got exit 0" >&2
  exit 1
}

# --- Fixture E: sensitive path $HOME refused ----------------------------------
set +e
python3 "$SCRIPT" --project-dir "$HOME" >/dev/null 2>&1
E_RC=$?
set -e
[ "$E_RC" != "0" ] || {
  echo "FAIL (E): expected refusal for \$HOME, got exit 0" >&2
  exit 1
}

# --- Fixture F: plugin cache path refused -------------------------------------
mkdir -p "$F_DIR/home/.claude/plugins/cache/fake-plugin"
set +e
HOME="$F_DIR/home" python3 "$SCRIPT" --project-dir "$F_DIR/home/.claude/plugins/cache/fake-plugin" >/dev/null 2>&1
F_RC=$?
set -e
[ "$F_RC" != "0" ] || {
  echo "FAIL (F): expected refusal for plugin cache, got exit 0" >&2
  exit 1
}

echo "test-rein-bootstrap-project-non-git: OK (A non-git + B no-git-mutate + C regression + D root-refused + E home-refused + F plugin-cache-refused)"
