#!/usr/bin/env bash
# tests/scripts/test-policy-loader-meta-check.sh — G3 Phase 4 Task 4.3
#
# Verifies `rein-policy-loader.py --meta-check-policy` CLI mode returns the
# correct effective policy ('true' | 'false' | 'auto') for 5 fixtures,
# always exit 0, fail-open on every error path.
#
# Scope ID: G3-MC-POLICY
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"
[ -f "$LOADER" ] || { echo "FAIL: $LOADER missing" >&2; exit 1; }

FAILED=0

# fixture <name> <yaml_content_or_empty> <expected_stdout> [expected_stderr_substring]
fixture() {
  local name="$1"
  local yaml_content="$2"
  local expected="$3"
  local expect_stderr="${4:-}"

  local tmp
  tmp=$(mktemp -d "/tmp/policy-meta-XXXXXX")
  if [ -n "$yaml_content" ]; then
    mkdir -p "$tmp/.rein/policy"
    printf '%s' "$yaml_content" > "$tmp/.rein/policy/meta-check.yaml"
  fi

  local out_file err_file
  out_file=$(mktemp)
  err_file=$(mktemp)

  set +e
  (cd "$tmp" && python3 "$LOADER" --meta-check-policy >"$out_file" 2>"$err_file")
  local rc=$?
  set -e

  local got
  got=$(cat "$out_file")

  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$name]: exit $rc (expected 0)" >&2
    FAILED=$((FAILED+1))
  elif [ "$got" != "$expected" ]; then
    echo "FAIL [$name]: stdout expected '$expected' got '$got'" >&2
    FAILED=$((FAILED+1))
  elif [ -n "$expect_stderr" ] && ! grep -q "$expect_stderr" "$err_file"; then
    echo "FAIL [$name]: stderr expected to contain '$expect_stderr', got:" >&2
    cat "$err_file" >&2
    FAILED=$((FAILED+1))
  else
    echo "OK [$name]: stdout='$got'"
  fi

  rm -rf "$tmp" "$out_file" "$err_file"
}

# Fixture 1: 파일 부재 → 'auto'
fixture "missing-file" "" "auto"

# Fixture 2: enabled: true → 'true'
fixture "enabled-true" "enabled: true
" "true"

# Fixture 3: enabled: false → 'false'
fixture "enabled-false" "enabled: false
" "false"

# Fixture 4: malformed yaml → 'auto' + stderr warning
fixture "malformed-yaml" "enabled: [{ invalid" "auto" "warning"

# Fixture 5: PyYAML 부재 시뮬레이션 (PYTHONPATH 으로 fake yaml 주입 → 'auto')
echo "--- fixture 5: pyyaml-absent ---"
PYYAML_TMP=$(mktemp -d "/tmp/no-pyyaml-XXXXXX")
cat > "$PYYAML_TMP/yaml.py" << 'PY'
raise ImportError("simulated PyYAML absence — G3 Phase 4 Task 4.3 fixture 5")
PY
SANDBOX=$(mktemp -d "/tmp/policy-pyyaml-XXXXXX")
mkdir -p "$SANDBOX/.rein/policy"
printf 'enabled: true\n' > "$SANDBOX/.rein/policy/meta-check.yaml"

set +e
GOT=$(cd "$SANDBOX" && PYTHONPATH="$PYYAML_TMP" python3 "$LOADER" --meta-check-policy 2>/dev/null)
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "FAIL [pyyaml-absent]: exit $RC (expected 0)" >&2
  FAILED=$((FAILED+1))
elif [ "$GOT" != "auto" ]; then
  echo "FAIL [pyyaml-absent]: expected 'auto', got '$GOT'" >&2
  FAILED=$((FAILED+1))
else
  echo "OK [pyyaml-absent]: stdout='$GOT' (fail-open with enabled:true ignored)"
fi
rm -rf "$PYYAML_TMP" "$SANDBOX"

if [ "$FAILED" -gt 0 ]; then
  echo "test-policy-loader-meta-check: FAIL ($FAILED fixture(s))" >&2
  exit 1
fi

echo "test-policy-loader-meta-check: OK (5/5 fixtures)"
