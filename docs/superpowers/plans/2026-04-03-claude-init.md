# claude-init Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single shell script (`scripts/claude-init.sh`) that copies the Claude Code template from a Git repo into new or existing projects, with interactive conflict resolution and `{{PROJECT_NAME}}` substitution.

**Architecture:** One self-contained bash script with functions for clone, copy, conflict prompt, and variable substitution. Three subcommands (`new`, `merge`, `update`) share the same copy/substitute core. `merge` and `update` are aliases internally.

**Tech Stack:** Bash, git, sed, diff, mktemp

---

## File Structure

| File | Responsibility |
|------|---------------|
| `scripts/claude-init.sh` | The entire CLI tool — argument parsing, clone, copy, conflict prompt, variable substitution |
| `tests/claude-init-test.sh` | Integration test script exercising `new`, `merge`, `update` flows in temp directories |

---

### Task 1: Script Skeleton + Argument Parsing

**Files:**
- Create: `scripts/claude-init.sh`

- [ ] **Step 1: Create the script with usage and argument parsing**

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
TEMPLATE_REPO="${CLAUDE_TEMPLATE_REPO:-https://github.com/JayJihyunKim/claude-code-ai-native.git}"

usage() {
  cat <<'EOF'
Usage:
  claude-init new <project-name>   Create a new project from template
  claude-init merge                Merge template into current project
  claude-init update               Update current project from template
  claude-init --version            Show version
  claude-init --help               Show this help

Environment:
  CLAUDE_TEMPLATE_REPO   Override template repository URL
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    new)
      if [[ $# -lt 2 ]]; then
        echo "Error: project name required" >&2
        echo "Usage: claude-init new <project-name>" >&2
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
      echo "claude-init $VERSION"
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Error: unknown command '$1'" >&2
      usage
      exit 1
      ;;
  esac
}

cmd_new() {
  echo "TODO: new $1"
}

cmd_merge() {
  echo "TODO: merge"
}

main "$@"
```

- [ ] **Step 2: Make it executable and verify argument parsing**

Run:
```bash
chmod +x scripts/claude-init.sh
scripts/claude-init.sh --help
scripts/claude-init.sh --version
scripts/claude-init.sh new 2>&1 || true
scripts/claude-init.sh bogus 2>&1 || true
```

Expected:
- `--help` prints usage text
- `--version` prints `claude-init 0.1.0`
- `new` without args prints error + usage, exits 1
- `bogus` prints error + usage, exits 1

- [ ] **Step 3: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: claude-init script skeleton with argument parsing"
```

---

### Task 2: Clone Helper + Cleanup Trap

**Files:**
- Modify: `scripts/claude-init.sh`

- [ ] **Step 1: Add clone_template and cleanup functions**

Insert after the `TEMPLATE_REPO` line, before `usage()`:

```bash
TMPDIR_PATH=""

cleanup() {
  if [[ -n "$TMPDIR_PATH" && -d "$TMPDIR_PATH" ]]; then
    rm -rf "$TMPDIR_PATH"
  fi
}

clone_template() {
  TMPDIR_PATH="$(mktemp -d)"
  trap cleanup EXIT

  echo "Cloning template from $TEMPLATE_REPO..."
  if ! git clone --depth 1 --quiet "$TEMPLATE_REPO" "$TMPDIR_PATH/template" 2>/dev/null; then
    echo "Error: failed to clone $TEMPLATE_REPO" >&2
    exit 1
  fi

  echo "$TMPDIR_PATH/template"
}
```

- [ ] **Step 2: Verify clone works**

Run:
```bash
source <(sed -n '/^clone_template/,/^}/p' scripts/claude-init.sh)
```

Or simpler — temporarily add a test call in `cmd_new`:

Replace `cmd_new` body:
```bash
cmd_new() {
  local project_name="$1"
  local template_dir
  template_dir="$(clone_template)"
  echo "Cloned to: $template_dir"
  ls "$template_dir/.claude" | head -5
}
```

Run:
```bash
scripts/claude-init.sh new test-verify
```

Expected: prints "Cloned to: /tmp/..." and lists files from `.claude/`. Cleanup removes temp dir on exit.

- [ ] **Step 3: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: add clone_template helper with cleanup trap"
```

---

### Task 3: Copy Logic with Include/Exclude

**Files:**
- Modify: `scripts/claude-init.sh`

- [ ] **Step 1: Add the file list generator function**

Insert after `clone_template()`:

```bash
# Files and directories to copy from template
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
  "AGENTS.md"
)

# SOT subdirectories — only create structure + .gitkeep
SOT_DIRS=(
  "SOT/inbox"
  "SOT/daily"
  "SOT/weekly"
  "SOT/decisions"
  "SOT/dod"
  "SOT/incidents"
  "SOT/agent-candidates"
)

# Generate flat list of files to copy from template_dir
# Output: relative paths (one per line)
list_copy_files() {
  local template_dir="$1"

  for target in "${COPY_TARGETS[@]}"; do
    local full_path="$template_dir/$target"
    if [[ -f "$full_path" ]]; then
      echo "$target"
    elif [[ -d "$full_path" ]]; then
      find "$full_path" -type f \
        ! -name '.DS_Store' \
        | while read -r f; do
          echo "${f#$template_dir/}"
        done
    fi
  done
}
```

- [ ] **Step 2: Add the copy_file helper**

```bash
# Copy a single file from template to destination, creating parent dirs
copy_file() {
  local template_dir="$1"
  local dest_dir="$2"
  local rel_path="$3"

  local src="$template_dir/$rel_path"
  local dst="$dest_dir/$rel_path"

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}
```

- [ ] **Step 3: Add the SOT scaffolding function**

```bash
# Create SOT directory structure with .gitkeep files and index.md
scaffold_sot() {
  local dest_dir="$1"
  local template_dir="$2"

  for sot_dir in "${SOT_DIRS[@]}"; do
    mkdir -p "$dest_dir/$sot_dir"
    touch "$dest_dir/$sot_dir/.gitkeep"
  done

  # Copy index.md from template if it exists
  if [[ -f "$template_dir/SOT/index.md" ]]; then
    copy_file "$template_dir" "$dest_dir" "SOT/index.md"
  fi
}
```

- [ ] **Step 4: Verify list_copy_files output**

Temporarily wire into `cmd_new`:
```bash
cmd_new() {
  local project_name="$1"
  local template_dir
  template_dir="$(clone_template)"
  echo "=== Files to copy ==="
  list_copy_files "$template_dir" | head -20
  echo "..."
  echo "Total: $(list_copy_files "$template_dir" | wc -l) files"
}
```

Run:
```bash
scripts/claude-init.sh new test-verify
```

Expected: list of relative paths like `.claude/CLAUDE.md`, `.claude/hooks/pre-bash-guard.sh`, etc. No `.DS_Store` files. No `SOT/inbox/` data files. No `.claude/plans/` files.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: add copy logic with include/exclude lists"
```

---

### Task 4: Interactive Conflict Prompt

**Files:**
- Modify: `scripts/claude-init.sh`

- [ ] **Step 1: Add the conflict prompt function**

Insert after `copy_file()`:

```bash
# Global flag for "all-overwrite" mode
ALL_OVERWRITE=false

# Prompt user for conflict resolution
# Returns: "overwrite", "skip", or "quit"
prompt_conflict() {
  local rel_path="$1"
  local template_dir="$2"
  local dest_dir="$3"

  if [[ "$ALL_OVERWRITE" == true ]]; then
    echo "overwrite"
    return
  fi

  while true; do
    echo ""
    echo "File exists: $rel_path"
    read -r -p "  [o]verwrite  [s]kip  [d]iff  [a]ll-overwrite  [q]uit  → " choice </dev/tty

    case "$choice" in
      o|O)
        echo "overwrite"
        return
        ;;
      s|S)
        echo "skip"
        return
        ;;
      d|D)
        echo ""
        diff --color "$dest_dir/$rel_path" "$template_dir/$rel_path" || true
        # After showing diff, ask again (only o/s)
        echo ""
        read -r -p "  [o]verwrite  [s]kip  → " choice2 </dev/tty
        case "$choice2" in
          o|O) echo "overwrite"; return ;;
          *)   echo "skip"; return ;;
        esac
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
        echo "  Invalid choice. Try again."
        ;;
    esac
  done
}
```

- [ ] **Step 2: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: add interactive conflict prompt for merge/update"
```

---

### Task 5: Variable Substitution

**Files:**
- Modify: `scripts/claude-init.sh`

- [ ] **Step 1: Add the substitute function**

Insert after `prompt_conflict()`:

```bash
# Replace {{PROJECT_NAME}} in all .md files under dest_dir
substitute_vars() {
  local dest_dir="$1"
  local project_name="$2"

  find "$dest_dir" -name '*.md' -type f -exec \
    sed -i '' "s/{{PROJECT_NAME}}/$project_name/g" {} +

  echo "Substituted {{PROJECT_NAME}} → $project_name"
}
```

Note: `sed -i ''` is macOS syntax. For Linux compatibility, detect OS:

```bash
substitute_vars() {
  local dest_dir="$1"
  local project_name="$2"

  local sed_flag="-i"
  if [[ "$(uname)" == "Darwin" ]]; then
    sed_flag="-i ''"
  fi

  find "$dest_dir" -name '*.md' -type f -print0 | while IFS= read -r -d '' file; do
    if grep -q '{{PROJECT_NAME}}' "$file"; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/{{PROJECT_NAME}}/$project_name/g" "$file"
      else
        sed -i "s/{{PROJECT_NAME}}/$project_name/g" "$file"
      fi
    fi
  done

  echo "Substituted {{PROJECT_NAME}} → $project_name"
}
```

- [ ] **Step 2: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: add PROJECT_NAME variable substitution"
```

---

### Task 6: Wire Up `new` Command

**Files:**
- Modify: `scripts/claude-init.sh`

- [ ] **Step 1: Implement cmd_new**

Replace the stub `cmd_new` with:

```bash
cmd_new() {
  local project_name="$1"
  local dest_dir
  dest_dir="$(pwd)/$project_name"

  if [[ -d "$dest_dir" ]]; then
    echo "Error: directory '$project_name' already exists" >&2
    exit 1
  fi

  local template_dir
  template_dir="$(clone_template)"

  echo "Creating project: $project_name"
  mkdir -p "$dest_dir"

  # Copy all template files
  local count=0
  while IFS= read -r rel_path; do
    copy_file "$template_dir" "$dest_dir" "$rel_path"
    count=$((count + 1))
  done < <(list_copy_files "$template_dir")

  # Scaffold SOT directories
  scaffold_sot "$dest_dir" "$template_dir"

  # Substitute variables
  substitute_vars "$dest_dir" "$project_name"

  echo ""
  echo "Done! Created $count files in $project_name/"
  echo ""
  echo "Next steps:"
  echo "  cd $project_name"
  echo "  git init"
}
```

- [ ] **Step 2: Test the new command end-to-end**

Run:
```bash
cd /tmp
scripts/claude-init.sh new my-test-project
```

Expected:
- Directory `/tmp/my-test-project` created
- `.claude/CLAUDE.md` exists
- `.claude/hooks/pre-edit-dod-gate.sh` exists
- `.claude/skills/` populated
- `SOT/inbox/.gitkeep` exists
- `AGENTS.md` exists
- No `.claude/settings.local.json`
- No `SOT/inbox/` data files

Verify:
```bash
ls my-test-project/.claude/
ls my-test-project/.claude/hooks/
ls my-test-project/.claude/skills/
ls my-test-project/SOT/
ls my-test-project/SOT/inbox/
cat my-test-project/AGENTS.md | head -3
rm -rf my-test-project
```

- [ ] **Step 3: Test error case — directory already exists**

Run:
```bash
cd /tmp && mkdir exists-test
scripts/claude-init.sh new exists-test 2>&1 || true
rm -rf exists-test
```

Expected: `Error: directory 'exists-test' already exists`, exit 1

- [ ] **Step 4: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: implement 'new' command"
```

---

### Task 7: Wire Up `merge`/`update` Command

**Files:**
- Modify: `scripts/claude-init.sh`

- [ ] **Step 1: Implement cmd_merge**

Replace the stub `cmd_merge` with:

```bash
cmd_merge() {
  local dest_dir
  dest_dir="$(pwd)"

  if [[ ! -d "$dest_dir/.git" ]]; then
    echo "Error: not a git repository. Run this from your project root." >&2
    exit 1
  fi

  local project_name
  project_name="$(basename "$dest_dir")"

  local template_dir
  template_dir="$(clone_template)"

  echo "Merging template into: $project_name"
  echo ""

  # Reset all-overwrite flag
  ALL_OVERWRITE=false

  # Copy template files with conflict detection
  local added=0
  local overwritten=0
  local skipped=0

  while IFS= read -r rel_path; do
    local dst="$dest_dir/$rel_path"
    if [[ -f "$dst" ]]; then
      if diff -q "$dst" "$template_dir/$rel_path" >/dev/null 2>&1; then
        skipped=$((skipped + 1))
        continue  # identical
      fi
      local action
      action="$(prompt_conflict "$rel_path" "$template_dir" "$dest_dir")"
      case "$action" in
        overwrite)
          copy_file "$template_dir" "$dest_dir" "$rel_path"
          echo "  Overwritten: $rel_path"
          overwritten=$((overwritten + 1))
          ;;
        skip)
          echo "  Skipped: $rel_path"
          skipped=$((skipped + 1))
          ;;
        quit)
          echo ""
          echo "Aborted. Files processed so far are kept."
          exit 0
          ;;
      esac
    else
      copy_file "$template_dir" "$dest_dir" "$rel_path"
      echo "  Added: $rel_path"
      added=$((added + 1))
    fi
  done < <(list_copy_files "$template_dir")

  # Scaffold missing SOT directories
  scaffold_sot "$dest_dir" "$template_dir"

  # Substitute variables
  substitute_vars "$dest_dir" "$project_name"

  echo ""
  echo "Done! Added: $added, Overwritten: $overwritten, Skipped/Identical: $skipped"
}
```

- [ ] **Step 2: Test merge into an existing project**

Run:
```bash
cd /tmp && mkdir merge-test && cd merge-test && git init
# Run merge — should add all files without prompts (no conflicts)
/Users/jihyun/Local_Projects/claude-code-ai-native/scripts/claude-init.sh merge
```

Expected: all files added, no conflict prompts, summary shows added count.

Verify:
```bash
ls .claude/hooks/
ls .claude/skills/
ls SOT/inbox/
cd /tmp && rm -rf merge-test
```

- [ ] **Step 3: Test merge with conflicts**

Run:
```bash
cd /tmp && mkdir conflict-test && cd conflict-test && git init
mkdir -p .claude/rules
echo "# custom rules" > .claude/rules/code-style.md
# Run merge — should prompt for code-style.md
/Users/jihyun/Local_Projects/claude-code-ai-native/scripts/claude-init.sh merge
# When prompted, test [d]iff then [s]kip
```

Expected: diff shown for `code-style.md`, skip preserves custom content, other files added.

```bash
cat .claude/rules/code-style.md  # should still say "# custom rules"
cd /tmp && rm -rf conflict-test
```

- [ ] **Step 4: Test not-a-repo error**

Run:
```bash
cd /tmp && mkdir not-repo && cd not-repo
/Users/jihyun/Local_Projects/claude-code-ai-native/scripts/claude-init.sh merge 2>&1 || true
cd /tmp && rm -rf not-repo
```

Expected: `Error: not a git repository`, exit 1

- [ ] **Step 5: Test update (alias for merge)**

Run:
```bash
cd /tmp && mkdir update-test && cd update-test && git init
/Users/jihyun/Local_Projects/claude-code-ai-native/scripts/claude-init.sh merge
# Now run update — all files identical, should be silent
/Users/jihyun/Local_Projects/claude-code-ai-native/scripts/claude-init.sh update
```

Expected: second run shows `Added: 0, Overwritten: 0, Skipped/Identical: N` (all identical).

```bash
cd /tmp && rm -rf update-test
```

- [ ] **Step 6: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: implement 'merge' and 'update' commands"
```

---

### Task 8: Integration Test Script

**Files:**
- Create: `tests/claude-init-test.sh`

- [ ] **Step 1: Write the test script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_INIT="$SCRIPT_DIR/scripts/claude-init.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_exists() {
  local desc="$1" path="$2"
  if [[ -d "$path" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (dir not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file should not exist: $path)"
    FAIL=$((FAIL + 1))
  fi
}

# ---- Test: --help ----
echo "Test: --help"
output="$("$CLAUDE_INIT" --help 2>&1)"
assert_eq "help contains 'Usage'" "0" "$(echo "$output" | grep -c 'Usage'  | grep -v '^0$' | wc -l | tr -d ' ')"

# ---- Test: --version ----
echo "Test: --version"
output="$("$CLAUDE_INIT" --version 2>&1)"
assert_eq "version output" "1" "$(echo "$output" | grep -c 'claude-init')"

# ---- Test: new ----
echo "Test: new command"
cd "$TEST_DIR"
"$CLAUDE_INIT" new test-project
P="$TEST_DIR/test-project"
assert_file_exists "CLAUDE.md copied" "$P/.claude/CLAUDE.md"
assert_file_exists "AGENTS.md copied" "$P/AGENTS.md"
assert_file_exists "hooks copied" "$P/.claude/hooks/pre-edit-dod-gate.sh"
assert_dir_exists "skills dir exists" "$P/.claude/skills"
assert_dir_exists "SOT/inbox exists" "$P/SOT/inbox"
assert_file_exists "SOT .gitkeep" "$P/SOT/inbox/.gitkeep"
assert_file_missing "no settings.local.json" "$P/.claude/settings.local.json"
assert_file_missing "no plans dir content" "$P/.claude/plans"

# ---- Test: new fails if dir exists ----
echo "Test: new fails if dir exists"
result=0
"$CLAUDE_INIT" new test-project 2>/dev/null || result=$?
assert_eq "exit code 1" "1" "$result"

# ---- Test: merge ----
echo "Test: merge command"
mkdir -p "$TEST_DIR/merge-project" && cd "$TEST_DIR/merge-project" && git init -q
"$CLAUDE_INIT" merge
assert_file_exists "merge: CLAUDE.md" "$TEST_DIR/merge-project/.claude/CLAUDE.md"
assert_file_exists "merge: hooks" "$TEST_DIR/merge-project/.claude/hooks/pre-edit-dod-gate.sh"
assert_dir_exists "merge: SOT" "$TEST_DIR/merge-project/SOT/inbox"

# ---- Test: merge not-a-repo ----
echo "Test: merge fails outside git repo"
mkdir -p "$TEST_DIR/not-repo" && cd "$TEST_DIR/not-repo"
result=0
"$CLAUDE_INIT" merge 2>/dev/null || result=$?
assert_eq "exit code 1" "1" "$result"

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
```

- [ ] **Step 2: Run the test script**

Run:
```bash
chmod +x tests/claude-init-test.sh
tests/claude-init-test.sh
```

Expected: all tests pass.

- [ ] **Step 3: Fix any failures**

If any tests fail, fix the issue in `scripts/claude-init.sh` and re-run.

- [ ] **Step 4: Commit**

```bash
git add tests/claude-init-test.sh scripts/claude-init.sh
git commit -m "test: add integration tests for claude-init"
```

---

### Task 9: Final Polish + README

**Files:**
- Modify: `scripts/claude-init.sh` (add color output)

- [ ] **Step 1: Add color helpers at the top of the script**

Insert after `set -euo pipefail`:

```bash
# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

info()  { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
error() { echo -e "${RED}Error: $*${NC}" >&2; }
```

- [ ] **Step 2: Replace echo/error calls throughout the script**

Replace all `echo "Error:` with `error "`, `echo "Done!` with `info "Done!`, etc.

Key replacements:
- `echo "Error: directory..."` → `error "directory..."`
- `echo "Error: not a git..."` → `error "not a git..."`
- `echo "Error: failed to clone..."` → `error "failed to clone..."`
- `echo "Cloning template..."` → `info "Cloning template..."`
- `echo "Creating project:..."` → `info "Creating project:..."`
- `echo "Done!..."` → `info "Done!..."`
- `echo "  Added:..."` → `echo -e "  ${GREEN}Added${NC}: $rel_path"`
- `echo "  Overwritten:..."` → `echo -e "  ${YELLOW}Overwritten${NC}: $rel_path"`
- `echo "  Skipped:..."` → `echo -e "  Skipped: $rel_path"`

- [ ] **Step 3: Run tests again to verify nothing broke**

Run:
```bash
tests/claude-init-test.sh
```

Expected: all tests still pass.

- [ ] **Step 4: Commit**

```bash
git add scripts/claude-init.sh
git commit -m "feat: add colored terminal output"
```

- [ ] **Step 5: Run full end-to-end manual test**

Run:
```bash
cd /tmp
scripts/claude-init.sh new final-test
ls final-test/.claude/hooks/
ls final-test/.claude/skills/ | head -5
ls final-test/SOT/
rm -rf final-test
```

Expected: clean colored output, all files in place, SOT scaffolded.

- [ ] **Step 6: Final commit if any adjustments**

```bash
git add scripts/claude-init.sh tests/claude-init-test.sh
git commit -m "chore: final polish for claude-init v0.1.0"
```
