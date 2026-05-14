#!/usr/bin/env bash
# test-plugin-skills-bundle.sh — Option C parity (post Phase 3, 2026-05-13).
#
# 배경: Option C Phase 3 (2026-05-13) 에서 dev overlay 의 `.claude/skills/` 가
# 폐기되었다. 메인테이너 환경은 `/plugin install rein@rein` 으로 동작하며
# `plugins/rein-core/skills/` 가 단독 SSOT 다.
#
# 본 test 는 Option C 정합을 enforce 한다:
#   (a) Overlay 부재: `.claude/skills/` 디렉토리가 존재하지 않아야 한다.
#       (잔존 시 dev overlay vs plugin SSOT drift 가 재발할 위험)
#   (b) Plugin SSOT presence: `plugins/rein-core/skills/` 가 존재하고
#       비어있지 않다 (최소 1개 skill 디렉토리 포함).
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

OVERLAY_DIR=".claude/skills"
PLUGIN_DIR="plugins/rein-core/skills"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# (a) Overlay 부재 assert — Option C Phase 3 폐기 정합.
if [ -e "$OVERLAY_DIR" ]; then
  fail "dev overlay must be absent post Option C Phase 3: $OVERLAY_DIR exists (remove to restore parity with plugin SSOT)"
fi

# (b) Plugin SSOT presence assert.
if [ ! -d "$PLUGIN_DIR" ]; then
  fail "plugin SSOT missing: $PLUGIN_DIR (rein-core plugin must ship a skills directory)"
fi

# Plugin dir 가 비어있지 않은지 확인 — 최소 1개 skill (디렉토리) 존재.
skill_count="$(find "$PLUGIN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$skill_count" -eq 0 ]; then
  fail "plugin SSOT empty: $PLUGIN_DIR has 0 skill directories (rein-core must ship at least 1 skill)"
fi

echo "test-plugin-skills-bundle: OK (overlay absent + plugin SSOT presence with $skill_count skill(s))"
