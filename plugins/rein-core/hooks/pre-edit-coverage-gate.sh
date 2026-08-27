#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# Coverage-validator invocation + trail/dod/.dod-coverage-mismatch /
# .dod-coverage-advisory marker production.
#
# feature-builder-refactor task step 1 (Marker B relocation). This logic
# used to live inline inside pre-edit-dod-gate.sh's `if [ "$DOD_FOUND" = true
# ]` branch. pre-edit-dod-gate.sh has since been retired and replaced by
# TWO successor hooks (Phase 7 wave 3 ③-b edit-gate handoff):
# pre-edit-discipline-gate.sh (v1 surviving discipline gates — DoD
# existence, governance-stage, incident/spec-review/routing preconditions)
# and pre-edit-task-gate.sh (the active-task axis's v2 authority wrapper).
# Coverage validation itself is a v1-surviving feature that belongs to
# neither successor (out of scope for the v2 hand-off — see the design
# doc's §제외 section), so its marker-producing logic stays OUT here in its
# own dedicated hook rather than living in either successor.
#
# This hook's decision does NOT replace pre-edit-task-gate.sh's own "no
# active task record" judgment (the successor to pre-edit-dod-gate.sh's old
# inline block of the same name).
#
# Structure update (Phase 7 wave 3 ③-b round 6, 2026-08-23 — supersedes an
# earlier revision of this paragraph that said "all three hooks run
# independently in the same PreToolUse matcher group ... and a deny from
# ANY of them blocks the edit ('deny wins')". That description went stale
# the moment pre-edit-dispatcher.sh was introduced and now contradicts the
# "Precondition-awareness" comment further below in this same file — this
# paragraph is the one being brought back into agreement with it):
# hooks.json no longer registers pre-edit-discipline-gate.sh /
# pre-edit-task-gate.sh / this hook individually in that matcher group.
# pre-edit-dispatcher.sh is the SOLE registrant and runs the three as its
# children, in this exact order, stopping at the first block: discipline-
# gate → task-gate → THIS hook (that dispatcher's own header documents the
# full ordering contract). This hook only ever runs once BOTH predecessors
# have already passed for the same edit — there is no parallel race left to
# reason about here, and no "deny wins across independently-running hooks"
# merge semantics either (the dispatcher's own first-block-stops model
# already resolves that). This hook only ever adds a NEW reason to block (a
# Tier-1 coverage mismatch/timeout); it never overrides a block from either
# predecessor (it cannot — the dispatcher would already have exited before
# ever reaching this hook), and pre-edit-discipline-gate.sh's own
# DOD_FOUND=true branch now always allows (see that hook's comment at the
# same spot this logic used to occupy, before the extraction).
#
# Exit code: 0=허용, 2=차단 (Tier 1 전용 — Tier 2 는 advisory, never blocks)
#
# Block points enforced here:
#   Tier 1 coverage mismatch / validator timeout — .dod-coverage-mismatch
#
# GMF-4 policy-toggle ordering (docs/specs/2026-06-12-gate-misfire-fixes.md
# §3.4): the policy check runs AFTER resolve_python (which already fail-
# closes on interpreter absence), so a missing interpreter can never be
# mistaken for a user policy disable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Shared libraries — missing any of these is fail-closed: a silently
# degraded coverage gate (one that can no longer classify paths, decide
# "active work exists", or select the active DoD) is exactly the drift this
# extraction is meant to prevent.
if ! . "$SCRIPT_DIR/lib/source-path-classify.sh" 2>/dev/null; then
  echo "[rein] The coverage gate cannot run because a required library is missing (lib/source-path-classify.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
if ! . "$SCRIPT_DIR/lib/dod-found.sh" 2>/dev/null; then
  echo "[rein] The coverage gate cannot run because a required library is missing (lib/dod-found.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
if ! . "$SCRIPT_DIR/lib/select-active-dod.sh" 2>/dev/null; then
  echo "[rein] The coverage gate cannot run because a required library is missing (lib/select-active-dod.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
if ! . "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null; then
  echo "[rein] The coverage gate cannot run because a required library is missing (lib/plugin-script-path.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
# Precondition-awareness — NOW HANDLED BY THE DISPATCHER, NOT THIS HOOK
# (Phase 7 wave 3 ③-b, edit-gate sequential dispatcher, 2026-08-23 — code
# review round 6 High fix). This hook used to independently re-derive "is a
# sibling precondition gate (incident-review / spec-review / routing)
# currently blocking this edit" via a same-process peek
# (`_rein_precheck_would_block`, sourcing lib/incident-review-gate.sh,
# lib/spec-review-gate.sh, lib/routing-gate.sh and calling each function
# inside a subshell). That peek assumed Claude Code's parallel,
# non-deterministic hook scheduling — it inferred a sibling's REAL verdict
# from disk-marker state because it could run before, after, or concurrently
# with pre-edit-discipline-gate.sh's own enforcing call for the very same
# edit. Round 6 (High) reproduced the reachable race this created: a
# one-shot spec-review bypass marker (`.skip-spec-gate`) consumed for real by
# discipline-gate's enforcing call could be observed by this hook's peek as
# "still blocking" (a stale read landing after the marker was already gone),
# causing this hook to silently skip its OWN coverage-validator check for an
# edit whose `covers:` list referenced a nonexistent Scope ID.
#
# pre-edit-dispatcher.sh (hooks.json's sole registrant for the PreToolUse
# Edit|Write|MultiEdit matcher group as of this fix) now runs
# pre-edit-discipline-gate.sh → pre-edit-task-gate.sh → THIS hook in
# guaranteed sequence, stopping at the first block. This hook running at all
# is itself the proof that every gate ahead of it in that sequence already
# passed — there is nothing left to peek at, so the peek, its
# `REIN_GATE_PEEK_MODE` export, and the three lib sourcings that existed
# solely to support it were removed. (The `REIN_GATE_PEEK_MODE` guards
# inside lib/incident-review-gate.sh / lib/spec-review-gate.sh /
# lib/routing-gate.sh themselves are left in place as an inert defense
# layer — see each file's own guard comments — in case a future caller
# reintroduces a same-process peek; they cost nothing while unused.)
#
# select-active-dod.sh / dod-found.sh / source-path-classify.sh /
# plugin-script-path.sh above remain sourced — this hook still uses them
# directly for its own DoD-existence / tier-selection / path-classification
# judgment, independent of the removed peek.

DOD_DIR="$PROJECT_DIR/trail/dod"
INBOX_DIR="$PROJECT_DIR/trail/inbox"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"

# Markers produced by this gate (same pair the now-retired pre-edit-dod-
# gate.sh used to produce inline — Plan A §4.2 table, unchanged by the move):
DOD_MISMATCH_MARKER="$DOD_DIR/.dod-coverage-mismatch"    # blocking
DOD_ADVISORY_MARKER="$DOD_DIR/.dod-coverage-advisory"    # non-blocking

VALIDATOR_TIMEOUT_S=30

# log_block — separate local copy, same shape as pre-edit-discipline-gate.sh
# and pre-edit-task-gate.sh's own (neither shares its copy with this one,
# matching the existing convention in this codebase where each gate owns its
# own log_block wrapper around the shared lib/rein-log-block.py SSOT — see
# bash-guard-infra.sh's copy for the PreToolUse(Bash) side).
log_block() {
  local reason="$1"
  local target="$2"
  if [ -z "${PYTHON_RUNNER+x}" ] || [ "${#PYTHON_RUNNER[@]}" -eq 0 ]; then
    return 0
  fi
  local _lb_helper="$SCRIPT_DIR/lib/rein-log-block.py"
  if [ ! -f "$_lb_helper" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  local count
  count=$("${PYTHON_RUNNER[@]}" "$_lb_helper" \
    "pre-edit-coverage-gate" "$reason" "$target" \
    "$BLOCKS_LOG_JSONL" "$PROJECT_DIR/.rein/logs/blocks-raw.jsonl" \
    path "${REIN_TEST_MODE:-0}" 2>/dev/null || echo 0)
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  local _auto_silent=0
  if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/auto-mode.sh" ]; then
    # shellcheck disable=SC1091
    . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/auto-mode.sh" 2>/dev/null || true
    if declare -F is_auto_mode >/dev/null 2>&1 && is_auto_mode; then
      _auto_silent=1
    fi
  fi
  if [ "$_auto_silent" = "0" ]; then
    if [ "$count" -ge 3 ]; then
      echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
    elif [ "$count" -ge 2 ]; then
      echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
    fi
  fi
}

INPUT=$(cat)

resolve_python
rc=$?
if [ "$rc" -ne 0 ]; then
  case "$rc" in
    10) echo "[rein] The coverage gate cannot run because Python is not installed. Install Python 3 to restore all edit checks." >&2 ;;
    11) echo "[rein] The coverage gate cannot run because the Windows App Execution Alias Python stub was detected instead of a real Python installation. Install Python 3 from python.org or the Microsoft Store to proceed." >&2 ;;
    12) echo "[rein] The coverage gate cannot run because Python failed to launch (exit 9009 family) — this is common in Windows Git Bash or MSYS, or when REIN_PYTHON points to an invalid interpreter. Check your Python installation or unset REIN_PYTHON." >&2 ;;
    *)  echo "[rein] The coverage gate cannot run because the Python resolver failed (rc=$rc). Check your Python installation or run 'rein update'." >&2 ;;
  esac
  print_windows_diagnostics_if_applicable >&2
  log_block "python runtime unavailable" "unknown"
  exit 2
fi

# --- Policy toggle (plugin mode only) — GMF-4 resolver-after form ---
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-edit-coverage-gate"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 1 ]; then
    exit 0  # loader ran cleanly + disabled by user policy
  fi
  # rc 0 = enabled (continue); rc ∉ {0,1} = loader call failure → fail-closed.
fi

FILE_PATH=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --default '')
EXTRACT_RC=$?
if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "[rein] The coverage gate cannot read the tool input because the hook JSON could not be parsed (extract-hook-json.py exited $EXTRACT_RC). This is an installation issue — run 'rein update' to repair." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Path normalize — same principle as pre-edit-discipline-gate.sh /
# pre-edit-task-gate.sh.
FILE_PATH_NORM=$("${PYTHON_RUNNER[@]}" -c \
  'import os,sys; print(os.path.normpath(sys.argv[1]))' \
  "$FILE_PATH" 2>/dev/null) || FILE_PATH_NORM=""
[ -z "$FILE_PATH_NORM" ] && FILE_PATH_NORM="$FILE_PATH"
FILE_PATH="$FILE_PATH_NORM"

# Shared classifier (lib/source-path-classify.sh) — must agree with
# pre-edit-discipline-gate.sh and pre-edit-task-gate.sh on "is this a source
# edit" (see that lib's header). Exempt / non-source paths never needed a
# coverage check under the old inline flow either (IS_SOURCE=false always
# exited 0 before reaching the DOD_FOUND branch).
rein_classify_source_path "$FILE_PATH"
if [ "$REIN_SRC_CLASS" != "source" ]; then
  exit 0
fi

# --- Governance-stage awareness (narrow — NOT a duplicate of the gate) ---
# pre-edit-discipline-gate.sh still owns the full governance-stage block/
# message (via lib/governance-invalid-gate.sh, Phase 7 wave 3 ③-b — see
# that hook's header for the full inheritance mapping; out of scope for
# this extraction). But this hook independently runs the SAME 1:0
# validator-pass case as the original inline code, which does `rm -f
# "$DOD_MISMATCH_MARKER" "$DOD_ADVISORY_MARKER"` — a self-heal that, run
# independently of pre-edit-discipline-gate.sh, would silently CLEAR the
# very .dod-coverage-mismatch marker that hook just set for a corrupt
# governance.json (both hooks run for the same edit event; without this
# guard the two would race on the shared marker file). In the original
# single-hook flow this could never happen: the governance check ran
# BEFORE the coverage-validator code and `exit 2`'d first, so the two were
# mutually exclusive within one invocation. This guard restores that mutual
# exclusion across the two now-separate hooks — it does not replicate
# governance-stage's blocking behavior or messaging, only skips touching
# the coverage markers when governance is broken, deferring entirely to
# pre-edit-discipline-gate.sh's own block for that condition.
if . "$SCRIPT_DIR/lib/governance-stage.sh" 2>/dev/null; then
  GOVERNANCE_STAGE=$(cd "$PROJECT_DIR" && read_governance_stage)
  if [ "$GOVERNANCE_STAGE" = "INVALID" ]; then
    exit 0
  fi
fi

# "Is there active work at all" — must be checked BEFORE select_active_dod,
# because select_active_dod's Tier 1/2 selection does not filter out an
# already-completed DoD (see lib/dod-found.sh header for the full
# explanation of why this ordering matters).
rein_dod_found
if [ "$DOD_FOUND" != true ]; then
  exit 0
fi

# Plan A Phase 4 Task 4.2 (GI-dod-gate-validator-call), relocated verbatim:
# run the active-DoD validator through the 30s timeout wrapper and enforce
# the §4.2 tier/exit-code table. No-op (exit 0) when no DoD candidate exists
# (tier=0), preserving the original "DoD file exists → permit edit" behavior.
SAD_LINE=$( cd "$PROJECT_DIR" && select_active_dod )
SAD_TIER=$(printf '%s' "$SAD_LINE" | cut -f1)
SAD_PATH=$(printf '%s' "$SAD_LINE" | cut -f2)
SAD_REASON=$(printf '%s' "$SAD_LINE" | cut -f3)

if [ "$SAD_TIER" = "0" ] || [ -z "$SAD_PATH" ]; then
  # No candidate DoD has '## 범위 연결' — silently pass through. Emit no
  # stderr to avoid polluting every Edit/Write with a warning.
  exit 0
fi

# X4.C.3 fast-path skip — design memo §8.4 / §3.4. effective_mode ==
# source_edit + FILE_PATH 가 state.json.dirty_files 에 이미 등재되어 있으면
# validator subprocess (~500ms) 를 skip 하고 직전 marker 상태를 그대로 유지.
# state.json 부재 (greenfield) / malformed JSON / unknown schema_version /
# state-machine.sh 부재 / lock 실패 → legacy validator path.
if [ -f "$SCRIPT_DIR/lib/state-machine.sh" ]; then
  if . "$SCRIPT_DIR/lib/state-machine.sh" 2>/dev/null; then
    if _fp_line=$(read_fast_path_state "$FILE_PATH" 2>/dev/null) \
        && IFS=$'\t' read -r _fp_valid _fp_mode _fp_match <<<"$_fp_line" \
        && [ "$_fp_valid" = "1" ] && [ "$_fp_mode" = "source_edit" ] \
        && [ "$_fp_match" = "1" ]; then
      echo "NOTICE: pre-edit-coverage-gate state.fast-path skip — file=$FILE_PATH (mode=source_edit, dirty_files hit, validator subprocess skipped)" >&2
      exit 0
    fi
  fi
fi

# --- Precondition-awareness precheck: REMOVED (Phase 7 wave 3 ③-b,
# sequential dispatcher, 2026-08-23 — code review round 6 High fix) ---
# 디스패처가 순차 실행 + 첫 차단 중단을 보장 — 이 훅이 실행됐다는 것
# 자체가 선행 게이트(discipline-gate, task-gate) 전부 통과의 증명이라
# 형제 추론이 불필요하다. 이전에 여기 있던 same-process peek
# (`_rein_precheck_would_block`)와 그 세 호출부는 제거됐다 — 이 파일
# 상단의 "Precondition-awareness" 갱신 주석에 근본 수리 배경 전체가
# 있다.
#
# RES-1: lazy-resolve VALIDATOR_PATH via plugin-aware helper. The resolver
# picks ${CLAUDE_PLUGIN_ROOT}/scripts/<name> first, then
# ${PROJECT_DIR}/scripts/<name> as fallback.
if [ -z "${VALIDATOR_PATH:-}" ]; then
  VALIDATOR_PATH=$(resolve_helper_script rein-validate-coverage-matrix.py) || {
    mkdir -p "$DOD_DIR" 2>/dev/null
    touch "$DOD_MISMATCH_MARKER" 2>/dev/null
    echo "[rein] The coverage validator (rein-validate-coverage-matrix.py) could not be found. Run 'rein update' to restore it." >&2
    log_block "validator helper missing" "$SAD_PATH"
    exit 2
  }
fi

# Validator call with 30s timeout.
if ! command -v timeout >/dev/null 2>&1; then
  # macOS BSD doesn't ship GNU timeout by default; fall through to
  # no-wrap invocation but still honor the "block on validator fail"
  # contract. The validator is bounded by its own implementation.
  VEXIT=0
  ( cd "$PROJECT_DIR" && "${PYTHON_RUNNER[@]}" "$VALIDATOR_PATH" dod "$SAD_PATH" 2>&1 ) >/dev/null || VEXIT=$?
else
  VEXIT=0
  ( cd "$PROJECT_DIR" && timeout "$VALIDATOR_TIMEOUT_S" "${PYTHON_RUNNER[@]}" "$VALIDATOR_PATH" dod "$SAD_PATH" 2>&1 ) >/dev/null || VEXIT=$?
fi

# Apply the §4.2 outcome table (tier × validator-result → marker + exit).
case "$SAD_TIER:$VEXIT" in
  1:0)
    rm -f "$DOD_MISMATCH_MARKER" "$DOD_ADVISORY_MARKER"
    ;;
  1:124)
    mkdir -p "$PROJECT_DIR/trail/incidents"
    printf '%s\tdod\t%s\ttimeout\n' "$(date -u +%FT%TZ)" "$SAD_PATH" \
      >> "$PROJECT_DIR/trail/incidents/validator-timeout.log" 2>/dev/null || true
    touch "$DOD_MISMATCH_MARKER"
    echo "[rein] The coverage validator timed out while checking $SAD_PATH — the edit is blocked until the validator can complete. Check if the plan file is valid." >&2
    log_block "validator timeout (tier 1)" "$SAD_PATH"
    exit 2
    ;;
  1:*)
    touch "$DOD_MISMATCH_MARKER"
    rm -f "$DOD_ADVISORY_MARKER"
    echo "[rein] The coverage check failed for the active task record ($SAD_PATH, exit $VEXIT). Update the '## 범위 연결' section to reference the IDs that are actually marked 'implemented' in the plan." >&2
    log_block "dod covers mismatch (tier 1)" "$SAD_PATH"
    exit 2
    ;;
  2:0)
    rm -f "$DOD_ADVISORY_MARKER"
    ;;
  2:124)
    mkdir -p "$PROJECT_DIR/trail/incidents"
    printf '%s\tdod\t%s\ttimeout\n' "$(date -u +%FT%TZ)" "$SAD_PATH" \
      >> "$PROJECT_DIR/trail/incidents/validator-timeout.log" 2>/dev/null || true
    touch "$DOD_ADVISORY_MARKER"
    echo "WARNING: [DoD gate] validator timeout on $SAD_PATH — advisory only (Tier 2)." >&2
    ;;
  2:*)
    touch "$DOD_ADVISORY_MARKER"
    echo "WARNING: [DoD gate] DoD validator failed for $SAD_PATH (exit $VEXIT, Tier 2 advisory — non-blocking)." >&2
    ;;
esac

exit 0
