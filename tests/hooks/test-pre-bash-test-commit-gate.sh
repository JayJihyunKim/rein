#!/bin/bash
# tests/hooks/test-pre-bash-test-commit-gate.sh
#
# HK-2 (docs/specs/2026-05-19-cc-feature-adoption.md §HK-2): the former single Bash guard
# was split into pre-bash-safety-guard.sh (always-on) + pre-bash-test-commit-
# gate.sh (if-gated). This suite verifies the TEST/COMMIT half enforces exactly
# its allocated block points.
#
# Spec block-point allocation for pre-bash-test-commit-gate.sh:
#   [P2]  coverage matrix mismatch
#   [P3]  review pending, no stamp
#   [P4]  code edited after review
#   [P5]  codex review stamp missing
#   [P6]  security review stamp missing
#   [P7]  commit message format
#   [I3]  coverage marker target unidentifiable (pairs with P2)
#   [I4]  commit-msg helper absent              (pairs with P7)
#   [I5]  commit-msg helper exec failure         (pairs with P7)
#   [I1]  python3 resolver failure   (common — lib/bash-guard-infra.sh)
#   [I2]  hook JSON parse failure    (common — lib/bash-guard-infra.sh)
#   [I6]  JSON deny emitter corrupt  (common — lib/bash-guard-infra.sh)
# GUARD-1: test *execution* (pytest etc.) is NOT stamp-gated — only commit is.
#
# Sandbox: test-harness.sh copies pre-bash-test-commit-gate.sh + the whole lib/
# (incl. bash-guard-infra.sh + extract-commit-msg.py + json-deny-emitter.sh).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-test-commit-gate.sh"

assert_json_deny() {
  local reason_code="$1"
  local msg="$2"
  assert_exit 0 "$msg: JSON deny path exits 0"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecision"])
' 2>/dev/null)
  [ "$decision" = "deny" ] \
    || fail "$msg: permissionDecision not \"deny\" (got: '$decision', stdout: $HOOK_STDOUT)"
  local pdr
  pdr=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(data["hookSpecificOutput"]["permissionDecisionReason"])
' 2>/dev/null)
  case "$pdr" in
    *"$reason_code"*) ;;
    *) fail "$msg: reason_code '$reason_code' not found in permissionDecisionReason: '$pdr'" ;;
  esac
}

assert_pass() {
  assert_exit 0 "$1: should pass"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no JSON deny, got stdout: $HOOK_STDOUT"
}

# Seed a DoD so the stamp gate is active, plus both review stamps so the
# *only* failing gate in a test is the one under test.
_seed_dod_only() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
}
_seed_dod_and_stamps() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  # M2/M3 (spec 2026-06-16): an empty `touch` stamp is now fail-closed. The
  # shared helper writes content-rich stamps that PASS the new contract (code
  # stamp verdict: PASS + fresh; security stamp fresher + same cycle + PASS) so
  # each downstream test exercises ONLY the gate it perturbs.
  _write_code_stamp     "2026-06-16T01:00:00Z" "2026-05-19-tc-gate-test" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "2026-05-19-tc-gate-test" "PASS"
}

# ============================================================
# M2/M3 (docs/specs/2026-06-16-review-stamp-freshness.md) — review stamp
# freshness + content binding. The commit gate now (M2) compares the security
# stamp's reviewed=/cycle=/verdict= against the code stamp's reviewed_at:/cycle:
# and (M3) reads the code stamp's PASS verdict via dual-read.
#
# Stamp schema divergence (spec §2.3): the security stamp uses `=` separators
# (reviewed=/cycle=/verdict=); the code stamp uses `: ` separators
# (reviewed_at:/cycle:/verdict:). Each is parsed by its own schema.
# ============================================================

# Write a content-rich code stamp (.codex-reviewed, `: ` separator).
# Args: $1=reviewed_at (ISO or "skip"), $2=cycle (or "skip"),
#       $3=verdict (or "skip"), $4=resolution legacy field (or "skip"),
#       $5=legacy timestamp (or "skip")
_write_code_stamp() {
  local rat="$1" cyc="$2" ver="$3" res="$4" ts="$5"
  local f="$SANDBOX/trail/dod/.codex-reviewed"
  : > "$f"
  [ "$rat" != "skip" ] && printf 'reviewed_at: %s\n' "$rat" >> "$f"
  [ "$ts"  != "skip" ] && printf 'timestamp: %s\n' "$ts" >> "$f"
  printf 'reviewer: codex\n' >> "$f"
  printf 'diff_base: N/A\n' >> "$f"
  [ "$ver" != "skip" ] && printf 'verdict: %s\n' "$ver" >> "$f"
  [ "$res" != "skip" ] && printf 'resolution: %s\n' "$res" >> "$f"
  [ "$cyc" != "skip" ] && printf 'cycle: %s\n' "$cyc" >> "$f"
  printf 'scope: wrapper-generated\n' >> "$f"
}

# Write a content-rich security stamp (.security-reviewed, `=` separator).
# Args: $1=reviewed (ISO or "skip"), $2=cycle (or "skip"), $3=verdict (or "skip")
_write_security_stamp() {
  local rev="$1" cyc="$2" ver="$3"
  local f="$SANDBOX/trail/dod/.security-reviewed"
  : > "$f"
  printf 'reviewer=security-reviewer\n' >> "$f"
  [ "$rev" != "skip" ] && printf 'reviewed=%s\n' "$rev" >> "$f"
  printf 'security_level=standard\n' >> "$f"
  [ "$cyc" != "skip" ] && printf 'cycle=%s\n' "$cyc" >> "$f"
  [ "$ver" != "skip" ] && printf 'verdict=%s\n' "$ver" >> "$f"
  printf 'mechanism=llm-security-review\n' >> "$f"
}

# Seed a standard (non-light) DoD + both content-rich stamps where the code
# stamp is PASS and the security stamp is fresh + same cycle + PASS, so the
# *only* gate that can fire is the one a test deliberately perturbs.
_seed_dod_and_rich_stamps() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "2026-05-19-tc-gate-test" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "2026-05-19-tc-gate-test" "PASS"
}

# ------------------------------------------------------------
# Task 1.1 — parser + ISO normalization, exercised BEHAVIORALLY through the gate.
#
# (codex integration-review R1 Medium) The earlier direct-source unit tests were
# false-green: sourcing the hook recomputes SCRIPT_DIR from $0, so the lib loads
# fail and the hook exits before the helpers are defined — the assertions ran
# against a stale HOOK_EXIT and passed without testing anything. The helper
# contracts are instead verified through the full `git commit` gate, which is the
# path that actually consumes them (rein prefers behavioral hook tests):
#   - trailing-Z unification: security `...Z` vs code `...` (no Z), same instant
#     + same cycle + PASS → commit passes (proves the two formats normalize equal)
#   - non-ISO fail-closed: a garbled security `reviewed=` → block (sentinel never
#     yields a comparable value that could pass freshness)
#   - missing field fail-closed: a security stamp without `verdict=` → block
# ------------------------------------------------------------

test_t11_normalize_z_mixed_compares_equal() {
  # security reviewed= carries trailing Z, code reviewed_at= does not; same
  # instant + same cycle + PASS. If normalize unifies Z, security>=code holds → pass.
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T02:00:00"  "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "T1.1 normalize unifies trailing Z (mixed Z/no-Z equal instant → pass)"
}

test_t11_non_iso_security_ts_fails_closed() {
  # Garbled security reviewed= (non-ISO) must fail-closed (block), never compare
  # as fresh. Standard-tier DoD so P6 is active.
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'reviewed=not-a-timestamp\ncycle=tc-cycle\nverdict=PASS\n' \
    > "$SANDBOX/trail/dod/.security-reviewed"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "T1.1 non-ISO security timestamp → fail-closed (STALE)"
}

test_t11_missing_verdict_field_fails_closed() {
  # security stamp without verdict= → parser returns empty → fail-closed (block).
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'reviewed=2026-06-16T02:00:00Z\ncycle=tc-cycle\n' \
    > "$SANDBOX/trail/dod/.security-reviewed"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "T1.1 missing verdict= in security stamp → fail-closed (STALE)"
}

# ------------------------------------------------------------
# Task 1.2 — M2 security stamp freshness + cycle + verdict (P6 area).
# Driven through the gate via `git commit` (standard-tier DoD → P6 active).
# ------------------------------------------------------------

# (M2-1) security < code (cycle matches) → SECURITY_REVIEW_STALE.
test_m2_security_older_than_code_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T05:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T01:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "M2 security older than code → SECURITY_REVIEW_STALE"
}

# (M2-2) security >= code, cycle matches non-empty, verdict=PASS → pass.
test_m2_security_fresh_same_cycle_pass_passes() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "M2 security fresh + same cycle + verdict=PASS → commit passes"
}

# (M2-3) security >= code but cycle mismatch → SECURITY_REVIEW_STALE.
test_m2_cycle_mismatch_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "OTHER-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "M2 cycle mismatch → SECURITY_REVIEW_STALE"
}

# (M2-4) both cycles empty → SECURITY_REVIEW_STALE (empty cycle is fail-closed).
test_m2_both_cycles_empty_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "skip" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "skip" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "M2 both cycles empty → SECURITY_REVIEW_STALE (no oops-equal pass)"
}

# (M2-5) security verdict=NEEDS-FIX though fresh + same cycle → NOT_PASSED.
test_m2_security_verdict_not_pass_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "NEEDS-FIX"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_NOT_PASSED" "M2 security verdict=NEEDS-FIX → SECURITY_REVIEW_NOT_PASSED"
}

# (M2-6) empty (touch'd) security stamp, standard-tier (not exempt) → fail-closed.
test_m2_empty_security_stamp_fails_closed() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  touch "$SANDBOX/trail/dod/.security-reviewed"   # empty / touch-only
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  # exit 0 + deny; reason is STALE (unparseable security reviewed → stale).
  assert_exit 0 "M2 empty security stamp → JSON deny path exits 0"
  printf '%s' "$HOOK_STDOUT" | grep -q '"permissionDecision"' \
    || fail "M2 empty security stamp must emit JSON deny (fail-closed), got: $HOOK_STDOUT"
}

# (M2-7) security reviewed not ISO (fresh-looking junk) → fail-closed STALE.
test_m2_security_reviewed_non_iso_fails_closed() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "garbage-not-iso" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "M2 non-ISO security reviewed → fail-closed SECURITY_REVIEW_STALE"
}

# ------------------------------------------------------------
# Task 1.5 — M3 code stamp PASS dual-read (P5 area).
# verdict: preferred, else legacy resolution:. Time must parse via
# reviewed_at: (new) or legacy timestamp: (old).
# ------------------------------------------------------------

# (M3-1) verdict: PASS → pass.
test_m3_verdict_pass_passes() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "M3 verdict: PASS → commit passes"
}

# (M3-2) verdict: NEEDS-FIX → CODE_REVIEW_NOT_PASSED.
test_m3_verdict_needs_fix_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "NEEDS-FIX" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODE_REVIEW_NOT_PASSED" "M3 verdict: NEEDS-FIX → CODE_REVIEW_NOT_PASSED"
}

# (M3-3) resolution: escalated_to_human (no verdict) → blocked (escalation格上).
test_m3_escalated_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "skip" "escalated_to_human" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODE_REVIEW_NOT_PASSED" "M3 resolution: escalated_to_human → blocked (escalated upgraded to block)"
}

# (M3-4) legacy resolution: passed (no verdict) → pass.
test_m3_legacy_resolution_passed_passes() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  # No verdict:, only legacy resolution: passed + legacy timestamp:.
  _write_code_stamp     "skip" "tc-cycle" "skip" "passed" "2026-06-16T01:00:00Z"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "M3 legacy resolution: passed (verdict absent) → commit passes"
}

# (M3-5) neither verdict: nor resolution: → fail-closed.
test_m3_no_verdict_field_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T01:00:00Z" "tc-cycle" "skip" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODE_REVIEW_NOT_PASSED" "M3 no verdict:/resolution: field → fail-closed block"
}

# (M3-6) both time fields unparseable (verdict PASS) → fail-closed.
test_m3_time_unparseable_blocks() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  # verdict PASS but no reviewed_at: and no timestamp: → time parse impossible.
  _write_code_stamp     "skip" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T02:00:00Z" "tc-cycle" "PASS"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODE_REVIEW_NOT_PASSED" "M3 no parseable time field → fail-closed block"
}

# ------------------------------------------------------------
# Task 1.4 — security-reviewer.md instruction must be content-rich.
# Doc verification: the standalone `touch trail/dod/.security-reviewed`
# instruction must be GONE and the standard 3-field schema must be present.
# ------------------------------------------------------------
test_t14_security_reviewer_doc_is_content_rich() {
  local doc="$REAL_PROJECT_DIR/plugins/rein-core/agents/security-reviewer.md"
  [ -f "$doc" ] || { fail "T1.4 security-reviewer.md not found at $doc"; return; }
  # No standalone `touch trail/dod/.security-reviewed` line (the bare touch
  # instruction is what M2 cannot parse).
  if grep -Eq '^[[:space:]]*touch[[:space:]]+trail/dod/\.security-reviewed[[:space:]]*$' "$doc"; then
    fail "T1.4 standalone 'touch trail/dod/.security-reviewed' must be removed"
  fi
  # Standard 3 fields present (= separator).
  grep -q 'reviewed=' "$doc" || fail "T1.4 doc must specify reviewed= field"
  grep -q 'cycle='    "$doc" || fail "T1.4 doc must specify cycle= field"
  grep -q 'verdict=PASS' "$doc" || fail "T1.4 doc must specify verdict=PASS field"
}

# ============================================================
# [P5] codex review stamp missing — git commit, DoD present, no stamps.
# ============================================================
test_p5_codex_stamp_missing_blocks() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "P5 git commit without codex stamp should emit JSON deny"
}

# ============================================================
# [P6] security review stamp missing — codex stamp present, security missing.
# ============================================================
test_p6_security_stamp_missing_blocks() {
  _seed_dod_only
  # M3: code stamp must be a content-rich PASS so the gate reaches P6 (not P5b).
  _write_code_stamp "2026-06-16T01:00:00Z" "2026-05-19-tc-gate-test" "PASS" "skip" "skip"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "P6 git commit without security stamp should emit JSON deny"
}

# ============================================================
# [P3] review pending, no stamp — .review-pending present, no codex stamp.
# ============================================================
test_p3_review_pending_no_stamp_blocks() {
  _seed_dod_only
  touch "$SANDBOX/trail/dod/.review-pending"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "REVIEW_PENDING_NO_STAMP" "P3 .review-pending without stamp should emit JSON deny"
}

# ============================================================
# [P4] code edited after review — .codex-reviewed older than .review-pending.
# ============================================================
test_p4_code_edited_after_review_blocks() {
  _seed_dod_only
  # codex stamp older than review-pending → stale review.
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch -t "203001010000" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null \
    || touch -d "2030-01-01" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null
  # NOTE: we make the stamp OLD (1970-ish) and pending NEW instead.
  touch -t "197001020000" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null \
    || touch -d "1970-01-02" "$SANDBOX/trail/dod/.codex-reviewed" 2>/dev/null
  touch "$SANDBOX/trail/dod/.review-pending"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODE_EDITED_AFTER_REVIEW" "P4 code edited after review should emit JSON deny"
}

# ============================================================
# [P7] commit message format — stamps present, bad-format message.
# ============================================================
test_p7_commit_msg_format_blocks() {
  _seed_dod_and_stamps
  local input='{"tool_input":{"command":"git commit -m \"bad message without type\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "COMMIT_MSG_FORMAT" "P7 bad commit message format should emit JSON deny"
}

# ============================================================
# GMF-1 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.1): canonical
# "git commit" recognition inside the gate. The old literal `command_invokes
# "git commit"` missed multi-space + git global-option forms, so the inner
# stamp/format checks were skipped on them. These verify the canonical model
# now drives those forms into the P5 stamp check (DoD present, no stamps).
# ============================================================

# RED → GREEN: git -C . commit must enter the stamp check.
test_gmf1_git_dash_C_commit_enters_stamp_check() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git -C . commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "git -C . commit must enter the codex stamp check"
}

# RED → GREEN: double-space between git and commit.
test_gmf1_git_double_space_commit_enters_stamp_check() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git  commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "git  commit (double space) must enter the codex stamp check"
}

# RED → GREEN: git -c <kv> commit.
test_gmf1_git_dash_c_kv_commit_enters_stamp_check() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git -c user.name=x commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "git -c user.name=x commit must enter the codex stamp check"
}

# RED → GREEN: git --git-dir=.git commit.
test_gmf1_git_gitdir_commit_enters_stamp_check() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git --git-dir=.git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "git --git-dir=.git commit must enter the codex stamp check"
}

# GREEN (over-match 0): git commit-graph write is a different subcommand —
# stamps absent, but it must NOT be gated (passes, no JSON deny).
test_gmf1_git_commit_graph_not_gated() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git commit-graph write"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "git commit-graph write must NOT enter the commit gate (shell-token boundary)"
}

# GREEN (over-match 0): git config commit.gpgsign — commit is config's arg.
test_gmf1_git_config_commit_arg_not_gated() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git config commit.gpgsign true"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "git config commit.gpgsign must NOT enter the commit gate"
}

# GREEN (over-match 0): allowlist-outside option is conservative non-match.
test_gmf1_git_bogus_option_commit_not_gated() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git --bogus commit"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "git --bogus commit (allowlist-outside) must NOT enter the commit gate"
}

# GMF-1 / Task 1.6 (codex R2 HIGH): the gate hard-fails (exit 2) when the
# canonical git-subcommand-model lib is missing — a missing/empty ERE must not
# reach command_invokes (which would make the matcher untrustworthy / leak).
test_gmf1_missing_git_model_lib_fails_closed() {
  _seed_dod_and_stamps
  rm -f "$SANDBOX/.claude/hooks/lib/git-subcommand-model.sh"
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "missing git-subcommand-model lib should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# GMF-2 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.2): merge/rebase/am
# exemption precision. The old `echo "$COMMAND" | grep -qE "git (merge|rebase|
# am)"` was an unanchored substring match, so a *normal* commit whose MESSAGE
# embedded the literal `git merge`/`git rebase`/`git am` string was wrongly
# exempted (whole commit skipped all stamp/coverage/format checks = false-
# negative). The fix consumes GMF-1's canonical $GIT_MERGE_ERE via
# command_invokes (clause-start anchored) so only a real merge/rebase/am
# subcommand is exempted; a literal mention inside `-m "..."` is not.
# ============================================================

# RED → GREEN: a normal commit whose message contains the literal "git merge"
# substring must NOT be exempted — it must enter the stamp check (DoD present,
# no stamps → P5).
test_gmf2_commit_msg_literal_git_merge_not_exempted() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git commit -m \"fix: document git merge behavior\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "commit with literal 'git merge' in message must NOT be exempted (enters stamp check)"
}

# RED → GREEN: same for a literal "git rebase" substring in the message.
test_gmf2_commit_msg_literal_git_rebase_not_exempted() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git commit -m \"chore: simplify git rebase docs\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "commit with literal 'git rebase' in message must NOT be exempted (enters stamp check)"
}

# GREEN (exemption preserved): a real merge is exempted from all gates even
# without stamps (auto-generated message, no edit→review flow). DoD present +
# no stamps would otherwise P5-block a commit; a real merge must pass.
test_gmf2_real_merge_still_exempted() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git merge --no-ff feature/x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "real git merge --no-ff must remain exempted (no new block)"
}

# GREEN (exemption preserved): real rebase.
test_gmf2_real_rebase_still_exempted() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git rebase main"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "real git rebase must remain exempted"
}

# GREEN (exemption preserved): real am.
test_gmf2_real_am_still_exempted() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git am < patch"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "real git am must remain exempted"
}

# GREEN (exemption preserved): merge with a leading global option — global
# option skip then first subcommand = merge → exempted.
test_gmf2_git_dash_C_merge_still_exempted() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git -C . merge feature/x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "git -C . merge (global-option skip) must remain exempted"
}

# GREEN (behavior unchanged): a commit message with the bare word "merge"
# (no literal "git merge") was never exempted by the old grep and must still
# enter the stamp check after the fix.
test_gmf2_commit_msg_bare_merge_word_enters_gate() {
  _seed_dod_only
  local input='{"tool_input":{"command":"git commit -m \"fix: resolve merge conflict\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "commit with bare word 'merge' in message must enter the stamp check (unchanged)"
}

# Negative: a well-formed commit with stamps + no markers passes.
test_good_commit_passes() {
  _seed_dod_and_stamps
  local input='{"tool_input":{"command":"git commit -m \"feat: well formed\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "well-formed git commit with stamps should pass"
}

# ============================================================
# GMF-4 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4): policy-toggle
# fail-open seal. The old top-of-file block hard-coded `python3` and did
# `if ! python3 <loader>; then exit 0`. When python3 is absent (127) or a
# Windows stub (49), `! <nonzero>` is true → the gate fell to exit 0 (OFF),
# mistaking interpreter-absence for a user policy disable. The fix moves the
# policy check AFTER the resolver (bg_resolve_python_or_die already exit-2s on
# interpreter absence) and calls the loader via "${PYTHON_RUNNER[@]}",
# distinguishing loader rc==1 (user disable → exit 0) from rc∉{0,1} / absence
# (fail-closed → gate active).
#
# These run the hook in a manual subshell (like the I1 tests) so we can export
# CLAUDE_PLUGIN_ROOT + curate PATH. _seed_policy_loader drops a loader script
# into $SANDBOX/.claude/scripts/ (CLAUDE_PLUGIN_ROOT=$SANDBOX/.claude).
# ============================================================

# _seed_policy_loader RC — write a stub rein-policy-loader.py that exits RC.
# (Deterministic: isolates the gate's rc-handling contract from the real
# loader's yaml parsing, which is out of GMF-4's scope.)
_seed_policy_loader() {
  local rc="$1"
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<PY
import sys
sys.exit($rc)
PY
}

# _run_hook_plugin_env [extra-setup] — run HOOK with CLAUDE_PLUGIN_ROOT set,
# under a missing-python PATH if MISSING_PY=1, else the real PATH. Captures
# exit into HOOK_EXIT and combined output into HOOK_STDERR (stdout+stderr).
_run_hook_missing_python() {
  local stdin_json="$1"
  local out rc
  out=$(
    with_missing_python
    printf '%s' "$stdin_json" \
      | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
        REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$HOOK" 2>&1
    printf '_RC=%s\n' "$?"
    cleanup_fakes
  )
  HOOK_EXIT=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)
  HOOK_STDERR=$(printf '%s' "$out" | grep -v '^_RC=' || true)
}

_run_hook_real_python() {
  local stdin_json="$1"
  local tmp_out tmp_err
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  printf '%s' "$stdin_json" \
    | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/$HOOK" >"$tmp_out" 2>"$tmp_err"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_out")
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"
}

# RED → GREEN: python3 absent + CLAUDE_PLUGIN_ROOT set + loader present must
# NOT drop to exit 0 (OFF). The resolver fail-closes (exit 2); the stamp-less
# commit stays gated. Current code: `! python3` (127) → exit 0 → red.
test_gmf4_python_absent_does_not_disable_gate() {
  _seed_dod_only
  _seed_policy_loader 0   # loader would say "enabled", but python is absent
  _run_hook_missing_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" != "0" ] \
    || fail "GMF-4 python absent must NOT disable the gate (got exit 0 = fail-open)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 python absent should fail closed via resolver (expected exit 2, got: $HOOK_EXIT)"
}

# GREEN: python3 present + policy DISABLE (loader rc 1) → gate OFF (exit 0).
test_gmf4_policy_disable_exits_zero() {
  _seed_dod_only          # stamps absent → would P5-block if the gate ran
  _seed_policy_loader 1   # loader says "disabled"
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "0" ] \
    || fail "GMF-4 policy disable (loader rc1) should exit 0 (got: $HOOK_EXIT; stderr: $HOOK_STDERR)"
  [ -z "$HOOK_STDOUT" ] \
    || fail "GMF-4 policy disable should emit no JSON deny (stdout: $HOOK_STDOUT)"
}

# GREEN: python3 present + policy ENABLE (loader rc 0) → gate body runs. With a
# DoD + no stamps, the body P5-blocks (JSON deny) — proving the gate entered.
test_gmf4_policy_enable_enters_body() {
  _seed_dod_only
  _seed_policy_loader 0   # loader says "enabled"
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  assert_json_deny "CODEX_STAMP_MISSING" "GMF-4 policy enable should enter the gate body (P5 stamp check)"
}

# GREEN: loader CRASH (rc∉{0,1}, e.g. rc 3) with python present → fail-closed,
# gate active (must not mistake a loader crash for a user disable).
test_gmf4_loader_crash_fails_closed() {
  _seed_dod_only
  _seed_policy_loader 3   # loader crashed
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" != "0" ] || {
    # exit 0 ONLY acceptable if it is a JSON deny (gate entered + blocked).
    printf '%s' "$HOOK_STDOUT" | grep -q '"permissionDecision"' \
      || fail "GMF-4 loader crash (rc3) must not disable the gate (got bare exit 0)"
  }
  assert_json_deny "CODEX_STAMP_MISSING" "GMF-4 loader crash should fall through to the gate body (P5)"
}

# ============================================================
# [P2] coverage matrix mismatch — non-empty marker, identifiable FAIL target.
# Uses a stub validator that always FAILs so revalidate rc=1 (P2 path).
# ============================================================
test_p2_coverage_mismatch_blocks() {
  _seed_dod_and_stamps
  # Stub validator: always exit 1 (FAIL). resolve_helper_script (plugin-script-
  # path.sh) resolves rein-validate-coverage-matrix.py from scripts/.
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
import sys
sys.exit(1)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  # Non-empty .coverage-mismatch with an existing plan file path.
  mkdir -p "$SANDBOX/docs/plans"
  echo "# plan" > "$SANDBOX/docs/plans/p.md"
  echo "$SANDBOX/docs/plans/p.md" > "$SANDBOX/trail/dod/.coverage-mismatch"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "COVERAGE_MISMATCH" "P2 coverage validator FAIL should emit JSON deny"
}

# ============================================================
# [I3] coverage marker target unidentifiable — empty marker → exit 2.
# ============================================================
test_i3_coverage_marker_unidentifiable_fails_closed() {
  _seed_dod_and_stamps
  touch "$SANDBOX/trail/dod/.coverage-mismatch"   # empty → rc=2 → I3
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I3 empty coverage marker should fail closed (exit 2)"
  assert_stderr_contains ".coverage-mismatch"
}

# ============================================================
# [I4] commit-msg helper absent — remove extract-commit-msg.py → exit 2.
# ============================================================
test_i4_commit_msg_helper_absent_fails_closed() {
  _seed_dod_and_stamps
  rm -f "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py"
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I4 missing commit-msg helper should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# [I5] commit-msg helper exec failure — replace helper with one that errors.
# ============================================================
test_i5_commit_msg_helper_exec_failure_fails_closed() {
  _seed_dod_and_stamps
  cat > "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py" <<'PY'
import sys
sys.exit(3)
PY
  local input='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I5 commit-msg helper exec failure should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# GUARD-1: test *execution* is NOT stamp-gated — pytest with a DoD and NO
# stamps must pass (only `git commit` is the hard gate).
# ============================================================
test_guard1_pytest_not_blocked_without_stamps() {
  _seed_dod_only
  local input='{"tool_input":{"command":"pytest tests/"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "GUARD-1 pytest without stamps should NOT be blocked"
}

# ============================================================
# [I1] python3 resolver failure (common infra — fail-closed exit 2).
# ============================================================
test_i1_python_resolver_failure_fails_closed() {
  local stdin_json='{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  local out rc
  out=$(
    with_empty_path
    with_fake_uname 'MINGW64_NT-10.0-22000'
    with_fake_python 49
    printf '%s' "$stdin_json" \
      | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$HOOK" 2>&1
    printf '_RC=%s\n' "$?"
    cleanup_fakes
  )
  rc=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)
  [ "$rc" = "2" ] \
    || fail "I1 expected exit 2, got rc='$rc' (out: $(printf '%s' "$out" | head -3 | tr '\n' ' '))"
  printf '%s' "$out" | grep -qF "[rein]" \
    || fail "I1 stderr missing '[rein]' prefix"
}

# ============================================================
# [I2] hook input JSON parse failure (common infra — exit 2).
# ============================================================
test_i2_json_parse_failure_fails_closed() {
  # Raw non-JSON byte string that extract-hook-json.py's json.loads rejects
  # (exit 20) — same payload test-exit2-stderr-tone.sh Suite F uses.
  local malformed='NOT_VALID_JSON { broken:'
  run_hook "$HOOK" "$malformed"
  assert_exit 2 "I2 malformed hook JSON should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# [I6] JSON deny emitter corrupt (common infra — exit 2).
# ============================================================
test_i6_emitter_unavailable_fails_closed() {
  rm -f "$SANDBOX/.claude/hooks/lib/json-deny-emitter.sh"
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_exit 2 "I6 missing emitter should fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# ============================================================
# SX-* (docs/specs/2026-06-16-commit-gate-security-surface-exempt.md)
# 보안-surface 면제 — 단독 `git commit`(staging 동반 없음 + allowlist 옵션만)
# 이고 staged diff 가 전부 허용목록(문서/trail/버전 문자열-only)이면 P6+M2 를
# 둘 다 skip. 그 외 전부 fail-closed(M2 구멍 재개방 금지).
#
# 면제 케이스는 PROJECT_DIR(=SANDBOX)가 실제 git repo 여야 한다 — gate 본문이
# `git -C "$PROJECT_DIR" diff --cached` / `git show HEAD:...` 를 호출하기 때문.
# 각 테스트는 sandbox 에 git init + baseline 커밋을 먼저 만들고(HEAD 존재 →
# plugin.json semantic 비교 가능) 그 위에 변경을 staging 한다.
# ============================================================

# _sx_git_init_baseline — sandbox 에 git repo + baseline 커밋 생성.
# baseline 에는 scripts/rein.sh(VERSION="1.5.5") + plugin.json + docs 를 둔다.
_sx_git_init_baseline() {
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/plugins/rein-core/.claude-plugin" "$SANDBOX/docs/specs"
  printf 'VERSION="1.5.5"\n' > "$SANDBOX/scripts/rein.sh"
  printf '{\n  "name": "rein",\n  "version": "1.5.5",\n  "description": "x"\n}\n' \
    > "$SANDBOX/plugins/rein-core/.claude-plugin/plugin.json"
  printf '# changelog\n' > "$SANDBOX/CHANGELOG.md"
  printf '# readme\n' > "$SANDBOX/README.md"
  printf '# spec\n' > "$SANDBOX/docs/specs/x.md"
  printf 'print("hi")\n' > "$SANDBOX/src_foo.py"
  printf '# hook\n' > "$SANDBOX/hookfile.sh"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit -q -m "baseline"
}

# _sx_seed_standard_dod_no_security — standard(비light) DoD + content-rich PASS
# 코드 표식만(보안 표식 부재). 면제 미성립이면 P6 부재 차단이 정상 동작.
_sx_seed_standard_dod_no_security() {
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp "2026-06-16T01:00:00Z" "2026-05-19-tc-gate-test" "PASS" "skip" "skip"
}

# (SX form / TOCTOU) `git add . && git commit` 한 줄 → 면제 미시도(staging 동반).
test_sx_add_and_commit_one_line_toctou_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"   # docs change (unstaged)
  local input='{"tool_input":{"command":"git add . && git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX add&&commit one-line (TOCTOU) → fail-closed (security required)"
}

# (SX form / TOCTOU) `git reset && git commit` → 면제 미시도.
test_sx_reset_and_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git reset && git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX reset&&commit → fail-closed (security required)"
}

# (SX form) 단독 `git commit -m` + 사전 staged docs-only + 보안표식 부재 → 통과.
test_sx_lone_commit_docs_only_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"chore: docs\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX lone commit, staged docs-only → exempt (passes without security stamp)"
}

# (SX form) -a / --amend / pathspec / 분리 keyid 자리 pathspec / 미상 옵션 → 미시도.
test_sx_commit_dash_a_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -a -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit -a → fail-closed"
}

test_sx_commit_am_combined_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -am \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit -am (combined) → fail-closed"
}

test_sx_commit_amend_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit --amend -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit --amend → fail-closed"
}

test_sx_commit_pathspec_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"chore: x\" CHANGELOG.md"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit <pathspec> → fail-closed (trailing pathspec)"
}

# (SX form) -S 뒤 분리 토큰은 keyid 로 소비 금지 → pathspec/소스 재검사로 fail.
test_sx_commit_dash_S_separate_pathspec_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -S src/x.py -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit -S <separate token> → token re-checked as pathspec → fail-closed"
}

test_sx_commit_unknown_option_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit --foo -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit --foo (unknown option) → fail-closed"
}

# (SX form) 글로벌 옵션(git -c x=y commit) → 면제 미시도 (글로벌옵션 완화 제거).
# HOLE FIX (codex integration review, 2026-06-16): a `-c`/`-C`/`--git-dir`/
# `--work-tree` global option between `git` and `commit` can redirect the
# committed repo/index away from the inspected index → fail-closed. Exemption
# is only `git` directly followed by `commit`. (Was: assert_pass.)
test_sx_commit_global_opt_only_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git -c user.name=x commit -m \"chore: docs\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git -c user.name=x commit (global opt) → fail-closed (relax removed)"
}

# (SX form) attached/등호/무인자 서명 + allowlist 옵션, staged docs-only → 통과.
test_sx_commit_signing_and_allowlist_opts_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -s -q -v -SABCDEF -m \"chore: docs\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX git commit -s -q -v -SABCDEF -m (attached keyid + allowlist) → exempt passes"
}

test_sx_commit_gpgsign_equals_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit --gpg-sign=KEY -m \"chore: docs\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX git commit --gpg-sign=KEY -m (equals keyid) → exempt passes"
}

# (SX form, codex R1 Med) 여러 단어 메시지(따옴표 보존) → 통과(pathspec 오인 금지).
test_sx_multiword_message_quoted_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"chore: release v1.5.6 with spaces\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX multi-word quoted message → exempt passes (spaces not mistaken for pathspec)"
}

# (SX form, codex R1 Med) 메시지 뒤 진짜 pathspec → 면제 미시도.
test_sx_message_then_real_pathspec_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"chore: msg\" CHANGELOG.md"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX message then real pathspec → fail-closed"
}

# ------------------------------------------------------------
# SX hole-fix (codex integration review, 2026-06-16): fail-open closures.
#   High — command substitution / subshell TOCTOU: `$(...)`/backtick/`<(...)`/
#     subshell `(...)` group can run `git add ...` (or anything) BEFORE the
#     gated `git commit`, staging source under a docs-only staged snapshot →
#     security-skipped commit. The earlier tokenizer kept `$(...)` inside the
#     `-m` message token and only counted clauses whose first token is exactly
#     `git`, so a glued `(git` subshell head went uncounted → wrongly exempt.
#   Med — effective repo/index mismatch: `-C`/`--git-dir`/`--work-tree`/`-c`
#     global options + `GIT_*` env prefixes (esp. GIT_INDEX_FILE) let the
#     committed index/repo differ from the `git -C "$PROJECT_DIR" diff --cached`
#     the gate inspects → exemption decided against the wrong index.
# Decision (fail-closed strengthen): exemption is attempted ONLY for a bare
# in-place single `git commit <allowlist-opts>` clause with NO shell evaluation
# (`$(`/backtick/`${...}`-as-command/`<(`/`>(`), NO subshell/group, NO env
# assignment prefix, and NO `git`→`commit` global option (repo/index redirect).
# Anything else → exemption not attempted (security required).
# RED (current code wrongly exempts) → GREEN (security required) after fix.
# ------------------------------------------------------------

# (SX hole — cmd-subst TOCTOU) `$(git add ...)` inside -m message → 면제 미시도.
test_sx_cmd_subst_in_message_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md   # staged snapshot = docs-only (would-be exempt)
  local input='{"tool_input":{"command":"git commit -m \"x $(git add src_foo.py)\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX \$(git add ...) in -m message (TOCTOU) → fail-closed (security required)"
}

# (SX hole — backtick TOCTOU) backtick `git add ...` inside -m message → 미시도.
test_sx_backtick_in_message_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"x `git add src_foo.py`\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX backtick \`git add ...\` in -m message (TOCTOU) → fail-closed"
}

# (SX hole — subshell group TOCTOU) `(git add ...); git commit` → 미시도.
test_sx_subshell_group_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"(git add src_foo.py); git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX subshell (git add ...); git commit (TOCTOU) → fail-closed"
}

# (SX hole — repo redirect) `git -C /other commit` → index 분리 가능 → 미시도.
test_sx_dash_C_other_repo_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git -C /other commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git -C /other commit (repo redirect) → fail-closed"
}

# (SX hole — repo redirect) `git --git-dir=/x --work-tree=/y commit` → 미시도.
test_sx_gitdir_worktree_redirect_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git --git-dir=/x --work-tree=/y commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git --git-dir/--work-tree commit (repo/index redirect) → fail-closed"
}

# (SX hole — env prefix) `GIT_INDEX_FILE=/tmp/x git commit` → index 분리 → 미시도.
test_sx_git_index_file_env_prefix_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"GIT_INDEX_FILE=/tmp/x git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX GIT_INDEX_FILE=... git commit (env index redirect) → fail-closed"
}

# (SX hole — config redirect) `git -c user.email=x commit` → 미시도(글로벌옵션 완화 제거).
test_sx_dash_c_config_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git -c user.email=x commit -m y"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git -c user.email=x commit (config redirect) → fail-closed (global-opt relax removed)"
}

# (SX hole — regression) 평범한 단독 `git commit -m "여러 단어"` (docs-only) → 여전히 통과.
test_sx_plain_lone_commit_multiword_still_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"chore: release v1.5.6 with several words\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX plain lone git commit (multi-word docs-only) → still exempt (no over-block)"
}

# ------------------------------------------------------------
# SX hole-fix R2 (codex integration review R2 High, 2026-06-16): non-git first
# clause skip. The earlier _sx_command_form_ok counted only clauses whose first
# token is exactly `git`; a clause whose first token is anything else (a shell
# builtin wrapper `command`, a `cd`, an `env`/`time`/`nice` wrapper, or any
# harmless command like `true`/`echo`) was SKIPPED — neither counted as a commit
# clause nor as an other-git clause. So `command git add s.py; git commit`,
# `cd /other && git commit`, `env git add s.py; git commit`, and even
# `true; git commit` all reduced to "exactly one commit clause, zero other-git
# clauses" and were wrongly exempted. The skipped clause runs at REAL shell
# execution time (staging source / committing in another repo) under a docs-only
# staged snapshot the gate inspected → security-skipped commit.
#
# 종착 규칙 (final rule): exemption requires the ENTIRE command to be exactly ONE
# non-empty clause, and that clause is a plain in-place `git commit <allowlist>`.
# Any second non-empty clause — whatever it is (cd/command/env/git add/true/echo)
# — → fail-closed. RED (current wrongly exempts) → GREEN (security required).
# ------------------------------------------------------------

# (SX hole R2 — command wrapper) `command git add s.py; git commit` → 면제 미시도.
test_sx_command_wrapper_then_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md   # staged snapshot = docs-only (would-be exempt)
  local input='{"tool_input":{"command":"command git add src_foo.py; git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX command git add ...; git commit (builtin wrapper) → fail-closed (security required)"
}

# (SX hole R2 — cd then commit) `cd /other && git commit` → repo decouple → 미시도.
test_sx_cd_other_then_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"cd /other && git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX cd /other && git commit (repo decouple) → fail-closed"
}

# (SX hole R2 — env wrapper) `env git add s.py; git commit` → 면제 미시도.
test_sx_env_wrapper_then_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"env git add src_foo.py; git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX env git add ...; git commit (env wrapper) → fail-closed"
}

# (SX hole R2 — harmless leading cmd) `true; git commit` → 2 clause → 면제 미시도.
test_sx_true_then_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"true; git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX true; git commit (harmless leading cmd, 2 clauses) → fail-closed"
}

# (SX hole R2 — harmless leading cmd) `echo hi && git commit` → 2 clause → 미시도.
test_sx_echo_then_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"echo hi && git commit -m x"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX echo hi && git commit (harmless leading cmd, 2 clauses) → fail-closed"
}

# (SX hole R2 — trailing harmless cmd) `git commit -m x; echo done` → 2 clause → 미시도.
test_sx_commit_then_trailing_cmd_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m x; echo done"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit -m x; echo done (trailing clause) → fail-closed"
}

# (SX hole R3 — background control) `git commit -m x &` → 백그라운드 실행은 평범한
# 전경 commit 이 아님. 후행 `&` 가 separator 라 "clause 1개 + 빈 후행 clause" 로
# 줄어 면제를 통과하던 fail-open (codex integration review R3 High). `&` 가 토큰에
# 하나라도 있으면 즉시 fail-closed 여야 한다. RED (이전 면제) → GREEN (보안 요구).
test_sx_background_commit_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md   # staged snapshot = docs-only (would-be exempt)
  local input='{"tool_input":{"command":"git commit -m x &"},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX git commit -m x & (background control) → fail-closed"
}

# (SX staged-diff) 사전 staged 2개(docs) → 정확 분류 → 통과.
test_sx_two_docs_staged_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  printf '# r\n' > "$SANDBOX/README.md"
  git -C "$SANDBOX" add CHANGELOG.md README.md
  local input='{"tool_input":{"command":"git commit -m \"docs: two\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX two docs staged → exempt passes"
}

# (SX staged-diff) hook.sh → docs/x.md rename → 구 경로 비허용 → 면제 미성립.
test_sx_rename_hook_to_doc_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  git -C "$SANDBOX" mv hookfile.sh docs/hookfile.md
  local input='{"tool_input":{"command":"git commit -m \"chore: move\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX rename hook.sh→docs/x.md → old path non-allowed → security required"
}

# (SX staged-diff) staged 없음 → 빈 출력 → fail-closed.
test_sx_no_staged_diff_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  # baseline 후 아무것도 staging 안 함 → git diff --cached 빈 출력.
  local input='{"tool_input":{"command":"git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX no staged diff (empty) → fail-closed"
}

# (SX staged-diff) PROJECT_DIR 가 git repo 아님 → git diff --cached 실패 → fail-closed.
test_sx_not_a_git_repo_failclosed() {
  # git init 하지 않음 → PROJECT_DIR(SANDBOX) 비-repo.
  _sx_seed_standard_dod_no_security
  local input='{"tool_input":{"command":"git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX non-git PROJECT_DIR → git diff --cached fails → fail-closed"
}

# (SX allowlist path) trail 표식 staged → 허용 → 통과.
test_sx_trail_marker_staged_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf 'reviewer=security-reviewer\n' > "$SANDBOX/trail/dod/.security-reviewed"
  git -C "$SANDBOX" add -A trail/dod/.security-reviewed
  local input='{"tool_input":{"command":"git commit -m \"chore: trail\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX trail/dod/.security-reviewed staged → exempt passes"
}

# (SX allowlist path) src 단독 staged → 비허용 → 보안 요구.
test_sx_source_file_staged_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf 'print("x")\n' > "$SANDBOX/src_foo.py"
  git -C "$SANDBOX" add src_foo.py
  local input='{"tool_input":{"command":"git commit -m \"chore: src\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX source file staged → non-allowed → security required"
}

# (SX allowlist path) docs + src 혼합 → 비허용 → 보안 요구.
test_sx_docs_plus_source_mixed_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  printf 'print("x")\n' > "$SANDBOX/src_foo.py"
  git -C "$SANDBOX" add CHANGELOG.md src_foo.py
  local input='{"tool_input":{"command":"git commit -m \"chore: mix\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX docs + source mixed → non-allowed → security required"
}

# (SX version line) rein.sh VERSION 1줄만 변경 → 허용 → 통과.
test_sx_rein_sh_version_only_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf 'VERSION="1.5.6"\n' > "$SANDBOX/scripts/rein.sh"
  git -C "$SANDBOX" add scripts/rein.sh
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX rein.sh VERSION-only line change → exempt passes"
}

# (SX version line) rein.sh VERSION + 다른 라인 변경 → 비허용 → 보안 요구.
test_sx_rein_sh_version_plus_logic_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf 'VERSION="1.5.6"\n# new comment\n' > "$SANDBOX/scripts/rein.sh"
  git -C "$SANDBOX" add scripts/rein.sh
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX rein.sh VERSION + extra line → non-allowed → security required"
}

# (SX version json) plugin.json top-level version 값만 변경 → 허용 → 통과.
test_sx_plugin_json_version_only_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '{\n  "name": "rein",\n  "version": "1.5.6",\n  "description": "x"\n}\n' \
    > "$SANDBOX/plugins/rein-core/.claude-plugin/plugin.json"
  git -C "$SANDBOX" add plugins/rein-core/.claude-plugin/plugin.json
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX plugin.json version-only change → exempt passes (semantic JSON compare)"
}

# (SX version json) plugin.json version + 다른 키 변경 → 비허용 → 보안 요구.
test_sx_plugin_json_other_key_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '{\n  "name": "rein",\n  "version": "1.5.6",\n  "description": "CHANGED"\n}\n' \
    > "$SANDBOX/plugins/rein-core/.claude-plugin/plugin.json"
  git -C "$SANDBOX" add plugins/rein-core/.claude-plugin/plugin.json
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX plugin.json version+other key change → non-allowed → security required"
}

# (SX version json) plugin.json 깨진 staged 내용 → 파싱 실패 → 비허용.
test_sx_plugin_json_parse_fail_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '{ broken json,,,' > "$SANDBOX/plugins/rein-core/.claude-plugin/plugin.json"
  git -C "$SANDBOX" add plugins/rein-core/.claude-plugin/plugin.json
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX plugin.json broken JSON → parse fail → security required"
}

# (SX version json, codex R1 Med) HEAD 부재(baseline 없는 repo) → git show HEAD: 실패 → 비허용.
test_sx_plugin_json_no_head_failclosed() {
  git -C "$SANDBOX" init -q 2>/dev/null
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  mkdir -p "$SANDBOX/plugins/rein-core/.claude-plugin"
  printf '{\n  "name": "rein",\n  "version": "1.5.6"\n}\n' \
    > "$SANDBOX/plugins/rein-core/.claude-plugin/plugin.json"
  git -C "$SANDBOX" add plugins/rein-core/.claude-plugin/plugin.json   # NO baseline commit → no HEAD
  _sx_seed_standard_dod_no_security
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX plugin.json with no HEAD (no baseline) → git show HEAD fail → security required"
}

# (SX skip P6/M2) 버전라인-only + 코드표식이 보안표식보다 최신(평소 STALE) → 통과(M2 skip).
test_sx_version_only_skips_m2_stale_compare() {
  _sx_git_init_baseline
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  # 코드 표식이 보안 표식보다 최신 + 다른 cycle = 평소라면 SECURITY_REVIEW_STALE.
  _write_code_stamp     "2026-06-16T05:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T01:00:00Z" "OTHER-cycle" "PASS"
  printf 'VERSION="1.5.6"\n' > "$SANDBOX/scripts/rein.sh"
  git -C "$SANDBOX" add scripts/rein.sh
  local input='{"tool_input":{"command":"git commit -m \"chore: bump\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX version-only + stale security stamp → M2 compare skipped, passes"
}

# (SX skip P6/M2) docs + 버전라인 혼합(전부 허용) → 통과.
test_sx_docs_plus_version_mixed_exempt_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  printf 'VERSION="1.5.6"\n' > "$SANDBOX/scripts/rein.sh"
  git -C "$SANDBOX" add CHANGELOG.md scripts/rein.sh
  local input='{"tool_input":{"command":"git commit -m \"chore: release\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX docs + version-line mixed (all allowed) → exempt passes"
}

# (SX nonexempt) 버전라인 + hook .sh 로직 변경 혼합 → 면제 미성립 → 보안 요구.
test_sx_version_plus_hook_logic_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf 'VERSION="1.5.6"\n' > "$SANDBOX/scripts/rein.sh"
  printf '# changed hook\necho new\n' > "$SANDBOX/hookfile.sh"
  git -C "$SANDBOX" add scripts/rein.sh hookfile.sh
  local input='{"tool_input":{"command":"git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX version-line + hook .sh logic → non-allowed → security required"
}

# (SX nonexempt) 면제 미성립 + stale 보안표식 → SECURITY_REVIEW_STALE 유지.
test_sx_nonexempt_stale_security_stamp_blocks() {
  _sx_git_init_baseline
  seed_dod "dod-2026-05-19-tc-gate-test.md"
  _write_code_stamp     "2026-06-16T05:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  _write_security_stamp "2026-06-16T01:00:00Z" "OTHER-cycle" "PASS"
  printf 'print("x")\n' > "$SANDBOX/src_foo.py"   # non-allowed → exemption fails
  git -C "$SANDBOX" add src_foo.py
  local input='{"tool_input":{"command":"git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_REVIEW_STALE" "SX non-exempt (source) + stale security stamp → SECURITY_REVIEW_STALE preserved"
}

# (SX nonexempt) hooks.json 단독 → 좁은 allowlist 밖 → 보안 요구.
test_sx_hooks_json_alone_failclosed() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '{"hooks":{}}\n' > "$SANDBOX/hooks.json"
  git -C "$SANDBOX" add hooks.json
  local input='{"tool_input":{"command":"git commit -m \"chore: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX hooks.json alone → outside narrow allowlist → security required"
}

# (SX coexist) light-tier+approved + src 편집(보안-surface 미성립) → skip(light-tier) → 통과.
test_sx_light_tier_with_source_still_passes() {
  _sx_git_init_baseline
  # light+approved DoD (Tier 1 active-dod marker).
  local content
  content=$(cat <<'DOD'
# DoD light
## 라우팅 추천
agent: rein:feature-builder
mcps: []
security_tier: light
approved_by_user: true
## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
)
  seed_dod "dod-2026-05-19-tc-gate-test.md" "$content"
  printf 'path=trail/dod/dod-2026-05-19-tc-gate-test.md\n' > "$SANDBOX/trail/dod/.active-dod"
  _write_code_stamp "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  printf 'print("x")\n' > "$SANDBOX/src_foo.py"   # source → security-surface not exempt
  git -C "$SANDBOX" add src_foo.py
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX light-tier + source edit → skip via light-tier (security-surface not needed)"
}

# (SX coexist) standard DoD + docs-only(보안-surface 성립) → skip(보안-surface) → 통과.
test_sx_standard_dod_docs_only_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"docs: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX standard DoD + docs-only → skip via security-surface"
}

# (SX coexist) 둘 다 미성립 → P6/M2 수행 → 보안 요구.
test_sx_neither_exempt_blocks() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf 'print("x")\n' > "$SANDBOX/src_foo.py"
  git -C "$SANDBOX" add src_foo.py
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "SECURITY_STAMP_MISSING" "SX neither exemption holds → P6/M2 run → security required"
}

# (SX coexist) P5 코드표식 부재는 면제와 무관하게 차단 (docs-only 면제 성립 상황).
test_sx_p5_codex_stamp_missing_blocks_despite_exempt() {
  _sx_git_init_baseline
  seed_dod "dod-2026-05-19-tc-gate-test.md"   # DoD only, NO codex stamp
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"docs: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "SX docs-only exempt but P5 codex stamp absent → still CODEX_STAMP_MISSING (P5 above exemption)"
}

# (SX audit) 보안-surface 면제 발동 → audit 로그 1줄 기록.
test_sx_audit_log_written_on_exempt() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local input='{"tool_input":{"command":"git commit -m \"docs: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX audit case: exemption passes"
  assert_file_exists "trail/incidents/security-surface-exempt.log"
  assert_file_contains "trail/incidents/security-surface-exempt.log" "reason=security-surface-exempt"
}

# (SX audit) light-tier 면제만 발동(보안-surface 미성립) → 본 audit 라인 미기록.
test_sx_audit_not_written_on_light_tier_only() {
  _sx_git_init_baseline
  local content
  content=$(cat <<'DOD'
# DoD light
## 라우팅 추천
agent: rein:feature-builder
mcps: []
security_tier: light
approved_by_user: true
## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
)
  seed_dod "dod-2026-05-19-tc-gate-test.md" "$content"
  printf 'path=trail/dod/dod-2026-05-19-tc-gate-test.md\n' > "$SANDBOX/trail/dod/.active-dod"
  _write_code_stamp "2026-06-16T01:00:00Z" "tc-cycle" "PASS" "skip" "skip"
  printf 'print("x")\n' > "$SANDBOX/src_foo.py"   # source → only light-tier exempts
  git -C "$SANDBOX" add src_foo.py
  local input='{"tool_input":{"command":"git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX light-tier only: passes"
  assert_file_missing "trail/incidents/security-surface-exempt.log"
}

# (SX audit) audit 디렉토리 제거 후 면제 발동 → 면제는 여전히 통과(비차단).
test_sx_audit_dir_removed_still_passes() {
  _sx_git_init_baseline
  _sx_seed_standard_dod_no_security
  printf '# c\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  rm -rf "$SANDBOX/trail/incidents"
  local input='{"tool_input":{"command":"git commit -m \"docs: x\""},"tool_result":{}}'
  run_hook "$HOOK" "$input"
  assert_pass "SX audit dir removed → exemption still passes (audit non-blocking)"
}

main() {
  # Policy block points P2-P7
  run_test test_p5_codex_stamp_missing_blocks                   "$HOOK"
  run_test test_p6_security_stamp_missing_blocks                "$HOOK"
  # M2/M3 review-stamp-freshness (docs/specs/2026-06-16-review-stamp-freshness.md)
  # Task 1.1 parser + ISO normalize helpers (source-only).
  run_test test_t11_normalize_z_mixed_compares_equal            "$HOOK"
  run_test test_t11_non_iso_security_ts_fails_closed            "$HOOK"
  run_test test_t11_missing_verdict_field_fails_closed          "$HOOK"
  # Task 1.2 M2 security stamp freshness + cycle + verdict.
  run_test test_m2_security_older_than_code_blocks              "$HOOK"
  run_test test_m2_security_fresh_same_cycle_pass_passes        "$HOOK"
  run_test test_m2_cycle_mismatch_blocks                        "$HOOK"
  run_test test_m2_both_cycles_empty_blocks                     "$HOOK"
  run_test test_m2_security_verdict_not_pass_blocks             "$HOOK"
  run_test test_m2_empty_security_stamp_fails_closed            "$HOOK"
  run_test test_m2_security_reviewed_non_iso_fails_closed       "$HOOK"
  # Task 1.5 M3 code stamp PASS dual-read.
  run_test test_m3_verdict_pass_passes                          "$HOOK"
  run_test test_m3_verdict_needs_fix_blocks                     "$HOOK"
  run_test test_m3_escalated_blocks                             "$HOOK"
  run_test test_m3_legacy_resolution_passed_passes             "$HOOK"
  run_test test_m3_no_verdict_field_blocks                     "$HOOK"
  run_test test_m3_time_unparseable_blocks                     "$HOOK"
  # Task 1.4 security-reviewer doc content-rich.
  run_test test_t14_security_reviewer_doc_is_content_rich       "$HOOK"
  run_test test_p3_review_pending_no_stamp_blocks               "$HOOK"
  run_test test_p4_code_edited_after_review_blocks              "$HOOK"
  run_test test_p7_commit_msg_format_blocks                     "$HOOK"
  # GMF-1 canonical commit recognition inside the gate
  run_test test_gmf1_git_dash_C_commit_enters_stamp_check       "$HOOK"
  run_test test_gmf1_git_double_space_commit_enters_stamp_check "$HOOK"
  run_test test_gmf1_git_dash_c_kv_commit_enters_stamp_check    "$HOOK"
  run_test test_gmf1_git_gitdir_commit_enters_stamp_check       "$HOOK"
  run_test test_gmf1_git_commit_graph_not_gated                 "$HOOK"
  run_test test_gmf1_git_config_commit_arg_not_gated            "$HOOK"
  run_test test_gmf1_git_bogus_option_commit_not_gated          "$HOOK"
  run_test test_gmf1_missing_git_model_lib_fails_closed         "$HOOK"
  # GMF-2 merge/rebase/am exemption precision
  run_test test_gmf2_commit_msg_literal_git_merge_not_exempted  "$HOOK"
  run_test test_gmf2_commit_msg_literal_git_rebase_not_exempted "$HOOK"
  run_test test_gmf2_real_merge_still_exempted                  "$HOOK"
  run_test test_gmf2_real_rebase_still_exempted                 "$HOOK"
  run_test test_gmf2_real_am_still_exempted                     "$HOOK"
  run_test test_gmf2_git_dash_C_merge_still_exempted            "$HOOK"
  run_test test_gmf2_commit_msg_bare_merge_word_enters_gate     "$HOOK"
  run_test test_good_commit_passes                              "$HOOK"
  # GMF-4 policy-toggle fail-open seal
  run_test test_gmf4_python_absent_does_not_disable_gate        "$HOOK"
  run_test test_gmf4_policy_disable_exits_zero                  "$HOOK"
  run_test test_gmf4_policy_enable_enters_body                  "$HOOK"
  run_test test_gmf4_loader_crash_fails_closed                  "$HOOK"
  run_test test_p2_coverage_mismatch_blocks                     "$HOOK"
  # Paired infra points I3-I5
  run_test test_i3_coverage_marker_unidentifiable_fails_closed  "$HOOK"
  run_test test_i4_commit_msg_helper_absent_fails_closed        "$HOOK"
  run_test test_i5_commit_msg_helper_exec_failure_fails_closed  "$HOOK"
  # GUARD-1 — test execution is not stamp-gated
  run_test test_guard1_pytest_not_blocked_without_stamps        "$HOOK"
  # Common infra I1·I2·I6
  run_test test_i1_python_resolver_failure_fails_closed         "$HOOK"
  run_test test_i2_json_parse_failure_fails_closed              "$HOOK"
  run_test test_i6_emitter_unavailable_fails_closed             "$HOOK"
  # SX-* security-surface exemption (docs/specs/2026-06-16-commit-gate-security-surface-exempt.md)
  # SX-command-form-failclosed
  run_test test_sx_add_and_commit_one_line_toctou_failclosed    "$HOOK"
  run_test test_sx_reset_and_commit_failclosed                  "$HOOK"
  run_test test_sx_lone_commit_docs_only_exempt_passes          "$HOOK"
  run_test test_sx_commit_dash_a_failclosed                     "$HOOK"
  run_test test_sx_commit_am_combined_failclosed                "$HOOK"
  run_test test_sx_commit_amend_failclosed                      "$HOOK"
  run_test test_sx_commit_pathspec_failclosed                   "$HOOK"
  run_test test_sx_commit_dash_S_separate_pathspec_failclosed   "$HOOK"
  run_test test_sx_commit_unknown_option_failclosed             "$HOOK"
  run_test test_sx_commit_global_opt_only_failclosed            "$HOOK"
  run_test test_sx_commit_signing_and_allowlist_opts_exempt_passes "$HOOK"
  run_test test_sx_commit_gpgsign_equals_exempt_passes          "$HOOK"
  run_test test_sx_multiword_message_quoted_exempt_passes       "$HOOK"
  run_test test_sx_message_then_real_pathspec_failclosed        "$HOOK"
  # SX hole-fix (codex integration review): cmd-subst/subshell/env/repo-redirect
  run_test test_sx_cmd_subst_in_message_failclosed              "$HOOK"
  run_test test_sx_backtick_in_message_failclosed               "$HOOK"
  run_test test_sx_subshell_group_failclosed                    "$HOOK"
  run_test test_sx_dash_C_other_repo_failclosed                 "$HOOK"
  run_test test_sx_gitdir_worktree_redirect_failclosed          "$HOOK"
  run_test test_sx_git_index_file_env_prefix_failclosed         "$HOOK"
  run_test test_sx_dash_c_config_commit_failclosed              "$HOOK"
  run_test test_sx_plain_lone_commit_multiword_still_passes     "$HOOK"
  # SX hole-fix R2 (codex integration review R2 High): non-git first clause skip
  run_test test_sx_command_wrapper_then_commit_failclosed       "$HOOK"
  run_test test_sx_cd_other_then_commit_failclosed              "$HOOK"
  run_test test_sx_env_wrapper_then_commit_failclosed           "$HOOK"
  run_test test_sx_true_then_commit_failclosed                  "$HOOK"
  run_test test_sx_echo_then_commit_failclosed                  "$HOOK"
  run_test test_sx_commit_then_trailing_cmd_failclosed          "$HOOK"
  # SX hole-fix R3 (codex integration review R3 High): background control `&`
  run_test test_sx_background_commit_failclosed                 "$HOOK"
  # SX-staged-diff-acquire
  run_test test_sx_two_docs_staged_exempt_passes                "$HOOK"
  run_test test_sx_rename_hook_to_doc_failclosed                "$HOOK"
  run_test test_sx_no_staged_diff_failclosed                    "$HOOK"
  run_test test_sx_not_a_git_repo_failclosed                    "$HOOK"
  # SX-allowlist-docs-trail
  run_test test_sx_trail_marker_staged_exempt_passes            "$HOOK"
  run_test test_sx_source_file_staged_failclosed                "$HOOK"
  run_test test_sx_docs_plus_source_mixed_failclosed            "$HOOK"
  # SX-allowlist-version-line
  run_test test_sx_rein_sh_version_only_exempt_passes           "$HOOK"
  run_test test_sx_rein_sh_version_plus_logic_failclosed        "$HOOK"
  run_test test_sx_plugin_json_version_only_exempt_passes       "$HOOK"
  run_test test_sx_plugin_json_other_key_failclosed             "$HOOK"
  run_test test_sx_plugin_json_parse_fail_failclosed            "$HOOK"
  run_test test_sx_plugin_json_no_head_failclosed               "$HOOK"
  # SX-skip-p6-m2-when-all-exempt
  run_test test_sx_version_only_skips_m2_stale_compare          "$HOOK"
  run_test test_sx_docs_plus_version_mixed_exempt_passes        "$HOOK"
  # SX-nonexempt-still-required
  run_test test_sx_version_plus_hook_logic_failclosed           "$HOOK"
  run_test test_sx_nonexempt_stale_security_stamp_blocks        "$HOOK"
  run_test test_sx_hooks_json_alone_failclosed                  "$HOOK"
  # SX-coexist-light-tier
  run_test test_sx_light_tier_with_source_still_passes          "$HOOK"
  run_test test_sx_standard_dod_docs_only_passes                "$HOOK"
  run_test test_sx_neither_exempt_blocks                        "$HOOK"
  run_test test_sx_p5_codex_stamp_missing_blocks_despite_exempt "$HOOK"
  # SX-audit-log
  run_test test_sx_audit_log_written_on_exempt                  "$HOOK"
  run_test test_sx_audit_not_written_on_light_tier_only         "$HOOK"
  run_test test_sx_audit_dir_removed_still_passes               "$HOOK"
  summary
}

main
