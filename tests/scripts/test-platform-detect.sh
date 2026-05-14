#!/usr/bin/env bash
# test-platform-detect.sh — Plan C Task 1.1
# Verifies detect_platform() returns "posix" on Linux/Darwin,
# "windows_git_bash" on MINGW*/MSYS*.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load functions without running main
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/rein.sh" --source-only

result=$(detect_platform)

case "$(uname -s)" in
  Linux|Darwin)
    if [ "$result" != "posix" ]; then
      echo "FAIL: expected 'posix' on $(uname -s), got '$result'" >&2
      exit 1
    fi
    ;;
  MINGW*|MSYS*)
    if [ "$result" != "windows_git_bash" ]; then
      echo "FAIL: expected 'windows_git_bash' on $(uname -s), got '$result'" >&2
      exit 1
    fi
    ;;
  *)
    # Unsupported platform — detect_platform should have printed an error.
    echo "SKIP: unsupported uname $(uname -s)"
    exit 0
    ;;
esac

echo "test-platform-detect: OK ($result)"
