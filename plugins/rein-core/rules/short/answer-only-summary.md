# Answer-only quick rule

## Behavior

Simple questions (info, opinion, tradeoff, planning) get a direct answer — no DoD/review/inbox ceremony. The moment an intent to edit code or create a file appears, escape to the full 11-step sequence (pre-edit-dod-gate enforces this). Re-verify volatile claims (release/branch/tag/publish) with git status/log/tag/ls-remote before answering — never trust trail/index.md alone. Mark anything unknown honestly as "unverified".

Full body: `${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md`.
