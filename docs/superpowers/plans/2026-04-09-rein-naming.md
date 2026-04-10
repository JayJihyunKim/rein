# Rein Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the project from `claude-code-ai-native` / `claude-init` to `Rein` across all user-facing surfaces (CLI, README, docs, tests).

**Architecture:** File rename (`claude-init.sh` → `rein.sh`) + string replacement across 4 files. Internal system files (`.claude/`, `AGENTS.md`, hooks) are untouched. The CLI script adds backward-compatible fallback for the old `CLAUDE_TEMPLATE_REPO` env var.

**Tech Stack:** Bash (CLI script), Markdown (docs)

---

### Task 1: Rename CLI script and update internal references

**Files:**
- Create: `scripts/rein.sh` (copy from `scripts/claude-init.sh` with modifications)
- Delete: `scripts/claude-init.sh`

- [ ] **Step 1: Create `scripts/rein.sh` from `scripts/claude-init.sh` with all references updated**

Copy `scripts/claude-init.sh` to `scripts/rein.sh` and apply these changes:

Line 20 — default repo URL and env var (with backward compat):
```bash
TEMPLATE_REPO="${REIN_TEMPLATE_REPO:-${CLAUDE_TEMPLATE_REPO:-git@github.com:JayJihyunKim/rein.git}}"
```

Lines 281-291 — usage text:
```bash
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
```

Line 407 — error message for missing project name:
```bash
        echo "Usage: rein new <project-name>" >&2
```

Line 419 — version output:
```bash
      echo "rein $VERSION"
```

- [ ] **Step 2: Make the new script executable**

Run: `chmod +x scripts/rein.sh`

- [ ] **Step 3: Verify the script works**

Run: `scripts/rein.sh --help`
Expected: Usage text with `rein` commands

Run: `scripts/rein.sh --version`
Expected: `rein 0.1.0`

- [ ] **Step 4: Delete old script via git**

Run: `git rm scripts/claude-init.sh`

- [ ] **Step 5: Commit**

```bash
git add scripts/rein.sh
git commit -m "feat: rename claude-init CLI to rein"
```

---

### Task 2: Update test file

**Files:**
- Create: `tests/rein-test.sh` (copy from `tests/claude-init-test.sh` with modifications)
- Delete: `tests/claude-init-test.sh`

- [ ] **Step 1: Create `tests/rein-test.sh` from `tests/claude-init-test.sh` with references updated**

Line 5 — script path:
```bash
CLAUDE_INIT="$SCRIPT_DIR/scripts/rein.sh"
```

Note: The variable name `CLAUDE_INIT` is internal to the test and does not affect users. Rename it to `REIN_CLI` for consistency:

All occurrences of `CLAUDE_INIT` → `REIN_CLI`:
```bash
REIN_CLI="$SCRIPT_DIR/scripts/rein.sh"
```

And all `"$CLAUDE_INIT"` → `"$REIN_CLI"` throughout the file.

Line 117 — version assertion:
```bash
assert_contains "--version output contains 'rein'" "rein" "$version_output"
```

- [ ] **Step 2: Make the test executable**

Run: `chmod +x tests/rein-test.sh`

- [ ] **Step 3: Run the tests**

Run: `tests/rein-test.sh`
Expected: All tests pass with `rein` references

- [ ] **Step 4: Delete old test file via git**

Run: `git rm tests/claude-init-test.sh`

- [ ] **Step 5: Commit**

```bash
git add tests/rein-test.sh
git commit -m "test: rename claude-init tests to rein"
```

---

### Task 3: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README.md with new branding**

Line 1 — title:
```markdown
# Rein — AI Native Development Framework
```

Line 3 — description:
```markdown
> Rein in your AI — 규칙·게이트·훅으로 AI의 고삐를 쥐는 프레임워크
```

Remove old line 3 (`이 저장소는 **AI Native** 방식으로 Claude Code를 운영하기 위한 템플릿입니다.`).

Line 46 — install command:
```bash
gh api repos/JayJihyunKim/rein/contents/scripts/rein.sh --jq '.content' | base64 -d | sudo tee /usr/local/bin/rein > /dev/null && sudo chmod +x /usr/local/bin/rein
```

Lines 54-55 — new project:
```bash
rein new my-project
cd my-project && git init
```

Line 58 — description:
```
템플릿의 `.claude/`, `SOT/`, `AGENTS.md`가 자동으로 복사되고 `{{PROJECT_NAME}}`이 프로젝트명으로 치환됩니다.
```
(This line stays the same — no `claude-init` reference.)

Lines 64-65 — merge:
```bash
cd existing-project
rein merge
```

Lines 73-74 — update:
```bash
cd existing-project
rein update
```

Lines 80-82 — environment variables table:
```markdown
| 변수 | 설명 | 기본값 |
|------|------|--------|
| `REIN_TEMPLATE_REPO` | 템플릿 Git 레포 URL | `git@github.com:JayJihyunKim/rein.git` |
| `CLAUDE_TEMPLATE_REPO` | (deprecated) `REIN_TEMPLATE_REPO`의 별칭 | — |
```

Lines 85-87 — custom repo example:
```bash
REIN_TEMPLATE_REPO="git@github.com:my-org/my-template.git" rein new my-project
```

- [ ] **Step 2: Verify README renders correctly**

Run: `head -10 README.md`
Expected: New title and tagline visible

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README with Rein branding"
```

---

### Task 4: Update SETUP_GUIDE.md

**Files:**
- Modify: `docs/SETUP_GUIDE.md`

- [ ] **Step 1: Update all references in SETUP_GUIDE.md**

Line 3 — description:
```markdown
> 이 문서는 Rein 프레임워크를 새 프로젝트에 적용하는 방법을 설명합니다.
```

Line 48 — gh repo create template:
```bash
  --template JayJihyunKim/rein \
```

Line 58 — clone command:
```bash
gh repo clone JayJihyunKim/rein /tmp/rein-template
```

Lines 60-64 — copy commands (update source path):
```bash
cp -r /tmp/rein-template/.claude  /path/to/your-project/
cp -r /tmp/rein-template/SOT     /path/to/your-project/
cp -r /tmp/rein-template/.github /path/to/your-project/
cp    /tmp/rein-template/AGENTS.md /path/to/your-project/
```

Line 67 — gitignore:
```bash
cat /tmp/rein-template/.gitignore >> /path/to/your-project/.gitignore
```

Line 70 — cleanup:
```bash
rm -rf /tmp/rein-template
```

Line 78 — git remote:
```bash
git remote add template git@github.com:JayJihyunKim/rein.git
```

- [ ] **Step 2: Verify the guide is consistent**

Run: `grep -c "claude-code-ai-native\|claude-init" docs/SETUP_GUIDE.md`
Expected: `0` (no old references remain)

- [ ] **Step 3: Commit**

```bash
git add docs/SETUP_GUIDE.md
git commit -m "docs: update SETUP_GUIDE with Rein branding"
```

---

### Task 5: Manual step — GitHub repo rename

This task is performed by the user in the browser, not by code.

- [ ] **Step 1: Document the manual step**

After all code changes are merged, the user should:
1. Go to GitHub → `JayJihyunKim/claude-code-ai-native` → Settings → General
2. Change "Repository name" to `rein`
3. Update local remote: `git remote set-url origin git@github.com:JayJihyunKim/rein.git`

Note: GitHub automatically redirects old URLs, so existing clones and links will continue to work.
