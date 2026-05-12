#!/usr/bin/env bash
# Verify scripts/rein-validate-plugin-rules.py behavior:
#   (a) Current working tree → exit 0 with "OK" baseline; none of the
#       existing-check error markers (mandate / inject-hooks / hooks.json
#       targets / dev-only rule) appear in stderr.
#   (b) Synthetic broken state — missing mandate → exit 1 with diagnostic
#   (c) Synthetic broken state — mandate too large → exit 1
#   (d) Synthetic broken state — dev-only rule present in plugin → exit 1
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

VALIDATOR="$PROJECT_DIR/scripts/rein-validate-plugin-rules.py"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR missing" >&2; exit 1; }

# (a) baseline — current tree should pass cleanly
set +e
python3 "$VALIDATOR" >/tmp/rein-vpr-a.out 2>/tmp/rein-vpr-a.err
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "FAIL (a): validator unexpectedly failed on current tree (rc=$RC)" >&2
  echo "stdout:" >&2; cat /tmp/rein-vpr-a.out >&2
  echo "stderr:" >&2; cat /tmp/rein-vpr-a.err >&2
  exit 1
fi
grep -q "^OK:" /tmp/rein-vpr-a.out || {
  echo "FAIL (a): missing OK baseline marker on stdout" >&2
  cat /tmp/rein-vpr-a.out >&2
  exit 1
}
# Sanity: confirm none of the known error markers slipped through.
for marker in "missing '## 행동 강령'" "action mandate size" "dev-only rule shipped" \
              "inject hook missing" "inject hook not executable" \
              "inject hook produced empty envelope" "inject hook envelope invalid JSON" \
              "inject hook envelope missing hookSpecificOutput" \
              "hooks.json missing" "hooks.json invalid JSON" \
              "command does not use plugin root marker" \
              "hooks.json references missing hook" "hooks.json target not executable"; do
  if grep -q "$marker" /tmp/rein-vpr-a.err; then
    echo "FAIL (a): unexpected error in current tree: $marker" >&2
    cat /tmp/rein-vpr-a.err >&2
    exit 1
  fi
done

# Synthetic-state tests need a writable fixture plugin root. We copy the
# current plugin tree to a temp dir, mutate, run validator pointing there.
# Validator currently hardcodes paths via REPO_ROOT, so synthetic checks
# operate on temporary clones via a small wrapper Python script.

# For (b)(c)(d) we test the underlying check functions directly via Python.
python3 - <<'PY' || exit 1
import sys, importlib.util, tempfile, shutil, pathlib

spec = importlib.util.spec_from_file_location("validator", "scripts/rein-validate-plugin-rules.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# (b) missing mandate
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    # Spoof REPO_ROOT/PLUGIN_ROOT/RULES_DIR/HOOKS_DIR by monkeypatching
    orig_repo, orig_plugin, orig_rules, orig_hooks = m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR
    m.REPO_ROOT = tdp
    m.PLUGIN_ROOT = tdp / "plugins" / "rein-core"
    m.RULES_DIR = m.PLUGIN_ROOT / "rules"
    m.HOOKS_DIR = m.PLUGIN_ROOT / "hooks"
    m.RULES_DIR.mkdir(parents=True)
    (m.RULES_DIR / "foo.md").write_text("# Foo\n\n## Not Mandate\nblah\n", encoding="utf-8")
    errs = []
    m.check_action_mandate(errs)
    assert any("missing '## 행동 강령'" in e for e in errs), f"(b) expected missing-mandate error, got: {errs}"
    m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR = orig_repo, orig_plugin, orig_rules, orig_hooks

# (c) mandate too large
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    orig_repo, orig_plugin, orig_rules, orig_hooks = m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR
    m.REPO_ROOT = tdp
    m.PLUGIN_ROOT = tdp / "plugins" / "rein-core"
    m.RULES_DIR = m.PLUGIN_ROOT / "rules"
    m.HOOKS_DIR = m.PLUGIN_ROOT / "hooks"
    m.RULES_DIR.mkdir(parents=True)
    big = "A" * 3000
    (m.RULES_DIR / "bar.md").write_text(f"# Bar\n\n## 행동 강령\n{big}\n", encoding="utf-8")
    errs = []
    m.check_action_mandate(errs)
    assert any("action mandate size" in e for e in errs), f"(c) expected size error, got: {errs}"
    m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR = orig_repo, orig_plugin, orig_rules, orig_hooks

# (d) dev-only rule present
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    orig_repo, orig_plugin, orig_rules, orig_hooks = m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR
    m.REPO_ROOT = tdp
    m.PLUGIN_ROOT = tdp / "plugins" / "rein-core"
    m.RULES_DIR = m.PLUGIN_ROOT / "rules"
    m.HOOKS_DIR = m.PLUGIN_ROOT / "hooks"
    m.RULES_DIR.mkdir(parents=True)
    (m.RULES_DIR / "branch-strategy.md").write_text("# X\n\n## 행동 강령\nshort\n", encoding="utf-8")
    errs = []
    m.check_action_mandate(errs)
    assert any("dev-only rule shipped in plugin" in e for e in errs), f"(d) expected dev-only error, got: {errs}"
    m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR = orig_repo, orig_plugin, orig_rules, orig_hooks

print("test-rein-validate-plugin-rules: all synthetic scenarios PASS")
PY

echo "test-rein-validate-plugin-rules: OK"
