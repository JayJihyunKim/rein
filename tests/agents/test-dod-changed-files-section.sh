#!/usr/bin/env bash
# tests/agents/test-dod-changed-files-section.sh — G3 Phase 4 Task 4.4
#
# Verifies that the 5 DoD-writer agents (spec §3.5) AND operating-sequence.md
# enumerate the `## 변경 파일` obligation, so that new DoDs include a
# repo-relative literal path bullet list which the post-edit-meta-check.sh
# sub-hook can compare against the dirty git diff.
#
# 6 assertions (5 agents + 1 rule). docs-writer / security-reviewer are
# explicitly out of scope per spec §3.5 (no DoD writing instruction).
#
# Scope ID: G3-DOD-TEMPLATE-CHANGED-FILES-SECTION
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

FILES=(
  "plugins/rein-core/agents/feature-builder.md"
  "plugins/rein-core/agents/feature-builder-fix.md"
  "plugins/rein-core/agents/feature-builder-refactor.md"
  "plugins/rein-core/agents/plan-writer.md"
  "plugins/rein-core/agents/researcher.md"
  "plugins/rein-core/rules/operating-sequence.md"
)

FAILED=0
for F in "${FILES[@]}"; do
  [ -f "$F" ] || { echo "FAIL: $F missing" >&2; FAILED=$((FAILED+1)); continue; }

  # (a) `## 변경 파일` 헤더 또는 명시적 언급 substring
  if ! grep -q "## 변경 파일" "$F"; then
    echo "FAIL: $F missing '## 변경 파일' substring" >&2
    FAILED=$((FAILED+1))
    continue
  fi

  # (b) `repo-relative literal path` 키워드 substring (instruction 본문 확인)
  if ! grep -q "repo-relative literal path" "$F"; then
    echo "FAIL: $F missing 'repo-relative literal path' keyword (instruction body)" >&2
    FAILED=$((FAILED+1))
    continue
  fi

  echo "OK: $F"
done

if [ "$FAILED" -gt 0 ]; then
  echo "test-dod-changed-files-section: FAIL — $FAILED file(s) missing required instruction" >&2
  exit 1
fi

echo "test-dod-changed-files-section: OK (6 files contain '## 변경 파일' + 'repo-relative literal path')"
