#!/usr/bin/env bash
# test-plugin-hooks-json-parity.sh — Plugin-First Restructure Phase 1 Task 1.4
# (extended in Phase 2 Task 2.1 with PLUGIN_ONLY_BASENAMES allowlist).
#
# Asymmetric parity check between plugin hooks.json and the canonical
# .claude/settings.json hooks section. Settings.json registrations MUST
# all appear in plugin hooks.json (catches DROP regressions). Plugin
# hooks.json may add EXTRA registrations only for scripts whose
# basename is in the PLUGIN_ONLY_BASENAMES allowlist — this is the
# escape hatch for plugin-mode behavior that scaffold mode does not
# need (e.g. session-start-rules.sh injects prompt-only rules into
# Claude's SessionStart context, but the rein-dev project relies on
# CLAUDE.md @import for the same content — rein-dev does not need the
# hook fired locally).
#
# Failure modes detected:
#
#   (1) DROPPED registration — a hook in settings.json is missing from
#       hooks.json (e.g. trail-rotate.sh accidentally classified as
#       utility-only and omitted).
#   (2) MATCHER NARROWING — a hook is present but with a smaller matcher
#       than settings.json (e.g. post-write-spec-review-gate.sh registered
#       as "Write" only when settings.json has "Edit|Write|MultiEdit").
#   (3) OVER-REGISTRATION — a triple in plugin hooks.json that does not
#       exist in settings.json AND whose script basename is NOT in the
#       PLUGIN_ONLY_BASENAMES allowlist. Plugin-only entries are
#       required to be deliberate (added to the allowlist below) so
#       drift is still caught when an unrelated extra hook leaks in.
#
# Mechanism: build (event, matcher_or_empty, basename) tuples from each
# file. Settings.json side is the canonical lower bound (every triple
# must be in plugin set). Plugin side may add triples whose basename is
# in PLUGIN_ONLY_BASENAMES. Comparison is matcher-text-exact (no regex
# semantic equality) — settings.json drives the canonical matcher
# string and plugin hooks.json must reproduce it verbatim. SessionStart
# / Stop entries have no matcher; they are compared with matcher=""
# on both sides.
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
#           prompt-only-rules-inject-via-session-start-hook-on-session-begin
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

SETTINGS_JSON=".claude/settings.json"
HOOKS_JSON="plugins/rein-core/hooks/hooks.json"

[ -f "$SETTINGS_JSON" ] || {
  echo "FAIL: $SETTINGS_JSON missing" >&2
  exit 1
}
[ -f "$HOOKS_JSON" ] || {
  echo "FAIL: $HOOKS_JSON missing" >&2
  exit 1
}

python3 - "$SETTINGS_JSON" "$HOOKS_JSON" <<'PY'
import json
import os
import sys

settings_path, hooks_path = sys.argv[1], sys.argv[2]

# ---- PLUGIN_ONLY_BASENAMES allowlist ----------------------------------------
# Hooks whose basename is in this set are allowed to appear in plugin
# hooks.json WITHOUT a matching settings.json entry. Deliberate plugin-mode
# extensions go here — adding a script outside this set will fail parity
# (catches accidental over-registration regressions).
#
# Current entries:
#   - session-start-bootstrap.sh: prompts for repo-local Rein bootstrap when
#     the plugin is enabled in an uninitialized git repo.
#   - session-start-rules.sh: emits SessionStart additionalContext envelope
#     with the 3 prompt-only rules (code-style, security, testing). rein-dev
#     itself loads these via @import in .claude/CLAUDE.md, so settings.json
#     does NOT register the hook. End-user plugin installs DO need the hook
#     to receive the same rule content. (Plan §Phase 2 Task 2.1.)
PLUGIN_ONLY_BASENAMES = {
    "session-start-bootstrap.sh",
    "session-start-rules.sh",
    "post-agent-review-trigger.sh",
}

with open(settings_path, "r", encoding="utf-8") as fh:
    settings = json.load(fh)
with open(hooks_path, "r", encoding="utf-8") as fh:
    hooks = json.load(fh)

# ---- (A) Build canonical set from settings.json ------------------------------
# settings.json structure:
#   hooks: { <EventName>: [ {matcher?, hooks: [{type, command}, ...]}, ... ] }
canonical = set()
for event_name, buckets in (settings.get("hooks") or {}).items():
    if not isinstance(buckets, list):
        print(f"FAIL: settings.json hooks.{event_name} is not a list", file=sys.stderr)
        sys.exit(1)
    for i, bucket in enumerate(buckets):
        if not isinstance(bucket, dict):
            print(f"FAIL: settings.json hooks.{event_name}[{i}] is not an object", file=sys.stderr)
            sys.exit(1)
        # SessionStart / Stop omit "matcher" entirely — represent as "".
        matcher = bucket.get("matcher", "")
        sub_hooks = bucket.get("hooks") or []
        if not isinstance(sub_hooks, list):
            print(f"FAIL: settings.json hooks.{event_name}[{i}].hooks is not a list", file=sys.stderr)
            sys.exit(1)
        for j, sh in enumerate(sub_hooks):
            cmd = sh.get("command") if isinstance(sh, dict) else None
            if not isinstance(cmd, str) or not cmd:
                print(f"FAIL: settings.json hooks.{event_name}[{i}].hooks[{j}] missing 'command'", file=sys.stderr)
                sys.exit(1)
            basename = os.path.basename(cmd)
            canonical.add((event_name, matcher, basename))

# ---- (B) Build plugin set from hooks.json -----------------------------------
# hooks.json structure:
#   hooks: { <EventName>: [ {matcher?, hooks: [{type, command}, ...]}, ... ] }
plugin_set = set()
events = hooks.get("hooks")
if not isinstance(events, dict) or not events:
    print("FAIL: hooks.json 'hooks' is not a non-empty object", file=sys.stderr)
    sys.exit(1)
for event_name, buckets in events.items():
    if not isinstance(event_name, str) or not event_name:
        print("FAIL: hooks.json event name must be a non-empty string", file=sys.stderr)
        sys.exit(1)
    if not isinstance(buckets, list):
        print(f"FAIL: hooks.json hooks.{event_name} is not a list", file=sys.stderr)
        sys.exit(1)
    for i, bucket in enumerate(buckets):
        if not isinstance(bucket, dict):
            print(f"FAIL: hooks.json hooks.{event_name}[{i}] is not an object", file=sys.stderr)
            sys.exit(1)
        matcher = bucket.get("matcher", "")
        sub_hooks = bucket.get("hooks") or []
        if not isinstance(sub_hooks, list):
            print(f"FAIL: hooks.json hooks.{event_name}[{i}].hooks is not a list", file=sys.stderr)
            sys.exit(1)
        for j, sh in enumerate(sub_hooks):
            cmd = sh.get("command") if isinstance(sh, dict) else None
            if not isinstance(cmd, str) or not cmd:
                print(f"FAIL: hooks.json hooks.{event_name}[{i}].hooks[{j}] missing 'command'", file=sys.stderr)
                sys.exit(1)
            basename = os.path.basename(cmd)
            plugin_set.add((event_name, matcher, basename))

# ---- (C) Diff ---------------------------------------------------------------
# settings.json side is the canonical lower bound: every triple there
# must be in plugin_set (catches DROP regressions, the (1) case).
# plugin side may have EXTRA triples ONLY when the basename is in
# PLUGIN_ONLY_BASENAMES (deliberate plugin-mode behavior).
missing_in_plugin = canonical - plugin_set
extra_in_plugin = plugin_set - canonical

# Partition extras: allowed (basename in allowlist) vs. unexpected.
unexpected_extras = {
    triple for triple in extra_in_plugin
    if triple[2] not in PLUGIN_ONLY_BASENAMES
}
allowed_extras = extra_in_plugin - unexpected_extras

ok = True
if missing_in_plugin:
    ok = False
    print("FAIL: plugin hooks.json is MISSING entries that settings.json has:", file=sys.stderr)
    for triple in sorted(missing_in_plugin):
        print(f"  - event={triple[0]!r} matcher={triple[1]!r} script={triple[2]!r}", file=sys.stderr)

if unexpected_extras:
    ok = False
    print("FAIL: plugin hooks.json has EXTRA entries not in settings.json (and not in PLUGIN_ONLY_BASENAMES allowlist):", file=sys.stderr)
    for triple in sorted(unexpected_extras):
        print(f"  - event={triple[0]!r} matcher={triple[1]!r} script={triple[2]!r}", file=sys.stderr)
    print(f"  (allowlist: {sorted(PLUGIN_ONLY_BASENAMES)})", file=sys.stderr)

# ---- (D) Helper diagnostic: matcher-mismatch detection ----------------------
# Same (event, basename) pair on both sides but different matcher. This is a
# narrower view of the (missing+extra) case and helps human readers debug.
def index_by_event_script(s):
    out = {}
    for ev, m, sn in s:
        out.setdefault((ev, sn), set()).add(m)
    return out

canonical_idx = index_by_event_script(canonical)
plugin_idx = index_by_event_script(plugin_set)
common_keys = set(canonical_idx.keys()) & set(plugin_idx.keys())
for key in sorted(common_keys):
    if canonical_idx[key] != plugin_idx[key]:
        # Will already have been flagged via missing/extra; print friendly note.
        ev, sn = key
        print(
            f"NOTE: matcher mismatch for event={ev!r} script={sn!r}: "
            f"settings={sorted(canonical_idx[key])} plugin={sorted(plugin_idx[key])}",
            file=sys.stderr,
        )

if not ok:
    sys.exit(1)

extras_note = ""
if allowed_extras:
    extras_note = f", {len(allowed_extras)} plugin-only extra(s) from PLUGIN_ONLY_BASENAMES allowlist"
print(f"test-plugin-hooks-json-parity: OK ({len(canonical)} triples shared between settings.json and plugin hooks.json{extras_note})")
PY
