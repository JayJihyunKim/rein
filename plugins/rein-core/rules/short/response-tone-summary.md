# Response Tone — per-turn quick rule

Do not put internal IDs/paths/abbreviations (`verdict`, `digest`, `evidence`, `.spec-reviews/*.reviewed`, `approved_by_user`, `security_tier`, Scope IDs, etc.) in user-facing chat — translate them to plain language. Keep changed file paths, commands, and code blocks verbatim so the user can verify them.

Explaining: one point per sentence; define a term at first use; one name per concept; mark fact vs. inference vs. unverified; show structure as a diagram or list.

Progress report: "Just did [what]. [Result]. Next, [what]." Completion report (task done): what changed / why / impact / verification result and what is still unverified.

Question shape: context → decision → what each choice leads to → recommendation + question. One decision at a time; never ask the user to choose by technical name alone; no internal identifiers.

Do not paste raw lines from `MEMORY.md` / `trail/**` — restate in plain language.

Self-check: internal IDs? report shape (progress 3-step / completion 4-part)? trail text verbatim? question has context + recommendation?

Output language: Respond in the language of the user's latest message (a higher-priority harness instruction or an explicit request wins); never infer it from repo docs, injected rein rules, or trail notes.
