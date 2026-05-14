#!/usr/bin/env bash
# test-rein-publish-tarball.sh — Phase 6 Task 6.1.
#
# Verifies `scripts/rein-publish.sh <version>`:
#   (a) Creates marketplace/plugins/<plugin>/<version>/<plugin>-<version>.tar.gz
#       for every plugins/*/ entry containing .claude-plugin/plugin.json.
#   (b) Updates marketplace/marketplace.json — adds the new
#       (plugin, version) pair to plugins[] (or upgrades version list).
#   (c) marketplace.json write is atomic: the file is replaced via rename,
#       not truncated-then-written (no partial JSON visible to readers).
#   (d) Tarball content includes plugin.json and the directory structure.
#
# Scope ID: rein-publish-uploads-plugin-tarballs-to-marketplace-on-tag-push.
#
# This test isolates by copying scripts + plugin fixture into a temp dir,
# so it does not mutate the real repo's marketplace/.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PUBLISH_SH="$PROJECT_DIR/scripts/rein-publish.sh"
UPDATE_PY="$PROJECT_DIR/scripts/rein-marketplace-update.py"
INITIAL_MARKETPLACE="$PROJECT_DIR/marketplace/marketplace.json"

[ -f "$PUBLISH_SH" ] || { echo "FAIL: scripts/rein-publish.sh missing" >&2; exit 1; }
[ -f "$UPDATE_PY" ] || { echo "FAIL: scripts/rein-marketplace-update.py missing" >&2; exit 1; }
[ -f "$INITIAL_MARKETPLACE" ] || { echo "FAIL: marketplace/marketplace.json missing" >&2; exit 1; }

# --- Sandbox ---------------------------------------------------------------
tmp=$(mktemp -d -t rein-publish-tarball-XXXXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts"
mkdir -p "$tmp/plugins/rein-core/.claude-plugin"
mkdir -p "$tmp/plugins/rein-core/hooks"
mkdir -p "$tmp/marketplace"

cp "$PUBLISH_SH" "$tmp/scripts/rein-publish.sh"
cp "$UPDATE_PY" "$tmp/scripts/rein-marketplace-update.py"

cat > "$tmp/plugins/rein-core/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "rein-core",
  "version": "1.0.0",
  "description": "test fixture"
}
EOF
echo "test hook contents" > "$tmp/plugins/rein-core/hooks/sample.sh"

# Initial marketplace.json — empty plugins[].
cat > "$tmp/marketplace/marketplace.json" <<'EOF'
{
  "name": "rein-marketplace",
  "version": "1.0.0",
  "plugins": []
}
EOF

cd "$tmp"

# --- Act -------------------------------------------------------------------
# Task 6.1 (self-hosted) path is exercised here. Task 6.2 (dual-channel)
# is exercised in tests/scripts/test-rein-publish-dual-channel.sh; this
# test asks the publish script to skip the Anthropic POST so that we can
# isolate the manifest/tarball assertions from network behaviour.
unset ANTHROPIC_MARKETPLACE_API ANTHROPIC_TOKEN
export REIN_PUBLISH_SELF_HOSTED_ONLY=1
SKIP_OUT=$(bash scripts/rein-publish.sh 1.0.0 2>&1) || {
  echo "FAIL: rein-publish.sh exited non-zero" >&2
  echo "$SKIP_OUT" >&2
  exit 1
}

# --- Assert (a) Tarball exists ---------------------------------------------
TARBALL="marketplace/plugins/rein-core/1.0.0/rein-core-1.0.0.tar.gz"
[ -f "$TARBALL" ] || {
  echo "FAIL[a]: $TARBALL was not created" >&2
  ls -laR marketplace/ >&2 || true
  exit 1
}

# --- Assert (d) Tarball contents -------------------------------------------
tar tzf "$TARBALL" | grep -q '^rein-core/.claude-plugin/plugin.json$' || {
  echo "FAIL[d]: tarball missing plugin.json entry" >&2
  tar tzf "$TARBALL" >&2
  exit 1
}
tar tzf "$TARBALL" | grep -q '^rein-core/hooks/sample.sh$' || {
  echo "FAIL[d]: tarball missing hooks/sample.sh" >&2
  exit 1
}

# --- Assert (b) marketplace.json updated -----------------------------------
python3 - "$tmp/marketplace/marketplace.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p, "r", encoding="utf-8"))
assert data["name"] == "rein-marketplace", data
assert data["version"] == "1.0.0", data
plugins = data["plugins"]
assert len(plugins) == 1, f"expected 1 plugin entry, got {len(plugins)}: {plugins}"
entry = plugins[0]
assert entry["name"] == "rein-core", entry
versions = entry.get("versions", [])
assert any(v.get("version") == "1.0.0" for v in versions), f"version 1.0.0 missing: {versions}"
v200 = next(v for v in versions if v["version"] == "1.0.0")
expected_path = "marketplace/plugins/rein-core/1.0.0/rein-core-1.0.0.tar.gz"
assert v200.get("source", {}).get("path") == expected_path, v200
sha = v200.get("source", {}).get("sha256", "")
assert isinstance(sha, str) and len(sha) == 64, f"bad sha: {sha!r}"
PY

# --- Assert (c) Atomic write — no .tmp leftover ----------------------------
# rein-marketplace-update.py creates hidden temp files prefixed
# `.marketplace.json.tmp.` (note the leading dot — `tempfile.mkstemp` keeps
# our prefix verbatim). Match both visible and hidden variants so that any
# future glob change in the writer is still caught here.
# rein-publish.sh additionally writes tar archives via `<plugin>-<ver>.tar.gz.XXXXXX`
# temp files that should be mv'd into place; we assert those are also gone.
LEFTOVER=$(find marketplace \( \
    -name '.marketplace.json.tmp*' \
    -o -name 'marketplace.json.tmp*' \
    -o -name '*.tar.gz.??????' \
  \) 2>/dev/null || true)
if [ -n "$LEFTOVER" ]; then
  echo "FAIL[c]: temp file leaked under marketplace/" >&2
  printf '%s\n' "$LEFTOVER" >&2
  exit 1
fi

# --- Assert (corrupt-manifest fail-clean) ----------------------------------
# Inject a malformed `versions` field on the existing entry; rein-publish.sh
# must reject the publish AND not leave an orphan tarball behind. This guards
# against a regression where an update.py failure leaves a phantom plugin
# version directory under marketplace/plugins/.
python3 - "$tmp/marketplace/marketplace.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p, "r", encoding="utf-8"))
data["plugins"][0]["versions"] = "corrupted-string-not-list"
with open(p, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY

# Use a fresh version so the tarball is observably orphan-or-not.
ORPHAN_DIR="marketplace/plugins/rein-core/9.9.9"
ORPHAN_TAR="$ORPHAN_DIR/rein-core-9.9.9.tar.gz"
[ ! -e "$ORPHAN_TAR" ] || { echo "FAIL: pre-existing orphan tarball" >&2; exit 1; }
if bash scripts/rein-publish.sh 9.9.9 >/tmp/rein-pub-corrupt.log 2>&1; then
  echo "FAIL: publish should fail when manifest is corrupted" >&2
  cat /tmp/rein-pub-corrupt.log >&2
  exit 1
fi
if [ -e "$ORPHAN_TAR" ]; then
  echo "FAIL: orphan tarball remained after manifest-update failure: $ORPHAN_TAR" >&2
  exit 1
fi
# Failure must be a one-line `error: ...` — never a Python traceback. CI logs
# are easier to grep + the operator sees a single actionable message.
if grep -q '^Traceback' /tmp/rein-pub-corrupt.log; then
  echo "FAIL: corrupt-manifest failure leaked a Python traceback to stderr" >&2
  cat /tmp/rein-pub-corrupt.log >&2
  exit 1
fi
if ! grep -q '^error:' /tmp/rein-pub-corrupt.log; then
  echo "FAIL: corrupt-manifest failure missing single-line 'error:' message" >&2
  cat /tmp/rein-pub-corrupt.log >&2
  exit 1
fi
# Restore manifest so the next assertion block keeps a sane file.
python3 - "$tmp/marketplace/marketplace.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p, "r", encoding="utf-8"))
data["plugins"][0]["versions"] = [
    {"version": "1.0.0", "source": {"type": "self-hosted",
                                    "path": "marketplace/plugins/rein-core/1.0.0/rein-core-1.0.0.tar.gz",
                                    "sha256": "0" * 64}}
]
with open(p, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY

# --- Assert (idempotency) — second publish of same version is harmless -----
SECOND=$(bash scripts/rein-publish.sh 1.0.0 2>&1) || {
  echo "FAIL: second publish exited non-zero" >&2
  echo "$SECOND" >&2
  exit 1
}
python3 - "$tmp/marketplace/marketplace.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
versions = data["plugins"][0]["versions"]
two_zero = [v for v in versions if v["version"] == "1.0.0"]
assert len(two_zero) == 1, f"version 1.0.0 duplicated on rerun: {versions}"
PY

echo "PASS test-rein-publish-tarball.sh"
