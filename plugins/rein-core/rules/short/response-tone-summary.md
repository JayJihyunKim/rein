# Response Tone — per-turn quick rule

Do not put internal IDs/paths/abbreviations (`stamp`, `verdict`, `.codex-reviewed`, `approved_by_user`, `security_tier`, Scope IDs, etc.) in user-facing chat — translate them to plain language. Keep changed file paths, commands, and code blocks verbatim so the user can verify them.

Reporting shape: "Just did [what]. [Result]. Next, [what]." — 1-2 sentences of result + 1 sentence of next step.

Question shape: plain language like "Proceed with this approach?" / "Simplify the security review?" — no internal identifiers.

Do not paste raw lines from `MEMORY.md` / `trail/index.md` / `trail/inbox/` / `trail/dod/` — restate in plain language.

Self-check (before sending): internal IDs exposed? report in 3-step shape? trail text quoted verbatim? internal IDs in a question?

Output language: Respond in the language of the user's latest message. Follow any higher-priority system/developer/harness language instruction first; otherwise the language the user explicitly requested; otherwise the dominant natural language of the latest user message. Do not infer the response language from repo docs, injected rein rules, or trail notes.
