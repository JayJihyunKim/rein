#!/bin/bash
# tests/hooks/test-teach-forward-gates.sh
#
# ONBOARD-1 Phase 2 regressions — teach-forward block messages for the core
# gates that used to live together in pre-edit-dod-gate.sh.
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대, 2026-08-21): pre-edit-dod-gate.sh 는
# 삭제되고 pre-edit-discipline-gate.sh + pre-edit-task-gate.sh 로 교대된다.
#
# Covers Scope IDs:
#   SCOPE-TEST-GATE-NEXTSTEP — DoD-absent / routing-approval / unreviewed-spec
#     block messages each contain numbered next steps (≤2) + exit 2 preserved.
#   SCOPE-TEST-HINT — routing-approval message contains the approval-line format
#     hint AND the hint's "recognized / not recognized" claims agree with the
#     shared regex (now pre-edit-discipline-gate.sh) applied directly.
#
# Scenario B (routing-approval) and C (unreviewed-spec) exercise
# routing-gate/spec-review-gate — both explicitly discipline-gate's axes per
# the rotation contract, unaffected by the active-task retirement. They keep
# their original teach-forward assertions verbatim, just retargeted.
#
# Scenario A (DoD-absent) is different in kind: its "no active task record"
# teach-forward message was owned by the OLD v1 active-task fallback
# judgment (hooks/lib/active-task-gate.sh's final `else` branch), which is
# retired wholesale by the rotation — task-gate's contract has NO v1 fallback
# ("구 v1 폴백 판정 소멸"); its blocking paths are exclusively (i) a v2 DENY
# relay (a generic evaluator reason, no numbered next-steps — see
# tests/hooks/test-active-task-authority-switch.sh's assert_v1_relayed_v2_deny
# for why that reason text can never carry this teach-forward UX) or (ii) a
# fail-closed exit 2 when delegation/switch-check itself cannot run. This
# default sandbox links no rein package/bin, so it lands in (ii) — but the
# specific "no active task record" / "trail/dod/dod-" / numbered-steps wording
# is NOT reproduced by that fail-closed path (it is new code, not a
# preserved copy of the old message). We keep the scenario as a
# characterization of the fail-closed *direction* (still exit 2, still
# assistant-toned) without asserting the retired message's exact shape.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# Shared approval-line regex — copied verbatim from pre-edit-discipline-gate.sh
# (and post-edit-dod-routing-check.sh). The hint's pass/fail claims must
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

# ---- Scenario A: task-gate fail-closed path (formerly "DoD-absent" v1
# teach-forward). See file header for why the message assertions are
# relaxed to exit-code + assistant-tone rather than the retired exact text.
test_task_gate_no_active_task_axis_fails_closed_in_default_sandbox() {
  # No DoD files, no rein package/bin linked → the axis's switch-check
  # cannot even run → fail-closed (exit 2), not a v1-style teach-forward
  # block. (This is new case (a)/(switch-state-read-failure) territory —
  # see tests/hooks/test-pre-edit-task-gate.sh and
  # tests/hooks/test-active-task-authority-switch.sh scenario (f) for the
  # dedicated coverage of that exact path.)
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-task-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "no active-task axis available in a default sandbox → fail-closed (exit 2 preserved)"
  [ -n "$HOOK_STDERR" ] || fail "task-gate fail-closed path must still say something on stderr"
  echo "$HOOK_STDERR" | grep -qF "[rein]" || fail "task-gate fail-closed stderr missing '[rein]' prefix"
}

# ---- Scenario B: routing-approval gate teach-forward + format hint
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

  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/foo.sh)"

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

# ---- Scenario C: unreviewed-spec gate teach-forward
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
  # GSD-2 (2026-08-05): 미리뷰 차단은 활성 작업이 참조하는 문서에만 발동한다.
  # 이 시나리오의 관심사(차단 메시지의 teach-forward 형식)를 새 계약 위에서
  # 유지하도록, 문서를 참조하는 활성 DoD 를 심는다.
  seed_dod "dod-2026-06-05-sample.md" '# DoD: sample
- 설계: docs/specs/sample-spec.md'
  # Edit a NON-test source file so the tests/ TDD exemption does not apply.
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "unreviewed-spec → block (exit 2 preserved)"
  assert_stderr_contains "has not been reviewed yet"
  assert_stderr_contains "rein-mark-spec-reviewed.sh"
  _assert_two_numbered_steps "unreviewed-spec"
}

main() {
  run_test test_task_gate_no_active_task_axis_fails_closed_in_default_sandbox pre-edit-task-gate.sh
  run_test test_routing_approval_teach_forward_and_hint    pre-edit-discipline-gate.sh
  run_test test_unreviewed_spec_teach_forward              pre-edit-discipline-gate.sh
  summary
}

main "$@"
