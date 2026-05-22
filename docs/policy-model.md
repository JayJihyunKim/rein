# Rein Policy Model — The Governance Layer

> Rein turns Claude Code from an autonomous coding assistant into a
> policy-governed engineering agent.

A plain Claude Code session runs: **command → the agent does the work.**

A Rein session runs: **command → check policy → check state → check evidence →
check review → proceed or block.**

That inserted middle is the governance layer. It is what makes the agent operate
inside a team's rules, evidence, and review process rather than on prompt
discipline alone.

## The three guarantees

1. **Work is defined before it happens.** A source edit requires an active
   Definition-of-Done record and an approved routing recommendation. The agent
   must say *what* it will do and *with which* agent/skill/MCP combination before
   touching code.

2. **Review is a gate, not a habit.** Code reviews produce a stamp. Without the
   stamp, `git commit` is blocked. Review stops being something you remember to
   do and becomes something the repo requires.

3. **Every failure becomes a rule.** When the same violation recurs, Rein
   surfaces it as an incident and offers to promote it into a rule — and a
   repeated rule into an agent. The system learns from its own mistakes instead
   of relying on the operator to re-prompt.

## Why this matters

In an AI-assisted workflow, quality lives in the operator's attention: every
wrong output is a re-prompt, and the standard exists only in someone's head. In
an AI-native workflow, quality lives in the repo: every wrong output is a rule
that prevents recurrence, and standards accumulate so quality compounds.

```
Re-prompt model:   mistake → re-prompt → (same mistake later)
Rule model:        mistake → rule → mistake prevented for everyone, every session
```

## Where policy lives today

Today the gate logic lives inside the lifecycle hooks (see
[architecture.md](architecture.md)). The decisions a hook makes — *require an
active task*, *require codex review before commit*, *block secret reads* — are
the de-facto policy. A future direction is to lift those decisions into a
declarative policy file so teams can express them directly:

```yaml
before_edit:
  require:
    - active_task
    - routing_approval
before_commit:
  require:
    - codex_review
    - security_review
    - passing_tests
```

This document describes the *concept*; the declarative engine is a roadmap item,
not a shipped feature.
