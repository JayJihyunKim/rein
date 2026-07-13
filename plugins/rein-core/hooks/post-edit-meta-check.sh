#!/usr/bin/env bash
# Plugin PostToolUse(Edit|Write|MultiEdit) sub-hook — G3 run-time meta-check
# advisory.
#
# Compares the active DoD's `## 변경 파일` hint set with the dirty git diff
# path set (D \ H) and emits a PostToolUse advisory envelope when they
# mismatch. The evaluated-check line is emitted only when
# REIN_META_CHECK_TRACE_FILE is set (test oracle opt-in) — the former
# unconditional trail/inbox jsonl append was retired 2026-07-13 (no consumer).
#
# Silent fail-open at every error path. Never blocks (no exit 2). Aggregator
# (post-edit-aggregator.sh) auto-merges via hook-output-cache.
#
# Dataflow (spec §3.2):
#   1. policy gate (HK-4)                              -> exit 0 if disabled
#   2. fast-path skip (state.json effective_mode=answer) -> G3-MC-FASTPATH
#   3. stdin parse (tool_use_id 추출용)
#   4. active DoD resolve via trail/dod/.active-dod    -> G3-MC-NO-ACTIVE-DOD
#      (NOT select_active_dod — meta-check filters on `## 변경 파일`,
#       not `## 범위 연결`. Different semantics. select_active_dod is for
#       design-coverage gates; meta-check is for file-list anchoring.)
#   5. effective policy: DoD `## 라우팅 추천` meta_check >
#      .rein/policy/meta-check.yaml > 'auto'           -> G3-MC-POLICY
#   6. hint set H from active DoD '## 변경 파일'        -> G3-MC-DOD-MISSING-HINT
#   7. dirty diff set D (env-scrubbed git diff)
#   8. mismatch = (D \ H) ≠ ∅                          -> G3-MC-DETECT
#   9. advisory envelope (conditional, Top-5 + ≤500B)  -> G3-MC-ADVISORY
#  10. trace line append (REIN_META_CHECK_TRACE_FILE opt-in only) -> G3-MC-INBOX (retired)
#
# Scope IDs:
#   G3-MC-FASTPATH G3-MC-NO-ACTIVE-DOD G3-MC-POLICY G3-MC-DOD-MISSING-HINT
#   G3-MC-DETECT G3-MC-ADVISORY G3-MC-INBOX
set -euo pipefail

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# (1) policy gate (HK-4)
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/post-edit-policy-gate.sh" ]; then
  # shellcheck source=./lib/post-edit-policy-gate.sh
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/post-edit-policy-gate.sh"
  post_edit_policy_gate "post-edit-meta-check"
fi

# (2) fast-path skip (G3-MC-FASTPATH)
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state-machine.sh" ]; then
  if . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state-machine.sh" 2>/dev/null; then
    if _fp_line=$(read_fast_path_state 2>/dev/null) \
        && IFS=$'\t' read -r _fp_valid _fp_mode _ <<<"$_fp_line" \
        && [ "$_fp_valid" = "1" ] && [ "$_fp_mode" = "answer" ]; then
      exit 0
    fi
  fi
fi

# (3) stdin parse
INPUT=$(cat || true)
[ -n "$INPUT" ] || exit 0

# (4) active DoD resolve (G3-MC-NO-ACTIVE-DOD)
ACTIVE_MARKER="trail/dod/.active-dod"
[ -f "$ACTIVE_MARKER" ] || exit 0

DOD_PATH=$(awk -F= '/^path=/{print $2; exit}' "$ACTIVE_MARKER" 2>/dev/null | tr -d '\r' || true)
[ -n "$DOD_PATH" ] || exit 0
[ -f "$DOD_PATH" ] || exit 0

# Path containment (GE-1 defense-in-depth — marker file is read-only here but
# share the helper to keep posture consistent across selector callers).
PROJECT_DIR="$(pwd)"
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/path-containment.sh" ]; then
  if . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/path-containment.sh" 2>/dev/null \
      && declare -F validate_repo_relative_path >/dev/null 2>&1; then
    validate_repo_relative_path "$PROJECT_DIR" "$DOD_PATH" >/dev/null 2>&1 || exit 0
  fi
fi

DOD_BASENAME=$(basename "$DOD_PATH")
DOD_SLUG=${DOD_BASENAME#dod-}
DOD_SLUG=${DOD_SLUG%.md}

# (5) effective policy (G3-MC-POLICY)
EFFECTIVE=""

# Step a: DoD `## 라우팅 추천` meta_check field (per-task override)
DOD_META_LINE=$(awk '
  /^## 라우팅 추천/ {f=1; next}
  f && /^## / {f=0}
  f && /^[[:space:]]*meta_check:/ {print; exit}
' "$DOD_PATH" 2>/dev/null || true)
if [ -n "$DOD_META_LINE" ]; then
  VAL=$(printf '%s' "$DOD_META_LINE" | sed -E 's/^[[:space:]]*meta_check:[[:space:]]*([^[:space:]]+).*$/\1/' | tr '[:upper:]' '[:lower:]')
  case "$VAL" in
    true|false|auto) EFFECTIVE="$VAL" ;;
  esac
fi

# Step b: .rein/policy/meta-check.yaml fallback (shell helper — PERF-SHELL-POLICY-LOADER)
# G3-perf-NFR: replaces python3 rein-policy-loader.py --meta-check-policy (~43ms cold)
# with shell awk (~5ms). Python rein-policy-loader.py::get_meta_check_policy() and
# --meta-check-policy CLI remain unchanged (PERF-PYTHON-API-BACKCOMPAT).
if [ -z "$EFFECTIVE" ]; then
  if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/meta-check-policy.sh" ]; then
    # shellcheck source=./lib/meta-check-policy.sh
    . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/meta-check-policy.sh"
    if declare -F meta_check_policy_shell >/dev/null 2>&1; then
      EFFECTIVE=$(meta_check_policy_shell 2>/dev/null || true)
    fi
  fi
fi

# Step c: built-in default
[ -n "$EFFECTIVE" ] || EFFECTIVE="auto"

# meta_check: false → immediate skip (G3-MC-POLICY false branch)
if [ "$EFFECTIVE" = "false" ]; then
  exit 0
fi

# (6)-(7) hint parse + dirty diff + mismatch detect + envelope prep
# Dirty set D = tracked-modified (git diff HEAD) ∪ untracked (ls-files --others).
# Spec §3.2 step 7 literally says "git diff --name-only HEAD" but that misses
# untracked Write-created files — exactly the UX path the meta-check exists to
# catch. We extend with `ls-files --others --exclude-standard` so a `Write` of
# a brand-new path also surfaces (codex Round 1 Medium).
DIFF_RAW=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git diff --name-only HEAD 2>/dev/null || true)
UNTRACKED=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git ls-files --others --exclude-standard 2>/dev/null || true)

# MCU-1: untracked mtime-window filter. The raw `ls-files --others` set mixes
# "files Write-created this session" (the path we want to surface) with
# "long-abandoned untracked files the user never .gitignored" (e.g. *.parquet,
# screens_ref/, key_meaning.png). The latter triggers a false-positive mismatch
# advisory on EVERY edit. We keep only untracked files whose mtime is at or
# after the session-start anchor (trail/incidents/.session-start-line stamp,
# written once per session by session-start-load-trail.sh). Files older than
# the anchor are abandoned and dropped.
#
# fail-open (CRITICAL): if the anchor is absent or its mtime is unreadable, we
# keep the WHOLE untracked set (current behavior) so the new-Write detection is
# never silently lost. The anchor stamp itself is always excluded from D — it is
# a hook-managed marker, not user work (it is tracked in the rein repo so
# ls-files --others normally omits it, but a freshly-rewritten stamp in a fresh
# sandbox can surface as untracked).
META_ANCHOR="trail/incidents/.session-start-line"
ANCHOR_EPOCH=""
if [ -f "$META_ANCHOR" ]; then
  if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/portable.sh" ]; then
    # shellcheck source=./lib/portable.sh
    . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/portable.sh" 2>/dev/null || true
  fi
  if declare -F portable_mtime_epoch >/dev/null 2>&1; then
    ANCHOR_EPOCH=$(portable_mtime_epoch "$META_ANCHOR" 2>/dev/null || true)
  else
    # portable.sh unavailable → inline BSD/GNU stat fallback. set -e safe via || true.
    case "$(uname 2>/dev/null || echo unknown)" in
      Darwin) ANCHOR_EPOCH=$(stat -f %m "$META_ANCHOR" 2>/dev/null || true) ;;
      *)      ANCHOR_EPOCH=$(stat -c %Y "$META_ANCHOR" 2>/dev/null || true) ;;
    esac
  fi
  # Non-numeric / 0 → treat as unreadable (fail-open).
  case "$ANCHOR_EPOCH" in
    ''|0|*[!0-9]*) ANCHOR_EPOCH="" ;;
  esac
fi

if [ -n "$UNTRACKED" ]; then
  UNTRACKED_FILTERED=""
  while IFS= read -r _u; do
    [ -n "$_u" ] || continue
    # Always exclude the anchor stamp itself — hook-managed marker, not work.
    [ "$_u" = "$META_ANCHOR" ] && continue
    if [ -n "$ANCHOR_EPOCH" ] && [ -f "$_u" ]; then
      _fe=""
      if declare -F portable_mtime_epoch >/dev/null 2>&1; then
        _fe=$(portable_mtime_epoch "$_u" 2>/dev/null || true)
      else
        case "$(uname 2>/dev/null || echo unknown)" in
          Darwin) _fe=$(stat -f %m "$_u" 2>/dev/null || true) ;;
          *)      _fe=$(stat -c %Y "$_u" 2>/dev/null || true) ;;
        esac
      fi
      case "$_fe" in
        ''|*[!0-9]*) _fe="" ;;
      esac
      # fail-open per-file: unreadable mtime → keep the file. Otherwise drop
      # files older than the session-start anchor (abandoned untracked).
      if [ -n "$_fe" ] && [ "$_fe" -lt "$ANCHOR_EPOCH" ]; then
        continue
      fi
    fi
    if [ -n "$UNTRACKED_FILTERED" ]; then
      UNTRACKED_FILTERED="$UNTRACKED_FILTERED"$'\n'"$_u"
    else
      UNTRACKED_FILTERED="$_u"
    fi
  done <<< "$UNTRACKED"
  UNTRACKED="$UNTRACKED_FILTERED"
fi

if [ -n "$UNTRACKED" ]; then
  if [ -n "$DIFF_RAW" ]; then
    DIFF_RAW="$DIFF_RAW"$'\n'"$UNTRACKED"
  else
    DIFF_RAW="$UNTRACKED"
  fi
fi

# D = ∅ → no-op (pre-edit sync state — common case before any modification)
if [ -z "$DIFF_RAW" ]; then
  exit 0
fi

# (8)-(10) Combined parse + mismatch + envelope/inbox + tool_use_id synthesis
# (single python call — PERF-HEREDOC-TOOL-USE-ID-MERGE).
# Data is passed via environment variables (NOT via pipe-stdin) because
# `python3 - <<'PY'` consumes stdin for the script source — a pipe on the
# left of `python3 -` is overridden by the heredoc and never reaches the
# script. Env-var passing keeps script + data cleanly separated.
#
# Phase 2 (G3-perf-NFR): META_INPUT is passed via env-var so the heredoc can
# extract tool_use_id inline, eliminating the separate line ~264 python3 -c
# invocation. Falls back to that separate call when INPUT > 16KB (Windows Git
# Bash total env block safety — spec §3.2.1).
META_INPUT_THRESHOLD=16384
INPUT_LEN=${#INPUT}
META_INPUT_PASS=""
if [ "$INPUT_LEN" -le "$META_INPUT_THRESHOLD" ]; then
  META_INPUT_PASS="$INPUT"
fi

PY_RESULT=$(META_DOD_PATH="$DOD_PATH" META_EFFECTIVE="$EFFECTIVE" META_DOD_SLUG="$DOD_SLUG" META_DIFF_RAW="$DIFF_RAW" META_INPUT="$META_INPUT_PASS" python3 - <<'PY' 2>/dev/null || true
import os
import sys
import json
import datetime

dod_path = os.environ.get("META_DOD_PATH", "")
effective = os.environ.get("META_EFFECTIVE", "auto")
dod_slug = os.environ.get("META_DOD_SLUG", "")
diff_blob = os.environ.get("META_DIFF_RAW", "")
input_blob = os.environ.get("META_INPUT", "")

D = {line.strip() for line in diff_blob.splitlines() if line.strip()}
diff_count = len(D)

# Parse DoD changed-files section -> H (repo-relative literal path bullet list)
# Use chr(96) instead of literal backtick because the heredoc lives inside a
# bash command substitution $(...), which (against POSIX) still parses backticks
# even though <<'PY' is single-quoted. chr(96) avoids that parser corner.
BT = chr(96)
hint_files = []
section_present = False
try:
    with open(dod_path, "r", encoding="utf-8") as fh:
        in_section = False
        for raw_line in fh:
            line = raw_line.rstrip("\n")
            if line.startswith("## 변경 파일"):
                in_section = True
                section_present = True
                continue
            if in_section and line.startswith("## "):
                in_section = False
                continue
            if not in_section:
                continue
            stripped = line.strip()
            if not stripped.startswith("- "):
                continue
            item = stripped[2:].strip()
            if item.startswith(BT):
                end = item.find(BT, 1)
                if end > 0:
                    item = item[1:end]
                else:
                    item = item.strip(BT)
            else:
                tokens = item.split(None, 1)
                first = tokens[0] if tokens else ""
                if "/" in first or "." in first:
                    item = first
            item = item.strip()
            if item:
                hint_files.append(item)
except Exception:
    pass

H = set(hint_files)
hint_count = len(H)
mismatch_set = sorted(D - H)
mismatch_count = len(mismatch_set)

# Codex Round 2 Medium: distinguish "section absent" from "section present but
# empty". Spec §3.2 dataflow step 6 G3-MC-DOD-MISSING-HINT applies only to the
# absent case. An empty present section is a legitimate H=∅ declaration ("no
# files expected to change") and must drive full-mismatch advisory like the
# `true` branch — NOT silent skip in auto.
if not section_present and effective == "auto":
    action = "SKIP_NO_HINT_AUTO"
elif mismatch_count > 0:
    action = "EMIT"
else:
    action = "INBOX_ONLY"

envelope_json = ""
if action == "EMIT":
    top5 = mismatch_set[:5]
    sample = ", ".join(top5)
    suffix = "" if mismatch_count <= 5 else f" ... (+{mismatch_count - 5} more)"
    # Spec §2.1 G3-MC-ADVISORY: body = slug + hint files count + diff files count
    # + (D \ H) Top-N + cap. The earlier draft omitted hint/diff counts (codex
    # Round 1 Medium); spec language is explicit.
    body = (
        f"[meta-check] DoD '{dod_slug}' '## 변경 파일' (hint={hint_count}) vs "
        f"diff (D={diff_count}) 불일치. 예상 외 {mismatch_count}개: {sample}{suffix}"
    )
    body_bytes = body.encode("utf-8")
    if len(body_bytes) > 500:
        body = body_bytes[:497].decode("utf-8", errors="ignore") + "..."
    envelope_json = json.dumps(
        {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": body}},
        ensure_ascii=False,
        separators=(",", ":"),
    )

inbox_json = ""
if action != "SKIP_NO_HINT_AUTO":
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    inbox_json = json.dumps(
        {
            "ts": ts,
            "dod_slug": dod_slug,
            "diff_files_count": diff_count,
            "mismatch_count": mismatch_count,
            "hint_files_count": hint_count,
            "sample_missing_files": mismatch_set[:5],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )

# Phase 2: tool_use_id extracted in-heredoc when META_INPUT is non-empty
# (fast path). On oversized INPUT (>16KB) META_INPUT is empty -> tool_use_id
# stays "" here and is extracted later via the legacy python3 -c fallback.
tool_use_id = ""
if input_blob:
    try:
        d = json.loads(input_blob)
        if isinstance(d, dict):
            tool_use_id = d.get("tool_use_id", "") or ""
    except Exception:
        pass

sys.stdout.write(f"{action}\n{envelope_json}\n{inbox_json}\n{tool_use_id}\n")
PY
)

ACTION=$(printf '%s\n' "$PY_RESULT" | sed -n '1p')
ENVELOPE=$(printf '%s\n' "$PY_RESULT" | sed -n '2p')
INBOX_LINE=$(printf '%s\n' "$PY_RESULT" | sed -n '3p')
TOOL_USE_ID=$(printf '%s\n' "$PY_RESULT" | sed -n '4p')

# ARG_MAX defensive retry: if heredoc exec failed (PY_RESULT empty AND we used
# env-var pass), the env block may have exceeded the OS limit despite our
# 16KB precheck (cumulative env+argv can exceed even when INPUT alone is small).
# Retry without META_INPUT to at least preserve advisory/inbox output —
# tool_use_id is recovered later via the legacy python3 -c fallback path.
if [ -z "$ACTION" ] && [ -n "$META_INPUT_PASS" ]; then
  PY_RESULT=$(META_DOD_PATH="$DOD_PATH" META_EFFECTIVE="$EFFECTIVE" META_DOD_SLUG="$DOD_SLUG" META_DIFF_RAW="$DIFF_RAW" python3 - <<'PY' 2>/dev/null || true
import os
import sys
import json
import datetime

dod_path = os.environ.get("META_DOD_PATH", "")
effective = os.environ.get("META_EFFECTIVE", "auto")
dod_slug = os.environ.get("META_DOD_SLUG", "")
diff_blob = os.environ.get("META_DIFF_RAW", "")

D = {line.strip() for line in diff_blob.splitlines() if line.strip()}
diff_count = len(D)
BT = chr(96)
hint_files = []
section_present = False
try:
    with open(dod_path, "r", encoding="utf-8") as fh:
        in_section = False
        for raw_line in fh:
            line = raw_line.rstrip("\n")
            if line.startswith("## 변경 파일"):
                in_section = True
                section_present = True
                continue
            if in_section and line.startswith("## "):
                in_section = False
                continue
            if not in_section:
                continue
            stripped = line.strip()
            if not stripped.startswith("- "):
                continue
            item = stripped[2:].strip()
            if item.startswith(BT):
                end = item.find(BT, 1)
                if end > 0:
                    item = item[1:end]
                else:
                    item = item.strip(BT)
            else:
                tokens = item.split(None, 1)
                first = tokens[0] if tokens else ""
                if "/" in first or "." in first:
                    item = first
            item = item.strip()
            if item:
                hint_files.append(item)
except Exception:
    pass

H = set(hint_files)
hint_count = len(H)
mismatch_set = sorted(D - H)
mismatch_count = len(mismatch_set)

if not section_present and effective == "auto":
    action = "SKIP_NO_HINT_AUTO"
elif mismatch_count > 0:
    action = "EMIT"
else:
    action = "INBOX_ONLY"

envelope_json = ""
if action == "EMIT":
    top5 = mismatch_set[:5]
    sample = ", ".join(top5)
    suffix = "" if mismatch_count <= 5 else f" ... (+{mismatch_count - 5} more)"
    body = (
        f"[meta-check] DoD '{dod_slug}' '## 변경 파일' (hint={hint_count}) vs "
        f"diff (D={diff_count}) 불일치. 예상 외 {mismatch_count}개: {sample}{suffix}"
    )
    body_bytes = body.encode("utf-8")
    if len(body_bytes) > 500:
        body = body_bytes[:497].decode("utf-8", errors="ignore") + "..."
    envelope_json = json.dumps(
        {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": body}},
        ensure_ascii=False,
        separators=(",", ":"),
    )

inbox_json = ""
if action != "SKIP_NO_HINT_AUTO":
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    inbox_json = json.dumps(
        {
            "ts": ts,
            "dod_slug": dod_slug,
            "diff_files_count": diff_count,
            "mismatch_count": mismatch_count,
            "hint_files_count": hint_count,
            "sample_missing_files": mismatch_set[:5],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )

# No tool_use_id here — recovered via legacy python3 -c fallback below
sys.stdout.write(f"{action}\n{envelope_json}\n{inbox_json}\n\n")
PY
)
  ACTION=$(printf '%s\n' "$PY_RESULT" | sed -n '1p')
  ENVELOPE=$(printf '%s\n' "$PY_RESULT" | sed -n '2p')
  INBOX_LINE=$(printf '%s\n' "$PY_RESULT" | sed -n '3p')
  TOOL_USE_ID=""  # force fallback extraction below
  # Mark as if oversized path so the fallback python3 -c at the cache write
  # branch knows to extract tool_use_id from $INPUT.
  INPUT_LEN=$((META_INPUT_THRESHOLD + 1))
fi

# G3-MC-DOD-MISSING-HINT (a) — auto + no hint → NOTICE + silent skip
if [ "$ACTION" = "SKIP_NO_HINT_AUTO" ]; then
  echo "[meta-check] active DoD '$DOD_SLUG' '## 변경 파일' 섹션 없음 → silent skip (effective=auto)" >&2
  exit 0
fi

# G3-MC-ADVISORY — emit envelope only on mismatch
if [ -n "$ENVELOPE" ]; then
  # Phase 2 fast path: TOOL_USE_ID already extracted inside heredoc.
  # Fallback path: oversized INPUT (>16KB) skipped env-var pass — extract here.
  if [ -z "$TOOL_USE_ID" ] && [ "$INPUT_LEN" -gt "$META_INPUT_THRESHOLD" ]; then
    TOOL_USE_ID=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    sys.stdout.write(d.get("tool_use_id", "") or "")
' 2>/dev/null || true)
  fi

  CACHE_OK=0
  if [ -n "$TOOL_USE_ID" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-output-cache.sh" ]; then
    # shellcheck disable=SC1091
    . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-output-cache.sh"
    if output_cache_write "$TOOL_USE_ID" "post-edit-meta-check" "$ENVELOPE" 2>/dev/null; then
      CACHE_OK=1
    fi
  fi

  if [ "$CACHE_OK" = "0" ]; then
    printf '%s\n' "$ENVELOPE"
  fi
fi

# G3-MC-INBOX (retired 2026-07-13) — the unconditional trail/inbox jsonl append
# is removed: no production consumer ever read it and it accumulated forever in
# user repos. The evaluated-check line is now written ONLY when a caller (tests)
# opts in via REIN_META_CHECK_TRACE_FILE, which keeps the behavioral test oracle
# (mismatch_count observation) without leaving files behind in real sessions.
if [ -n "$INBOX_LINE" ] && [ -n "${REIN_META_CHECK_TRACE_FILE:-}" ]; then
  printf '%s\n' "$INBOX_LINE" >> "$REIN_META_CHECK_TRACE_FILE" 2>/dev/null || true
fi

exit 0
