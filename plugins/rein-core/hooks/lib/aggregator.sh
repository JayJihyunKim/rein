#!/usr/bin/env bash
# Plugin dispatcher aggregator helper.
#
# Collects multiple sub-hook (stdout, exit_code) pairs and emits a single
# PostToolUse JSON envelope concatenating each sub-hook's
# additionalContext separated by `\n\n---\n\n`. Sub-hook exit codes are
# tracked so the dispatcher can propagate exit 2 (hard block) from any
# sub-hook while ignoring other nonzero exits (best-effort).
#
# Exit-code policy (explicit — numeric max is NOT used):
#   - any sub-hook exit 2  -> aggregator_exit_code echoes "2" (hard block)
#   - other nonzero exits  -> stderr diagnostic; dispatcher still exits 0
#   - 127 (sub-hook missing) does NOT override 2; the order of aggregator_add
#     calls does not matter — exit-2 propagation is OR-based, not max-based.
#
# Functions:
#   aggregator_init                    — reset state
#   aggregator_add <stdout> <exit>     — record one sub-hook result
#   aggregator_emit                    — write the single envelope to stdout
#   aggregator_exit_code               — echo "2" if any sub-hook exit 2, else "0"
#
# Usage:
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/aggregator.sh"
#   aggregator_init
#   for sub in ...; do
#     out=$(bash "$sub" <<<"$INPUT"); rc=$?
#     aggregator_add "$out" "$rc"
#   done
#   aggregator_emit
#   exit "$(aggregator_exit_code)"
#
# NOTE: this file does NOT set `pipefail` globally — the dispatcher pipes
# `printf "$INPUT" | sub-hook` to feed stdin, and a closed-stdin sub-hook
# (cache-mode) triggers SIGPIPE on printf which would surface as a fake
# nonzero rc under pipefail. The dispatcher captures `$?` of the sub-hook
# explicitly, so we only need `set -u` here.

AGG_CONTEXTS=()
AGG_HAS_EXIT2=0

aggregator_init() {
  AGG_CONTEXTS=()
  AGG_HAS_EXIT2=0
}

aggregator_add() {
  local sub_stdout="${1:-}"
  local sub_exit="${2:-0}"
  if [ "$sub_exit" = "2" ]; then
    AGG_HAS_EXIT2=1
  elif [ "$sub_exit" != "0" ]; then
    # Best-effort: log to stderr but don't fail the dispatcher.
    echo "rein-dispatcher: sub-hook exit $sub_exit (ignored — not a hard block)" >&2
  fi
  [ -z "$sub_stdout" ] && return 0
  # Parse and extract additionalContext if envelope is valid JSON.
  # The python helper writes either:
  #   - the additionalContext string to stdout (valid envelope), OR
  #   - a "rein-dispatcher:" diagnostic to stderr (invalid envelope).
  # We capture the two streams separately so a diagnostic never leaks
  # into AGG_CONTEXTS.
  local ctx diag
  local tmp_err
  tmp_err=$(mktemp -t rein-agg.XXXXXX 2>/dev/null) || tmp_err=""
  if [ -n "$tmp_err" ]; then
    ctx=$(printf '%s' "$sub_stdout" | python3 -c '
import sys, json
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        hso = data.get("hookSpecificOutput")
        if isinstance(hso, dict):
            c = hso.get("additionalContext", "")
            if isinstance(c, str):
                sys.stdout.write(c)
                sys.exit(0)
    # Valid JSON but wrong shape — treat as invalid envelope.
    sys.stderr.write("rein-dispatcher: sub-hook stdout is not a valid JSON envelope — ignored\n")
except Exception:
    sys.stderr.write("rein-dispatcher: sub-hook stdout is not a valid JSON envelope — ignored\n")
' 2>"$tmp_err")
    if [ -s "$tmp_err" ]; then
      cat "$tmp_err" >&2
    fi
    rm -f "$tmp_err" 2>/dev/null
  else
    # mktemp failed — fall back to merged capture, then strip diagnostic.
    ctx=$(printf '%s' "$sub_stdout" | python3 -c '
import sys, json
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        hso = data.get("hookSpecificOutput")
        if isinstance(hso, dict):
            c = hso.get("additionalContext", "")
            if isinstance(c, str):
                sys.stdout.write(c)
                sys.exit(0)
    sys.stderr.write("rein-dispatcher: sub-hook stdout is not a valid JSON envelope — ignored\n")
except Exception:
    sys.stderr.write("rein-dispatcher: sub-hook stdout is not a valid JSON envelope — ignored\n")
' 2>/dev/null)
  fi
  [ -n "$ctx" ] && AGG_CONTEXTS+=("$ctx")
}

aggregator_emit() {
  if [ "${#AGG_CONTEXTS[@]}" -eq 0 ]; then
    return 0
  fi
  # Markdown-only transport: rule bodies are UTF-8 markdown so they cannot
  # contain NUL bytes. We use \0 as the inter-segment delimiter to preserve
  # every other byte (including newlines) inside each segment exactly. Note
  # that bash command substitution itself cannot carry NUL bytes through
  # $(...) capture, but that is fine here because the python helper writes
  # the joined string (with NULs already split out) back to stdout. If a
  # future rule body could legitimately contain \0 bytes, replace this with
  # a length-prefixed framing.
  local joined
  joined=$(printf '%s\0' "${AGG_CONTEXTS[@]}" | python3 -c '
import sys
raw = sys.stdin.buffer.read().rstrip(b"\x00")
parts = raw.split(b"\x00")
sys.stdout.write("\n\n---\n\n".join(p.decode("utf-8") for p in parts))
')
  local escaped
  escaped=$(printf '%s' "$joined" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$escaped"
}

aggregator_exit_code() {
  if [ "$AGG_HAS_EXIT2" = "1" ]; then echo 2; else echo 0; fi
}
