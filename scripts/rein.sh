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

VERSION="1.0.0"
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
# Legacy v1.x scaffold-mode helper retained for migration tooling references.
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
# Internal helper retained for migration tooling — returns the flat
# repo-relative path list of rein-managed files for v1.x → v1.0.0 migration.
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
  rein init [flags]                 Install rein-core plugin into current git repo
  rein update                       Show plugin update pointer (use 'claude plugin update rein-core')
  rein migrate [flags]              v1.x scaffold → v1.0 plugin migration (legacy)
                                    Flags: --dry-run, --resume
  rein job <subcmd>                 Background job (start|status|stop|tail|list|gc)
  rein --version                    Show version
  rein --help                       Show this help

Flags (init):
  --mode=plugin                     Only 'plugin' mode is supported (default)
  --scope=<user|project|local|managed>
                                    Settings.json scope for plugin entry
                                    (default: project)

Environment:
  REIN_TEMPLATE_REPO                Override template repository URL
  CLAUDE_TEMPLATE_REPO              (deprecated) Alias for REIN_TEMPLATE_REPO
EOF
}

# ---------------------------------------------------------------------------
# rein init — mode + scope flags
#
# MODE/SCOPE globals are set by parse_init_flags() before cmd_init() dispatches
# to install_plugin_mode(). v1.0.0 OSS launch supports plugin mode only.
# ---------------------------------------------------------------------------
MODE=""               # set by --mode=plugin (only valid value); defaults to "plugin"
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
          error "--mode requires a value (plugin)"; exit 1
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

  MODE="${MODE:-plugin}"
  SCOPE="${SCOPE:-project}"

  case "$MODE" in
    plugin) ;;
    *) error "invalid --mode '$MODE' (only 'plugin' is supported)"; exit 1 ;;
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
# Plugin-mode rein init: register rein in the chosen scope's settings.json,
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
  # rein@^1.0.0 — pinned to the major plugin version (v1.0.0 OSS launch).
  ( cd "$target_root" && python3 "$install_py" \
      --scope "$SCOPE" \
      --plugin "rein=^1.0.0" >/dev/null )

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

  info "rein init: setting up plugin mode (scope=$SCOPE)..."

  local target_root="$PWD"
  install_plugin_mode "$target_root"

  echo ""
  info "rein init complete (mode=plugin scope=$SCOPE version=$VERSION)."
  info "  Plugin entry written to scope=$SCOPE settings.json."
  info "  Use 'claude /plugin install rein@rein-dev-local' or restart Claude Code to activate."
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
    init)
      shift
      cmd_init "$@"
      ;;
    merge|update)
      echo 'plugin 모드는 `claude plugin update rein-core` 를 사용하세요. 자세한 내용: https://github.com/JayJihyunKim/rein'
      exit 0
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
