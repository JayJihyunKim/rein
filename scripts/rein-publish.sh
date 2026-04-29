#!/usr/bin/env bash
# rein-publish.sh — Phase 6 Tasks 6.1 + 6.2 (marketplace publish).
#
# Publishes every `plugins/*/` package along two channels:
#   1. Self-hosted: build tarball under
#      `marketplace/plugins/<plugin>/<version>/<plugin>-<version>.tar.gz` and
#      atomically register it in `marketplace/marketplace.json` (via
#      scripts/rein-marketplace-update.py).
#   2. Anthropic public marketplace: POST the same tarball to
#      `${ANTHROPIC_MARKETPLACE_API}/plugins/<plugin>/versions/<version>`
#      with `Authorization: Bearer ${ANTHROPIC_TOKEN}` (Round 5 fix
#      Finding 6: NO default URL is hardcoded; both env vars are required
#      and the script fails fast — BEFORE building any tarball — when
#      either is missing).
#
# Both channels must succeed. If the Anthropic POST fails after the
# self-hosted manifest was updated, we restore the manifest from a
# pre-publish snapshot AND restore (or remove) every tarball we touched.
# Restoration of the manifest itself is atomic (write-to-temp + mv) so
# a concurrent reader cannot see a half-restored file.
#
# Cross-channel atomicity (e.g. distributed transaction across the two
# marketplaces) is spec §6.2 Open Question and is NOT in scope here —
# we only promise best-effort sequential rollback.
#
# Reproducibility note: when GNU tar is available we pin --sort/--owner/
# --mtime so the same plugin tree always yields the same archive bytes
# (and therefore the same sha256 in the manifest). On BSD tar (macOS
# local dev), tarballs are still functional but byte-stable only across
# runs on the same host. CI runs on Linux + GNU tar, so the manifest
# sha256 published from CI is reproducible by re-running the workflow.
#
# Token handling: ANTHROPIC_TOKEN is NEVER passed in `curl` argv. We use
# `curl -H @-` and feed the entire `Authorization: Bearer ...` header on
# stdin via a here-string, so the token does not appear in /proc/<pid>/
# cmdline or in `ps` output. We also pin `--max-redirs 0` to forbid the
# server from redirecting our authenticated POST to a different host —
# without that, a malicious or misconfigured 3xx could leak the bearer
# token to an unrelated origin (curl forwards `-H` headers to redirect
# targets by default, see `man curl` § "headers set with this option").
#
# Scope IDs:
#   - rein-publish-uploads-plugin-tarballs-to-marketplace-on-tag-push
#   - marketplace-publishes-to-anthropic-and-self-hosted-json-simultaneously-on-release
# Spec ref: docs/specs/2026-04-27-plugin-first-restructure.md
#
# Usage:
#   scripts/rein-publish.sh <version>
#
# Environment:
#   REIN_PUBLISH_SELF_HOSTED_ONLY  if "1", skip the Anthropic POST entirely
#                                  (used by Task 6.1 tarball test + dry runs).
#   ANTHROPIC_MARKETPLACE_API      base URL of the Anthropic marketplace API.
#                                  Required unless SELF_HOSTED_ONLY=1. Must
#                                  be HTTPS, except http://127.0.0.1:* or
#                                  http://localhost:* are accepted (test
#                                  mock servers).
#   ANTHROPIC_TOKEN                bearer token. Required unless
#                                  SELF_HOSTED_ONLY=1. Never echoed to
#                                  stdout/stderr and never placed in argv.

set -euo pipefail

VERSION="${1:?usage: rein-publish.sh <version>}"

# Validate VERSION charset matches what rein-marketplace-update.py accepts.
# Catches things like `--curl-arg` injection through $1 before $VERSION is
# expanded into other arguments / paths / URLs.
case "$VERSION" in
  ''|*[!A-Za-z0-9._+-]*)
    echo "error: invalid version: $VERSION" >&2
    exit 2
    ;;
esac

# Resolve repo root from this script (handles symlinked / CI invocations).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PLUGINS_DIR="plugins"
MANIFEST="marketplace/marketplace.json"
UPDATE_PY="scripts/rein-marketplace-update.py"

if [ ! -d "$PLUGINS_DIR" ]; then
  echo "error: $PLUGINS_DIR/ not found" >&2
  exit 2
fi
if [ ! -f "$UPDATE_PY" ]; then
  echo "error: $UPDATE_PY not found" >&2
  exit 2
fi

# --- Fail-fast on Anthropic env vars (BEFORE any side effects) -------------
#
# Round 5 fix Finding 6: NO default URL is hardcoded. CI must inject the
# repository variable / secret. Missing either → fail-fast at the very
# start of the run, BEFORE we build a tarball or touch the manifest, so
# that a misconfigured CI cannot leave half-published state behind.
SKIP_ANTHROPIC=0
if [ "${REIN_PUBLISH_SELF_HOSTED_ONLY:-0}" = "1" ]; then
  SKIP_ANTHROPIC=1
else
  if [ -z "${ANTHROPIC_MARKETPLACE_API:-}" ]; then
    echo "error: ANTHROPIC_MARKETPLACE_API env var required (e.g., set in CI repository variable)" >&2
    exit 1
  fi
  if [ -z "${ANTHROPIC_TOKEN:-}" ]; then
    echo "error: ANTHROPIC_TOKEN env var required (set in CI secret config)" >&2
    exit 1
  fi
  # Refuse plain http:// in production. Loopback http (test mock servers)
  # is allowed because credential exposure on loopback is bounded to the
  # local test process. We do NOT echo the URL value in the rejection
  # message because operators sometimes accidentally encode credentials
  # in URLs and we don't want that to land in CI logs.
  case "$ANTHROPIC_MARKETPLACE_API" in
    https://*) ;;
    http://127.0.0.1:*|http://localhost:*) ;;
    *)
      echo "error: ANTHROPIC_MARKETPLACE_API must be HTTPS (or http://127.0.0.1:* / http://localhost:* in tests)" >&2
      exit 1
      ;;
  esac
fi

# --- Rollback bookkeeping --------------------------------------------------
#
# Per-tarball entries describe what state existed BEFORE this run touched
# the tarball path. On rollback we reverse the change exactly:
#   - kind=created   : tarball did not exist before; remove it on rollback.
#   - kind=overwrote : a tarball existed at this path; restore its prior
#                      bytes from the side-saved snapshot.
# The two parallel arrays use the same index. Bash 3.2 (macOS default) does
# not support associative arrays, so we keep these as positional pairs.
ROLLBACK_KINDS=()
ROLLBACK_TARBALLS=()
ROLLBACK_TARBALL_BACKUPS=()
ROLLBACK_DIRS_TO_RMDIR=()
SELF_HOSTED_BACKUP=""
PUBLISHED_PLUGINS=()

snapshotManifest() {
  # Side-save current marketplace.json so rollback can restore it byte-for-
  # byte. mktemp lands the snapshot outside the marketplace/ tree so the
  # workflow artifact upload doesn't accidentally pick it up.
  if [ -z "$SELF_HOSTED_BACKUP" ] && [ -f "$MANIFEST" ]; then
    SELF_HOSTED_BACKUP="$(mktemp -t rein-marketplace-backup-XXXXXX)"
    cp -- "$MANIFEST" "$SELF_HOSTED_BACKUP"
  fi
}

# Atomic manifest restore: write to a temp file in the SAME dir as the
# manifest (so `mv` is a same-FS rename), then mv into place. Without this
# a concurrent reader can observe a truncated marketplace.json mid-restore.
restoreManifestAtomically() {
  local src="$1"
  local dst="$2"
  local dir
  dir="$(dirname "$dst")"
  local tmpDst
  tmpDst="$(mktemp "$dir/.marketplace.json.restore.XXXXXX")"
  if cp -- "$src" "$tmpDst" 2>/dev/null; then
    mv -f -- "$tmpDst" "$dst" 2>/dev/null || rm -f -- "$tmpDst" 2>/dev/null || true
  else
    rm -f -- "$tmpDst" 2>/dev/null || true
  fi
}

rollbackSelfHosted() {
  # Restore manifest atomically (or remove if it didn't exist before).
  if [ -n "$SELF_HOSTED_BACKUP" ] && [ -f "$SELF_HOSTED_BACKUP" ]; then
    restoreManifestAtomically "$SELF_HOSTED_BACKUP" "$MANIFEST"
  elif [ -f "$MANIFEST" ]; then
    rm -f -- "$MANIFEST" 2>/dev/null || true
  fi
  # Reverse each per-tarball mutation (in reverse order to honour any
  # nesting of rollback dirs).
  local i kind path backup
  for ((i=${#ROLLBACK_TARBALLS[@]}-1; i>=0; i--)); do
    kind="${ROLLBACK_KINDS[$i]}"
    path="${ROLLBACK_TARBALLS[$i]}"
    backup="${ROLLBACK_TARBALL_BACKUPS[$i]}"
    case "$kind" in
      overwrote)
        if [ -n "$backup" ] && [ -f "$backup" ]; then
          mv -f -- "$backup" "$path" 2>/dev/null || rm -f -- "$backup" 2>/dev/null || true
        fi
        ;;
      created)
        rm -f -- "$path" 2>/dev/null || true
        ;;
    esac
  done
  # rmdir is intentionally non-recursive — we only remove version dirs we
  # created from scratch (and only if they are now empty, so a re-publish
  # that deleted nobody's existing dir is safe).
  for d in "${ROLLBACK_DIRS_TO_RMDIR[@]:-}"; do
    [ -n "$d" ] && rmdir "$d" 2>/dev/null || true
  done
  if [ -n "$SELF_HOSTED_BACKUP" ]; then
    rm -f -- "$SELF_HOSTED_BACKUP" 2>/dev/null || true
  fi
}

# --- Phase 1: self-hosted publish -----------------------------------------

snapshotManifest

for pluginPath in "$PLUGINS_DIR"/*/; do
  [ -d "$pluginPath" ] || continue
  pluginName="$(basename "$pluginPath")"

  # Skip dirs that aren't plugins (no plugin.json).
  if [ ! -f "$pluginPath/.claude-plugin/plugin.json" ]; then
    continue
  fi

  # Validate plugin name early — same charset our update.py enforces. Defends
  # against weird directory names that could embed shell metacharacters.
  case "$pluginName" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: skipping plugin with disallowed name: $pluginName" >&2
      rollbackSelfHosted
      exit 2
      ;;
  esac

  outDir="marketplace/plugins/$pluginName/$VERSION"
  tarball="$outDir/${pluginName}-${VERSION}.tar.gz"

  # Note: we only schedule rmdir for the version dir if WE created it.
  if [ ! -d "$outDir" ]; then
    ROLLBACK_DIRS_TO_RMDIR+=("$outDir")
  fi
  mkdir -p "$outDir"

  # Snapshot the prior state of $tarball BEFORE we overwrite it. This is
  # what makes re-publishing an existing version safe under rollback.
  rollbackKind="created"
  rollbackBackup=""
  if [ -f "$tarball" ]; then
    rollbackKind="overwrote"
    rollbackBackup="$(mktemp -t rein-tar-backup-XXXXXX.tar.gz)"
    cp -- "$tarball" "$rollbackBackup"
  fi

  # Build tarball into a temp file in the SAME directory, then mv into the
  # final path on success. Without this, a partial `tar` write (e.g. disk
  # full, fake tar, signal-killed tar) would truncate the previously
  # published tarball at $tarball BEFORE our rollback bookkeeping registers
  # the snapshot. mv-on-same-dir is rename(2) → atomic. If `tar` fails, we
  # delete the temp file, restore the prior tarball (already snapshotted
  # above) — which is now still untouched at $tarball — and exit.
  # mktemp template form (path embedded in template) works on both GNU
  # and BSD mktemp, unlike the GNU-only `-p <dir>` flag.
  tmpTar="$(mktemp "$outDir/${pluginName}-${VERSION}.tar.gz.XXXXXX")"
  set +e
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    tar --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --mtime='UTC 2026-04-28' \
        -czf "$tmpTar" \
        -C "$PLUGINS_DIR" \
        -- "$pluginName"
  else
    tar -czf "$tmpTar" \
        -C "$PLUGINS_DIR" \
        -- "$pluginName"
  fi
  tarRc=$?
  set -e
  if [ "$tarRc" -ne 0 ]; then
    # tar failed — temp file is incomplete; original tarball untouched.
    rm -f -- "$tmpTar" 2>/dev/null || true
    if [ -n "$rollbackBackup" ]; then
      rm -f -- "$rollbackBackup" 2>/dev/null || true
    fi
    echo "error: tar failed for $pluginName $VERSION (rc=$tarRc); prior tarball (if any) preserved" >&2
    rollbackSelfHosted
    exit "$tarRc"
  fi
  # Atomic publish of new bytes into the final path.
  mv -f -- "$tmpTar" "$tarball"

  ROLLBACK_KINDS+=("$rollbackKind")
  ROLLBACK_TARBALLS+=("$tarball")
  ROLLBACK_TARBALL_BACKUPS+=("$rollbackBackup")

  # Atomic JSON update. If update.py fails (corrupt prior manifest, validation
  # error, etc.), delete the tarball we just produced AND restore the
  # manifest from snapshot so the failure leaves no orphan artifact.
  set +e
  python3 "$UPDATE_PY" "$pluginName" "$VERSION" "$tarball" --manifest "$MANIFEST"
  updateRc=$?
  set -e
  if [ "$updateRc" -ne 0 ]; then
    echo "error: failed to update self-hosted manifest for $pluginName $VERSION (rc=$updateRc)" >&2
    rollbackSelfHosted
    exit "$updateRc"
  fi

  PUBLISHED_PLUGINS+=("$pluginName")
done

# Self-hosted-only mode (Task 6.1 unit test + manual dry runs) stops here.
if [ "$SKIP_ANTHROPIC" = "1" ]; then
  # Snapshot is no longer needed; clean up side files.
  if [ -n "$SELF_HOSTED_BACKUP" ]; then
    rm -f -- "$SELF_HOSTED_BACKUP" || true
  fi
  for backup in "${ROLLBACK_TARBALL_BACKUPS[@]:-}"; do
    [ -n "$backup" ] && rm -f -- "$backup" 2>/dev/null || true
  done
  exit 0
fi

# --- Phase 2: Anthropic public marketplace POST ---------------------------

# POST one plugin tarball. We feed the Authorization header to curl on
# stdin via `-H @-` so the bearer token never appears in argv (and thus
# never in /proc/<pid>/cmdline or `ps` output). `--max-redirs 0` blocks
# the server from forwarding our authenticated POST to another origin.
postOnePlugin() {
  local pluginName="$1"
  local tarball="marketplace/plugins/$pluginName/$VERSION/${pluginName}-${VERSION}.tar.gz"
  if [ ! -f "$tarball" ]; then
    echo "error: tarball missing for $pluginName: $tarball" >&2
    return 1
  fi
  local url="$ANTHROPIC_MARKETPLACE_API/plugins/$pluginName/versions/$VERSION"
  # `-fS` fails on HTTP error and shows a terse error; `-o /dev/null`
  # discards the response body so a server echo cannot leak the token
  # into our stdout/stderr; `--connect-timeout 10 --max-time 120` bound
  # the request; `--max-redirs 0` forbids redirect-following so the
  # token cannot be forwarded to another host.
  if ! printf 'Authorization: Bearer %s\n' "$ANTHROPIC_TOKEN" \
      | curl -fS -X POST "$url" \
        --connect-timeout 10 --max-time 120 \
        --max-redirs 0 \
        --no-progress-meter \
        -o /dev/null \
        -H @- \
        -F "tarball=@${tarball}"; then
    echo "error: Anthropic POST failed for $pluginName $VERSION" >&2
    return 1
  fi
}

for pluginName in "${PUBLISHED_PLUGINS[@]:-}"; do
  [ -n "$pluginName" ] || continue
  if ! postOnePlugin "$pluginName"; then
    rollbackSelfHosted
    exit 1
  fi
done

# Successful run — drop the rollback snapshots.
if [ -n "$SELF_HOSTED_BACKUP" ]; then
  rm -f -- "$SELF_HOSTED_BACKUP" || true
fi
for backup in "${ROLLBACK_TARBALL_BACKUPS[@]:-}"; do
  [ -n "$backup" ] && rm -f -- "$backup" 2>/dev/null || true
done

exit 0
