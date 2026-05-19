#!/usr/bin/env bash
# tests/hooks/test-post-edit-dispatcher.sh
#
# Verifies post-edit-dispatcher.sh behavior + codex-review follow-ups (Phase 2-4):
#   A. dispatcher 가 7개 sub-hook 을 호출하고 캐시 export.
#   B. hook_input_export/clear roundtrip (new 2-arg signature).
#   C. 직접 호출 (no cache) 호환 — sub-hook 들이 stdin fallback 으로 동작.
#   D. policy gate — profile: lean 시 dispatcher 가 무거운 sub-hook 을 skip.
#   E. sub-hook exit 2 (fail-closed) 가 dispatcher 를 통해 propagate.
#   F. 거대 payload 도 INPUT_FILE 경로로 안전 전달 (ARG_MAX 회피).
#   G. extractor 실패 (invalid JSON) 시 CACHE_OK=0 → sub-hook 들이 자체 파싱.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-dispatcher.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ok: $1"; }

[ -x "$DISPATCHER" ] || fail "dispatcher missing: $DISPATCHER"

# ---------------------------------------------------------------------------
# Common test harness: sandbox dispatcher + trace sub-hooks
# ---------------------------------------------------------------------------
setup_sandbox() {
  local sb="$1"
  mkdir -p "$sb/.claude/hooks/lib"
  cp "$PROJECT_DIR/plugins/rein-core/hooks/lib/python-runner.sh" "$sb/.claude/hooks/lib/"
  cp "$PROJECT_DIR/plugins/rein-core/hooks/lib/hook-input-cache.sh" "$sb/.claude/hooks/lib/"
  cp "$PROJECT_DIR/plugins/rein-core/hooks/lib/extract-hook-json.py" "$sb/.claude/hooks/lib/"
  cp "$PROJECT_DIR/plugins/rein-core/hooks/lib/aggregator.sh" "$sb/.claude/hooks/lib/"
  cp "$DISPATCHER" "$sb/.claude/hooks/post-edit-dispatcher.sh"
  chmod +x "$sb/.claude/hooks/post-edit-dispatcher.sh"
}

write_trace_shim() {
  local hook_path="$1"
  local trace_log="$2"
  local exit_code="${3:-0}"
  cat > "$hook_path" <<EOF
#!/usr/bin/env bash
echo "called=\$0" >> "$trace_log"
echo "cache=\${REIN_HOOK_INPUT_CACHE:-unset}" >> "$trace_log"
echo "file_path=\${REIN_HOOK_FILE_PATH:-unset}" >> "$trace_log"
echo "paths=\${REIN_HOOK_FILE_PATHS:-unset}" >> "$trace_log"
echo "input_file=\${REIN_HOOK_INPUT_FILE:-unset}" >> "$trace_log"
exit $exit_code
EOF
  chmod +x "$hook_path"
}

# ---------------------------------------------------------------------------
# Fixture A: dispatcher 가 sub-hook 7개를 trace 한다.
# ---------------------------------------------------------------------------
A_SB="$TMP_ROOT/A"
setup_sandbox "$A_SB"
A_TRACE="$A_SB/trace"
mkdir -p "$A_TRACE"
for sub in \
  post-edit-hygiene.sh post-edit-review-gate.sh post-edit-index-sync-inbox.sh \
  post-edit-spec-review-gate.sh post-edit-plan-coverage.sh post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh post-edit-routing-procedure-rule.sh
do
  write_trace_shim "$A_SB/.claude/hooks/$sub" "$A_TRACE/$sub.log"
done

A_PAYLOAD='{"tool_input":{"file_path":"/tmp/example.py"}}'
echo "$A_PAYLOAD" | "$A_SB/.claude/hooks/post-edit-dispatcher.sh" || fail "dispatcher exited non-zero"

for sub in \
  post-edit-hygiene.sh post-edit-review-gate.sh post-edit-index-sync-inbox.sh \
  post-edit-spec-review-gate.sh post-edit-plan-coverage.sh post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh post-edit-routing-procedure-rule.sh
do
  [ -f "$A_TRACE/$sub.log" ] || fail "sub-hook not called: $sub"
  grep -q "cache=1" "$A_TRACE/$sub.log" || fail "$sub did not see REIN_HOOK_INPUT_CACHE=1"
  grep -q "file_path=/tmp/example.py" "$A_TRACE/$sub.log" || fail "$sub did not see FILE_PATH via cache"
  grep -q "input_file=/" "$A_TRACE/$sub.log" || fail "$sub did not see REIN_HOOK_INPUT_FILE"
done
ok "Fixture A: dispatcher calls all 8 sub-hooks with cache + INPUT_FILE populated"

# ---------------------------------------------------------------------------
# Fixture B: hook_input_export 2-arg signature + clear roundtrip.
# ---------------------------------------------------------------------------
(
  set +e
  . "$A_SB/.claude/hooks/lib/hook-input-cache.sh"
  hook_input_export "p1\np2" "p1"
  [ "${REIN_HOOK_INPUT_CACHE:-}" = "1" ] || { echo "FAIL B: cache flag not set"; exit 1; }
  [ "${REIN_HOOK_FILE_PATHS:-}" = $'p1\\np2' ] || [ "${REIN_HOOK_FILE_PATHS:-}" = "p1\\np2" ] || { echo "FAIL B: FILE_PATHS not exported correctly: '${REIN_HOOK_FILE_PATHS:-}'"; exit 1; }
  hook_input_clear
  [ -z "${REIN_HOOK_INPUT_CACHE:-}" ] || { echo "FAIL B: cache flag still set after clear"; exit 1; }
  [ -z "${REIN_HOOK_INPUT_FILE:-}" ] || { echo "FAIL B: INPUT_FILE still set after clear"; exit 1; }
  exit 0
) || fail "Fixture B sub-shell"
ok "Fixture B: hook_input_export(2-arg) + hook_input_clear roundtrip"

# ---------------------------------------------------------------------------
# Fixture C: 직접 호출 시 sub-hook fallback (no cache).
# ---------------------------------------------------------------------------
C_PAYLOAD='{"tool_input":{"file_path":"/nonexistent/path/example.py"}}'
echo "$C_PAYLOAD" | "$PROJECT_DIR/plugins/rein-core/hooks/post-edit-hygiene.sh"
rc=$?
[ "$rc" = "0" ] || fail "Fixture C: post-edit-hygiene fallback returned $rc"
ok "Fixture C: post-edit-hygiene direct invocation (no cache) returns 0"

# ---------------------------------------------------------------------------
# Fixture D: policy gate skips hooks disabled by profile:lean (plugin mode).
# ---------------------------------------------------------------------------
D_SB="$TMP_ROOT/D"
setup_sandbox "$D_SB"
mkdir -p "$D_SB/scripts" "$D_SB/.rein/policy"
cp "$PROJECT_DIR/scripts/rein-policy-loader.py" "$D_SB/scripts/"
cat > "$D_SB/.rein/policy/hooks.yaml" <<'YAML'
profile: lean
YAML

D_TRACE="$D_SB/trace"
mkdir -p "$D_TRACE"
for sub in \
  post-edit-hygiene.sh post-edit-review-gate.sh post-edit-index-sync-inbox.sh \
  post-edit-spec-review-gate.sh post-edit-plan-coverage.sh post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh post-edit-routing-procedure-rule.sh
do
  write_trace_shim "$D_SB/.claude/hooks/$sub" "$D_TRACE/$sub.log"
done

D_PAYLOAD='{"tool_input":{"file_path":"/tmp/example.py"}}'
( cd "$D_SB" && CLAUDE_PLUGIN_ROOT="$D_SB" echo "$D_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$D_SB" "$D_SB/.claude/hooks/post-edit-dispatcher.sh" ) || fail "Fixture D dispatcher exited non-zero"

# lean profile disables 3 hooks → trace logs should NOT exist for them
for disabled in post-edit-plan-coverage.sh post-edit-spec-review-gate.sh post-edit-dod-routing-check.sh; do
  [ ! -f "$D_TRACE/$disabled.log" ] || fail "Fixture D: $disabled was called despite profile:lean"
done
# enabled hooks should be called (lean leaves these on; the design-plan-coverage
# rule injector is not in the lean disable list, so it should run too)
for enabled in post-edit-hygiene.sh post-edit-review-gate.sh post-edit-index-sync-inbox.sh post-edit-design-plan-coverage-rule.sh post-edit-routing-procedure-rule.sh; do
  [ -f "$D_TRACE/$enabled.log" ] || fail "Fixture D: $enabled was not called despite being enabled"
done
ok "Fixture D: profile:lean blocks 3 heavy hooks, lets 5 light hooks run"

# ---------------------------------------------------------------------------
# Fixture E: sub-hook exit 2 propagates through dispatcher.
# ---------------------------------------------------------------------------
E_SB="$TMP_ROOT/E"
setup_sandbox "$E_SB"
E_TRACE="$E_SB/trace"
mkdir -p "$E_TRACE"
write_trace_shim "$E_SB/.claude/hooks/post-edit-hygiene.sh" "$E_TRACE/hygiene.log"
write_trace_shim "$E_SB/.claude/hooks/post-edit-review-gate.sh" "$E_TRACE/review.log"
write_trace_shim "$E_SB/.claude/hooks/post-edit-index-sync-inbox.sh" "$E_TRACE/index.log"
write_trace_shim "$E_SB/.claude/hooks/post-edit-spec-review-gate.sh" "$E_TRACE/spec.log" 2
write_trace_shim "$E_SB/.claude/hooks/post-edit-plan-coverage.sh" "$E_TRACE/coverage.log"
write_trace_shim "$E_SB/.claude/hooks/post-edit-dod-routing-check.sh" "$E_TRACE/dod.log"

E_PAYLOAD='{"tool_input":{"file_path":"/tmp/example.py"}}'
set +e
echo "$E_PAYLOAD" | "$E_SB/.claude/hooks/post-edit-dispatcher.sh"
e_rc=$?
set -e
[ "$e_rc" = "2" ] || fail "Fixture E: dispatcher should propagate exit 2, got $e_rc"
ok "Fixture E: sub-hook exit 2 propagates to dispatcher"

# ---------------------------------------------------------------------------
# Fixture F: large payload uses INPUT_FILE (env var not blown).
# ---------------------------------------------------------------------------
F_SB="$TMP_ROOT/F"
setup_sandbox "$F_SB"
F_TRACE="$F_SB/trace"
mkdir -p "$F_TRACE"
for sub in \
  post-edit-hygiene.sh post-edit-review-gate.sh post-edit-index-sync-inbox.sh \
  post-edit-spec-review-gate.sh post-edit-plan-coverage.sh post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh post-edit-routing-procedure-rule.sh
do
  write_trace_shim "$F_SB/.claude/hooks/$sub" "$F_TRACE/$sub.log"
done

# 200KB content — well within file but would bloat env if exported.
LARGE_CONTENT=$(head -c 200000 /dev/urandom | base64 | tr -d '\n' | head -c 200000)
F_PAYLOAD=$(python3 -c "import json; print(json.dumps({'tool_input': {'file_path': '/tmp/big.py', 'content': '''$LARGE_CONTENT'''}}))")
echo "$F_PAYLOAD" | "$F_SB/.claude/hooks/post-edit-dispatcher.sh" || fail "Fixture F: dispatcher failed on large payload"

# Verify INPUT_FILE was used (env var REIN_HOOK_INPUT not set in trace).
grep -q "input_file=/" "$F_TRACE/post-edit-hygiene.sh.log" || fail "Fixture F: INPUT_FILE not exported for large payload"
ok "Fixture F: ~200KB payload routes through INPUT_FILE"

# ---------------------------------------------------------------------------
# Fixture G: invalid JSON → CACHE_OK=0 → sub-hooks fall back to stdin.
# ---------------------------------------------------------------------------
G_SB="$TMP_ROOT/G"
setup_sandbox "$G_SB"
G_TRACE="$G_SB/trace"
mkdir -p "$G_TRACE"
for sub in \
  post-edit-hygiene.sh post-edit-review-gate.sh post-edit-index-sync-inbox.sh \
  post-edit-spec-review-gate.sh post-edit-plan-coverage.sh post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh post-edit-routing-procedure-rule.sh
do
  write_trace_shim "$G_SB/.claude/hooks/$sub" "$G_TRACE/$sub.log"
done

# Invalid JSON
echo 'NOT JSON {{{' | "$G_SB/.claude/hooks/post-edit-dispatcher.sh"
# sub-hooks should still be called (no cache), but cache flag should be unset/0
for sub in post-edit-hygiene.sh; do
  [ -f "$G_TRACE/$sub.log" ] || fail "Fixture G: $sub not called on invalid JSON"
  grep -q "cache=unset\|cache=0" "$G_TRACE/$sub.log" \
    || fail "Fixture G: $sub saw cache=1 even though extraction should have failed: $(cat "$G_TRACE/$sub.log")"
done
ok "Fixture G: invalid JSON → cache disabled, sub-hooks fall back"

echo "test-post-edit-dispatcher: OK (7/7 fixtures)"
