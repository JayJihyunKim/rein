#!/bin/bash
# tests/hooks/test-session-start-tone.sh
#
# Task 3.3: SessionStart additionalContext banner assistant-tone verification.
#
# Tests assert the NEW assistant-tone strings are present and the OLD
# imperative/jargon strings are absent. Before the hook rewrite these tests
# fail (RED); after the rewrite they pass (GREEN). Data content is preserved.
#
# Scenarios:
#   T1 — heal failure notice:   OLD "rein-heal-legacy-pending 실패 (rc=…)" bare
#                               NEW natural sentence with "확인" + log path hint
#   T2 — spec review notice:    OLD "소스 편집 전 `/codex-review` 로 리뷰하거나 대체 경로로 해소 필요."
#                               NEW sentence ending with period, natural flow
#   T3 — abnormal session end:  OLD "Stop hook 이 정상 실행되지 않았습니다."
#                               NEW first-person observation sentence
#   T4 — pending incidents:     OLD "**첫 source 편집 시도가 차단됩니다.**"
#                               NEW natural sentence without "차단됩니다" bluntness
#   T8 — bootstrap degraded:    OLD "rein: degraded mode — '...' is not a git repo."
#                               NEW natural sentence without "degraded mode" jargon
#
# (T5–T7 — skill/MCP regen + scan failure tone — retired 2026-05-18 with the
#  smart-routing A+ refactor that removed the inventory scanner subsystem.
#  The hook no longer emits those messages, so there is nothing to tone-check.)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# ---- helpers ----------------------------------------------------------------

seed_project_json() {
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/project.json" <<'JSON'
{"mode":"plugin","scope":"project","version":"test"}
JSON
}

seed_index() {
  printf '# Project Index\n- task: placeholder\n' > "$SANDBOX/trail/index.md"
}

assert_stdout_contains() {
  local pattern="$1"
  local msg="${2:-stdout missing expected pattern: $pattern}"
  echo "$HOOK_STDOUT" | grep -qF "$pattern" || fail "$msg"
}

assert_stdout_not_contains() {
  local pattern="$1"
  local msg="${2:-stdout must not contain old pattern: $pattern}"
  echo "$HOOK_STDOUT" | grep -qF "$pattern" && fail "$msg" || true
}

# ---- T1: heal failure — OLD "rein-heal-legacy-pending 실패 (rc=$RC)" bare ------
# The OLD message is:
#   "### ⚠️ rein-heal-legacy-pending 실패 (rc=$HEAL_RC) — $HEAL_LOG 참조"
# NEW message should use a natural sentence pattern, e.g.
#   "### 세션 준비 작업 일부가 완료되지 않았습니다"
# We trigger the failure by providing a broken HEAL_SCRIPT path reference.
# In sandbox, HEAL_SCRIPT resolves empty → heal is skipped → no failure notice.
# Instead we test the message strings directly by grepping the hook source for
# the old/new patterns (source-level tone check).
test_T1_heal_failure_message_rewritten() {
  local hook_src
  hook_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh"

  # OLD pattern must not appear in hook source (removed by rewrite)
  grep -qF "rein-heal-legacy-pending 실패 (rc=" "$hook_src" \
    && fail "T1: OLD bare 'rein-heal-legacy-pending 실패 (rc=...' still present in hook source"

  # NEW pattern must appear (natural assistant-tone sentence)
  grep -qF "세션 준비 작업 일부가 완료되지 않았습니다" "$hook_src" \
    || fail "T1: NEW assistant-tone heal failure sentence missing in hook source"
}

# ---- T2: spec review notice — OLD bare action suffix -------------------------
# OLD: "소스 편집 전 `/codex-review` 로 리뷰하거나 대체 경로로 해소 필요."
# NEW: natural sentence, e.g. "리뷰를 먼저 완료해 주세요"
test_T2_spec_review_message_rewritten() {
  local hook_src
  hook_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh"

  # OLD bare imperative suffix must be gone
  grep -qF "대체 경로로 해소 필요." "$hook_src" \
    && fail "T2: OLD '대체 경로로 해소 필요.' still present in hook source"

  # NEW pattern must appear
  grep -qF "리뷰를 먼저 완료해 주세요" "$hook_src" \
    || fail "T2: NEW assistant-tone spec review sentence missing in hook source"
}

# ---- T3: abnormal session end — OLD jargon-heavy sentence --------------------
# OLD: "마지막 aggregate 이후 Stop hook 이 정상 실행되지 않았습니다."
# NEW: natural, e.g. "지난 세션이 예상치 못하게 종료됐을 수 있습니다."
test_T3_abnormal_session_message_rewritten() {
  local hook_src
  hook_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh"

  grep -qF "Stop hook 이 정상 실행되지 않았습니다" "$hook_src" \
    && fail "T3: OLD 'Stop hook 이 정상 실행되지 않았습니다' still present in hook source"

  grep -qF "지난 세션이 예상치 못하게 종료됐을 수 있습니다" "$hook_src" \
    || fail "T3: NEW assistant-tone abnormal-session sentence missing in hook source"
}

# ---- T4: pending incidents — OLD blunt "차단됩니다" imperative ----------------
# OLD: "**첫 source 편집 시도가 차단됩니다.** `incidents-to-rule` 스킬 호출 + AskUserQuestion 으로 처리하세요."
# NEW: natural, e.g. "편집을 시작하기 전에 미처리 incident 를 처리해 주세요."
test_T4_pending_incidents_message_rewritten() {
  local hook_src
  hook_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh"

  grep -qF "첫 source 편집 시도가 차단됩니다" "$hook_src" \
    && fail "T4: OLD '첫 source 편집 시도가 차단됩니다' still present in hook source"

  grep -qF "편집을 시작하기 전에" "$hook_src" \
    || fail "T4: NEW assistant-tone pending-incident sentence missing in hook source"
}

# ---- T8: bootstrap degraded messages — OLD "degraded mode" jargon -----------
# OLD (bootstrap.sh line 84): "rein: degraded mode (REIN_NO_AUTO_BOOTSTRAP=1). Gates inactive for this session."
# OLD (bootstrap.sh line 106): "rein: degraded mode — '...' is not a git repo. ..."
# NEW: natural sentences without "degraded mode" jargon
test_T8_bootstrap_messages_rewritten() {
  local hook_src
  hook_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/session-start-bootstrap.sh"

  grep -qF "degraded mode (REIN_NO_AUTO_BOOTSTRAP=1)" "$hook_src" \
    && fail "T8: OLD 'degraded mode (REIN_NO_AUTO_BOOTSTRAP=1)' still present in bootstrap hook"

  grep -qF "degraded mode — '" "$hook_src" \
    && fail "T8: OLD 'degraded mode — ''' still present in bootstrap hook"

  # NEW: natural sentence for opt-out case
  grep -qF "감시 기능이 이번 세션에서 비활성화됩니다" "$hook_src" \
    || fail "T8: NEW assistant-tone opt-out sentence missing in bootstrap hook"

  # NEW: natural sentence for non-git case
  grep -qF "git 저장소가 아닙니다" "$hook_src" \
    || fail "T8: NEW assistant-tone non-git sentence missing in bootstrap hook"
}

# ---- Runtime tone checks: actually run the hook and verify output ------------

# T9: spec review runtime — section header emitted, natural action guidance
test_T9_spec_review_runtime_natural_guidance() {
  seed_project_json
  seed_index
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  cat > "$SANDBOX/trail/dod/.spec-reviews/test-spec.pending" <<'MARKER'
path=docs/specs/test-spec.md
created=2026-05-17T10:00:00Z
MARKER

  run_hook "session-start-load-trail.sh"
  assert_exit 0

  # Data: count must still be emitted
  assert_stdout_contains "미해결 spec review"

  # Tone: old bare suffix must not appear in output
  assert_stdout_not_contains "대체 경로로 해소 필요."
  # Tone: new natural guidance must appear
  assert_stdout_contains "리뷰를 먼저 완료해 주세요"
}

# T10: main banner runtime — natural narrative sentences present
test_T10_main_banner_runtime_natural_sentences() {
  seed_project_json
  seed_index
  run_hook "session-start-load-trail.sh"
  assert_exit 0

  # Data: header must be present
  assert_stdout_contains "trail 세션 시작 컨텍스트"

  # Freshness notice must still reference git commands (data unchanged)
  assert_stdout_contains "git status"

  # Old jargon phrases must not appear in banner area
  assert_stdout_not_contains "bulk trail off" \
    "main banner must not use internal 'bulk trail off' jargon"
  assert_stdout_not_contains "ceremony 생략" \
    "main banner must not use internal 'ceremony 생략' jargon"
}

# ---- main -------------------------------------------------------------------
# Source-level tone checks (T1–T4, T8): verify hook source has been rewritten
run_test test_T1_heal_failure_message_rewritten
run_test test_T2_spec_review_message_rewritten
run_test test_T3_abnormal_session_message_rewritten
run_test test_T4_pending_incidents_message_rewritten
run_test test_T8_bootstrap_messages_rewritten
# Runtime output checks (T9–T10): verify hook output is assistant-tone
run_test test_T9_spec_review_runtime_natural_guidance  session-start-load-trail.sh
run_test test_T10_main_banner_runtime_natural_sentences session-start-load-trail.sh

summary
