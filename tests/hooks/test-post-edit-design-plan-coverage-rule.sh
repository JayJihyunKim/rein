#!/usr/bin/env bash
# tests/hooks/test-post-edit-design-plan-coverage-rule.sh
#
# Verifies the plugin PostToolUse sub-hook
# `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh`:
#
#   (a) Match cases emit a PostToolUse envelope whose additionalContext
#       contains the design-plan-coverage 행동 강령.
#         - docs/specs/** (relative)
#         - docs/plans/** (absolute)
#         - trail/dod/dod-*.md
#   (b) Path resolution fallback chain works:
#         tool_input.file_path → tool_response.filePath → tool_result.file_path
#   (c) Non-matching paths produce *no* stdout (silent — won't inflate context).
#   (d) Malformed JSON exits silently with no stdout (post-hook contract).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

OUT="$(mktemp)"
# X4.C.3: the hook fast-path-skips its envelope when the resolved project's
# .rein/state.json reports mode=answer. Pin an isolated (state-absent) project
# dir so these envelope-contract assertions exercise the legacy path
# deterministically instead of inheriting the maintainer repo's live state.json.
SANDBOX="$(mktemp -d)"
export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
trap 'rm -rf "$OUT" "$SANDBOX"' EXIT

invoke() {
  local input="$1"
  : > "$OUT"
  printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>/dev/null || true
}

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

# (a1) docs/specs match (relative path)
invoke '{"tool_input":{"file_path":"docs/specs/2026-01-01-foo.md"}}'
assert_envelope "docs/specs relative match"

# (a2) docs/plans match (absolute path)
invoke '{"tool_input":{"file_path":"/Users/foo/repo/docs/plans/2026-01-01-bar.md"}}'
assert_envelope "docs/plans absolute match"

# (a3) trail/dod/dod-*.md match
invoke '{"tool_input":{"file_path":"trail/dod/dod-2026-05-12-test.md"}}'
assert_envelope "trail/dod/dod-*.md match"

# (b1) fallback: tool_response.filePath (when tool_input.file_path absent)
invoke '{"tool_response":{"filePath":"docs/specs/foo.md"}}'
assert_envelope "tool_response.filePath fallback"

# (b2) legacy fallback: tool_result.file_path
invoke '{"tool_result":{"file_path":"docs/plans/foo.md"}}'
assert_envelope "tool_result.file_path legacy fallback"

# (c1) non-matching path (src file) — silent
invoke '{"tool_input":{"file_path":"src/foo.py"}}'
assert_silent "src/foo.py non-match → silent"

# (c2) non-matching path: trail/dod/ but no dod- prefix → silent
invoke '{"tool_input":{"file_path":"trail/dod/notes.md"}}'
assert_silent "trail/dod/notes.md (no dod- prefix) → silent"

# (c3) non-matching path: docs/other/ → silent
invoke '{"tool_input":{"file_path":"docs/other/x.md"}}'
assert_silent "docs/other/x.md → silent"

# (d) malformed JSON → silent
invoke 'not json at all'
assert_silent "malformed JSON → silent"

# (e) empty stdin → silent
: > "$OUT"
printf '' | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>/dev/null || true
assert_silent "empty stdin → silent"

# (f) CLAUDE_PLUGIN_ROOT unset → silent (scaffold mode)
: > "$OUT"
printf '%s' '{"tool_input":{"file_path":"docs/specs/foo.md"}}' \
  | env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" >"$OUT" 2>/dev/null || true
assert_silent "CLAUDE_PLUGIN_ROOT unset → silent"

echo "test-post-edit-design-plan-coverage-rule: OK"
