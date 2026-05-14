#!/bin/bash
# tests/cli/test-install.sh
#
# E2E tests for install.sh — rein CLI installer.
# Uses HOME override + local repo path to simulate network install.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$PROJECT_DIR/install.sh"
REIN_SH="$PROJECT_DIR/scripts/rein.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
  echo "FAIL: install.sh not found at $INSTALL_SH" >&2
  exit 1
fi

TEST_COUNT=0
FAIL_COUNT=0

start_test() {
  TEST_COUNT=$((TEST_COUNT + 1))
  CURRENT_TEST="$1"
  echo "TEST: $CURRENT_TEST"
}

pass() { echo "  PASS"; }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

setup_fake_home() {
  FAKE_HOME=$(mktemp -d "/tmp/rein-install-test-XXXXXX")
  export HOME="$FAKE_HOME"
  export REIN_INSTALL_SOURCE="$REIN_SH"  # local copy instead of curl
  export REIN_INSTALL_YES=1              # non-interactive
}

teardown_fake_home() {
  [[ -n "${FAKE_HOME:-}" && -d "$FAKE_HOME" ]] && rm -rf "$FAKE_HOME"
  unset HOME FAKE_HOME REIN_INSTALL_SOURCE REIN_INSTALL_YES
  export HOME="$ORIG_HOME"
}

ORIG_HOME="$HOME"

# ---------------------------------------------------------------------------
# Test: install_clean_state_creates_bin_and_env
# ---------------------------------------------------------------------------
start_test "install_clean_state_creates_bin_and_env"
setup_fake_home
bash "$INSTALL_SH" > "$FAKE_HOME/install.log" 2>&1
if [[ -x "$FAKE_HOME/.rein/bin/rein" && -f "$FAKE_HOME/.rein/env" ]]; then
  pass
else
  fail "~/.rein/bin/rein or ~/.rein/env missing"
  cat "$FAKE_HOME/install.log"
fi
teardown_fake_home

# ---------------------------------------------------------------------------
# Test: install_creates_env_with_path_export
# ---------------------------------------------------------------------------
start_test "install_creates_env_with_path_export"
setup_fake_home
bash "$INSTALL_SH" > "$FAKE_HOME/install.log" 2>&1
if grep -q 'PATH="\$HOME/.rein/bin:\$PATH"' "$FAKE_HOME/.rein/env"; then
  pass
else
  fail "~/.rein/env missing PATH export"
  cat "$FAKE_HOME/.rein/env" 2>&1 || true
fi
teardown_fake_home

# ---------------------------------------------------------------------------
# Test: detect_shell_rc_prefers_zshrc_when_shell_is_zsh
# ---------------------------------------------------------------------------
start_test "detect_shell_rc_prefers_zshrc_when_shell_is_zsh"
setup_fake_home
touch "$FAKE_HOME/.zshrc" "$FAKE_HOME/.bashrc"
export SHELL="/bin/zsh"
# Source install.sh functions without running main
INSTALL_SOURCED=1 source "$INSTALL_SH"
result=$(detect_shell_rc)
if [[ "$result" == "$FAKE_HOME/.zshrc" ]]; then
  pass
else
  fail "expected .zshrc, got: $result"
fi
unset SHELL
teardown_fake_home

# ---------------------------------------------------------------------------
# Test: install_adds_env_source_to_zshrc_when_yes
# ---------------------------------------------------------------------------
start_test "install_adds_env_source_to_zshrc_when_yes"
setup_fake_home
touch "$FAKE_HOME/.zshrc"
export SHELL="/bin/zsh"
bash "$INSTALL_SH" > "$FAKE_HOME/install.log" 2>&1
if grep -q '\. "\$HOME/.rein/env"' "$FAKE_HOME/.zshrc"; then
  pass
else
  fail ".zshrc missing env source line"
  cat "$FAKE_HOME/.zshrc"
fi
unset SHELL
teardown_fake_home

# ---------------------------------------------------------------------------
# Test: install_does_not_duplicate_env_source_line
# ---------------------------------------------------------------------------
start_test "install_does_not_duplicate_env_source_line"
setup_fake_home
echo '. "$HOME/.rein/env"' > "$FAKE_HOME/.zshrc"
export SHELL="/bin/zsh"
bash "$INSTALL_SH" > "$FAKE_HOME/install.log" 2>&1
count=$(grep -c '\. "\$HOME/.rein/env"' "$FAKE_HOME/.zshrc")
if [[ "$count" -eq 1 ]]; then
  pass
else
  fail "expected 1 occurrence, found $count"
fi
unset SHELL
teardown_fake_home

# ---------------------------------------------------------------------------
# Test: install_warns_about_old_usr_local_bin_rein
# ---------------------------------------------------------------------------
start_test "install_warns_about_old_usr_local_bin_rein"
setup_fake_home
# Simulate old install by creating a fake path; we can't touch /usr/local/bin
# in tests, so we inject a test hook via REIN_OLD_INSTALL_PATH.
FAKE_OLD=$(mktemp "/tmp/fake-old-rein-XXXXXX")
echo '#!/bin/bash' > "$FAKE_OLD"
chmod +x "$FAKE_OLD"
export REIN_OLD_INSTALL_PATH="$FAKE_OLD"
bash "$INSTALL_SH" > "$FAKE_HOME/install.log" 2>&1
if grep -q "Old installation detected" "$FAKE_HOME/install.log"; then
  pass
else
  fail "missing old install warning"
  cat "$FAKE_HOME/install.log"
fi
rm -f "$FAKE_OLD"
unset REIN_OLD_INSTALL_PATH
teardown_fake_home

echo ""
echo "Total: $TEST_COUNT, Failed: $FAIL_COUNT"
exit $FAIL_COUNT
