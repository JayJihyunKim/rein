#!/usr/bin/env bash
# tests/hooks/test-hk1-post-write-rename.sh
#
# TDD red-phase gate for HK-1: post-write-* → post-edit-* rename.
#
# Assertions:
#   (1) The 4 old post-write-* hook files must NOT exist under plugins/rein-core/hooks/.
#   (2) The 4 new post-edit-* hook files MUST exist and be executable.
#   (3) post-edit-dispatcher.sh must NOT contain any reference to the old names.
#   (4) hooks.json must register the 4 renamed post-edit-* sub-hooks directly
#       (Phase 2b HK-4 dispatcher split; replaced the prior dispatcher trace).
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

# ── (4) hooks.json registers the 4 renamed sub-hooks directly ────────────────
# Phase 2b HK-4: post-edit-dispatcher.sh deprecated (단일 entry → sub-hook 직접
# 등록 분할). 따라서 "dispatcher 가 sub-hook 들을 호출" 검증은 더 이상 의미가
# 없고, "hooks.json 에 4 renamed sub-hook 이 PostToolUse Edit|Write|MultiEdit
# matcher 로 직접 등록돼 있는가" 가 본 test (rename 완료) 의 정확한 의도.
HOOKS_JSON="$HOOKS_DIR/hooks.json"
[ -f "$HOOKS_JSON" ] || fail "hooks.json missing: $HOOKS_JSON"

python3 - "$HOOKS_JSON" <<'PY' || fail "hooks.json registration check failed"
import json, os, sys
required = {
    "post-edit-spec-review-gate.sh",
    "post-edit-dod-routing-check.sh",
    "post-edit-design-plan-coverage-rule.sh",
    "post-edit-routing-procedure-rule.sh",
}
data = json.load(open(sys.argv[1], encoding="utf-8"))
found = set()
for group in data.get("hooks", {}).get("PostToolUse", []):
    if group.get("matcher", "") != "Edit|Write|MultiEdit":
        continue
    for hook in group.get("hooks", []):
        found.add(os.path.basename(hook.get("command", "")))
missing = required - found
if missing:
    print(f"FAIL: renamed sub-hooks not registered in hooks.json: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
PY
ok "(4) hooks.json registers all 4 renamed post-edit-* sub-hooks directly"

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
