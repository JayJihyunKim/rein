#!/bin/bash
# tests/hooks/test-skill-mcp-inventory.sh
#
# Skill/MCP 인벤토리 스캔 + 훅 통합 테스트.
# HOME=$SANDBOX/.fakehome 로 격리 → 실제 ~/.claude 건드리지 않음.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Python 스캔 스크립트를 HOME 격리 상태로 실행
run_scanner() {
  local sandbox_home="$1"
  HOME="$sandbox_home" python3 "$REAL_PROJECT_DIR/scripts/rein-scan-skill-mcp.py" \
    --project-dir "$SANDBOX" --scan
}

# 스킬 디렉토리 + SKILL.md 생성
seed_skill() {
  # $1=base_dir (절대경로), $2=skill_name, $3=desc (optional)
  local base_dir="$1"
  local skill_name="$2"
  local desc="${3:-test skill}"
  mkdir -p "$base_dir/$skill_name"
  cat > "$base_dir/$skill_name/SKILL.md" <<EOF
---
name: $skill_name
description: $desc
---

# Skill: $skill_name
EOF
}

# 가짜 home 디렉토리 초기화
setup_fakehome() {
  local fakehome="$SANDBOX/.fakehome"
  mkdir -p "$fakehome/.claude/skills"
  mkdir -p "$fakehome/.claude/plugins/cache"
  echo "$fakehome"
}

seed_initialized_rein_project() {
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/project.json" <<'JSON'
{"mode":"scaffold","scope":"project","version":"test"}
JSON
  cat > "$SANDBOX/trail/index.md" <<'MD'
# trail/index.md

## 현재 상태

- test fixture
MD
}

# ---------------------------------------------------------------------------
# 스캔 테스트
# ---------------------------------------------------------------------------

test_scan_empty_project() {
  local fakehome
  fakehome=$(setup_fakehome)
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  [ $? -eq 0 ] || fail "scanner should exit 0 on empty project"
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["skill_count"]==0, "expected 0 skills, got " + str(d["skill_count"])' \
    || fail "skill_count should be 0"
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["mcp_count"]==0, "expected 0 mcps, got " + str(d["mcp_count"])' \
    || fail "mcp_count should be 0"
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert "needs_regen" in d' \
    || fail "needs_regen key missing"
}

test_scan_user_skills_only() {
  local fakehome
  fakehome=$(setup_fakehome)
  seed_skill "$fakehome/.claude/skills" "my-skill" "A user skill"
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["skill_count"]==1, "expected 1 skill, got " + str(d["skill_count"])' \
    || fail "skill_count should be 1 (user skill only)"
}

test_scan_project_skills_only() {
  local fakehome
  fakehome=$(setup_fakehome)
  mkdir -p "$SANDBOX/.claude/skills"
  seed_skill "$SANDBOX/.claude/skills" "proj-skill" "A project skill"
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["skill_count"]==1, "expected 1 skill, got " + str(d["skill_count"])' \
    || fail "skill_count should be 1 (project skill only)"
}

test_scan_both() {
  local fakehome
  fakehome=$(setup_fakehome)
  seed_skill "$fakehome/.claude/skills" "user-skill" "User skill"
  mkdir -p "$SANDBOX/.claude/skills"
  seed_skill "$SANDBOX/.claude/skills" "proj-skill" "Project skill"
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["skill_count"]==2, "expected 2, got " + str(d["skill_count"])' \
    || fail "skill_count should be 2 (user + project)"
}

test_scan_mcps_from_json() {
  local fakehome
  fakehome=$(setup_fakehome)
  # ~/.claude.json with mcpServers
  cat > "$fakehome/.claude.json" <<'EOF'
{
  "mcpServers": {
    "context7": {"command": "npx", "args": ["-y", "@context7/mcp"]},
    "tavily": {"command": "npx", "args": ["-y", "tavily-mcp"]}
  }
}
EOF
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["mcp_count"]==2, "expected 2 mcps, got " + str(d["mcp_count"])' \
    || fail "mcp_count should be 2"
}

# ---------------------------------------------------------------------------
# 해시 테스트
# ---------------------------------------------------------------------------

test_hash_stable() {
  local fakehome
  fakehome=$(setup_fakehome)
  seed_skill "$fakehome/.claude/skills" "stable-skill" "desc"
  local out1 out2 h1 h2
  out1=$(run_scanner "$fakehome" 2>/dev/null)
  out2=$(run_scanner "$fakehome" 2>/dev/null)
  h1=$(echo "$out1" | python3 -c 'import json, sys; print(json.load(sys.stdin)["new_hash"])')
  h2=$(echo "$out2" | python3 -c 'import json, sys; print(json.load(sys.stdin)["new_hash"])')
  [ "$h1" = "$h2" ] || fail "hash should be stable across runs (got $h1 vs $h2)"
}

test_hash_changes_on_skill_added() {
  local fakehome
  fakehome=$(setup_fakehome)
  local out1 h1 out2 h2
  # First scan (no skills)
  out1=$(run_scanner "$fakehome" 2>/dev/null)
  h1=$(echo "$out1" | python3 -c 'import json, sys; print(json.load(sys.stdin)["new_hash"])')
  # Add a skill
  seed_skill "$fakehome/.claude/skills" "new-skill" "Added skill"
  out2=$(run_scanner "$fakehome" 2>/dev/null)
  h2=$(echo "$out2" | python3 -c 'import json, sys; print(json.load(sys.stdin)["new_hash"])')
  [ "$h1" != "$h2" ] || fail "hash should change after adding a skill"
}

# ---------------------------------------------------------------------------
# 캐시 파일 테스트
# ---------------------------------------------------------------------------

test_first_scan_creates_inventory() {
  local fakehome
  fakehome=$(setup_fakehome)
  run_scanner "$fakehome" >/dev/null 2>&1
  assert_file_exists ".claude/cache/skill-mcp-inventory.json"
}

test_needs_regen_first_run() {
  local fakehome
  fakehome=$(setup_fakehome)
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  # No prior inventory AND no guide → needs_regen=true
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["needs_regen"]==True, "first run should need regen"' \
    || fail "needs_regen should be true on first run (no cache)"
}

test_needs_regen_no_change() {
  local fakehome
  fakehome=$(setup_fakehome)
  seed_skill "$fakehome/.claude/skills" "same-skill" "desc"
  # Create a fake guide so guide_exists=true
  mkdir -p "$SANDBOX/.claude/cache"
  echo "# guide" > "$SANDBOX/.claude/cache/skill-mcp-guide.md"
  # First scan stores inventory
  run_scanner "$fakehome" >/dev/null 2>&1
  # Second scan — same inventory, guide exists → needs_regen=false
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["needs_regen"]==False, "no change should not need regen"' \
    || fail "needs_regen should be false when nothing changed"
}

test_needs_regen_new_skill() {
  local fakehome
  fakehome=$(setup_fakehome)
  # Create guide
  mkdir -p "$SANDBOX/.claude/cache"
  echo "# guide" > "$SANDBOX/.claude/cache/skill-mcp-guide.md"
  # First scan (no skills)
  run_scanner "$fakehome" >/dev/null 2>&1
  # Add a skill
  seed_skill "$fakehome/.claude/skills" "brand-new" "New skill"
  # Second scan → needs_regen=true
  local out
  out=$(run_scanner "$fakehome" 2>/dev/null)
  echo "$out" | python3 -c 'import json, sys; d=json.load(sys.stdin); assert d["needs_regen"]==True, "new skill should trigger regen"' \
    || fail "needs_regen should be true when a new skill is added"
}

# ---------------------------------------------------------------------------
# SessionStart 훅 출력 테스트
# ---------------------------------------------------------------------------

test_session_start_outputs_guide() {
  # 가이드 파일이 있으면 SessionStart 출력에 포함되어야 함
  seed_initialized_rein_project
  mkdir -p "$SANDBOX/.claude/cache"
  echo "# Skill Guide Content" > "$SANDBOX/.claude/cache/skill-mcp-guide.md"
  # Copy scanner so hook can call it
  cp "$REAL_PROJECT_DIR/scripts/rein-scan-skill-mcp.py" "$SANDBOX/scripts/rein-scan-skill-mcp.py"
  run_hook "session-start-load-trail.sh"
  assert_exit 0 "hook should exit 0"
  echo "$HOOK_STDOUT" | grep -q "Skill/MCP 활용 가이드" || fail "output should contain guide section header"
  echo "$HOOK_STDOUT" | grep -q "Skill Guide Content" || fail "output should contain guide file content"
}

test_session_start_truncates_large_guide() {
  # 6KB 초과 가이드는 잘려야 함
  seed_initialized_rein_project
  mkdir -p "$SANDBOX/.claude/cache"
  # Create a 7KB file
  python3 -c "print('# Big Guide\n' + 'x' * 7200)" > "$SANDBOX/.claude/cache/skill-mcp-guide.md"
  cp "$REAL_PROJECT_DIR/scripts/rein-scan-skill-mcp.py" "$SANDBOX/scripts/rein-scan-skill-mcp.py"
  run_hook "session-start-load-trail.sh"
  assert_exit 0 "hook should exit 0"
  echo "$HOOK_STDOUT" | grep -q "truncated" || fail "output should mention truncation for large guide"
}

test_session_start_uses_cached_guide_without_scan_when_fresh() {
  seed_initialized_rein_project
  mkdir -p "$SANDBOX/.claude/cache"
  echo "# Cached Guide" > "$SANDBOX/.claude/cache/skill-mcp-guide.md"
  cat > "$SANDBOX/.claude/cache/skill-mcp-inventory.json" <<'JSON'
{"hash":"cached","skills":{"user":[],"project":[]},"mcps":{"user":[],"project":[]}}
JSON
  cat > "$SANDBOX/scripts/rein-scan-skill-mcp.py" <<'SH'
#!/usr/bin/env bash
echo scanner should not run >&2
exit 99
SH
  chmod +x "$SANDBOX/scripts/rein-scan-skill-mcp.py"

  run_hook "session-start-load-trail.sh"
  assert_exit 0 "hook should exit 0"
  echo "$HOOK_STDOUT" | grep -q "Cached Guide" || fail "output should contain cached guide"
  echo "$HOOK_STDERR" | grep -q "scanner should not run" && fail "fresh cache should skip scanner"
}

test_session_start_emits_regen_flag() {
  # 처음 스캔 (guide 없음) → 재생성 flag 출력 + stamp 생성
  seed_initialized_rein_project
  cp "$REAL_PROJECT_DIR/scripts/rein-scan-skill-mcp.py" "$SANDBOX/scripts/rein-scan-skill-mcp.py"
  # Ensure no guide exists
  rm -f "$SANDBOX/.claude/cache/skill-mcp-guide.md"
  run_hook "session-start-load-trail.sh"
  assert_exit 0 "hook should exit 0"
  echo "$HOOK_STDOUT" | grep -q "인벤토리 변경 감지\|재생성 필요" || fail "output should mention regen needed"
  assert_file_exists ".claude/cache/.skill-mcp-regen-pending"
}

# ---------------------------------------------------------------------------
# DoD 경고 테스트
# ---------------------------------------------------------------------------

test_dod_warning_active_dod_only() {
  # v0.7.3 routing enforcement 이후: '## 라우팅 추천' 섹션이 없는 legacy DoD 는
  # grandfather 되어 경고 없이 통과한다 (opt-in-by-section-presence).
  seed_dod "dod-2026-04-13-feature-x.md" "# DoD feature-x
## 완료 기준
- 뭔가 한다"
  local json_input
  json_input="{\"tool_input\":{\"file_path\":\"$SANDBOX/scripts/test.py\"}}"

  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/rein-aggregate-incidents.py" 2>/dev/null || true

  run_hook "pre-edit-dod-gate.sh" "$json_input"
  # Legacy DoD 에는 BLOCKED 경고가 뜨지 않아야 한다.
  echo "$HOOK_STDERR" | grep -q "BLOCKED.*라우팅 추천" && fail "legacy DoD should be grandfathered, not blocked"
  echo "$HOOK_STDERR" | grep -q "활용 skill/MCP" && fail "legacy skill/MCP 경고 문구는 이제 존재하지 않아야 한다"
  return 0
}

test_dod_no_warning_with_section() {
  # '## 라우팅 추천' + approved_by_user: true 가 있으면 통과.
  seed_dod "dod-2026-04-13-feature-y.md" "# DoD feature-y
## 완료 기준
- 뭔가 한다

## 라우팅 추천

\`\`\`yaml
agent: feature-builder
skills:
  - codex
mcps: []
rationale:
  - 작업 성격: test
approved_by_user: true
\`\`\`
"
  cp "$REAL_PROJECT_DIR/scripts/rein-aggregate-incidents.py" "$SANDBOX/scripts/rein-aggregate-incidents.py" 2>/dev/null || true

  local json_input
  json_input="{\"tool_input\":{\"file_path\":\"$SANDBOX/scripts/test.py\"}}"
  run_hook "pre-edit-dod-gate.sh" "$json_input"
  # 정상 구성이므로 라우팅 관련 BLOCKED 메시지가 없어야 한다.
  echo "$HOOK_STDERR" | grep -q "BLOCKED.*라우팅 추천" && fail "routing section valid but gate blocked"
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  echo "=== Skill/MCP Inventory Tests ==="
  echo

  # Scan tests (no hooks needed — direct python call)
  run_test test_scan_empty_project
  run_test test_scan_user_skills_only
  run_test test_scan_project_skills_only
  run_test test_scan_both
  run_test test_scan_mcps_from_json

  # Hash tests
  run_test test_hash_stable
  run_test test_hash_changes_on_skill_added

  # Cache tests
  run_test test_first_scan_creates_inventory
  run_test test_needs_regen_first_run
  run_test test_needs_regen_no_change
  run_test test_needs_regen_new_skill

  # SessionStart hook tests
  run_test test_session_start_outputs_guide "session-start-load-trail.sh"
  run_test test_session_start_truncates_large_guide "session-start-load-trail.sh"
  run_test test_session_start_uses_cached_guide_without_scan_when_fresh "session-start-load-trail.sh"
  run_test test_session_start_emits_regen_flag "session-start-load-trail.sh"

  # DoD warning tests
  run_test test_dod_warning_active_dod_only "pre-edit-dod-gate.sh" "rein-aggregate-incidents.py"
  run_test test_dod_no_warning_with_section "pre-edit-dod-gate.sh" "rein-aggregate-incidents.py"

  summary
}

main "$@"
