#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

FILE="plugins/rein-core/rules/design-plan-coverage.md"
[ -f "$FILE" ] || { echo "FAIL: $FILE missing" >&2; exit 1; }

SIZE=$(wc -c < "$FILE")
MAX=12000
if [ "$SIZE" -ge "$MAX" ]; then
  echo "FAIL: $FILE size=$SIZE bytes >= $MAX" >&2
  exit 1
fi

# Action mandate section present + ≤ 2048 bytes
python3 - "$FILE" 2048 <<'PY' || exit 1
import re, sys
path, max_bytes = sys.argv[1], int(sys.argv[2])
body = open(path, encoding="utf-8").read()
m = re.search(r"^#\s+.+?\n+(## 행동 강령\b.*?)(?=\n## |\Z)", body, re.DOTALL | re.MULTILINE)
if not m:
    print(f"FAIL: {path} missing '## 행동 강령' section as first `## ` header", file=sys.stderr)
    sys.exit(1)
mandate = m.group(1)
size = len(mandate.encode("utf-8"))
if size > max_bytes:
    print(f"FAIL: {path} mandate size {size} > {max_bytes}", file=sys.stderr)
    sys.exit(1)
print(f"OK: {path} total={open(path,'rb').read().__len__()} bytes, mandate={size} bytes")
PY
echo "test-design-plan-coverage-plugin-size: OK ($SIZE bytes < $MAX, budget=12000)"
