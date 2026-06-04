#!/usr/bin/env bash
# Plugin PostToolUse(Edit|Write|MultiEdit) sub-hook — event-brief delivery
# for the design-plan-coverage rule.
#
# Triggers when an Edit/Write/MultiEdit targets a design/plan/DoD document:
#   - docs/specs/**
#   - docs/plans/**
#   - trail/dod/dod-*.md
#
# Emits a PostToolUse envelope so the design-plan-coverage 행동 강령
# (coverage matrix mandate) is visible in the next model request — companion
# to (not replacement for) post-edit-plan-coverage.sh's validator gate.
#
# Silent exit 0 when:
#   - CLAUDE_PLUGIN_ROOT unset (non-plugin runtime — rule body lives elsewhere)
#   - stdin empty / malformed JSON
#   - file path does not match the watched globs
#   - rule body unresolvable
#
# This hook never blocks (no exit 2). Path classification is glob-based
# (cheap), not file-existence based — the model gets the brief regardless
# of whether the validator finds a matrix on disk.
#
# ROUTE-BIND-1: spec/plan 작성 시 provenance claim 부재면 soft nudge(stderr,
# exit 0) 도 emit — 전용 에이전트 경유 작성을 유도(차단 아님). 정당 수동 작성은
# advisory 라 무해.
#
# Scope ID: post-tool-use-injects-design-plan-coverage-action-mandate-plus-body-when-edit-write-targets-docs-specs-or-docs-plans-or-trail-dod-dod
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# --- design-route nudge 문구 (ROUTE-BIND-1, SC-5) ---
# 정의가 호출 블록(glob case 이후)보다 위에 있어야 한다 — bash 는 top-to-bottom
# 이라 호출 라인 실행 시점에 정의돼 있어야 한다(미정의 함수 호출 exit 127 방지).
# 채널 = stderr(>&2), exit 0 — additionalContext 미사용(aggregator 미간섭).
# stamp/provenance/hash/exit code/표식 등 내부용어 비노출 — "전용 작성 경로"로
# 평이화(response-tone).
_design_route_nudge() {
  case "$1" in
    spec)
      {
        echo "[rein] docs/specs 에 직접 작성한 것으로 보입니다. rein 에서는 spec-writer 가 설계 문서를 쓰고"
        echo "       바로 검토까지 받게 되어 있습니다. 전용 작성 경로가 아니었다면, 멈추고 spec-writer 로"
        echo "       다시 작성하는 편이 안전합니다. (의도한 수동 작성이면 이 안내는 무시해도 됩니다.)"
      } >&2
      ;;
    plan)
      {
        echo "[rein] docs/plans 에 직접 작성한 것으로 보입니다. rein 에서는 plan-writer 가 구현 계획을 쓰고"
        echo "       커버리지 검증·검토까지 받게 되어 있습니다. 전용 작성 경로가 아니었다면, 멈추고 plan-writer 로"
        echo "       다시 작성하는 편이 안전합니다. (의도한 수동 작성이면 이 안내는 무시해도 됩니다.)"
      } >&2
      ;;
  esac
}

# HK-4: 분할 후 dispatcher 가 처리하던 정책 평가를 각 sub-hook 이 자체 호출.
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/post-edit-policy-gate.sh" ]; then
  # shellcheck source=./lib/post-edit-policy-gate.sh
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/post-edit-policy-gate.sh"
  post_edit_policy_gate "post-edit-design-plan-coverage-rule"
fi

# X4.C.3 fast-path skip — design memo §8.4. effective_mode == answer 는
# Stop 직후 PostToolUse(Edit) 가 fire 된 이상 신호 → envelope skip.
# fail-soft gate: state.json 부재 (greenfield) / malformed JSON / unknown
# schema_version / state-machine.sh 부재 / lock 실패 → legacy path (정상 inject).
# state_is_valid 로 게이트해, read_state 가 corrupt/unknown-schema state 에도
# echo 하는 default "answer" 를 envelope-skip 신호로 오인하지 않는다
# (codex Round 1 HIGH = state 부재, Round 2 HIGH = malformed / unknown schema).
# X4.C.5: read_fast_path_state folds validate + effective-mode into one python
# call under one lock (was state_is_valid + read_effective_mode = 3 python +
# 1 lock). Non-zero return = lock/python/parse failure → fall through to legacy
# inject (codex Round 3 HIGH preserved). The leading "valid" field is "1" only
# for a well-typed schema-v1 doc, so a corrupt/unknown-schema state never trips
# the answer-skip (codex Round 1/2 HIGH preserved).
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state-machine.sh" ]; then
  if . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state-machine.sh" 2>/dev/null; then
    # Third field (dirty_match) is unused here — no match_path passed, so it is
    # always "0". `_` is the conventional throwaway (shellcheck-recognised).
    if _fp_line=$(read_fast_path_state 2>/dev/null) \
        && IFS=$'\t' read -r _fp_valid _fastpath_mode _ <<<"$_fp_line" \
        && [ "$_fp_valid" = "1" ] && [ "$_fastpath_mode" = "answer" ]; then
      exit 0
    fi
  fi
fi

# Hook input on stdin (Claude Code JSON envelope). Extract file_path with
# the same fallback chain used by post-edit-plan-coverage.sh so both hooks
# agree on the path they care about:
#   tool_input.file_path  (primary)
#   tool_response.filePath (secondary — Claude Code response field)
#   tool_result.file_path  (legacy tertiary — older payload shape)
INPUT=$(cat || true)
[ -n "$INPUT" ] || exit 0

META2=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print(""); print(""); sys.exit(0)
if not isinstance(data, dict):
    print(""); print(""); sys.exit(0)
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
tid = data.get("tool_use_id")
tid = tid if isinstance(tid, str) else ""
# tool_use_id FIRST (toolu_ format — newline-free), file_path LAST so any
# embedded newline in file_path is preserved as the remaining lines (codex
# Medium: a newline-bearing file_path must not desync the two-field transport).
sys.stdout.write(tid + "\n" + (p or ""))
' 2>/dev/null || true)
TOOL_USE_ID=$(printf '%s\n' "$META2" | sed -n '1p')
FILE_PATH=$(printf '%s\n' "$META2" | sed '1d')

[ -n "$FILE_PATH" ] || exit 0

# Glob match — accept absolute or repo-relative paths. Order matters: the
# trail/dod pattern requires a `dod-` prefix on the filename, while the
# docs/specs and docs/plans patterns match any descendant.
# NUDGE_KIND 은 spec/plan match 에만 세팅 — ROUTE-BIND-1 nudge 분기용.
# trail/dod 는 coverage brief 만 받고 nudge 비대상(빈 동작).
NUDGE_KIND=""
case "$FILE_PATH" in
  */docs/specs/*|docs/specs/*) NUDGE_KIND="spec" ;;
  */docs/plans/*|docs/plans/*) NUDGE_KIND="plan" ;;
  */trail/dod/dod-*.md|trail/dod/dod-*.md) ;;   # coverage brief 만, nudge 아님
  *) exit 0 ;;
esac

# --- design-route nudge (ROUTE-BIND-1) ---
# spec/plan 이 전용 에이전트(spec-writer/plan-writer)의 provenance claim 없이
# 써지면 soft nudge(stderr advisory, exit 0)를 emit. claim 이 있으면 매칭 후
# 소비(삭제)하고 무발화 (presence+consume — SC-3). timestamp 비교 없음.
# 비차단 불변식: 어떤 단계 실패도 exit 2 안 함 (호스트 훅 계약 보존).
# 의도한 수동 작성(메인테이너 dogfood / 외부 에디터 / 리뷰 fix / 마이그레이션)이면
# advisory 라 무해 — nudge 문구 괄호절이 면책 (SC-7).
# opt-out 메커니즘은 첫 cycle 비도입 (advisory 라 무해 + 괄호절 면책).
# 후속 cycle 에서 .rein/policy 기반 suppress 검토 (본 cycle 비범위 — SC-7).
# hot-path 0 (NFR-1/2): 본 블록은 위 case 가 비-design 을 *) exit 0 으로 거른
# 이후 [ -n "$NUDGE_KIND" ] 안쪽에서만 실행 → 비-design 편집은 python3/grep/rm
# 어떤 프로세스도 spawn 안 함.
if [ -n "$NUDGE_KIND" ]; then
  _emit_nudge=1
  # 절대경로 정규화 — helper/spec-review-gate 와 동일 (매칭 키 일치).
  _abs=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || true)
  if [ -n "$_abs" ]; then
    # hash 규약 재사용 (post-edit-spec-review-gate.sh:81-93 와 byte-identical).
    _design_compute_hash() {
      local input="$1"
      if command -v shasum >/dev/null 2>&1; then printf '%s' "$input" | shasum | cut -c1-16
      elif command -v sha1sum >/dev/null 2>&1; then printf '%s' "$input" | sha1sum | cut -c1-16
      else local t="${input: -12}"; local l="${#input}"; printf '%s%d' "$(echo "$t" | tr -cd 'a-zA-Z0-9')" "$l" | cut -c1-16; fi
    }
    # hash 실패도 비차단 (set -e fail-soft): shasum/sha1sum/cut 파이프가 깨져도
    # _hash="" 로 두고 매칭을 건너뛴다 → nudge 정상 발화, exit 0 유지.
    _hash=$(_design_compute_hash "$_abs" 2>/dev/null) || _hash=""
    # PROJECT_DIR: 호스트 훅은 CLAUDE_PLUGIN_ROOT inject runtime — project-dir.sh
    # 로 helper 와 동일 해소. (미source 시 source)
    if ! declare -F resolve_project_dir >/dev/null 2>&1; then
      . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/project-dir.sh" 2>/dev/null || true
    fi
    if declare -F resolve_project_dir >/dev/null 2>&1; then
      # resolve_project_dir 실패도 비차단 — $PWD 로 fallback (set -e 회피).
      _pd=$(resolve_project_dir "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)") || _pd="$PWD"
      [ -n "$_pd" ] || _pd="$PWD"
    else
      _pd="$PWD"
    fi
    _marker="$_pd/.rein/cache/.design-provenance/${_hash}.touched"
    # 매칭 = hash 비어있지 않음 + claim 존재 + path= 정확 대조 (grep -qxF — BRE
    # 메타문자 방어). hash 실패(_hash="") 시 매칭 건너뜀 → nudge.
    if [ -n "$_hash" ] && [ -f "$_marker" ] && grep -qxF -- "path=$_abs" "$_marker" 2>/dev/null; then
      rm -f "$_marker" 2>/dev/null || true   # consume — 1회성. rm 실패해도 비차단(exit 0 유지).
      _emit_nudge=0                            # 정상 경로 — 무발화.
    fi
  fi
  if [ "$_emit_nudge" = "1" ]; then
    _design_route_nudge "$NUDGE_KIND"   # 위에서 정의한 문구 함수 (정의가 위·같은 커밋 — issue 1)
  fi
fi

# shellcheck disable=SC1091
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/rule-inject.sh"

# Sentinel idiom — preserve trailing newlines (see rule-inject.sh for
# rationale). The if-then-else inside the subshell makes the subshell rc
# reflect rule_inject_body's rc instead of printf's success.
if ! BODY=$(if rule_inject_body design-plan-coverage; then printf x; else exit 1; fi); then
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
# 의 envelope 을 직접 surface). TOOL_USE_ID 는 위 META2 추출에서 이미 설정됨.
if [ -n "$TOOL_USE_ID" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-output-cache.sh" ]; then
  # shellcheck disable=SC1091
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-output-cache.sh"
  if output_cache_write "$TOOL_USE_ID" "post-edit-design-plan-coverage-rule" "$ENVELOPE"; then
    exit 0
  fi
fi

# Fallback — direct stdout emit (cache 미가용 또는 write 실패).
printf '%s\n' "$ENVELOPE"
