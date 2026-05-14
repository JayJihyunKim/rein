#!/usr/bin/env bash
# tests/integration/test-slash-command-namespace.sh — Phase 9 Task 9.3.
#
# Verifies the slash-command namespace contract for plugin mode:
#
#   A. Every plugins/rein-core/skills/<name>/SKILL.md exists with YAML
#      frontmatter that includes `name:` and `description:`. The `name:`
#      field MUST equal the directory name (no rename drift).
#   E. settings.json shipped by the plugin does not pre-register any
#      aliases. We check the ROOT settings.json and confirm it has no
#      `aliases` key, OR if present, the map is empty.
#   F. Plugin SKILL.md descriptions must not advertise bare `/<skill>`
#      slash commands; references must use the namespaced `/rein:<skill>`
#      form.
#
# Assertion history:
#   - B and C (KR/EN README alias parity) were removed in v5 when the README
#     rewrite consolidated alias docs under REIN_SETUP_GUIDE.md.
#   - D (REIN_SETUP_GUIDE alias block) was removed in v6 when the setup
#     guide was retired and aliases were dropped as advertised user-facing
#     customisation. Users who want short invocations add them to their own
#     `.claude/settings.json`; the framework no longer documents the pattern.
#
# Scope ID: slash-commands-namespace-with-rein-prefix-on-invocation

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILLS_DIR="$PROJECT_DIR/plugins/rein-core/skills"
SETTINGS_JSON="$PROJECT_DIR/.claude/settings.json"

[ -d "$SKILLS_DIR" ]    || { echo "FAIL: missing $SKILLS_DIR" >&2; exit 1; }
[ -f "$SETTINGS_JSON" ] || { echo "FAIL: missing $SETTINGS_JSON" >&2; exit 1; }

FAIL_COUNT=0
fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
ok()   { echo "  ok: $1"; }

TMP="$(mktemp -d -t rein-slash-namespace-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Assert A — every skill has SKILL.md with frontmatter that includes
# `name:` (= dir name) and a non-empty `description:` value.
#
# Parsing strategy (codex Round 1 medium fix):
#   1. Strip UTF-8 BOM and normalize CRLF → LF.
#   2. Extract the leading `---\n...\n---\n` block.
#   3. Try yaml.safe_load. If it succeeds with a dict, use it.
#   4. Otherwise (Claude Code / Anthropic skills frontmatter often contains
#      unquoted prose with embedded colons that PyYAML rejects but Claude
#      Code itself tolerates) fall back to per-line regex extraction of
#      `name:` and `description:` keys. The fallback only requires the
#      key to appear at column 0 and consumes the rest of the line as
#      the value. Multi-line block scalars are treated as if Claude Code
#      reads only the first line — the goal of this test is the
#      namespace contract, not strict YAML conformance.
A_REPORT="$TMP/a.report"
python3 - "$SKILLS_DIR" >"$A_REPORT" <<'PY'
import sys, os, re, json
try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


def parse_frontmatter(text):
    """Return (name, description, parser_used) or (None, None, error_str)."""
    if text.startswith('﻿'):
        text = text[1:]
    text = text.replace("\r\n", "\n")
    m = re.match(r'^---\n(.*?)\n---\s*\n', text, re.DOTALL)
    if not m:
        return None, None, "missing YAML frontmatter (---...---)"
    fm_text = m.group(1)
    if HAS_YAML:
        try:
            fm = yaml.safe_load(fm_text)
            if isinstance(fm, dict) and "name" in fm and "description" in fm:
                name = fm.get("name")
                desc = fm.get("description")
                if isinstance(name, str) and isinstance(desc, str):
                    return name.strip(), desc.strip(), "yaml"
        except yaml.YAMLError:
            pass
    # Fallback: regex line-extraction. Claude Code accepts unquoted prose
    # with embedded colons as long as the first colon is the key/value
    # separator.
    name = None
    desc = None
    for line in fm_text.splitlines():
        if name is None:
            mn = re.match(r'^name:\s*(.+)$', line)
            if mn:
                name = mn.group(1).strip().strip('"').strip("'")
                continue
        if desc is None:
            md_ = re.match(r'^description:\s*(.+)$', line)
            if md_:
                desc = md_.group(1).strip().strip('"').strip("'")
                continue
    return (name, desc, "regex-fallback") if (name and desc) else (None, None, "neither yaml nor regex extracted name+description")


skills_dir = sys.argv[1]
results = {"valid": [], "errors": []}
for entry in sorted(os.listdir(skills_dir)):
    skill_path = os.path.join(skills_dir, entry)
    if not os.path.isdir(skill_path):
        continue
    md_path = os.path.join(skill_path, "SKILL.md")
    if not os.path.isfile(md_path):
        results["errors"].append(f"{entry}: SKILL.md missing")
        continue
    try:
        text = open(md_path, encoding="utf-8", errors="replace").read()
        name, desc, info = parse_frontmatter(text)
        if not name:
            results["errors"].append(f"{entry}: {info}")
            continue
        if name != entry:
            results["errors"].append(f"{entry}: name='{name}' does not match dir (parser={info})")
            continue
        if not desc:
            results["errors"].append(f"{entry}: missing/empty description (parser={info})")
            continue
        results["valid"].append(entry)
    except Exception as e:
        results["errors"].append(f"{entry}: {e}")
print(json.dumps(results))
PY
A_VALID=$(python3 -c "import json,sys; d=json.load(open('$A_REPORT')); print(len(d.get('valid',[])))")
A_ERRORS=$(python3 -c "import json,sys; d=json.load(open('$A_REPORT')); print('\n'.join(d.get('errors',[])))")
if [ -z "$A_ERRORS" ] && [ "$A_VALID" -gt 0 ]; then
  ok "A: $A_VALID plugins/rein-core skills have valid YAML frontmatter (name + description)"
else
  fail "A: $A_VALID skills valid; errors:"
  printf '%s\n' "$A_ERRORS" | sed 's/^/    /' >&2
fi

# (Assertions B, C, D removed — see header comment. As of v6 the framework
#  no longer advertises slash-command aliases anywhere; users who want short
#  invocations add them to their own `.claude/settings.json`.)

# Assert E — settings.json has no pre-registered aliases (alias is opt-in
# user customization). Either no `aliases` key OR an empty `aliases` map.
ALIAS_COUNT=$(python3 - "$SETTINGS_JSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); sys.exit(0)
a = d.get("aliases", {})
print(len(a) if isinstance(a, dict) else -1)
PY
)
case "$ALIAS_COUNT" in
  0)
    ok "E: .claude/settings.json has no pre-registered aliases (opt-in)"
    ;;
  -1)
    fail "E: .claude/settings.json could not be parsed or has malformed 'aliases' field"
    ;;
  *)
    fail "E: .claude/settings.json has $ALIAS_COUNT pre-registered aliases (expected 0 — alias is opt-in user customization)"
    ;;
esac

# Assert F — plugin SKILL.md descriptions must not advertise bare slash
# commands of the form `/<skill-name>` for skills shipped by this same
# plugin. If a description references the slash invocation, it must use
# the namespaced form `/rein:<skill-name>`. codex Round 1 High:
# without this assertion, packaged plugin docs could keep telling users
# to call `/codex-review` (bare) instead of `/rein:codex-review`.
#
# Scope of this check (intentionally narrow):
#   - Only the YAML `description` field of each plugin SKILL.md.
#   - Only references that look like `/<known-skill-name>` (word boundary
#     on both sides to avoid false matches inside paths or URLs).
#   - Conceptual prose elsewhere in SKILL.md body is NOT scrubbed (would
#     require migrating too much content; the description is the primary
#     user-facing hint).
F_REPORT="$TMP/f.report"
python3 - "$SKILLS_DIR" >"$F_REPORT" <<'PY'
import sys, os, re, json
try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

skills_dir = sys.argv[1]
known = sorted(
    d for d in os.listdir(skills_dir)
    if os.path.isdir(os.path.join(skills_dir, d))
)


def get_description(md_path):
    text = open(md_path, encoding="utf-8", errors="replace").read()
    text = text.replace("\r\n", "\n")
    m = re.match(r'^---\n(.*?)\n---\s*\n', text, re.DOTALL)
    if not m:
        return ""
    fm_text = m.group(1)
    if HAS_YAML:
        try:
            fm = yaml.safe_load(fm_text)
            if isinstance(fm, dict):
                d = fm.get("description")
                if isinstance(d, str):
                    return d
        except yaml.YAMLError:
            pass
    for line in fm_text.splitlines():
        m2 = re.match(r'^description:\s*(.+)$', line)
        if m2:
            return m2.group(1).strip().strip('"').strip("'")
    return ""


violations = []
for entry in known:
    md = os.path.join(skills_dir, entry, "SKILL.md")
    if not os.path.isfile(md):
        continue
    desc = get_description(md)
    for k in known:
        # Match /k as standalone token, not preceded by ":".
        # Word-boundary on both sides; avoid /rein:k matching as bare /k.
        pat = re.compile(r'(?<![/A-Za-z0-9-:])/' + re.escape(k) + r'(?![A-Za-z0-9-:])')
        if pat.search(desc):
            violations.append(f"{entry}: description references bare '/{k}' "
                              f"(should be '/rein:{k}')")
print(json.dumps({"violations": violations, "checked": len(known)}))
PY
F_VIOL=$(python3 -c "import json; d=json.load(open('$F_REPORT')); print('\n'.join(d.get('violations',[])))")
F_CHECKED=$(python3 -c "import json; d=json.load(open('$F_REPORT')); print(d.get('checked',0))")
if [ -z "$F_VIOL" ]; then
  ok "F: $F_CHECKED plugin SKILL.md descriptions use namespaced slash invocation (no bare /<skill>)"
else
  fail "F: bare slash command found in plugin SKILL.md description:"
  printf '%s\n' "$F_VIOL" | sed 's/^/    /' >&2
fi

if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "test-slash-command-namespace: FAIL ($FAIL_COUNT assertions failed)" >&2
  exit 1
fi
echo "test-slash-command-namespace: OK (3/3 assertions)"
