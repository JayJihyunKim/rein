#!/usr/bin/env bash
set -euo pipefail

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

info()  { echo -e "${GREEN}$*${NC}" >&2; }
warn()  { echo -e "${YELLOW}$*${NC}" >&2; }
error() { echo -e "${RED}Error: $*${NC}" >&2; }
fatal() { echo -e "${RED}Fatal: $*${NC}" >&2; exit 1; }

VERSION="2.0.0"
TEMPLATE_REPO="${REIN_TEMPLATE_REPO:-${CLAUDE_TEMPLATE_REPO:-git@github.com:JayJihyunKim/rein.git}}"

# ---------------------------------------------------------------------------
# detect_platform()
# Returns "posix" on Linux/Darwin, "windows_git_bash" on MINGW*/MSYS*.
# Exits 1 (prints error to stderr) on unsupported platforms.
# Plan C Task 1.1.
# ---------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Linux|Darwin) echo "posix" ;;
    MINGW*|MSYS*) echo "windows_git_bash" ;;
    *) echo "unsupported: $(uname -s)" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# write_atomic <path> <content>
# Writes <content> to <path> via temp-file + rename, so a concurrent reader
# never sees a partial write. Plan C Task 1.2 (BG-file-state-atomic-write).
#
# The temp-file name combines PID + shell-level-random so concurrent writers
# (running as subshells that inherit $$) don't collide on the staging name.
# ---------------------------------------------------------------------------
write_atomic() {
  local path="$1" content="$2"
  # BASHPID differs in subshells; RANDOM adds extra entropy so parallel
  # invocations inside ( ... ) & ( ... ) & never pick the same tmp path.
  local tmp="${path}.tmp.${BASHPID:-$$}.${RANDOM}${RANDOM}"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$path"
}

# ---------------------------------------------------------------------------
# State / jobs dir helpers — fixed paths, relative to project root.
# Plan C Task 1.2 (BG-file-state-layout).
# ---------------------------------------------------------------------------
rein_state_dir()     { echo ".claude/.rein-state"; }
rein_base_dir()      { echo ".claude/.rein-state/base"; }
rein_conflicts_dir() { echo ".claude/.rein-state/conflicts"; }

# Phase 3 Task 3.3: jobs path is mode-aware.
#
# Resolution order (preserves legacy installs without forcing migration):
#   1. Plugin install — ${CLAUDE_PLUGIN_ROOT}/scripts/rein-state-paths.py jobs
#      always wins when available. Plugin host always sets CLAUDE_PLUGIN_ROOT.
#   2. Scaffold dev — plugins/rein-core/scripts/rein-state-paths.py jobs IF
#      .rein/project.json explicitly opts into the new layout (mode set OR
#      .rein/cache/ directory already exists). This avoids surprising legacy
#      rein-dev clones (no .rein/project.json) by keeping their jobs in
#      .claude/cache/jobs/ until ``rein migrate`` runs in Phase 4.
#   3. Legacy fallback — .claude/cache/jobs.
rein_jobs_dir() {
  local resolver=""
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/rein-state-paths.py" ]; then
    resolver="$CLAUDE_PLUGIN_ROOT/scripts/rein-state-paths.py"
  fi
  if [ -z "$resolver" ] && [ -f ".rein/project.json" ] && [ -f "plugins/rein-core/scripts/rein-state-paths.py" ]; then
    resolver="plugins/rein-core/scripts/rein-state-paths.py"
  fi
  if [ -z "$resolver" ] && [ -d ".rein/cache" ] && [ -f "plugins/rein-core/scripts/rein-state-paths.py" ]; then
    resolver="plugins/rein-core/scripts/rein-state-paths.py"
  fi
  if [ -n "$resolver" ]; then
    local resolved
    resolved=$(python3 "$resolver" jobs 2>/dev/null || true)
    if [ -n "$resolved" ]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi
  echo ".claude/cache/jobs"
}

# ---------------------------------------------------------------------------
# is_text_file <path>
# Returns 0 if the extension matches rein's snapshot-eligible text set,
# 1 otherwise. Extension match is case-sensitive on purpose — rein's own
# template files always use lowercase extensions, and treating README.MD
# as snapshot-eligible would imply a policy we don't guarantee.
# Plan C Task 2.1 (RU-snapshot-textfile-only).
# ---------------------------------------------------------------------------
is_text_file() {
  case "$1" in
    *.md|*.sh|*.py|*.json|*.yml|*.yaml|*.txt|*.toml) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# sha256_of <path>
# Portable sha256 wrapper: sha256sum (Linux) / shasum (macOS) / openssl fallback.
# Emits only the hex digest, empty string on failure.
# Plan C Task 2.2 — used by the v2 update path.
# ---------------------------------------------------------------------------
sha256_of() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# rein_manifest_helper
# Absolute path to scripts/rein-manifest-v2.py. Resolves via BASH_SOURCE so
# it works both when rein.sh is executed directly and when sourced from
# tests (--source-only). Cached across calls.
# Plan C Task 2.2.
# ---------------------------------------------------------------------------
_REIN_MANIFEST_HELPER=""
rein_manifest_helper() {
  if [ -z "$_REIN_MANIFEST_HELPER" ]; then
    local src="${BASH_SOURCE[0]:-$0}"
    local dir
    dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)
    _REIN_MANIFEST_HELPER="$dir/rein-manifest-v2.py"
  fi
  echo "$_REIN_MANIFEST_HELPER"
}

# ---------------------------------------------------------------------------
# is_first_update_v2
# Returns 0 (true) if the current update should take the v2 first-update
# path (preserve text files + seed base). Triggers on:
#   - no manifest at all (fresh install — nothing to compare)
#   - manifest schema_version == "1" (legacy install, not yet migrated)
#   - base snapshot directory missing (partial migration)
# Otherwise returns 1 — the v2 steady-state update path handles subsequent
# updates via 3-way merge (Phase 3).
# Plan C Task 2.2 (RU-first-update-preserves-modified-files).
# ---------------------------------------------------------------------------
is_first_update_v2() {
  local manifest=".claude/.rein-manifest.json"
  [ ! -f "$manifest" ] && return 0
  local schema
  schema=$(python3 "$(rein_manifest_helper)" schema "$manifest" 2>/dev/null)
  [ "$schema" = "1" ] && return 0
  [ ! -d "$(rein_base_dir)" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# apply_first_update_text <template_root> <rel_path>
# Apply the v1 → v2 first-update policy to a single text file:
#   - If user file is absent    → install incoming, seed base=incoming.
#                                  log "installed: <rel>".
#   - If user == incoming       → no-op, seed base=incoming, log no change.
#   - If user != incoming       → PRESERVE user, seed base=incoming,
#                                  log "preserved: <rel> (modified since install)".
# Never overwrites the user's on-disk content. Binary/non-text paths must
# NOT call this helper — they use the legacy 2-way path.
# Plan C Task 2.2 (RU-first-update-preserves-modified-files,
#                  RU-first-update-seeds-base-for-textfiles-only).
# ---------------------------------------------------------------------------
apply_first_update_text() {
  local template_root="$1" rel="$2"
  local incoming="$template_root/$rel"
  [ -f "$incoming" ] || { echo "apply_first_update_text: missing incoming $incoming" >&2; return 2; }

  local base="$(rein_base_dir)/$rel"
  mkdir -p "$(dirname "$base")"

  if [ ! -f "$rel" ]; then
    mkdir -p "$(dirname "$rel")"
    cp "$incoming" "$rel"
    cp "$incoming" "$base"
    echo "installed: $rel"
    return 0
  fi

  local hu hi
  hu=$(sha256_of "$rel")
  hi=$(sha256_of "$incoming")
  if [ "$hu" = "$hi" ]; then
    cp "$incoming" "$base"
    return 0
  fi

  cp "$incoming" "$base"
  echo "preserved: $rel (modified since install)"
  return 0
}

# ---------------------------------------------------------------------------
# _rein_rej_slug <rel>
# Produces a filename-safe slug from a relative path for use as the
# conflict artifact name. Replaces '/' with '-' and strips any other
# character that isn't [A-Za-z0-9.-] to '-'.
# ---------------------------------------------------------------------------
_rein_rej_slug() {
  printf '%s' "$1" | tr '/' '-' | tr -c 'A-Za-z0-9.-' '-'
}

# ---------------------------------------------------------------------------
# Staging manifest helpers — Plan C Task 3.3 (RU-update-manifest-atomic-only).
#
# The v2 update path never mutates the live manifest directly. Instead:
#   1. stage_manifest_begin — create/reset a staging manifest next to the
#      live file. Any stale staging from a previously-interrupted run is
#      discarded (with a warning) so that we never mix payloads.
#   2. stage_manifest_add <rel> <sha> — upsert one entry into the staging
#      manifest. Atomic on a per-call basis (via rein-manifest-v2.py).
#   3. stage_manifest_commit — atomically rename the staging file onto the
#      live manifest path. After this, the live manifest reflects the
#      entire update; before this, it reflects the prior state.
#
# This matches the plan's contract: user-facing files may be half-updated
# on an interrupted run, but the live manifest is either the prior
# snapshot or the new snapshot, never a partial blend.
# ---------------------------------------------------------------------------
staging_manifest_path() { echo "$(rein_state_dir)/manifest.next.json"; }

# manifest_path() is already defined earlier in this file for v1 callers.
# The v2 path re-uses that function (it takes a project_dir and returns
# "$project_dir/.claude/.rein-manifest.json"). v2 code always calls it with
# "." so the path is relative to the CWD — same contract as the v1 flow.

stage_manifest_begin() {
  local stage; stage=$(staging_manifest_path)
  mkdir -p "$(rein_state_dir)"
  if [ -f "$stage" ]; then
    warn "warning: stale staging manifest detected at $stage, discarding"
    rm -f "$stage"
  fi
  # Initialize a fresh v2 manifest at the staging path.
  python3 "$(rein_manifest_helper)" init "$stage" "$VERSION"
}

stage_manifest_add() {
  local rel="$1" sha="$2"
  local stage; stage=$(staging_manifest_path)
  [ -f "$stage" ] || { echo "stage_manifest_add: call stage_manifest_begin first" >&2; return 2; }
  python3 "$(rein_manifest_helper)" add "$stage" "$rel" "$sha" "$VERSION"
}

stage_manifest_commit() {
  local stage; stage=$(staging_manifest_path)
  local live; live=$(manifest_path ".")
  [ -f "$stage" ] || { echo "stage_manifest_commit: nothing to commit ($stage missing)" >&2; return 2; }
  mkdir -p "$(dirname "$live")"
  mv -f "$stage" "$live"
}

# ---------------------------------------------------------------------------
# safe_cp_base <incoming_src> <base_dst> <rel>
# Copies an incoming template file into the base-snapshot location. On any
# failure (typically EACCES when the base dir is read-only for tests), it
# emits a .rej artifact under rein_conflicts_dir/ and returns 1 — callers
# treat that as a conflict (RU-update-base-write-failure-as-conflict).
# Success path returns 0 with base updated byte-for-byte.
# Plan C Task 3.5.
# ---------------------------------------------------------------------------
safe_cp_base() {
  local src="$1" dst="$2" rel="$3"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  if cp "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  local rc=$?
  local ts slug rej
  ts=$(date -u +'%Y-%m-%dT%H-%M-%S')
  slug=$(_rein_rej_slug "$rel")
  mkdir -p "$(rein_conflicts_dir)"
  rej="$(rein_conflicts_dir)/${ts}-${slug}.base-write-failed.rej"
  printf 'base-write-failed: errno_exit=%s rel=%s dst=%s\n' "$rc" "$rel" "$dst" > "$rej"
  return 1
}

# ---------------------------------------------------------------------------
# count_prune_candidates <project_dir> <template_dir>
# Returns (stdout) the number of files currently recorded in the manifest
# that are absent from the incoming template. Plan C Task 4.1 helper for
# report_prune_count (RU-update-default-shows-prune-count).
#
# Implementation note: silently returns 0 when the manifest is missing or
# unreadable — callers use this for an informational one-liner, so they
# must not fail because a fresh install has no manifest yet.
# ---------------------------------------------------------------------------
count_prune_candidates() {
  local project_dir="$1" template_dir="$2"
  local mf; mf=$(manifest_path "$project_dir")
  if [ ! -f "$mf" ]; then
    echo 0
    return 0
  fi
  python3 - "$mf" "$template_dir" <<'PY'
import json, os, sys
mf, template_root = sys.argv[1], sys.argv[2]
try:
    with open(mf) as f:
        data = json.load(f)
except Exception:
    print(0); sys.exit(0)
files = (data.get("files") or {}).keys()
gone = [rel for rel in files if not os.path.exists(os.path.join(template_root, rel))]
print(len(gone))
PY
}

# ---------------------------------------------------------------------------
# report_prune_count <project_dir> <template_dir>
# Emits the "N file(s) removed from template since last update" line when
# count_prune_candidates > 0, silent otherwise. Used by cmd_update's
# default (non-prune) path. Plan C Task 4.1.
# ---------------------------------------------------------------------------
report_prune_count() {
  local project_dir="$1" template_dir="$2"
  local gone
  gone=$(count_prune_candidates "$project_dir" "$template_dir")
  if [ "$gone" -gt 0 ]; then
    echo "ℹ️  $gone file(s) removed from template since last update. Run 'rein update --prune' to review."
  fi
}

# ---------------------------------------------------------------------------
# _classify_prune_candidates <project_dir> <template_dir>
# Emits TSV lines to stdout classifying every manifest-tracked file that is
# absent from the current template:
#   SAFE\t<rel>       — on-disk content matches recorded sha → safe to delete
#   MODIFIED\t<rel>   — user has edited → preserve
#   GONE\t<rel>       — already deleted by the user → nothing to do
#   UNSAFE\t<rel>\t…  — path escapes project root → refuse to touch
# Shared by prune_review + prune_apply. Plan C Task 4.2.
# ---------------------------------------------------------------------------
_classify_prune_candidates() {
  local project_dir="$1" template_dir="$2"
  local mf; mf=$(manifest_path "$project_dir")
  [ -f "$mf" ] || return 0
  python3 - "$mf" "$template_dir" "$project_dir" <<'PY'
import json, os, sys, hashlib
mf, template_root, project_dir = sys.argv[1], sys.argv[2], sys.argv[3]
project_abs = os.path.realpath(project_dir)

try:
    with open(mf) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

files = data.get("files") or {}
gone_from_template = sorted(
    rel for rel in files if not os.path.exists(os.path.join(template_root, rel))
)

def sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

def is_safe(rel):
    if not rel or os.path.isabs(rel):
        return False
    norm = os.path.normpath(rel)
    if norm.startswith("..") or os.path.isabs(norm):
        return False
    if any(p == ".." for p in norm.split(os.sep)):
        return False
    full = os.path.realpath(os.path.join(project_abs, norm))
    try:
        common = os.path.commonpath([project_abs, full])
    except ValueError:
        return False
    return common == project_abs and full != project_abs

for rel in gone_from_template:
    if not is_safe(rel):
        print(f"UNSAFE\t{rel}\trefusing to touch path outside project")
        continue
    full = os.path.join(project_abs, rel)
    recorded = (files.get(rel) or {}).get("sha256", "")
    if not os.path.exists(full):
        print(f"GONE\t{rel}")
        continue
    cur = sha256(full)
    if cur and cur == recorded:
        print(f"SAFE\t{rel}")
    else:
        print(f"MODIFIED\t{rel}")
PY
}

# ---------------------------------------------------------------------------
# prune_review <project_dir> <template_dir>
# Print SAFE/MODIFIED/GONE/UNSAFE classification. Never deletes.
# Exit 0 regardless of counts.
# Plan C Task 4.2 (RU-prune-review-without-confirm).
# ---------------------------------------------------------------------------
prune_review() {
  local project_dir="$1" template_dir="$2"
  local plan; plan=$(mktemp)
  _classify_prune_candidates "$project_dir" "$template_dir" > "$plan"
  local safe_count mod_count gone_count unsafe_count
  safe_count=$(awk -F'\t' '$1=="SAFE"{c++} END{print c+0}' "$plan")
  mod_count=$(awk -F'\t' '$1=="MODIFIED"{c++} END{print c+0}' "$plan")
  gone_count=$(awk -F'\t' '$1=="GONE"{c++} END{print c+0}' "$plan")
  unsafe_count=$(awk -F'\t' '$1=="UNSAFE"{c++} END{print c+0}' "$plan")

  echo "Prune review (dry-run, use --prune --confirm to apply):"
  echo "  SAFE     (delete): $safe_count"
  echo "  MODIFIED (keep):   $mod_count"
  echo "  GONE     (noop):   $gone_count"
  if [ "$unsafe_count" -gt 0 ]; then
    echo "  UNSAFE   (skip):   $unsafe_count"
  fi
  if [ "$safe_count" -gt 0 ] || [ "$mod_count" -gt 0 ]; then
    echo
    awk -F'\t' '$1=="SAFE"     {print "  SAFE     " $2}' "$plan"
    awk -F'\t' '$1=="MODIFIED" {print "  MODIFIED " $2}' "$plan"
  fi
  rm -f "$plan"
  return 0
}

# ---------------------------------------------------------------------------
# prune_apply <project_dir> <template_dir>
# Move SAFE files into .rein-prune-backup-<ts>/ (preserving project-rel
# layout), leaving MODIFIED + GONE + UNSAFE untouched. Safe to call in
# steady state — creates the backup dir lazily only when there is at least
# one candidate.
# Plan C Task 4.2 (RU-prune-confirm-requires-flag, RU-remove-backup shared helper).
# ---------------------------------------------------------------------------
prune_apply() {
  local project_dir="$1" template_dir="$2"
  local plan; plan=$(mktemp)
  _classify_prune_candidates "$project_dir" "$template_dir" > "$plan"
  local ts backup_dir moved preserved
  ts=$(date +'%Y-%m-%dT%H-%M-%S')
  backup_dir="$project_dir/.rein-prune-backup-$ts"
  moved=0
  preserved=0

  local line kind rel
  while IFS= read -r line; do
    kind=$(printf '%s' "$line" | cut -f1)
    rel=$(printf '%s' "$line" | cut -f2)
    case "$kind" in
      SAFE)
        if [ -f "$project_dir/$rel" ]; then
          mkdir -p "$backup_dir/$(dirname "$rel")"
          mv "$project_dir/$rel" "$backup_dir/$rel"
          moved=$((moved + 1))
        fi
        ;;
      MODIFIED)
        preserved=$((preserved + 1))
        ;;
      # GONE / UNSAFE — nothing to do
    esac
  done < "$plan"
  rm -f "$plan"

  echo "✓ Pruned $moved file(s). Preserved $preserved modified file(s)."
  if [ "$moved" -gt 0 ]; then
    echo "  Backup: $backup_dir/"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# do_update_v2 <template_root> <rel1> <rel2> ...
# Per-file transactional update loop for the v2 steady-state path
# (Plan C Task 3.2 / RU-update-per-file-content-immediate + Task 3.4 /
#  RU-update-exit-code-partial-conflict).
#
# For each text file, invokes three_way_merge. Non-text files are surfaced
# via _REIN_UPDATE_NONTEXT so the caller can loop them through the legacy
# 2-way path. The caller must call stage_manifest_begin before this and
# stage_manifest_commit after — do_update_v2 only calls stage_manifest_add
# on clean merges, so conflict files retain their prior manifest sha.
#
# Globals set (reset on every call):
#   _REIN_UPDATE_UPDATES   — count of files cleanly merged / fast-forwarded
#   _REIN_UPDATE_CONFLICTS — count of conflict files (user preserved, .rej written)
#   _REIN_UPDATE_FATAL     — 1 if an unrecoverable error was seen, else 0
#   _REIN_UPDATE_NONTEXT   — space-separated list of non-text rel paths
#
# Return codes (mirror Plan C Task 3.4 exit-code mapping):
#   0 — all clean
#   1 — one or more conflicts, transaction can complete
#   2 — fatal error mid-loop (staging manifest left intact for inspection)
# ---------------------------------------------------------------------------
do_update_v2() {
  local template_root="$1"; shift
  _REIN_UPDATE_UPDATES=0
  _REIN_UPDATE_CONFLICTS=0
  _REIN_UPDATE_FATAL=0
  _REIN_UPDATE_NONTEXT=""

  local rel
  for rel in "$@"; do
    if ! is_text_file "$rel"; then
      _REIN_UPDATE_NONTEXT="${_REIN_UPDATE_NONTEXT:+$_REIN_UPDATE_NONTEXT }$rel"
      continue
    fi
    local incoming="$template_root/$rel"
    if [ ! -f "$incoming" ]; then
      # Template no longer carries the file — not our job here; prune is
      # handled in Phase 4. Skip with no sha stage.
      continue
    fi
    local user_p="$rel"
    local base_p="$(rein_base_dir)/$rel"

    local rc=0
    three_way_merge "$user_p" "$base_p" "$incoming" "$rel" || rc=$?

    case "$rc" in
      0)
        _REIN_UPDATE_UPDATES=$((_REIN_UPDATE_UPDATES + 1))
        stage_manifest_add "$rel" "$(sha256_of "$incoming")"
        ;;
      1)
        _REIN_UPDATE_CONFLICTS=$((_REIN_UPDATE_CONFLICTS + 1))
        ;;
      *)
        _REIN_UPDATE_FATAL=1
        echo "fatal: three_way_merge failed for $rel (rc=$rc)" >&2
        return 2
        ;;
    esac
  done

  if [ "$_REIN_UPDATE_CONFLICTS" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# three_way_merge <user_path> <base_path> <incoming_path> <rel_for_record>
#
# Return codes:
#   0 — clean: user updated (or unchanged) to converged state, base refreshed
#   1 — conflict: user and base preserved byte-for-byte, .rej written
#   2 — fatal (e.g., git merge-file crashed with signal)
#
# Decision matrix (sha256 comparison):
#   - user missing                                  → cp incoming→user, cp incoming→base (first install)
#   - all three equal                               → no-op
#   - user != base but user == incoming             → cp incoming→base (user already caught up)
#   - user == base and base != incoming             → cp incoming→{user, base} (clean fast-forward)
#   - user != base and base == incoming             → no-op (user-only changes)
#   - user != base and user != incoming             → true 3-way:
#         git merge-file -p user base incoming > merged
#         success → mv merged → user, cp incoming → base
#         conflict markers → preserve user + base unchanged, write .rej
#
# Plan C Task 3.1 (RU-three-way-merge-*).
# ---------------------------------------------------------------------------
three_way_merge() {
  local user="$1" base="$2" incoming="$3" rel="$4"

  [ -f "$incoming" ] || { echo "three_way_merge: missing incoming $incoming" >&2; return 2; }

  # First install — user absent ⇒ install incoming, then seed base.
  # If the base-seed fails we keep the user file (already installed) and
  # report a conflict per RU-update-base-write-failure-as-conflict.
  if [ ! -f "$user" ]; then
    mkdir -p "$(dirname "$user")"
    cp "$incoming" "$user"
    # Finding 3 (2026-04-24): propagate exec bit even in edge cases where
    # cp on the current filesystem does not reflect incoming mode.
    if [[ -x "$incoming" && ! -x "$user" ]]; then chmod +x "$user"; fi
    if ! safe_cp_base "$incoming" "$base" "$rel"; then
      return 1
    fi
    return 0
  fi

  # base may not exist yet if the caller is in a partially-migrated state.
  # Try to seed it; if that fails, degrade to conflict immediately — we
  # cannot safely run 3-way without a base, and silently overwriting the
  # user would violate RU-three-way-merge-no-silent-overwrite.
  if [ ! -f "$base" ]; then
    if ! safe_cp_base "$incoming" "$base" "$rel"; then
      return 1
    fi
    # Continue with the rest of the decision tree so user is still
    # reconciled against incoming if the contents differ.
  fi

  local hu hb hi
  hu=$(sha256_of "$user")
  hb=$(sha256_of "$base")
  hi=$(sha256_of "$incoming")

  # All equal — nothing to do.
  if [ "$hu" = "$hi" ] && [ "$hb" = "$hi" ]; then
    return 0
  fi

  # User already converged to incoming — only base lagged.
  if [ "$hu" = "$hi" ]; then
    if ! safe_cp_base "$incoming" "$base" "$rel"; then
      return 1
    fi
    return 0
  fi

  # User untouched since install (user == base), base != incoming → fast-forward.
  # Update user first (via temp+mv for atomicity), then refresh base. If
  # base-write fails after user was already advanced, the user is now at
  # the incoming content — not a silent overwrite of unrelated user edits
  # since hu == hb, so the user had never diverged — but we still must
  # report conflict so the caller doesn't mark the manifest forward.
  if [ "$hu" = "$hb" ]; then
    local utmp="${user}.update.${BASHPID:-$$}.${RANDOM}"
    cp "$incoming" "$utmp"
    mv -f "$utmp" "$user"
    # Finding 3 (2026-04-24): mv across filesystems may fall back to
    # cp-into-existing-dst, which preserves dst's prior mode instead of
    # the incoming mode. Defensive chmod even on same-fs paths.
    if [[ -x "$incoming" && ! -x "$user" ]]; then chmod +x "$user"; fi
    if ! safe_cp_base "$incoming" "$base" "$rel"; then
      return 1
    fi
    return 0
  fi

  # User-only changes, template unchanged (base == incoming). Nothing to do.
  if [ "$hb" = "$hi" ]; then
    return 0
  fi

  # True 3-way merge required. git merge-file works in place, so stage
  # a temp that starts as a copy of user, then merge into it. We avoid
  # toggling 'set -e' here because mutating the shell option from inside
  # a function leaks state to the caller; instead, swallow failure via
  # '|| rc=$?' so the function never mutates the caller's errexit state.
  local tmp="${user}.merge.${BASHPID:-$$}.${RANDOM}"
  cp "$user" "$tmp"

  local rc=0
  git merge-file -p "$tmp" "$base" "$incoming" > "${tmp}.out" 2>/dev/null || rc=$?

  if [ "$rc" = "0" ]; then
    mv -f "${tmp}.out" "$user"
    rm -f "$tmp"
    # Finding 3 (2026-04-24): ${tmp}.out was written by shell redirect
    # from `git merge-file -p`, so its mode is 0644-ish regardless of
    # incoming's exec bit. Re-propagate exec bit when incoming has one.
    if [[ -x "$incoming" && ! -x "$user" ]]; then chmod +x "$user"; fi
    if ! safe_cp_base "$incoming" "$base" "$rel"; then
      # User content landed successfully; base refresh failed. Manifest
      # stays at the prior sha (caller decides via conflict count) and a
      # .rej artifact has been written by safe_cp_base.
      return 1
    fi
    return 0
  fi

  # rc 1..127 = number of conflicts reported by merge-file. Anything else
  # (signal termination, binary file, etc.) is a fatal error.
  if [ "$rc" -ge 1 ] && [ "$rc" -le 127 ]; then
    local ts slug rej
    ts=$(date -u +'%Y-%m-%dT%H-%M-%S')
    slug=$(_rein_rej_slug "$rel")
    mkdir -p "$(rein_conflicts_dir)"
    rej="$(rein_conflicts_dir)/${ts}-${slug}.rej"
    mv -f "${tmp}.out" "$rej"
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp" "${tmp}.out"
  return 2
}

# ---------------------------------------------------------------------------
# ensure_gitignore_entries()
# Appends rein operational-hygiene entries to ./.gitignore if missing.
# Idempotent for partially-migrated installs — each pattern is checked and
# appended independently. A header line is added the first time any entry
# is appended during the current invocation so we don't spam headers on
# repeat calls with nothing to add.
# Plan C Task 1.3 (RU-backup-dirs-gitignored, RU-snapshot-storage-location-ignored).
# ---------------------------------------------------------------------------
ensure_gitignore_entries() {
  local gi=".gitignore"
  [ -f "$gi" ] || touch "$gi"

  local header_written=0
  local pat
  for pat in \
    '.rein-prune-backup-*/' \
    '.rein-remove-backup-*/' \
    '/.claude/.rein-state/' \
    '/.claude/cache/jobs/'
  do
    if ! grep -qF "$pat" "$gi"; then
      if [ "$header_written" = "0" ]; then
        # Ensure separation from preceding content, then emit the header once.
        printf '\n# rein operational hygiene (Spec C / Plan C Task 1.3)\n' >> "$gi"
        header_written=1
      fi
      printf '%s\n' "$pat" >> "$gi"
    fi
  done
}

# ---------------------------------------------------------------------------
# Temp dir + cleanup
#
# IMPORTANT: clone_template() must NOT be called inside a command substitution
# $(...) because that spawns a subshell and the EXIT trap fires in the subshell,
# deleting the temp dir before the parent can use it.
# Instead, call clone_template directly; it sets the global TMPDIR_PATH and
# TEMPLATE_DIR variables.
# ---------------------------------------------------------------------------
TMPDIR_PATH=""
TEMPLATE_DIR=""

# Preserve original argv for exec re-run after self-update.
ORIGINAL_ARGV=()

cleanup() {
  if [[ -n "$TMPDIR_PATH" && -d "$TMPDIR_PATH" ]]; then
    rm -rf "$TMPDIR_PATH"
  fi
}

# ---------------------------------------------------------------------------
# clone_template()
# Sets global TEMPLATE_DIR (and TMPDIR_PATH for cleanup).
# Installs EXIT trap in the *current* shell (not a subshell).
# ---------------------------------------------------------------------------
clone_template() {
  TMPDIR_PATH="$(mktemp -d)"
  trap cleanup EXIT

  info "Cloning template from $TEMPLATE_REPO ..."
  git clone --depth 1 --quiet "$TEMPLATE_REPO" "$TMPDIR_PATH/template" >&2

  TEMPLATE_DIR="$TMPDIR_PATH/template"
}

# ---------------------------------------------------------------------------
# template_version(template_dir)
# Extracts VERSION="..." from template_dir/scripts/rein.sh.
# Prints version string, or empty on failure.
# ---------------------------------------------------------------------------
template_version() {
  local template_dir="$1"
  local tmpl_rein="$template_dir/scripts/rein.sh"
  [[ -f "$tmpl_rein" ]] || { echo ""; return 1; }
  grep -E '^VERSION=' "$tmpl_rein" | head -1 | cut -d'"' -f2
}

# ---------------------------------------------------------------------------
# current_cli_path()
# Returns absolute path of the currently executing rein script.
# Uses BASH_SOURCE[0] resolved to absolute form.
# Honors REIN_CLI_PATH override for testing.
# ---------------------------------------------------------------------------
current_cli_path() {
  if [[ -n "${REIN_CLI_PATH:-}" ]]; then
    echo "$REIN_CLI_PATH"
    return 0
  fi

  local src="${BASH_SOURCE[0]:-$0}"
  # Resolve to absolute path (readlink -f is GNU-only; use portable fallback)
  if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readlink -f "$src"
  else
    # macOS fallback
    local dir
    dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)
    echo "${dir}/$(basename "$src")"
  fi
}

# ---------------------------------------------------------------------------
# self_update_check(template_dir)
# Decides whether the CLI should self-update.
# Returns 0 and prints nothing if no action needed.
# Returns 1 and prints next-step token if action needed:
#   "APPLY"    — overwrite self and exec re-run
#   "MIGRATE"  — old install, print notice only
# Callers inspect return code; this function does not perform any change.
# ---------------------------------------------------------------------------
self_update_check() {
  local template_dir="$1"

  # Guard 1: recursion protection
  if [[ "${REIN_SELF_UPDATED:-0}" == "1" ]]; then
    info "Self-update: already updated in this invocation, skipping"
    return 0
  fi

  # Guard 2: explicit disable
  if [[ "${REIN_NO_SELF_UPDATE:-0}" == "1" ]]; then
    info "Self-update: disabled via REIN_NO_SELF_UPDATE"
    return 0
  fi

  # Extract template version
  local tv
  tv=$(template_version "$template_dir")
  if [[ -z "$tv" ]]; then
    warn "Self-update: template has no VERSION, skipping"
    return 0
  fi

  # Compare
  if [[ "$tv" == "$VERSION" ]]; then
    info "Self-update: versions match ($VERSION), skipping"
    return 0
  fi

  # Versions differ — return APPLY or MIGRATE based on current path
  local cli_path
  cli_path=$(current_cli_path)

  if [[ "$cli_path" == "/usr/local/bin/rein" ]]; then
    echo "MIGRATE"
  elif [[ "$cli_path" == "$HOME/.rein/bin/rein" ]]; then
    echo "APPLY"
  else
    info "Self-update: detected rein at $cli_path (custom install), skipping"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# self_update_apply(template_dir)
# Overwrites current CLI with template's scripts/rein.sh atomically.
# Validates new file before replacing.
# Caller is responsible for exec re-run after this returns.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# CLI-adjacent helper scripts. These must live in the same directory as the
# `rein` executable (BASH_SOURCE[0] sibling) because rein_manifest_helper()
# and friends resolve them via that path. Self-update and first-home install
# copy the whole set — v1.1.3 hotfix for the case where pre-v1.1.3 users
# self-updated and only got the main rein.sh refreshed, leaving the helper
# slot broken (`rein-manifest-v2.py: No such file or directory`).
# ---------------------------------------------------------------------------
CLI_HELPER_SCRIPTS=(
  "rein-manifest-v2.py"
  "rein-path-match.py"
  "rein-job-wrapper.sh"
)

# _install_cli_helpers <template_dir> <bin_dir>
# Copies every CLI_HELPER_SCRIPTS entry from template_dir/scripts/ into
# bin_dir via the same atomic tmp+mv pattern used for rein.sh itself. Emits
# warnings (not fatals) when a helper is absent from the template — the main
# rein.sh should still finish updating so the user has a working entry point
# and can recover manually if needed.
_install_cli_helpers() {
  local template_dir="$1"
  local bin_dir="$2"
  local helper src dest tmp
  for helper in "${CLI_HELPER_SCRIPTS[@]}"; do
    src="$template_dir/scripts/$helper"
    dest="$bin_dir/$helper"
    if [[ ! -f "$src" ]]; then
      warn "CLI helper missing in template: $helper (skipping)"
      continue
    fi
    if [[ -L "$dest" ]]; then
      warn "Refusing to overwrite symlink at $dest (skipping $helper)"
      continue
    fi
    tmp=$(mktemp "${dest}.XXXXXX") || {
      warn "mktemp failed for $helper (skipping)"
      continue
    }
    if ! cp "$src" "$tmp"; then
      rm -f "$tmp"
      warn "Failed to copy $helper to $tmp (skipping)"
      continue
    fi
    chmod +x "$tmp"
    if ! mv "$tmp" "$dest"; then
      rm -f "$tmp"
      warn "Failed to install $helper to $dest"
      continue
    fi
  done
}

# _ensure_cli_helpers_present
# Self-heal entry called from cmd_merge right after ensure_gitignore_entries.
# Detects stranded installs where rein.sh exists but one or more CLI-adjacent
# helpers (CLI_HELPER_SCRIPTS) are missing from the bin directory, and
# restores them from the freshly cloned TEMPLATE_DIR. Idempotent — no-op
# when all helpers are present. Does nothing if TEMPLATE_DIR is unset or if
# the cli_path cannot be resolved (both are indicative of a test-only code
# path that wouldn't hit a real install anyway).
# Plan — v1.1.4 hotfix (chicken-and-egg recovery for v1.0.x/v1.1.0–v1.1.2 →
# v1.1.3 self-updaters + structural defense against same-version drift).
_ensure_cli_helpers_present() {
  # If we were not yet set up by cmd_merge, skip (source-only test paths).
  [ -n "${TEMPLATE_DIR:-}" ] || return 0
  local cli_path cli_dir
  cli_path=$(current_cli_path 2>/dev/null) || return 0
  [ -n "$cli_path" ] || return 0
  cli_dir=$(cd "$(dirname "$cli_path")" 2>/dev/null && pwd -P) || return 0
  [ -n "$cli_dir" ] || return 0
  local helper missing=0
  for helper in "${CLI_HELPER_SCRIPTS[@]}"; do
    if [ ! -f "$cli_dir/$helper" ]; then
      missing=1
      break
    fi
  done
  [ "$missing" -eq 1 ] || return 0
  info "Recovering missing CLI helpers from template into $cli_dir ..."
  _install_cli_helpers "$TEMPLATE_DIR" "$cli_dir"
}

self_update_apply() {
  local template_dir="$1"
  local tmpl_rein="$template_dir/scripts/rein.sh"
  local cli_path
  cli_path=$(current_cli_path)

  [[ -f "$tmpl_rein" ]] || fatal "Template rein.sh not found at $tmpl_rein"

  # Sanity check: new file must pass bash -n and have VERSION
  if ! bash -n "$tmpl_rein" 2>/dev/null; then
    fatal "Template rein.sh has syntax errors, aborting self-update"
  fi
  if ! grep -q '^VERSION=' "$tmpl_rein"; then
    fatal "Template rein.sh missing VERSION, aborting self-update"
  fi

  # Atomic replace: copy to sibling tmp, chmod, mv
  local tmp
  tmp=$(mktemp "${cli_path}.XXXXXX") || {
    fatal "mktemp failed for self-update at ${cli_path}"
  }
  cp "$tmpl_rein" "$tmp" || {
    rm -f "$tmp"
    fatal "Failed to copy new rein.sh to $tmp"
  }
  chmod +x "$tmp"
  if [[ -L "$cli_path" ]]; then
    rm -f "$tmp"
    fatal "Refusing to overwrite symlink at $cli_path"
  fi
  mv "$tmp" "$cli_path" || {
    rm -f "$tmp"
    fatal "Failed to install new rein to $cli_path"
  }

  # v1.1.3 hotfix: refresh CLI-adjacent helpers alongside rein.sh. Before
  # this, self-updates that crossed v1.1.0 (which added the helpers) left
  # users with a broken v2 update path because the helpers were never copied
  # into the bin directory.
  local cli_dir
  cli_dir=$(cd "$(dirname "$cli_path")" 2>/dev/null && pwd -P)
  if [[ -n "$cli_dir" ]]; then
    _install_cli_helpers "$template_dir" "$cli_dir"
  fi

  info "Self-updated: $cli_path"
}

# ---------------------------------------------------------------------------
# migrate_old_install_notice()
# Prints migration guidance for users still on /usr/local/bin/rein.
# Never calls sudo.
# ---------------------------------------------------------------------------
migrate_old_install_notice() {
  warn ""
  warn "⚠️  Migration notice: rein CLI path is changing"
  warn "    old: /usr/local/bin/rein"
  warn "    new: \$HOME/.rein/bin/rein"
  warn ""
  warn "    Please remove the old binary:"
  warn "      sudo rm /usr/local/bin/rein"
  warn ""
  warn "    And ensure ~/.rein/env is sourced in your shell rc:"
  warn "      echo '. \"\$HOME/.rein/env\"' >> ~/.zshrc"
  warn ""
  warn "    The new CLI will be active in your next shell session."
  warn ""
}

# ---------------------------------------------------------------------------
# prompt_self_update()
# Asks user to confirm self-update. Auto-Y when REIN_YES=1 or non-tty.
# Returns 0 (yes) / 1 (no).
# ---------------------------------------------------------------------------
prompt_self_update() {
  local template_dir="$1"
  local tv
  tv=$(template_version "$template_dir")
  info ""
  info "CLI update available: $VERSION -> $tv"

  if [[ "${REIN_YES:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    info "Auto-confirmed (REIN_YES or non-interactive)"
    return 0
  fi

  local ans
  read -r -p "Proceed with self-update? [Y/n] " ans
  case "$ans" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# install_to_new_home(template_dir)
# Copies template scripts/rein.sh to $HOME/.rein/bin/rein and writes
# $HOME/.rein/env. Used during /usr/local/bin -> $HOME/.rein migration.
# ---------------------------------------------------------------------------
install_to_new_home() {
  local template_dir="$1"
  local tmpl_rein="$template_dir/scripts/rein.sh"
  local new_bin="$HOME/.rein/bin/rein"
  local new_env="$HOME/.rein/env"

  # Validate template before installing (mirrors self_update_apply checks)
  if ! bash -n "$tmpl_rein" 2>/dev/null; then
    warn "Template rein.sh has syntax errors, skipping migration install"
    return 1
  fi
  if ! grep -q '^VERSION=' "$tmpl_rein"; then
    warn "Template rein.sh missing VERSION, skipping migration install"
    return 1
  fi

  mkdir -p "$HOME/.rein/bin"

  # Atomic install: mktemp+mv (same as self_update_apply)
  if [[ -L "$new_bin" ]]; then
    warn "Refusing to overwrite symlink at $new_bin"
    return 1
  fi
  local tmp
  tmp=$(mktemp "${new_bin}.XXXXXX") || {
    warn "mktemp failed for migration install"
    return 1
  }
  cp "$tmpl_rein" "$tmp" || {
    rm -f "$tmp"
    warn "Failed to copy template to $tmp"
    return 1
  }
  chmod +x "$tmp"
  mv "$tmp" "$new_bin"

  # v1.1.3 hotfix: install CLI-adjacent helpers alongside rein (same
  # reason as self_update_apply — BASH_SOURCE sibling resolution).
  _install_cli_helpers "$template_dir" "$HOME/.rein/bin"

  # KEEP IN SYNC WITH install.sh:write_env_file()
  if [[ -L "$new_env" ]]; then
    warn "Refusing to overwrite symlink at $new_env"
    return 1
  fi
  cat > "$new_env" <<'EOF'
#!/bin/sh
# rein shell setup — managed file, do not edit manually
case ":${PATH}:" in
    *:"$HOME/.rein/bin":*) ;;
    *) export PATH="$HOME/.rein/bin:$PATH" ;;
esac
EOF

  info "New CLI installed at: $new_bin"
  info "Env file:             $new_env"
}

# ---------------------------------------------------------------------------
# Legacy v1.x copy targets (cmd_new + cmd_merge)
#
# Phase 5 Task 5.2 step 6 — the canonical SSOT for what ships into a user repo
# is now plugins/rein-core/plugin.json (firstClass + scaffoldOverlay +
# scaffoldExtras + scaffoldHelperScripts), reproduced by
# scripts/rein-build-scaffold.py. The hardcoded top-level COPY_TARGETS array
# has been retired to eliminate drift risk between the array and plugin.json.
#
# `cmd_new` (legacy `rein new <project>`) and `cmd_merge` (legacy `rein update`
# scaffold-mode 3-way merge path) still need a flat list of repo-relative paths
# to walk. They get it from `list_copy_files()`, which derives the list at
# call time from the same scaffold contract. Phase 8/9 will move both commands
# to delegate fully to rein-build-scaffold.py + manifest-v2; until then the
# helper below is the single point that knows what "rein-managed" means.
# ---------------------------------------------------------------------------

TRAIL_DIRS=(
  "trail/inbox"
  "trail/daily"
  "trail/weekly"
  "trail/decisions"
  "trail/dod"
  "trail/incidents"
  "trail/agent-candidates"
)

# _legacy_scaffold_paths()
# Returns the flat repo-relative path list that v1.x cmd_new/cmd_merge use to
# enumerate rein-managed files. Internal helper — NOT a top-level module
# variable. Kept private so the legacy paths cannot accidentally drift from
# plugin.json's contract; the v2.0 install path uses rein-build-scaffold.py
# directly (see install_scaffold_mode).
_legacy_scaffold_paths() {
  printf '%s\n' \
    ".claude/CLAUDE.md" \
    ".claude/settings.json" \
    ".claude/settings.local.json.example" \
    ".claude/orchestrator.md" \
    ".claude/hooks" \
    ".claude/rules" \
    ".claude/workflows" \
    ".claude/agents" \
    ".claude/registry" \
    ".claude/skills" \
    ".claude/security" \
    ".claude/router" \
    ".github/workflows/daily-trail-audit.yml" \
    ".github/workflows/issue-triage.yml" \
    ".github/workflows/repo-audit.yml" \
    ".github/workflows/weekly-agent-evolution.yml" \
    "AGENTS.md" \
    "REIN_SETUP_GUIDE.md" \
    "scripts/rein-manifest-v2.py" \
    "scripts/rein-path-match.py" \
    "scripts/rein-job-wrapper.sh"
}

# ---------------------------------------------------------------------------
# list_copy_files(template_dir)
# Outputs NUL-terminated relative file paths for all rein-managed scaffold
# targets (v1.x compatibility surface). For files, prints directly. For
# directories, finds all files recursively excluding .DS_Store.
# Output is NUL-terminated to safely handle filenames with spaces/newlines.
# ---------------------------------------------------------------------------
list_copy_files() {
  local template_dir="$1"

  while IFS= read -r target; do
    local full_path="$template_dir/$target"

    if [[ ! -e "$full_path" ]]; then
      # Target doesn't exist in template; skip silently
      continue
    fi

    if [[ -f "$full_path" ]]; then
      printf '%s\0' "$target"
    elif [[ -d "$full_path" ]]; then
      # Use -print0 for safe handling of unusual filenames
      find "$full_path" -type f ! -name ".DS_Store" -print0 | \
        while IFS= read -r -d '' abs_file; do
          printf '%s\0' "${abs_file#"$template_dir/"}"
        done
    fi
  done < <(_legacy_scaffold_paths)
}

# ---------------------------------------------------------------------------
# Manifest tracking (.claude/.rein-manifest.json)
#
# The manifest records every file rein installs into a project so that
# subsequent updates can:
#   1) detect user modifications (compare on-disk sha256 vs manifest sha256)
#   2) detect files that were removed from the template since last update
#      (set difference between current template files and manifest files)
#
# The manifest enables the `--prune` flag to safely delete deprecated files
# that the user has not modified, while preserving anything they touched.
# ---------------------------------------------------------------------------
manifest_path() {
  echo "$1/.claude/.rein-manifest.json"
}

# manifest_sha256(file): portable sha256 of a file. Empty string on failure.
manifest_sha256() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
  else
    echo ""
  fi
}

# manifest_generate(project_dir, template_dir)
# Build/refresh the manifest from the project_dir, using template_dir to
# enumerate which files belong to rein. Preserves `installed_at` and
# per-file `added_in` from any pre-existing manifest.
manifest_generate() {
  local project_dir="$1"
  local template_dir="$2"
  local mf
  mf=$(manifest_path "$project_dir")

  local list_file
  list_file=$(mktemp)
  # Track files copied via list_copy_files (rein-managed code/config).
  #
  # SCOPE NOTE: trail/ files are intentionally NOT tracked in the manifest:
  #   - trail/index.md is a starter file that the project owner immediately
  #     customizes; treating it as rein-tracked would mean prune sees it as
  #     "removed from template" (because list_copy_files excludes trail/) and
  #     would attempt to delete it.
  #   - trail/<sub>/.gitkeep files are harmless directory markers; tracking
  #     them would create the same false-positive prune target.
  # The manifest contract is therefore: "tracks every rein-managed file
  # under list_copy_files()". trail/ is user state, not rein-managed.
  while IFS= read -r -d '' rel_path; do
    local dest="$project_dir/$rel_path"
    if [[ -f "$dest" ]]; then
      printf '%s\t%s\n' "$rel_path" "$(manifest_sha256 "$dest")" >> "$list_file"
    fi
  done < <(list_copy_files "$template_dir")

  python3 - "$mf" "$VERSION" "$list_file" <<'PYEOF'
import json, os, sys, datetime

mf, version, list_file = sys.argv[1], sys.argv[2], sys.argv[3]

prev = {}
prev_files = {}
prev_installed_at = None
if os.path.exists(mf):
    try:
        with open(mf) as f:
            prev = json.load(f)
        prev_files = prev.get("files", {}) or {}
        prev_installed_at = prev.get("installed_at")
    except Exception:
        pass

files = {}
with open(list_file) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        rel, sha = parts
        added_in = prev_files.get(rel, {}).get("added_in", version)
        files[rel] = {"sha256": sha, "added_in": added_in}

now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
manifest = {
    "schema_version": "1",
    "rein_version": version,
    "installed_at": prev_installed_at or now,
    "updated_at": now,
    "files": files,
}

os.makedirs(os.path.dirname(mf), exist_ok=True)
with open(mf, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  rm -f "$list_file"
}

# manifest_validate(project_dir)
# Returns 0 if manifest exists and is parseable with schema_version "1" or "2",
# 1 if missing, 2 if corrupt or unsupported schema. Accepts both schema versions
# because v1.1.2+ commits a v2 manifest via stage_manifest_commit; legacy v1
# manifests are still valid for pre-first-update projects.
manifest_validate() {
  local mf
  mf=$(manifest_path "$1")
  [[ -f "$mf" ]] || return 1
  python3 - "$mf" <<'PYEOF' >/dev/null 2>&1 || return 2
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
schema = d.get("schema_version")
assert schema in ("1", "2"), f"unsupported schema: {schema}"
assert isinstance(d.get("files", {}), dict), "files must be object"
PYEOF
  return 0
}

# ---------------------------------------------------------------------------
# Prune (deprecated-file removal)
#
# Logic: compare manifest's tracked files vs the current template's file list.
# Files present in manifest but absent in template are "removal candidates".
# For each candidate:
#   - if dest does not exist: skip (already removed)
#   - if dest sha256 == manifest sha256: SAFE delete
#   - if dest sha256 != manifest sha256: USER MODIFIED — preserve + warn
#
# In dry-run mode (default) only the classification is printed.
# In confirm mode, safe candidates are backed up to .rein-prune-backup-<ts>/
# and then removed; the manifest is regenerated to reflect the new state.
#
# Files matched by .gitignore are always preserved (extra safety net).
# ---------------------------------------------------------------------------
prune_impl() {
  local project_dir="$1"
  local template_dir="$2"
  local confirm="$3"           # "true" | "false"
  local manifest_override="${4:-}"  # optional: path to a snapshot manifest to
                                    # use instead of project_dir's current one
                                    # (cmd_merge passes the pre-merge snapshot
                                    # so prune sees the OLD file set).

  local mf
  if [[ -n "$manifest_override" && -f "$manifest_override" ]]; then
    mf="$manifest_override"
  else
    mf=$(manifest_path "$project_dir")
    # Validate only when using the live manifest. A snapshot from cmd_merge
    # has already been validated implicitly (it was a copy of a prior file).
    local mv_rc=0
    manifest_validate "$project_dir" || mv_rc=$?
    if [[ "$mv_rc" -ne 0 ]]; then
      case "$mv_rc" in
        1) warn "No manifest found — prune disabled until next 'rein update'." ;;
        2) error "Manifest is corrupt or has unsupported schema; refusing to prune." ;;
        *) error "Manifest validation failed with code $mv_rc" ;;
      esac
      return 0
    fi
  fi

  # Build current template file list
  local cur_list
  cur_list=$(mktemp)
  while IFS= read -r -d '' rel_path; do
    printf '%s\n' "$rel_path" >> "$cur_list"
  done < <(list_copy_files "$template_dir")

  # Have python compute the candidate set, classify each, and emit actions
  local plan
  plan=$(mktemp)
  python3 - "$mf" "$cur_list" "$project_dir" "$plan" <<'PYEOF'
import json, os, sys, hashlib, subprocess

mf, cur_list_path, project_dir, plan_path = sys.argv[1:5]

# Resolve project_dir to an absolute, canonical form so containment checks
# are reliable.
project_dir_abs = os.path.realpath(project_dir)

with open(mf) as f:
    manifest = json.load(f)

prev = set((manifest.get("files") or {}).keys())
cur = set()
with open(cur_list_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if line:
            cur.add(line)

candidates = sorted(prev - cur)

def sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

def is_gitignored(path):
    try:
        rc = subprocess.call(
            ["git", "check-ignore", "-q", path],
            cwd=project_dir_abs,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return rc == 0
    except Exception:
        return False

def is_safe_relpath(rel):
    """Reject paths that escape the project. Manifest entries must be:
    - Non-empty
    - Not absolute
    - No '..' segments after normalization
    - Resolved path must be strictly under project_dir
    """
    if not rel or os.path.isabs(rel):
        return False
    norm = os.path.normpath(rel)
    if norm.startswith("..") or os.path.isabs(norm):
        return False
    parts = norm.split(os.sep)
    if any(p == ".." for p in parts):
        return False
    full = os.path.realpath(os.path.join(project_dir_abs, norm))
    # Must live under project_dir_abs (and not BE project_dir_abs itself).
    try:
        common = os.path.commonpath([project_dir_abs, full])
    except ValueError:
        return False
    return common == project_dir_abs and full != project_dir_abs

with open(plan_path, "w") as out:
    for rel in candidates:
        if not is_safe_relpath(rel):
            out.write(f"UNSAFE\t{rel}\trefusing to touch path outside project\n")
            continue
        full = os.path.join(project_dir_abs, rel)
        recorded = (manifest["files"].get(rel) or {}).get("sha256", "")
        if not os.path.exists(full):
            out.write(f"GONE\t{rel}\n")
            continue
        # Reject symlinks at the leaf (defense in depth — a symlink could
        # point outside even if the rel path looks fine)
        if os.path.islink(full):
            out.write(f"UNSAFE\t{rel}\tsymlink not allowed\n")
            continue
        if is_gitignored(full):
            out.write(f"IGNORED\t{rel}\n")
            continue
        actual = sha256(full)
        if actual is None:
            out.write(f"ERROR\t{rel}\tcannot read\n")
            continue
        if actual == recorded:
            out.write(f"SAFE\t{rel}\t{recorded}\n")
        else:
            out.write(f"MODIFIED\t{rel}\n")
PYEOF

  rm -f "$cur_list"

  # Read plan, emit user-facing report, optionally execute
  local safe_count=0 modified_count=0 gone_count=0 ignored_count=0
  local backup_dir=""
  # backup_dir is created via mktemp below (after the report header) so that
  # the directory name is unpredictable. See M2 fix.

  # M2 fix: use mktemp -d so the backup dir name is unpredictable, blocking
  # symlink-planting attacks against a guessed timestamp.
  if [[ "$confirm" == "true" ]]; then
    backup_dir=$(mktemp -d "$project_dir/.rein-prune-backup-XXXXXXXX") || {
      error "Failed to create backup directory under $project_dir"
      return 1
    }
  fi

  echo "" >&2
  echo -e "${BOLD}Prune analysis${NC}" >&2
  echo "  manifest: $mf" >&2
  echo "  mode:     $([[ "$confirm" == "true" ]] && echo 'CONFIRM (will delete)' || echo 'DRY-RUN (no changes)')" >&2
  echo "" >&2

  local unsafe_count=0
  while IFS=$'\t' read -r kind rel rest; do
    case "$kind" in
      SAFE)
        safe_count=$((safe_count + 1))
        if [[ "$confirm" == "true" ]]; then
          # TOCTOU re-check: confirm sha256 is STILL the recorded value
          # immediately before deleting. The python plan recorded the
          # expected sha as `rest`. If the file changed since classification,
          # downgrade to MODIFIED and skip.
          local now_sha
          now_sha=$(manifest_sha256 "$project_dir/$rel")
          if [[ "$now_sha" != "$rest" ]]; then
            modified_count=$((modified_count + 1))
            safe_count=$((safe_count - 1))
            echo -e "  ${GREEN}PRESERVED${NC}: $rel  (modified after planning — TOCTOU guard)" >&2
            continue
          fi
          # M1 fix: explicitly reject symlinks at the leaf right before cp/rm,
          # in case a concurrent attacker swapped the file for a symlink
          # between the python plan and this point. Without this, `cp` would
          # follow the symlink and read the target's content into the backup
          # (an information-disclosure window, bounded by sha collision).
          if [[ -L "$project_dir/$rel" ]]; then
            unsafe_count=$((unsafe_count + 1))
            safe_count=$((safe_count - 1))
            echo -e "  ${RED}REFUSED${NC}: $rel  (symlink appeared after planning — refusing)" >&2
            continue
          fi
          mkdir -p "$backup_dir/$(dirname "$rel")"
          # cp -P (no-dereference) is defensive even though we just checked
          # the leaf is not a symlink. It also disables hardlink resolution
          # via -P on platforms where that matters.
          cp -P "$project_dir/$rel" "$backup_dir/$rel"
          rm -f "$project_dir/$rel"
          echo -e "  ${RED}DELETED${NC}: $rel  (backup: ${backup_dir##*/})" >&2
        else
          echo -e "  ${YELLOW}WOULD-DELETE${NC}: $rel" >&2
        fi
        ;;
      MODIFIED)
        modified_count=$((modified_count + 1))
        echo -e "  ${GREEN}PRESERVED${NC}: $rel  (user-modified)" >&2
        ;;
      GONE)
        gone_count=$((gone_count + 1))
        ;;
      IGNORED)
        ignored_count=$((ignored_count + 1))
        echo -e "  ${GREEN}PRESERVED${NC}: $rel  (gitignored)" >&2
        ;;
      UNSAFE)
        unsafe_count=$((unsafe_count + 1))
        echo -e "  ${RED}REFUSED${NC}: $rel  ($rest)" >&2
        ;;
      ERROR)
        echo -e "  ${RED}ERROR${NC}: $rel  ($rest)" >&2
        ;;
    esac
  done < "$plan"

  rm -f "$plan"

  echo "" >&2
  echo -e "${BOLD}Summary${NC}: deleted=$safe_count, preserved-modified=$modified_count, preserved-ignored=$ignored_count, already-gone=$gone_count, refused-unsafe=$unsafe_count" >&2

  if [[ "$confirm" == "true" && "$safe_count" -gt 0 ]]; then
    info "Backup written to: $backup_dir"
    # Round 2 codex-review fix (Group 7 2026-04-24): previously called
    # manifest_generate here, which hardcodes schema_version="1" and would
    # clobber the v2 manifest that cmd_merge just committed via
    # stage_manifest_commit. Since cmd_merge stages only files present in
    # the current template (pruned files are already absent from the
    # staged manifest), no further regeneration is needed: the live v2
    # manifest already reflects the post-prune state correctly.
  elif [[ "$confirm" != "true" && "$safe_count" -gt 0 ]]; then
    echo "" >&2
    info "Run 'rein update --prune --confirm' to actually delete the $safe_count file(s) above."
  fi
}

# ---------------------------------------------------------------------------
# copy_file(template_dir, dest_dir, rel_path)
# ---------------------------------------------------------------------------
copy_file() {
  local template_dir="$1"
  local dest_dir="$2"
  local rel_path="$3"

  local src="$template_dir/$rel_path"
  local dst="$dest_dir/$rel_path"

  mkdir -p "$(dirname "$dst")"

  # Refuse to overwrite a symlink at dst (need-to-confirm.md 그룹 4B, 2026-04-25).
  # Mirrors _install_cli_helpers (above) + bc97752 family — prevents symlink
  # redirection / TOCTOU when a malicious symlink at dst would otherwise
  # cause `cp` to follow the link and overwrite an attacker-chosen path.
  if [[ -L "$dst" ]]; then
    warn "Refusing to overwrite symlink at $dst (skipping $rel_path)"
    return 0
  fi

  # Capture pre-existing dst mode for additive OR (never-revoke).
  local prev_dst_mode=""
  if [[ -f "$dst" ]]; then
    prev_dst_mode=$(stat -f '%Lp' "$dst" 2>/dev/null || stat -c '%a' "$dst" 2>/dev/null || echo "")
  fi

  # Atomic write — 묶음 D (d) advisory: cp → mktemp tmp → mode 적용 → mv.
  # `_install_cli_helpers` (rein.sh:867) 패턴 재사용. `[[ -L $dst ]]` check 와
  # 최종 dst 사이 race window 단축. mktemp 실패 시 fallback to direct cp
  # (best-effort) — Round 2 fix: fallback 에서도 동일한 mode parity 로직 적용
  # 해 atomicity 만 포기하고 grant-up / never-revoke contract 는 보존.
  local tmp target
  if tmp=$(mktemp "${dst}.XXXXXX" 2>/dev/null); then
    cp "$src" "$tmp"
    target="$tmp"
  else
    cp "$src" "$dst"
    target="$dst"
  fi

  # Additive mode parity (need-to-confirm.md 그룹 4A, 2026-04-25 + 묶음 D
  # advisory a/b/c):
  #   - 권한 확대 (grant-up) 정책 — template 일관성 우선. 사용자 chmod 축소
  #     (예: 0700) 도 src level 의 set bit 들로 grant up 됨 (의도된 trade-off).
  #   - portable stat: macOS BSD `stat -f '%Lp'` → Linux GNU `stat -c '%a'` fallback.
  #   - octal regex 검증 (^[0-7]+$) — 비정상 stat 출력 시 fallback path 강등.
  #   - chmod -- 옵션 파싱 종료 — leading-dash dst 방어.
  #   - target mode = src mode OR prev dst mode (octal). src 의 set bit 모두
  #     grant + dst 의 추가 bit 보존 (never-revoke 정책, 회귀 test case 4 호환).
  #   - stat 부재 환경 fallback: 기존 `chmod +x` grant only.
  local src_mode
  src_mode=$(stat -f '%Lp' "$src" 2>/dev/null || stat -c '%a' "$src" 2>/dev/null || echo "")
  if [[ "$src_mode" =~ ^[0-7]+$ ]]; then
    local combined
    if [[ "$prev_dst_mode" =~ ^[0-7]+$ ]]; then
      combined=$(printf '%o' "$((0$src_mode | 0$prev_dst_mode))")
    else
      combined="$src_mode"
    fi
    chmod -- "$combined" "$target"
  elif [[ -x "$src" && ! -x "$target" ]]; then
    chmod -- +x "$target"
  fi

  # Atomic rename — race window 단축 (advisory d). mktemp fallback 일 때는
  # target == dst 라 mv skip.
  if [[ "$target" != "$dst" ]]; then
    mv -- "$tmp" "$dst"
  fi
}

# ---------------------------------------------------------------------------
# scaffold_trail(dest_dir, template_dir)
# Creates trail directory structure with .gitkeep files.
# Copies trail/index.md from template if it exists (in merge mode: only if the
# file does not already exist, to avoid silently destroying local state).
# ---------------------------------------------------------------------------
scaffold_trail() {
  local dest_dir="$1"
  local template_dir="$2"
  local is_merge="${3:-false}"   # pass "true" for merge/update

  for trail_dir in "${TRAIL_DIRS[@]}"; do
    mkdir -p "$dest_dir/$trail_dir"
    touch "$dest_dir/$trail_dir/.gitkeep"
  done

  if [[ -f "$template_dir/trail/index.md" ]]; then
    mkdir -p "$dest_dir/trail"
    local dest_index="$dest_dir/trail/index.md"
    if [[ "$is_merge" == "true" && -f "$dest_index" ]]; then
      # In merge mode, do not silently overwrite existing trail/index.md.
      # The file is managed by the project owner; leave it alone.
      :
    else
      cp "$template_dir/trail/index.md" "$dest_index"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Interactive conflict resolution + CLI flags
# ---------------------------------------------------------------------------
ALL_OVERWRITE=false   # set by [a]ll-overwrite prompt OR --all/--yes flag
PRUNE_MODE=false      # set by --prune flag
PRUNE_CONFIRM=false   # set by --confirm flag (only meaningful with --prune)

# _has_tty(): returns 0 if /dev/tty is available and readable
_has_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

# prompt_conflict(rel_path, template_dir, dest_dir)
# Prints one of: overwrite | skip | quit  to stdout.
# If no tty is available, falls back to "skip" with a warning on stderr.
prompt_conflict() {
  local rel_path="$1"
  local template_dir="$2"
  local dest_dir="$3"

  if [[ "$ALL_OVERWRITE" == "true" ]]; then
    echo "overwrite"
    return
  fi

  # Non-interactive fallback
  if ! _has_tty; then
    warn "no tty available; skipping '$rel_path'"
    echo "skip"
    return
  fi

  local existing="$dest_dir/$rel_path"
  local incoming="$template_dir/$rel_path"

  while true; do
    printf "File exists: %s\n  [o]verwrite  [s]kip  [d]iff  [a]ll-overwrite  [q]uit  → " \
      "$rel_path" >/dev/tty
    local answer
    read -r answer </dev/tty

    case "$answer" in
      o|O)
        echo "overwrite"
        return
        ;;
      s|S)
        echo "skip"
        return
        ;;
      d|D)
        # --color is GNU-specific; fall back gracefully on macOS/BSD diff
        if diff --help 2>&1 | grep -q -- '--color'; then
          diff --color "$existing" "$incoming" >/dev/tty 2>&1 || true
        else
          diff "$existing" "$incoming" >/dev/tty 2>&1 || true
        fi
        # After showing diff, ask overwrite/skip
        while true; do
          printf "  [o]verwrite  [s]kip  → " >/dev/tty
          local answer2
          read -r answer2 </dev/tty
          case "$answer2" in
            o|O)
              echo "overwrite"
              return
              ;;
            s|S)
              echo "skip"
              return
              ;;
            *)
              printf "Please enter 'o' or 's'.\n" >/dev/tty
              ;;
          esac
        done
        ;;
      a|A)
        ALL_OVERWRITE=true
        echo "overwrite"
        return
        ;;
      q|Q)
        echo "quit"
        return
        ;;
      *)
        printf "Please enter o, s, d, a, or q.\n" >/dev/tty
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# substitute_vars(dest_dir, project_name)
# Replaces {{PROJECT_NAME}} in all .md files under dest_dir.
# Handles both macOS/BSD sed (-i '') and GNU/Linux sed (-i).
# Escapes /, &, and \ in project_name to prevent sed misinterpretation.
# ---------------------------------------------------------------------------
substitute_vars() {
  local dest_dir="$1"
  local project_name="$2"

  # Escape characters that have special meaning in sed replacement strings:
  # & (whole-match), / (delimiter), \ (escape)
  local escaped_name
  escaped_name="${project_name//\\/\\\\}"   # backslash → \\
  escaped_name="${escaped_name//&/\\&}"     # & → \&
  escaped_name="${escaped_name//\//\\/}"    # / → \/

  # Detect sed flavor
  if sed --version 2>/dev/null | grep -q GNU; then
    # GNU/Linux sed
    find "$dest_dir" -type f -name "*.md" -exec \
      sed -i "s/{{PROJECT_NAME}}/$escaped_name/g" {} +
  else
    # macOS/BSD sed requires an explicit extension argument (empty string = no backup)
    find "$dest_dir" -type f -name "*.md" -exec \
      sed -i '' "s/{{PROJECT_NAME}}/$escaped_name/g" {} +
  fi
}

# ---------------------------------------------------------------------------
# usage()
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  rein new <project-name>           Create a new project from template
  rein init [flags]                 Install rein into current git repo (v2.0+)
  rein merge [flags]                Merge template into current project
  rein update [flags]               Update current project from template
  rein remove [flags]               Remove rein-tracked files (see 'rein remove --help')
  rein migrate [flags]              v1.x scaffold → v2.0 plugin migration (Phase 4)
                                    Flags: --dry-run, --resume
  rein --version                    Show version
  rein --help                       Show this help

Flags (init):
  --mode=<plugin|scaffold>          plugin (default v2.0+) or full scaffold
  --scope=<user|project|local|managed>
                                    Settings.json scope for plugin entry
                                    (default: project)

Flags (merge / update):
  --all, --yes                      Auto-overwrite every conflict (CI friendly)
  --prune                           Dry-run: show files removed from template
  --prune --confirm                 Actually delete unmodified deprecated files
                                    (creates .rein-prune-backup-<ts>/ first)

Environment:
  REIN_TEMPLATE_REPO                Override template repository URL
  CLAUDE_TEMPLATE_REPO              (deprecated) Alias for REIN_TEMPLATE_REPO

Manifest:
  rein tracks installed files in .claude/.rein-manifest.json so that updates
  can detect user modifications and prune deprecated files safely. The
  manifest is created/refreshed on every 'rein new', 'rein merge', and
  'rein update'. User-modified files (sha256 mismatch) are never pruned.
EOF
}

# ---------------------------------------------------------------------------
# Phase 5: rein init / rein update — mode + scope flags
#
# Plugin-First Restructure (docs/plans/2026-04-27-plugin-first-restructure-plan.md
# Phase 5 lines 1168-1370). MODE/SCOPE globals are set by parse_init_flags()
# before cmd_init() dispatches to install_plugin_mode() / install_scaffold_mode().
# ---------------------------------------------------------------------------
MODE=""               # set by --mode=<plugin|scaffold>; defaults to "plugin"
SCOPE=""              # set by --scope=<user|project|local|managed>; defaults to "project"

# REIN_HOME = parent dir of scripts/ — used by install_*_mode to locate
# rein-install-plugin-to-settings.py / rein-build-scaffold.py / rein-manifest-v2.py.
# Resolved from the *currently executing* rein.sh (via BASH_SOURCE) so the source
# of truth is always the rein-dev checkout that owns this CLI, not the user's
# project. Tests source rein.sh in --source-only mode and rely on this.
_phase5_rein_home() {
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # scripts/ lives one level under REIN_HOME
  echo "$(dirname "$script_path")"
}

# parse_init_flags(args...)
# Sets MODE / SCOPE globals from --mode=<x> / --mode <x> / --scope=<x> / --scope <x>.
# Unknown flags trigger error. Validates values against allow-lists.
parse_init_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode=*) MODE="${1#--mode=}"; shift ;;
      --mode)
        if [[ $# -lt 2 ]]; then
          error "--mode requires a value (plugin|scaffold)"; exit 1
        fi
        MODE="$2"; shift 2 ;;
      --scope=*) SCOPE="${1#--scope=}"; shift ;;
      --scope)
        if [[ $# -lt 2 ]]; then
          error "--scope requires a value (user|project|local|managed)"; exit 1
        fi
        SCOPE="$2"; shift 2 ;;
      --no-self-update)
        export REIN_NO_SELF_UPDATE=1; shift ;;
      --)
        shift; break ;;
      -*)
        error "unknown flag '$1' for rein init"; exit 1 ;;
      *)
        error "unexpected argument '$1' for rein init"; exit 1 ;;
    esac
  done

  # Defaults — v2.0+ ships plugin-mode + project-scope by default.
  MODE="${MODE:-plugin}"
  SCOPE="${SCOPE:-project}"

  case "$MODE" in
    plugin|scaffold) ;;
    *) error "unknown --mode '$MODE' (want: plugin|scaffold)"; exit 1 ;;
  esac
  case "$SCOPE" in
    user|project|local|managed) ;;
    *) error "unknown --scope '$SCOPE' (want: user|project|local|managed)"; exit 1 ;;
  esac
}

# write_rein_project_json(target_root, mode)
# Writes <target_root>/.rein/project.json with {mode, scope, version} by
# delegating to scripts/rein-write-project-json.py — the canonical helper
# that fsyncs the parent dir after os.replace for durable, crash-safe
# write-last semantics (Phase 4 Task 4.10). No re-implementation here.
write_rein_project_json() {
  local target_root="$1"
  local mode="$2"
  local rein_home write_py
  rein_home="$(_phase5_rein_home)"
  write_py="$rein_home/scripts/rein-write-project-json.py"
  if [[ ! -f "$write_py" ]]; then
    error "rein-write-project-json.py missing at $write_py"; exit 1
  fi
  ( cd "$target_root" && python3 "$write_py" \
      --mode "$mode" \
      --scope "$SCOPE" \
      --version "$VERSION" >/dev/null )
}

# write_rein_policy_templates(target_root)
# Creates <target_root>/.rein/policy/{hooks,rules}.yaml empty templates.
# Idempotent: existing files are not overwritten.
write_rein_policy_templates() {
  local target_root="$1"
  local policy_dir="$target_root/.rein/policy"
  mkdir -p "$policy_dir"
  if [[ ! -f "$policy_dir/hooks.yaml" ]]; then
    cat > "$policy_dir/hooks.yaml" <<'YAML'
# .rein/policy/hooks.yaml — toggle plugin-shipped hooks (Phase 2 Task 2.7).
# Add `<hook-name>: false` to disable a hook the plugin would otherwise enable.
# Empty file = use plugin defaults (all hooks enabled).
YAML
  fi
  if [[ ! -f "$policy_dir/rules.yaml" ]]; then
    cat > "$policy_dir/rules.yaml" <<'YAML'
# .rein/policy/rules.yaml — per-rule replace override (Phase 2 Task 2.8).
# Add `<rule-name>: |` followed by the replacement rule body to override the
# plugin-shipped text. Empty file = use plugin defaults.
YAML
  fi
}

# install_plugin_mode(target_root)
# Plugin-mode rein init: register rein-core in the chosen scope's settings.json,
# write .rein/project.json + .rein/policy/* templates, and ensure trail/ exists.
# Does NOT write .claude/.rein-manifest.json (plugin manager owns those files).
# Tasks 5.1, 5.3, 5.4, 5.5, 5.6.
install_plugin_mode() {
  local target_root="$1"
  local rein_home
  rein_home="$(_phase5_rein_home)"
  local install_py="$rein_home/scripts/rein-install-plugin-to-settings.py"

  if [[ ! -f "$install_py" ]]; then
    error "rein-install-plugin-to-settings.py missing at $install_py"
    exit 1
  fi

  # CLAUDE.md preservation guard — Task 5.6. plugin mode must never touch the
  # user's CLAUDE.md (root or .claude/). Capture sha256 before/after, AND the
  # presence flag so an absent-to-created regression is caught (codex
  # Round 1 finding — plugin mode must "not touch" means file existence is
  # part of the invariant, not just byte-equality of pre-existing content).
  local sha_root_before="" sha_nested_before=""
  local exists_root_before=0 exists_nested_before=0
  if [[ -f "$target_root/CLAUDE.md" ]]; then
    sha_root_before=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_root/CLAUDE.md")
    exists_root_before=1
  fi
  if [[ -f "$target_root/.claude/CLAUDE.md" ]]; then
    sha_nested_before=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_root/.claude/CLAUDE.md")
    exists_nested_before=1
  fi

  # Run the plugin install helper from inside target_root so SCOPE-relative
  # paths (.claude/settings.json, .claude/settings.local.json,
  # .claude/managed-settings.json) anchor on the user repo. user-scope writes
  # to ~/.claude/settings.json regardless of cwd.
  # rein-core@^2.0.0 — pinned to the major plugin version, NOT the rein.sh
  # CLI version (which still tracks pre-2.0 internal releases until Phase 9
  # bumps VERSION=2.0.0). Plan §5.1 step 1.
  ( cd "$target_root" && python3 "$install_py" \
      --scope "$SCOPE" \
      --plugin "rein-core=^2.0.0" >/dev/null )

  # Write .rein/project.json + policy templates + ensure trail/ scaffolded.
  write_rein_project_json "$target_root" "plugin"
  write_rein_policy_templates "$target_root"
  mkdir -p "$target_root/trail/inbox" \
           "$target_root/trail/dod" \
           "$target_root/trail/incidents" \
           "$target_root/trail/decisions"
  : > "$target_root/trail/inbox/.gitkeep"
  : > "$target_root/trail/dod/.gitkeep"
  : > "$target_root/trail/incidents/.gitkeep"
  : > "$target_root/trail/decisions/.gitkeep"
  if [[ ! -f "$target_root/trail/index.md" ]]; then
    printf '# trail/index.md\n\n> rein 프로젝트 상태 — 매 세션 종료 시 갱신.\n' \
      > "$target_root/trail/index.md"
  fi

  # --scope=local seeds .claude/settings.local.json into .gitignore (Task 5.4).
  if [[ "$SCOPE" == "local" ]]; then
    local gi="$target_root/.gitignore"
    touch "$gi"
    if ! grep -qxF '.claude/settings.local.json' "$gi"; then
      printf '\n# rein local-scope settings (per-developer overrides)\n.claude/settings.local.json\n' >> "$gi"
    fi
  fi

  # CLAUDE.md preservation guard — verify both byte equality (when pre-existing)
  # AND presence parity (absent-to-created regression).
  local exists_root_after=0 exists_nested_after=0
  [[ -f "$target_root/CLAUDE.md" ]] && exists_root_after=1
  [[ -f "$target_root/.claude/CLAUDE.md" ]] && exists_nested_after=1

  if [[ "$exists_root_before" != "$exists_root_after" ]]; then
    error "rein init plugin-mode unexpectedly created/removed $target_root/CLAUDE.md"
    exit 1
  fi
  if [[ "$exists_nested_before" != "$exists_nested_after" ]]; then
    error "rein init plugin-mode unexpectedly created/removed $target_root/.claude/CLAUDE.md"
    exit 1
  fi

  if [[ -n "$sha_root_before" ]]; then
    local sha_root_after
    sha_root_after=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_root/CLAUDE.md")
    if [[ "$sha_root_before" != "$sha_root_after" ]]; then
      error "rein init plugin-mode unexpectedly modified $target_root/CLAUDE.md"
      exit 1
    fi
  fi
  if [[ -n "$sha_nested_before" ]]; then
    local sha_nested_after
    sha_nested_after=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_root/.claude/CLAUDE.md")
    if [[ "$sha_nested_before" != "$sha_nested_after" ]]; then
      error "rein init plugin-mode unexpectedly modified $target_root/.claude/CLAUDE.md"
      exit 1
    fi
  fi
}

# _version_ge "X.Y.Z" "A.B.C" → exit 0 (true) iff X.Y.Z >= A.B.C.
#
# Behavior contract (Phase 8 Task 8.1, codex Round 1 fix):
#   - Both arguments must match `^[0-9]+\.[0-9]+\.[0-9]+$` exactly. Anything
#     else (empty, non-numeric, prerelease tags like "2.5.0-rc1", custom build
#     suffixes) is rejected → exit 1 (treated as "not >="). This keeps the
#     scaffold-deprecation gate quiet for non-release builds and prereleases.
#   - The actual comparison is integer-tuple comparison, NOT `sort -V`. We
#     observed on macOS that `printf '%s\n%s\n' "foo" "2.5.0" | sort -V -C`
#     returns 0 (i.e., treats "foo" as <= "2.5.0"), which would falsely emit
#     the warning. We also observed `sort -V` treats "2.5.0-rc1" >= "2.5.0",
#     which is the wrong direction for prereleases. Pure-bash arithmetic
#     comparison is portable across macOS BSD `sort`, GNU coreutils, MSYS2,
#     and WSL2 with no surprises.
_version_ge() {
  local lhs="${1:-}" rhs="${2:-}"
  local re='^[0-9]+\.[0-9]+\.[0-9]+$'
  [[ "$lhs" =~ $re ]] || return 1
  [[ "$rhs" =~ $re ]] || return 1
  local IFS=.
  # shellcheck disable=SC2206 # split on '.' is intentional
  local lp=($lhs) rp=($rhs)
  if   (( lp[0] != rp[0] )); then (( lp[0] > rp[0] ))
  elif (( lp[1] != rp[1] )); then (( lp[1] > rp[1] ))
  else                            (( lp[2] >= rp[2] ))
  fi
}

# _scaffold_deprec_emit_if_ge_2_5_0
# Emits the scaffold-mode deprecation warning to stderr when the running
# rein.sh VERSION >= 2.5.0. Phase 8 Task 8.1: warning is emitted, install
# proceeds (non-blocking). Removal/relegation is deferred to v3.0+ planning
# (spec §4.2). The warning text is referenced by
# tests/scripts/test-scaffold-deprecation-warning.sh.
_scaffold_deprec_emit_if_ge_2_5_0() {
  if _version_ge "$VERSION" "2.5.0"; then
    cat >&2 <<'EOF'
WARNING: --mode=scaffold is deprecated since v2.5.0.
Plugin mode is the default and recommended path.
See README and CHANGELOG for migration guide.
--mode=scaffold will be removed or relegated to fallback-only in v3.0.
EOF
  fi
}

# install_scaffold_mode(target_root)
# Scaffold-mode rein init: invoke rein-build-scaffold.py for the 3-source export
# (plugin first-class + scaffoldOverlay + scaffoldExtras + scaffoldHelperScripts),
# rsync into target_root, then generate .claude/.rein-manifest.json.
# Tasks 5.2, 5.5. Phase 8 Task 8.1 prepends a v2.5+ deprecation warning.
install_scaffold_mode() {
  _scaffold_deprec_emit_if_ge_2_5_0
  local target_root="$1"
  local rein_home
  rein_home="$(_phase5_rein_home)"
  local build_py="$rein_home/scripts/rein-build-scaffold.py"
  local manifest_py="$rein_home/scripts/rein-manifest-v2.py"

  if [[ ! -f "$build_py" ]]; then
    error "rein-build-scaffold.py missing at $build_py"; exit 1
  fi
  if [[ ! -f "$manifest_py" ]]; then
    error "rein-manifest-v2.py missing at $manifest_py"; exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    error "rsync is required for rein init --mode=scaffold"; exit 1
  fi

  local tmp_export
  tmp_export=$(mktemp -d -t rein-scaffold-XXXXXX)
  if [[ -z "$tmp_export" || ! -d "$tmp_export" ]]; then
    error "could not create tmp dir for scaffold export"; return 1
  fi

  # Run the rest under a single-shot cleanup pattern. We delegate the body
  # to a nested function so we can rm -rf $tmp_export exactly once on every
  # exit path (success, build failure, rsync failure, manifest failure,
  # project.json failure, or unexpected error). Codex Round 1 finding —
  # earlier per-call cleanup left tmp_export behind on post-rsync failures.
  _phase5_scaffold_body() {
    # 3-source export (plugin first-class + scaffoldOverlay + scaffoldExtras +
    # scaffoldHelperScripts). --include-domain reserved for Phase 7.
    if ! python3 "$build_py" \
         --source "$rein_home/plugins/rein-core" \
         --include-domain \
         --out "$tmp_export" >&2; then
      error "rein-build-scaffold.py failed"; return 1
    fi

    # rsync export tree into target_root. Trailing slash on source = "copy
    # contents", matching plan §5.2 step 3. -a preserves timestamps, exec
    # bits, and symlinks.
    if ! mkdir -p "$target_root"; then
      error "could not create target_root $target_root"; return 1
    fi
    if ! rsync -a "$tmp_export/" "$target_root/"; then
      error "rsync to $target_root failed"; return 1
    fi

    # Generate manifest from what was actually rsynced.
    local mf="$target_root/.claude/.rein-manifest.json"
    if ! mkdir -p "$(dirname "$mf")"; then
      error "could not create manifest dir"; return 1
    fi
    if ! python3 "$manifest_py" init "$mf" "$VERSION" >/dev/null; then
      error "rein-manifest-v2.py init failed"; return 1
    fi
    if ! python3 - "$manifest_py" "$mf" "$VERSION" "$tmp_export" <<'PYEOF'
import os, subprocess, sys, hashlib
manifest_py, mf, version, tmp_export = sys.argv[1:5]
for root, dirs, files in os.walk(tmp_export):
    rel_root = os.path.relpath(root, tmp_export)
    for fn in files:
        full = os.path.join(root, fn)
        rel = fn if rel_root == "." else os.path.join(rel_root, fn)
        with open(full, "rb") as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
        subprocess.check_call([
            "python3", manifest_py, "add", mf, rel, sha, version
        ])
PYEOF
    then
      error "manifest add loop failed"; return 1
    fi

    # .rein/project.json mode=scaffold + policy templates + trail/ (parity
    # with plugin-mode init so downstream hooks find their dirs). Each post-
    # rsync mutation is wrapped so any failure routes through the single
    # cleanup line at the bottom of install_scaffold_mode.
    if ! write_rein_project_json "$target_root" "scaffold"; then
      error "write_rein_project_json failed"; return 1
    fi
    if ! write_rein_policy_templates "$target_root"; then
      error "write_rein_policy_templates failed"; return 1
    fi
    if ! mkdir -p "$target_root/trail/inbox" \
                  "$target_root/trail/dod" \
                  "$target_root/trail/incidents" \
                  "$target_root/trail/decisions"; then
      error "mkdir trail/* failed"; return 1
    fi
    if [[ ! -f "$target_root/trail/index.md" ]]; then
      if ! printf '# trail/index.md\n\n> rein 프로젝트 상태 — 매 세션 종료 시 갱신.\n' \
           > "$target_root/trail/index.md"; then
        error "could not seed trail/index.md"; return 1
      fi
    fi
    return 0
  }

  local body_rc=0
  _phase5_scaffold_body || body_rc=$?
  rm -rf "$tmp_export"
  unset -f _phase5_scaffold_body
  return "$body_rc"
}

# cmd_init([flags])
# Phase 5 entry point: install rein in the current directory (cwd) using the
# requested mode + scope. cwd must be a git repo (so trail/ + .rein/ live in
# version control alongside user code).
cmd_init() {
  parse_init_flags "$@"

  if [[ ! -e ".git" ]]; then
    error "rein init: not a git repository (no .git in current directory)"
    exit 1
  fi

  local target_root="$PWD"

  case "$MODE" in
    plugin)   install_plugin_mode   "$target_root" ;;
    scaffold) install_scaffold_mode "$target_root" ;;
  esac

  echo ""
  info "rein init complete (mode=$MODE scope=$SCOPE version=$VERSION)."
  if [[ "$MODE" == "plugin" ]]; then
    info "  Plugin entry written to scope=$SCOPE settings.json."
    info "  Use 'claude /plugin install rein-core' or restart Claude Code to activate."
  else
    info "  Scaffold installed under $target_root/.claude/."
  fi
}

# update_plugin_mode(target_root)
# Plugin-mode rein update: rein does not own plugin file content. Print
# redirect message (Anthropic plugin manager handles updates) and exit 0.
# Task 5.7.
update_plugin_mode() {
  local target_root="$1"
  echo ""
  info "rein update: plugin mode detected (.rein/project.json mode=plugin)."
  info "  Claude Code's plugin manager handles plugin updates."
  info "  Run '/plugin update' inside Claude Code, or bump the version pin in"
  info "  $target_root/.claude/settings.json (or settings.local.json /"
  info "  ~/.claude/settings.json depending on your scope)."
  echo ""
}

# read_project_mode(target_root)
# Reads .rein/project.json's "mode" field. Prints "plugin" / "scaffold".
# Returns "scaffold" when project.json is absent (legacy v1.x install).
read_project_mode() {
  local target_root="$1"
  python3 - "$target_root" <<'PYEOF'
import json, os, sys
target_root = sys.argv[1]
p = os.path.join(target_root, ".rein", "project.json")
try:
    with open(p) as f:
        d = json.load(f)
    print(d.get("mode", "scaffold"))
except (FileNotFoundError, json.JSONDecodeError):
    print("scaffold")
PYEOF
}

# ---------------------------------------------------------------------------
# cmd_new(project_name)
# ---------------------------------------------------------------------------
cmd_new() {
  local project_name="$1"
  local dest_dir="$project_name"

  # 경로 검증: 상대/절대 경로 탈출 방지
  if [[ "$project_name" == *..* ]] || [[ "$project_name" == /* ]] || [[ "$project_name" == */* ]]; then
    error "project name must be a simple directory name (no '..', '/', or absolute paths)."
    exit 1
  fi

  if [[ -e "$dest_dir" ]]; then
    error "directory '$dest_dir' already exists."
    exit 1
  fi

  # clone_template sets global TEMPLATE_DIR; do NOT use command substitution
  clone_template

  mkdir -p "$dest_dir"

  local file_count=0
  while IFS= read -r -d '' rel_path; do
    copy_file "$TEMPLATE_DIR" "$dest_dir" "$rel_path"
    file_count=$((file_count + 1))
  done < <(list_copy_files "$TEMPLATE_DIR")

  scaffold_trail "$dest_dir" "$TEMPLATE_DIR" "false"
  substitute_vars "$dest_dir" "$project_name"

  # Generate initial manifest so future updates can prune safely
  manifest_generate "$dest_dir" "$TEMPLATE_DIR"

  # Plan C Task 1.3 — seed .gitignore with rein operational-hygiene entries
  # so base snapshots, prune/remove backups, and job logs never land in git.
  ( cd "$dest_dir" && ensure_gitignore_entries )

  echo ""
  info "Created project '$project_name' with $file_count files."
  echo ""
  info "Next steps:"
  info "  cd $project_name"
  info "  git init"
}

# ---------------------------------------------------------------------------
# cmd_merge()
# Also used for the 'update' alias.
# ---------------------------------------------------------------------------
cmd_merge() {
  # Accept both .git directory (normal repo) and .git file (worktree/submodule)
  if [[ ! -e ".git" ]]; then
    error "not a git repository (no .git found in current directory)."
    exit 1
  fi

  local project_name
  project_name="$(basename "$PWD")"

  # clone_template sets global TEMPLATE_DIR; do NOT use command substitution
  clone_template

  # --- Self-update check (v0.7.0+) ---
  # Detect whether the CLI itself needs updating before applying template
  # changes to the user's project. Runs APPLY (overwrite self + exec re-run)
  # or MIGRATE (print notice + stage new HOME install) based on current path.
  local _rein_action _rein_rc=0
  _rein_action=$(self_update_check "$TEMPLATE_DIR") || _rein_rc=$?

  if [[ $_rein_rc -eq 1 ]]; then
    case "$_rein_action" in
      APPLY)
        if prompt_self_update "$TEMPLATE_DIR"; then
          self_update_apply "$TEMPLATE_DIR"
          export REIN_SELF_UPDATED=1
          info "Restarting with new version..."
          exec "$(current_cli_path)" "${ORIGINAL_ARGV[@]}"
        else
          warn "Self-update skipped by user. CLI remains at v$VERSION."
        fi
        ;;
      MIGRATE)
        install_to_new_home "$TEMPLATE_DIR"
        migrate_old_install_notice
        ;;
    esac
  fi

  # ALL_OVERWRITE may have been set by --all/--yes flag in main(); preserve
  # that. Only reset to false if it has not been set explicitly.
  : "${ALL_OVERWRITE:=false}"

  # Plan C Task 1.3 — top up rein operational-hygiene entries in the user
  # project's .gitignore. Idempotent; safe to call on every update.
  ensure_gitignore_entries

  # v1.1.4 hotfix: self-heal missing CLI-adjacent helpers before any code
  # path tries to invoke them. Covers the chicken-and-egg case where a
  # pre-v1.1.3 CLI self-updated to v1.1.3 — the v1.1.2 self_update_apply
  # only replaced rein.sh, leaving helpers absent. Because self_update_check
  # now sees `tv == VERSION` on subsequent runs, self_update_apply (which
  # in v1.1.3+ DOES copy helpers) is never re-entered. Without this
  # self-heal the user is stranded until a future version bump triggers
  # self-update again. More generally: any same-version drift between
  # rein.sh and its sibling helpers is now auto-recoverable from the
  # freshly cloned template.
  _ensure_cli_helpers_present

  # ---- Prune snapshot (must be taken BEFORE any manifest mutation) --------
  # Round 2 codex-review finding (Group 7 2026-04-24): if we snapshot the
  # manifest AFTER stage_manifest_commit, the snapshot reflects the new
  # manifest (current template files only), so prune sees zero candidates
  # and template-removed files never get cleaned up. Take the snapshot
  # here — pre-v2-commit — so prune_impl compares OLD tracked files vs
  # NEW template and correctly identifies removals.
  local prune_snapshot=""
  if [[ "$PRUNE_MODE" == "true" ]]; then
    local live_mf_pre
    live_mf_pre=$(manifest_path "$PWD")
    if [[ -f "$live_mf_pre" ]]; then
      prune_snapshot=$(mktemp)
      cp "$live_mf_pre" "$prune_snapshot"
    fi
  fi

  # ---- v2 update dispatcher (Group 7A hotfix, 2026-04-24) -----------------
  # Wires cmd_merge to the v2 primitives that were shipped in v1.1.0 but
  # never dispatched from the CLI entry point (dead-code regression).
  #
  #   - is_first_update_v2 true  → apply_first_update_text per text file
  #                                 (preserve user + seed base), copy_file
  #                                 for non-text.
  #   - is_first_update_v2 false → stage_manifest_begin + do_update_v2
  #                                 (three_way_merge per text file), legacy
  #                                 2-way prompt for non-text, stage commit.
  #
  # Exit codes (propagated to the outer dispatcher):
  #   0 — all clean or user approved overwrites
  #   1 — ≥1 text-file 3-way conflict (user versions preserved, .rej written)
  #   2 — fatal error inside do_update_v2 (staging manifest left for inspection)
  # -----------------------------------------------------------------------
  local added=0 updated=0 overwritten=0 identical=0 conflicts=0
  local nontext_added=0 nontext_overwritten=0 nontext_identical=0
  local final_rc=0

  # Collect template rel paths up front so we can reason about the whole set.
  local rels=()
  while IFS= read -r -d '' rel_path; do
    rels+=("$rel_path")
  done < <(list_copy_files "$TEMPLATE_DIR")

  if is_first_update_v2; then
    info "First-time v2 update — seeding base snapshot + preserving user modifications"
    stage_manifest_begin
    local rel_path
    for rel_path in "${rels[@]}"; do
      if is_text_file "$rel_path"; then
        # apply_first_update_text stdout: "installed: <rel>" |
        # "preserved: <rel> (modified since install)" | silent (== same)
        # Capture so we can classify for the summary.
        local fu_out fu_rc=0
        fu_out=$(apply_first_update_text "$TEMPLATE_DIR" "$rel_path") || fu_rc=$?
        if [[ $fu_rc -ne 0 ]]; then
          error "apply_first_update_text failed for $rel_path (rc=$fu_rc)"
          final_rc=2
          continue
        fi
        case "$fu_out" in
          installed:*) added=$((added + 1)); [[ -n "$fu_out" ]] && echo -e "  ${GREEN}Added${NC}: $rel_path" >&2 ;;
          preserved:*) updated=$((updated + 1)); echo -e "  ${YELLOW}Preserved${NC}: $rel_path (user-modified)" >&2 ;;
          *)           identical=$((identical + 1)) ;;
        esac
        # Apply Finding 3 / Issue 2 parity for new installs: if incoming is
        # executable and user file exists but lacks exec bit, set it.
        if [[ -f "$rel_path" && -x "$TEMPLATE_DIR/$rel_path" && ! -x "$rel_path" ]]; then
          chmod +x "$rel_path" 2>/dev/null || true
        fi
        stage_manifest_add "$rel_path" "$(sha256_of "$TEMPLATE_DIR/$rel_path")"
      else
        # Non-text in first-update: mirror legacy path.
        # stage_skipped=true when user chose to preserve their own version —
        # symmetric with do_update_v2 conflict policy (never advance staged
        # sha past the incoming version the user declined).
        local stage_skipped=false
        if [[ -f "$rel_path" ]]; then
          if diff -q "$rel_path" "$TEMPLATE_DIR/$rel_path" >/dev/null 2>&1; then
            # Issue 2 fix: identical content but mode may differ — force
            # copy_file so chmod+x logic (copy_file body) runs.
            copy_file "$TEMPLATE_DIR" "$PWD" "$rel_path"
            nontext_identical=$((nontext_identical + 1))
          else
            local action; action="$(prompt_conflict "$rel_path" "$TEMPLATE_DIR" "$PWD")"
            case "$action" in
              overwrite) copy_file "$TEMPLATE_DIR" "$PWD" "$rel_path"; nontext_overwritten=$((nontext_overwritten + 1)); echo -e "  ${YELLOW}Overwritten${NC}: $rel_path" >&2 ;;
              skip)      nontext_identical=$((nontext_identical + 1)); stage_skipped=true ;;
              quit)      info "Aborted by user."; exit 0 ;;
            esac
          fi
        else
          copy_file "$TEMPLATE_DIR" "$PWD" "$rel_path"
          nontext_added=$((nontext_added + 1))
          echo -e "  ${GREEN}Added${NC}: $rel_path" >&2
        fi
        if [[ "$stage_skipped" != "true" ]]; then
          stage_manifest_add "$rel_path" "$(sha256_of "$TEMPLATE_DIR/$rel_path")"
        fi
      fi
    done
    if [[ $final_rc -ne 2 ]]; then
      stage_manifest_commit
    fi
  else
    # v2 steady-state: 3-way merge text files, legacy 2-way for non-text.
    stage_manifest_begin
    local v2_rc=0
    do_update_v2 "$TEMPLATE_DIR" "${rels[@]}" || v2_rc=$?

    updated=$_REIN_UPDATE_UPDATES
    conflicts=$_REIN_UPDATE_CONFLICTS

    # Non-text fallback — _REIN_UPDATE_NONTEXT is space-separated.
    if [[ -n "${_REIN_UPDATE_NONTEXT:-}" ]]; then
      local nontext_rel
      for nontext_rel in $_REIN_UPDATE_NONTEXT; do
        # stage_skipped=true when user chose to preserve their own version —
        # symmetric with do_update_v2 conflict policy (never advance staged
        # sha past the incoming version the user declined).
        local stage_skipped=false
        if [[ -f "$nontext_rel" ]]; then
          if diff -q "$nontext_rel" "$TEMPLATE_DIR/$nontext_rel" >/dev/null 2>&1; then
            # Issue 2 fix: content identical → still call copy_file so
            # mode propagation runs (fixes exec bit drift regression).
            copy_file "$TEMPLATE_DIR" "$PWD" "$nontext_rel"
            nontext_identical=$((nontext_identical + 1))
          else
            local action; action="$(prompt_conflict "$nontext_rel" "$TEMPLATE_DIR" "$PWD")"
            case "$action" in
              overwrite) copy_file "$TEMPLATE_DIR" "$PWD" "$nontext_rel"; nontext_overwritten=$((nontext_overwritten + 1)); echo -e "  ${YELLOW}Overwritten${NC}: $nontext_rel" >&2 ;;
              skip)      nontext_identical=$((nontext_identical + 1)); stage_skipped=true ;;
              quit)      info "Aborted by user."; exit 0 ;;
            esac
          fi
        else
          copy_file "$TEMPLATE_DIR" "$PWD" "$nontext_rel"
          nontext_added=$((nontext_added + 1))
          echo -e "  ${GREEN}Added${NC}: $nontext_rel" >&2
        fi
        if [[ "$stage_skipped" != "true" ]]; then
          stage_manifest_add "$nontext_rel" "$(sha256_of "$TEMPLATE_DIR/$nontext_rel")"
        fi
      done
    fi

    if [[ $v2_rc -eq 2 ]]; then
      error "fatal error during v2 update — staging manifest preserved at $(staging_manifest_path)"
      exit 2
    fi

    stage_manifest_commit
    final_rc=$v2_rc  # 0 or 1 (partial conflict)
  fi

  scaffold_trail "$PWD" "$TEMPLATE_DIR" "true"
  substitute_vars "$PWD" "$project_name"

  echo ""
  info "Update summary:"
  [[ $added -gt 0 ]]              && echo "  added: $added"
  [[ $updated -gt 0 ]]            && echo "  updated (3-way merge): $updated"
  [[ $conflicts -gt 0 ]]          && echo -e "  ${YELLOW}conflicts${NC}: $conflicts (user versions kept; .rej files in $(rein_conflicts_dir))"
  [[ $overwritten -gt 0 ]]        && echo "  overwritten: $overwritten"
  [[ $identical -gt 0 ]]          && echo "  identical: $identical"
  [[ $nontext_added -gt 0 ]]      && echo "  non-text added: $nontext_added"
  [[ $nontext_overwritten -gt 0 ]] && echo "  non-text overwritten: $nontext_overwritten"
  [[ $nontext_identical -gt 0 ]]  && echo "  non-text identical/mode-refreshed: $nontext_identical"

  # ---- Prune (uses the pre-commit snapshot taken earlier) ----
  # The snapshot was captured at the top of cmd_merge before stage_manifest_*
  # mutated the live manifest. That snapshot holds the OLD tracked-file set,
  # which is what prune_impl needs to compare against the NEW template to
  # identify removal candidates.
  if [[ "$PRUNE_MODE" == "true" ]]; then
    prune_impl "$PWD" "$TEMPLATE_DIR" "$PRUNE_CONFIRM" "$prune_snapshot"
    [[ -n "$prune_snapshot" && -f "$prune_snapshot" ]] && rm -f "$prune_snapshot"
  fi

  # v2 manifest has already been committed atomically via stage_manifest_commit.
  # manifest_generate writes schema_version="1" unconditionally (v1.1.0 legacy
  # helper) — calling it here would clobber the v2 manifest we just committed,
  # forcing is_first_update_v2 to return true on every subsequent update and
  # effectively keeping the 3-way merge path dead. Finding from codex Round 1
  # (Group 7 2026-04-24). If prune ran and removed files, those entries are
  # still present in the committed manifest; that's a separate, pre-existing
  # gap (prune does not update the manifest) and not introduced by this fix.
  # TODO: make manifest_generate v2-aware; until then, skip it here.

  exit "$final_rc"
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# rein_path_match_helper
# Absolute path to scripts/rein-path-match.py. Cached across calls.
# Mirrors rein_manifest_helper. Plan C Task 5.2.
# ---------------------------------------------------------------------------
_REIN_PATH_MATCH_HELPER=""
rein_path_match_helper() {
  if [ -z "$_REIN_PATH_MATCH_HELPER" ]; then
    local src="${BASH_SOURCE[0]:-$0}"
    local dir
    dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)
    _REIN_PATH_MATCH_HELPER="$dir/rein-path-match.py"
  fi
  echo "$_REIN_PATH_MATCH_HELPER"
}

# ---------------------------------------------------------------------------
# path_matches <pattern> <rel>
# Bash wrapper around rein-path-match.py. Returns 0 if match, 1 otherwise.
# Plan C Task 5.2.
# ---------------------------------------------------------------------------
path_matches() {
  local pattern="$1" rel="$2"
  local result
  result=$(python3 "$(rein_path_match_helper)" "$pattern" "$rel" 2>/dev/null || echo "false")
  [ "$result" = "true" ]
}

# ---------------------------------------------------------------------------
# _rein_file_is_modified <rel>
# Compares the on-disk sha256 of <rel> against the sha recorded in the
# manifest. Returns 0 (true) if content differs or the file is absent but
# recorded (both of those cases mean "don't blindly remove").
# Plan C Task 5.4 helper.
# ---------------------------------------------------------------------------
_rein_file_is_modified() {
  local rel="$1"
  [ -f "$rel" ] || return 1   # nothing to preserve if file is already gone
  local recorded
  recorded=$(python3 "$(rein_manifest_helper)" read "$(manifest_path .)" "$rel" 2>/dev/null || echo "")
  [ -n "$recorded" ] || return 1  # not tracked — caller shouldn't try to remove
  local cur
  cur=$(sha256_of "$rel")
  [ "$recorded" != "$cur" ]
}

# ---------------------------------------------------------------------------
# _rein_remove_backup_and_delete <backup_dir> <rel1> <rel2> ...
# Shared helper for prune_apply + cmd_remove. For each rel:
#   - If file is tracked-and-modified (sha mismatch): preserve in place,
#     echo "preserved (modified): <rel>".
#   - Else: mkdir -p the mirror path under <backup_dir>, mv the file into
#     it (byte-preserving), increment the removed counter.
#
# Emits one summary line:
#   "✓ Removed N file(s). Preserved M modified file(s). Backup: <dir>/"
#   (Backup line omitted when N == 0.)
# Plan C Task 5.4 + 5.5 (RU-remove-modified-preserved-no-force-flag,
#                        RU-remove-backup shared helper).
# ---------------------------------------------------------------------------
_rein_remove_backup_and_delete() {
  local backup_dir="$1"; shift
  local removed=0 preserved=0
  local rel
  for rel in "$@"; do
    [ -e "$rel" ] || continue
    if _rein_file_is_modified "$rel"; then
      echo "preserved (modified): $rel"
      preserved=$((preserved + 1))
      continue
    fi
    mkdir -p "$backup_dir/$(dirname "$rel")"
    mv "$rel" "$backup_dir/$rel"
    removed=$((removed + 1))
  done
  echo "✓ Removed $removed file(s). Preserved $preserved modified file(s)."
  if [ "$removed" -gt 0 ]; then
    echo "  Backup: $backup_dir/"
  fi
}

# ---------------------------------------------------------------------------
# _rein_remove_usage
# Prints the rein remove help text. Exits with the caller's desired code.
# ---------------------------------------------------------------------------
_rein_remove_usage() {
  cat <<'EOF'
Usage:
  rein remove --path <glob> --confirm     Remove files matching <glob>
                                          (anchored segment matcher: '*' =
                                          one segment, '**' = zero or more).
                                          User-modified files are preserved.
  rein remove --all --confirm             Remove ALL rein-tracked files.
                                          TTY only — requires typed 'DELETE'.
  rein remove --dry-run                   Preview all tracked files that
                                          would be targeted. No deletion.

  rein remove --help                      Show this help.

Safety:
  - Deleted files land in .rein-remove-backup-<ts>/ (project root).
  - User-modified files are ALWAYS preserved in place (no --force flag).
  - --all --confirm rejects non-interactive stdin (pipe / redirect / heredoc).
EOF
}

# ---------------------------------------------------------------------------
# cmd_remove <args...>
# Dispatcher for 'rein remove'. Parses --path/--all/--confirm/--dry-run,
# enforces the scope-flag requirement (RU-remove-requires-scope-flag), and
# delegates to:
#   - _rein_remove_dry_run
#   - _rein_remove_path_apply <glob>
#   - _rein_remove_all_apply
# The TTY-only gate for --all --confirm is enforced inside
# _rein_remove_all_apply (RU-remove-all-requires-typed-confirmation, Plan C
# Task 5.3).
# ---------------------------------------------------------------------------
cmd_remove() {
  local have_path=0 have_all=0 have_confirm=0 have_dry=0 have_help=0
  local path_glob=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --path)
        have_path=1
        [ $# -lt 2 ] && { error "--path requires a <glob> argument"; exit 2; }
        path_glob="$2"
        shift 2
        ;;
      --all)      have_all=1;     shift ;;
      --confirm)  have_confirm=1; shift ;;
      --dry-run)  have_dry=1;     shift ;;
      --help|-h)  have_help=1;    shift ;;
      *)
        error "unknown flag: $1"
        _rein_remove_usage >&2
        exit 2
        ;;
    esac
  done

  if [ "$have_help" = "1" ]; then
    _rein_remove_usage
    exit 0
  fi

  if [ "$have_path" = "0" ] && [ "$have_all" = "0" ] && [ "$have_dry" = "0" ]; then
    # No scope flag at all
    if [ "$have_confirm" = "1" ]; then
      cat >&2 <<'EOF'
Error: 'rein remove --confirm' requires either --path <glob> or --all.
  To remove specific files: rein remove --path '.claude/skills/foo/*' --confirm
  To remove ALL rein files:  rein remove --all --confirm   (requires typed confirmation)
EOF
      exit 2
    fi
    # No flags at all → usage + exit 2
    _rein_remove_usage >&2
    exit 2
  fi

  # Prefer --dry-run even when other flags are also present — it's purely
  # informational and must never cause side effects.
  if [ "$have_dry" = "1" ]; then
    _rein_remove_dry_run
    exit 0
  fi

  if [ "$have_confirm" = "0" ]; then
    error "rein remove requires --confirm to actually remove files (use --dry-run to preview)"
    exit 2
  fi

  if [ "$have_all" = "1" ] && [ "$have_path" = "1" ]; then
    error "rein remove: cannot combine --all with --path"
    exit 2
  fi

  if [ "$have_path" = "1" ]; then
    _rein_remove_path_apply "$path_glob"
    exit $?
  fi

  if [ "$have_all" = "1" ]; then
    _rein_remove_all_apply
    exit $?
  fi
}

# ---------------------------------------------------------------------------
# _rein_remove_dry_run
# Lists every manifest-tracked file. Used to preview the total scope
# without choosing a specific glob. No filesystem mutation.
# ---------------------------------------------------------------------------
_rein_remove_dry_run() {
  local mf; mf=$(manifest_path ".")
  if [ ! -f "$mf" ]; then
    echo "(no manifest — nothing is tracked yet)"
    return 0
  fi
  echo "Dry-run: rein remove would consider these tracked files:"
  python3 "$(rein_manifest_helper)" list "$mf" | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# _rein_remove_path_apply <glob>
# Remove all manifest-tracked files whose relpath matches <glob>, skipping
# user-modified files (preserved) and logging backups.
# ---------------------------------------------------------------------------
_rein_remove_path_apply() {
  local glob="$1"
  local mf; mf=$(manifest_path ".")
  if [ ! -f "$mf" ]; then
    error "no manifest — nothing to remove"
    exit 2
  fi
  local targets=()
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if path_matches "$glob" "$rel"; then
      targets+=("$rel")
    fi
  done < <(python3 "$(rein_manifest_helper)" list "$mf")

  if [ "${#targets[@]}" = "0" ]; then
    echo "No tracked files match pattern: $glob"
    return 0
  fi

  local ts; ts=$(date +'%Y-%m-%dT%H-%M-%S')
  local backup=".rein-remove-backup-$ts"
  _rein_remove_backup_and_delete "$backup" "${targets[@]}"
  return 0
}

# ---------------------------------------------------------------------------
# _rein_remove_all_apply
# TTY-only typed-DELETE gate for 'rein remove --all --confirm'.
#
# CRITICAL SECURITY CONTRACT (Plan C v3):
#   - [ ! -t 0 ]  → non-interactive stdin → immediate exit 2.
#   - 'script -q' / 'expect' / any other TTY-mock is deliberately not
#     special-cased — if the test harness actually attaches a PTY, the
#     gate activates; pipes / redirects / heredocs all short-circuit.
#   - NO --yes / --force / --no-confirm bypass exists. Those strings
#     are rejected at the cmd_remove dispatcher layer as unknown flags.
# ---------------------------------------------------------------------------
_rein_remove_all_apply() {
  if [ ! -t 0 ]; then
    cat >&2 <<'EOF'
aborted: --all --confirm requires a TTY (interactive typed 'DELETE').
non-interactive stdin (pipe, redirect, heredoc) is rejected by design.
EOF
    exit 2
  fi

  cat <<'EOF'
This will remove ALL files tracked by the rein manifest.
User-modified files will be preserved.
Backup will be written to .rein-remove-backup-<ts>/.
Type DELETE to confirm (or anything else to abort):
EOF
  printf '> '
  local input=""
  read -r input || input=""
  if [ "$input" != "DELETE" ]; then
    echo "aborted" >&2
    exit 2
  fi

  local mf; mf=$(manifest_path ".")
  if [ ! -f "$mf" ]; then
    error "no manifest — nothing to remove"
    exit 2
  fi

  local targets=()
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    targets+=("$rel")
  done < <(python3 "$(rein_manifest_helper)" list "$mf")

  if [ "${#targets[@]}" = "0" ]; then
    echo "No tracked files to remove."
    return 0
  fi

  local ts; ts=$(date +'%Y-%m-%dT%H-%M-%S')
  local backup=".rein-remove-backup-$ts"
  _rein_remove_backup_and_delete "$backup" "${targets[@]}"
  return 0
}

# ---------------------------------------------------------------------------
# parse_flags(args...)
# Sets ALL_OVERWRITE / PRUNE_MODE / PRUNE_CONFIRM globals based on flags
# present in the remaining args. Unknown flags trigger an error.
# Positional args (e.g. project name) are not accepted here — caller must
# have already shifted past them.
# ---------------------------------------------------------------------------
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        ALL_OVERWRITE=true
        export REIN_YES=1
        ;;
      --yes|-y)
        ALL_OVERWRITE=true
        export REIN_YES=1
        ;;
      --no-self-update)
        export REIN_NO_SELF_UPDATE=1
        ;;
      --prune)
        PRUNE_MODE=true
        ;;
      --confirm)
        PRUNE_CONFIRM=true
        ;;
      --)
        shift
        break
        ;;
      -*)
        error "unknown flag '$1'"
        usage
        exit 1
        ;;
      *)
        error "unexpected argument '$1'"
        usage
        exit 1
        ;;
    esac
    shift
  done

  # Validate combinations
  if [[ "$PRUNE_CONFIRM" == "true" && "$PRUNE_MODE" != "true" ]]; then
    error "--confirm requires --prune"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# rein job * — background job infrastructure (Plan C Phase 7–8).
#
# Design §5: three files per job under .claude/cache/jobs/:
#   <jid>.json    meta: {name, cmd, cwd, started_at, transport, finished_at, exit_code}
#   <jid>.status  one of: running / success / failed / unknown_dead
#   <jid>.exit    decimal exit code, written atomically by rein_job_wrapper
#   <jid>.pid     live pid (removed when wrapper finishes)
#   <jid>.log     merged stdout/stderr
# All writes go through temp-file + mv so a reader never sees a partial
# line (BG-file-state-atomic-write).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# rein_job_wrapper — completion writer (Task 7.3, BG-job-completion-writer).
# Must be defined at the top so `declare -f rein_job_wrapper` can capture
# its body and hand it to the detached child. The detach paths (POSIX
# setsid / MINGW subshell) re-source this definition inside the child so
# no process-local state is shared with the caller's shell.
#
# Args: pidf exitf statf metaf log -- <command argv...>
# Contract:
#   - writes pid atomically
#   - runs command with stdin redirected to /dev/null (BG-no-interactive-jobs)
#   - writes exit code atomically
#   - flips .status to success|failed
#   - updates meta with finished_at + exit_code
#   - removes .pid on the way out
# ---------------------------------------------------------------------------
rein_job_wrapper() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5"
  shift 5
  # Atomic write: own pid.
  printf '%s' "$$" > "${pidf}.tmp.$$" && mv -f "${pidf}.tmp.$$" "$pidf"
  printf '%s' "running" > "${statf}.tmp.$$" && mv -f "${statf}.tmp.$$" "$statf"
  # Run the command. stdin closed per no-interactive contract. We swallow
  # errexit failure from the command itself — the rc is the signal.
  local rc=0
  "$@" >"$log" 2>&1 </dev/null || rc=$?
  printf '%s' "$rc" > "${exitf}.tmp.$$" && mv -f "${exitf}.tmp.$$" "$exitf"
  local final
  if [ "$rc" -eq 0 ]; then final=success; else final=failed; fi
  printf '%s' "$final" > "${statf}.tmp.$$" && mv -f "${statf}.tmp.$$" "$statf"
  python3 - "$metaf" "$rc" <<'PY' 2>/dev/null || true
import json, os, sys, time
meta_path, rc = sys.argv[1], int(sys.argv[2])
try:
    with open(meta_path) as f:
        m = json.load(f)
except Exception:
    m = {}
m["finished_at"] = int(time.time())
m["exit_code"] = rc
tmp = meta_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(m, f)
os.replace(tmp, meta_path)
PY
  rm -f "$pidf"
}

# ---------------------------------------------------------------------------
# _rein_job_launch — dispatch detach to the platform-specific helper.
# Task 7.2 shell_mode transform happens HERE (plan says: "맨 앞에서 transform
# 먼저 수행") so wrapper remains argv-only and platform paths share the
# already-transformed "$@".
# ---------------------------------------------------------------------------
_rein_job_launch() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5" shell_mode="$6"
  shift 6

  # Task 7.2 (BG-job-start-shell-opt-in): wrap argv in `bash -c <expr>` when
  # the caller passed --shell. Default path is argv-only so shell metachars
  # are literal (BG-job-start-default-argv-transport).
  if [ "$shell_mode" = "1" ]; then
    # Join with a single space. If the caller passed multiple argv after
    # --shell (e.g. `--shell -- foo 'bar baz'`), join them and hand the
    # joined string to bash -c as a single expression. This is lossy for
    # multi-token arrays; callers should supply exactly one expression
    # after --, matching the design.
    local expr="$*"
    set -- bash -c "$expr"
  fi

  local platform
  platform=$(detect_platform) || return $?
  case "$platform" in
    posix)           _rein_job_launch_posix "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" ;;
    windows_git_bash) _rein_job_launch_mingw "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" ;;
    *) echo "unsupported platform: $platform" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _rein_wrapper_script_path — absolute path to the standalone wrapper script.
# Resolves next to rein.sh so it is shippable via COPY_TARGETS and can be
# invoked without re-embedding the wrapper body inside `bash -c "$(declare
# -f …)"` (the heredoc-in-bash-c path runs into nested-quote pitfalls).
# Cached per process.
# ---------------------------------------------------------------------------
_REIN_WRAPPER_SCRIPT=""
_rein_wrapper_script_path() {
  if [ -z "$_REIN_WRAPPER_SCRIPT" ]; then
    local src="${BASH_SOURCE[0]:-$0}"
    local dir
    dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)
    _REIN_WRAPPER_SCRIPT="$dir/rein-job-wrapper.sh"
  fi
  echo "$_REIN_WRAPPER_SCRIPT"
}

# ---------------------------------------------------------------------------
# _rein_job_launch_posix — Task 7.4 (BG-job-detach-posix-setsid-with-pid).
# Uses setsid when available so the child becomes a session leader and the
# recorded pid doubles as the process-group id for cmd_job_stop. Falls back
# to nohup when setsid is missing (rare on modern Linux/Darwin but possible
# in minimal containers).
# ---------------------------------------------------------------------------
_rein_job_launch_posix() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5"
  shift 5
  local wrapper
  wrapper="$(_rein_wrapper_script_path)"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
      </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
      </dev/null >/dev/null 2>&1 &
  fi
  disown "$!" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _rein_job_launch_mingw — Task 7.5 (BG-job-detach-windows-git-bash-subshell-pid).
# MINGW64 / MSYS2 Git Bash usually does not ship setsid. Prefer it when
# present (some installs have it via coreutils); otherwise detach via a
# `( ... & )` subshell so the child reparents off the interactive shell.
# ---------------------------------------------------------------------------
_rein_job_launch_mingw() {
  local pidf="$1" exitf="$2" statf="$3" metaf="$4" log="$5"
  shift 5
  local wrapper
  wrapper="$(_rein_wrapper_script_path)"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
      </dev/null >/dev/null 2>&1 &
  else
    ( bash "$wrapper" "$pidf" "$exitf" "$statf" "$metaf" "$log" "$@" \
        </dev/null >/dev/null 2>&1 & )
  fi
}

# ---------------------------------------------------------------------------
# cmd_job_start — Task 7.1 / 7.2.
# CLI: rein job start <name> [--shell] -- <cmd argv...>
# Returns within ~1s by detaching the job and emitting the id. Argv path
# keeps shell metachars literal; --shell wraps in `bash -c <expr>`.
# ---------------------------------------------------------------------------
cmd_job_start() {
  local name="" shell_mode=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --shell) shell_mode=1; shift ;;
      --)      shift; break ;;
      -*)      echo "unknown flag: $1" >&2; return 2 ;;
      *)       if [ -z "$name" ]; then name="$1"; shift
               else break; fi ;;
    esac
  done
  [ -n "$name" ] || { echo "usage: rein job start <name> [--shell] -- <cmd...>" >&2; return 2; }
  [ $# -gt 0 ]   || { echo "usage: rein job start <name> [--shell] -- <cmd...>" >&2; return 2; }

  local ts hex jid jd
  ts=$(date +%s)
  hex=$(printf '%04x' $((RANDOM & 0xFFFF)))
  jid="${name}-${ts}-${hex}"
  jd="$(rein_jobs_dir)"
  mkdir -p "$jd"

  local metaf="$jd/$jid.json"
  local pidf="$jd/$jid.pid"
  local statf="$jd/$jid.status"
  local exitf="$jd/$jid.exit"
  local log="$jd/$jid.log"

  local transport="argv"
  [ "$shell_mode" = "1" ] && transport="shell"

  local cwd joined_cmd
  cwd="$(pwd)"
  # Join cmd argv into a single representational string for the meta file.
  # This is informational (display in `rein job list`); the real execution
  # always uses the argv vector directly.
  joined_cmd="$*"

  python3 - "$metaf" "$name" "$transport" "$cwd" "$ts" "$joined_cmd" <<'PY'
import json, os, sys
metaf, name, transport, cwd, ts, cmd = sys.argv[1:7]
m = {
    "name": name,
    "transport": transport,
    "cwd": cwd,
    "started_at": int(ts),
    "cmd": cmd,
}
tmp = metaf + ".tmp"
with open(tmp, "w") as f:
    json.dump(m, f)
os.replace(tmp, metaf)
PY

  # Initialise status + log so status probe + tail never hit ENOENT before
  # the wrapper writes its first atomic update.
  write_atomic "$statf" "running"
  : > "$log"

  _rein_job_launch "$pidf" "$exitf" "$statf" "$metaf" "$log" "$shell_mode" "$@"

  echo "started: $jid"
  echo "log: $log"

  # Best-effort async GC so long-lived repos don't accumulate stale logs.
  # Failures (missing python3, concurrent GC, etc.) are swallowed because
  # GC is a hygiene task, not a correctness one.
  ( cmd_job_gc >/dev/null 2>&1 & ) 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# _probe_pid_alive <pid> — Task 8.1.
# Platform-aware liveness probe:
#   POSIX → `kill -0 <pid>` is the canonical "is this pid alive" check.
#   MINGW → `tasklist /FI "PID eq <pid>" /NH /FO CSV` with MSYS2_ARG_CONV_EXCL
#           to stop MSYS rewriting `/FI` into a POSIX path.
# Returns 0 if alive, 1 if not, 2 on unsupported platform.
# ---------------------------------------------------------------------------
_probe_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  local platform
  platform=$(detect_platform) || return 2
  case "$platform" in
    posix)
      kill -0 "$pid" 2>/dev/null
      ;;
    windows_git_bash)
      MSYS2_ARG_CONV_EXCL="*" tasklist /FI "PID eq $pid" /NH /FO CSV 2>/dev/null \
        | grep -q ",\"$pid\","
      ;;
    *) return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_job_status <jid> — Task 8.1 (BG-job-status-running-check).
# Prints status + (for settled jobs) exit + duration. Detects stale jobs
# whose .status is still "running" but whose recorded pid is no longer alive;
# rewrites state files to "unknown_dead" and reports that.
# ---------------------------------------------------------------------------
cmd_job_status() {
  local jid="${1:-}"
  [ -n "$jid" ] || { echo "usage: rein job status <job-id>" >&2; return 2; }
  local jd; jd="$(rein_jobs_dir)"
  local metaf="$jd/$jid.json"
  local statf="$jd/$jid.status"
  local pidf="$jd/$jid.pid"
  local exitf="$jd/$jid.exit"
  [ -f "$metaf" ] || { echo "unknown job: $jid" >&2; return 2; }

  local status
  status=$(cat "$statf" 2>/dev/null || echo "unknown")

  # Stale detection — .status claims running but no live pid behind it.
  if [ "$status" = "running" ]; then
    local pid
    pid=$(cat "$pidf" 2>/dev/null || echo "")
    if [ -n "$pid" ] && ! _probe_pid_alive "$pid"; then
      write_atomic "$statf" "unknown_dead"
      write_atomic "$exitf" "-1"
      status="unknown_dead"
    elif [ -z "$pid" ] && [ ! -f "$pidf" ]; then
      # .pid missing but .status=running — wrapper exited between our reads
      # or a partial start. Trust the .exit if present; otherwise mark dead.
      if [ -f "$exitf" ]; then
        local ec
        ec=$(cat "$exitf")
        if [ "$ec" = "0" ]; then
          write_atomic "$statf" "success"; status="success"
        else
          write_atomic "$statf" "failed"; status="failed"
        fi
      else
        write_atomic "$statf" "unknown_dead"
        write_atomic "$exitf" "-1"
        status="unknown_dead"
      fi
    fi
  fi

  python3 - "$metaf" "$status" "$exitf" <<'PY'
import json, os, sys, time
metaf, status, exitf = sys.argv[1:4]
try:
    with open(metaf) as f: m = json.load(f)
except Exception:
    m = {}
started = m.get("started_at", 0)
finished = m.get("finished_at")
print(f"status: {status}")
if status == "running":
    age = int(time.time()) - started if started else 0
    print(f"  (started {age}s ago)")
else:
    ec = m.get("exit_code")
    if ec is None and os.path.exists(exitf):
        try: ec = open(exitf).read().strip()
        except Exception: ec = "?"
    if ec is None: ec = "?"
    print(f"exit: {ec}")
    if finished and started:
        print(f"duration: {int(finished) - int(started)}s")
PY
  return 0
}

# ---------------------------------------------------------------------------
# cmd_job_stop_posix <pid> — Task 8.2 (BG-job-stop-posix-process-group).
# Sends SIGTERM to the process group (`kill -TERM -<pid>`), waits briefly
# for graceful shutdown, escalates to SIGKILL if still alive. When the
# pgroup signal fails (job started without setsid — pid is not a pgid),
# falls back to single-pid kill and warns once on stderr.
# ---------------------------------------------------------------------------
cmd_job_stop_posix() {
  local pid="$1"
  local target
  if kill -TERM "-$pid" 2>/dev/null; then
    echo "sent SIGTERM to process group $pid"
    target="-$pid"
  else
    echo "warning: job started without setsid; killing single PID only" >&2
    kill -TERM "$pid" 2>/dev/null || true
    target="$pid"
  fi

  local i
  for i in 1 2 3 4 5 6 7 8; do
    if ! _probe_pid_alive "$pid"; then
      echo "pid $pid exited gracefully"
      return 0
    fi
    sleep 0.25
  done

  # Escalate.
  if kill -KILL "$target" 2>/dev/null; then
    echo "escalated to SIGKILL"
  else
    # Target gone on its own between the wait and the escalate — still OK.
    :
  fi
  for i in 1 2 3 4; do
    _probe_pid_alive "$pid" || return 0
    sleep 0.25
  done
  echo "warning: pid $pid still alive after SIGKILL" >&2
  return 1
}

# ---------------------------------------------------------------------------
# cmd_job_stop_mingw <pid> — Task 8.3 (BG-job-stop-windows-git-bash-tree).
# SIGTERM first (respected on MINGW by processes spawned via Git Bash),
# then `taskkill /F /T /PID` to tree-kill on Windows if the pid is still
# alive. /T walks the child tree; /F forces termination.
# ---------------------------------------------------------------------------
cmd_job_stop_mingw() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if ! _probe_pid_alive "$pid"; then
      echo "pid $pid exited gracefully"
      return 0
    fi
    sleep 0.25
  done
  if MSYS2_ARG_CONV_EXCL="*" taskkill /F /T /PID "$pid" >/dev/null 2>&1; then
    echo "escalated to taskkill /F /T"
  fi
  for i in 1 2 3 4; do
    _probe_pid_alive "$pid" || return 0
    sleep 0.25
  done
  echo "warning: pid $pid still alive after taskkill" >&2
  return 1
}

# ---------------------------------------------------------------------------
# cmd_job_stop <jid> — dispatcher (Task 8.2/8.3).
# ---------------------------------------------------------------------------
cmd_job_stop() {
  local jid="${1:-}"
  [ -n "$jid" ] || { echo "usage: rein job stop <job-id>" >&2; return 2; }
  local jd; jd="$(rein_jobs_dir)"
  local pidf="$jd/$jid.pid"
  local metaf="$jd/$jid.json"
  if [ ! -f "$metaf" ]; then
    echo "unknown job: $jid" >&2; return 2
  fi
  if [ ! -f "$pidf" ]; then
    echo "job not running or already finished: $jid" >&2; return 2
  fi
  local pid
  pid=$(cat "$pidf" 2>/dev/null || echo "")
  [ -n "$pid" ] || { echo "pid file empty for $jid" >&2; return 2; }

  local platform
  platform=$(detect_platform) || return 2
  case "$platform" in
    posix)           cmd_job_stop_posix "$pid" ;;
    windows_git_bash) cmd_job_stop_mingw "$pid" ;;
    *) echo "unsupported platform for stop" >&2; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_job_tail <jid> [--lines N] — Task 8.4 (BG-job-tail-default-50-lines).
# Prints the last N lines of the job log (default 50). Shorter logs are
# printed in full; no error on jobs still writing.
# ---------------------------------------------------------------------------
cmd_job_tail() {
  local jid="" n=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) n="${2:-}"; shift 2 ;;
      -*) echo "unknown flag: $1" >&2; return 2 ;;
      *)  if [ -z "$jid" ]; then jid="$1"; shift
          else echo "unexpected arg: $1" >&2; return 2; fi ;;
    esac
  done
  [ -n "$jid" ] || { echo "usage: rein job tail <job-id> [--lines N]" >&2; return 2; }
  case "$n" in ''|*[!0-9]*) echo "--lines must be a positive integer" >&2; return 2 ;; esac
  local log; log="$(rein_jobs_dir)/$jid.log"
  [ -f "$log" ] || { echo "no log for job: $jid" >&2; return 2; }
  tail -n "$n" "$log"
}

# ---------------------------------------------------------------------------
# cmd_job_list — Task 8.5 (BG-job-list-split-running-recent).
# Two-section output: RUNNING (currently live jobs) + RECENT (last 10
# finished, most recently started first). Empty sections still print their
# headers so downstream tools can pipe safely.
# ---------------------------------------------------------------------------
cmd_job_list() {
  local jd; jd="$(rein_jobs_dir)"
  if [ ! -d "$jd" ]; then
    echo "RUNNING:"
    echo "RECENT:"
    return 0
  fi
  python3 - "$jd" <<'PY'
import json, os, sys, glob
jd = sys.argv[1]
jobs = []
for metaf in sorted(glob.glob(os.path.join(jd, "*.json"))):
    try:
        with open(metaf) as f: m = json.load(f)
    except Exception:
        continue
    base = os.path.basename(metaf)
    jid = base[:-5] if base.endswith(".json") else base
    statf = metaf[:-5] + ".status"
    status = "unknown"
    if os.path.exists(statf):
        try: status = open(statf).read().strip()
        except Exception: pass
    jobs.append({"jid": jid, "status": status, **m})
running = [j for j in jobs if j.get("status") == "running"]
recent  = [j for j in jobs if j.get("status") != "running"]
recent.sort(key=lambda x: -x.get("started_at", 0))
recent = recent[:10]
print("RUNNING:")
for j in running:
    print(f"  {j['jid']}  (started {j.get('started_at','?')})")
print("RECENT:")
for j in recent:
    ec = j.get("exit_code", "?")
    print(f"  {j['jid']}  {j.get('status','?')}({ec})")
PY
}

# ---------------------------------------------------------------------------
# cmd_job_gc — Task 8.6 (BG-cleanup-gc).
# Two-tier retention:
#   - .log    kept for 7 days after finished_at
#   - .json / .exit / .status kept for 30 days
# .pid is always absent by the time we run (wrapper removes it), so this
# function does not try to touch it. Silently skips still-running jobs.
#
# Called both via `rein job gc` and asynchronously from `rein job start`
# so long-lived repos don't accumulate stale logs.
# ---------------------------------------------------------------------------
cmd_job_gc() {
  local jd; jd="$(rein_jobs_dir)"
  [ -d "$jd" ] || return 0
  python3 - "$jd" <<'PY'
import json, os, sys, time, glob
jd = sys.argv[1]
now = time.time()
for metaf in glob.glob(os.path.join(jd, "*.json")):
    try:
        with open(metaf) as f: m = json.load(f)
    except Exception:
        continue
    finished = m.get("finished_at")
    if not finished:
        continue  # still running — skip
    age_days = (now - float(finished)) / 86400.0
    base = metaf[:-5]  # strip .json
    if age_days > 7:
        for ext in (".log",):
            p = base + ext
            if os.path.exists(p):
                try: os.remove(p)
                except OSError: pass
    if age_days > 30:
        for ext in (".json", ".exit", ".status"):
            p = base + ext
            if os.path.exists(p):
                try: os.remove(p)
                except OSError: pass
PY
}

# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------
main() {
  # Preserve original argv for potential exec re-run after self-update
  ORIGINAL_ARGV=("$@")

  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    new)
      if [[ $# -lt 2 ]]; then
        error "project name required"
        echo "Usage: rein new <project-name> [--all]" >&2
        exit 1
      fi
      shift
      local project_name="$1"
      shift
      parse_flags "$@"
      cmd_new "$project_name"
      ;;
    init)
      shift
      cmd_init "$@"
      ;;
    merge|update)
      shift
      # Phase 5 Task 5.7 — branch on mode BEFORE the legacy 3-way merge path
      # touches anything. plugin mode never runs cmd_merge: rein doesn't own
      # the plugin's files (CLAUDE.md included), so update is a redirect.
      if [[ -e ".git" ]]; then
        local _phase5_mode
        _phase5_mode="$(read_project_mode "$PWD")"
        if [[ "$_phase5_mode" == "plugin" ]]; then
          # Snapshot CLAUDE.md sha256 + presence flag to prove zero-touch.
          # Presence parity catches absent→created regressions; byte equality
          # catches in-place mutation. Both are enforced.
          local _phase5_sha_root_before="" _phase5_sha_nested_before=""
          local _phase5_exists_root_before=0 _phase5_exists_nested_before=0
          if [[ -f "$PWD/CLAUDE.md" ]]; then
            _phase5_sha_root_before=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PWD/CLAUDE.md")
            _phase5_exists_root_before=1
          fi
          if [[ -f "$PWD/.claude/CLAUDE.md" ]]; then
            _phase5_sha_nested_before=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PWD/.claude/CLAUDE.md")
            _phase5_exists_nested_before=1
          fi
          update_plugin_mode "$PWD"
          local _phase5_exists_root_after=0 _phase5_exists_nested_after=0
          [[ -f "$PWD/CLAUDE.md" ]] && _phase5_exists_root_after=1
          [[ -f "$PWD/.claude/CLAUDE.md" ]] && _phase5_exists_nested_after=1
          [[ "$_phase5_exists_root_before" == "$_phase5_exists_root_after" ]] || {
            error "rein update plugin-mode unexpectedly created/removed CLAUDE.md"
            exit 1
          }
          [[ "$_phase5_exists_nested_before" == "$_phase5_exists_nested_after" ]] || {
            error "rein update plugin-mode unexpectedly created/removed .claude/CLAUDE.md"
            exit 1
          }
          if [[ -n "$_phase5_sha_root_before" ]]; then
            local _phase5_sha_root_after
            _phase5_sha_root_after=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PWD/CLAUDE.md")
            [[ "$_phase5_sha_root_before" == "$_phase5_sha_root_after" ]] || {
              error "rein update plugin-mode unexpectedly modified CLAUDE.md"
              exit 1
            }
          fi
          if [[ -n "$_phase5_sha_nested_before" ]]; then
            local _phase5_sha_nested_after
            _phase5_sha_nested_after=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PWD/.claude/CLAUDE.md")
            [[ "$_phase5_sha_nested_before" == "$_phase5_sha_nested_after" ]] || {
              error "rein update plugin-mode unexpectedly modified .claude/CLAUDE.md"
              exit 1
            }
          fi
          exit 0
        fi
      fi
      parse_flags "$@"
      cmd_merge
      ;;
    remove)
      shift
      cmd_remove "$@"
      ;;
    migrate)
      # Phase 4 / Phase 9 Task 9.4: dispatch to the migrate orchestrator.
      # The orchestrator (scripts/rein-migrate.sh) handles the v1.x scaffold
      # → v2.0 plugin transition: lock → manifest cleanup → plugin install →
      # router git mv → runtime init → project.json write-last → lock
      # release. Forward all remaining argv (e.g., --dry-run, --resume).
      shift
      local _migrate_sh
      _migrate_sh="$(_phase5_rein_home)/scripts/rein-migrate.sh"
      if [[ ! -f "$_migrate_sh" ]]; then
        error "rein-migrate.sh missing at $_migrate_sh"; exit 1
      fi
      bash "$_migrate_sh" "$@"
      ;;
    job)
      shift
      if [[ $# -eq 0 ]]; then
        error "rein job requires a subcommand (start|status|stop|tail|list|gc)"
        exit 1
      fi
      local subcmd="$1"; shift
      case "$subcmd" in
        start)  cmd_job_start "$@" ;;
        status) cmd_job_status "$@" ;;
        stop)   cmd_job_stop "$@" ;;
        tail)   cmd_job_tail "$@" ;;
        list)   cmd_job_list "$@" ;;
        gc)     cmd_job_gc "$@" ;;
        *)
          error "unknown job subcommand '$subcmd' (want: start|status|stop|tail|list|gc)"
          exit 1
          ;;
      esac
      ;;
    --version|-v)
      echo "rein $VERSION"
      ;;
    --help|-h)
      usage
      ;;
    *)
      error "unknown command '$1'"
      usage
      exit 1
      ;;
  esac
}

# --source-only mode — tests source this file to load functions without running main.
# Example: `source scripts/rein.sh --source-only` then invoke detect_platform etc.
# Plan C Task 1.1.
if [[ "${1:-}" == "--source-only" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Only invoke main when executed directly. Tests can source this file with
# REIN_SOURCED=1 to load all functions without triggering main.
if [[ "${REIN_SOURCED:-0}" != "1" ]]; then
  main "$@"
fi
