#!/usr/bin/env bash
# test-background-jobs-registered.sh — Plugin-First Restructure Phase 2 Task 2.5.
#
# Verifies the background-jobs rule (codex foreground policy) is registered in
# the rein-core plugin:
#   (a) pre-bash-guard.sh hook script exists in the plugin mirror.
#   (b) hooks.json contains a PreToolUse / Bash registration whose command
#       basename is pre-bash-guard.sh.
#   (c) pre-bash-guard.sh contains the codex foreground policy enforcement
#       surface — namely the pipe-to-bash blocking pattern that prevents
#       'codex exec ... | tail -N' or similar pipe-bash forms (which the Bash
#       tool would auto-background, breaking codex's TTY/stdin contract; see
#       .claude/rules/background-jobs.md "Exception — codex 계열 명령은
#       foreground 전용"). Detection is structural: we require the bash-pipe
#       blocking grep pattern AND the codex review stamp logic to coexist in
#       this hook so that the codex foreground policy has both the gate
#       (pipe-bash block) and the review stamp consumer.
#   (d) docs/rules/background-jobs.md exists in the plugin and is sha256-
#       identical to the source .claude/rules/background-jobs.md.
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_DIR="plugins/rein-core"
HOOK_SCRIPT="$PLUGIN_DIR/hooks/pre-bash-guard.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
RULE_NAME="background-jobs.md"
PLUGIN_RULE_DOC="$PLUGIN_DIR/rules/$RULE_NAME"
SOURCE_RULE_DOC="plugins/rein-core/rules/$RULE_NAME"

EXPECTED_EVENT="PreToolUse"
EXPECTED_MATCHER="Bash"
EXPECTED_BASENAME="pre-tool-use-bash-rules.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "neither sha256sum nor shasum is available"
  fi
}

# (a) Hook script presence.
[ -f "$HOOK_SCRIPT" ] || fail "hook script missing: $HOOK_SCRIPT"

# (b) hooks.json registration check via Python.
[ -f "$HOOKS_JSON" ] || fail "hooks.json missing: $HOOKS_JSON"

python3 - "$HOOKS_JSON" "$EXPECTED_EVENT" "$EXPECTED_MATCHER" "$EXPECTED_BASENAME" <<'PY'
import json
import os
import sys

hooks_json_path, expected_event, expected_matcher, expected_basename = sys.argv[1:5]

with open(hooks_json_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

# Claude Code hooks.json schema:
#   {"hooks": {"<Event>": [{"matcher": "...", "hooks": [{"command": "..."}, ...]}, ...]}}
hooks_by_event = data.get("hooks", {})
for matcher_group in hooks_by_event.get(expected_event, []):
    if matcher_group.get("matcher", "") != expected_matcher:
        continue
    for hook in matcher_group.get("hooks", []):
        cmd = hook.get("command", "")
        if os.path.basename(cmd) == expected_basename:
            sys.exit(0)

print(
    "FAIL: no hooks.json entry matched event="
    f"{expected_event} matcher={expected_matcher} basename={expected_basename}",
    file=sys.stderr,
)
sys.exit(1)
PY

# (c) Codex foreground policy enforcement structure.
#     Two complementary surfaces must both be present in pre-bash-guard.sh:
#       (c1) pipe-to-bash blocking pattern (prevents auto-background of
#            'cmd | bash' which is the failure mode in
#            trail/dod/dod-2026-04-22-codex-foreground-policy.md).
#       (c2) codex review stamp logic — the hook is the consumer of the
#            .codex-reviewed stamp, so codex must be referenced in the gate.
if ! grep -qE '\| *(bash|sh)' "$HOOK_SCRIPT"; then
  fail "$HOOK_SCRIPT missing pipe-to-bash blocking pattern (codex foreground gate)"
fi
if ! grep -qi 'codex' "$HOOK_SCRIPT"; then
  fail "$HOOK_SCRIPT missing codex reference (foreground policy consumer)"
fi

# (d) Rule reference doc presence + sha256 parity with source.
[ -f "$SOURCE_RULE_DOC" ] || fail "source rule doc missing: $SOURCE_RULE_DOC"
[ -f "$PLUGIN_RULE_DOC" ] || fail "plugin rule doc missing: $PLUGIN_RULE_DOC"

src_sha="$(sha256_of "$SOURCE_RULE_DOC")"
dst_sha="$(sha256_of "$PLUGIN_RULE_DOC")"
if [ "$src_sha" != "$dst_sha" ]; then
  fail "sha256 drift for rule doc '$RULE_NAME': source=$src_sha plugin=$dst_sha"
fi

echo "test-background-jobs-registered: OK (hook + hooks.json + codex foreground gate + rule doc parity)"
