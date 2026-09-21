#!/usr/bin/env bash
# Plugin SessionStart hook — emit prompt-only rules to additionalContext.
#
# For each of the 7 prompt-only rules — 6 always-on (code-style, security,
# testing, operating-sequence, routing-map, response-tone) plus 1 opt-in
# (`orchestrator-first`, slotted between operating-sequence and routing-map
# only when `.rein/policy/rules.yaml` enables it) — it injects the SHORT
# "행동 강령" summary from ${CLAUDE_PLUGIN_ROOT}/rules/short/<rule>-summary.md,
# concatenates them (separated by `\n\n`), JSON-encodes the result, and prints
# a single SessionStart envelope to stdout:
#
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":<concatenated>}}
#
# Summaries (not full bodies) keep the emitted JSON line under the platform
# per-hook cap (10,000 chars). Measured line length: opt-in off — 6,861 chars
# (8,085 on a first session, which prepends the onboarding primer); opt-in on
# — 9,212 chars on a first session, the largest envelope this hook produces.
# Full bodies (~22KB combined) overflowed the cap and truncated the envelope
# tail (the persona/rule-loss bug, PT-2). Full bodies remain in plugin source
# for on-demand Read.
#
# Per-rule policy override (Phase 2 Task 2.8):
#   For each rule, if `.rein/policy/rules.yaml` defines
#   `<rule>: { override: <body> }`, the override BODY REPLACES the summary in
#   the concatenation (power-user opt-in; user owns the override's size).
#   Replace, not append. Per-rule, not all-or-nothing. Fail-open on every
#   error: missing yaml, malformed yaml, missing PyYAML, or any unexpected
#   shape falls back to the summary (then full body) for that rule. When the
#   summary file is missing, the full body is the fallback so a missing
#   summary degrades to old behaviour rather than dropping the rule.
#
# Graceful degrade: when the rules dir does not exist (e.g. plugin layout
# regression or a partial install), exit 0 silently with no envelope —
# Claude Code hooks treat empty stdout as a no-op SessionStart.
#
# Scope ID: prompt-only-rules-inject-via-session-start-hook-on-session-begin
#           policy-rules-yaml-overrides-rule-text-when-present
set -euo pipefail

# Graceful degrade: if CLAUDE_PLUGIN_ROOT is unset (not in plugin runtime)
# OR if the rules dir doesn't exist (partial install / layout regression),
# exit 0 silently — Claude Code treats empty stdout as a no-op SessionStart
# so the rest of session bootstrap still proceeds.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
RULES_DIR="${CLAUDE_PLUGIN_ROOT}/rules"
LOADER="${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py"
if [ ! -d "$RULES_DIR" ]; then
  exit 0
fi

# ONBOARD-1: first-session onboarding. This hook is the LAST SessionStart hook
# (bootstrap → load-trail → rules), so it is the SOLE marker writer
# (SCOPE-SINGLE-WRITER): bootstrap (earlier) only reads the marker for its
# stdout emit, this hook prepends the primer to additionalContext AND writes
# the marker afterward. Because rules runs last, bootstrap always observes the
# marker-absent snapshot in the same session → the two channels stay
# synchronized without a lock.
ONBOARDED_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/onboarded-check.sh"
ONBOARDED_HELPER_LOADED=0
if [ -f "$ONBOARDED_HELPER" ]; then
  # shellcheck disable=SC1091
  source "$ONBOARDED_HELPER"
  ONBOARDED_HELPER_LOADED=1
fi

# Resolve PROJECT_DIR (user git root) the same way the bootstrap hook does, so
# the marker is read/written under the user's project, not the plugin root.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Snapshot marker presence BEFORE building/emitting content. We must capture
# the first-session decision once: prepend the primer iff the helper loaded and
# the marker is absent, then write the marker only after the envelope is emitted.
ONBOARD_FIRST_SESSION=0
if [ "$ONBOARDED_HELPER_LOADED" = "1" ] && ! rein_is_onboarded "$PROJECT_DIR"; then
  ONBOARD_FIRST_SESSION=1
fi

# OFD-INJECT-1: orchestrator-first is an OPT-IN 7th rule, injected only when
# `.rein/policy/rules.yaml` has `orchestrator-first: {enabled: true}`.
# FAIL-CLOSED (unlike the fail-open override probe in append_rule): it turns ON
# only when the loader exits 0 AND its stdout is byte-for-byte `true`. A missing
# loader, a non-zero exit (even one that printed "true" before dying),
# malformed yaml, an older loader's empty answer or any other stdout leaves it
# OFF, so a broken loader or policy file can never switch the new default on.
# The answer is compared with `cmp`, not captured with `$(...)`: command
# substitution drops trailing newlines and NUL bytes, which would let a
# near-miss answer pass. `pipefail` (set above) makes a non-zero loader exit
# fail the pipeline, and the `if` keeps that failure from tripping `set -e`.
# stderr is dropped — the override probes already surface the yaml warning.
OFD_ENABLED=0
if [ -f "$LOADER" ]; then
  if python3 "$LOADER" --rule-enabled orchestrator-first 2>/dev/null \
    | cmp -s - <(printf 'true'); then
    OFD_ENABLED=1
  fi
fi

# Append one rule to CONTENT: the policy override body when defined, else the
# SHORT summary, else the full body; nothing when neither file exists.
append_rule() {
  local rule="$1" override="" summary_file rule_file
  # Per-rule override probe (Task 2.8). The loader prints the override body
  # if `.rein/policy/rules.yaml` defines one for this rule, else nothing.
  # We deliberately do NOT silence loader stderr — when the user's
  # `.rein/policy/rules.yaml` is malformed, the loader emits a one-line
  # `warning:` to stderr (Plan Task 2.10 fail-open). Passing it through
  # gives the user a single, visible diagnostic instead of swallowing it.
  # `|| true` keeps the loop alive on any non-zero exit (defence-in-depth
  # — the loader's own contract is exit 0 on every path).
  if [ -f "$LOADER" ]; then
    override=$(python3 "$LOADER" --rule-override "$rule" || true)
  fi
  if [ -n "$override" ]; then
    # Override body replaces the default for this rule (power-user opt-in;
    # the user owns the override's size). Overrides bypass summarization.
    CONTENT+="$override"$'\n\n'
    return 0
  fi
  # No override → inject the SHORT summary (PT-2). Full rule bodies are
  # ~22KB combined and overflow the per-hook cap (10,000 chars), which
  # truncates the tail of the envelope (the original persona/rule-loss
  # bug). The "행동 강령" summary keeps this hook's output safely under
  # the cap, while full bodies stay in plugin source for on-demand
  # Read. Fall back to the full body only if the summary file is missing,
  # so a missing summary degrades to the old behaviour instead of dropping
  # the rule entirely.
  summary_file="$RULES_DIR/short/${rule}-summary.md"
  rule_file="$RULES_DIR/${rule}.md"
  if [ -f "$summary_file" ]; then
    CONTENT+="$(cat "$summary_file")"$'\n\n'
  elif [ -f "$rule_file" ]; then
    CONTENT+="$(cat "$rule_file")"$'\n\n'
  fi
}

CONTENT=""
for RULE in code-style security testing operating-sequence routing-map response-tone; do
  # The opt-in slot sits between operating-sequence and routing-map. The 6-rule
  # list literal above is pinned by test-ups1-short-rule-injection.sh — keep it.
  if [ "$RULE" = "routing-map" ] && [ "$OFD_ENABLED" = "1" ]; then
    append_rule orchestrator-first
  fi
  append_rule "$RULE"
done

# persona injection moved to its own SessionStart hook (PT-3, PT-4):
# session-start-persona.sh emits the persona in a SEPARATE envelope so it has
# its own per-hook size budget and survives regardless of how this rules block
# grows. hooks.json runs it AFTER this hook ("tone applied last" ordering).

# Empty CONTENT (no defaults available, no overrides) — exit silently.
if [ -z "$CONTENT" ]; then
  exit 0
fi

# ONBOARD-1: on the first session prepend the primer to the front of the rule
# additionalContext (same envelope's content extended — NOT a second envelope,
# preserving the one-envelope-per-SessionStart contract). The primer body comes
# from the shared single definition (rein_primer_body) so it is byte-identical
# to the user-stdout channel emitted by the bootstrap hook.
#
# append ONE bootstrap-status line after the primer
# body (NOT a marker rename — .rein/.onboarded still only means "primer shown
# once"; this line separately answers "did bootstrap actually finish").
# Same tri-marker predicate lib/bootstrap-check.sh uses (trail/ +
# .rein/project.json + trail/index.md) — recomputed directly here rather
# than sourcing that helper, since this is a one-line status read, not a
# safety-checked resolution.
if [ "$ONBOARD_FIRST_SESSION" = "1" ]; then
  BOOTSTRAP_STATUS_LINE="초기화는 아직이에요 — 위 안내를 따라 주세요."
  if [ -d "$PROJECT_DIR/trail" ] && [ -f "$PROJECT_DIR/.rein/project.json" ] && [ -f "$PROJECT_DIR/trail/index.md" ]; then
    BOOTSTRAP_STATUS_LINE="초기화는 이미 끝났어요."
  fi
  CONTENT="$(rein_primer_body)"$'\n'"$BOOTSTRAP_STATUS_LINE"$'\n\n'"$CONTENT"
fi

# JSON-encode CONTENT via python3 (handles all escaping including newlines,
# quotes, control chars). Print envelope to stdout.
ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"

# ONBOARD-1 (sole marker writer): only after the envelope is emitted, and only
# if this was the first session, write the onboarded marker so subsequent
# sessions stay silent on both channels. Marker write failure is non-blocking
# (assumption B): worst case is one duplicate primer next session — harmless.
if [ "$ONBOARD_FIRST_SESSION" = "1" ]; then
  version=$(python3 -c "import json;print(json.load(open('${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "")
  rein_mark_onboarded "$PROJECT_DIR" "$version" || true
fi
