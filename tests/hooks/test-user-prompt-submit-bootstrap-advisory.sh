#!/usr/bin/env bash
# Verify user-prompt-submit-rules.sh integrates lib/bootstrap-check.sh (Wave 3,
# Task 2.1):
#   (A) trail/ missing on safe project_dir → bootstrap guidance is prepended to
#       the answer-only-mode body inside a single additionalContext envelope.
#   (B) bootstrap complete (trail/ + .rein/project.json + trail/index.md) → no
#       bootstrap guidance, only the existing body.
#   (C) helper exit 11 (sensitive-path — $HOME as cwd) → no bootstrap guidance,
#       silent passthrough, only the existing body.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/user-prompt-submit-rules.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

A_DIR=$(mktemp -d "/tmp/upsub-A-XXXXXX")
B_DIR=$(mktemp -d "/tmp/upsub-B-XXXXXX")
A_OUT=$(mktemp)
B_OUT=$(mktemp)
C_OUT=$(mktemp)
trap 'rm -rf "$A_DIR" "$B_DIR" 2>/dev/null || true; rm -f "$A_OUT" "$B_OUT" "$C_OUT" 2>/dev/null || true' EXIT

# ---------- (A) trail/ missing → bootstrap advisory prepended ----------------
( cd "$A_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$A_OUT" 2>/dev/null )
python3 - "$A_OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL(A): stdout empty", file=sys.stderr); sys.exit(1)
data = json.loads(raw)
hso = data.get("hookSpecificOutput", {})
if hso.get("hookEventName") != "UserPromptSubmit":
    print(f"FAIL(A): hookEventName {hso.get('hookEventName')!r}", file=sys.stderr); sys.exit(1)
ctx = hso.get("additionalContext", "")
if "rein-bootstrap-project.py" not in ctx:
    print(f"FAIL(A): missing bootstrap command in additionalContext (len={len(ctx)})", file=sys.stderr); sys.exit(1)
if "Answer-only quick rule" not in ctx:
    print("FAIL(A): missing answer-only-mode body marker 'Answer-only quick rule'", file=sys.stderr); sys.exit(1)
# Ordering check: guidance precedes the rule body.
if ctx.index("rein-bootstrap-project.py") >= ctx.index("Answer-only quick rule"):
    print("FAIL(A): bootstrap guidance must precede the rule body", file=sys.stderr); sys.exit(1)
PY

# ---------- (B) bootstrap complete → no bootstrap advisory -------------------
# Partial-bootstrap fix (v1.3.0+1): bootstrap_check requires all three markers
# (trail/ dir, .rein/project.json, trail/index.md). Seed all three so the
# helper takes the rc=0 (bootstrapped) path and no advisory is prepended.
mkdir "$B_DIR/trail" "$B_DIR/.rein"
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' > "$B_DIR/.rein/project.json"
printf '# trail/index.md\n' > "$B_DIR/trail/index.md"
( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$B_OUT" 2>/dev/null )
python3 - "$B_OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL(B): stdout empty", file=sys.stderr); sys.exit(1)
data = json.loads(raw)
ctx = data["hookSpecificOutput"]["additionalContext"]
if "rein-bootstrap-project.py" in ctx:
    print("FAIL(B): bootstrap complete yet bootstrap advisory still prepended", file=sys.stderr); sys.exit(1)
if "Answer-only quick rule" not in ctx:
    print("FAIL(B): missing answer-only-mode body marker 'Answer-only quick rule'", file=sys.stderr); sys.exit(1)
PY

# ---------- (C) helper exit 11 (sensitive-path) → no bootstrap advisory ------
# Running with cwd=$HOME triggers the sensitive-path branch in
# bootstrap-check.sh, which returns exit 11 with empty stdout. The hook must
# silently pass through and emit only the existing body.
( cd "$HOME" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$C_OUT" 2>/dev/null )
python3 - "$C_OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL(C): stdout empty", file=sys.stderr); sys.exit(1)
data = json.loads(raw)
ctx = data["hookSpecificOutput"]["additionalContext"]
if "rein-bootstrap-project.py" in ctx:
    print("FAIL(C): helper exit 11 should suppress advisory, but command is present", file=sys.stderr); sys.exit(1)
if "Answer-only quick rule" not in ctx:
    print("FAIL(C): missing answer-only-mode body marker 'Answer-only quick rule'", file=sys.stderr); sys.exit(1)
PY

echo "test-user-prompt-submit-bootstrap-advisory: OK (A advisory + B silent + C helper-unsafe silent)"
