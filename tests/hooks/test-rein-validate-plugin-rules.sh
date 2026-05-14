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
grep -qE "(^OK:|rein-check-plugin-drift: OK)" /tmp/rein-vpr-a.out || {
  echo "FAIL (a): missing OK baseline marker on stdout (expected legacy 'OK:' or new 'rein-check-plugin-drift: OK')" >&2
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
# Option C Phase 2 (2026-05-13): validator 6 check 가 rein-check-plugin-drift.py
# 로 흡수됨. check 함수는 (repo_root, errors) 인자 받는 형태로 변경 — monkeypatch
# 없이 직접 호출.
python3 - <<'PY' || exit 1
import sys, importlib.util, tempfile, shutil, pathlib

spec = importlib.util.spec_from_file_location("drift_checker", "scripts/rein-check-plugin-drift.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# (b) missing mandate
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    rules_dir = tdp / "plugins" / "rein-core" / "rules"
    rules_dir.mkdir(parents=True)
    (rules_dir / "foo.md").write_text("# Foo\n\n## Not Mandate\nblah\n", encoding="utf-8")
    errs = []
    m.check_action_mandate(tdp, errs)
    assert any("missing '## 행동 강령'" in e for e in errs), f"(b) expected missing-mandate error, got: {errs}"

# (c) mandate too large
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    rules_dir = tdp / "plugins" / "rein-core" / "rules"
    rules_dir.mkdir(parents=True)
    big = "A" * 3000
    (rules_dir / "bar.md").write_text(f"# Bar\n\n## 행동 강령\n{big}\n", encoding="utf-8")
    errs = []
    m.check_action_mandate(tdp, errs)
    assert any("action mandate size" in e for e in errs), f"(c) expected size error, got: {errs}"

# (d) dev-only rule present
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    rules_dir = tdp / "plugins" / "rein-core" / "rules"
    rules_dir.mkdir(parents=True)
    (rules_dir / "branch-strategy.md").write_text("# X\n\n## 행동 강령\nshort\n", encoding="utf-8")
    errs = []
    m.check_action_mandate(tdp, errs)
    assert any("dev-only rule shipped in plugin" in e for e in errs), f"(d) expected dev-only error, got: {errs}"

print("test-rein-validate-plugin-rules: all synthetic scenarios PASS")
PY

echo "test-rein-validate-plugin-rules: OK"
