#!/usr/bin/env bash
# tests/hooks/test-post-edit-routing-procedure-rule.sh
#
# Characterization / regression fixture for the plugin PostToolUse sub-hook
# `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh`.
#
# Purpose (per docs/plans/2026-06-02-hook-hotpath-perf-implementation.md
# Task 2.2 / 2.3): lock in byte-identical behavior across the 3-tier
# file_path fallback chain *and* a non-string tool_use_id case, so the
# PERF-B spawn-merge (Task 2.2 — 3 python3 calls → 2) does NOT silently
# change which inputs fire the routing advisory.
#
# This fixture MUST pass against the CURRENT (pre-merge) hook (it encodes
# current behavior) AND remain green after the spawn-merge in track-b-rpr.
#
# Cases:
#   (a) tool_input.file_path = DoD path + string tool_use_id
#         → advisory fires, envelope present, file_path used.
#   (b) tool_input absent → tool_response.filePath = DoD path
#         → advisory fires (2nd-tier fallback).
#   (c) tool_input + tool_response empty → tool_result.file_path = DoD path
#         → advisory fires (3rd-tier legacy fallback).
#   (d) no file_path anywhere → hook early-exits, no advisory.
#   (e) tool_input.file_path = DoD path + NON-STRING tool_use_id (int)
#         → advisory STILL fires, file_path extracted.
#       (guards the codex-High TypeError regression: if the merged python
#        does `str + non-str` the whole META blob comes back empty and
#        file_path early-exits = advisory wrongly suppressed.)
#   (f) non-matching path (not a DoD file) → silent.
#   (g) malformed JSON / empty stdin / CLAUDE_PLUGIN_ROOT unset → silent.
#
# The advisory fires only for trail/dod/dod-[0-9]*.md paths whose target
# file does NOT already contain a '## 라우팅 추천' section. We deliberately
# point at NON-EXISTENT dod-*.md paths: the hook treats a missing file as
# "inject so the model sees the template after a future write surfaces it"
# (see the hook's grep guard), so the advisory fires deterministically.
#
# Output routing: when a *valid* Anthropic tool_use_id (`toolu_...`) is
# present AND the output cache is writable, the hook writes its envelope to
# the cache and emits nothing on stdout (the aggregator merges it). To
# assert on stdout deterministically — the same mechanism the sibling
# design-plan-coverage fixture uses — we keep tool_use_id either absent or a
# value that fails the `^toolu_...$` sanitizer (e.g. "test-1" / the int
# 12345), which forces the documented stdout fallback. The advisory body is
# identical on both paths, so this characterizes the firing decision, not
# the transport.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

OUT="$(mktemp)"
# Pin an isolated (state-absent) project dir so the X4.C.3 effective_mode
# fast-path skip does not fire and so cache writes (if any) land in a
# throwaway sandbox instead of the maintainer repo. State-absent ⇒ the hook
# takes its legacy inject path deterministically (mirrors the sibling
# design-plan-coverage fixture).
SANDBOX="$(mktemp -d)"
export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
export CLAUDE_PROJECT_DIR="$SANDBOX"
trap 'rm -rf "$OUT" "$SANDBOX"' EXIT

invoke() {
  local input="$1"
  : > "$OUT"
  printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>/dev/null || true
}

# Asserts the routing-procedure advisory fired: a PostToolUse envelope whose
# additionalContext carries the routing rule body (행동 강령 + 라우팅 추천 마커).
assert_envelope() {
  local label="$1"
  python3 - "$OUT" <<'PY' || { echo "FAIL: $label — envelope assertion" >&2; cat "$OUT" >&2; exit 1; }
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
assert raw.strip(), "empty stdout"
data = json.loads(raw)
hso = data.get("hookSpecificOutput", {})
assert hso.get("hookEventName") == "PostToolUse", f"hookEventName={hso.get('hookEventName')!r}"
ctx = hso.get("additionalContext", "")
assert "행동 강령" in ctx, "missing 행동 강령 in additionalContext"
assert "라우팅 추천" in ctx, "additionalContext is not the routing-procedure rule body (missing 라우팅 추천)"
PY
  echo "  ok: $label"
}

assert_silent() {
  local label="$1"
  if [ -s "$OUT" ]; then
    echo "FAIL: $label — expected no stdout, got:" >&2
    cat "$OUT" >&2
    exit 1
  fi
  echo "  ok: $label"
}

# A DoD path matching the hook glob (trail/dod/dod-[0-9]*.md). Point at a
# guaranteed-nonexistent file under the sandbox so the '## 라우팅 추천'
# already-present guard never short-circuits the inject.
DOD_REL="trail/dod/dod-2026-06-02-track-b-tests.md"
DOD_ABS="$SANDBOX/trail/dod/dod-2026-06-02-abs.md"

# (a) tool_input.file_path (1st tier) + string tool_use_id → advisory fires.
#     A non-toolu_ string id still forces the stdout fallback (sanitizer
#     rejects it), so we can assert on stdout.
invoke "{\"tool_input\":{\"file_path\":\"$DOD_REL\"},\"tool_use_id\":\"test-string-id\"}"
assert_envelope "(a) tool_input.file_path + string tool_use_id"

# (a2) absolute DoD path also matches the */trail/dod/dod-[0-9]*.md glob.
invoke "{\"tool_input\":{\"file_path\":\"$DOD_ABS\"}}"
assert_envelope "(a2) absolute DoD file_path match"

# (b) 2nd-tier fallback: tool_input absent, tool_response.filePath present.
invoke "{\"tool_response\":{\"filePath\":\"$DOD_REL\"}}"
assert_envelope "(b) tool_response.filePath 2nd-tier fallback"

# (b2) tool_input present but empty (the `or {}` / file_path "" path), so
#      resolution must still fall through to tool_response.filePath.
invoke "{\"tool_input\":{},\"tool_response\":{\"filePath\":\"$DOD_REL\"}}"
assert_envelope "(b2) empty tool_input → tool_response.filePath fallback"

# (c) 3rd-tier legacy fallback: tool_input + tool_response empty,
#     tool_result.file_path present.
invoke "{\"tool_input\":{},\"tool_response\":{},\"tool_result\":{\"file_path\":\"$DOD_REL\"}}"
assert_envelope "(c) tool_result.file_path 3rd-tier legacy fallback"

# (d) no file_path anywhere → early-exit, silent.
invoke '{"tool_input":{},"tool_response":{},"tool_result":{}}'
assert_silent "(d) no file_path anywhere → silent"

# (e) NON-STRING tool_use_id (int) + valid file_path → advisory STILL fires.
#     This is the codex-High TypeError regression guard for the spawn-merge:
#     a naive merged python doing (data.get("tool_use_id","") or "") would
#     raise TypeError on the int, collapsing the whole META blob to empty and
#     suppressing the advisory. The type-guard must keep file_path intact.
invoke "{\"tool_input\":{\"file_path\":\"$DOD_REL\"},\"tool_use_id\":12345}"
assert_envelope "(e) non-string (int) tool_use_id → advisory still fires"

# (e2) NON-STRING tool_use_id (list) variant — same guard, different type.
invoke "{\"tool_input\":{\"file_path\":\"$DOD_REL\"},\"tool_use_id\":[1,2,3]}"
assert_envelope "(e2) non-string (list) tool_use_id → advisory still fires"

# (f) non-matching path: a DoD-shaped dir but not a dod-[0-9]*.md file → silent.
invoke '{"tool_input":{"file_path":"trail/dod/notes.md"}}'
assert_silent "(f1) trail/dod/notes.md (no dod- numeric prefix) → silent"

# (f2) non-matching path: a source file → silent.
invoke '{"tool_input":{"file_path":"src/foo.py"}}'
assert_silent "(f2) src/foo.py non-match → silent"

# (f3) non-matching path: a spec/plan file (routing hook only fires on DoD) → silent.
invoke '{"tool_input":{"file_path":"docs/specs/2026-01-01-foo.md"}}'
assert_silent "(f3) docs/specs (routing hook ignores) → silent"

# (g1) malformed JSON → silent.
invoke 'not json at all'
assert_silent "(g1) malformed JSON → silent"

# (g2) empty stdin → silent.
: > "$OUT"
printf '' | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>/dev/null || true
assert_silent "(g2) empty stdin → silent"

# (g3) CLAUDE_PLUGIN_ROOT unset → silent (scaffold / non-plugin runtime).
: > "$OUT"
printf '%s' "{\"tool_input\":{\"file_path\":\"$DOD_REL\"}}" \
  | env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" >"$OUT" 2>/dev/null || true
assert_silent "(g3) CLAUDE_PLUGIN_ROOT unset → silent"

echo "test-post-edit-routing-procedure-rule: OK"
