#!/usr/bin/env bash
# .claude/hooks/lib/test-oracle-log.sh
#
# Shared helper for appending High-severity bad-test detections to
# trail/incidents/bad-test-candidates.log per Plan B Task 5.2.
#
# Scope IDs:
#   - TO-rollout-detection-log-high-only
#
# Contract:
#   - Appends iff would_be_high=true AND severity != Low.
#   - MATCH / PARTIAL / Low / would_be_high=false are noise and are not recorded.
#   - Line format: ISO8601 | k=v | k=v | ...  (space between fields, ' | '
#     separator) — design §7.
#   - PROJECT_DIR env var determines the log root. Falls back to git root.
#
# Usage:
#   source .claude/hooks/lib/test-oracle-log.sh
#   bad_test_log_append pr=142 test=test_foo status=CONTRADICTS \
#     corroboration=design+scope-id would_be_high=true confirmed=unknown

set -u

bad_test_log_append() {
  # Parse k=v pairs into local vars; skip unknown keys silently to stay
  # forward-compatible with envelope emitters.
  local pr="" test="" status="" corroboration="" would_be_high="" confirmed=""
  local severity=""
  local arg key val
  for arg in "$@"; do
    key="${arg%%=*}"
    val="${arg#*=}"
    case "$key" in
      pr)             pr="$val" ;;
      test)           test="$val" ;;
      status)         status="$val" ;;
      corroboration)  corroboration="$val" ;;
      would_be_high)  would_be_high="$val" ;;
      confirmed)      confirmed="$val" ;;
      severity)       severity="$val" ;;
    esac
  done

  # Filter: only High-severity gets logged (design §7 detection log scope).
  # would_be_high=true during warn-only phase, severity=High after promotion.
  if [ "${would_be_high:-}" != "true" ] && [ "${severity:-}" != "High" ]; then
    return 0
  fi
  # Defensive: still skip explicit Low.
  if [ "${severity:-}" = "Low" ]; then
    return 0
  fi

  local project
  project="${PROJECT_DIR:-}"
  if [ -z "$project" ]; then
    project=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
  local log_path="$project/trail/incidents/bad-test-candidates.log"
  mkdir -p "$(dirname "$log_path")"

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Compose the line. Skip empty fields for readability but always keep ts.
  local line="$ts"
  [ -n "$pr" ]             && line="$line | pr=$pr"
  # During warn-only the severity column reads "would-be-high"; after
  # promotion the caller can pass severity=High directly.
  if [ "${would_be_high:-}" = "true" ] && [ -z "${severity:-}" ]; then
    line="$line | would-be-high"
  elif [ -n "${severity:-}" ]; then
    line="$line | $severity"
  fi
  [ -n "$test" ]           && line="$line | test=$test"
  [ -n "$status" ]         && line="$line | $status"
  [ -n "$corroboration" ]  && line="$line | corroboration=$corroboration"
  [ -n "$confirmed" ]      && line="$line | confirmed=$confirmed"

  printf '%s\n' "$line" >> "$log_path"
  return 0
}
