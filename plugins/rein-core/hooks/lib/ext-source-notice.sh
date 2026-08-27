#!/bin/bash
# hooks/lib/ext-source-notice.sh
#
# GMF-3 "why does this file need a DoD" per-path stderr notice — extracted
# from the (now-retired) pre-edit-dod-gate.sh's inline emit_ext_source_
# notice() (that hook's L329-343, defined right after the source-path-
# classify call and before the governance-stage block).
#
# Why this is now a shared lib instead of staying inlined in one hook
# (Phase 7 wave 3 ③-b edit-gate handoff): the active-task axis that used to
# call this function (pre-edit-dod-gate.sh's v1 "no active task record"
# fallback, via lib/active-task-gate.sh's rein_check_active_task) has moved
# entirely to the new pre-edit-task-gate.sh — but that hook also needs to
# show the SAME notice on its v2-delegated DENY relay path (so a user who
# gets blocked because a path was classified as source purely by extension,
# not by directory whitelist, still sees the "why" explanation regardless
# of whether v1 or v2 made the call). Two hand-copied definitions would
# silently drift the moment the marker scheme or message wording changes in
# only one copy — the same rationale lib/source-path-classify.sh's header
# already established for the classification this function consumes
# (EXT_SOURCE_HIT). pre-edit-discipline-gate.sh does not currently call
# this function itself (the active-task axis it used to gate does not live
# there anymore), but it is left available as a shared lib rather than
# living solely inside pre-edit-task-gate.sh, in case a future discipline-
# axis block point needs the identical notice.
#
# This is a MECHANICAL move: the sha1-based per-path "notify once" marker
# and the stderr message text are copied byte-for-byte from the original
# inline definition. No logic changed.
#
# Contract for the caller:
#   . "$SCRIPT_DIR/lib/source-path-classify.sh"   # sets EXT_SOURCE_HIT
#   . "$SCRIPT_DIR/lib/ext-source-notice.sh"
#   rein_classify_source_path "$FILE_PATH"
#   emit_ext_source_notice   # reads ambient EXT_SOURCE_HIT, FILE_PATH,
#                            # DOD_DIR, PYTHON_RUNNER (array); best-effort —
#                            # a PYTHON_RUNNER/hash failure only skips the
#                            # notice, never affects the caller's block
#                            # decision, which must already be final by the
#                            # time this is called.
#
# The per-path marker (trail/dod/.ext-source-notice-<sha>) is shared state
# on disk between whichever hook happens to call this first for a given
# path — a notice shown once by pre-edit-task-gate.sh's DENY relay will not
# be shown again by a hypothetical future discipline-gate caller for the
# same path, and vice versa. This matches the original single-hook
# behavior's own "per file path, once" contract; it was never per-hook.

if [ -n "${__REIN_EXT_SOURCE_NOTICE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_EXT_SOURCE_NOTICE_LOADED=1

emit_ext_source_notice() {
  [ "$EXT_SOURCE_HIT" = true ] || return 0
  local _ext_sha _ext_marker _ext_token
  _ext_sha=$("${PYTHON_RUNNER[@]}" -c '
import hashlib, sys
print(hashlib.sha1(sys.argv[1].encode("utf-8")).hexdigest()[:12])
' "$FILE_PATH" 2>/dev/null)
  [ -n "$_ext_sha" ] || return 0
  _ext_marker="$DOD_DIR/.ext-source-notice-$_ext_sha"
  [ -f "$_ext_marker" ] && return 0
  _ext_token="${FILE_PATH##*.}"
  echo "[rein] 이 파일은 소스 확장자(.$_ext_token)로 판정되어 DoD 를 요구합니다 (디렉토리 화이트리스트가 아닌 확장자 기준). 정책 토글로 끌 수 있습니다." >&2
  mkdir -p "$DOD_DIR" 2>/dev/null
  touch "$_ext_marker" 2>/dev/null
}
