# Rein Architecture — Hook Lifecycle

> How Rein turns Claude Code's lifecycle hooks into a chain of process gates.

Rein registers hooks at every major Claude Code execution point. Each hook either
lets the action proceed or blocks it (`exit 2`, or `exit 0` with a JSON deny for
Bash). The result is not a workflow *runner* but a process *enforcer*.

## Lifecycle map

```
SessionStart      → bootstrap + trail load + rules inject
UserPromptSubmit  → answer-only vs full-sequence routing
PreToolUse(Edit)  → trail bootstrap gate → rotate → DoD gate
PostToolUse(Edit) → hygiene → review gate → index sync → spec review →
                    plan coverage → routing check → state journal → aggregator
PreToolUse(Bash)  → dispatcher (safety-guard + test-commit-gate)
PostToolUse(Bash) → state journal
PreToolUse(Agent) → agent rules
PostToolUse(Agent)→ review trigger
Stop              → session gate + resolver-cache GC + state journal
```

## What each gate enforces

| Gate | Hook | Blocks when |
|---|---|---|
| Active task | `pre-edit-dod-gate.sh` | a source edit is attempted without a Definition-of-Done record |
| Routing approval | `pre-edit-dod-gate.sh` | the DoD has no user-approved `## 라우팅 추천` section |
| Codex review | `pre-bash-test-commit-gate.sh` `[P5]` | `git commit` runs without a `.codex-reviewed` stamp |
| Security review | `pre-bash-test-commit-gate.sh` `[P6]` | `git commit` runs without a `.security-reviewed` stamp (unless `security_tier: light` + approved) |
| Conventional commit | `pre-bash-test-commit-gate.sh` `[P7]` | the commit message is not Conventional-Commits shaped |
| Secret safety | `pre-bash-safety-guard.sh` `[P8–P11]` | a command reads/stages/commits a `.env` file, or pipes to a shell |

Test execution itself is never blocked — TDD red/green is preserved (`GUARD-1`).
The stamps are enforced only at `git commit`.

## Bash dispatch

`PreToolUse(Bash)` registers a single hook, `pre-bash-dispatcher.sh`, which
classifies the command and conditionally invokes the safety guard and the
test/commit gate. The gate only does meaningful work for test-runner and commit
patterns; other commands pass through.

## State and evidence

- **Markers** under `trail/dod/` (`.active-dod`, `.codex-reviewed`,
  `.security-reviewed`, …) carry per-session gate state.
- **`.rein/cache/hook-resolver/`** caches the PreToolUse resolver result so the
  split PostToolUse sub-hooks reuse it; the Stop hook GCs entries older than 24h.
- **`trail/`** is the durable evidence trail: `inbox/` → `daily/` → `weekly/`,
  with `index.md` auto-loaded at session start.

See [policy-model.md](policy-model.md) for how these gates compose into a
governance layer.
