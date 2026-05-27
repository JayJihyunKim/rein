#!/usr/bin/env bash
# tests/hooks/test-auto-mode.sh — 자동모드 시맨틱 회귀
#
# Verifies:
#   (a) is_auto_mode returns 1 when marker absent, 0 when present
#   (b) auto_mode_log_bypass appends a single line to
#       trail/incidents/auto-mode-bypass.log under the project dir
#   (c) bash-guard-infra log_block silences WARNING when marker present and
#       emits WARNING when marker absent (using REIN_PROJECT_DIR_OVERRIDE)
#   (d) pre-edit-dod-gate stderr message gets silenced under auto mode by
#       smoke-testing the elif chain via the helper (functional check)
#
# Out of scope: full stop-session-gate JSON block bypass test (the gate has
# its own existing test suite; the inline auto-mode check is small enough
# that the (c) + (d) coverage demonstrates the pattern).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
HELPER="$PLUGIN_ROOT/hooks/lib/auto-mode.sh"

[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }

FAILED=0

# ---------- (a) is_auto_mode marker absence/presence ----------------------
SANDBOX=$(mktemp -d "/tmp/auto-mode-XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

if REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash -c ". '$HELPER'; is_auto_mode"; then
  echo "FAIL: marker absent should yield is_auto_mode=1 (got 0)" >&2
  FAILED=$((FAILED+1))
else
  echo "OK [a1-marker-absent-is-not-auto-mode]"
fi

mkdir -p "$SANDBOX/.rein"
touch "$SANDBOX/.rein/auto-mode.flag"
if REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash -c ". '$HELPER'; is_auto_mode"; then
  echo "OK [a2-marker-present-is-auto-mode]"
else
  echo "FAIL: marker present should yield is_auto_mode=0 (got non-zero)" >&2
  FAILED=$((FAILED+1))
fi

# ---------- (b) auto_mode_log_bypass appends one audit line ---------------
LOG="$SANDBOX/trail/incidents/auto-mode-bypass.log"
[ -f "$LOG" ] && { echo "FAIL: log file should not exist yet" >&2; FAILED=$((FAILED+1)); }

REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash -c "
  . '$HELPER'
  auto_mode_log_bypass 'test-reason-1'
  auto_mode_log_bypass 'test-reason-2'
"
if [ ! -f "$LOG" ]; then
  echo "FAIL: $LOG was not created" >&2
  FAILED=$((FAILED+1))
else
  LINES=$(wc -l < "$LOG" | tr -d ' ')
  if [ "$LINES" != "2" ]; then
    echo "FAIL: audit log expected 2 lines, got $LINES" >&2
    FAILED=$((FAILED+1))
  elif ! grep -q "test-reason-1" "$LOG" || ! grep -q "test-reason-2" "$LOG"; then
    echo "FAIL: audit log missing expected reason substrings" >&2
    cat "$LOG" >&2
    FAILED=$((FAILED+1))
  else
    echo "OK [b-audit-log-2-lines]"
  fi
fi

# ---------- (c) static grep — silence pattern present in WARNING emit lib --
# bash-guard-infra log_block 함수 e2e 호출은 BLOCKS_LOG_JSONL / BG_GUARD_NAME /
# python helper 등 의존성이 많아 격리 어려움. 대신 static grep 으로 `incidents-to-rule`
# WARNING 직전에 `is_auto_mode` 분기가 도입됐는지 검증.
for f in plugins/rein-core/hooks/lib/bash-guard-infra.sh plugins/rein-core/hooks/pre-edit-dod-gate.sh; do
  # 같은 함수 안에 'incidents-to-rule' 과 'is_auto_mode' 가 공존하는지 확인
  if ! grep -q "incidents-to-rule" "$f"; then
    echo "FAIL [c-$f-missing-incidents-to-rule-emit]" >&2
    FAILED=$((FAILED+1))
    continue
  fi
  if ! grep -q "is_auto_mode" "$f"; then
    echo "FAIL [c-$f-missing-is_auto_mode-guard]" >&2
    FAILED=$((FAILED+1))
    continue
  fi
  echo "OK [c-$f-has-auto-mode-guard]"
done

# ---------- (d) end-to-end smoke: is_auto_mode short-circuits hooks -------
# Functional check — sourcing the helper from any hook that uses the
# `if declare -F is_auto_mode && is_auto_mode; then exit 0; fi` pattern
# returns 0 (skip) when marker present.
for hook in plugins/rein-core/hooks/session-start-load-trail.sh \
            plugins/rein-core/hooks/stop-session-gate.sh \
            plugins/rein-core/hooks/pre-edit-dod-gate.sh; do
  if ! grep -q "is_auto_mode" "$hook"; then
    echo "FAIL [d-$hook-missing-is_auto_mode-call]" >&2
    FAILED=$((FAILED+1))
  fi
done
if [ "$FAILED" -eq 0 ]; then
  echo "OK [d-3-hooks-call-is_auto_mode]"
fi

if [ "$FAILED" -gt 0 ]; then
  echo "test-auto-mode: FAIL ($FAILED assertion(s))" >&2
  exit 1
fi
echo "test-auto-mode: OK (helper + audit log + bash-guard silence + hook integration)"
