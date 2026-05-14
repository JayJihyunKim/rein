#!/bin/bash
# Test: rein-route-record.py 가 무효 id 를 invalid_ids 로 분리 기록
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/.claude/agents" "$TMP/.claude/skills/codex-review" "$TMP/.rein/policy/router"
cat > "$TMP/.claude/agents/feature-builder.md" <<'EOF'
---
name: feature-builder
description: test
---
EOF
cat > "$TMP/.claude/skills/codex-review/SKILL.md" <<'EOF'
---
name: codex-review
description: test
---
EOF
cat > "$TMP/.rein/policy/router/feedback-log.yaml" <<'EOF'
entries: []
EOF
cat > "$TMP/.rein/policy/router/overrides.yaml" <<'EOF'
entries: []
EOF

python3 "$PROJECT_DIR/scripts/rein-route-record.py" \
  --project-dir "$TMP" \
  feedback \
  --dod dod-foo.md \
  --agent feature-builder \
  --skills "codex-review,ghost-skill" \
  --mcps "" \
  --outcome success > /dev/null

# Pure-python assertions without yaml dependency (Group 7B, 2026-04-24).
# rein-route-record.py writes a controlled YAML subset so we can parse
# structurally via regex without PyYAML — required because macOS CI
# runners do not ship pyyaml and rein's stated convention is "ruamel.yaml
# preferred, fall back to manual text insertion".
python3 - "$TMP/.rein/policy/router/feedback-log.yaml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()

# 1. Exactly one entry — rein-route-record.py writes each entry as a
#    top-level list element starting with "- date:" at 2-space indent
#    (textual writer) or "-   date:" (ruamel writer). Both begin with
#    "- date:" after normalizing leading whitespace.
entries_starts = re.findall(r'(?m)^[ \t]*-[ \t]+date:', text)
assert len(entries_starts) == 1, f"expected 1 entry, got {len(entries_starts)}: {entries_starts}"

# 2. agent: feature-builder under recommended.
assert re.search(r'agent:[ \t]+["\']?feature-builder["\']?', text), \
    f"agent != feature-builder in:\n{text}"

# 3. codex-review appears as a valid skill (bullet under skills:, not inside invalid_ids).
#    Split on invalid_ids boundary to check codex-review only in the pre-invalid section.
m = re.split(r'(?m)^[ \t]*invalid_ids[ \t]*:', text, maxsplit=1)
valid_section = m[0]
assert re.search(r'(?m)^[ \t]*-[ \t]+["\']?codex-review["\']?[ \t]*$', valid_section), \
    f"codex-review not in skills list:\n{valid_section}"
assert not re.search(r'(?m)^[ \t]*-[ \t]+["\']?ghost-skill["\']?[ \t]*$', valid_section), \
    f"ghost-skill leaked into valid skills:\n{valid_section}"

# 4. ghost-skill is in invalid_ids with kind: skill.
#    Look for "id: ghost-skill" followed (possibly across a line) by "kind: skill".
assert len(m) == 2, f"invalid_ids block missing:\n{text}"
invalid_section = m[1]
# Accept either order (id before kind, or kind before id) on adjacent lines.
pair_re = (
    r'id:[ \t]+["\']?ghost-skill["\']?\s*[\n][ \t]*kind:[ \t]+["\']?skill["\']?'
    r'|kind:[ \t]+["\']?skill["\']?\s*[\n][ \t]*id:[ \t]+["\']?ghost-skill["\']?'
)
assert re.search(pair_re, invalid_section), \
    f"invalid_ids missing ghost-skill/skill pair:\n{invalid_section}"

print("OK")
PY
