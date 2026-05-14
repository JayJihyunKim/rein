#!/usr/bin/env bash
# tests/scripts/test-rules-prompt-bundle-drift.sh — Plugin-First Restructure Phase 2 Task 2.1
#
# Drift detection: the 3 prompt-only rule body files mirrored into
# plugins/rein-core/skills/rules-prompt/<name>.md must be sha256-identical
# to their source-of-truth counterparts under .claude/rules/<name>.md.
#
# Mirrored set: code-style.md, security.md, testing.md. The rules-prompt
# skill bundles these so the SessionStart hook
# (plugins/rein-core/hooks/session-start-rules.sh) can read them at
# runtime without crossing back to the rein-dev repo layout. Any drift
# between source and mirror means user sessions would see different rule
# content than rein-dev developers — exactly the regression mode the
# Plugin-First Restructure plan §4 forbids.
#
# Scope ID: prompt-only-rules-inject-via-session-start-hook-on-session-begin
#
# SKIP NOTE (2026-05-14, v1.2.0 cycle 종결): b8f2191 commit 의 Phase 2 Group C
# Task 2.1 work 가 dev 에만 commit 되고 main 에 안 들어간 incomplete 상태.
# plugins/rein-core/skills/rules-prompt/ 디렉토리 부재 — 별 cycle 에서 진행 예정.
# 본 test 는 그 work 가 완료될 때까지 skip.
echo "SKIP: rules-prompt skill bundle work incomplete (b8f2191) — deferred to next cycle"
exit 0

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

SOURCE_DIR=".claude/rules"
MIRROR_DIR="plugins/rein-core/skills/rules-prompt"

RULES=(
  "code-style.md"
  "security.md"
  "testing.md"
)

# Pick a sha256 tool that works on macOS + Linux + Git Bash.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "FAIL: neither sha256sum nor shasum is available" >&2
    exit 1
  fi
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -d "$MIRROR_DIR" ] || fail "mirror dir missing: $MIRROR_DIR (Task 2.1 requires plugins/rein-core/skills/rules-prompt/)"

for rule in "${RULES[@]}"; do
  src="$SOURCE_DIR/$rule"
  dst="$MIRROR_DIR/$rule"
  [ -f "$src" ] || fail "source rule missing: $src"
  [ -f "$dst" ] || fail "plugin mirror missing: $dst"
  src_sha="$(sha256_of "$src")"
  dst_sha="$(sha256_of "$dst")"
  if [ "$src_sha" != "$dst_sha" ]; then
    fail "sha256 drift for rule '$rule': source=$src_sha plugin=$dst_sha"
  fi
done

echo "test-rules-prompt-bundle-drift: OK (3 rule body files mirrored sha256-identical)"
