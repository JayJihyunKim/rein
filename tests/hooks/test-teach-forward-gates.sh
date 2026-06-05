#!/bin/bash
# tests/hooks/test-teach-forward-gates.sh
#
# ONBOARD-1 Phase 2 regressions — teach-forward block messages for the three
# core gates in pre-edit-dod-gate.sh.
#
# Covers Scope IDs:
#   SCOPE-TEST-GATE-NEXTSTEP — DoD-absent / routing-approval / unreviewed-spec
#     block messages each contain numbered next steps (≤2) + exit 2 preserved.
#   SCOPE-TEST-HINT — routing-approval message contains the approval-line format
#     hint AND the hint's "recognized / not recognized" claims agree with the
#     shared regex (pre-edit-dod-gate.sh:752) applied directly.
#
# Strategy: the shared sandbox harness triggers each gate in isolation by
# shaping the trail/dod + .spec-reviews state, then asserts stderr + exit 2.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# Shared approval-line regex — copied verbatim from pre-edit-dod-gate.sh:752
# (and post-edit-dod-routing-check.sh:85). The hint's pass/fail claims must
# agree with THIS regex.
APPROVAL_RE='^[[:space:]]*approved_by_user:[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$'

_make_input() {
  # $1 = source file path inside sandbox (relative)
  printf '{"tool_input":{"file_path":"%s"}}' "$SANDBOX/$1"
}

# Helper: assert stderr contains a numbered next-step pattern (1) and 2)) and
# at most 2 such numbered steps (≤2 per spec).
_assert_two_numbered_steps() {
  local label="$1"
  echo "$HOOK_STDERR" | grep -qE '(^|[[:space:]])1\)' || fail "$label: missing step '1)'"
  echo "$HOOK_STDERR" | grep -qE '(^|[[:space:]])2\)' || fail "$label: missing step '2)'"
  # No '3)' numbered step (keep next steps ≤2).
  if echo "$HOOK_STDERR" | grep -qE '(^|[[:space:]])3\)'; then
    fail "$label: more than 2 numbered next steps (found '3)')"
  fi
}

# ---- Scenario A: DoD-absent gate teach-forward (line ~893)
test_dod_absent_teach_forward() {
  # No DoD files, no spec-reviews, no incidents → DoD-absent block.
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "DoD-absent → block (exit 2 preserved)"
  assert_stderr_contains "no active task record"
  assert_stderr_contains "trail/dod/dod-"
  _assert_two_numbered_steps "DoD-absent"
}

# ---- Scenario B: routing-approval gate teach-forward + format hint (line ~766)
test_routing_approval_teach_forward_and_hint() {
  # An active DoD (new format, no inbox match) with a '## 라우팅 추천' section
  # but NO approval line → routing-approval block.
  cat > "$SANDBOX/trail/dod/dod-2026-06-05-rt.md" <<'EOF'
# DoD rt
## 라우팅 추천
agent: feature-builder
skills: []
mcps: []
rationale: sample
approved_by_user: false
EOF
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "routing-approval → block (exit 2 preserved)"
  assert_stderr_contains "without user approval"
  _assert_two_numbered_steps "routing-approval"
  # SCOPE-TEST-HINT (a): the format hint text is present.
  assert_stderr_contains "Approval line format"
  assert_stderr_contains "no quotes"
  assert_stderr_contains "Not recognized"

  # SCOPE-TEST-HINT (b): the hint's claims agree with the shared regex.
  # Forms the hint says ARE recognized → regex must PASS.
  local f
  for f in \
    'approved_by_user: true' \
    '  approved_by_user: true' \
    'approved_by_user: true # confirmed' ; do
    if ! printf '%s\n' "$f" | grep -qE "$APPROVAL_RE"; then
      fail "hint regex parity: form claimed recognized but regex rejected: [$f]"
    fi
  done
  # Forms the hint says are NOT recognized → regex must FAIL.
  for f in \
    '- approved_by_user: true' \
    '**approved_by_user: true**' \
    'approved_by_user: "true"' ; do
    if printf '%s\n' "$f" | grep -qE "$APPROVAL_RE"; then
      fail "hint regex parity: form claimed NOT recognized but regex accepted: [$f]"
    fi
  done
}

# ---- Scenario C: unreviewed-spec gate teach-forward (line ~665)
test_unreviewed_spec_teach_forward() {
  # A .spec-reviews/<hash>.pending pointing at an existing spec, with no
  # matching .reviewed → unreviewed-spec block.
  mkdir -p "$SANDBOX/docs/specs" "$SANDBOX/trail/dod/.spec-reviews"
  cat > "$SANDBOX/docs/specs/sample-spec.md" <<'EOF'
# sample spec
body
EOF
  cat > "$SANDBOX/trail/dod/.spec-reviews/deadbeef.pending" <<EOF
path=$SANDBOX/docs/specs/sample-spec.md
created=2026-06-05T00:00:00
EOF
  # Edit a NON-test source file so the tests/ TDD exemption does not apply.
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "unreviewed-spec → block (exit 2 preserved)"
  assert_stderr_contains "has not been reviewed yet"
  assert_stderr_contains "rein-mark-spec-reviewed.sh"
  _assert_two_numbered_steps "unreviewed-spec"
}

main() {
  run_test test_dod_absent_teach_forward                   pre-edit-dod-gate.sh
  run_test test_routing_approval_teach_forward_and_hint    pre-edit-dod-gate.sh
  run_test test_unreviewed_spec_teach_forward              pre-edit-dod-gate.sh
  summary
}

main "$@"
