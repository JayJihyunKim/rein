#!/bin/bash
# Hook: SessionStart
# Detect a project directory where the Rein plugin is enabled but repo-local
# state has not been initialized yet. SessionStart cannot ask interactively
# itself, so it injects concise context instructing Claude to ask before
# bootstrapping.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_SCRIPT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}/scripts/rein-bootstrap-project.py"

_json_cwd() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
cwd = data.get("cwd") or data.get("project_dir") or ""
print(cwd if isinstance(cwd, str) else "")
' 2>/dev/null
}

_quote() {
  python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$1"
}

_is_plugin_storage() {
  case "$1" in
    */.claude/plugins) return 0 ;;
    */.claude/plugins/*) return 0 ;;
    *) return 1 ;;
  esac
}

INPUT_CWD="$(_json_cwd)"
if [ -n "$INPUT_CWD" ] && [ -d "$INPUT_CWD" ]; then
  START_DIR="$INPUT_CWD"
else
  START_DIR="$PWD"
fi

PROJECT_DIR="$(git -C "$START_DIR" rev-parse --show-toplevel 2>/dev/null)" || PROJECT_DIR="$START_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || exit 0
[ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ] || exit 0

# Never create or prompt for repo state inside Claude's plugin cache /
# marketplace clones. Those directories are code/cache, not user projects.
if _is_plugin_storage "$PROJECT_DIR"; then
  exit 0
fi

# Fully initialized = both `.rein/project.json` and `trail/index.md` exist.
# Partial state (only one of the two) still needs the bootstrap prompt so
# load-trail does not inject half-baked context. Symmetry with the early-exit
# in session-start-load-trail.sh.
if [ -f "$PROJECT_DIR/.rein/project.json" ] && [ -f "$PROJECT_DIR/trail/index.md" ]; then
  exit 0
fi

if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
  exit 0
fi

Q_BOOTSTRAP="$(_quote "$BOOTSTRAP_SCRIPT")"
Q_ROOT="$(_quote "$PROJECT_DIR")"

cat <<EOF
## Rein bootstrap required

Rein plugin is enabled in this project directory, but repo-local Rein memory is not initialized yet.

- Rein uses \`trail/\` as the project's core memory and evidence log.
- Do not create files automatically.
- Before doing source work, ask the user whether to initialize Rein state in this project directory.
- If the user approves, run:

\`\`\`bash
python3 $Q_BOOTSTRAP --project-dir $Q_ROOT
\`\`\`

This must create state only under the project directory, never under Claude plugin cache or marketplace directories.

EOF

exit 0
