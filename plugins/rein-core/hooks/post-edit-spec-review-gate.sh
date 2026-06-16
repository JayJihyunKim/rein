#!/bin/bash
# Hook: PostToolUse(Write|Edit|MultiEdit)
# canonical 설계 문서 작성 시 pending review 마커 생성

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
# shellcheck source=./lib/hook-input-cache.sh
. "$SCRIPT_DIR/lib/hook-input-cache.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
DOD_DIR="$PROJECT_DIR/trail/dod"
SPEC_REVIEWS_DIR="$DOD_DIR/.spec-reviews"

# M4 (2026-06-16): conservative marker for the THREE fail-open paths below.
# This hook used to `exit 0` silently when it could not resolve python / parse
# the JSON, so an unreviewed spec edit produced no .pending marker and the next
# source edit was not blocked (fail-open). Mirroring post-edit-dod-routing-check.sh
# (L35-43/L49), each fail-open path now drops a single generic conservative
# marker recording its cause; pre-edit-dod-gate.sh glob-blocks on it. The
# success path auto-heals the marker (rm -f). The marker is generic (file
# unknown — we could not resolve which path was edited), so a single token with
# a `cause=` body distinguishes the three failures.
SPEC_GEN_FAILED_MARKER="$DOD_DIR/.spec-review-gen-failed"

# write_spec_gen_failed_marker <cause>
#   cause ∈ {noncache-python, json-parse, cache-python}. Best-effort: marker
#   creation must never abort the hook (post-hook stays silent/exit 0).
write_spec_gen_failed_marker() {
  local cause="$1"
  mkdir -p "$DOD_DIR" 2>/dev/null || true
  {
    echo "cause=$cause"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$SPEC_GEN_FAILED_MARKER" 2>/dev/null || true
}

# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# HK-4: 분할 후 dispatcher 가 처리하던 정책 평가를 각 sub-hook 이 자체 호출.
# shellcheck source=./lib/post-edit-policy-gate.sh
. "$SCRIPT_DIR/lib/post-edit-policy-gate.sh"
post_edit_policy_gate "post-edit-spec-review-gate"

# Plan A §2 (GI-path-policy-lib): shared path classifier. Fail-closed if
# library is missing — silent degrade to "no matcher" would stop creating
# pending markers for real specs, defeating the spec review gate.
if ! . "$SCRIPT_DIR/lib/path-policy.sh" 2>/dev/null; then
  echo "BLOCKED: [post-edit-spec-review-gate] path-policy library missing at $SCRIPT_DIR/lib/path-policy.sh" >&2
  exit 2
fi

hook_input_load   # 캐시 활성 시 INPUT/FILE_PATHS 채워짐.

if [ "${REIN_HOOK_INPUT_CACHE:-0}" != "1" ]; then
  # Post-hook: Python 미해결 시 조용히 skip (세션 차단 금지). M4: 조용히 통과하면
  # 미리뷰 spec 변경의 .pending 이 안 생겨 다음 편집이 안 막히므로(fail-open),
  # exit 0 직전에 보수 마커를 남긴다 (routing-check 패턴).
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    write_spec_gen_failed_marker "noncache-python"
    exit 0
  fi

  # MultiEdit + Edit/Write 모두 지원: 모든 편집 파일 경로 추출.
  # 수집 순서(원본 보존): tool_input.file_path → tool_input.edits[*].file_path
  #                   → tool_result.edits[*].file_path → tool_result.file_path(fallback only).
  # 빈 값/중복은 awk 단계에서 제거 (원본의 `if fp and fp not in paths` 의미 유지).
  # 서브쉘에서 pipefail 을 켜서 helper 실패를 정확히 캡처한다.
  FILE_PATHS=$(
    set -o pipefail
    printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_input.file_path \
      --array-of tool_input.edits --subfield file_path \
      --array-of tool_result.edits --subfield file_path \
      --default '' 2>/dev/null \
      | awk 'NF && !seen[$0]++'
  )
  PY_EXIT=$?

  # helper 가 실패했으면 세션은 차단하지 않되 사용자가 stderr 로 인지 가능하게 한다.
  # M4: JSON 파싱 실패도 fail-open 경로 — 보수 마커를 남겨 다음 편집이 막히게 한다.
  if [ "$PY_EXIT" -ne 0 ]; then
    echo "WARNING: post-edit-spec-review-gate JSON 파싱 실패 — marker 미생성" >&2
    write_spec_gen_failed_marker "json-parse"
    exit 0
  fi

  # fallback: tool_result.file_path 는 1~3 에서 경로를 찾지 못했을 때만 사용 (Codex final review A4).
  if [ -z "$FILE_PATHS" ]; then
    FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_result.file_path --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
  fi
fi

[ -z "$FILE_PATHS" ] && exit 0

# 캐시 경로에서도 path normalize 용 PYTHON_RUNNER 가 필요. M4: 여기서 조용히
# 통과하면 캐시로 받은 spec path 의 .pending 이 안 생기므로(fail-open) 보수
# 마커를 남긴다.
if [ -z "${PYTHON_RUNNER[0]:-}" ]; then
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    write_spec_gen_failed_marker "cache-python"
    exit 0
  fi
fi

# M4: success path reached — python resolved + FILE_PATHS extracted (non-empty,
# guarded above). Auto-heal of the conservative marker is NOT done here:
# clearing on ANY successful edit (incl. non-spec source files) would let a
# `.skip-spec-gen-gate` bypass + a later non-spec edit silently clear the marker
# while the spec missed during the failure window stays untracked — reopening
# the M4 fail-open (codex integration-review R1 High). Instead, heal ONLY after a
# canonical spec/plan is actually reprocessed (pending created) below — proof the
# producer works for specs again. Until then the marker persists (block again),
# and the one-shot bypass stays the deliberate escape.
_healed_canonical_spec=false

# 해시 계산
compute_hash() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum | cut -c1-16
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha1sum | cut -c1-16
  else
    # fallback: path 끝 12자 + length 접미
    local tail="${input: -12}"
    local len="${#input}"
    printf '%s%d' "$(echo "$tail" | tr -cd 'a-zA-Z0-9')" "$len" | cut -c1-16
  fi
}

# Plan A §2 consumer: canonical = design spec (is_spec_path) OR plan
# (is_plan_path). The shared library (GI-path-policy-lib) expects
# repo-relative input; this wrapper does the absolute → relative
# normalization locally (GI-path-policy-input-contract).
is_canonical_spec() {
  local abs="$1"
  local rel
  case "$abs" in
    "$PROJECT_DIR"/*) rel="${abs#$PROJECT_DIR/}" ;;
    *) return 1 ;;  # repo 외부는 canonical 아님
  esac
  is_spec_path "$rel" || is_plan_path "$rel"
}

# 각 파일에 대해 마커 생성 (while 루프가 subshell을 생성하므로 미리 mkdir)
mkdir -p "$SPEC_REVIEWS_DIR"

while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue

  # 절대경로 정규화
  ABS=$("${PYTHON_RUNNER[@]}" -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null)
  [ -z "$ABS" ] && continue

  # canonical 매칭
  is_canonical_spec "$ABS" || continue

  HASH=$(compute_hash "$ABS")
  MARKER="$SPEC_REVIEWS_DIR/${HASH}.pending"
  REVIEWED_MARKER="$SPEC_REVIEWS_DIR/${HASH}.reviewed"

  # SR-1: a spec edit invalidates any prior review. Remove a stale .reviewed so
  # the pre-edit spec gate forces a re-review of the just-edited document.
  # Without this, editing an already-reviewed spec leaves (.pending + old
  # .reviewed) coexisting and the gate's existence-only check passes on the
  # stale .reviewed (review-bypass). Placed before the create/touch branches
  # below so it covers both — any path through this loop means the canonical
  # spec was just edited.
  rm -f "$REVIEWED_MARKER" 2>/dev/null || true

  # X4.C.3 fast-path skip — design memo §8.4. 같은 spec 의 .pending marker 가 이미
  # 존재하고 path 가 일치하면 mtime 만 touch (body re-write subprocess 회피).
  # NOTICE 메시지는 그대로 유지 — 사용자에게 review 필요성 계속 알림.
  # 고정 문자열 + 전체 줄 매칭 (-xF) — $ABS 의 정규식 메타문자 (. * 등) 가 BRE 로
  # 해석되어 다른 path 와 느슨하게 매칭되는 것을 방지 (security review Info-1).
  if [ -f "$MARKER" ] && grep -qxF -- "path=$ABS" "$MARKER" 2>/dev/null; then
    touch "$MARKER" 2>/dev/null || true
  else
    {
      echo "path=$ABS"
      echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
    } > "$MARKER"
  fi

  echo "NOTICE: spec review pending — $ABS" >&2
  echo "  리뷰 후: rein-mark-spec-reviewed.sh \"$ABS\" codex (plugin bundle 또는 repo scripts/)" >&2
  # M4: a canonical spec was successfully reprocessed (pending created/refreshed)
  # → the producer demonstrably works for specs again, so it is safe to clear a
  # conservative marker left by a prior failed run. Narrowed from the old
  # top-of-file clear so non-spec edits never auto-heal (codex R1 High).
  _healed_canonical_spec=true
done <<< "$FILE_PATHS"

# M4 auto-heal (narrowed): only when a canonical spec/plan was actually
# reprocessed this run. Non-spec edits leave the marker in place → block again.
if [ "$_healed_canonical_spec" = true ]; then
  rm -f "$SPEC_GEN_FAILED_MARKER" 2>/dev/null || true
fi

exit 0
