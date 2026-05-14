#!/usr/bin/env bash
# tests/fixtures/fake-codex.sh
# Fake `codex` binary for testing rein-codex-review.sh.
#
# Injection seam: wrapper reads CODEX_BIN env var. Tests set
# CODEX_BIN=./tests/fixtures/fake-codex.sh to substitute this stub
# for the real codex CLI.
#
# Contract with the wrapper:
#   - Receives the envelope on stdin (the wrapper pipes it with `| codex exec`).
#   - Ignores all CLI args (model, sandbox, etc.).
#   - Writes the captured stdin prompt to $FAKE_CODEX_CAPTURE (if set).
#   - Emits the verdict body configured via $FAKE_CODEX_VERDICT
#     (default: "PASS\nAll checks clean.") on stdout.
#   - Exits with $FAKE_CODEX_EXIT (default: 0).
#
# The wrapper parses stdout for PASS / NEEDS-FIX / REJECT.

set -u

# Subcommand might be `exec`, `exec resume`, etc. — swallow everything.
# Read all stdin (prompt/envelope).
capture_file="${FAKE_CODEX_CAPTURE:-}"
verdict="${FAKE_CODEX_VERDICT:-PASS
All checks clean.}"
exit_code="${FAKE_CODEX_EXIT:-0}"

if [ -n "$capture_file" ]; then
  # Write stdin (the envelope) to the capture file for golden asserts.
  cat > "$capture_file"
else
  # Discard stdin if no capture requested.
  cat > /dev/null
fi

printf '%s\n' "$verdict"
exit "$exit_code"
