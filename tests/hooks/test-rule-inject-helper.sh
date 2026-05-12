#!/usr/bin/env bash
# Verify the rule-inject helper:
#   (a) returns the bundled default body when no override is configured
#   (b) returns the override body when `.rein/policy/rules.yaml` defines one
#   (c) fail-open on malformed yaml (returns default body) + stderr warning
#   (d) returns exit 1 when neither override nor default exists
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HELPER="$PROJECT_DIR/plugins/rein-core/hooks/lib/rule-inject.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }
[ -x "$HELPER" ] || { echo "FAIL: $HELPER not executable" >&2; exit 1; }

PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

# Scratch dir for `.rein/policy/` fixtures — operate without polluting the real one.
SCRATCH=$(mktemp -d "/tmp/test-rule-inject-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
cd "$SCRATCH"

# ---------- (a) bundled default ----------------------------------------------
BODY_A=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HELPER" code-style 2>/dev/null)
echo "$BODY_A" | grep -q "행동 강령" || { echo "FAIL (a): bundled default missing mandate header" >&2; exit 1; }

# ---------- (b) override returned when configured ----------------------------
mkdir -p .rein/policy
cat > .rein/policy/rules.yaml <<'YAML'
code-style:
  override: |
    custom-override-body-marker-12345
YAML
BODY_B=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HELPER" code-style 2>/dev/null)
echo "$BODY_B" | grep -q "custom-override-body-marker-12345" || {
  echo "FAIL (b): override body not returned" >&2
  echo "got:" >&2; echo "$BODY_B" | head -5 >&2
  exit 1
}

# ---------- (c) fail-open on malformed yaml ----------------------------------
cat > .rein/policy/rules.yaml <<'YAML'
this is: : not yaml [[[
YAML
BODY_C=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HELPER" code-style 2>/dev/null)
echo "$BODY_C" | grep -q "행동 강령" || { echo "FAIL (c): fail-open did not return bundled default" >&2; exit 1; }

# ---------- (d) exit 1 when neither override nor default exists --------------
rm -rf .rein/policy
EMPTY_ROOT=$(mktemp -d "/tmp/empty-plugin-XXXXXX")
set +e
CLAUDE_PLUGIN_ROOT="$EMPTY_ROOT" bash "$HELPER" no-such-rule 2>/dev/null
RC=$?
set -e
rm -rf "$EMPTY_ROOT"
if [ "$RC" -ne 1 ]; then
  echo "FAIL (d): expected exit 1 when no body resolved, got $RC" >&2
  exit 1
fi

echo "test-rule-inject-helper: OK (default + override + fail-open + exit-1)"
