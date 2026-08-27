#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit)
# trail/dod/.session-has-src-edit ("이번 세션에 소스를 편집했는가") producer.
#
# feature-builder-refactor task step 1 (Marker A relocation). This marker
# used to be touched inline by pre-edit-dod-gate.sh, at every point that hook
# decided to ALLOW a source-file edit (three call sites, all on an exit-0
# path reached only when IS_SOURCE=true AND every earlier check in that hook
# passed). pre-edit-dod-gate.sh is slated for eventual full replacement by
# the v2 governance runtime; if the touch stayed inline there, the marker
# would go permanently unproduced the moment that hook is retired, and
# stop-session-gate.sh's "did this session edit source" check (which reads
# this exact marker — see that hook, ~line 60) would silently and
# permanently read false. This hook is the new, independent producer.
#
# Equivalence to the old inline touch (why PostToolUse here is safe, not
# just convenient): the old touch fired iff (a) IS_SOURCE=true for the edited
# path AND (b) pre-edit-dod-gate.sh itself did not block. Condition (b) is
# also required for the Edit/Write/MultiEdit tool call to actually execute at
# all — a PreToolUse deny from pre-edit-dod-gate.sh (or from ANY sibling
# PreToolUse hook in the same matcher group, e.g. pre-edit-coverage-gate.sh's
# Tier-1 coverage-mismatch block) prevents the tool from running, which in
# turn means THIS PostToolUse hook never fires. So "IS_SOURCE=true AND the
# edit actually went through" (what this hook checks) is exactly equivalent
# to the old "IS_SOURCE=true AND pre-edit-dod-gate.sh reached one of its
# exit-0 paths" — for every reachable input, not just the common case. (The
# one theoretical divergence — a sibling hook denying for an unrelated
# reason while pre-edit-dod-gate.sh itself would have allowed — already
# could not co-occur with IS_SOURCE=true before this refactor either: the
# other PreToolUse(Edit) hooks that can deny, pre-edit-trail-bootstrap-gate.sh
# and pre-edit-index-lines.sh, only fire for conditions — missing trail/, or
# trail/index.md line-limit — that themselves already force IS_SOURCE=false
# or DOD_FOUND=false in pre-edit-dod-gate.sh, so the old touch was never
# reached there either.)
#
# Consumers (unchanged by this move):
#   hooks/stop-session-gate.sh          — reads the marker (~line 60/173)
#   hooks/session-start-load-trail.sh   — clears the marker at session start
#     (~line 78)
#
# Never blocks — this is pure bookkeeping, matching the original inline
# touch's role (a side effect of an already-decided allow, never itself a
# gate). Every failure path below is fail-open (exit 0): the worst case of a
# missed touch is stop-session-gate.sh under-counting "did this session edit
# source", which only affects an advisory inbox/index reminder, not a
# security decision.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
# shellcheck source=./lib/hook-input-cache.sh
. "$SCRIPT_DIR/lib/hook-input-cache.sh"
# HK-4: 분할 후 dispatcher 가 처리하던 정책 평가를 각 sub-hook 이 자체 호출.
# shellcheck source=./lib/post-edit-policy-gate.sh
. "$SCRIPT_DIR/lib/post-edit-policy-gate.sh"
post_edit_policy_gate "post-edit-src-touch-marker"

PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
SRC_EDIT_MARKER="$PROJECT_DIR/trail/dod/.session-has-src-edit"

. "$SCRIPT_DIR/lib/shadow-capture.sh" 2>/dev/null && shadow_capture_init "post-edit-src-touch-marker"  # fire-and-forget

# Shared classifier — same source of truth pre-edit-dod-gate.sh uses (see
# that lib's header). Missing library → fail-open (silent skip): this is
# advisory bookkeeping, not a gate, so degrading is preferable to blocking.
if ! . "$SCRIPT_DIR/lib/source-path-classify.sh" 2>/dev/null; then
  exit 0
fi

hook_input_load   # 캐시 활성 시 INPUT/FILE_PATHS 채워짐. 없으면 INPUT 만.

if [ "${REIN_HOOK_INPUT_CACHE:-0}" != "1" ]; then
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 0
  fi

  # 수집 순서 (구 편집 훅들에서 계승한 semantics — 이 파일이 현행 기준):
  #   1) tool_input.file_path          (Edit/Write)
  #   2) tool_input.edits[*].file_path (MultiEdit 입력)
  #   3) tool_result.edits[*].file_path(MultiEdit 결과)
  #   4) tool_result.file_path         (fallback — 1~3 에서 못 찾았을 때만)
  FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
    --field tool_input.file_path \
    --array-of tool_input.edits --subfield file_path \
    --array-of tool_result.edits --subfield file_path \
    --default '' 2>/dev/null | awk 'NF && !seen[$0]++')

  if [ -z "$FILE_PATHS" ]; then
    FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_result.file_path --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
  fi
fi

if [ -z "${PYTHON_RUNNER[0]:-}" ]; then
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 0
  fi
fi

[ -z "$FILE_PATHS" ] && exit 0

FOUND_SOURCE=false
while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue

  # Path normalize — 소멸한 구 편집 게이트들에서 계승한 동일 원칙.
  FILE_PATH_NORM=$("${PYTHON_RUNNER[@]}" -c \
    'import os,sys; print(os.path.normpath(sys.argv[1]))' \
    "$FILE_PATH" 2>/dev/null) || FILE_PATH_NORM=""
  [ -z "$FILE_PATH_NORM" ] && FILE_PATH_NORM="$FILE_PATH"

  declare -F shadow_capture_set_subject >/dev/null 2>&1 && shadow_capture_set_subject "$FILE_PATH_NORM"

  rein_classify_source_path "$FILE_PATH_NORM"
  if [ "$REIN_SRC_CLASS" = "source" ]; then
    FOUND_SOURCE=true
    break
  fi
done <<< "$FILE_PATHS"

if [ "$FOUND_SOURCE" = true ]; then
  mkdir -p "$(dirname "$SRC_EDIT_MARKER")" 2>/dev/null
  touch "$SRC_EDIT_MARKER" 2>/dev/null
fi

exit 0
