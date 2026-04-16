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

VERSION="0.7.0"
TEMPLATE_REPO="${REIN_TEMPLATE_REPO:-${CLAUDE_TEMPLATE_REPO:-git@github.com:JayJihyunKim/rein.git}}"

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
# Copy targets
# ---------------------------------------------------------------------------
COPY_TARGETS=(
  ".claude/CLAUDE.md"
  ".claude/settings.json"
  ".claude/settings.local.json.example"
  ".claude/orchestrator.md"
  ".claude/hooks"
  ".claude/rules"
  ".claude/workflows"
  ".claude/agents"
  ".claude/registry"
  ".claude/skills"
  ".claude/security"
  ".claude/router"
  ".github/workflows"
  "AGENTS.md"
  "docs/SETUP_GUIDE.md"
)

SOT_DIRS=(
  "SOT/inbox"
  "SOT/daily"
  "SOT/weekly"
  "SOT/decisions"
  "SOT/dod"
  "SOT/incidents"
  "SOT/agent-candidates"
)

# ---------------------------------------------------------------------------
# list_copy_files(template_dir)
# Outputs NUL-terminated relative file paths for all COPY_TARGETS.
# For files, prints directly. For directories, finds all files recursively
# excluding .DS_Store.
# Output is NUL-terminated to safely handle filenames with spaces/newlines.
# ---------------------------------------------------------------------------
list_copy_files() {
  local template_dir="$1"

  for target in "${COPY_TARGETS[@]}"; do
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
  done
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
  # SCOPE NOTE: SOT/ files are intentionally NOT tracked in the manifest:
  #   - SOT/index.md is a starter file that the project owner immediately
  #     customizes; treating it as rein-tracked would mean prune sees it as
  #     "removed from template" (because list_copy_files excludes SOT/) and
  #     would attempt to delete it.
  #   - SOT/<sub>/.gitkeep files are harmless directory markers; tracking
  #     them would create the same false-positive prune target.
  # The manifest contract is therefore: "tracks every rein-managed file
  # under list_copy_files()". SOT/ is user state, not rein-managed.
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
# Returns 0 if manifest exists and is parseable with schema_version=1,
# 1 if missing, 2 if corrupt or unsupported schema.
manifest_validate() {
  local mf
  mf=$(manifest_path "$1")
  [[ -f "$mf" ]] || return 1
  python3 - "$mf" <<'PYEOF' >/dev/null 2>&1 || return 2
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get("schema_version") == "1", "unsupported schema"
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
    # Regenerate manifest to reflect deletions
    manifest_generate "$project_dir" "$template_dir"
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
  cp "$src" "$dst"
}

# ---------------------------------------------------------------------------
# scaffold_sot(dest_dir, template_dir)
# Creates SOT directory structure with .gitkeep files.
# Copies SOT/index.md from template if it exists (in merge mode: only if the
# file does not already exist, to avoid silently destroying local state).
# ---------------------------------------------------------------------------
scaffold_sot() {
  local dest_dir="$1"
  local template_dir="$2"
  local is_merge="${3:-false}"   # pass "true" for merge/update

  for sot_dir in "${SOT_DIRS[@]}"; do
    mkdir -p "$dest_dir/$sot_dir"
    touch "$dest_dir/$sot_dir/.gitkeep"
  done

  if [[ -f "$template_dir/SOT/index.md" ]]; then
    mkdir -p "$dest_dir/SOT"
    local dest_index="$dest_dir/SOT/index.md"
    if [[ "$is_merge" == "true" && -f "$dest_index" ]]; then
      # In merge mode, do not silently overwrite existing SOT/index.md.
      # The file is managed by the project owner; leave it alone.
      :
    else
      cp "$template_dir/SOT/index.md" "$dest_index"
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
  rein merge [flags]                Merge template into current project
  rein update [flags]               Update current project from template
  rein --version                    Show version
  rein --help                       Show this help

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

  scaffold_sot "$dest_dir" "$TEMPLATE_DIR" "false"
  substitute_vars "$dest_dir" "$project_name"

  # Generate initial manifest so future updates can prune safely
  manifest_generate "$dest_dir" "$TEMPLATE_DIR"

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

  local added=0
  local overwritten=0
  local skipped=0

  while IFS= read -r -d '' rel_path; do
    local dest_file="$PWD/$rel_path"

    if [[ -f "$dest_file" ]]; then
      # Check if files are identical
      if diff -q "$dest_file" "$TEMPLATE_DIR/$rel_path" >/dev/null 2>&1; then
        # Identical — skip silently
        skipped=$((skipped + 1))
      else
        # Different — prompt user
        local action
        action="$(prompt_conflict "$rel_path" "$TEMPLATE_DIR" "$PWD")"

        case "$action" in
          overwrite)
            copy_file "$TEMPLATE_DIR" "$PWD" "$rel_path"
            overwritten=$((overwritten + 1))
            echo -e "  ${YELLOW}Overwritten${NC}: $rel_path" >&2
            ;;
          skip)
            skipped=$((skipped + 1))
            ;;
          quit)
            info "Aborted by user."
            exit 0
            ;;
        esac
      fi
    else
      # New file — copy without prompting
      copy_file "$TEMPLATE_DIR" "$PWD" "$rel_path"
      added=$((added + 1))
      echo -e "  ${GREEN}Added${NC}: $rel_path" >&2
    fi
  done < <(list_copy_files "$TEMPLATE_DIR")

  scaffold_sot "$PWD" "$TEMPLATE_DIR" "true"
  substitute_vars "$PWD" "$project_name"

  echo ""
  info "Done! Added: $added, Overwritten: $overwritten, Skipped/Identical: $skipped"

  # ---- Prune (must run BEFORE manifest_generate) ----
  # Why this order: prune compares the OLD manifest (from the previous
  # install/update — recording what was tracked before this run) against the
  # NEW template's file list. If we regenerated the manifest first, the old
  # tracked files would be lost and prune would have nothing to compare.
  if [[ "$PRUNE_MODE" == "true" ]]; then
    local snapshot=""
    local live_mf
    live_mf=$(manifest_path "$PWD")
    if [[ -f "$live_mf" ]]; then
      snapshot=$(mktemp)
      cp "$live_mf" "$snapshot"
    fi
    prune_impl "$PWD" "$TEMPLATE_DIR" "$PRUNE_CONFIRM" "$snapshot"
    [[ -n "$snapshot" && -f "$snapshot" ]] && rm -f "$snapshot"
  fi

  # Refresh manifest so it reflects post-merge (and post-prune) state
  manifest_generate "$PWD" "$TEMPLATE_DIR"
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
    merge|update)
      shift
      parse_flags "$@"
      cmd_merge
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

# Only invoke main when executed directly. Tests can source this file with
# REIN_SOURCED=1 to load all functions without triggering main.
if [[ "${REIN_SOURCED:-0}" != "1" ]]; then
  main "$@"
fi
