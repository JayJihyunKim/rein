#!/usr/bin/env bash
# test-subagent-review-registered.sh — Plugin-First Restructure Phase 2 Task 2.3.
#
# Verifies the subagent-review rule is registered in the rein-core plugin:
#   (a) both ③-c commit-gate successors exist in the plugin mirror (Phase 7
#       웨이브 3 ③-c, 2026-08-23 갱신: the former single (구)pre-bash-test-
#       commit-gate.sh — HK-2 split successor of the original Bash guard,
#       owning the review-evidence gate that enforces subagent-review.md's
#       "code_review/security_review v2 증거는 실제 리뷰를 거친 후에만
#       발급" contract at commit time (③-d, 2026-08-24: the legacy
#       .codex-reviewed/.security-reviewed stamp write path this contract
#       used to reference was removed outright — v2 evidence issuance is now
#       the sole recording mechanism) — was deleted and replaced by
#       pre-bash-commit-discipline-gate.sh (coverage/commit-msg discipline,
#       no review axis) + pre-bash-commit-review-gate.sh (the actual
#       review-evidence gate successor, delegating to the v2 engine). Both
#       are sequential children of pre-bash-dispatcher.sh Step 3 — see that
#       dispatcher's own header. This check only verifies file presence; the
#       review-evidence enforcement *content* is covered in depth by
#       tests/hooks/test-background-jobs-registered.sh's check (c).
#   (b) hooks.json contains a PreToolUse registration with matcher Agent
#       whose command basename is pre-tool-use-agent-rules.sh (the dedicated
#       subagent-review rule-injection hook — unaffected by the ③-c Bash
#       commit-gate split; this hook lives on the Agent matcher, not Bash,
#       and is registered directly rather than via any dispatcher).
#   (c) docs/rules/subagent-review.md exists in the plugin and is sha256-identical
#       to the source .claude/rules/subagent-review.md.
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_DIR="plugins/rein-core"
# ③-c split (2026-08-23): the former single pre-bash-test-commit-gate.sh
# successor set. discipline-gate = coverage/commit-msg discipline (no
# review-stamp axis); review-gate = the actual review-stamp gate successor
# (see header above).
DISCIPLINE_GATE="$PLUGIN_DIR/hooks/pre-bash-commit-discipline-gate.sh"
REVIEW_GATE="$PLUGIN_DIR/hooks/pre-bash-commit-review-gate.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
RULE_NAME="subagent-review.md"
PLUGIN_RULE_DOC="$PLUGIN_DIR/rules/$RULE_NAME"
SOURCE_RULE_DOC="plugins/rein-core/rules/$RULE_NAME"

EXPECTED_EVENT="PreToolUse"
EXPECTED_MATCHER="Agent"
EXPECTED_BASENAME="pre-tool-use-agent-rules.sh"

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

# (a) Hook script presence in plugin mirror — both ③-c successors.
[ -f "$DISCIPLINE_GATE" ] || fail "hook script missing: $DISCIPLINE_GATE"
[ -f "$REVIEW_GATE" ] || fail "hook script missing: $REVIEW_GATE"

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

# (c) Rule reference doc presence + sha256 parity with source.
[ -f "$SOURCE_RULE_DOC" ] || fail "source rule doc missing: $SOURCE_RULE_DOC"
[ -f "$PLUGIN_RULE_DOC" ] || fail "plugin rule doc missing: $PLUGIN_RULE_DOC"

src_sha="$(sha256_of "$SOURCE_RULE_DOC")"
dst_sha="$(sha256_of "$PLUGIN_RULE_DOC")"
if [ "$src_sha" != "$dst_sha" ]; then
  fail "sha256 drift for rule doc '$RULE_NAME': source=$src_sha plugin=$dst_sha"
fi

echo "test-subagent-review-registered: OK (hook + hooks.json + rule doc parity)"
