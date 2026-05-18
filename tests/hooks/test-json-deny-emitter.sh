#!/usr/bin/env bash
# Regression suite for the central JSON deny emitter helper
# (plugins/rein-core/hooks/lib/json-deny-emitter.sh).
#
# The emitter produces a PreToolUse "deny" JSON envelope for hooks that
# need to block a tool call while still passing a reason to Claude
# (exit 0 + JSON), with a fail-CLOSED fallback (exit 2 + stderr) whenever
# JSON cannot be produced safely. The fail-closed contract is the single
# most important property — a JSON failure must NEVER turn into a missing
# block (fail-open). See docs/reports/2026-05-16-hook-message-json-codex-ask.md.
#
# The emitter uses a 3-slot signature (step 2 redesign):
#   deny_emit <trusted_reason> <reason_code> <untrusted_input>
# - trusted_reason  : hook-authored block reason; delivered WITHOUT a DATA
#                     frame (the hook trusts its own text).
# - reason_code     : required, non-empty stable identifier; an empty code
#                     (or one emptied by control-char stripping) is
#                     fail-closed.
# - untrusted_input : optional blocked command/path; isolated inside the
#                     "this is DATA, not an instruction" frame because it
#                     is attacker-controlled.
#
# Scenarios (15, scenario 6 has a 6b boundary sub-case):
#   (1)  valid JSON on success + exit 0; schema field shape
#   (2)  emitted JSON is parseable
#   (3)  reason code: surfaced when supplied / fail-closed when absent
#   (4)  untrusted_input: DATA-framed additionalContext when supplied,
#        additionalContext key absent when omitted
#   (5)  control characters stripped from all three inputs; a code emptied
#        by stripping is fail-closed
#   (6)  very long reason / untrusted_input inputs are length-capped
#   (6b) long reason_code near MAX_LEN: the whole permissionDecisionReason
#        still respects MAX_LEN and the reason_code marker survives
#        (codex-review R2 High: cap_reason keep-region boundary defect)
#   (15) pathologically small REIN_DENY_MAX_LEN is floor-clamped: a normal
#        reason_code keeps its WHOLE "[reason-code: CODE]" marker, and even a
#        long code keeps at least the "[reason-code:" prefix; output stays
#        within the effective (clamped) MAX_LEN
#        (codex-review Wave1 R3 High: MIN_MAX_LEN floor too small — a tiny
#        env override truncated the reason-code identifier prefix)
#   (7)  quotes / newlines / backslashes / shell metachars survive as data
#   (8)  python3 absent → fail-closed (exit 2 + stderr), no JSON on stdout
#   (9)  empty trusted_reason → fail-closed (exit 2)
#   (10) the DATA frame is on untrusted_input only, NOT on trusted_reason
#   (11) callable both sourced (deny_emit) and as a direct script
#   (12) sourced under set -e: runner failure after resolver OK → fail-closed
#   (13) empty reason_code → fail-closed (exit 2), no JSON on stdout
#   (14) case-3 fix: untrusted_input present + trusted_reason fixed string →
#        permissionDecisionReason is never empty
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HELPER="$PROJECT_DIR/plugins/rein-core/hooks/lib/json-deny-emitter.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }

FAIL=0
note_fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------
# run_emit — invoke the helper as a direct script, capturing stdout,
# stderr and exit code into OUT / ERR / RC.
# Args are passed straight through to the script.
# ---------------------------------------------------------------
run_emit() {
  local err_file out_file
  err_file=$(mktemp)
  out_file=$(mktemp)
  bash "$HELPER" "$@" >"$out_file" 2>"$err_file"
  RC=$?
  OUT=$(cat "$out_file")
  ERR=$(cat "$err_file")
  rm -f "$err_file" "$out_file"
}

# ---------- (1) valid JSON on success + exit 0 -------------------------------
# reason_code is required, so every success-path call now passes a code.
run_emit "DoD file is required before editing source" "DOD_MISSING"
if [ "$RC" -ne 0 ]; then
  note_fail "(1) success path should exit 0, got $RC (stderr: $ERR)"
fi
OUT="$OUT" python3 - <<'PY' || note_fail "(1) success JSON shape invalid"
import json, os, sys
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
assert hso["hookEventName"] == "PreToolUse", hso.get("hookEventName")
assert hso["permissionDecision"] == "deny", hso.get("permissionDecision")
reason = hso["permissionDecisionReason"]
assert isinstance(reason, str) and reason, repr(reason)
assert "DoD file is required" in reason, repr(reason)
PY
echo "  ok: (1) success → exit 0 + PreToolUse deny envelope"

# ---------- (2) emitted JSON is parseable (no trailing junk) -----------------
run_emit "blocked: review stamp missing" "REVIEW_STAMP_MISSING"
printf '%s' "$OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
  || note_fail "(2) emitted stdout is not valid JSON"
echo "  ok: (2) emitted JSON parses cleanly"

# ---------- (3) reason code surfaced when given, fail-closed when absent -----
# reason_code is now REQUIRED: with a code → surfaced; without → fail-closed.
run_emit "missing routing approval" "ROUTE_NOT_APPROVED"
OUT="$OUT" python3 - <<'PY' || note_fail "(3a) reason code not surfaced"
import json, os
data = json.loads(os.environ["OUT"])
blob = json.dumps(data)
assert "ROUTE_NOT_APPROVED" in blob, "reason code missing from envelope"
PY
run_emit "missing routing approval"
if [ "$RC" -ne 2 ]; then
  note_fail "(3b) absent reason code must fail-closed with exit 2, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(3b) absent reason code must emit no JSON, got: $OUT"
fi
echo "  ok: (3) reason code surfaced when given, fail-closed when absent"

# ---------- (4) untrusted_input → DATA-framed additionalContext --------------
# $3 is the untrusted_input slot: when given it appears in additionalContext
# inside the DATA frame; when omitted the additionalContext key is absent.
run_emit "DoD missing" "DOD_MISSING" "rm -rf /tmp/scratch"
OUT="$OUT" python3 - <<'PY' || note_fail "(4a) untrusted_input not surfaced/framed"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
ac = hso.get("additionalContext", "")
assert "rm -rf /tmp/scratch" in ac, repr(ac)
# Untrusted input must be framed as DATA, not an instruction.
low = ac.lower()
assert ("data" in low and "instruction" in low) or "not an instruction" in low, \
    "untrusted_input not DATA-framed: %r" % ac
PY
run_emit "DoD missing" "DOD_MISSING"
OUT="$OUT" python3 - <<'PY' || note_fail "(4b) additionalContext should be absent"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
assert "additionalContext" not in hso, \
    "additionalContext must be absent when no untrusted_input: %r" % hso
PY
echo "  ok: (4) untrusted_input → DATA-framed additionalContext, absent when omitted"

# ---------- (5) control characters stripped (reason + code + context) -------
# Feed control chars (BEL, ESC, VT, FF) into ALL three inputs — reason,
# reason code, untrusted_input — and assert none survive in the envelope.
CTRL_REASON=$(printf 'reason\x07with\x1bcontrol\x0bchars\x0chere')
CTRL_CODE=$(printf 'CO\x07DE\x1bX')
CTRL_CONTEXT=$(printf 'ctx\x07with\x1bctrl\x0bhere')
run_emit "$CTRL_REASON" "$CTRL_CODE" "$CTRL_CONTEXT"
if [ "$RC" -ne 0 ]; then
  note_fail "(5) control-char input should still emit JSON, got exit $RC"
fi
OUT="$OUT" python3 - <<'PY' || note_fail "(5) control chars leaked into envelope"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
# reason (with the surfaced reason code) and additionalContext are both
# delivered to the model — every field must be clean.
fields = [hso["permissionDecisionReason"], hso.get("additionalContext", "")]
for field in fields:
    for ch in field:
        cp = ord(ch)
        # Allow tab/newline/CR only; reject other C0 control chars + DEL.
        assert (cp >= 0x20 and cp != 0x7F) or ch in "\t\n\r", \
            "control char survived: %r" % ch
PY
# A reason_code made ENTIRELY of control chars empties after stripping —
# that must fail-closed (the S9 "identifiable by code" guarantee needs a
# non-empty code).
CTRL_ONLY_CODE=$(printf '\x07\x1b\x0b\x0c')
run_emit "trusted reason text" "$CTRL_ONLY_CODE"
if [ "$RC" -ne 2 ]; then
  note_fail "(5) code emptied by control-char stripping must fail-closed, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(5) code emptied by stripping must emit no JSON, got: $OUT"
fi
echo "  ok: (5) C0 control chars stripped; code emptied by stripping → fail-closed"

# ---------- (6) very long inputs are length-capped (reason + context) -------
# Also asserts the S9 invariant: the reason_code stays identifiable even when
# a very long trusted_reason forces the permissionDecisionReason to be capped.
# A naive "cap the reason body, append the code, then re-cap the whole thing"
# would truncate the appended "[reason-code: CODE]" off the right edge — the
# block would lose its stable identifier. The cap must keep the code alive.
LONG_PATH=$(python3 -c 'print("/very/long/path/" + "segment/" * 4000 + "file.py")')
LONG_CTX=$(python3 -c 'print("context " * 4000)')
run_emit "$LONG_PATH" "LONG_CODE" "$LONG_CTX"
if [ "$RC" -ne 0 ]; then
  note_fail "(6) very long input should still emit JSON, got exit $RC"
fi
OUT="$OUT" python3 - <<'PY' || note_fail "(6) long input not capped / reason_code lost"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
reason = hso["permissionDecisionReason"]
context = hso.get("additionalContext", "")
# Emitter must cap both delivered fields — a 32k+ char field is not acceptable.
assert len(reason) <= 8192, "reason not length-capped: %d chars" % len(reason)
assert len(context) <= 8192, "context not length-capped: %d chars" % len(context)
# S9: even after the reason was capped, the stable reason_code must survive
# in the (capped) permissionDecisionReason — a capped block is still
# identifiable by its code.
assert "[reason-code: LONG_CODE]" in reason, \
    "reason_code dropped from capped reason (S9 violation): %r" % reason[-120:]
PY
echo "  ok: (6) oversized reason/untrusted_input capped; reason_code survives the cap"

# ---------- (6b) long reason_code near MAX_LEN: whole reason still ≤ MAX_LEN -
# codex-review R2 High: cap_reason reserves `keep = MAX_LEN - len(suffix)`
# for the body, where the suffix is "\n[reason-code: CODE]". When CODE is so
# long that `keep` lands in 0 < keep < len(TRUNC_MARKER), cap_to(body, keep)
# returns the truncation marker WHOLE (len ~12 > keep) — so capped_body +
# suffix exceeds MAX_LEN. Scenario (6) above only stresses a long *reason*
# with a short code, never a long *code*; this case closes that gap.
#
# code_len 8175 → suffix len 8191 → keep 1 (the broken 0<keep<12 region).
# The whole permissionDecisionReason must still be ≤ MAX_LEN (8192) AND the
# reason_code marker must survive (S9: a capped block stays identifiable).
LONG_CODE=$(python3 -c 'print("C" * 8175)')
run_emit "short reason body" "$LONG_CODE"
if [ "$RC" -ne 0 ]; then
  note_fail "(6b) long reason_code should still emit JSON, got exit $RC (stderr: $ERR)"
fi
OUT="$OUT" python3 - <<'PY' || note_fail "(6b) long reason_code: reason exceeds MAX_LEN or code lost"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
reason = hso["permissionDecisionReason"]
# The whole reason — body + code suffix — must respect MAX_LEN even when the
# code suffix alone is near the cap. This is the R2 boundary defect.
assert len(reason) <= 8192, \
    "permissionDecisionReason exceeds MAX_LEN with long code: %d chars" % len(reason)
# S9: the reason_code marker must still be present — a capped block stays
# identifiable by its code. The "[reason-code:" prefix is the stable anchor.
assert "[reason-code:" in reason, \
    "reason_code marker dropped with long code (S9 violation): %r" % reason[-120:]
PY
# Sweep the whole broken keep region (suffix len 8175..8210, i.e. keep 17..-18)
# so no off-by-one slips back in. Every result must stay ≤ MAX_LEN with the
# marker alive.
for code_len in 8170 8175 8176 8179 8180 8185 8190 8200; do
  CODE_N=$(python3 -c "print('C' * $code_len)")
  run_emit "short reason body" "$CODE_N"
  if [ "$RC" -ne 0 ]; then
    note_fail "(6b) code_len=$code_len should emit JSON, got exit $RC"
    continue
  fi
  OUT="$OUT" python3 - <<'PY' || note_fail "(6b) code_len boundary sweep failed"
import json, os
data = json.loads(os.environ["OUT"])
reason = data["hookSpecificOutput"]["permissionDecisionReason"]
assert len(reason) <= 8192, "reason exceeds MAX_LEN: %d chars" % len(reason)
assert "[reason-code:" in reason, "reason_code marker dropped: %r" % reason[-80:]
PY
done
echo "  ok: (6b) long reason_code near MAX_LEN: whole reason ≤ MAX_LEN, code survives"

# ---------- (7) quotes / newlines / backslashes survive as data --------------
TRICKY=$(printf 'he said "rm -rf /" \\ and\nthen `whoami` $(id) end')
run_emit "$TRICKY" "TRICKY_CODE"
if [ "$RC" -ne 0 ]; then
  note_fail "(7) tricky input should emit JSON, got exit $RC"
fi
OUT="$OUT" python3 - <<'PY' || note_fail "(7) tricky chars broke JSON"
import json, os
data = json.loads(os.environ["OUT"])
reason = data["hookSpecificOutput"]["permissionDecisionReason"]
# The quoted command must survive verbatim as DATA, not be executed.
assert 'rm -rf /' in reason, repr(reason)
assert 'whoami' in reason, repr(reason)
PY
echo "  ok: (7) quotes/newlines/metachars preserved as data, JSON intact"

# ---------- (8) python3 absent → fail-closed ---------------------------------
# Build a clean PATH that still has coreutils (so the emitter script itself
# can run) but has NO python3/python — this forces resolve_python to fail.
# A python-named shim that always fails is dropped in first to also cover
# the "command -v finds it but it does not launch" case.
FAKE_BIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/python3"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/python"
chmod +x "$FAKE_BIN/python3" "$FAKE_BIN/python"
# Resolve the directories that hold coreutils (bash, cat, dirname, …) so the
# emitter and its `cd`/`dirname` calls keep working without any real python.
CLEAN_PATH="$FAKE_BIN"
for tool in bash cat dirname mktemp chmod env tr; do
  tdir=$(dirname "$(command -v "$tool" 2>/dev/null)" 2>/dev/null)
  case ":$CLEAN_PATH:" in
    *":$tdir:"*) : ;;
    *) [ -n "$tdir" ] && CLEAN_PATH="$CLEAN_PATH:$tdir" ;;
  esac
done
run_emit_no_python() {
  local err_file out_file
  err_file=$(mktemp)
  out_file=$(mktemp)
  # PATH has coreutils but only failing python shims → resolve_python fails.
  PATH="$CLEAN_PATH" REIN_PYTHON="" VIRTUAL_ENV="" \
    bash "$HELPER" "$@" >"$out_file" 2>"$err_file"
  RC=$?
  OUT=$(cat "$out_file")
  ERR=$(cat "$err_file")
  rm -f "$err_file" "$out_file"
}
run_emit_no_python "this block must fail closed" "NO_PYTHON_CODE"
rm -rf "$FAKE_BIN"
if [ "$RC" -ne 2 ]; then
  note_fail "(8) python3 absent must fail-closed with exit 2, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(8) python3 absent must emit NO JSON on stdout, got: $OUT"
fi
if [ -z "$ERR" ]; then
  note_fail "(8) python3 absent must write a diagnostic to stderr"
fi
echo "  ok: (8) python3 absent → fail-closed (exit 2, stderr, no stdout JSON)"

# ---------- (9) empty trusted_reason → fail-closed ---------------------------
run_emit "" "SOME_CODE"
if [ "$RC" -ne 2 ]; then
  note_fail "(9) empty trusted_reason must fail-closed with exit 2, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(9) empty trusted_reason must emit no JSON, got: $OUT"
fi
echo "  ok: (9) empty trusted_reason → fail-closed (exit 2)"

# ---------- (10) DATA frame is on untrusted_input only -----------------------
# In the 3-slot design the DATA frame isolates untrusted_input ONLY. The
# trusted_reason is hook-authored, so it must NOT carry the frame.
run_emit "Reading the .env file via Bash is blocked." "ENV_READ_BLOCKED" \
  "/Users/x/.env"
OUT="$OUT" python3 - <<'PY' || note_fail "(10) DATA frame placement wrong"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
reason = hso["permissionDecisionReason"]
context = hso.get("additionalContext", "")
low_reason = reason.lower()
low_ctx = context.lower()


def is_framed(text):
    return ("data" in text and "instruction" in text) or \
        "not an instruction" in text


# trusted_reason slot must NOT be DATA-framed (hook-authored, trusted).
assert not is_framed(low_reason), \
    "trusted_reason must not carry the DATA frame: %r" % reason
# untrusted_input slot MUST be DATA-framed.
assert is_framed(low_ctx), \
    "untrusted_input must carry the DATA frame: %r" % context
PY
echo "  ok: (10) DATA frame on untrusted_input only, not on trusted_reason"

# ---------- (11) usable both sourced and as a script -------------------------
SRC_OUT=$(bash -c "
set -u
source '$HELPER'
deny_emit 'sourced invocation reason' 'SOURCED_CODE'
")
SRC_RC=$?
if [ "$SRC_RC" -ne 0 ]; then
  note_fail "(11) sourced deny_emit should exit 0, got $SRC_RC"
fi
SRC_OUT="$SRC_OUT" python3 - <<'PY' || note_fail "(11) sourced deny_emit JSON invalid"
import json, os
data = json.loads(os.environ["SRC_OUT"])
assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
PY
echo "  ok: (11) callable as direct script and via sourced deny_emit"

# ---------- (12) sourced under set -e: runner failure after resolver OK ------
# codex-review High (2026-05-16): a python that passes the resolver health
# probe but then fails on the real serialise call must STILL fail-closed
# (exit 2). Under a sourcing hook's `set -e`, a plain `json=$(...)` assignment
# would let the nonzero status abort the hook before the fail-closed
# normalisation runs — a fail-open path. The emitter now guards it with `if`.
FAKE_BIN3=$(mktemp -d)
cat > "$FAKE_BIN3/python3" <<'SHIM'
#!/bin/sh
# Resolver health probe (`-c "import sys; sys.exit(0)"`) → succeed.
# Real deny-JSON build (its `-c` program contains `import json`) → exit 127,
# simulating an interpreter/runner failure AFTER resolution succeeded.
for a in "$@"; do
  case "$a" in
    *"import json"*) exit 127 ;;
  esac
done
exit 0
SHIM
chmod +x "$FAKE_BIN3/python3"
CLEAN_PATH3="$FAKE_BIN3"
for tool in bash cat dirname mktemp chmod env tr; do
  tdir=$(dirname "$(command -v "$tool" 2>/dev/null)" 2>/dev/null)
  case ":$CLEAN_PATH3:" in
    *":$tdir:"*) : ;;
    *) [ -n "$tdir" ] && CLEAN_PATH3="$CLEAN_PATH3:$tdir" ;;
  esac
done
SE_OUT=$(mktemp)
SE_ERR=$(mktemp)
PATH="$CLEAN_PATH3" REIN_PYTHON="" VIRTUAL_ENV="" bash -c "
set -eu
source '$HELPER'
deny_emit 'runner fails after resolver ok' 'RUNNER_FAIL_CODE'
" >"$SE_OUT" 2>"$SE_ERR"
SE_RC=$?
rm -rf "$FAKE_BIN3"
if [ "$SE_RC" -ne 2 ]; then
  note_fail "(12) sourced+set -e runner failure must fail-closed exit 2, got $SE_RC"
fi
if [ -s "$SE_OUT" ]; then
  note_fail "(12) sourced+set -e runner failure must emit no JSON, got: $(cat "$SE_OUT")"
fi
rm -f "$SE_OUT" "$SE_ERR"
echo "  ok: (12) sourced + set -e + runner failure → fail-closed (exit 2, no JSON)"

# ---------- (13) empty reason_code → fail-closed -----------------------------
# S3 core contract: reason_code is required. An empty code (even with a
# valid reason and untrusted_input) must fail-closed — no JSON on stdout.
run_emit "trusted reason text" "" "untrusted command here"
if [ "$RC" -ne 2 ]; then
  note_fail "(13) empty reason_code must fail-closed with exit 2, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(13) empty reason_code must emit no JSON, got: $OUT"
fi
if [ -z "$ERR" ]; then
  note_fail "(13) empty reason_code must write a diagnostic to stderr"
fi
echo "  ok: (13) empty reason_code → fail-closed (exit 2, stderr, no stdout JSON)"

# ---------- (14) case-3 fix: trusted_reason always populated -----------------
# S4: even when only the untrusted_input slot carries meaningful detail, the
# trusted_reason slot keeps permissionDecisionReason non-empty, and the
# untrusted command shows up ONLY in additionalContext (DATA-framed).
run_emit "Tool call blocked: see reason." "CASE3_FIX" "rm -rf /tmp/x"
if [ "$RC" -ne 0 ]; then
  note_fail "(14) case-3 fix call should exit 0, got $RC (stderr: $ERR)"
fi
OUT="$OUT" python3 - <<'PY' || note_fail "(14) case-3 fix: reason empty or input misplaced"
import json, os
data = json.loads(os.environ["OUT"])
hso = data["hookSpecificOutput"]
reason = hso["permissionDecisionReason"]
context = hso.get("additionalContext", "")
# trusted_reason slot keeps the reason non-empty (the case-3 defect fix).
assert reason.strip(), "permissionDecisionReason must not be empty: %r" % reason
assert "Tool call blocked" in reason, repr(reason)
# The untrusted command lives ONLY in additionalContext, never in the reason.
assert "rm -rf /tmp/x" in context, repr(context)
assert "rm -rf /tmp/x" not in reason, \
    "untrusted_input leaked into trusted reason: %r" % reason
low_reason = reason.lower()
# And the trusted reason has no DATA frame (frame is on untrusted only).
assert not (("data" in low_reason and "instruction" in low_reason)
            or "not an instruction" in low_reason), \
    "trusted_reason must not carry the DATA frame: %r" % reason
PY
echo "  ok: (14) case-3 fix → trusted_reason always populated, untrusted isolated"

# ---------- (15) pathologically small REIN_DENY_MAX_LEN is floor-clamped -----
# codex-review Wave1 R3 High: REIN_DENY_MAX_LEN is operator-tunable. A tiny
# hostile/typo value (1, 17, …) is clamped UP to MIN_MAX_LEN. The old floor
# (17) was large enough only for the fixed scaffold + ONE code char, so a
# NORMAL reason_code fed through cap_reason's keep<0 branch had its
# "[reason-code:" identifier prefix sliced off — an exit-0 bounded output
# whose reason_code was no longer identifiable (S9 violation).
#
# Invariants this scenario locks:
#   (a) a NORMAL-length reason_code keeps its WHOLE "[reason-code: CODE]"
#       marker, for any trusted_reason length and any sub-floor MAX_LEN;
#   (b) even a pathologically LONG reason_code keeps at least the stable
#       "[reason-code:" prefix (never sliced into "[rea…[truncated]");
#   (c) the whole permissionDecisionReason stays within the effective
#       (clamped) MAX_LEN — the clamp produces a bounded result, not an
#       over-length one.
# The effective MAX_LEN is read back from the emitter itself so the test
# does not hard-code the floor value (one source of truth: the emitter).

# Effective floor (MIN_MAX_LEN) as the emitter computes it — derived, not
# hard-coded, so a future floor change keeps this test honest.
EFFECTIVE_FLOOR=$(REIN_DENY_MAX_LEN=1 python3 - <<'PY'
import os
TRUNC_MARKER = "…[truncated]"
REASON_CODE_TEMPLATE = "\n[reason-code: {code}]"
REASON_CODE_FIXED_LEN = len(REASON_CODE_TEMPLATE.replace("{code}", ""))
# Must mirror json-deny-emitter.sh MIN_MAX_LEN exactly.
NORMAL_CODE_BUDGET = 32
MIN_BODY_BUDGET = 24
MIN_MAX_LEN = (
    REASON_CODE_FIXED_LEN + NORMAL_CODE_BUDGET + len(TRUNC_MARKER) + MIN_BODY_BUDGET
)
print(MIN_MAX_LEN)
PY
)

# (15a) NORMAL reason_code + long trusted_reason + sub-floor MAX_LEN values:
# the whole "[reason-code: CODE]" marker must survive intact.
LONG_REASON=$(python3 -c 'print("block reason detail " * 600)')
for tiny in 1 16 17 18 "$EFFECTIVE_FLOOR"; do
  for ncode in DOD_MISSING ENV_READ_BLOCKED DESTRUCTIVE_GIT_CONFIRM CODE_EDITED_AFTER_REVIEW; do
    REIN_DENY_MAX_LEN="$tiny" run_emit "$LONG_REASON" "$ncode"
    if [ "$RC" -ne 0 ]; then
      note_fail "(15a) MAX_LEN=$tiny code=$ncode should emit JSON, got exit $RC (stderr: $ERR)"
      continue
    fi
    OUT="$OUT" NCODE="$ncode" FLOOR="$EFFECTIVE_FLOOR" python3 - <<'PY' \
      || note_fail "(15a) MAX_LEN floor-clamp lost the normal reason_code marker"
import json, os
data = json.loads(os.environ["OUT"])
reason = data["hookSpecificOutput"]["permissionDecisionReason"]
ncode = os.environ["NCODE"]
floor = int(os.environ["FLOOR"])
# (a) the WHOLE marker for a normal-length code must survive intact.
marker = "[reason-code: %s]" % ncode
assert marker in reason, \
    "normal reason_code marker sliced by floor-clamp (S9): %r" % reason[-160:]
# (c) result is bounded by the effective (clamped) MAX_LEN.
assert len(reason) <= floor, \
    "clamped reason exceeds effective MAX_LEN %d: %d chars" % (floor, len(reason))
PY
  done
done

# (15b) pathologically LONG reason_code + tiny MAX_LEN: the marker cannot
# survive whole, but the stable "[reason-code:" prefix must NOT be sliced
# off — the R3 repro (REIN_DENY_MAX_LEN=17, code_len=8175) must now keep it.
HUGE_CODE=$(python3 -c 'print("C" * 8175)')
for tiny in 1 17 "$EFFECTIVE_FLOOR"; do
  REIN_DENY_MAX_LEN="$tiny" run_emit "short reason body" "$HUGE_CODE"
  if [ "$RC" -ne 0 ]; then
    note_fail "(15b) MAX_LEN=$tiny long code should emit JSON, got exit $RC (stderr: $ERR)"
    continue
  fi
  OUT="$OUT" FLOOR="$EFFECTIVE_FLOOR" python3 - <<'PY' \
    || note_fail "(15b) long reason_code: '[reason-code:' prefix sliced or over-length"
import json, os
data = json.loads(os.environ["OUT"])
reason = data["hookSpecificOutput"]["permissionDecisionReason"]
floor = int(os.environ["FLOOR"])
# (b) the stable identifier prefix must survive even for a huge code — the
# old floor 17 sliced this into "[rea…[truncated]".
assert "[reason-code:" in reason, \
    "reason_code prefix sliced off by tiny MAX_LEN (R3 defect): %r" % reason[:40]
# (c) still bounded by the effective (clamped) MAX_LEN.
assert len(reason) <= floor, \
    "clamped reason exceeds effective MAX_LEN %d: %d chars" % (floor, len(reason))
PY
done

# (15c) the floor-clamp must not break the fail-closed contract: an empty
# reason_code under a tiny MAX_LEN still fails closed (exit 2, no JSON).
REIN_DENY_MAX_LEN=1 run_emit "trusted reason text" ""
if [ "$RC" -ne 2 ]; then
  note_fail "(15c) empty reason_code under tiny MAX_LEN must fail-closed, got $RC"
fi
if [ -n "$OUT" ]; then
  note_fail "(15c) empty reason_code under tiny MAX_LEN must emit no JSON, got: $OUT"
fi
echo "  ok: (15) tiny REIN_DENY_MAX_LEN floor-clamped: normal code marker whole, long-code prefix kept, bounded"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-json-deny-emitter: OK (15 scenarios, incl. 6b boundary sub-case)"
  exit 0
else
  echo "test-json-deny-emitter: $FAIL scenario(s) FAILED"
  exit 1
fi
