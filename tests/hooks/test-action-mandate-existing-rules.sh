#!/usr/bin/env bash
# Verify plugins/rein-core/rules/{code-style,security,testing}.md each have a
# `## 행동 강령` section as the FIRST `## ` header, with body size <= 2048 bytes.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

RULES=(code-style security testing)
MAX=2048
FAIL=0

for name in "${RULES[@]}"; do
  file="plugins/rein-core/rules/${name}.md"
  [ -f "$file" ] || { echo "FAIL: $file missing" >&2; FAIL=1; continue; }

  python3 - "$file" "$MAX" <<'PY' || FAIL=1
import re, sys
path, max_bytes = sys.argv[1], int(sys.argv[2])
body = open(path, encoding="utf-8").read()
# Find: first `# Title\n` then capture from first `## 행동 강령\n` up to next `## ` (or EOF)
m = re.search(r"^#\s+.+?\n+(## 행동 강령\b.*?)(?=\n## |\Z)", body, re.DOTALL | re.MULTILINE)
if not m:
    print(f"FAIL: {path} missing '## 행동 강령' section as the first `## ` header after title", file=sys.stderr)
    sys.exit(1)
mandate = m.group(1)
size = len(mandate.encode("utf-8"))
if size > max_bytes:
    print(f"FAIL: {path} action mandate size {size} > {max_bytes} bytes", file=sys.stderr)
    sys.exit(1)
print(f"OK: {path} mandate={size} bytes")
PY
done

if [ "$FAIL" != "0" ]; then
  echo "test-action-mandate-existing-rules: FAIL" >&2
  exit 1
fi
echo "test-action-mandate-existing-rules: OK"
