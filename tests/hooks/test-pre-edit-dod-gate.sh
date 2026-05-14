#!/bin/bash
# tests/hooks/test-pre-edit-dod-gate.sh
#
# Integration tests for Plan A Phase 4 pre-edit-dod-gate.sh extensions:
#   - Task 4.1: 2-tier active DoD selection via lib/select-active-dod.sh
#   - Task 4.2: validator invocation with 30s timeout + §4.2 tier×result table
#   - Task 4.3: no session cache (.claude/cache/dod-gate-validator* forbidden)
#
# Scope IDs:
#   - GI-dod-gate-active-dod-selection
#   - GI-dod-gate-validator-call
#   - GI-dod-gate-cache-invalidation
#   - GI-validator-v2-timeout-fail-closed
#
# Scenarios (Plan A Task 4.4):
#   A. Tier 1 blocking — .active-dod marker + invalid covers → exit 2 + .dod-coverage-mismatch
#   B. Tier 1 pass    — .active-dod marker + valid DoD → exit 0 + no marker
#   C. Tier 2 advisory — no marker + DoD with 범위 연결 + mismatch → exit 0 + .dod-coverage-advisory
#   D. No candidate  — no marker + DoD without 범위 연결 → exit 0 (legacy path)
#   E. Validator timeout — mocked validator sleeps > 30s → exit 2 (Tier 1) + timeout log
#   F. No cache regression — hook invocations never create .claude/cache/dod-gate-validator*

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
        "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh"
      rm -f "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh.bak"
      ;;
  esac
}

# Plan-A dod file that avoids the "unreviewed spec" block. We keep the
# sandbox free of .spec-reviews/*.pending so the spec-review gate is inert.

_make_input() {
  # $1 = source file path inside sandbox (relative)
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$abs"
}

# ---- Scenario A: Tier 1 fail → block
test_scenario_A_tier1_invalid_covers_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "Tier 1 + unknown covers → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "BLOCKED"
}

# ---- Scenario B: Tier 1 pass → exit 0, no marker
test_scenario_B_tier1_valid_passes() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "Tier 1 + valid covers → exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario C: Tier 2 fail → advisory (non-blocking)
test_scenario_C_tier2_advisory_non_blocking() {
  _mk_sandbox_extras tier2-fail
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "Tier 2 + unknown covers → advisory, not blocking"
  assert_file_exists "trail/dod/.dod-coverage-advisory"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
}

# ---- Scenario D: no candidate DoD → exit 0 silently (legacy path)
test_scenario_D_no_candidate_passes() {
  _mk_sandbox_extras no-candidate
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

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

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

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

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"
  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  # Forbidden pattern: .claude/cache/dod-gate-validator*
  if ls "$SANDBOX/.claude/cache"/dod-gate-validator* >/dev/null 2>&1; then
    fail "forbidden cache file created by pre-edit-dod-gate"
  fi
}

# ---- Scenario G (Phase 7b Task 7.3 Step 7): malformed governance.json
# must trigger fail-closed block + .dod-coverage-mismatch + log append.
test_scenario_G_governance_invalid_fails_closed() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  # Corrupt the governance config. The hook's read_governance_stage
  # should return "INVALID", which the hook converts to fail-closed.
  mkdir -p "$SANDBOX/.claude/.rein-state"
  echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "malformed governance.json → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  # Log must be appended with an invalid_stage entry.
  if [ ! -f "$SANDBOX/trail/incidents/governance-config-invalid.log" ]; then
    fail "governance-config-invalid.log not created"
  else
    grep -q "invalid_stage" "$SANDBOX/trail/incidents/governance-config-invalid.log" \
      || fail "governance-config-invalid.log missing 'invalid_stage' marker"
  fi
  assert_stderr_contains "governance.json"
}

# ---- Scenario H (2026-04-22 retro-review-sweep M1):
# `.claude/rules/*` 는 branch-strategy.md 기준 main 포함 source 이므로 DoD gate
# 를 통과해야 한다. 기존 blanket `*/.claude/*` exemption 이 제거된 결과 검증.
test_scenario_H_m1_claude_rules_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/rules"
  touch "$SANDBOX/.claude/rules/foo.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/rules/foo.md)"

  assert_exit 2 ".claude/rules/foo.md 편집 시 M1 whitelist 상 source → DoD gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "BLOCKED"
}

# ---- Scenario I (M1):
# `.claude/cache/*` 는 hook/validator 가 기록하는 runtime state. DoD 없이도 면제.
# 기존 exemption 유지 확인.
test_scenario_I_m1_claude_cache_exempts() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/cache"
  touch "$SANDBOX/.claude/cache/test"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/cache/test)"

  assert_exit 0 ".claude/cache/test → runtime state 면제로 exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario J (M1):
# repo root 의 AGENTS.md 는 main 포함 — 편집 시 DoD 필요.
test_scenario_J_m1_agents_md_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/AGENTS.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input AGENTS.md)"

  assert_exit 2 "AGENTS.md 편집 시 M1 whitelist 상 source → DoD gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "BLOCKED"
}

# ---- Scenario K (M1):
# `.claude/skills/**` 는 main 포함 — 편집 시 DoD 필요.
test_scenario_K_m1_claude_skills_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/skills/foo"
  touch "$SANDBOX/.claude/skills/foo/SKILL.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/skills/foo/SKILL.md)"

  assert_exit 2 ".claude/skills/foo/SKILL.md 편집 시 M1 whitelist 상 source → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "BLOCKED"
}

# ---- Scenario L (M1 Round 2, 2026-04-22):
# `.gitignore` 는 main 포함 — 편집 시 DoD 필요. 기존 `*.gitignore` 면제는 제거됨.
# Codex Round 1 의 Medium finding 반영.
test_scenario_L_m1_gitignore_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/.gitignore"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .gitignore)"

  assert_exit 2 ".gitignore 편집 시 M1 whitelist 상 source → DoD gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "BLOCKED"
}

# ---- Scenario L2 (M1 Round 3, 2026-04-22): cache 경로의 .gitignore 도 차단.
# Codex Round 2 finding: `.claude/cache/.gitignore` 는 main 포함 (branch-
# strategy.md) 지만 cache blanket exemption 이 우선해서 bypass 되고 있었음.
# .gitignore 는 위치와 무관하게 항상 source 로 분류해야 한다.
test_scenario_L2_m1_cache_gitignore_still_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/cache"
  touch "$SANDBOX/.claude/cache/.gitignore"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/cache/.gitignore)"

  assert_exit 2 ".claude/cache/.gitignore 편집 시 cache exemption 무시하고 block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "BLOCKED"
}

# ---- Scenario M (M1 Round 2): `.gitkeep` 은 여전히 면제 (placeholder).
test_scenario_M_m1_gitkeep_exempts() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/some/dir"
  touch "$SANDBOX/some/dir/.gitkeep"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input some/dir/.gitkeep)"

  assert_exit 0 ".gitkeep → placeholder 면제 exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

main() {
  run_test test_scenario_A_tier1_invalid_covers_blocks pre-edit-dod-gate.sh
  run_test test_scenario_B_tier1_valid_passes          pre-edit-dod-gate.sh
  run_test test_scenario_C_tier2_advisory_non_blocking pre-edit-dod-gate.sh
  run_test test_scenario_D_no_candidate_passes         pre-edit-dod-gate.sh
  run_test test_scenario_E_tier1_timeout_blocks_and_logs pre-edit-dod-gate.sh
  run_test test_scenario_F_no_cache_regression         pre-edit-dod-gate.sh
  run_test test_scenario_G_governance_invalid_fails_closed pre-edit-dod-gate.sh
  run_test test_scenario_H_m1_claude_rules_blocks      pre-edit-dod-gate.sh
  run_test test_scenario_I_m1_claude_cache_exempts     pre-edit-dod-gate.sh
  run_test test_scenario_J_m1_agents_md_blocks         pre-edit-dod-gate.sh
  run_test test_scenario_K_m1_claude_skills_blocks     pre-edit-dod-gate.sh
  run_test test_scenario_L_m1_gitignore_blocks         pre-edit-dod-gate.sh
  run_test test_scenario_L2_m1_cache_gitignore_still_blocks pre-edit-dod-gate.sh
  run_test test_scenario_M_m1_gitkeep_exempts          pre-edit-dod-gate.sh
  summary
}

main "$@"
