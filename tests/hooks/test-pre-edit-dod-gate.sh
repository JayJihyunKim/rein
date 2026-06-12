#!/bin/bash
# tests/hooks/test-pre-edit-dod-gate.sh
#
# Integration tests for Plan A Phase 4 pre-edit-dod-gate.sh extensions:
#   - Task 4.1: 2-tier active DoD selection via lib/select-active-dod.sh
#   - Task 4.2: validator invocation with 30s timeout + §4.2 tier×result table
#   - Task 4.3: no session cache (.claude/cache/dod-gate-validator* forbidden)
#
# Scope IDs:
#   - GI-dod-gate-active-dod-selection
#   - GI-dod-gate-validator-call
#   - GI-dod-gate-cache-invalidation
#   - GI-validator-v2-timeout-fail-closed
#
# Scenarios (Plan A Task 4.4):
#   A. Tier 1 blocking — .active-dod marker + invalid covers → exit 2 + .dod-coverage-mismatch
#   B. Tier 1 pass    — .active-dod marker + valid DoD → exit 0 + no marker
#   C. Tier 2 advisory — no marker + DoD with 범위 연결 + mismatch → exit 0 + .dod-coverage-advisory
#   D. No candidate  — no marker + DoD without 범위 연결 → exit 0 (legacy path)
#   E. Validator timeout — mocked validator sleeps > 30s → exit 2 (Tier 1) + timeout log
#   F. No cache regression — hook invocations never create .claude/cache/dod-gate-validator*

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# _mk_sandbox_extras: beyond the harness defaults, lay down the plan /
# design / DoD files that the validator v2 expects in the sandbox.
#
# Args: $1=kind  one of: tier1-pass | tier1-fail | tier2-fail | no-candidate | tier1-timeout
_mk_sandbox_extras() {
  local kind="$1"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/docs/specs" "$SANDBOX/docs/plans"

  # Copy the real validator + path-policy lib so the hook can call them.
  cp "$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py" \
     "$SANDBOX/scripts/rein-validate-coverage-matrix.py"

  # Design (Scope Items table).
  cat > "$SANDBOX/docs/specs/sample-design.md" <<'EOF'
# Sample design

## Scope Items

| ID | desc |
|----|------|
| S1 | sample item one |
| S2 | sample item two |
EOF

  # Plan with coverage matrix + covers:.
  cat > "$SANDBOX/docs/plans/sample-plan.md" <<'EOF'
# Sample plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/sample-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| S1 | implemented | Phase 1 |
| S2 | implemented | Phase 2 |

## Phase 1
covers: [S1]

## Phase 2
covers: [S2]
EOF

  case "$kind" in
    tier1-pass)
      # Valid DoD: covers ⊆ implemented IDs + marker → Tier 1.
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, S2]
EOF
      cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
      ;;
    tier1-fail)
      # Covers an unknown ID → validator exits 2 → Tier 1 block.
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, ZZZ]
EOF
      cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
      ;;
    tier2-fail)
      # No marker. DoD has 범위 연결 but an unknown ID → validator exits 2 →
      # advisory marker only (Tier 2).
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [NOPE]
EOF
      ;;
    no-candidate)
      # DoD has no '## 범위 연결' — selector returns tier 0.
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-legacy.md" <<'EOF'
# legacy DoD, no 범위 연결
EOF
      ;;
    tier1-timeout)
      # Stand up a fake validator that sleeps > 30s. Replace the copied
      # real validator with a script that exec's `sleep 99`. We use a
      # shorter VALIDATOR_TIMEOUT_S by patching the hook in the sandbox.
      cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'EOF'
#!/usr/bin/env python3
import sys, time
time.sleep(99)
sys.exit(0)
EOF
      chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1]
EOF
      cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
      # Patch sandbox hook to use a 2s timeout for this test only.
      sed -i.bak \
        's/VALIDATOR_TIMEOUT_S=30/VALIDATOR_TIMEOUT_S=2/' \
        "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh"
      rm -f "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh.bak"
      ;;
  esac
}

# Plan-A dod file that avoids the "unreviewed spec" block. We keep the
# sandbox free of .spec-reviews/*.pending so the spec-review gate is inert.

_make_input() {
  # $1 = source file path inside sandbox (relative)
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$abs"
}

# ---- Scenario A: Tier 1 fail → block
test_scenario_A_tier1_invalid_covers_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "Tier 1 + unknown covers → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario B: Tier 1 pass → exit 0, no marker
test_scenario_B_tier1_valid_passes() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "Tier 1 + valid covers → exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario C: Tier 2 fail → advisory (non-blocking)
test_scenario_C_tier2_advisory_non_blocking() {
  _mk_sandbox_extras tier2-fail
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "Tier 2 + unknown covers → advisory, not blocking"
  assert_file_exists "trail/dod/.dod-coverage-advisory"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
}

# ---- Scenario D: no candidate DoD → exit 0 silently (legacy path)
test_scenario_D_no_candidate_passes() {
  _mk_sandbox_extras no-candidate
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "no candidate → pass"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario E: validator timeout (Tier 1) → block + log
test_scenario_E_tier1_timeout_blocks_and_logs() {
  # Skip gracefully if timeout(1) is unavailable (BSD macOS w/o GNU coreutils).
  if ! command -v timeout >/dev/null 2>&1; then
    echo "  SKIP: timeout(1) not on PATH — scenario E not applicable"
    return 0
  fi
  _mk_sandbox_extras tier1-timeout
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "Tier 1 + validator timeout → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  # Timeout log must have been appended.
  if [ ! -f "$SANDBOX/trail/incidents/validator-timeout.log" ]; then
    fail "validator-timeout.log not created"
  else
    grep -q "timeout" "$SANDBOX/trail/incidents/validator-timeout.log" \
      || fail "validator-timeout.log missing 'timeout' entry"
  fi
}

# ---- Scenario F: no cache file is ever created
test_scenario_F_no_cache_regression() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"
  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  # Forbidden pattern: .claude/cache/dod-gate-validator*
  if ls "$SANDBOX/.claude/cache"/dod-gate-validator* >/dev/null 2>&1; then
    fail "forbidden cache file created by pre-edit-dod-gate"
  fi
}

# ---- Scenario G (Phase 7b Task 7.3 Step 7): malformed governance.json
# must trigger fail-closed block + .dod-coverage-mismatch + log append.
test_scenario_G_governance_invalid_fails_closed() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  # Corrupt the governance config. The hook's read_governance_stage
  # should return "INVALID", which the hook converts to fail-closed.
  mkdir -p "$SANDBOX/.claude/.rein-state"
  echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "malformed governance.json → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  # Log must be appended with an invalid_stage entry.
  if [ ! -f "$SANDBOX/trail/incidents/governance-config-invalid.log" ]; then
    fail "governance-config-invalid.log not created"
  else
    grep -q "invalid_stage" "$SANDBOX/trail/incidents/governance-config-invalid.log" \
      || fail "governance-config-invalid.log missing 'invalid_stage' marker"
  fi
  assert_stderr_contains "[rein] The edit gate cannot run because the governance config file"
}

# ---- Scenario H (2026-04-22 retro-review-sweep M1):
# `.claude/rules/*` 는 branch-strategy.md 기준 main 포함 source 이므로 DoD gate
# 를 통과해야 한다. 기존 blanket `*/.claude/*` exemption 이 제거된 결과 검증.
test_scenario_H_m1_claude_rules_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/rules"
  touch "$SANDBOX/.claude/rules/foo.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/rules/foo.md)"

  assert_exit 2 ".claude/rules/foo.md 편집 시 M1 whitelist 상 source → DoD gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario I (M1):
# `.claude/cache/*` 는 hook/validator 가 기록하는 runtime state. DoD 없이도 면제.
# 기존 exemption 유지 확인.
test_scenario_I_m1_claude_cache_exempts() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/cache"
  touch "$SANDBOX/.claude/cache/test"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/cache/test)"

  assert_exit 0 ".claude/cache/test → runtime state 면제로 exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Scenario J (M1):
# repo root 의 AGENTS.md 는 main 포함 — 편집 시 DoD 필요.
test_scenario_J_m1_agents_md_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/AGENTS.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input AGENTS.md)"

  assert_exit 2 "AGENTS.md 편집 시 M1 whitelist 상 source → DoD gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario K (M1):
# `.claude/skills/**` 는 main 포함 — 편집 시 DoD 필요.
test_scenario_K_m1_claude_skills_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/skills/foo"
  touch "$SANDBOX/.claude/skills/foo/SKILL.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/skills/foo/SKILL.md)"

  assert_exit 2 ".claude/skills/foo/SKILL.md 편집 시 M1 whitelist 상 source → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario L (M1 Round 2, 2026-04-22):
# `.gitignore` 는 main 포함 — 편집 시 DoD 필요. 기존 `*.gitignore` 면제는 제거됨.
# Codex Round 1 의 Medium finding 반영.
test_scenario_L_m1_gitignore_blocks() {
  _mk_sandbox_extras tier1-fail
  touch "$SANDBOX/.gitignore"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .gitignore)"

  assert_exit 2 ".gitignore 편집 시 M1 whitelist 상 source → DoD gate block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario L2 (M1 Round 3, 2026-04-22): cache 경로의 .gitignore 도 차단.
# Codex Round 2 finding: `.claude/cache/.gitignore` 는 main 포함 (branch-
# strategy.md) 지만 cache blanket exemption 이 우선해서 bypass 되고 있었음.
# .gitignore 는 위치와 무관하게 항상 source 로 분류해야 한다.
test_scenario_L2_m1_cache_gitignore_still_blocks() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/.claude/cache"
  touch "$SANDBOX/.claude/cache/.gitignore"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input .claude/cache/.gitignore)"

  assert_exit 2 ".claude/cache/.gitignore 편집 시 cache exemption 무시하고 block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ---- Scenario M (M1 Round 2): `.gitkeep` 은 여전히 면제 (placeholder).
test_scenario_M_m1_gitkeep_exempts() {
  _mk_sandbox_extras tier1-fail
  mkdir -p "$SANDBOX/some/dir"
  touch "$SANDBOX/some/dir/.gitkeep"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input some/dir/.gitkeep)"

  assert_exit 0 ".gitkeep → placeholder 면제 exit 0"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ============================================================
# GMF-3: DoD 소스 판정 확장 (behavioral-contract, tightening-only)
#
# IS_SOURCE 판정을 디렉토리 화이트리스트 + 소스 확장자 화이트리스트(additive)
# + 비소스 명시 제외(generated/vendored=source-dir 앞, doc/data/lock=source-dir
# 뒤)로 확장. spec §3.3 / plan §3.3 Phase 3.
#
# 검증 전략: DoD 가 전혀 없는 sandbox(default sandbox_setup, .active-dod 없음,
# dod 파일 없음, .spec-reviews 없음)에서 IS_SOURCE 가 차단의 결정 인자가 되게
# 한다. IS_SOURCE=true → 본문 통과 후 "no active task record" 차단(exit 2),
# IS_SOURCE=false → IS_SOURCE 게이트에서 즉시 exit 0. 이로써 IS_SOURCE 판정만
# 분리 검증한다(기존 시나리오 A~D 의 DoD-validator 경로와 직교).
# ============================================================

# _mk_no_dod_sandbox: GMF-3 검증용 — DoD/spec-review 일체 없는 sandbox.
# 별도 seed 없음(harness 기본 sandbox_setup 만으로 trail/dod 는 비어 있음).
# 파일을 디스크에 만들어 hook 이 실제 경로를 normalize 하게 한다.
_mk_no_dod_src_file() {
  # $1 = relative path inside sandbox
  local rel="$1"
  mkdir -p "$SANDBOX/$(dirname "$rel")"
  touch "$SANDBOX/$rel"
}

# ---- GMF-3 red: 루트 internal/x.go (디렉토리 화이트리스트 밖) → 확장자로 차단
test_gmf3_red_root_internal_go_blocks() {
  _mk_no_dod_src_file "internal/x.go"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input internal/x.go)"

  assert_exit 2 "internal/x.go (source-dir 밖, .go 소스 확장자) → DoD 없으면 차단"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

# ---- GMF-3 red: cmd/main.go (디렉토리 화이트리스트 밖) → 확장자로 차단
test_gmf3_red_cmd_main_go_blocks() {
  _mk_no_dod_src_file "cmd/main.go"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input cmd/main.go)"

  assert_exit 2 "cmd/main.go (source-dir 밖, .go 소스 확장자) → DoD 없으면 차단"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

# ---- GMF-3 green(비소스 통과): docs/README.md (문서)
test_gmf3_green_docs_md_passes() {
  _mk_no_dod_src_file "docs/README.md"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input docs/README.md)"

  assert_exit 0 "docs/README.md (문서 확장자) → 비소스 통과"
}

# ---- GMF-3 green(비소스 통과): 루트 config.json (source-dir 밖 데이터)
test_gmf3_green_root_config_json_passes() {
  _mk_no_dod_src_file "config.json"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input config.json)"

  assert_exit 0 "루트 config.json (데이터 확장자, source-dir 밖) → 비소스 통과"
}

# ---- GMF-3 green(비소스 통과): Cargo.lock (락 파일)
test_gmf3_green_cargo_lock_passes() {
  _mk_no_dod_src_file "Cargo.lock"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input Cargo.lock)"

  assert_exit 0 "Cargo.lock (락 확장자) → 비소스 통과"
}

# ---- GMF-3 green(vendored 통과): vendor/foo.go (소스 확장자지만 vendored)
test_gmf3_green_vendor_go_passes() {
  _mk_no_dod_src_file "vendor/foo.go"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input vendor/foo.go)"

  assert_exit 0 "vendor/foo.go (vendored, source-dir 앞 제외) → 비소스 통과"
}

# ---- GMF-3 green(generated 경계 1): src/generated/api.ts (*/generated/*)
test_gmf3_green_src_generated_dir_passes() {
  _mk_no_dod_src_file "src/generated/api.ts"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input src/generated/api.ts)"

  assert_exit 0 "src/generated/api.ts (*/generated/*, source-dir 앞 제외) → 비소스 통과"
}

# ---- GMF-3 green(generated 경계 2): src/api.generated.ts (*.generated.*)
test_gmf3_green_src_generated_suffix_passes() {
  _mk_no_dod_src_file "src/api.generated.ts"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input src/api.generated.ts)"

  assert_exit 0 "src/api.generated.ts (*.generated.*, source-dir 앞 제외) → 비소스 통과"
}

# ---- GMF-3 green(generated 경계 3 — 불변): src/api.ts (일반 src 소스 → 차단)
test_gmf3_green_src_api_ts_still_blocks() {
  _mk_no_dod_src_file "src/api.ts"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input src/api.ts)"

  assert_exit 2 "src/api.ts (generated 미매칭 → source-dir 로 차단, 불변)"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

# ---- GMF-3 green(불완화): src/schema.json — source-dir 내부 data 는 여전히 차단
test_gmf3_green_src_schema_json_still_blocks() {
  _mk_no_dod_src_file "src/schema.json"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input src/schema.json)"

  assert_exit 2 "src/schema.json (source-dir 내부 → doc/data 제외가 통과시키면 안 됨, 불완화)"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

# ---- GMF-3 green(불완화): scripts/config.yaml — source-dir 내부 data 는 여전히 차단
test_gmf3_green_scripts_config_yaml_still_blocks() {
  _mk_no_dod_src_file "scripts/config.yaml"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input scripts/config.yaml)"

  assert_exit 2 "scripts/config.yaml (source-dir 내부 → 불완화 유지)"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

# ---- GMF-3 green(불완화): src/app.ts — 기존 source-dir 소스 차단 유지
test_gmf3_green_src_app_ts_still_blocks() {
  _mk_no_dod_src_file "src/app.ts"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input src/app.ts)"

  assert_exit 2 "src/app.ts (source-dir 소스 → 차단 유지, 불변)"
  assert_stderr_contains "[rein] Source files cannot be edited yet"
}

# ---- GMF-3 안내: 확장자 판정 새 차단 시 이유 메시지 stderr (파일경로당 1회)
test_gmf3_ext_notice_first_block_emits_reason() {
  _mk_no_dod_src_file "internal/x.go"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input internal/x.go)"

  assert_exit 2 "확장자-소스 첫 차단 → exit 2"
  # 확장자 기준(디렉토리 아님)으로 DoD 를 요구한다는 구분 가능한 안내.
  assert_stderr_contains "소스 확장자"
}

# ---- GMF-3 안내: 같은 파일 두 번째 차단 시 안내 없음 (파일경로당 1회)
test_gmf3_ext_notice_suppressed_second_block() {
  _mk_no_dod_src_file "internal/x.go"

  # 1회차 — 안내 출력 + marker 생성
  run_hook "pre-edit-dod-gate.sh" "$(_make_input internal/x.go)"
  assert_exit 2 "1회차 차단"

  # 2회차 — 같은 경로 → 안내 억제
  run_hook "pre-edit-dod-gate.sh" "$(_make_input internal/x.go)"
  assert_exit 2 "2회차도 차단(불변)"
  echo "$HOOK_STDERR" | grep -qF "소스 확장자" \
    && fail "같은 파일 2회차 차단에서 확장자 안내가 억제되지 않음(파일경로당 1회 위반)"
}

# ---- GMF-3 안내: 다른 확장자-소스 파일은 첫 차단 시 안내 있음 (경로 단위 억제)
test_gmf3_ext_notice_per_path_distinct_files() {
  _mk_no_dod_src_file "internal/x.go"
  _mk_no_dod_src_file "cmd/main.go"

  # internal/x.go 첫 차단 → 안내 + marker
  run_hook "pre-edit-dod-gate.sh" "$(_make_input internal/x.go)"
  assert_stderr_contains "소스 확장자"

  # cmd/main.go 는 다른 경로 → 첫 차단이므로 안내 있어야 함
  run_hook "pre-edit-dod-gate.sh" "$(_make_input cmd/main.go)"
  assert_stderr_contains "소스 확장자"
}

# ---- GMF-3 안내: 디렉토리 매칭 차단(확장자 아님)은 안내 없음 (기존 동작 불변)
test_gmf3_dir_match_block_no_ext_notice() {
  _mk_no_dod_src_file "src/app.ts"

  run_hook "pre-edit-dod-gate.sh" "$(_make_input src/app.ts)"

  assert_exit 2 "src/app.ts (디렉토리 매칭) → 차단"
  echo "$HOOK_STDERR" | grep -qF "소스 확장자" \
    && fail "디렉토리 매칭 차단에서 확장자 안내가 잘못 출력됨(EXT_SOURCE_HIT 아님)"
}

# ============================================================
# GMF-4 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4): policy-toggle
# fail-open seal. The old top block hard-coded `python3` and `if ! python3
# <loader>; then exit 0`, so an absent interpreter (127) or Windows stub (49)
# turned the DoD gate OFF, mistaking interpreter-absence for a user disable.
# The fix moves the policy check after resolve_python (which already fail-
# closes rc 10/11/12 → exit 2) and calls the loader via "${PYTHON_RUNNER[@]}",
# distinguishing loader rc==1 (user disable → exit 0) from rc∉{0,1} / absence
# (fail-closed → gate active). Gate-active here = a DoD-less source edit blocks.
# ============================================================

HOOK_PEDG="pre-edit-dod-gate.sh"

_seed_policy_loader() {
  local rc="$1"
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<PY
import sys
sys.exit($rc)
PY
}

_run_pedg_missing_python() {
  local stdin_json="$1"
  local out
  out=$(
    with_missing_python
    printf '%s' "$stdin_json" \
      | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
        REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$HOOK_PEDG" 2>&1
    printf '_RC=%s\n' "$?"
    cleanup_fakes
  )
  HOOK_EXIT=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)
  HOOK_STDERR=$(printf '%s' "$out" | grep -v '^_RC=' || true)
}

_run_pedg_real_python() {
  local stdin_json="$1"
  local tmp_out tmp_err
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  printf '%s' "$stdin_json" \
    | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/$HOOK_PEDG" >"$tmp_out" 2>"$tmp_err"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_out")
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"
}

# RED → GREEN: python3 absent must not disable the DoD gate. A DoD-less source
# edit (src/app.ts) must still block. Current code: `! python3` (127) → exit 0.
test_gmf4_python_absent_does_not_disable_gate() {
  _mk_no_dod_src_file "src/app.ts"
  _seed_policy_loader 0
  _run_pedg_missing_python "$(_make_input src/app.ts)"
  [ "$HOOK_EXIT" != "0" ] \
    || fail "GMF-4 python absent must NOT disable the DoD gate (got exit 0 = fail-open)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 python absent should fail closed via resolver (expected exit 2, got: $HOOK_EXIT)"
}

# GREEN: python present + policy DISABLE (loader rc 1) → gate OFF (exit 0),
# even for a DoD-less source edit that would otherwise block.
test_gmf4_policy_disable_exits_zero() {
  _mk_no_dod_src_file "src/app.ts"
  _seed_policy_loader 1
  _run_pedg_real_python "$(_make_input src/app.ts)"
  [ "$HOOK_EXIT" = "0" ] \
    || fail "GMF-4 policy disable (loader rc1) should exit 0 (got: $HOOK_EXIT; stderr: $HOOK_STDERR)"
}

# GREEN: python present + policy ENABLE (loader rc 0) → gate body runs and
# blocks the DoD-less source edit (exit 2).
test_gmf4_policy_enable_enters_body() {
  _mk_no_dod_src_file "src/app.ts"
  _seed_policy_loader 0
  _run_pedg_real_python "$(_make_input src/app.ts)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 policy enable should enter the gate body and block (expected exit 2, got: $HOOK_EXIT)"
  echo "$HOOK_STDERR" | grep -qF "[rein] Source files cannot be edited yet" \
    || fail "GMF-4 policy enable should surface the no-active-task-record block"
}

# GREEN: loader CRASH (rc 3) with python present → fail-closed, gate active
# (blocks the DoD-less source edit, not mistaking crash for disable).
test_gmf4_loader_crash_fails_closed() {
  _mk_no_dod_src_file "src/app.ts"
  _seed_policy_loader 3
  _run_pedg_real_python "$(_make_input src/app.ts)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 loader crash (rc3) should fail closed and block (expected exit 2, got: $HOOK_EXIT)"
}

main() {
  run_test test_scenario_A_tier1_invalid_covers_blocks pre-edit-dod-gate.sh
  run_test test_scenario_B_tier1_valid_passes          pre-edit-dod-gate.sh
  run_test test_scenario_C_tier2_advisory_non_blocking pre-edit-dod-gate.sh
  run_test test_scenario_D_no_candidate_passes         pre-edit-dod-gate.sh
  run_test test_scenario_E_tier1_timeout_blocks_and_logs pre-edit-dod-gate.sh
  run_test test_scenario_F_no_cache_regression         pre-edit-dod-gate.sh
  run_test test_scenario_G_governance_invalid_fails_closed pre-edit-dod-gate.sh
  run_test test_scenario_H_m1_claude_rules_blocks      pre-edit-dod-gate.sh
  run_test test_scenario_I_m1_claude_cache_exempts     pre-edit-dod-gate.sh
  run_test test_scenario_J_m1_agents_md_blocks         pre-edit-dod-gate.sh
  run_test test_scenario_K_m1_claude_skills_blocks     pre-edit-dod-gate.sh
  run_test test_scenario_L_m1_gitignore_blocks         pre-edit-dod-gate.sh
  run_test test_scenario_L2_m1_cache_gitignore_still_blocks pre-edit-dod-gate.sh
  run_test test_scenario_M_m1_gitkeep_exempts          pre-edit-dod-gate.sh
  # GMF-3: DoD 소스 판정 확장
  run_test test_gmf3_red_root_internal_go_blocks       pre-edit-dod-gate.sh
  run_test test_gmf3_red_cmd_main_go_blocks            pre-edit-dod-gate.sh
  run_test test_gmf3_green_docs_md_passes              pre-edit-dod-gate.sh
  run_test test_gmf3_green_root_config_json_passes     pre-edit-dod-gate.sh
  run_test test_gmf3_green_cargo_lock_passes           pre-edit-dod-gate.sh
  run_test test_gmf3_green_vendor_go_passes            pre-edit-dod-gate.sh
  run_test test_gmf3_green_src_generated_dir_passes    pre-edit-dod-gate.sh
  run_test test_gmf3_green_src_generated_suffix_passes pre-edit-dod-gate.sh
  run_test test_gmf3_green_src_api_ts_still_blocks     pre-edit-dod-gate.sh
  run_test test_gmf3_green_src_schema_json_still_blocks pre-edit-dod-gate.sh
  run_test test_gmf3_green_scripts_config_yaml_still_blocks pre-edit-dod-gate.sh
  run_test test_gmf3_green_src_app_ts_still_blocks     pre-edit-dod-gate.sh
  run_test test_gmf3_ext_notice_first_block_emits_reason pre-edit-dod-gate.sh
  run_test test_gmf3_ext_notice_suppressed_second_block pre-edit-dod-gate.sh
  run_test test_gmf3_ext_notice_per_path_distinct_files pre-edit-dod-gate.sh
  run_test test_gmf3_dir_match_block_no_ext_notice     pre-edit-dod-gate.sh
  # GMF-4: 정책 토글 fail-open 봉합
  run_test test_gmf4_python_absent_does_not_disable_gate pre-edit-dod-gate.sh
  run_test test_gmf4_policy_disable_exits_zero         pre-edit-dod-gate.sh
  run_test test_gmf4_policy_enable_enters_body         pre-edit-dod-gate.sh
  run_test test_gmf4_loader_crash_fails_closed         pre-edit-dod-gate.sh
  summary
}

main "$@"
