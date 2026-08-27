#!/bin/bash
# tests/hooks/test-pre-edit-coverage-gate.sh
#
# feature-builder-refactor task step 1 (Marker B relocation). These
# scenarios used to live in tests/hooks/test-pre-edit-dod-gate.sh and
# exercise pre-edit-dod-gate.sh directly (its DOD_FOUND=true branch used to
# run the coverage validator inline). That logic — and the
# .dod-coverage-mismatch / .dod-coverage-advisory marker production — moved
# to the new pre-edit-coverage-gate.sh hook (same PreToolUse
# Edit|Write|MultiEdit matcher group). This file is the retargeted copy:
# identical fixtures, identical assertions, new hook name — proving the move
# preserved behavior exactly (same input → same marker/exit outcome).
#
# Scenarios (moved from test-pre-edit-dod-gate.sh, unrenamed to keep the
# history traceable):
#   A. Tier 1 blocking — .active-dod marker + invalid covers → exit 2 + .dod-coverage-mismatch
#   B. Tier 1 pass    — .active-dod marker + valid DoD → exit 0 + no marker
#   C. Tier 2 advisory — no marker + DoD with 범위 연결 + mismatch → exit 0 + .dod-coverage-advisory
#   D. No candidate  — no marker + DoD without 범위 연결 → exit 0 (legacy path)
#   E. Validator timeout — mocked validator sleeps > 30s → exit 2 (Tier 1) + timeout log
#   F. No cache regression — hook invocations never create .claude/cache/dod-gate-validator*
#   H/I/J/K/L/L2/M — M1 source-classification scenarios that use a tier1-fail/
#     tier1-pass fixture as the vehicle to prove a path IS/IS NOT source (the
#     coverage-validator message + marker are the observable signal). These
#     depend on lib/source-path-classify.sh agreeing with pre-edit-dod-gate.sh
#     — which it must, by construction (single shared classifier).
#
# NOT moved here (stayed in test-pre-edit-dod-gate.sh, unaffected by this
# extraction): G (governance-invalid — a different, out-of-scope marker
# producer left inline in pre-edit-dod-gate.sh), GMF-3/GMF-4 (exercise the
# "no active DoD" branch, never reach the coverage validator).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# _mk_sandbox_extras: beyond the harness defaults, lay down the plan /
# design / DoD files that the validator v2 expects in the sandbox.
#
# Args: $1=kind  one of: tier1-pass | tier1-fail | tier2-fail | no-candidate | tier1-timeout
_mk_sandbox_extras() {
  local kind="$1"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/docs/specs" "$SANDBOX/docs/plans"

  # Copy the real validator + path-policy lib so the hook can call them.
  cp "$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py" \
     "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  # Also copy the incident aggregator (REIN_GATE_PEEK_MODE regression tests
  # below need a REAL --count-pending answer, not a "helper missing" fail-
  # closed short-circuit, to actually exercise the LIVE_COUNT>0 branch).
  cp "$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-aggregate-incidents.py" \
     "$SANDBOX/scripts/rein-aggregate-incidents.py"

  # Design (Scope Items table).
  cat > "$SANDBOX/docs/specs/sample-design.md" <<'EOF'
# Sample design

## Scope Items

| ID | desc |
|----|------|
| S1 | sample item one |
| S2 | sample item two |
EOF

  # Plan with coverage matrix + covers:.
  cat > "$SANDBOX/docs/plans/sample-plan.md" <<'EOF'
# Sample plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/sample-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| S1 | implemented | Phase 1 |
| S2 | implemented | Phase 2 |

## Phase 1
covers: [S1]

## Phase 2
covers: [S2]
EOF

  case "$kind" in
    tier1-pass)
      # Valid DoD: covers ⊆ implemented IDs + marker → Tier 1.
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, S2]
EOF
      cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
      ;;
    tier1-fail)
      # Covers an unknown ID → validator exits 2 → Tier 1 block.
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, ZZZ]
EOF
      cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
      ;;
    tier2-fail)
      # No marker. DoD has 범위 연결 but an unknown ID → validator exits 2 →
      # advisory marker only (Tier 2).
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [NOPE]
EOF
      ;;
    no-candidate)
      # DoD has no '## 범위 연결' — selector returns tier 0.
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-legacy.md" <<'EOF'
# legacy DoD, no 범위 연결
EOF
      ;;
    tier1-timeout)
      # Stand up a fake validator that sleeps > 30s. Replace the copied
      # real validator with a script that exec's `sleep 99`. We use a
      # shorter VALIDATOR_TIMEOUT_S by patching the hook in the sandbox.
      cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'EOF'
#!/usr/bin/env python3
import sys, time
time.sleep(99)
sys.exit(0)
EOF
      chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1]
EOF
      cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
      # Patch sandbox hook to use a 2s timeout for this test only.
      sed -i.bak \
        's/VALIDATOR_TIMEOUT_S=30/VALIDATOR_TIMEOUT_S=2/' \
        "$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh"
      rm -f "$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh.bak"
      ;;
  esac
}

_make_input() {
  # $1 = source file path inside sandbox (relative)
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$abs"
}

# _run_coverage_gate_with_plugin_root: like run_hook, but sets
# CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" explicitly. The auto-mode branch of
# lib/incident-review-gate.sh's rein_check_incident_review_gate (guarded by
# `[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/auto-mode.sh" ]`) never fires
# under a plain run_hook() call, which leaves CLAUDE_PLUGIN_ROOT unset — the
# scenario below needs that branch actually entered. sandbox_setup already
# copies the full lib/ directory (auto-mode.sh included) to
# $SANDBOX/.claude/hooks/lib/, so this path genuinely resolves.
_run_coverage_gate_with_plugin_root() {
  local stdin_json="$1"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp); tmp_stderr=$(mktemp)
  printf '%s' "$stdin_json" \
    | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh" \
      >"$tmp_stdout" 2>"$tmp_stderr"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_stdout")
  HOOK_STDERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr"
}

# ---- Scenario A: Tier 1 fail → block
test_scenario_A_tier1_invalid_covers_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "Tier 1 + unknown covers → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario B: Tier 1 pass → exit 0, no marker
test_scenario_B_tier1_valid_passes() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "Tier 1 + valid covers → exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario C: Tier 2 fail → advisory (non-blocking)
test_scenario_C_tier2_advisory_non_blocking() {
  _mk_sandbox_extras tier2-fail
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "Tier 2 + unknown covers → advisory, not blocking"
  assert_file_exists "trail/dod/.dod-coverage-advisory"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
}

# ---- Scenario D: no candidate DoD → exit 0 silently (legacy path)
test_scenario_D_no_candidate_passes() {
  _mk_sandbox_extras no-candidate
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "no candidate → pass"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario E: validator timeout (Tier 1) → block + log
test_scenario_E_tier1_timeout_blocks_and_logs() {
  # Skip gracefully if timeout(1) is unavailable (BSD macOS w/o GNU coreutils).
  if ! command -v timeout >/dev/null 2>&1; then
    echo "  SKIP: timeout(1) not on PATH — scenario E not applicable"
    return 0
  fi
  _mk_sandbox_extras tier1-timeout
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "Tier 1 + validator timeout → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  # Timeout log must have been appended.
  if [ ! -f "$SANDBOX/trail/incidents/validator-timeout.log" ]; then
    fail "validator-timeout.log not created"
  else
    grep -q "timeout" "$SANDBOX/trail/incidents/validator-timeout.log" \
      || fail "validator-timeout.log missing 'timeout' entry"
  fi
}

# ---- Scenario F: no cache file is ever created
test_scenario_F_no_cache_regression() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"
  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  # Forbidden pattern: .claude/cache/dod-gate-validator*
  if ls "$SANDBOX/.claude/cache"/dod-gate-validator* >/dev/null 2>&1; then
    fail "forbidden cache file created by pre-edit-coverage-gate"
  fi
}

# ---- Scenario H (2026-04-22 retro-review-sweep M1):
# `.claude/rules/*` 는 branch-strategy.md 기준 main 포함 source 이므로
# coverage gate 를 통과(=평가 대상이)해야 한다.
test_scenario_H_m1_claude_rules_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/rules"
  touch "$SANDBOX/.claude/rules/foo.md"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input .claude/rules/foo.md)"

  assert_exit 2 ".claude/rules/foo.md 편집 시 M1 whitelist 상 source → coverage gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario I (M1):
# `.claude/cache/*` 는 hook/validator 가 기록하는 runtime state. 면제.
test_scenario_I_m1_claude_cache_exempts() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/cache"
  touch "$SANDBOX/.claude/cache/test"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input .claude/cache/test)"

  assert_exit 0 ".claude/cache/test → runtime state 면제로 exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario J (M1):
# repo root 의 AGENTS.md 는 main 포함 — coverage gate 평가 대상.
test_scenario_J_m1_agents_md_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/AGENTS.md"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input AGENTS.md)"

  assert_exit 2 "AGENTS.md 편집 시 M1 whitelist 상 source → coverage gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario K (M1):
# `.claude/skills/**` 는 main 포함 — coverage gate 평가 대상.
test_scenario_K_m1_claude_skills_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/skills/foo"
  touch "$SANDBOX/.claude/skills/foo/SKILL.md"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input .claude/skills/foo/SKILL.md)"

  assert_exit 2 ".claude/skills/foo/SKILL.md 편집 시 M1 whitelist 상 source → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario L (M1 Round 2, 2026-04-22):
# `.gitignore` 는 main 포함 — coverage gate 평가 대상.
test_scenario_L_m1_gitignore_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/.gitignore"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input .gitignore)"

  assert_exit 2 ".gitignore 편집 시 M1 whitelist 상 source → coverage gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario L2 (M1 Round 3, 2026-04-22): cache 경로의 .gitignore 도 차단.
test_scenario_L2_m1_cache_gitignore_still_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/cache"
  touch "$SANDBOX/.claude/cache/.gitignore"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input .claude/cache/.gitignore)"

  assert_exit 2 ".claude/cache/.gitignore 편집 시 cache exemption 무시하고 block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario M (M1 Round 2): `.gitkeep` 은 여전히 면제 (placeholder).
test_scenario_M_m1_gitkeep_exempts() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/some/dir"
  touch "$SANDBOX/some/dir/.gitkeep"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input some/dir/.gitkeep)"

  assert_exit 0 ".gitkeep → placeholder 면제 exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ============================================================
# REIN_GATE_PEEK_MODE regression — HISTORICAL, PEEK REMOVED (Phase 7 wave 3
# ③-b code review round 1 introduced the peek; round 6, High, removed it
# entirely, 2026-08-23).
#
# History: pre-edit-coverage-gate.sh used to run a same-process precheck
# (_rein_precheck_would_block) that called the SAME incident-review-gate /
# spec-review-gate / routing-gate functions pre-edit-discipline-gate.sh (the
# ENFORCING hook) calls, inside a subshell, to infer "would a sibling gate
# already be blocking this edit". Those functions consume one-shot bypass
# markers as a real filesystem mutation (rm -f) on a block. Because Claude
# Code ran every hook matched to the same PreToolUse event in parallel with
# a non-deterministic order (hooks guide), that peek could observe a
# sibling bypass marker in an inconsistent state — round 1 found "peek
# consumes the marker for real before the enforcing hook ever sees it"; the
# round 1 fix (guarding every one-shot `rm -f` behind REIN_GATE_PEEK_MODE)
# closed THAT mutation, but round 6 found the peek was still unsound at a
# more fundamental level: a STALE READ of the marker (peek observing "still
# present" a moment after the enforcing hook's REAL removal already
# happened) caused this hook to skip its own coverage-validator check for
# an edit whose `covers:` list referenced a nonexistent Scope ID — the
# exact same-process peek reasoning that round 1 patched was itself
# structurally unsound on top of a non-deterministic scheduler, no matter
# how the mutation half was guarded.
#
# Round 6 fix: pre-edit-dispatcher.sh now runs pre-edit-discipline-gate.sh
# → pre-edit-task-gate.sh → pre-edit-coverage-gate.sh in guaranteed
# sequential order with first-block-wins semantics. This hook running at
# all is proof every gate ahead of it in that sequence already passed —
# there is nothing left to peek at, so the peek code (and the three lib
# sourcings that existed only to support it) was deleted from
# pre-edit-coverage-gate.sh entirely (see that file's own updated header
# comment).
#
# Scenarios N/O/P/Q below are KEPT (not deleted) because their behavioral
# assertions still hold — now for a more direct reason. Running
# pre-edit-coverage-gate.sh IN ISOLATION (never pre-edit-discipline-gate.sh,
# never the dispatcher) against a sandbox where a sibling precondition would
# be blocking AND a one-shot bypass marker is present: the bypass marker
# still SURVIVES and the hook still lands on exit 0 — but now trivially,
# because this hook no longer sources lib/incident-review-gate.sh,
# lib/spec-review-gate.sh, or lib/routing-gate.sh at all, so it never even
# attempts to read (let alone write) those markers. Scenario S (new, below)
# adds a direct structural assertion locking in the removal itself, so a
# regression that reintroduces the peek fails immediately instead of only
# being caught by these now-trivial behavioral checks.
# ============================================================

# ---- Scenario N: incident-review-gate one-shot bypass must survive a
# coverage-gate-only run (now trivially true — this hook no longer sources
# lib/incident-review-gate.sh at all, see the block comment above).
test_scenario_N_incident_bypass_peek_does_not_consume() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/auto-hook-peek111.md" <<'EOF'
---
status: "pending"
pattern_hash: "peek111"
hook: "hook"
reason: "peek test incident"
count: "2"
first_seen: "2026-01-01T00:00:00"
last_seen_at: "2026-01-02T00:00:00"
---

# Incident: hook / peek test incident
EOF
  touch "$SANDBOX/trail/dod/.incident-review-pending"
  echo "reason=test bypass" > "$SANDBOX/trail/dod/.skip-incident-gate"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "coverage-gate alone must not block on an incident-review precondition it does not own"
  assert_file_exists "trail/dod/.skip-incident-gate"
}

# ---- Scenario O: routing-gate one-shot bypass (missing-section branch)
# must survive a coverage-gate-only run (now trivially true — this hook no
# longer sources lib/routing-gate.sh at all, see the block comment above
# scenario N).
test_scenario_O_routing_bypass_peek_does_not_consume() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  touch "$SANDBOX/trail/dod/.routing-missing-dod-2026-04-21-sample.md"
  echo "reason=test bypass" > "$SANDBOX/trail/dod/.skip-routing-gate"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "coverage-gate alone must not block on a routing precondition it does not own"
  assert_file_exists "trail/dod/.skip-routing-gate"
}

# ============================================================
# Peek-must-never-write-a-persistent-audit-log regression — HISTORICAL,
# PEEK REMOVED (Phase 7 wave 3 ③-b code review round 2, Medium, introduced;
# round 6, High, removed the peek entirely — see the block comment above
# scenario N). Both scenarios below still run pre-edit-coverage-gate.sh
# ALONE (never pre-edit-discipline-gate.sh, never the dispatcher) and still
# prove the audit log is never created/appended — now trivially, because
# this hook no longer sources lib/spec-review-gate.sh or
# lib/incident-review-gate.sh at all, so the code paths that used to write
# these lines are simply not reachable from this file anymore.
# ============================================================

# ---- Scenario P: spec-review-gate's SKIP_SPEC_GATE consume-audit log
# (hooks/lib/spec-review-gate.sh, the BYPASS_LOG write right after the
# `rm -f "$SKIP_SPEC_GATE"` guard) must not fire from a coverage-gate-only
# run (now trivially true — this hook does not source that lib at all).
test_scenario_P_spec_review_bypass_audit_log_peek_does_not_write() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  echo "reason=test bypass" > "$SANDBOX/trail/dod/.skip-spec-gate"

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "coverage-gate alone must not block on a spec-review precondition it does not own"
  assert_file_exists "trail/dod/.skip-spec-gate"
  assert_file_missing "trail/incidents/auto-mode-bypass.log"
}

# ---- Scenario Q: incident-review-gate's auto-mode silence path
# (hooks/lib/incident-review-gate.sh, the `auto_mode_log_bypass` call in the
# `elif ... is_auto_mode` branch) must not fire from a coverage-gate-only
# run either (now trivially true — this hook does not source that lib at
# all). This branch only activates when CLAUDE_PLUGIN_ROOT resolves to a
# real hooks/lib/auto-mode.sh, which run_hook() does not set — hence the
# dedicated _run_coverage_gate_with_plugin_root helper.
test_scenario_Q_incident_auto_mode_bypass_audit_log_peek_does_not_write() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/auto-hook-peekq1.md" <<'EOF'
---
status: "pending"
pattern_hash: "peekq1"
hook: "hook"
reason: "peek auto-mode test incident"
count: "2"
first_seen: "2026-01-01T00:00:00"
last_seen_at: "2026-01-02T00:00:00"
---

# Incident: hook / peek auto-mode test incident
EOF
  touch "$SANDBOX/trail/dod/.incident-review-pending"
  # 바이패스 없음, 대신 auto-mode 활성 — is_auto_mode() 분기로 진입시킨다.
  mkdir -p "$SANDBOX/.rein"
  touch "$SANDBOX/.rein/auto-mode.flag"

  _run_coverage_gate_with_plugin_root "$(_make_input scripts/foo.sh)"

  assert_exit 0 "coverage-gate alone must not block on an incident-review precondition it does not own"
  assert_file_missing "trail/incidents/auto-mode-bypass.log"
}

# ============================================================
# Scenario S (new, round 6 High fix) — structural regression lock: the peek
# code, its REIN_GATE_PEEK_MODE export, and the three precondition-gate lib
# sourcings must never reappear in this file. Scenarios N/O/P/Q above still
# assert the OLD peek's behavioral guarantees (bypass markers survive, audit
# logs stay empty) but those assertions are now trivially true for any
# reason at all (including a totally broken hook that crashes before
# reading anything) — they alone would not catch someone re-adding the peek
# in a NEW form that still passes those checks. This scenario greps the
# shipped hook source directly so a reintroduction fails immediately,
# independent of what a re-added peek's own behavior might look like.
# ============================================================
test_scenario_S_peek_code_structurally_absent() {
  local hook_src="$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh"
  if [ ! -f "$hook_src" ]; then
    fail "hook source not found in sandbox: $hook_src"
    return
  fi
  # Strip full-line comments before grepping — the hook's own header
  # legitimately mentions `_rein_precheck_would_block` / `REIN_GATE_PEEK_
  # MODE` in prose (backtick-quoted, historical) explaining WHY the peek was
  # removed. This check must catch a re-added CODE path, not the prose that
  # documents its removal, so comment-only lines (leading `#`, optional
  # leading whitespace) are excluded first.
  local code_only
  code_only=$(grep -vE '^[[:space:]]*#' "$hook_src")
  if printf '%s\n' "$code_only" | grep -q '_rein_precheck_would_block'; then
    fail "pre-edit-coverage-gate.sh still defines/calls _rein_precheck_would_block in code — the removed peek regressed"
  fi
  if printf '%s\n' "$code_only" | grep -q 'REIN_GATE_PEEK_MODE'; then
    fail "pre-edit-coverage-gate.sh still references REIN_GATE_PEEK_MODE in code — the removed peek regressed"
  fi
  for lib in incident-review-gate.sh spec-review-gate.sh routing-gate.sh; do
    if printf '%s\n' "$code_only" | grep -qE "\\.\\s+\"\\\$SCRIPT_DIR/lib/${lib}\""; then
      fail "pre-edit-coverage-gate.sh still sources lib/${lib} — that sourcing existed only to support the removed peek"
    fi
  done
  # This hook must still source the libs it genuinely needs for its OWN
  # judgment — the removal above must not have taken these out too.
  for lib in source-path-classify.sh dod-found.sh select-active-dod.sh plugin-script-path.sh; do
    if ! printf '%s\n' "$code_only" | grep -qE "\\.\\s+\"\\\$SCRIPT_DIR/lib/${lib}\""; then
      fail "pre-edit-coverage-gate.sh no longer sources lib/${lib} — this hook still needs it for its own judgment"
    fi
  done
}

main() {
  run_test test_scenario_A_tier1_invalid_covers_blocks   pre-edit-coverage-gate.sh
  run_test test_scenario_B_tier1_valid_passes             pre-edit-coverage-gate.sh
  run_test test_scenario_C_tier2_advisory_non_blocking    pre-edit-coverage-gate.sh
  run_test test_scenario_D_no_candidate_passes            pre-edit-coverage-gate.sh
  run_test test_scenario_E_tier1_timeout_blocks_and_logs  pre-edit-coverage-gate.sh
  run_test test_scenario_F_no_cache_regression            pre-edit-coverage-gate.sh
  run_test test_scenario_H_m1_claude_rules_blocks         pre-edit-coverage-gate.sh
  run_test test_scenario_I_m1_claude_cache_exempts        pre-edit-coverage-gate.sh
  run_test test_scenario_J_m1_agents_md_blocks            pre-edit-coverage-gate.sh
  run_test test_scenario_K_m1_claude_skills_blocks        pre-edit-coverage-gate.sh
  run_test test_scenario_L_m1_gitignore_blocks            pre-edit-coverage-gate.sh
  run_test test_scenario_L2_m1_cache_gitignore_still_blocks pre-edit-coverage-gate.sh
  run_test test_scenario_M_m1_gitkeep_exempts             pre-edit-coverage-gate.sh
  # REIN_GATE_PEEK_MODE regression — peek must not consume one-shot bypasses
  run_test test_scenario_N_incident_bypass_peek_does_not_consume  pre-edit-coverage-gate.sh
  run_test test_scenario_O_routing_bypass_peek_does_not_consume   pre-edit-coverage-gate.sh
  # Peek must never write a persistent audit log either (round 2 fix)
  run_test test_scenario_P_spec_review_bypass_audit_log_peek_does_not_write   pre-edit-coverage-gate.sh
  run_test test_scenario_Q_incident_auto_mode_bypass_audit_log_peek_does_not_write pre-edit-coverage-gate.sh
  # Structural regression lock — peek code must never reappear
  run_test test_scenario_S_peek_code_structurally_absent  pre-edit-coverage-gate.sh
  summary
}

main "$@"
