#!/usr/bin/env bash
# Verify rule-inject helper does NOT truncate large bodies and emits size diagnostic.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HELPER="$PROJECT_DIR/plugins/rein-core/hooks/lib/rule-inject.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }

# Build a synthetic plugin root with a 12,000-byte dummy rule.
PROOT=$(mktemp -d "/tmp/overflow-handoff-XXXXXX")
trap 'rm -rf "$PROOT"' EXIT
mkdir -p "$PROOT/rules" "$PROOT/scripts"
python3 - "$PROOT" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "rules" / "huge-rule.md"
p.parent.mkdir(parents=True, exist_ok=True)
header = "# Huge Rule\n\n## 행동 강령\n\n짧은 결론.\n\n## Body\n\n"
filler = "A" * (12000 - len(header.encode("utf-8")))
p.write_text(header + filler, encoding="utf-8")
PY

EXPECT=$(wc -c < "$PROOT/rules/huge-rule.md")
[ "$EXPECT" -ge 12000 ] || { echo "FAIL: dummy rule size $EXPECT < 12000" >&2; exit 1; }

OUT=$(mktemp); ERR=$(mktemp)
CLAUDE_PLUGIN_ROOT="$PROOT" bash "$HELPER" huge-rule >"$OUT" 2>"$ERR"
GOT=$(wc -c < "$OUT")

# Size must match exactly (no truncation)
if [ "$GOT" -ne "$EXPECT" ]; then
  echo "FAIL: body truncated. expected=$EXPECT got=$GOT" >&2
  exit 1
fi

# Size diagnostic on stderr
if ! grep -q "rein-rule-inject: rule=huge-rule size=" "$ERR"; then
  echo "FAIL: missing size diagnostic on stderr" >&2
  cat "$ERR" >&2
  exit 1
fi

rm -f "$OUT" "$ERR"
echo "test-overflow-handoff-no-truncation: OK (body=$GOT bytes passed through, size diagnostic emitted)"
