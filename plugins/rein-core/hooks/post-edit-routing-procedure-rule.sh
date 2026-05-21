#!/usr/bin/env bash
# Plugin PostToolUse(Edit|Write|MultiEdit) sub-hook — routing-procedure rule
# body delivery on DoD write.
#
# Triggers when an Edit/Write/MultiEdit targets a DoD file:
#   - trail/dod/dod-[0-9]*.md
#
# AND when that DoD file does NOT yet contain a `## 라우팅 추천` section.
#
# Emits a PostToolUse envelope containing the routing-procedure rule body so
# the model sees the routing-section template and procedure in the next
# request — fulfilling the promise made by pre-edit-dod-gate.sh and
# post-edit-dod-routing-check.sh stderr messages ("PostToolUse hook 이
# routing 절차 본문 자동 inject").
#
# Silent exit 0 when:
#   - CLAUDE_PLUGIN_ROOT unset (scaffold mode — rule body lives elsewhere)
#   - stdin empty / malformed JSON
#   - file path is not a DoD file (trail/dod/dod-[0-9]*.md)
#   - DoD already contains '## 라우팅 추천' section (no inject needed)
#   - rule body unresolvable
#
# This hook never blocks (no exit 2). It is advisory inject only — the gate
# itself (pre-edit-dod-gate.sh routing-gate block) does the blocking, and
# the .routing-missing-* marker is written by post-edit-dod-routing-check.sh.
#
# Scope ID: routing-procedure-injection-hook-fulfils-pre-edit-dod-gate-stderr-promise-by-emitting-routing-rule-body-on-dod-write-via-post-edit-dispatcher-sub-hook
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# HK-4: 분할 후 dispatcher 가 처리하던 정책 평가를 각 sub-hook 이 자체 호출.
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/post-edit-policy-gate.sh" ]; then
  # shellcheck source=./lib/post-edit-policy-gate.sh
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/post-edit-policy-gate.sh"
  post_edit_policy_gate "post-edit-routing-procedure-rule"
fi

# X4.C.3 fast-path skip — design memo §8.4. effective_mode == answer 는
# Stop 직후 PostToolUse(Edit) 가 fire 된 이상 신호 → envelope skip.
# fail-soft gate: state.json 부재 (greenfield) / malformed JSON / unknown
# schema_version / state-machine.sh 부재 / lock 실패 → legacy path (정상 inject).
# state_is_valid 로 게이트해, read_state 가 corrupt/unknown-schema state 에도
# echo 하는 default "answer" 를 envelope-skip 신호로 오인하지 않는다
# (codex Round 1 HIGH = state 부재, Round 2 HIGH = malformed / unknown schema).
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state-machine.sh" ]; then
  if . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state-machine.sh" 2>/dev/null; then
    # read_effective_mode prints "answer" AND returns non-zero on lock-acquire
    # failure → trust the captured mode only when the read succeeds (exit 0).
    # A failed read falls through to legacy inject (codex Round 3 HIGH).
    if state_is_valid && _fastpath_mode=$(read_effective_mode 2>/dev/null) \
        && [ "$_fastpath_mode" = "answer" ]; then
      exit 0
    fi
  fi
fi

# Hook input on stdin (Claude Code JSON envelope). Extract file_path with
# the same fallback chain used by post-edit-design-plan-coverage-rule.sh:
#   tool_input.file_path  (primary)
#   tool_response.filePath (secondary — Claude Code response field)
#   tool_result.file_path  (legacy tertiary — older payload shape)
INPUT=$(cat || true)
[ -n "$INPUT" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("")
    sys.exit(0)
if not isinstance(data, dict):
    print("")
    sys.exit(0)
ti = data.get("tool_input") or {}
tr = data.get("tool_response") or {}
tl = data.get("tool_result") or {}
p = ""
if isinstance(ti, dict):
    p = ti.get("file_path") or ""
if not p and isinstance(tr, dict):
    p = tr.get("filePath") or ""
if not p and isinstance(tl, dict):
    p = tl.get("file_path") or ""
print(p or "")
' 2>/dev/null || true)

[ -n "$FILE_PATH" ] || exit 0

# Glob match — DoD files only (trail/dod/dod-<numeric-prefix>*.md). Reject
# anything else (specs, plans, source files) silently.
case "$FILE_PATH" in
  */trail/dod/dod-[0-9]*.md|trail/dod/dod-[0-9]*.md) ;;
  *) exit 0 ;;
esac

# Skip when DoD file already has the routing section — no inject needed.
# If file doesn't exist (rare race) we still inject so the model sees the
# template after a future write surfaces it.
if [ -f "$FILE_PATH" ] && grep -q '^## 라우팅 추천' "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# Sentinel idiom — preserve trailing newlines (see rule-inject.sh for
# rationale). The if-then-else inside the subshell makes the subshell rc
# reflect rule_inject_body's rc instead of printf's success.
if ! BODY=$(if rule_inject_body routing-procedure; then printf x; else exit 1; fi); then
  exit 0
fi
BODY="${BODY%x}"
[ -n "$BODY" ] || exit 0

ENVELOPE=$(printf '%s' "$BODY" | python3 -c '
import sys, json
ctx = sys.stdin.read()
env = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ctx}}
sys.stdout.write(json.dumps(env, ensure_ascii=False, separators=(",", ":")))
')

# Phase 2c HK-5: aggregator merge 위해 output cache 에 write 시도. 성공 시
# stdout skip — post-edit-aggregator (PostToolUse 마지막 entry) 가 자신의 entry
# 에서 합쳐 emit. 실패 시 stdout fallback (기존 동작 — Claude Code 가 본 entry
# 의 envelope 을 직접 surface).
TOOL_USE_ID=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    sys.stdout.write(d.get("tool_use_id", "") or "")
' 2>/dev/null || true)

if [ -n "$TOOL_USE_ID" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-output-cache.sh" ]; then
  # shellcheck disable=SC1091
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-output-cache.sh"
  if output_cache_write "$TOOL_USE_ID" "post-edit-routing-procedure-rule" "$ENVELOPE"; then
    exit 0
  fi
fi

# Fallback — direct stdout emit (cache 미가용 또는 write 실패).
printf '%s\n' "$ENVELOPE"
