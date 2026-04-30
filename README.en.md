# Rein — AI Native Development Framework

> A repository scaffold for teams that let AI agents write code but don't want to rely on prompt discipline alone

**[한국어](README.md)** | English

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## What Rein does

Rein adds a small set of repo rules and automatic guardrails so your AI coding agent (currently Claude Code) has to **define the task first, leave an evidence trail, and pass review before code lands**.

**Use Rein if**:

- You maintain long-lived codebases
- Consistency of AI output matters more to your team than raw speed
- You want code review, evidence, and checkpoints **codified as team discipline**, not held in people's heads

**Don't use Rein if**:

- You write throwaway scripts or one-shot projects
- Your team doesn't want process files added to the repo
- You run outside POSIX bash / WSL2 (native Windows PowerShell unsupported)

> **Tool support**: Rein's automatic guardrails are built on Claude Code's hook lifecycle. The same concepts (AGENTS.md, rule files, review gates) work as **reference documents only** in Cursor / Copilot — there is no automatic blocking there.

---

## What changes in practice

**Without Rein — common pain**

```
Developer: "implement login"
   ↓
AI: writes code → git commit
   ↓
No review. No definition of done.
Next session has no trace of what was done and why.
```

**With Rein — same request**

```
Developer: "implement login"
   ↓
Rein: "First, write trail/dod/dod-2026-04-22-login.md with completion criteria."
   → AI writes the checklist (DoD file)
   ↓
AI edits code (allowed because the DoD exists)
   ↓
AI runs git commit
   → Rein: "No code review stamp. Blocked."
   → AI runs a review → stamp is created → commit allowed
   ↓
On session end, decisions and changes are logged to trail/inbox/.
The next session automatically loads this record into context.
```

---

## 4 core guarantees

### 1. Code cannot be edited before the task is defined

Before any source file edit, a **Definition of Done** file must exist. If you try to edit without one, the hook blocks the operation.

```
trail/dod/dod-2026-04-22-auth-refactor.md   ← write this first
src/auth.ts                                  ← then you can edit
```

### 2. Commits and tests are blocked until review runs

After implementation, `git commit` and `pytest` are blocked. They are only allowed after a code review produces a review-stamp file.

### 3. Evidence accumulates and rotates automatically

Session records pile up in `trail/` and older entries are auto-merged into weekly/monthly summaries. On the next session, the latest records are auto-loaded into the agent's context.

```
trail/
├── inbox/      ← today's completed work logs
├── daily/      ← auto-merged after 7 days
├── weekly/     ← auto-merged after 4 weeks
├── dod/        ← Definition of Done files
└── index.md    ← current project state (5-15 lines)
```

### 4. Updates are owned by Claude Code's plugin manager

Plugin updates run via `claude plugin update rein-core`. Your repo's hooks/skills/agents are owned by the plugin manifest, so updates do not touch user-modified files.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
```

Installs to `$HOME/.rein/bin/rein`. **No sudo required.**

```bash
source ~/.rein/env
rein --version
```

---

## Quick Start

```bash
# 1. Enter an existing git repo (rein init requires .git)
cd existing-project

# 2. rein init — install in plugin mode (the only install path)
rein init

# 3. Write current project state in trail/index.md (5-15 lines)

# 4. Customize AGENTS.md for your project

# 5. Run Claude Code — Rein automatically guides the workflow
claude
```

`rein init` runs in Claude Code plugin mode. The `rein-core` plugin published on Claude Code marketplace automatically fetches hooks/skills/agents; your repo only retains `.rein/project.json` and the plugin pin in `.claude/settings.json`. See [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) for the full flow.

---

## What gets added to your repo

```
repo/
├── AGENTS.md              ← global execution rules
├── .claude/
│   ├── CLAUDE.md          ← Claude Code entry point
│   ├── settings.json      ← hook configuration
│   ├── rules/             ← code style, testing, security rules
│   ├── hooks/             ← automatic guardrail scripts
│   ├── agents/            ← role-specific agent definitions
│   └── skills/            ← on-demand skills
├── trail/                 ← evidence store (auto-rotating)
└── REIN_SETUP_GUIDE.md    ← detailed guide
```

---

## CLI commands

| Command | Description |
|---------|-------------|
| `rein init` | Install the rein-core plugin into the current git repo (plugin-only) |
| `rein update` | Print plugin update pointer (run `claude plugin update rein-core` for the actual update) |
| `rein job <subcmd>` | Background jobs (start/status/stop/tail/list/gc) |
| `rein --version` | Print version |
| `rein --help` | Show help |

For environment variables and flags see [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md).

### Slash command invocation

In plugin mode, Rein's skills are exposed under the `/rein:` namespace. Examples: `/rein:codex-review`, `/rein:codex-ask`.

#### Recommended custom alias
Add the following to `.claude/settings.json` for shorter invocations:
```json
{
  "aliases": {
    "/cr": "/rein:codex-review",
    "/ca": "/rein:codex-ask"
  }
}
```

---

## Platform support

| Platform | Status |
|---|---|
| macOS | ✅ Official |
| Linux | ✅ Official |
| Windows (WSL2) | ✅ Official |
| Windows (Git Bash / MSYS2) | ⚠️ Best-effort, not in regular test matrix |
| Windows (PowerShell / CMD native) | ❌ Unsupported |

Windows users should use **WSL2 (Ubuntu)**. Installation instructions and Git Bash diagnostics are in [docs/troubleshooting/windows.md](docs/troubleshooting/windows.md).

---

## Advanced features (optional)

These become useful as your project grows. They are not required for the basic flow.

- **On-demand skills**: repo audit, auto-promotion of recurring failures into rules, CHANGELOG generation, etc. Details: [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md)
- **Design → Plan scope tracking**: automatically verifies that design-document scope items are all covered in implementation plans. Details: [.claude/rules/design-plan-coverage.md](.claude/rules/design-plan-coverage.md)
- **Repeated-failure rule promotion**: after 2-3 recurrences of the same block, generates an AGENTS.md rule candidate or agent candidate
- **Smart router**: recommends the best combination of agents, skills, and MCP connectors for a given task type

## Compatibility notes

### `everything-claude-code` plugin

The `gateguard-fact-force` hook in `everything-claude-code` (>= 1.9.0) is incompatible with Rein. Installing both causes every Edit/Write/Bash operation to deadlock. Rein already provides equivalent functionality — remove the plugin.

### Upgrading from v0.6.x

Starting with v0.7.0, the CLI install path changed from `/usr/local/bin/rein` to `$HOME/.rein/bin/rein`. Existing users should run [install.sh](install.sh) once to migrate.

---

## Release history

The first official launch is v1.0.0. For pre-v1 dev cycle history see the [archive](docs/changelog-archive/2026-04-pre-v1.md).

---

## Contributing

Issues and PRs are welcome. Please review [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) to understand the framework structure before contributing.

## License

MIT License. See [LICENSE](LICENSE) for details.

## References

- [agentsmd/agents.md](https://agents.md) — AGENTS.md hierarchy
- [anthropics/skills](https://github.com/anthropics/skills) — Skill definitions
