#!/bin/bash
# .claude/hooks/lib/governance-stage.sh
# Parse the rein governance stage from .claude/.rein-state/governance.json.
#
# Scope IDs:
#   - GI-governance-stage-config
#
# Contract (Spec A §6):
#   * No config file → Stage 1 (fresh install / advisory mode).
#   * Malformed JSON or stage value not in {1, 2, 3} → "INVALID".
#     Caller MUST fail-closed on INVALID — "silent Stage 1 downgrade" is a
#     bypass path and is explicitly forbidden.
#
# Usage:
#   source "$(dirname "$0")/lib/governance-stage.sh"
#   STAGE=$(read_governance_stage)   # "1" | "2" | "3" | "INVALID"
#   case "$STAGE" in
#     INVALID) # fail-closed ;;
#     1) # advisory mode ;;
#     2|3) # blocking mode ;;
#   esac
#
# Implementation note:
#   We parse the JSON via `python3 -c` rather than hand-rolled awk/sed to
#   get correct handling of whitespace, nested values, etc. Hooks that
#   already ran `resolve_python` can rely on `python3` being available;
#   those that haven't (e.g. read_governance_stage used standalone) use
#   the plain `python3` PATH lookup and accept that missing Python means
#   INVALID (caller will fail-closed).

if [ -n "${__REIN_GOVERNANCE_STAGE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_GOVERNANCE_STAGE_LOADED=1

# read_governance_stage: prints "1" / "2" / "3" / "INVALID" to stdout.
# Never exits on malformed input — caller decides fail-closed behavior.
read_governance_stage() {
  local config=".claude/.rein-state/governance.json"
  if [ ! -f "$config" ]; then
    echo "1"
    return 0
  fi
  local stage
  # Use python3 to parse — intentionally tolerant of missing python (the
  # governance surface is itself a Python stack, so this is a reasonable
  # base assumption; if python3 is missing, that's already govcheck-broken
  # and caller will surface it via the "INVALID" path).
  stage=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    s = data.get("stage", None)
    if s in (1, 2, 3):
        print(s)
    else:
        print("INVALID")
except Exception:
    print("INVALID")
' "$config" 2>/dev/null)
  case "$stage" in
    1|2|3)
      echo "$stage"
      ;;
    *)
      echo "INVALID"
      ;;
  esac
}
