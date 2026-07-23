#!/usr/bin/env bash
# test-onboarding-primer.sh
#
# ONBOARD-1 Phase 1 regressions — first-session onboarding primer.
#
# Covers Scope IDs:
#   SCOPE-TEST-FIRST    — marker absent → primer emitted + exactly one marker created
#   SCOPE-TEST-SECOND   — marker present → both channels silent (rules still ship 6 rules)
#   SCOPE-TEST-CHANNELS — (a) bootstrap stdout carries primer, (b) rules
#                         additionalContext carries primer + exactly one envelope,
#                         (c) hooks.json SessionStart bootstrap index < rules index,
#                         + both channels' primer body byte-identical
#   SCOPE-TEST-BACKFILL — rc=0 (trail/ present) + marker absent → 1 emit + marker,
#                         re-run silent
#   SCOPE-PERF          — marker present (pass path) → no primer emit, no marker write
#   Helper unit (Task 1.1) — rein_is_onboarded / rein_mark_onboarded contract
#
# Strategy: real temp git repos + CLAUDE_PLUGIN_ROOT pointed at the repo's
# plugin root, mirroring test-session-start-bootstrap-helper-refactor.sh. The
# rc=10 (fresh) vs rc=0 (existing user) paths are driven by trail/ +
# .rein/project.json presence (bootstrap-check.sh contract).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
BOOTSTRAP_HOOK="$PLUGIN_ROOT/hooks/session-start-bootstrap.sh"
RULES_HOOK="$PLUGIN_ROOT/hooks/session-start-rules.sh"
HELPER="$PLUGIN_ROOT/hooks/lib/onboarded-check.sh"

# Primer anchors (the three required copy elements per SCOPE-PRIMER-COPY).
# Friendly 3-line copy (2026-06-05): welcome line / inline flow / stuck-is-OK.
PRIMER_PARA_ANCHOR="처음 오셨네요"                            # (a) welcome line (sed start)
PRIMER_FLOW_ANCHOR="무엇을 할지 정하기"                       # (b) flow (define→approve→review)
PRIMER_STUCK_ANCHOR="막혀도 괜찮아요"                         # (c) stuck-is-normal (sed end)
# Persona selection guidance (Task 5.2 — primer-adds-persona-selection-guidance-without-new-marker).
PRIMER_PERSONA_ANCHOR1="말투도 고를 수 있어요"                # (d) persona guidance line 1
PRIMER_PERSONA_ANCHOR2="페르소나 골라줘"                      # (d) persona trigger phrase

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

TMP_DIRS=()
mk_repo() {
  # mk_repo <kind>  → echo the new repo path.
  #   kind=fresh    : git repo, no trail/, no marker  (rc=10 path)
  #   kind=existing : git repo + trail/ + .rein/project.json + index, no marker (rc=0)
  local kind="$1" d
  d="$(mktemp -d "/tmp/onb-test-XXXXXX")"
  git -C "$d" init -q 2>/dev/null
  if [ "$kind" = "existing" ]; then
    mkdir -p "$d/trail" "$d/.rein"
    printf '%s' '{"mode":"plugin","scope":"project","version":"test"}' > "$d/.rein/project.json"
    printf '# trail/index.md\n' > "$d/trail/index.md"
  fi
  TMP_DIRS+=("$d")
  printf '%s\n' "$d"
}
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

run_bootstrap() { ( cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BOOTSTRAP_HOOK" </dev/null 2>/dev/null ); }
run_rules()     { ( cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RULES_HOOK" </dev/null 2>/dev/null ); }

# extract_additional_context FILE → print additionalContext, fail loud if not
# exactly one SessionStart envelope.
extract_additional_context() {
  python3 - "$1" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
# Exactly one JSON object on stdout (one envelope).
lines = [l for l in raw.splitlines() if l.strip()]
if len(lines) != 1:
    print("__ENVELOPE_COUNT_NOT_ONE__", len(lines), file=sys.stderr)
    sys.exit(3)
data = json.loads(lines[0])
hso = data["hookSpecificOutput"]
assert hso["hookEventName"] == "SessionStart", hso.get("hookEventName")
sys.stdout.write(hso["additionalContext"])
PY
}

# --------------------------------------------------------------------------
# Pre-flight: required files exist + executable.
# --------------------------------------------------------------------------
[ -f "$HELPER" ]         || { echo "FAIL: helper missing: $HELPER" >&2; exit 1; }
[ -x "$BOOTSTRAP_HOOK" ] || { echo "FAIL: bootstrap hook not executable" >&2; exit 1; }
[ -x "$RULES_HOOK" ]     || { echo "FAIL: rules hook not executable" >&2; exit 1; }

# ==========================================================================
# Helper unit (Task 1.1): rein_is_onboarded / rein_mark_onboarded
# ==========================================================================
echo "RUN helper_unit"
(
  # shellcheck disable=SC1090
  source "$HELPER"
  d="$(mktemp -d "/tmp/onb-helper-XXXXXX")"
  trap 'rm -rf "$d"' EXIT
  if rein_is_onboarded "$d"; then echo "  FAIL: rein_is_onboarded true with no marker"; exit 1; fi
  rein_mark_onboarded "$d" "9.9.9" || { echo "  FAIL: rein_mark_onboarded returned non-zero"; exit 1; }
  if ! rein_is_onboarded "$d"; then echo "  FAIL: rein_is_onboarded false after mark"; exit 1; fi
  grep -q '^onboarded=' "$d/.rein/.onboarded" || { echo "  FAIL: marker missing onboarded= field"; exit 1; }
  grep -q '^version=9.9.9$' "$d/.rein/.onboarded" || { echo "  FAIL: marker missing version=9.9.9"; exit 1; }
  # rein_primer_body emits the three required anchors.
  body="$(rein_primer_body)"
  case "$body" in *"$PRIMER_PARA_ANCHOR"*) :;; *) echo "  FAIL: primer body missing paragraph anchor"; exit 1;; esac
  case "$body" in *"$PRIMER_FLOW_ANCHOR"*) :;; *) echo "  FAIL: primer body missing flow anchor"; exit 1;; esac
  case "$body" in *"$PRIMER_STUCK_ANCHOR"*) :;; *) echo "  FAIL: primer body missing stuck anchor"; exit 1;; esac
  # Task 5.2: persona selection guidance present in primer body (no new marker/hook).
  case "$body" in *"$PRIMER_PERSONA_ANCHOR1"*) :;; *) echo "  FAIL: primer body missing persona guidance line"; exit 1;; esac
  case "$body" in *"$PRIMER_PERSONA_ANCHOR2"*) :;; *) echo "  FAIL: primer body missing persona trigger phrase"; exit 1;; esac
  echo "  OK"
) || FAIL=$((FAIL + 1))

# ==========================================================================
# SCOPE-TEST-CHANNELS (c): hooks.json SessionStart bootstrap index < rules index
# ==========================================================================
echo "RUN channels_hooks_json_order"
python3 - "$PLUGIN_ROOT/hooks/hooks.json" <<'PY'
import json, sys
m = json.loads(open(sys.argv[1]).read())
ss = m["hooks"]["SessionStart"]
cmds = [h["command"] for g in ss for h in g.get("hooks", [])]
b = next((i for i, c in enumerate(cmds) if c.endswith("session-start-bootstrap.sh")), None)
r = next((i for i, c in enumerate(cmds) if c.endswith("session-start-rules.sh")), None)
assert b is not None, "session-start-bootstrap.sh not declared in SessionStart"
assert r is not None, "session-start-rules.sh not declared in SessionStart"
assert b < r, f"bootstrap index {b} must be < rules index {r} (single-writer safety net)"
PY
if [ "$?" = "0" ]; then pass "hooks.json SessionStart bootstrap declared before rules"; else fail "hooks.json SessionStart order (bootstrap<rules)"; fi

# ==========================================================================
# SCOPE-TEST-FIRST + SCOPE-TEST-CHANNELS(a)(b) + body equality (fresh / rc=10)
# ==========================================================================
echo "RUN first_session_fresh_rc10"
REPO="$(mk_repo fresh)"
BS_OUT="$(mktemp)"; RL_OUT="$(mktemp)"
TMP_DIRS+=("$BS_OUT" "$RL_OUT")
run_bootstrap "$REPO" > "$BS_OUT"
# bootstrap is read-only — marker must NOT exist yet (SCOPE-SINGLE-WRITER).
if [ -f "$REPO/.rein/.onboarded" ]; then fail "bootstrap wrote marker (must be read-only)"; else pass "bootstrap read-only (no marker after bootstrap)"; fi
# (a) bootstrap stdout carries the primer.
if grep -qF "$PRIMER_FLOW_ANCHOR" "$BS_OUT"; then pass "bootstrap stdout carries primer (SCOPE-TEST-CHANNELS a)"; else fail "bootstrap stdout missing primer"; fi
run_rules "$REPO" > "$RL_OUT"
# (b) rules additionalContext carries the primer + exactly one envelope.
CTX="$(extract_additional_context "$RL_OUT")"; ENV_RC=$?
if [ "$ENV_RC" != "0" ]; then fail "rules envelope not exactly one / parse error"; else
  if printf '%s' "$CTX" | grep -qF "$PRIMER_FLOW_ANCHOR"; then pass "rules additionalContext carries primer (SCOPE-TEST-CHANNELS b)"; else fail "rules additionalContext missing primer"; fi
  if printf '%s' "$CTX" | grep -qF "operating-sequence" || printf '%s' "$CTX" | grep -qiF "operating sequence"; then pass "rules additionalContext still ships rule bodies"; else fail "rules additionalContext lost rule bodies"; fi
fi
# SCOPE-TEST-FIRST: after rules, exactly one marker created.
if [ -f "$REPO/.rein/.onboarded" ]; then pass "marker created by rules (SCOPE-TEST-FIRST)"; else fail "marker not created after rules"; fi
# Both channels' primer body byte-identical (single shared definition).
# Extract the primer paragraph block (from para anchor line down to stuck line) from each.
BS_PRIMER="$(grep -n "$PRIMER_PARA_ANCHOR" "$BS_OUT" >/dev/null && sed -n "/$PRIMER_PARA_ANCHOR/,/$PRIMER_STUCK_ANCHOR/p" "$BS_OUT")"
RL_PRIMER="$(printf '%s' "$CTX" | sed -n "/$PRIMER_PARA_ANCHOR/,/$PRIMER_STUCK_ANCHOR/p")"
if [ -n "$BS_PRIMER" ] && [ "$BS_PRIMER" = "$RL_PRIMER" ]; then pass "both channels carry identical primer body"; else fail "primer body differs between channels"; fi
# Negative anchor: primer must NOT carry the out-of-scope 11-step gate map header.
if printf '%s' "$CTX" | grep -qF "11단계"; then fail "primer leaked out-of-scope gate map (11단계)"; else pass "primer omits out-of-scope gate map"; fi

# ==========================================================================
# SCOPE-TEST-SECOND + SCOPE-PERF: marker present → both channels silent
# ==========================================================================
echo "RUN second_session_silent"
# REPO from the previous block now has the marker → reuse as "second session".
BS2="$(mktemp)"; RL2="$(mktemp)"
TMP_DIRS+=("$BS2" "$RL2")
# Snapshot marker mtime to prove no re-write occurs (SCOPE-PERF: no write on pass path).
M_BEFORE="$(cat "$REPO/.rein/.onboarded")"
run_bootstrap "$REPO" > "$BS2"
run_rules "$REPO" > "$RL2"
if grep -qF "$PRIMER_FLOW_ANCHOR" "$BS2"; then fail "bootstrap re-emitted primer on second session"; else pass "bootstrap silent on second session (SCOPE-TEST-SECOND)"; fi
CTX2="$(extract_additional_context "$RL2")"; ENV2_RC=$?
if [ "$ENV2_RC" != "0" ]; then fail "second-session rules envelope not exactly one"; else
  if printf '%s' "$CTX2" | grep -qF "$PRIMER_FLOW_ANCHOR"; then fail "rules re-emitted primer on second session"; else pass "rules additionalContext primer-free on second session (SCOPE-TEST-SECOND)"; fi
  if printf '%s' "$CTX2" | grep -qF "operating-sequence" || printf '%s' "$CTX2" | grep -qiF "operating sequence"; then pass "rules still ships rule bodies on second session"; else fail "rules lost rule bodies on second session"; fi
fi
M_AFTER="$(cat "$REPO/.rein/.onboarded")"
if [ "$M_BEFORE" = "$M_AFTER" ]; then pass "marker not re-written on pass path (SCOPE-PERF)"; else fail "marker re-written on pass path (perf regression)"; fi

# ==========================================================================
# SCOPE-TEST-BACKFILL: rc=0 existing user, marker absent → 1 emit + marker, re-run silent
# ==========================================================================
echo "RUN backfill_rc0"
BREPO="$(mk_repo existing)"
BB1="$(mktemp)"; BR1="$(mktemp)"; BB2="$(mktemp)"; BR2="$(mktemp)"
TMP_DIRS+=("$BB1" "$BR1" "$BB2" "$BR2")
run_bootstrap "$BREPO" > "$BB1"
# bootstrap still read-only on rc=0.
if [ -f "$BREPO/.rein/.onboarded" ]; then fail "bootstrap wrote marker on rc=0 (must be read-only)"; else pass "bootstrap read-only on rc=0 backfill"; fi
if grep -qF "$PRIMER_FLOW_ANCHOR" "$BB1"; then pass "bootstrap backfill emits primer once (rc=0)"; else fail "bootstrap backfill did not emit primer (rc=0)"; fi
run_rules "$BREPO" > "$BR1"
if [ -f "$BREPO/.rein/.onboarded" ]; then pass "rules wrote marker on rc=0 backfill"; else fail "rules did not write marker on rc=0 backfill"; fi
CTXB="$(extract_additional_context "$BR1")"
if printf '%s' "$CTXB" | grep -qF "$PRIMER_FLOW_ANCHOR"; then pass "rules backfill carries primer (rc=0)"; else fail "rules backfill missing primer (rc=0)"; fi
# Re-run: both channels silent.
run_bootstrap "$BREPO" > "$BB2"
run_rules "$BREPO" > "$BR2"
if grep -qF "$PRIMER_FLOW_ANCHOR" "$BB2"; then fail "bootstrap re-emitted after backfill"; else pass "bootstrap silent after backfill (SCOPE-TEST-BACKFILL)"; fi
CTXB2="$(extract_additional_context "$BR2")"
if printf '%s' "$CTXB2" | grep -qF "$PRIMER_FLOW_ANCHOR"; then fail "rules re-emitted after backfill"; else pass "rules silent after backfill (SCOPE-TEST-BACKFILL)"; fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-onboarding-primer: OK (helper + first/second/channels/backfill/perf)"
  exit 0
else
  echo "test-onboarding-primer: $FAIL assertion(s) FAILED" >&2
  exit 1
fi
