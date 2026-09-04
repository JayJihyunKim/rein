#!/usr/bin/env bash
# e2e: git-required onboarding round trip against the SOURCE tree hooks
# (git-required-onboarding DoD). Relocatable: the repo root is derived from
# this script's own directory, never hardcoded.
#
#   S1  non-git dir with a space in its name: SessionStart guidance → prompt-submit
#       reminder → rendered command passes bash gate (no marker) → tampered blocked
#       → literal execution refused (rc 3) → git init → literal execution ok →
#       marker cleared → gate silent → advisory silent
#   S2a mixed: $PWD = fresh git repo A, envelope cwd = non-git B → A NOT bootstrapped,
#       marker under B, gate passes through keyed on B
#   S2b mixed reverse: $PWD = non-git B, envelope cwd = fresh git repo A → A auto-bootstrapped
#   S3  single-quote path: rendered command passes gate via exact match; same command with a
#       different --project-dir target is blocked
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR="${PR_OVERRIDE:-$REPO/plugins/rein-core}"
SS="$PR/hooks/session-start-bootstrap.sh"
UPS="$PR/hooks/user-prompt-submit-rules.sh"
GATE="$PR/hooks/pre-tool-use-bash-bootstrap-gate.sh"

[ -f "$SS" ]   || { echo "FAIL: $SS missing" >&2; exit 1; }
[ -f "$UPS" ]  || { echo "FAIL: $UPS missing" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FAIL: $GATE missing" >&2; exit 1; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/e2e-onb-XXXXXX")
trap 'rm -rf "$SB"' EXIT
export REIN_SESSION_ID="e2e-$$"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }
ng(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else ng "$1"; fi; }

env_json(){ python3 -c 'import json,sys;print(json.dumps({"cwd":sys.argv[1]}))' "$1"; }
bash_json(){ python3 -c 'import json,sys;print(json.dumps({"cwd":sys.argv[1],"tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$1" "$2"; }
run_ss(){ env_json "$1" | (cd "$2" && CLAUDE_PLUGIN_ROOT=$PR bash "$SS") >"$3" 2>"$3.err"; echo $?; }
run_ups(){ env_json "$1" | (cd "$2" && CLAUDE_PLUGIN_ROOT=$PR bash "$UPS") >"$3" 2>"$3.err"; echo $?; }
run_gate(){ bash_json "$1" "$3" | (cd "$2" && CLAUDE_PLUGIN_ROOT=$PR bash "$GATE") >"$4" 2>"$4.err"; echo $?; }
extract_cmd(){ python3 -c '
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r"python3 (?:\x27[^\x27]*\x27|\"[^\"]*\"|(?:\\.|\S)+) --project-dir (?:\x27[^\x27]*\x27|\"[^\"]*\"|(?:\\.|\S)+)", t)
print(m.group(0) if m else "")' "$1"; }
marker(){ printf '%s/.claude/cache/.rein-session-degraded' "$1"; }

echo "== S1: non-git dir with space =="
D="$SB/My Project"; mkdir -p "$D"
rc=$(run_ss "$D" "$D" "$SB/s1.ss")
check "S1 session-start rc=0 (got $rc)" '[ "$rc" = 0 ]'
check "S1 guidance mentions git init" 'grep -q "git init" "$SB/s1.ss"'
check "S1 guidance asks approval first" 'grep -q "ask the user FIRST" "$SB/s1.ss"'
check "S1 marker non-git-dir under D" '[ "$(head -n1 "$(marker "$D")" 2>/dev/null)" = non-git-dir ]'
CMD=$(extract_cmd "$SB/s1.ss")
echo "  rendered: $CMD"
check "S1 rendered command found" '[ -n "$CMD" ]'
check "S1 rendered command has no backslash" '! printf "%s" "$CMD" | grep -q "\\\\"'
rc=$(run_ups "$D" "$D" "$SB/s1.ups")
check "S1 2nd prompt = short reminder (no approval question)" 'grep -q -i "still off\|꺼져" "$SB/s1.ups" && ! grep -q "ask the user FIRST" "$SB/s1.ups"'
rc=$(run_gate "$D" "$D" "$CMD" "$SB/s1.g1")
check "S1 gate (degraded) passes rendered cmd (rc $rc)" '[ "$rc" = 0 ]'
rm -f "$(marker "$D")"
rc=$(run_gate "$D" "$D" "$CMD" "$SB/s1.g2")
check "S1 gate (NO marker) passes rendered cmd via allow-list (rc $rc)" '[ "$rc" = 0 ]'
rc=$(run_gate "$D" "$D" "$CMD --allow-non-git" "$SB/s1.g3")
check "S1 gate passes rendered cmd + --allow-non-git (rc $rc)" '[ "$rc" = 0 ]'
rc=$(run_gate "$D" "$D" "$CMD && echo pwned" "$SB/s1.g4")
check "S1 gate blocks tampered cmd (rc $rc)" '[ "$rc" = 2 ]'
rc=$(run_gate "$D" "$D" "$CMD --verbose" "$SB/s1.g5")
check "S1 gate blocks extra token (rc $rc)" '[ "$rc" = 2 ]'
rc=$(run_gate "$D" "$D" "echo hi" "$SB/s1.g6")
check "S1 gate blocks unrelated cmd when not bootstrapped (rc $rc)" '[ "$rc" = 2 ]'
(cd "$D" && bash -c "$CMD") >"$SB/s1.x1" 2>&1; rc=$?
check "S1 literal exec refused in non-git (rc 3, got $rc)" '[ "$rc" = 3 ]'
check "S1 refusal names git init" 'grep -q "git init" "$SB/s1.x1"'
check "S1 nothing created by refusal" '[ ! -d "$D/trail" ] && [ ! -f "$D/.rein/project.json" ]'
mkdir -p "$D/.claude/cache"; printf 'non-git-dir\n' >"$(marker "$D")"
git -C "$D" init -q
(cd "$D" && bash -c "$CMD") >"$SB/s1.x2" 2>&1; rc=$?
check "S1 literal exec after git init ok (rc $rc)" '[ "$rc" = 0 ]'
check "S1 trail/ + marker created" '[ -f "$D/trail/index.md" ] && [ -f "$D/.rein/project.json" ]'
check "S1 degraded marker cleared by script" '[ ! -f "$(marker "$D")" ]'
rc=$(run_gate "$D" "$D" "echo hi" "$SB/s1.g7")
check "S1 gate silent after bootstrap (rc $rc)" '[ "$rc" = 0 ] && [ ! -s "$SB/s1.g7.err" ]'
rc=$(run_ups "$D" "$D" "$SB/s1.ups2")
check "S1 advisory has no bootstrap/git guidance after bootstrap" '! grep -q -i "rein-bootstrap-project.py\|git init\|still off\|꺼져\|PARTIAL\|부분 완료" "$SB/s1.ups2"'

echo "== S2a: mixed — PWD=git A, envelope=non-git B =="
A="$SB/repoA"; B="$SB/plain B"; mkdir -p "$A" "$B"; git -C "$A" init -q
rc=$(run_ss "$B" "$A" "$SB/s2a.ss")
check "S2a A NOT auto-bootstrapped" '[ ! -d "$A/trail" ] && [ ! -d "$A/.rein" ]'
check "S2a no marker under A" '[ ! -f "$(marker "$A")" ]'
check "S2a marker non-git-dir under B" '[ "$(head -n1 "$(marker "$B")" 2>/dev/null)" = non-git-dir ]'
check "S2a guidance names B" 'grep -q "plain B" "$SB/s2a.ss"'
check "S2a guidance does not name A as target" '! grep -q -- "--project-dir .*repoA" "$SB/s2a.ss"'
rc=$(run_ups "$B" "$A" "$SB/s2a.ups")
check "S2a advisory = reminder keyed on B" 'grep -q -i "still off\|꺼져" "$SB/s2a.ups"'
rc=$(run_gate "$B" "$A" "echo hi" "$SB/s2a.g1")
check "S2a gate passes through (degraded keyed on B) (rc $rc)" '[ "$rc" = 0 ]'

echo "== S2b: mixed reverse — PWD=non-git B2, envelope=git A2 =="
A2="$SB/repoA2"; B2="$SB/plain B2"; mkdir -p "$A2" "$B2"; git -C "$A2" init -q
rc=$(run_ss "$A2" "$B2" "$SB/s2b.ss")
check "S2b A2 auto-bootstrapped" '[ -f "$A2/trail/index.md" ] && [ -f "$A2/.rein/project.json" ]'
check "S2b no marker under A2 or B2" '[ ! -f "$(marker "$A2")" ] && [ ! -f "$(marker "$B2")" ]'
check "S2b B2 untouched" '[ ! -d "$B2/trail" ] && [ ! -d "$B2/.claude" ]'

echo "== S3: single-quote path =="
Q="$SB/it's here"; mkdir -p "$Q"
rc=$(run_ss "$Q" "$Q" "$SB/s3.ss")
CMDQ=$(extract_cmd "$SB/s3.ss")
echo "  rendered: $CMDQ"
check "S3 rendered command found" '[ -n "$CMDQ" ]'
rm -f "$(marker "$Q")"
rc=$(run_gate "$Q" "$Q" "$CMDQ" "$SB/s3.g1")
check "S3 gate passes exact rendered cmd (no marker) (rc $rc)" '[ "$rc" = 0 ]'
OTHER="$SB/other's"; mkdir -p "$OTHER"
rc=$(run_gate "$OTHER" "$OTHER" "$CMDQ" "$SB/s3.g2")
check "S3 gate blocks rendered cmd when confirmed path differs (rc $rc)" '[ "$rc" = 2 ]'
(cd "$Q" && git init -q && bash -c "$CMDQ") >"$SB/s3.x" 2>&1; rc=$?
check "S3 literal exec ok after git init (rc $rc)" '[ "$rc" = 0 ] && [ -f "$Q/.rein/project.json" ]'

echo "== summary: pass=$PASS fail=$FAIL =="
[ "$FAIL" = 0 ]
