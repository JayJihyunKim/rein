#!/bin/bash
# tests/hooks/test-state-fast-path-skip.sh — Cycle X4.C.3
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md
#   §8.4 산출물 (X4.C.3 — hook 별 state read + fast-path skip):
#     T1 (a) pre-edit-dod-gate: state.mode=source_edit + file in dirty_files
#             → DoD validator subprocess skip (NOTICE 출력)
#     T2 (b) post-edit-design-plan-coverage-rule: effective_mode=answer
#             → envelope inject skip (stdout 빈)
#     T3 (c) post-edit-routing-procedure-rule: effective_mode=answer
#             → envelope inject skip
#     T4 (d) post-edit-spec-review-gate: 같은 spec 의 .pending marker 이미 존재
#             → re-write 없음 (mtime 동일)
#     T5 fail-soft: state-machine.sh 부재 시 4 hook 모두 legacy path (회귀 0)

set -u

REAL_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="$REAL_PROJECT_DIR/plugins/rein-core"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
CURRENT_FAILS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && return 0
  echo "  FAIL [$label]: expected='$expected' actual='$actual'" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) return 0 ;;
  esac
  echo "  FAIL [$label]: '$needle' not found in output" >&2
  echo "    haystack: $haystack" >&2
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  FAIL [$label]: '$needle' unexpectedly found in output" >&2
      echo "    haystack: $haystack" >&2
      CURRENT_FAILS=$((CURRENT_FAILS + 1))
      return 1
      ;;
  esac
  return 0
}
start_test() { CURRENT_TEST="$1"; CURRENT_FAILS=0; echo "TEST: $CURRENT_TEST"; }
end_test() {
  if [ "$CURRENT_FAILS" -eq 0 ]; then PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS"
  else FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
mk_sandbox() {
  SANDBOX=$(mktemp -d "/tmp/state-fastpath-XXXXXX")
  export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
}
rm_sandbox() {
  unset REIN_PROJECT_DIR_OVERRIDE
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# Seed state.json with given mode + dirty_files (array of abs paths).
# dirty_files schema = list of {"path": ..., "kind": ...} per state-machine.sh
# drain_state output (kind 은 본 test 의 핵심 contract 아님 — 임의 "source").
seed_state() {
  local mode="$1"; shift
  mkdir -p "$SANDBOX/.rein"
  python3 - "$mode" "$SANDBOX/.rein/state.json" "$@" <<'PY'
import json, sys
mode = sys.argv[1]
out_path = sys.argv[2]
paths = list(sys.argv[3:])
# Complete schema-v1 document (design memo §2 required fields) so state_is_valid
# accepts it — fast-path engages. updated_at is required; optional fields omitted.
state = {
    "schema_version": 1,
    "mode": mode,
    "updated_at": "2026-05-21T00:00:00Z",
    "dirty_files": [{"path": p, "kind": "source"} for p in paths],
    "last_drain_seq": 0,
}
with open(out_path, "w") as f:
    json.dump(state, f)
PY
}

# T1: pre-edit-dod-gate fast-path skip on dirty_files match.
# Scenario: state.mode=source_edit + dirty_files=[abs(scripts/foo.py)],
# Edit on scripts/foo.py → validator subprocess skipped (stderr NOTICE).
t1_pre_edit_dod_gate_fast_path() {
  start_test "T1: pre-edit-dod-gate fast-path skip when mode=source_edit + file in dirty_files"
  mk_sandbox
  # Required scaffold: active DoD + plan + 매트릭스 (validator 가 통과되려면 일관성 필요)
  mkdir -p "$SANDBOX/trail/dod" "$SANDBOX/trail/inbox" "$SANDBOX/scripts" \
           "$SANDBOX/docs/plans" "$SANDBOX/docs/specs"
  cat > "$SANDBOX/scripts/foo.py" <<'PY'
print("hello")
PY
  cat > "$SANDBOX/trail/dod/dod-2026-05-21-fastpath-test.md" <<'EOF'
# DoD
- 날짜: 2026-05-21
## 범위 연결
plan ref: docs/plans/2026-05-21-fastpath-test.md
work unit: Phase 1
covers: [A1]
## 라우팅 추천
```yaml
agent: rein:feature-builder
skills: []
mcps: []
approved_by_user: true
```
EOF
  cat > "$SANDBOX/docs/specs/2026-05-21-fastpath-test.md" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  cat > "$SANDBOX/docs/plans/2026-05-21-fastpath-test.md" <<'EOF'
## Design 범위 커버리지 매트릭스
> design ref: docs/specs/2026-05-21-fastpath-test.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|-----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
  ABS="$SANDBOX/scripts/foo.py"
  seed_state "source_edit" "$ABS"

  local input
  input=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))
' "$ABS")

  local stderr
  stderr=$(printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
             REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/pre-edit-dod-gate.sh" 2>&1 >/dev/null)
  local rc=$?
  assert_eq "exit_rc" "0" "$rc"
  assert_contains "fast_path_notice" "$stderr" "state.fast-path"
  end_test
  rm_sandbox
}

# T2: post-edit-design-plan-coverage-rule fast-path skip when mode=answer.
t2_post_edit_design_plan_coverage_rule_skip() {
  start_test "T2: post-edit-design-plan-coverage-rule skip envelope when effective_mode=answer"
  mk_sandbox
  seed_state "answer"
  mkdir -p "$SANDBOX/docs/specs"
  local input='{"tool_input":{"file_path":"docs/specs/test.md"},"tool_use_id":"t2"}'
  local stdout
  stdout=$(printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
             REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null)
  local rc=$?
  assert_eq "exit_rc" "0" "$rc"
  assert_not_contains "no_envelope" "$stdout" "hookSpecificOutput"
  end_test
  rm_sandbox
}

# T3: post-edit-routing-procedure-rule fast-path skip when mode=answer.
t3_post_edit_routing_procedure_rule_skip() {
  start_test "T3: post-edit-routing-procedure-rule skip envelope when effective_mode=answer"
  mk_sandbox
  seed_state "answer"
  mkdir -p "$SANDBOX/trail/dod"
  local dod_path="$SANDBOX/trail/dod/dod-2026-05-21-t3.md"
  printf '# DoD\n' > "$dod_path"
  local input
  input=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}, "tool_use_id": "t3"}))
' "$dod_path")
  local stdout
  stdout=$(printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
             REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null)
  local rc=$?
  assert_eq "exit_rc" "0" "$rc"
  assert_not_contains "no_envelope" "$stdout" "hookSpecificOutput"
  end_test
  rm_sandbox
}

# T4: post-edit-spec-review-gate marker 중복 생성 skip — 동일 spec 의 .pending
# marker 가 이미 존재하면 mtime 만 갱신 (file body 변경 없음).
t4_post_edit_spec_review_gate_marker_dedup() {
  start_test "T4: post-edit-spec-review-gate skip re-write when .pending marker exists"
  mk_sandbox
  mkdir -p "$SANDBOX/docs/specs" "$SANDBOX/trail/dod/.spec-reviews"
  local spec_path="$SANDBOX/docs/specs/dummy.md"
  cat > "$spec_path" <<'EOF'
# spec
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  # First invocation: marker should be created.
  local input
  input=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))
' "$spec_path")
  printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$PLUGIN_ROOT/hooks/post-edit-spec-review-gate.sh" >/dev/null 2>&1
  # Capture marker content + mtime.
  local marker
  marker=$(ls "$SANDBOX/trail/dod/.spec-reviews/"*.pending 2>/dev/null | head -1)
  if [ -z "$marker" ] || [ ! -f "$marker" ]; then
    echo "  FAIL [marker_created]: .pending marker not created on first call" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
    end_test; rm_sandbox; return
  fi
  local content_before mtime_before
  content_before=$(cat "$marker")
  # Set mtime backwards by 2s so we can detect touch.
  python3 -c '
import os, sys
os.utime(sys.argv[1], (1, 1))
' "$marker"
  mtime_before=$(stat -f '%m' "$marker" 2>/dev/null || stat -c '%Y' "$marker")
  # Seed state so fast-path may apply (mode=source_edit; dirty_files not required for dedup).
  seed_state "source_edit" "$spec_path"
  # Second invocation: marker should be touched (mtime updated) but body unchanged.
  printf '%s' "$input" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$PLUGIN_ROOT/hooks/post-edit-spec-review-gate.sh" >/dev/null 2>&1
  local content_after mtime_after
  content_after=$(cat "$marker")
  mtime_after=$(stat -f '%m' "$marker" 2>/dev/null || stat -c '%Y' "$marker")
  assert_eq "body_unchanged" "$content_before" "$content_after"
  # mtime must increase (touch occurred — fast-path 또는 정상 path 모두 mtime 갱신).
  if [ "$mtime_after" -le "$mtime_before" ]; then
    echo "  FAIL [mtime_touched]: mtime_before=$mtime_before mtime_after=$mtime_after" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  end_test
  rm_sandbox
}

# T5: fail-soft — state-machine.sh 부재 시 4 hook 모두 legacy path (회귀 0).
t5_hooks_fail_soft_when_lib_absent() {
  start_test "T5: 4 patched hooks fail-soft when state-machine.sh absent"
  mk_sandbox
  # Construct sandbox plugin root without state-machine.sh.
  local SANDBOX_PLUGIN="$SANDBOX/plugin"
  mkdir -p "$SANDBOX_PLUGIN/hooks/lib" "$SANDBOX_PLUGIN/scripts" \
           "$SANDBOX_PLUGIN/rules" "$SANDBOX_PLUGIN/rules/short"
  cp -R "$PLUGIN_ROOT/hooks/"*.sh "$SANDBOX_PLUGIN/hooks/" 2>/dev/null || true
  cp -R "$PLUGIN_ROOT/hooks/lib/"*.sh "$SANDBOX_PLUGIN/hooks/lib/" 2>/dev/null || true
  cp -R "$PLUGIN_ROOT/hooks/lib/"*.py "$SANDBOX_PLUGIN/hooks/lib/" 2>/dev/null || true
  cp -R "$PLUGIN_ROOT/scripts/"* "$SANDBOX_PLUGIN/scripts/" 2>/dev/null || true
  cp -R "$PLUGIN_ROOT/rules/"* "$SANDBOX_PLUGIN/rules/" 2>/dev/null || true
  # Explicit absence:
  rm -f "$SANDBOX_PLUGIN/hooks/lib/state-machine.sh"

  mkdir -p "$SANDBOX/trail/dod" "$SANDBOX/trail/inbox" \
           "$SANDBOX/scripts" "$SANDBOX/docs/specs" "$SANDBOX/docs/plans"
  local dod_path="$SANDBOX/trail/dod/dod-2026-05-21-t5.md"
  printf '# DoD\n' > "$dod_path"

  local rcs=""
  # 5.1 post-edit-design-plan-coverage-rule (legacy: emits envelope for spec path)
  local out_dpc
  out_dpc=$(printf '{"tool_input":{"file_path":"docs/specs/x.md"},"tool_use_id":"t5"}' \
            | env CLAUDE_PLUGIN_ROOT="$SANDBOX_PLUGIN" \
              REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
              bash "$SANDBOX_PLUGIN/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null; echo "rc=$?")
  local dpc_rc dpc_stdout
  dpc_rc=$(echo "$out_dpc" | tail -1 | sed 's/^rc=//')
  dpc_stdout=$(echo "$out_dpc" | sed '$d')
  rcs="$rcs dpc=$dpc_rc"
  if [ "$dpc_rc" != "0" ]; then
    echo "  FAIL [post-edit-design-plan-coverage-rule fail-soft]: rc=$dpc_rc" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  # legacy contract: envelope (hookSpecificOutput) emitted for matching spec path.
  case "$dpc_stdout" in
    *hookSpecificOutput*) ;;
    *)
      echo "  FAIL [post-edit-design-plan-coverage-rule legacy envelope]: missing hookSpecificOutput" >&2
      CURRENT_FAILS=$((CURRENT_FAILS + 1))
      ;;
  esac

  # 5.2 post-edit-routing-procedure-rule (legacy: emits envelope for DoD without 라우팅 추천)
  local out_rt
  out_rt=$(printf '%s' '{"tool_input":{"file_path":"'"$dod_path"'"},"tool_use_id":"t5"}' \
            | env CLAUDE_PLUGIN_ROOT="$SANDBOX_PLUGIN" \
              REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
              bash "$SANDBOX_PLUGIN/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null; echo "rc=$?")
  local rt_rc rt_stdout
  rt_rc=$(echo "$out_rt" | tail -1 | sed 's/^rc=//')
  rt_stdout=$(echo "$out_rt" | sed '$d')
  rcs="$rcs rt=$rt_rc"
  if [ "$rt_rc" != "0" ]; then
    echo "  FAIL [post-edit-routing-procedure-rule fail-soft]: rc=$rt_rc" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  case "$rt_stdout" in
    *hookSpecificOutput*) ;;
    *)
      echo "  FAIL [post-edit-routing-procedure-rule legacy envelope]: missing hookSpecificOutput" >&2
      CURRENT_FAILS=$((CURRENT_FAILS + 1))
      ;;
  esac

  # 5.3 post-edit-spec-review-gate (legacy: creates .pending marker)
  local spec_path="$SANDBOX/docs/specs/dummy.md"
  cat > "$spec_path" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  local input2
  input2=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))
' "$spec_path")
  local out_sr
  out_sr=$(printf '%s' "$input2" | env CLAUDE_PLUGIN_ROOT="$SANDBOX_PLUGIN" \
           REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
           bash "$SANDBOX_PLUGIN/hooks/post-edit-spec-review-gate.sh" 2>/dev/null; echo "rc=$?")
  local sr_rc
  sr_rc=$(echo "$out_sr" | tail -1 | sed 's/^rc=//')
  rcs="$rcs sr=$sr_rc"
  if [ "$sr_rc" != "0" ]; then
    echo "  FAIL [post-edit-spec-review-gate fail-soft]: rc=$sr_rc" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  local marker
  marker=$(ls "$SANDBOX/trail/dod/.spec-reviews/"*.pending 2>/dev/null | head -1)
  if [ -z "$marker" ]; then
    echo "  FAIL [legacy marker]: .pending marker missing when state-machine.sh absent" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi

  # 5.4 pre-edit-dod-gate (legacy: validator subprocess runs, no fast-path skip)
  # 시나리오: state-machine.sh 부재 + dirty_files 매칭 의도 있어도 → legacy path.
  # 5.3 에서 생성한 .pending marker 가 spec-review gate 를 차단하므로 skip.
  touch "$SANDBOX/trail/dod/.skip-spec-gate"
  cat > "$SANDBOX/scripts/foo.py" <<'PY'
print("hello")
PY
  cat > "$dod_path" <<'EOF'
# DoD
- 날짜: 2026-05-21
## 범위 연결
plan ref: docs/plans/2026-05-21-t5.md
work unit: Phase 1
covers: [A1]
## 라우팅 추천
```yaml
agent: rein:feature-builder
skills: []
mcps: []
approved_by_user: true
```
EOF
  cat > "$SANDBOX/docs/specs/2026-05-21-t5.md" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  cat > "$SANDBOX/docs/plans/2026-05-21-t5.md" <<'EOF'
## Design 범위 커버리지 매트릭스
> design ref: docs/specs/2026-05-21-t5.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|-----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
  local ABS="$SANDBOX/scripts/foo.py"
  local input3
  input3=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))
' "$ABS")
  local out_pre stderr_pre
  stderr_pre=$(printf '%s' "$input3" | env CLAUDE_PLUGIN_ROOT="$SANDBOX_PLUGIN" \
              REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
              bash "$SANDBOX_PLUGIN/hooks/pre-edit-dod-gate.sh" 2>&1 >/dev/null)
  local pre_rc=$?
  rcs="$rcs pre=$pre_rc"
  if [ "$pre_rc" != "0" ]; then
    echo "  FAIL [pre-edit-dod-gate fail-soft]: rc=$pre_rc stderr='$stderr_pre'" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi
  # state-machine.sh 부재 → fast-path NOTICE 출력되지 않아야 함 (legacy path)
  assert_not_contains "no_fastpath_notice_when_lib_absent" "$stderr_pre" "state.fast-path"

  echo "  rcs:$rcs"
  end_test
  rm_sandbox
}

# T6: fail-soft — state.json 부재 (lib 존재) → 4 hook 모두 legacy path.
# codex Round 1 HIGH 회귀 검증: state.json 부재 환경에서 envelope 이 정상 발행되어야 함.
t6_hooks_fail_soft_when_state_file_absent() {
  start_test "T6: 4 patched hooks fail-soft when state.json absent (lib exists)"
  mk_sandbox
  # NOTE: state.json 을 만들지 않는다 (lib 만 존재). PLUGIN_ROOT 그대로 사용.
  mkdir -p "$SANDBOX/trail/dod" "$SANDBOX/trail/inbox" \
           "$SANDBOX/scripts" "$SANDBOX/docs/specs" "$SANDBOX/docs/plans"

  # 6.1 post-edit-design-plan-coverage-rule — envelope 정상 발행
  local out_dpc
  out_dpc=$(printf '{"tool_input":{"file_path":"docs/specs/x.md"},"tool_use_id":"t6"}' \
            | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
              REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
              bash "$PLUGIN_ROOT/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null)
  assert_contains "dpc_legacy_envelope" "$out_dpc" "hookSpecificOutput"

  # 6.2 post-edit-routing-procedure-rule — envelope 정상 발행
  local dod_path="$SANDBOX/trail/dod/dod-2026-05-21-t6.md"
  printf '# DoD\n' > "$dod_path"
  local out_rt
  out_rt=$(printf '%s' '{"tool_input":{"file_path":"'"$dod_path"'"},"tool_use_id":"t6"}' \
            | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
              REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
              bash "$PLUGIN_ROOT/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null)
  assert_contains "rt_legacy_envelope" "$out_rt" "hookSpecificOutput"

  # 6.3 post-edit-spec-review-gate — .pending marker 정상 생성
  local spec_path="$SANDBOX/docs/specs/dummy.md"
  cat > "$spec_path" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  local input2
  input2=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))
' "$spec_path")
  printf '%s' "$input2" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$PLUGIN_ROOT/hooks/post-edit-spec-review-gate.sh" >/dev/null 2>&1
  local marker
  marker=$(ls "$SANDBOX/trail/dod/.spec-reviews/"*.pending 2>/dev/null | head -1)
  if [ -z "$marker" ]; then
    echo "  FAIL [spec-review legacy marker]: .pending marker missing when state.json absent" >&2
    CURRENT_FAILS=$((CURRENT_FAILS + 1))
  fi

  # 6.4 pre-edit-dod-gate — state.json 부재 → fast-path NOTICE 없음, 정상 validator 경로
  cat > "$SANDBOX/scripts/foo.py" <<'PY'
print("hello")
PY
  cat > "$dod_path" <<'EOF'
# DoD
- 날짜: 2026-05-21
## 범위 연결
plan ref: docs/plans/2026-05-21-t6.md
work unit: Phase 1
covers: [A1]
## 라우팅 추천
```yaml
agent: rein:feature-builder
skills: []
mcps: []
approved_by_user: true
```
EOF
  cat > "$SANDBOX/docs/specs/2026-05-21-t6.md" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  cat > "$SANDBOX/docs/plans/2026-05-21-t6.md" <<'EOF'
## Design 범위 커버리지 매트릭스
> design ref: docs/specs/2026-05-21-t6.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|-----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
  local ABS="$SANDBOX/scripts/foo.py"
  local input3
  input3=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))
' "$ABS")
  local stderr_pre
  stderr_pre=$(printf '%s' "$input3" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
              REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
              bash "$PLUGIN_ROOT/hooks/pre-edit-dod-gate.sh" 2>&1 >/dev/null)
  assert_not_contains "no_fastpath_when_state_absent" "$stderr_pre" "state.fast-path"
  end_test
  rm_sandbox
}

# T7: malformed state.json → 두 envelope hook 은 legacy envelope 발행 (skip 금지).
# codex Round 2 HIGH 회귀 검증: read_state 가 corrupt state 에 echo 하는 default
# "answer" 를 fast-path skip 신호로 오인하면 안 됨. state_is_valid 게이트가
# malformed JSON 을 legacy fallback 으로 보낸다 (design memo §2.3 / §8.4).
t7_envelope_hooks_legacy_on_malformed_state() {
  start_test "T7: envelope hooks emit legacy envelope when state.json is malformed"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein" "$SANDBOX/docs/specs" "$SANDBOX/trail/dod"
  printf '%s' '{ this is not valid json ' > "$SANDBOX/.rein/state.json"

  # design-plan-coverage — docs/specs match → envelope 발행 기대
  local out_dpc
  out_dpc=$(printf '%s' '{"tool_input":{"file_path":"docs/specs/test.md"},"tool_use_id":"t7a"}' \
             | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
               bash "$PLUGIN_ROOT/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null)
  assert_contains "dpc_legacy_envelope" "$out_dpc" "hookSpecificOutput"

  # routing-procedure — DoD path match → envelope 발행 기대
  local dod_path="$SANDBOX/trail/dod/dod-2026-05-21-t7.md"
  printf '# DoD\n' > "$dod_path"
  local input_rt out_rt
  input_rt=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]},"tool_use_id":"t7b"}))' "$dod_path")
  out_rt=$(printf '%s' "$input_rt" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null)
  assert_contains "rt_legacy_envelope" "$out_rt" "hookSpecificOutput"
  end_test
  rm_sandbox
}

# T8: unknown schema_version (write-side > read-side) → 두 envelope hook legacy emit.
# design memo §2.3 forward-compat: 오래된 hook 이 새 schema 를 만나면 state 무시 +
# 자기 envelope 사용. read_state 의 default mode=answer 가 skip 으로 오인되면 안 됨.
t8_envelope_hooks_legacy_on_unknown_schema() {
  start_test "T8: envelope hooks emit legacy envelope when state.json schema_version unknown"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein" "$SANDBOX/docs/specs" "$SANDBOX/trail/dod"
  printf '%s' '{"schema_version":2,"mode":"answer","dirty_files":[],"last_drain_seq":0}' > "$SANDBOX/.rein/state.json"

  local out_dpc
  out_dpc=$(printf '%s' '{"tool_input":{"file_path":"docs/specs/test.md"},"tool_use_id":"t8a"}' \
             | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
               bash "$PLUGIN_ROOT/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null)
  assert_contains "dpc_legacy_envelope" "$out_dpc" "hookSpecificOutput"

  local dod_path="$SANDBOX/trail/dod/dod-2026-05-21-t8.md"
  printf '# DoD\n' > "$dod_path"
  local input_rt out_rt
  input_rt=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]},"tool_use_id":"t8b"}))' "$dod_path")
  out_rt=$(printf '%s' "$input_rt" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null)
  assert_contains "rt_legacy_envelope" "$out_rt" "hookSpecificOutput"
  end_test
  rm_sandbox
}

# T9: lock-acquire 실패 → 두 envelope hook legacy emit (skip 금지).
# codex Round 3 HIGH 회귀: read_effective_mode 는 lock 실패 시 stdout 에 "answer"
# 를 출력하고 non-zero 로 종료. capture 가 exit status 를 무시하면 lock 실패에도
# fast-path skip 됨. 결정론적 lock-실패 주입 — 두 backend 모두 cover:
#   mkdir backend: state.lock.d 선점 + REIN_STATE_LOCK_TIMEOUT_MS=0 → 즉시 fail
#   flock backend: state.lock 를 디렉토리로 → `exec 9>state.lock` 실패
t9_envelope_hooks_legacy_on_lock_failure() {
  start_test "T9: envelope hooks emit legacy envelope when lock acquisition fails"
  mk_sandbox
  mkdir -p "$SANDBOX/docs/specs" "$SANDBOX/trail/dod"
  seed_state "answer"                   # valid state — lock 정상이면 skip 될 상태
  mkdir "$SANDBOX/.rein/state.lock.d"   # mkdir backend mutex 선점
  mkdir "$SANDBOX/.rein/state.lock"     # flock backend: exec 9>state.lock 실패 유도

  local out_dpc
  out_dpc=$(printf '%s' '{"tool_input":{"file_path":"docs/specs/test.md"},"tool_use_id":"t9a"}' \
             | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
               REIN_STATE_LOCK_TIMEOUT_MS=0 \
               bash "$PLUGIN_ROOT/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null)
  assert_contains "dpc_legacy_envelope_on_lock_fail" "$out_dpc" "hookSpecificOutput"

  local dod_path="$SANDBOX/trail/dod/dod-2026-05-21-t9.md"
  printf '# DoD\n' > "$dod_path"
  local input_rt out_rt
  input_rt=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]},"tool_use_id":"t9b"}))' "$dod_path")
  out_rt=$(printf '%s' "$input_rt" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             REIN_STATE_LOCK_TIMEOUT_MS=0 \
             bash "$PLUGIN_ROOT/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null)
  assert_contains "rt_legacy_envelope_on_lock_fail" "$out_rt" "hookSpecificOutput"
  end_test
  rm_sandbox
}

# T10: schema-v1 contract 위반 (필드 타입 깨짐 / 비-enum mode / required 필드 누락)
# → 두 envelope hook 은 legacy emit (skip 금지). state_is_valid 가 design memo §2
# required/optional contract 를 강제하므로, 불완전·corrupt state 의 mode 를 신뢰하지
# 않는다. 누적 회귀: R4 필드 타입, R5 mode enum, R6 required 필드 누락.
# 각 케이스는 한 축만 깨뜨려 그 축의 검증을 격리 (나머지는 valid + updated_at 포함).
t10_envelope_hooks_legacy_on_invalid_state() {
  start_test "T10: envelope hooks emit legacy envelope for invalid/incomplete schema-v1 state"
  mk_sandbox
  mkdir -p "$SANDBOX/.rein" "$SANDBOX/docs/specs" "$SANDBOX/trail/dod"

  printf '# DoD\n' > "$SANDBOX/trail/dod/dod-2026-05-21-t10.md"  # routing glob match

  # 두 envelope hook 모두 주어진 (invalid) state.json 에서 legacy envelope 를
  # 발행하는지 — design-plan-coverage (docs/specs match) + routing (DoD match).
  # codex Round 7: 전 invalid-state 매트릭스를 두 hook 모두에 대해 검증 (이전엔
  # routing 이 비-enum mode 1 케이스만 받아 claim/coverage 불일치).
  _t10_both_emit() {  # $1=label  $2=state-json
    printf '%s' "$2" > "$SANDBOX/.rein/state.json"
    local out_d out_r
    out_d=$(printf '%s' '{"tool_input":{"file_path":"docs/specs/test.md"},"tool_use_id":"t10d"}' \
           | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/post-edit-design-plan-coverage-rule.sh" 2>/dev/null)
    assert_contains "${1}_dpc" "$out_d" "hookSpecificOutput"
    out_r=$(printf '%s' '{"tool_input":{"file_path":"trail/dod/dod-2026-05-21-t10.md"},"tool_use_id":"t10r"}' \
           | env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
             bash "$PLUGIN_ROOT/hooks/post-edit-routing-procedure-rule.sh" 2>/dev/null)
    assert_contains "${1}_rt" "$out_r" "hookSpecificOutput"
  }

  _t10_both_emit "bad_last_drain_seq"     '{"schema_version":1,"mode":"source_edit","updated_at":"","dirty_files":[],"last_drain_seq":"bad"}'  # R4
  _t10_both_emit "nonarray_dirty_files"   '{"schema_version":1,"mode":"answer","updated_at":"","dirty_files":"oops","last_drain_seq":0}'        # R4
  _t10_both_emit "nonenum_mode"           '{"schema_version":1,"mode":"answer bogus","updated_at":"","dirty_files":[],"last_drain_seq":0}'      # R5
  _t10_both_emit "missing_mode"           '{"schema_version":1,"updated_at":"","dirty_files":[],"last_drain_seq":0}'                            # R6
  _t10_both_emit "missing_dirty_files"    '{"schema_version":1,"mode":"answer","updated_at":"","last_drain_seq":0}'                             # R6
  _t10_both_emit "missing_last_drain_seq" '{"schema_version":1,"mode":"answer","updated_at":"","dirty_files":[]}'                               # R6
  _t10_both_emit "missing_updated_at"     '{"schema_version":1,"mode":"answer","dirty_files":[],"last_drain_seq":0}'                            # R6 (required §2)
  end_test
  rm_sandbox
}

run_all() {
  t1_pre_edit_dod_gate_fast_path
  t2_post_edit_design_plan_coverage_rule_skip
  t3_post_edit_routing_procedure_rule_skip
  t4_post_edit_spec_review_gate_marker_dedup
  t5_hooks_fail_soft_when_lib_absent
  t6_hooks_fail_soft_when_state_file_absent
  t7_envelope_hooks_legacy_on_malformed_state
  t8_envelope_hooks_legacy_on_unknown_schema
  t9_envelope_hooks_legacy_on_lock_failure
  t10_envelope_hooks_legacy_on_invalid_state
}

run_all

echo ""
echo "================================"
echo "Tests run: $((PASS_COUNT + FAIL_COUNT))"
echo "Passed:    $PASS_COUNT"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
