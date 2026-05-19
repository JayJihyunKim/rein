#!/usr/bin/env bash
# tests/hooks/test-hk1-post-write-rename.sh
#
# TDD red-phase gate for HK-1: post-write-* → post-edit-* rename.
#
# Assertions:
#   (1) The 4 old post-write-* hook files must NOT exist under plugins/rein-core/hooks/.
#   (2) The 4 new post-edit-* hook files MUST exist and be executable.
#   (3) post-edit-dispatcher.sh must NOT contain any reference to the old names.
#   (4) The dispatcher must invoke the 4 renamed hooks (end-to-end trace).
#   (5) rein-policy-loader.py must NOT reference post-write-spec-review-gate
#       or post-write-dod-routing-check as PROFILE_HOOK_DEFAULTS keys.
#
# This test is intentionally FAILING before the rename is performed.
# After the rename it must PASS.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/plugins/rein-core/hooks"
DISPATCHER="$HOOKS_DIR/post-edit-dispatcher.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

# ── (1) Old post-write-* hook files must NOT exist ──────────────────────────
for old in \
  post-write-spec-review-gate.sh \
  post-write-dod-routing-check.sh \
  post-write-design-plan-coverage-rule.sh \
  post-write-routing-procedure-rule.sh
do
  [ ! -f "$HOOKS_DIR/$old" ] \
    || fail "old hook still exists (not yet renamed): $old"
done
ok "(1) old post-write-* hooks no longer exist in plugins/rein-core/hooks/"

# ── (2) New post-edit-* hook files MUST exist and be executable ──────────────
for new in \
  post-edit-spec-review-gate.sh \
  post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh \
  post-edit-routing-procedure-rule.sh
do
  [ -f "$HOOKS_DIR/$new" ] \
    || fail "renamed hook missing: $new"
  [ -x "$HOOKS_DIR/$new" ] \
    || fail "renamed hook not executable: $new"
done
ok "(2) all 4 post-edit-* hooks exist and are executable"

# ── (3) Dispatcher must not reference old names ──────────────────────────────
if grep -q 'post-write-spec-review-gate\|post-write-dod-routing-check\|post-write-design-plan-coverage-rule\|post-write-routing-procedure-rule' \
    "$DISPATCHER"; then
  fail "dispatcher still references old post-write- names"
fi
ok "(3) dispatcher contains no references to old post-write- hook names"

# ── (4) End-to-end: dispatcher invokes the 4 renamed hooks ───────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SB="$TMP/sb"
mkdir -p "$SB/.claude/hooks/lib"
cp "$HOOKS_DIR/lib/python-runner.sh"    "$SB/.claude/hooks/lib/"
cp "$HOOKS_DIR/lib/hook-input-cache.sh" "$SB/.claude/hooks/lib/"
cp "$HOOKS_DIR/lib/extract-hook-json.py" "$SB/.claude/hooks/lib/"
cp "$HOOKS_DIR/lib/aggregator.sh"       "$SB/.claude/hooks/lib/"
cp "$DISPATCHER"                         "$SB/.claude/hooks/post-edit-dispatcher.sh"
chmod +x "$SB/.claude/hooks/post-edit-dispatcher.sh"

TRACE="$TMP/trace"
mkdir -p "$TRACE"

write_shim() {
  local p="$1" log="$2"
  cat > "$p" <<EOF
#!/usr/bin/env bash
echo "called=\$0" >> "$log"
EOF
  chmod +x "$p"
}

# Populate all 8 sub-hooks; only the 4 renamed ones are the focus.
for sub in \
  post-edit-hygiene.sh \
  post-edit-review-gate.sh \
  post-edit-index-sync-inbox.sh \
  post-edit-spec-review-gate.sh \
  post-edit-plan-coverage.sh \
  post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh \
  post-edit-routing-procedure-rule.sh
do
  write_shim "$SB/.claude/hooks/$sub" "$TRACE/$sub.log"
done

PAYLOAD='{"tool_input":{"file_path":"/tmp/example.py"}}'
echo "$PAYLOAD" | "$SB/.claude/hooks/post-edit-dispatcher.sh" \
  || fail "dispatcher exited non-zero"

for renamed in \
  post-edit-spec-review-gate.sh \
  post-edit-dod-routing-check.sh \
  post-edit-design-plan-coverage-rule.sh \
  post-edit-routing-procedure-rule.sh
do
  [ -f "$TRACE/$renamed.log" ] \
    || fail "renamed hook was not called by dispatcher: $renamed"
done
ok "(4) dispatcher calls all 4 renamed post-edit-* hooks"

# ── (5) rein-policy-loader.py must use post-edit- keys ───────────────────────
LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"
if grep -q '"post-write-spec-review-gate":\|'"'"'post-write-spec-review-gate'"'" "$LOADER"; then
  fail "rein-policy-loader.py still references post-write-spec-review-gate key"
fi
if grep -q '"post-write-dod-routing-check":\|'"'"'post-write-dod-routing-check'"'" "$LOADER"; then
  fail "rein-policy-loader.py still references post-write-dod-routing-check key"
fi
ok "(5) rein-policy-loader.py uses post-edit- keys (no old post-write- keys)"

echo "test-hk1-post-write-rename: OK"
