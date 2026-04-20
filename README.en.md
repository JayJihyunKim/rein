# Rein — AI Native Development Framework

> Rein in your AI — Rules, gates, and hooks to keep AI agents consistent and accountable.

**[한국어](README.md)** | English

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Why Rein?

AI coding assistants (Claude Code, Cursor, Copilot, etc.) are powerful but **inconsistent**. They give different answers to the same question, forget project rules, and modify code without review.

Rein solves this with **rule files + automatic gates + lifecycle hooks**:

| | AI Assisted (Traditional) | AI Native (Rein) |
|---|---|---|
| How you instruct | "Write this function like this" | "Run this workflow" |
| Quality standards | In developer's head | In files (AGENTS.md, rules/) |
| When it fails | Re-prompt the output | Fix the **system** (rule files) |
| Scalability | Human intervenes every time | Quality improves as rules accumulate |

## Key Features

### 1. Definition of Done (DoD) Gate

Forces a **completion criteria file** before any source code edit. If you try to modify code without a DoD file, the hook blocks it.

```
trail/dod/dod-2026-04-16-auth-refactor.md  ← Write this first
src/auth.ts                                 ← Then you can edit
```

### 2. Mandatory Code Review

After implementation, code review is required before tests or commits are allowed. Running `git commit` or `pytest` without a review stamp is blocked.

### 3. Evidence Store (trail/)

Session records accumulate and rotate automatically:

```
trail/
├── inbox/          ← Today's completed work logs
├── daily/          ← Auto-merged after 7 days
├── weekly/         ← Auto-merged after 4 weeks
├── dod/            ← Definition of Done files
├── incidents/      ← Hook block logs + auto-aggregation
└── index.md        ← Current project state (5-15 lines)
```

### 4. Smart Router

Automatically recommends the best combination of agents, skills, and MCPs based on task type.

### 5. Self-Evolving Rules

When the same problem repeats, it **automatically promotes to a rule**:
- 2 occurrences → `incidents-to-rule` generates an AGENTS.md rule candidate
- 3 occurrences → `incidents-to-agent` generates an agent candidate

### 6. CLI Self-Update

Running `rein update` updates both template files **and the CLI itself** to the latest version. No sudo required.

---

## Supported platforms

| Platform | Status | Notes |
|----------|--------|-------|
| macOS | ✅ Official | |
| Linux | ✅ Official | |
| Windows (WSL2) | ✅ Official | See "Windows users" below |
| Windows (Git Bash / MSYS2) | ⚠️ Best-effort | Not part of the regular test matrix |
| Windows (PowerShell / CMD native) | ❌ Unsupported | Hooks assume POSIX bash + GNU coreutils |

### Windows users

Rein's hooks rely on bash + GNU coreutils, and a few Python scripts use POSIX-only APIs (`fcntl` for file locking). On Windows, **use WSL2 (Ubuntu)**.

**Install WSL2** (open PowerShell as **Administrator**):

```powershell
wsl --install
```

- One-liner on Windows 10 2004 (build 19041) or later, and Windows 11
- Ubuntu is installed as the default distribution and prompts for a username on first boot
- Reboot, then run `wsl` again to enter the Ubuntu shell

Then install Rein the same way as on Linux:

```bash
# Prerequisites (usually preinstalled on Ubuntu)
sudo apt update && sudo apt install -y git curl python3

# Install Rein
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
source ~/.rein/env
rein --version
```

Keep your project checkouts under `~/` (the WSL filesystem). Working from `/mnt/c/...` (the Windows filesystem) is functional but noticeably slower for disk I/O.

More details in Microsoft's docs: [aka.ms/wsl-install](https://aka.ms/wsl-install).

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
```

Installs to `$HOME/.rein/bin/rein`. **No sudo required.** After installation:

```bash
source ~/.rein/env
rein --version
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `rein new <project>` | Create a new project from template. Copies `.claude/`, `trail/`, `AGENTS.md` with `{{PROJECT_NAME}}` substitution |
| `rein merge` | Merge template into existing project. Prompts `[overwrite / skip / diff]` on conflicts |
| `rein update` | Update project from latest template. Skips identical files. Includes CLI self-update |
| `rein update --yes` | Auto-approve all prompts (CI-friendly) |
| `rein update --prune` | Detect files removed from template (dry-run) |
| `rein update --prune --confirm` | Actually delete deprecated files (creates backup first) |
| `rein --version` | Print version |
| `rein --help` | Show help |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `REIN_TEMPLATE_REPO` | Template Git repo URL | `git@github.com:JayJihyunKim/rein.git` |
| `REIN_BUDGET_BYTES` | Trail loading budget at session start | `65536` |

## Project Structure

```
repo/
├── AGENTS.md                    ← Global execution rules
├── .claude/
│   ├── CLAUDE.md                ← Entry point + @import hub
│   ├── settings.json            ← Hook + permission config
│   ├── orchestrator.md          ← Smart router criteria
│   ├── rules/                   ← Code style, testing, security rules
│   ├── hooks/                   ← Lifecycle automation scripts
│   ├── agents/                  ← Role-specific agent definitions
│   ├── skills/                  ← On-demand skills
│   └── workflows/               ← Task-type procedures
├── trail/                       ← Evidence store
├── REIN_SETUP_GUIDE.md          ← Detailed setup guide
└── install.sh                   ← CLI installer
```

## Quick Start

```bash
# 1. Create project
rein new my-project && cd my-project && git init

# 2. Write current project state in trail/index.md
# 3. Customize AGENTS.md for your project

# 4. Run Claude Code — Rein automatically guides the workflow
claude
```

> For detailed customization, see [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md).

## Included Skills

| Skill | Role |
|-------|------|
| `brainstorming` | Rein-native brainstorming. Validates feasibility/compatibility against the existing system before converging on options; writes artifacts to `docs/superpowers/brainstorms/`. Takes precedence over `superpowers:brainstorming`. |
| `writing-plans` | Converts a design/spec into an implementation plan with coverage matrix + `covers:` tags. Rein-native; takes precedence over `superpowers:writing-plans`. |
| `codex` | Two modes: `/codex review` (code review, stamp, severity escalation, Sonnet fallback) and `/codex ask` (second opinion — stamp-less, always a new session, no `resume --last`). |
| `repo-audit` | Repository health check (stale rules, missing tests) |
| `incidents-to-rule` | Repeated failures → auto-generate AGENTS.md rule candidates |
| `incidents-to-agent` | Repeated patterns → generate agent candidates |
| `promote-agent` | Promote agent candidate to active agent |
| `changelog-writer` | Auto-generate CHANGELOG from Git history |
| `pr-review-fixer` | Auto-apply PR review comments |

**Stitch UI Design Skills** (requires Stitch MCP):

| Skill | Role |
|-------|------|
| `stitch-design` | Design system management + prompt enhancement |
| `stitch-loop` | Multi-page auto-generation |
| `enhance-prompt` | Vague UI requests → precise prompts |
| `react-components` | Design → React component conversion |

> Stitch skills load on-demand and don't consume context when unused.

## Compatibility Notes

### `everything-claude-code` Plugin

The `gateguard-fact-force` hook in `everything-claude-code` (>= 1.9.0) is incompatible with Rein. Installing both causes all Edit/Write/Bash operations to deadlock. Rein already provides equivalent functionality — remove the plugin.

### Upgrading from v0.6.x

Starting with v0.7.0, the CLI install path changed from `/usr/local/bin/rein` to `$HOME/.rein/bin/rein`. Run [install.sh](install.sh) once to migrate. After that, `rein update` handles self-updates automatically.

## Version History

### v0.10.0 (2026-04-20) — rein-native brainstorming + /codex ask + tests CI + incident classifier
- New rein-native `brainstorming` skill — validates feasibility/compatibility against the existing system before converging on options (artifacts under `docs/superpowers/brainstorms/`)
- Split `/codex` into `/codex review` (Mode A, review stamp) and `/codex ask` (Mode B, second opinion, stamp-less, no `resume --last`)
- New `.github/workflows/tests.yml` — runs the full hook + script suites on push/PR across ubuntu + macOS (windows advisory). Maintainer-only (rein-dev)
- New incident `agent_eligible` classification — `/incidents-to-agent` now auto-excludes hook-source bug patterns (`false`)
- Router excludes `superpowers:brainstorming` / `superpowers:writing-plans` by id prefix so rein-native skills take precedence
- Details: [CHANGELOG](CHANGELOG.md)

### v0.9.1 (2026-04-20) — hotfix: `rein merge` hook exec bit propagation
- `scripts/rein.sh:copy_file()` now propagates the src exec bit onto pre-existing dst files when needed (preserves already-correct 755 files; no downgrade)

### v0.9.0 (2026-04-20) — cross-platform portability + Windows WSL2 guidance
- Fixed `file_size()` in `session-start-load-trail.sh` breaking on Linux (GNU `stat -f` returns exit 0 in filesystem-info mode, so the `||` fallback never fired)
- Consolidated BSD/GNU dispatch helpers into `.claude/hooks/lib/portable.sh` (removed duplicated `_mtime`/`_mtime_date`/`file_size` copies)
- Added `.gitattributes` to force LF line endings — protects shebang hooks on Windows checkouts
- Declared supported platforms: macOS / Linux / Windows via WSL2. README now includes a WSL2 installation walkthrough.

### v0.7.5 (2026-04-19)
- Smart router enforcement — new DoDs require a `## 라우팅 추천` section + explicit user approval (hook blocks edits when missing)
- Skill/MCP guide auto-generation script added

### v0.7.4 (2026-04-19)
- Design → Plan scope coverage tracking — scope items dropped during plan transition are detected at plan-edit time

### v0.7.3 (2026-04-19)
- Hook safety hardening (critical security fix) — `exit 0` fail-open on missing `python3` / parse failure replaced with fail-closed behavior

### v0.7.2 (2026-04-19)
- Incidents semi-automation — recurring failure patterns detected at session end and routed to rule / agent promotion flow

### v0.7.1 (2026-04-17)
- Public release prep (English README, MIT license, public mirror workflow)

### v0.7.0 (2026-04-16)
- CLI install path moved to `$HOME/.rein/bin/rein` (no more sudo)
- New `install.sh` installer + CLI self-update
- `SOT/` renamed to `trail/`

### v0.6.0 (2026-04-15)
- Auto-load trail context at session start (SessionStart hook)
- Design document review enforcement gate
- Incidents auto-aggregation (JSONL + Python)
- Skill/MCP inventory auto-scan

### v0.5.0 (2026-04-15)
- Manifest-based file tracking + `--prune` support
- Symlink / path traversal security hardening

### v0.4.x (2026-04-15)
- Mandatory code review + escalation rules
- Stop-session-gate deadlock resolution
- Linux/macOS stat compatibility fix
- Commit message validation improvements

### v0.3.0
- Smart router introduction

### v0.2.0 (2026-04-09)
- Security layer (per-project security levels)

### v0.1.0
- Initial release: CLI, DoD gate, stop-session gate, inbox rotation

## Contributing

Issues and PRs are welcome. Please review [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) to understand the framework structure before contributing.

## License

MIT License. See [LICENSE](LICENSE) for details.

## References

- [agentsmd/agents.md](https://agents.md) — AGENTS.md hierarchy
- [getsentry/sentry](https://github.com/getsentry/sentry) — Real-world AGENTS.md example
- [anthropics/skills](https://github.com/anthropics/skills) — Skill definitions
