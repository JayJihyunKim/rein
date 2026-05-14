#!/usr/bin/env bash
# test-rein-update-claude-md-untouched.sh — Phase 5 Task 5.7.
#
# Verifies plugin-mode `rein update` redirects to the plugin manager and
# never modifies user-authored CLAUDE.md (root or .claude/).
#
# Scope ID: rein-update-does-not-touch-user-claude-md-on-plugin-mode

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REIN_SH="$PROJECT_DIR/scripts/rein.sh"

TMP="$(mktemp -d -t rein-update-claude-md-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# Arrange — fixture: plugin-mode project with both CLAUDE.md files (user-authored).
mkdir -p "$TMP/.claude" "$TMP/.rein"
( cd "$TMP" && git init -q && git config user.email t@t && git config user.name t )
ROOT_CONTENT="user-root-update-claude-md-$(date +%s)"
NESTED_CONTENT="user-nested-update-claude-md-$(date +%s)"
echo "$ROOT_CONTENT" > "$TMP/CLAUDE.md"
echo "$NESTED_CONTENT" > "$TMP/.claude/CLAUDE.md"

# project.json signals plugin mode → cmd_merge / update should redirect
# without running the legacy 3-way merge path.
cat > "$TMP/.rein/project.json" <<'JSON'
{
  "mode": "plugin",
  "scope": "project",
  "version": "1.0.0"
}
JSON

SHA_ROOT_BEFORE=$(python3 -c \
  "import hashlib; print(hashlib.sha256(open('$TMP/CLAUDE.md','rb').read()).hexdigest())")
SHA_NESTED_BEFORE=$(python3 -c \
  "import hashlib; print(hashlib.sha256(open('$TMP/.claude/CLAUDE.md','rb').read()).hexdigest())")

# Act — `rein update` in plugin mode.
( cd "$TMP" && REIN_NO_SELF_UPDATE=1 \
    bash "$REIN_SH" update >/tmp/update-claude-md.stdout 2>/tmp/update-claude-md.stderr ) \
  || { cat /tmp/update-claude-md.stderr >&2; fail "rein update failed"; }

# Assert A — the redirect message identifies plugin mode.
# rein.sh's info() writes to stderr, not stdout. The test checks both streams
# so we don't depend on which fd the diagnostic helper picks.
grep -qiE 'plugin mode|plugin manager' \
  /tmp/update-claude-md.stdout /tmp/update-claude-md.stderr \
  || fail "A: rein update did not print plugin redirect message"
ok "A: rein update plugin mode prints redirect message"

# Assert B — both CLAUDE.md files unchanged.
[ -f "$TMP/CLAUDE.md" ] || fail "B: root CLAUDE.md was deleted"
[ -f "$TMP/.claude/CLAUDE.md" ] || fail "B: nested CLAUDE.md was deleted"
SHA_ROOT_AFTER=$(python3 -c \
  "import hashlib; print(hashlib.sha256(open('$TMP/CLAUDE.md','rb').read()).hexdigest())")
SHA_NESTED_AFTER=$(python3 -c \
  "import hashlib; print(hashlib.sha256(open('$TMP/.claude/CLAUDE.md','rb').read()).hexdigest())")
[ "$SHA_ROOT_BEFORE" = "$SHA_ROOT_AFTER" ] || fail "B: root CLAUDE.md sha drift"
[ "$SHA_NESTED_BEFORE" = "$SHA_NESTED_AFTER" ] || fail "B: nested CLAUDE.md sha drift"
ok "B: CLAUDE.md (root + nested) sha256 unchanged after rein update"

# Assert C — manifest creation must not have happened (plugin mode is unmanaged).
[ -f "$TMP/.claude/.rein-manifest.json" ] && \
  fail "C: rein update plugin-mode created .claude/.rein-manifest.json"
ok "C: no manifest created on plugin-mode update"

echo "test-rein-update-claude-md-untouched: OK (3/3 assertions)"
