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
#   - $FAKE_CODEX_VERDICT_FILE (set + readable) overrides $FAKE_CODEX_VERDICT —
#     body is read from the file. Large payloads (>100KB, e.g. the D1 SIGPIPE
#     regression test) cannot ride an env var without hitting ARG_MAX in the
#     wrapper's child processes; a file path keeps the env small.
#   - Exits with $FAKE_CODEX_EXIT (default: 0).
#
# The wrapper parses stdout for PASS / NEEDS-FIX / REJECT.

set -u

# Subcommand might be `exec`, `exec resume`, etc. — swallow everything.
# Read all stdin (prompt/envelope).
capture_file="${FAKE_CODEX_CAPTURE:-}"
verdict_file="${FAKE_CODEX_VERDICT_FILE:-}"
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

if [ -n "$verdict_file" ] && [ -r "$verdict_file" ]; then
  cat "$verdict_file"
else
  printf '%s\n' "$verdict"
fi
exit "$exit_code"
