#!/usr/bin/env bash
# test-plugin-scripts-bundle.sh — Plugin-First Restructure Task 1.3 + Task 2.7
#
# Asserts the helper script bundle for the rein-core plugin: 13 files
# mirrored from `scripts/` into `plugins/rein-core/scripts/`. The plugin
# manifest references these helpers via the `helperScripts` slot; this
# test guards drift between the source-of-truth and the plugin mirror.
#
# Composition history:
#   - Task 1.3 (Phase 1): 11 helpers — 9 from scripts/ + 2 from .claude/hooks/lib/
#   - Task 2.7 (Phase 2): +1 helper — rein-policy-loader.py at scripts/ (dual-mirrored)
#   - 2026-04-30 v1.0.0 OSS launch: -2 helpers (rein-manifest-v2.py, rein-path-match.py
#     dropped with scaffold mode) → 10 total.
#   - 2026-05-13 Option C Phase 3: .claude/hooks/lib/{portable,python-runner}.sh
#     overlay polish complete. plugin hooks source plugins/rein-core/hooks/lib/
#     directly, the scripts/ mirror copies became orphaned — dropped from
#     the bundle test together with the deleted overlay sources → 8 total.
#   - 2026-05-14 v1.2.0 cycle INC-1: +4 helpers — incident-automation chain
#     (rein-aggregate-incidents.py, rein-stop-emit-block.py,
#      rein-mark-incident-processed.py, rein-mark-agent-candidate.py) shipped
#     into plugins/rein-core/scripts/. These were repo-local before; hooks
#     and skills now resolve via ${CLAUDE_PLUGIN_ROOT} (RES-1) so the plugin
#     mirror is required for fresh installs → 12 total.
#   - 2026-05-14 v1.2.0 cycle RTG-2: +1 helper — rein-scan-skill-mcp.py
#     shipped into plugins/rein-core/scripts/. SessionStart now resolves
#     the scanner via RES-1 and the guide path via rein-state-paths.py
#     (new skill-mcp-guide state), replacing the .claude/cache hardcoded
#     reference → 13 total.
#   - 2026-05-14 v1.2.0 cycle Wave 5 Fix F1: rein-scan-skill-mcp.py
#     write path refactored — inventory.json now routes through
#     _resolve_inventory_dir() mirroring rein-generate-skill-mcp-guide.py
#     so plugin mode write (${CLAUDE_PLUGIN_DATA}/runtime/inventory/) and
#     scaffold mode write stay in lockstep with the generator's read path.
#     Composition unchanged → still 13 total. dev fallback scripts/
#     mirror seeded to maintain sha256 parity invariant (b).
#
# Assertions (3 invariants):
#   (a) All 13 expected files exist in plugins/rein-core/scripts/.
#   (b) sha256(plugin mirror) == sha256(source) for each file.
#       Failure names the diverging file with both hashes.
#   (c) Executable bit is set on the 3 .sh files in the mirror.
#
# Source mapping is a literal data block — two parallel arrays — so this
# test does NOT parse the plan file. If the bundle composition changes,
# the plan and this test must be updated together.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

MIRROR_DIR="$PROJECT_DIR/plugins/rein-core/scripts"

# Parallel arrays: SOURCES[i] is mirrored to MIRROR_DIR/DESTS[i].
# Order is documented (lib first, then scripts/) but the test does not
# rely on order — it iterates and checks each pair independently.
SOURCES=(
  "scripts/rein-job-wrapper.sh"
  "scripts/rein-validate-coverage-matrix.py"
  "scripts/rein-mark-spec-reviewed.sh"
  "scripts/rein-codex-review.sh"
  "scripts/rein-route-record.py"
  "scripts/rein-generate-skill-mcp-guide.py"
  "scripts/rein-heal-legacy-pending.py"
  "scripts/rein-policy-loader.py"
  "scripts/rein-aggregate-incidents.py"
  "scripts/rein-stop-emit-block.py"
  "scripts/rein-mark-incident-processed.py"
  "scripts/rein-mark-agent-candidate.py"
  "scripts/rein-scan-skill-mcp.py"
)
DESTS=(
  "rein-job-wrapper.sh"
  "rein-validate-coverage-matrix.py"
  "rein-mark-spec-reviewed.sh"
  "rein-codex-review.sh"
  "rein-route-record.py"
  "rein-generate-skill-mcp-guide.py"
  "rein-heal-legacy-pending.py"
  "rein-policy-loader.py"
  "rein-aggregate-incidents.py"
  "rein-stop-emit-block.py"
  "rein-mark-incident-processed.py"
  "rein-mark-agent-candidate.py"
  "rein-scan-skill-mcp.py"
)

# Files that must have the executable bit set in the plugin mirror.
# Note: .py helpers are invoked as `python3 path/to/file.py` so the
# executable bit is not required on the mirror — only .sh launchers.
EXECUTABLE_DESTS=(
  "rein-job-wrapper.sh"
  "rein-mark-spec-reviewed.sh"
  "rein-codex-review.sh"
)

count=${#SOURCES[@]}
if [ "$count" -ne 13 ] || [ "${#DESTS[@]}" -ne 13 ]; then
  echo "FAIL: source/dest arrays must have exactly 13 entries each (sources=$count, dests=${#DESTS[@]})" >&2
  exit 1
fi

# Pick a sha256 command portably (macOS ships shasum, Linux often sha256sum).
sha256_of() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "FAIL: neither sha256sum nor shasum available on PATH" >&2
    exit 1
  fi
}

# --- (a) all 13 mirror files exist -------------------------------------
for i in "${!DESTS[@]}"; do
  dest="$MIRROR_DIR/${DESTS[$i]}"
  if [ ! -f "$dest" ]; then
    echo "FAIL[a]: missing plugin mirror file: plugins/rein-core/scripts/${DESTS[$i]}" >&2
    exit 1
  fi
done

# --- (b) sha256 drift check -------------------------------------------
for i in "${!SOURCES[@]}"; do
  src="$PROJECT_DIR/${SOURCES[$i]}"
  dest="$MIRROR_DIR/${DESTS[$i]}"

  if [ ! -f "$src" ]; then
    echo "FAIL[b]: source file missing: ${SOURCES[$i]}" >&2
    exit 1
  fi

  src_hash=$(sha256_of "$src")
  dest_hash=$(sha256_of "$dest")

  if [ "$src_hash" != "$dest_hash" ]; then
    echo "FAIL[b]: sha256 drift on ${DESTS[$i]}" >&2
    echo "  source (${SOURCES[$i]}): $src_hash" >&2
    echo "  mirror (plugins/rein-core/scripts/${DESTS[$i]}): $dest_hash" >&2
    exit 1
  fi
done

# --- (c) executable bit on .sh mirrors --------------------------------
for name in "${EXECUTABLE_DESTS[@]}"; do
  path="$MIRROR_DIR/$name"
  if [ ! -x "$path" ]; then
    echo "FAIL[c]: executable bit not set on plugins/rein-core/scripts/$name" >&2
    exit 1
  fi
done

echo "test-plugin-scripts-bundle: OK (13 helpers mirrored sha256-identical)"
