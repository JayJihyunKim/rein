#!/usr/bin/env bash
# Verify user-prompt-submit-rules.sh integrates lib/bootstrap-check.sh (Wave 3,
# Task 2.1):
#   (A) trail/ missing on safe project_dir → bootstrap guidance is prepended to
#       the answer-only-mode body inside a single additionalContext envelope.
#   (B) bootstrap complete (trail/ + .rein/project.json + trail/index.md) → no
#       bootstrap guidance, only the existing body.
#   (C) helper exit 11 (sensitive-path — $HOME as cwd) → no bootstrap guidance,
#       silent passthrough, only the existing body.
#   (D) git-required-onboarding DoD: a non-git degraded sandbox (SessionStart
#       already wrote .claude/cache/.rein-session-degraded=non-git-dir) makes
#       this channel's advisory carry the SAME guidance the SessionStart hook
#       would print — parity is asserted by calling the shared lib function
#       directly with the same args and checking the advisory contains it
#       verbatim (bootstrap-check.sh may still append its own Claude-facing
#       trailer around it).
#   (E) two consecutive advisories in the SAME session (same
#       REIN_SESSION_ID) → first call gets the full
#       approval-question guidance, second call gets a short reminder only
#       (no repeated approval question), both still carry the git-required
#       core message and the recovery command.
#   (F) a NEW session key (different REIN_SESSION_ID) on the same directory
#       gets the full guidance again — the "already shown" state is
#       per-session, not permanent.
#   (G) after a successful bootstrap (git init + the real bootstrap script)
#       the degraded marker is gone, so no bootstrap advisory is emitted at
#       all — not even the reminder.
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
D_DIR=$(mktemp -d "/tmp/upsub-D-XXXXXX")
E_DIR=$(mktemp -d "/tmp/upsub-E-XXXXXX")
G_DIR=$(mktemp -d "/tmp/upsub-G-XXXXXX")
A_OUT=$(mktemp)
B_OUT=$(mktemp)
C_OUT=$(mktemp)
D_OUT=$(mktemp)
E1_OUT=$(mktemp)
E2_OUT=$(mktemp)
F_OUT=$(mktemp)
G_OUT=$(mktemp)
trap 'rm -rf "$A_DIR" "$B_DIR" "$D_DIR" "$E_DIR" "$G_DIR" 2>/dev/null || true; rm -f "$A_OUT" "$B_OUT" "$C_OUT" "$D_OUT" "$E1_OUT" "$E2_OUT" "$F_OUT" "$G_OUT" 2>/dev/null || true' EXIT

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


# ---------- (D) non-git degraded marker → advisory equals SessionStart guidance ----
# Seed the degraded marker as if SessionStart had already run and found this
# directory is not a git repository (bootstrap-check.sh's own degraded-reason
# override, not bootstrap_check's default fresh/partial template).
mkdir -p "$D_DIR/.claude/cache"
printf 'non-git-dir\n' > "$D_DIR/.claude/cache/.rein-session-degraded"
( cd "$D_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_SESSION_ID="fixture-d-session" bash "$HOOK" </dev/null >"$D_OUT" 2>/dev/null )

# Compute the SAME guidance the shared lib would produce for the SAME args
# bootstrap-check.sh resolves internally: resolved_real = realpath(D_DIR),
# bootstrap_script = "$PLUGIN_ROOT/scripts/rein-bootstrap-project.py".
D_DIR_REAL="$(cd "$D_DIR" && pwd -P)"
EXPECTED_GUIDANCE="$(
  # shellcheck disable=SC1090
  source "$PLUGIN_ROOT/hooks/lib/git-required-guidance.sh"
  rein_git_required_guidance non-git-dir "$D_DIR_REAL" "$PLUGIN_ROOT/scripts/rein-bootstrap-project.py"
)"
[ -n "$EXPECTED_GUIDANCE" ] || { echo "FAIL(D): setup error — lib produced no guidance" >&2; exit 1; }

python3 - "$D_OUT" "$EXPECTED_GUIDANCE" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
expected = sys.argv[2]
if not raw.strip():
    print("FAIL(D): stdout empty", file=sys.stderr); sys.exit(1)
data = json.loads(raw)
ctx = data["hookSpecificOutput"]["additionalContext"]
if expected not in ctx:
    print("FAIL(D): advisory does not contain the SessionStart-parity guidance", file=sys.stderr)
    print(f"--- expected (substring) ---\n{expected}", file=sys.stderr)
    print(f"--- got (additionalContext) ---\n{ctx}", file=sys.stderr)
    sys.exit(1)
if "Answer-only quick rule" not in ctx:
    print("FAIL(D): missing answer-only-mode body marker 'Answer-only quick rule'", file=sys.stderr); sys.exit(1)
PY


# ---------- (E) two consecutive advisories, SAME session: full then reminder ----
mkdir -p "$E_DIR/.claude/cache"
printf 'non-git-dir
' > "$E_DIR/.claude/cache/.rein-session-degraded"
( cd "$E_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_SESSION_ID="fixture-e-session" bash "$HOOK" </dev/null >"$E1_OUT" 2>/dev/null )
( cd "$E_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_SESSION_ID="fixture-e-session" bash "$HOOK" </dev/null >"$E2_OUT" 2>/dev/null )
python3 - "$E1_OUT" "$E2_OUT" <<'PY' || exit 1
import json, sys
raw1 = open(sys.argv[1], encoding="utf-8").read()
raw2 = open(sys.argv[2], encoding="utf-8").read()
if not raw1.strip() or not raw2.strip():
    print("FAIL(E): stdout empty on one of the two calls", file=sys.stderr); sys.exit(1)
ctx1 = json.loads(raw1)["hookSpecificOutput"]["additionalContext"]
ctx2 = json.loads(raw2)["hookSpecificOutput"]["additionalContext"]
if "FIRST" not in ctx1:
    print("FAIL(E): first call in a fresh session should carry the full approval-question guidance (missing 'FIRST')", file=sys.stderr); sys.exit(1)
if "git init" not in ctx1:
    print("FAIL(E): first call missing 'git init'", file=sys.stderr); sys.exit(1)
if "FIRST" in ctx2 or "approval" in ctx2:
    print("FAIL(E): second call in the SAME session repeated the approval question", file=sys.stderr); sys.exit(1)
if "git init" not in ctx2:
    print("FAIL(E): second call (reminder) lost the git-required recovery command ('git init')", file=sys.stderr); sys.exit(1)
if "저장소가 아니" not in ctx2 and "not a git repository" not in ctx2:
    print("FAIL(E): second call (reminder) lost the git-required core message", file=sys.stderr); sys.exit(1)
PY

# ---------- (F) a NEW session key on the SAME directory → full guidance again ----
( cd "$E_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_SESSION_ID="fixture-f-session" bash "$HOOK" </dev/null >"$F_OUT" 2>/dev/null )
python3 - "$F_OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL(F): stdout empty", file=sys.stderr); sys.exit(1)
ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
if "FIRST" not in ctx:
    print("FAIL(F): a new session key should get the full guidance again (missing 'FIRST')", file=sys.stderr); sys.exit(1)
PY

# ---------- (G) after a successful bootstrap, the marker is gone → nothing emitted ----
mkdir -p "$G_DIR/.claude/cache"
printf 'non-git-dir
' > "$G_DIR/.claude/cache/.rein-session-degraded"
( cd "$G_DIR" && git init -q )
python3 "$PLUGIN_ROOT/scripts/rein-bootstrap-project.py" --project-dir "$G_DIR" >/dev/null 2>&1
[ ! -f "$G_DIR/.claude/cache/.rein-session-degraded" ] || { echo "FAIL(G): setup error — degraded marker survived the bootstrap run" >&2; exit 1; }
( cd "$G_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_SESSION_ID="fixture-g-session" bash "$HOOK" </dev/null >"$G_OUT" 2>/dev/null )
python3 - "$G_OUT" <<'PY' || exit 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    print("FAIL(G): stdout empty", file=sys.stderr); sys.exit(1)
ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
if "rein-bootstrap-project.py" in ctx:
    print("FAIL(G): bootstrapped project still carries a bootstrap advisory", file=sys.stderr); sys.exit(1)
if "Answer-only quick rule" not in ctx:
    print("FAIL(G): missing answer-only-mode body marker 'Answer-only quick rule'", file=sys.stderr); sys.exit(1)
PY

echo "test-user-prompt-submit-bootstrap-advisory: OK (A advisory + B silent + C helper-unsafe silent + D non-git parity + E full-then-reminder + F new-session-full + G post-bootstrap-silent)"
