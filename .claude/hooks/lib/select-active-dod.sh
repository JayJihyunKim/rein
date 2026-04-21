#!/bin/bash
# .claude/hooks/lib/select-active-dod.sh
# Shared DoD-selection function used by
#   .claude/hooks/pre-edit-dod-gate.sh   (Phase 4)
#   scripts/rein-codex-review.sh         (Phase 6 — future dispatch)
#
# Scope IDs:
#   - GI-dod-gate-active-dod-selection
#   - GI-dod-gate-selector-shared-with-codex-review
#
# Design (Spec A §4.1): 2-tier selection.
#
#   Tier 1 — explicit marker (blocking authority):
#     trail/dod/.active-dod exists AND has a valid `path=<…>` that resolves
#     to a DoD with `## 범위 연결`. Invalid markers fall through to Tier 2
#     and log to trail/incidents/invalid-active-dod-marker.log.
#
#   Tier 2 — advisory fallback (non-blocking authority):
#     Most recent DoD under trail/dod/ that has `## 범위 연결`, tie-broken
#     by slug lex order. Still runs the validator but failures are
#     advisory-only (caller writes .dod-coverage-advisory).
#
#   Tier 0 — no candidate DoD: caller emits warning and returns exit 0.
#
# No caching is performed (GI-dod-gate-cache-invalidation) — the scan is
# cheap (marker stat O(1), trail/dod glob O(n) with n≈10).
#
# Usage:
#   source "$(dirname "$0")/lib/select-active-dod.sh"
#   result=$(select_active_dod)        # "<tier>\t<dod_path>\t<reason>"
#   tier="${result%%$'\t'*}"
#
# Output format (stdout): exactly one line "<tier>\t<dod_path>\t<reason>".
#   tier       "0" | "1" | "2"
#   dod_path   repo-relative path, or empty string if tier=0
#   reason     short human description (no tabs, no newlines)
#
# The function always returns 0; caller inspects the tier to decide.

if [ -n "${__REIN_SELECT_ACTIVE_DOD_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_SELECT_ACTIVE_DOD_LOADED=1

# _sad_dod_has_range_link: return 0 iff a DoD file contains `## 범위 연결`.
_sad_dod_has_range_link() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -q '^## 범위 연결' "$path" 2>/dev/null
}

# _sad_log_invalid_marker: append one line to the incident log.
# Arguments: <reason>
_sad_log_invalid_marker() {
  local reason="$1"
  local log="trail/incidents/invalid-active-dod-marker.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$reason" >> "$log" 2>/dev/null || true
}

# _sad_record_session_choice: append one line to active-dod-choice.log, but
# only once per session. Session key defaults to ${REIN_SESSION_ID:-PPID};
# the marker file is .claude/cache/active-dod-choice.session-<key>.flag.
_sad_record_session_choice() {
  local tier="$1"
  local path="$2"
  local reason="$3"
  local cache_dir=".claude/cache"
  local log="$cache_dir/active-dod-choice.log"
  local key="${REIN_SESSION_ID:-${PPID:-$$}}"
  local flag="$cache_dir/active-dod-choice.session-${key}.flag"
  mkdir -p "$cache_dir" 2>/dev/null || true
  # Only append once per session (per spec §4.1 note).
  if [ -f "$flag" ]; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" "$tier" "$path" "$reason" >> "$log" 2>/dev/null || true
  : > "$flag" 2>/dev/null || true
}

# select_active_dod: emit "<tier>\t<dod_path>\t<reason>" on stdout.
select_active_dod() {
  local marker="trail/dod/.active-dod"
  local path=""
  local tier="0"
  local reason=""

  # ---- Tier 1: explicit marker.
  if [ -f "$marker" ]; then
    local marker_path
    marker_path=$(grep '^path=' "$marker" 2>/dev/null | head -1 | sed 's/^path=//')
    if [ -n "$marker_path" ]; then
      if [ -f "$marker_path" ]; then
        if _sad_dod_has_range_link "$marker_path"; then
          tier="1"
          path="$marker_path"
          reason="marker-blocking"
        else
          _sad_log_invalid_marker "marker target missing '## 범위 연결': $marker_path"
          # fall through to Tier 2
        fi
      else
        _sad_log_invalid_marker "marker target does not exist: $marker_path"
        # fall through to Tier 2
      fi
    else
      _sad_log_invalid_marker "marker file has no 'path=' line"
      # fall through to Tier 2
    fi
  fi

  # ---- Tier 2: advisory fallback (most recent DoD with `## 범위 연결`).
  if [ "$tier" = "0" ]; then
    if [ -d "trail/dod" ]; then
      # Build list of candidates: all dod-*.md with `## 범위 연결`.
      # Sort by mtime desc, tie-break by slug ascending.
      # We use find + stat-epoch via python3 helper if available; otherwise
      # rely on a plain `ls -t` which is good enough for tie-break within
      # 1-second resolution.
      local best_path=""
      local best_mtime=""
      local best_slug=""
      while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        _sad_dod_has_range_link "$f" || continue
        local mt
        # Prefer python3 (portable); fallback to stat (macOS: -f %m, GNU: -c %Y)
        mt=$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$f" 2>/dev/null \
             || stat -f '%m' "$f" 2>/dev/null \
             || stat -c '%Y' "$f" 2>/dev/null \
             || echo "0")
        local slug
        slug="$(basename "$f")"
        if [ -z "$best_path" ]; then
          best_path="$f"
          best_mtime="$mt"
          best_slug="$slug"
          continue
        fi
        if [ "$mt" -gt "$best_mtime" ] 2>/dev/null; then
          best_path="$f"
          best_mtime="$mt"
          best_slug="$slug"
        elif [ "$mt" = "$best_mtime" ]; then
          # Tie-break: lexicographically smaller slug wins.
          if [ "$slug" \< "$best_slug" ]; then
            best_path="$f"
            best_slug="$slug"
          fi
        fi
      done < <(find trail/dod -maxdepth 1 -type f -name 'dod-*.md' -print0 2>/dev/null)
      if [ -n "$best_path" ]; then
        tier="2"
        path="$best_path"
        reason="advisory-latest-mtime"
      fi
    fi
  fi

  # Record selection once per session (no caching of the result itself).
  _sad_record_session_choice "$tier" "$path" "$reason"

  printf '%s\t%s\t%s\n' "$tier" "$path" "$reason"
  return 0
}
