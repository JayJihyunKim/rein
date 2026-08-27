#!/bin/bash
# plugins/rein-core/hooks/lib/stamp-parse.sh
#
# Review-stamp parser + ISO normalize helpers (M2/M3, spec 2026-06-16).
# `_parse_stamp_field` / `_normalize_iso` are pure, side-effect-free helpers
# used by the code-review axis's P5 (M3 code-stamp dual-read) and the
# security-review axis's P6 (M2 security-stamp freshness) checks.
#
# Origin: originally defined INLINE in hooks/pre-bash-test-commit-gate.sh
# (before that hook's stdin read / resolver calls, so its own
# REIN_GATE_SOURCE_ONLY test-harness guard could expose them without running
# the gate body). hooks/lib/code-review-gate.sh and
# hooks/lib/security-review-gate.sh consumed them only via call-time bash
# scope — they never sourced a copy of their own, relying entirely on
# whichever hook happened to source them first.
#
# Reason for the move (2026-08-19, user-directed): Phase 7 of the v2
# authority rollout plans to delete pre-bash-test-commit-gate.sh once its
# gate body is fully delegated. Deleting that file would silently break both
# lib/code-review-gate.sh and lib/security-review-gate.sh — their P5/P6
# checks call `_parse_stamp_field`/`_normalize_iso`, and with the inline
# definitions gone those calls would fail with "command not found" (and,
# because the callers are `x=$(cmd)` substitutions rather than `set -e`
# guarded statements, that failure degrades SILENTLY into an empty value
# rather than an obvious crash — see each caller's fail-closed handling of
# an empty parse result). This scope-only dependency was a hidden removal-
# order constraint: the hook could not be deleted before its two dependents
# stopped relying on being sourced-into by it. This file makes the
# dependency an explicit, standalone library so the two gate libs no longer
# need pre-bash-test-commit-gate.sh (or any other sourcing hook) to define
# these functions for them.
#
# This is a pure relocation — the two function bodies below are byte-
# identical to their original inline definitions; no behavior changed.
#
# Consumers:
#   hooks/lib/code-review-gate.sh      — rein_check_code_review_stamp() P5
#   hooks/lib/security-review-gate.sh  — rein_check_security_review_stamp() P6
#   hooks/pre-bash-test-commit-gate.sh — sources this directly too (in
#     addition to receiving it transitively via the two libs above) so its
#     own lib-load contract stays self-describing rather than depending on
#     an incidental side effect of sourcing a sibling lib.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/stamp-parse.sh"
#   val=$(_parse_stamp_field "$file" "verdict" ": ")
#   norm=$(_normalize_iso "$raw_ts") || norm=""

if [ -n "${__REIN_STAMP_PARSE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_STAMP_PARSE_LOADED=1

# _parse_stamp_field FILE KEY SEP
#   Extract the value of KEY<SEP>... from FILE's first matching line.
#   SEP is the literal separator after the key (": " for the code stamp,
#   "=" for the security stamp). Trailing whitespace is stripped. Prints the
#   value to stdout; prints nothing (empty = fail-closed sentinel) when the
#   file is absent, the key is absent, or the value is empty. Always rc 0 —
#   callers treat an empty result as the fail-closed condition (§6.3).
_parse_stamp_field() {
  local file="$1" key="$2" sep="$3"
  [ -f "$file" ] || return 0
  # Anchor the key at line start; match the literal separator; capture the rest.
  # `head -1` keeps only the first occurrence. sed strips the "key+sep" prefix
  # and any trailing whitespace. The separator may contain a space (": "), so we
  # match the key followed by optional spaces + the separator's non-space core.
  local line val
  line=$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*${sep%% *}" "$file" 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  # Remove everything up to and including the first separator occurrence.
  case "$sep" in
    ": ")
      val=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//")
      ;;
    "=")
      val=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//")
      ;;
    *)
      val=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*${sep}[[:space:]]*//")
      ;;
  esac
  # Strip trailing whitespace.
  val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+$//')
  printf '%s' "$val"
}

# _normalize_iso TS
#   Normalize an ISO-8601 UTC timestamp for lexicographic comparison: unify the
#   trailing `Z` (the security stamp may use a `Z`-less +%Y-%m-%dT%H:%M:%S
#   variant, spec §6.2) by stripping it, so `...T02:00:00Z` and `...T02:00:00`
#   compare equal. Validates the shape `YYYY-MM-DDTHH:MM:SS` (with optional
#   trailing Z); non-ISO input → no stdout + rc 1 (fail-closed sentinel) so a
#   garbage value can never produce a comparable string that passes freshness.
_normalize_iso() {
  local ts="$1"
  # Strip a single trailing Z if present.
  ts="${ts%Z}"
  # Must match YYYY-MM-DDTHH:MM:SS exactly (date + 'T' + time, second res).
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9])
      printf '%s' "$ts"
      return 0
      ;;
    *)
      # Fail-closed: non-ISO → no comparable value.
      return 1
      ;;
  esac
}
