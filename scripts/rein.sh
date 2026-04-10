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

VERSION="0.3.0"
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
  "apps/web/AGENTS.md"
  "ml/AGENTS.md"
  "services/api/AGENTS.md"
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
# Interactive conflict resolution
# ---------------------------------------------------------------------------
ALL_OVERWRITE=false

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
  rein new <project-name>   Create a new project from template
  rein merge                Merge template into current project
  rein update               Update current project from template
  rein --version            Show version
  rein --help               Show this help

Environment:
  REIN_TEMPLATE_REPO       Override template repository URL
  CLAUDE_TEMPLATE_REPO     (deprecated) Alias for REIN_TEMPLATE_REPO
EOF
}

# ---------------------------------------------------------------------------
# cmd_new(project_name)
# ---------------------------------------------------------------------------
cmd_new() {
  local project_name="$1"
  local dest_dir="$project_name"

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

  ALL_OVERWRITE=false

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
}

# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------
main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    new)
      if [[ $# -lt 2 ]]; then
        error "project name required"
        echo "Usage: rein new <project-name>" >&2
        exit 1
      fi
      cmd_new "$2"
      ;;
    merge)
      cmd_merge
      ;;
    update)
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

main "$@"
