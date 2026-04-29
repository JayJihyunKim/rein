---
name: rules-prompt
description: rein prompt-only rules — code-style, security, testing — injected at SessionStart via session-start-rules.sh hook
---

# rules-prompt

This skill bundles the 3 prompt-only rules that are injected into Claude's
SessionStart context. The actual rule content is in:
- code-style.md
- security.md
- testing.md

The session-start-rules.sh hook reads these 3 files and emits a SessionStart
additionalContext envelope. Per Task 2.8, `.rein/policy/rules.yaml` can replace
any rule body via per-rule override.
