#!/bin/bash
# tests/hooks/test-security-tier-gate.sh
#
# RT-1 (docs/specs/2026-05-19-cc-feature-adoption.md §RT-1):
# Verify that the `security_tier` field in the DoD `## 라우팅 추천` YAML
# controls whether the .security-reviewed stamp is required for `git commit`.
#
# Gate behavior (fail-closed):
#   security_tier: light  + approved_by_user: true  → P6 stamp SKIPPED
#   security_tier: light  + approved_by_user: false → P6 stamp REQUIRED
#   security_tier: standard (any approved_by_user)  → P6 stamp REQUIRED
#   security_tier: deep                             → P6 stamp REQUIRED
#   security_tier field absent                      → P6 stamp REQUIRED (backward-compat)
#   security_tier: garbage/malformed value          → P6 stamp REQUIRED (fail-closed)
#
# P5 (.codex-reviewed) is ALWAYS required regardless of security_tier.
#
# Block-point reference (pre-bash-test-commit-gate.sh):
#   [P5]  codex review stamp missing   — never skipped
#   [P6]  security review stamp missing — skipped only for light+approved

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

# Build a DoD content string with the routing YAML populated.
# Args: $1=security_tier value (or "absent" to omit the field),
#       $2=approved_by_user value (true|false)
#
# NOTE: ## 범위 연결 is included so select_active_dod can resolve this DoD
# as a Tier 2 candidate (most-recent DoD with ## 범위 연결). Without it
# select_active_dod returns Tier 0 → fail-closed regardless of security_tier.
# Real DoDs always carry ## 범위 연결 (required by pre-edit-dod-gate).
_dod_content_with_routing() {
  local tier_val="$1"
  local approved="$2"
  if [ "$tier_val" = "absent" ]; then
    cat <<DOD
# DoD: security-tier-gate-test

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
rationale:
  - test fixture
approved_by_user: ${approved}

## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
  else
    cat <<DOD
# DoD: security-tier-gate-test

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: ${tier_val}
rationale:
  - test fixture
approved_by_user: ${approved}

## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
  fi
}

# Seed a DoD with given routing YAML, plus the codex stamp.
# The security stamp is intentionally NOT created — each test
# then asserts whether it is required (deny P6) or skipped (pass).
_seed_fixture() {
  local tier_val="$1"
  local approved="$2"
  local content
  content="$(_dod_content_with_routing "$tier_val" "$approved")"
  seed_dod "dod-2026-05-19-security-tier-test.md" "$content"
  # Codex stamp always present — we're only testing security tier behavior.
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  # Deliberately NO .security-reviewed
}

COMMIT_INPUT='{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}'

# ============================================================
# Case (a): security_tier: light + approved_by_user: true
#   → git commit passes WITHOUT .security-reviewed stamp.
#   → .codex-reviewed is still required (present in this fixture).
# ============================================================
test_a_light_approved_passes_without_security_stamp() {
  _seed_fixture "light" "true"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_pass "RT-1(a) security_tier:light + approved:true → commit should pass without security stamp"
}

# ============================================================
# Case (b): security_tier: standard + approved_by_user: true
#   → .security-reviewed still required (P6 deny).
# ============================================================
test_b_standard_still_requires_security_stamp() {
  _seed_fixture "standard" "true"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(b) security_tier:standard → P6 security stamp should still be required"
}

# ============================================================
# Case (c): security_tier: light + approved_by_user: false
#   → fail-closed: .security-reviewed still required (P6 deny).
# ============================================================
test_c_light_not_approved_still_requires_security_stamp() {
  _seed_fixture "light" "false"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(c) security_tier:light but approved:false → fail-closed, P6 still required"
}

# ============================================================
# Case (d): security_tier field absent
#   → backward-compat: .security-reviewed still required (P6 deny).
# ============================================================
test_d_no_security_tier_field_requires_security_stamp() {
  _seed_fixture "absent" "true"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(d) no security_tier field → backward-compat, P6 still required"
}

# ============================================================
# Case (e): security_tier: <garbage value>
#   → fail-closed: .security-reviewed still required (P6 deny).
# ============================================================
test_e_garbage_security_tier_fails_closed() {
  _seed_fixture "INVALID_GARBAGE_VALUE_123" "true"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(e) malformed/garbage security_tier → fail-closed, P6 still required"
}

# ============================================================
# Case (f): security_tier: deep + approved_by_user: true
#   → .security-reviewed still required (P6 deny).
# ============================================================
test_f_deep_still_requires_security_stamp() {
  _seed_fixture "deep" "true"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(f) security_tier:deep → P6 security stamp should still be required"
}

# ============================================================
# Case (g): security_tier: light + approved_by_user: true + BOTH stamps present
#   → should also pass (light+approved is a relaxation, not a break when stamp exists).
# ============================================================
test_g_light_approved_with_security_stamp_also_passes() {
  _seed_fixture "light" "true"
  touch "$SANDBOX/trail/dod/.security-reviewed"
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_pass "RT-1(g) light+approved with security stamp present → commit should pass"
}

# ============================================================
# Case (h): security_tier: light + approved_by_user: true — P5 (.codex-reviewed)
#   is STILL required even when security stamp is skipped.
# ============================================================
test_h_light_approved_still_requires_codex_stamp() {
  local content
  content="$(_dod_content_with_routing "light" "true")"
  seed_dod "dod-2026-05-19-security-tier-test.md" "$content"
  # Intentionally NO .codex-reviewed and NO .security-reviewed
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "CODEX_STAMP_MISSING" \
    "RT-1(h) light+approved but no codex stamp → P5 still required (codex stamp is never skipped)"
}

# ============================================================
# Case (i): no DoD files at all (DoD_EXISTS=false)
#   → gate skips all stamp checks, commit passes.
# ============================================================
test_i_no_dod_skips_all_stamp_checks() {
  # No seed_dod call — trail/dod/ is empty.
  run_hook "$HOOK" "$COMMIT_INPUT"
  # Commit msg format is valid, stamps not checked → should pass
  assert_pass "RT-1(i) no DoD present → stamp checks skipped, commit passes"
}

# ============================================================
# Case (j): STALE-DOD BYPASS REGRESSION (codex Finding 2 / RT-1 fail-open)
#
# Setup: TWO DoDs —
#   dod-2026-05-19-aa-standard.md  → security_tier: standard
#     (has ## 범위 연결, so it qualifies as Tier 1 target)
#   dod-2026-05-19-zz-light.md     → security_tier: light + approved_by_user: true
#     (alphabetically LATER — the buggy glob loop "last-match-wins" selected this)
#
# A trail/dod/.active-dod marker points at the STANDARD DoD (Tier 1).
#
# With .codex-reviewed present and .security-reviewed absent:
#   Expected (post-fix): hook resolves the STANDARD DoD via select_active_dod
#                        → BLOCKED with SECURITY_STAMP_MISSING.
#   Pre-fix (buggy): glob loop last-match picks zz-light → BYPASS (fail-open).
# ============================================================
test_j_stale_dod_bypass_regression() {
  # DoD 1: standard — the authoritative active one, pointed at by .active-dod.
  # Must carry ## 범위 연결 so select_active_dod Tier 1 resolves it.
  local std_content
  std_content=$(cat <<'DOD'
# DoD standard (active)

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: standard
rationale:
  - test fixture — stale-dod bypass regression
approved_by_user: true

## 범위 연결
plan ref: docs/plans/regression-test.md
covers: [regression-test-id]
DOD
  )
  seed_dod "dod-2026-05-19-aa-standard.md" "$std_content"

  # DoD 2: light+approved, alphabetically LATER (zz > aa).
  # The old glob loop would pick this one as "last match" and skip P6.
  local light_content
  light_content=$(cat <<'DOD'
# DoD light (stale, alphabetically later)

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: light
rationale:
  - test fixture — stale-dod bypass regression
approved_by_user: true
DOD
  )
  seed_dod "dod-2026-05-19-zz-light.md" "$light_content"

  # .active-dod marker → Tier 1: points at the STANDARD DoD.
  printf 'path=trail/dod/dod-2026-05-19-aa-standard.md\n' \
    > "$SANDBOX/trail/dod/.active-dod"

  # .codex-reviewed present — P5 is satisfied.
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  # NO .security-reviewed — P6 must block.

  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(j) stale-dod bypass: active=standard, stale-later=light → P6 must BLOCK (not bypass via glob)"
}

# ============================================================
# Case (k): SECTION-SCOPE REGRESSION (codex R2 HIGH / RT-1 fail-open)
#
# security_tier / approved_by_user must be read ONLY from the
# `## 라우팅 추천` section. A DoD with `security_tier: light` +
# `approved_by_user: true` placed OUTSIDE that section (here: as plain
# lines before it) must NOT grant the skip — the routing section itself
# declares `security_tier: standard`.
#
#   Expected (post-fix): awk scopes extraction to `## 라우팅 추천`
#                        → standard → BLOCKED with SECURITY_STAMP_MISSING.
#   Pre-fix (buggy): global `grep -m1` picks the first out-of-section
#                    `security_tier: light` → BYPASS (fail-open).
# ============================================================
test_k_out_of_section_tier_does_not_count() {
  local content
  content=$(cat <<'DOD'
# DoD section-scope regression

이 줄들은 ## 라우팅 추천 섹션 밖이다 — 게이트가 무시해야 한다:
security_tier: light
approved_by_user: true

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: standard
rationale:
  - test fixture — section-scope regression
approved_by_user: true

## 범위 연결
plan ref: docs/plans/section-scope-test.md
covers: [section-scope-id]
DOD
  )
  seed_dod "dod-2026-05-19-section-scope-test.md" "$content"
  printf 'path=trail/dod/dod-2026-05-19-section-scope-test.md\n' \
    > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  # NO .security-reviewed — routing section is standard → P6 must block.
  run_hook "$HOOK" "$COMMIT_INPUT"
  assert_json_deny "SECURITY_STAMP_MISSING" \
    "RT-1(k) out-of-section security_tier:light must NOT count — routing section is standard → P6 must BLOCK"
}

main() {
  run_test test_a_light_approved_passes_without_security_stamp     "$HOOK"
  run_test test_b_standard_still_requires_security_stamp           "$HOOK"
  run_test test_c_light_not_approved_still_requires_security_stamp "$HOOK"
  run_test test_d_no_security_tier_field_requires_security_stamp   "$HOOK"
  run_test test_e_garbage_security_tier_fails_closed               "$HOOK"
  run_test test_f_deep_still_requires_security_stamp               "$HOOK"
  run_test test_g_light_approved_with_security_stamp_also_passes   "$HOOK"
  run_test test_h_light_approved_still_requires_codex_stamp        "$HOOK"
  run_test test_i_no_dod_skips_all_stamp_checks                    "$HOOK"
  run_test test_j_stale_dod_bypass_regression                      "$HOOK"
  run_test test_k_out_of_section_tier_does_not_count               "$HOOK"
  summary
}

main
