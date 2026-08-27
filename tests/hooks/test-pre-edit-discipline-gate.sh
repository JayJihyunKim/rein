#!/bin/bash
# tests/hooks/test-pre-edit-discipline-gate.sh
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대, 2026-08-21): pre-edit-dod-gate.sh 는
# 삭제되고 두 신설 훅으로 교대된다.
#   - pre-edit-discipline-gate.sh — 정책 토글(GMF-4)·추출/0x1F/LF 하드닝·
#     PERF-2 캐시 공급·소스 분류 면제·거버넌스 훼손 차단(lib/
#     governance-invalid-gate.sh 경유, 동작 동일)·incident-review·dod-found·
#     spec-review·routing 을 전부 물려받는다. 활성작업(active-task) 최종
#     판정만 빠진다 — 그 축은 pre-edit-task-gate.sh 가 전담(v2 위임 100%,
#     v1 폴백 소멸).
#   - pre-edit-task-gate.sh — 활성작업 축 v2 1급 래퍼(별도 파일,
#     tests/hooks/test-pre-edit-task-gate.sh + tests/hooks/
#     test-active-task-authority-switch.sh 참조).
#
# 이 파일은 이전 tests/hooks/test-pre-edit-dod-gate.sh 에서 discipline-gate
# 관할 축(governance-invalid/Z1·Z2 boundary/GMF-4 policy toggle/SEC-1
# malformed-extraction hardening)만 물려받는다. GMF-3(소스 분류 경계)·SEC-1
# sanity·SEC-2(개행 임베딩)는 활성작업 축의 차단이 관측 가능해야 의미가
# 있으므로 tests/hooks/test-pre-edit-task-gate.sh 로 이동했다(그 파일 헤더
# 참조 — discipline-gate 는 더 이상 "활성 작업 없음" 으로 차단하지 않기
# 때문에 이 훅 단독으로는 IS_SOURCE=true/false 를 관측적으로 구분할 수 없다).
#
# Original scope IDs:
#   - GI-dod-gate-active-dod-selection
#   - GI-dod-gate-validator-call
#   - GI-dod-gate-cache-invalidation
#   - GI-validator-v2-timeout-fail-closed

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

_mk_sandbox_extras() {
  # 유지: feature-builder-refactor task step 1 의 유일한 kind ("tier1-pass").
  local kind="$1"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/docs/specs" "$SANDBOX/docs/plans"

  cp "$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py" \
     "$SANDBOX/scripts/rein-validate-coverage-matrix.py"

  cat > "$SANDBOX/docs/specs/sample-design.md" <<'EOF'
# Sample design

## Scope Items

| ID | desc |
|----|------|
| S1 | sample item one |
| S2 | sample item two |
EOF

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
  esac
}

_make_input() {
  # $1 = source file path inside sandbox (relative)
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$abs"
}

# ---- Scenario G: malformed governance.json must trigger fail-closed block +
# .dod-coverage-mismatch + log append. Still owned inline by discipline-gate
# (via lib/governance-invalid-gate.sh — same behavior, just extracted into a
# named lib per the rotation contract's "거버넌스 훼손 차단" bullet).
test_scenario_G_governance_invalid_fails_closed() {
  _mk_sandbox_extras tier1-pass
  touch "$SANDBOX/scripts/foo.sh"

  mkdir -p "$SANDBOX/.claude/.rein-state"
  echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"

  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "malformed governance.json → block"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  if [ ! -f "$SANDBOX/trail/incidents/governance-config-invalid.log" ]; then
    fail "governance-config-invalid.log not created"
  else
    grep -q "invalid_stage" "$SANDBOX/trail/incidents/governance-config-invalid.log" \
      || fail "governance-config-invalid.log missing 'invalid_stage' marker"
  fi
  assert_stderr_contains "[rein] The edit gate cannot run because the governance config file"
}

# ============================================================
# Z. Characterization tests for the split-hook boundary
# (feature-builder-refactor task step 1, Marker B relocation; adapted 2026-08-21
# for the ③-b editing-gate rotation).
# ============================================================

_z_fixture_tier1_fail() {
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/docs/specs" "$SANDBOX/docs/plans"
  cp "$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py" \
     "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  cat > "$SANDBOX/docs/specs/sample-design.md" <<'EOF'
# Sample design

## Scope Items

| ID | desc |
|----|------|
| S1 | sample item one |
EOF
  cat > "$SANDBOX/docs/plans/sample-plan.md" <<'EOF'
# Sample plan

## Design 범위 커버리지 매트릭스

> design ref: docs/specs/sample-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| S1 | implemented | Phase 1 |

## Phase 1
covers: [S1]
EOF
  cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, ZZZ]
EOF
  cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
  touch "$SANDBOX/scripts/foo.sh"
}

# ---- Z1 (adapted, 2026-08-21): the original claim was "DOD_FOUND=true →
# pre-edit-dod-gate.sh alone always allows" (proving the coverage-validator
# check moved out to pre-edit-coverage-gate.sh). After the ③-b rotation,
# discipline-gate no longer performs the active-task judgment AT ALL — so
# the claim generalizes: discipline-gate always allows this Tier-1-FAIL DoD
# fixture regardless of DOD_FOUND, and never touches the coverage markers.
# (This is the discipline-gate side of new case (c) — see
# tests/hooks/test-pre-edit-task-gate.sh header for the task-gate side.)
test_scenario_Z1_discipline_gate_always_allows_coverage_untouched() {
  _z_fixture_tier1_fail

  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 0 "discipline-gate alone always allows now (active-task judgment retired + coverage check delegated)"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
  assert_file_missing "trail/dod/.dod-coverage-advisory"
}

# ---- Z2 (unchanged): same exact fixture, run through the coverage-gate
# hook directly instead — proves the OVERALL PreToolUse(Edit) pipeline
# still blocks this input. 현행 모델(③-b round 6~): coverage-gate 는
# pre-edit-dispatcher.sh 의 순차 후행 자식이며, 프로덕션에서는 선행
# 자식들이 통과했을 때만 실행된다 — 이 테스트의 직접 호출은 그 실행
# 조건이 충족된 상황의 단위 검증이다. This hook's name/behavior is
# untouched by the ③-b rotation.
test_scenario_Z2_coverage_gate_still_blocks_the_same_input() {
  _z_fixture_tier1_fail

  run_hook "pre-edit-coverage-gate.sh" "$(_make_input scripts/foo.sh)"

  assert_exit 2 "the same input the split-off sibling hook still blocks (pipeline behavior unchanged)"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_stderr_contains "[rein] The coverage check failed"
}

# ============================================================
# New case (c) (Phase 7 웨이브 3 ③-b 계약 필수 케이스): discipline-gate 는
# 활성작업 판정을 하지 않는다 — 작업 없음 + 소스 파일이어도 exit 0. 차단은
# (전환된 경우) task-gate 의 v2 위임 몫이다.
# ============================================================
test_case_c_discipline_gate_never_judges_active_task_even_when_source_and_no_dod() {
  # 의도적으로 DoD/inbox/spec-review/routing 전부 비움 — discipline-gate 의
  # 다른 어떤 축도 걸리지 않는 "깨끗한" 상태에서, IS_SOURCE=true 인 파일을
  # 편집해도 활성작업 부재만으로는 차단되지 않음을 증명한다.
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/no-active-task.sh"

  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/no-active-task.sh)"

  assert_exit 0 "case (c): source file + no active DoD anywhere → discipline-gate does not block (그 판정은 task-gate 소관)"
}

# ============================================================
# GMF-4 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4): policy-toggle
# fail-open seal. Now discipline-gate's own toggle (rotation contract: "정책
# 토글(GMF-4, 키=새 이름)"). The old top block hard-coded `python3` and
# `if ! python3 <loader>; then exit 0`, so an absent interpreter (127) or
# Windows stub (49) turned the gate OFF, mistaking interpreter-absence for a
# user disable. The fix moves the policy check after resolve_python (which
# already fail-closes rc 10/11/12 → exit 2) and calls the loader via
# "${PYTHON_RUNNER[@]}", distinguishing loader rc==1 (user disable → exit 0)
# from rc∉{0,1} / absence (fail-closed → gate active).
#
# "gate active" proof fixture (2026-08-21, adapted for ③-b): the original
# fixture used a DoD-less src/app.ts file and asserted the OLD active-task
# block message — that judgment retired from discipline-gate (case (c)
# above), so a DoD-less source edit alone no longer proves the body was
# entered (discipline-gate would allow it either way). We use the
# governance-invalid fixture instead — it blocks UNCONDITIONALLY once the
# gate body runs, independent of DOD_FOUND/active-task state, so it is a
# reliable "did the policy check let us reach the body" proof.
# ============================================================

HOOK_PEDG="pre-edit-discipline-gate.sh"

_seed_policy_loader() {
  local rc="$1"
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<PY
import sys
sys.exit($rc)
PY
}

_seed_governance_invalid() {
  mkdir -p "$SANDBOX/.claude/.rein-state"
  echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"
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

# RED → GREEN: python3 absent must not disable the gate. Any source edit
# must still block (resolve_python fails before the policy toggle is even
# reached, so no governance fixture is needed here).
test_gmf4_python_absent_does_not_disable_gate() {
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/app.sh"
  _seed_policy_loader 0
  _run_pedg_missing_python "$(_make_input scripts/app.sh)"
  [ "$HOOK_EXIT" != "0" ] \
    || fail "GMF-4 python absent must NOT disable the gate (got exit 0 = fail-open)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 python absent should fail closed via resolver (expected exit 2, got: $HOOK_EXIT)"
}

# GREEN: python present + policy DISABLE (loader rc 1) → gate OFF (exit 0),
# even with a corrupt governance.json that would otherwise unconditionally block.
test_gmf4_policy_disable_exits_zero() {
  _seed_governance_invalid
  _seed_policy_loader 1
  _run_pedg_real_python "$(_make_input scripts/app.sh)"
  [ "$HOOK_EXIT" = "0" ] \
    || fail "GMF-4 policy disable (loader rc1) should exit 0 (got: $HOOK_EXIT; stderr: $HOOK_STDERR)"
}

# GREEN: python present + policy ENABLE (loader rc 0) → gate body runs and
# blocks on the unconditional governance-invalid check (exit 2).
test_gmf4_policy_enable_enters_body() {
  _seed_governance_invalid
  _seed_policy_loader 0
  _run_pedg_real_python "$(_make_input scripts/app.sh)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 policy enable should enter the gate body and block (expected exit 2, got: $HOOK_EXIT)"
  echo "$HOOK_STDERR" | grep -qF "[rein] The edit gate cannot run because the governance config file" \
    || fail "GMF-4 policy enable should surface the governance-invalid block"
}

# GREEN: loader CRASH (rc 3) with python present → fail-closed, gate active
# (blocks on the same unconditional governance-invalid check).
test_gmf4_loader_crash_fails_closed() {
  _seed_governance_invalid
  _seed_policy_loader 3
  _run_pedg_real_python "$(_make_input scripts/app.sh)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 loader crash (rc3) should fail closed and block (expected exit 2, got: $HOOK_EXIT)"
}

# ============================================================
# SEC-1 (2026-08-19 보안 검토 실증): 구분자(0x1F) 충돌로 편집 게이트
# 체인 전체 우회 — the count-check itself (fires BEFORE source
# classification, unconditionally on the extracted field shape) stays fully
# owned by discipline-gate and unaffected by the active-task retirement.
# SEC-1's "no false positive on a normal path" sanity check and SEC-2 (the
# LF-embedding variant) both depend on IS_SOURCE driving an OBSERVABLE
# block, which discipline-gate can no longer provide alone — they moved to
# tests/hooks/test-pre-edit-task-gate.sh (see that file's header).
# ============================================================

# _make_input_embedded_sep: JSON text embeds a literal U+001F (ASCII Unit Separator) escape.
_make_input_embedded_sep() {
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s\\u001f%s"},"tool_name":"Edit"}' "$abs" "$2"
}

test_sec1_embedded_separator_in_file_path_fails_closed() {
  run_hook "pre-edit-discipline-gate.sh" "$(_make_input_embedded_sep internal/notes backdoor.go)"

  assert_exit 2 "internal/notes<0x1F>backdoor.go → 구분자 충돌 감지, fail-closed 차단(무음 통과 금지)"
  assert_stderr_contains "malformed field extraction"
  assert_file_contains "trail/incidents/blocks.jsonl" "json parse failure"
}

# ============================================================
# REPRO-1 (Phase 7 wave 3 ③-b code review round 2, High) — 외부에서
# REIN_GATE_PEEK_MODE=1 이 이 ENFORCING 훅의 프로세스 환경에 유입되면,
# routing-gate 의 1회성 바이패스 소비(rm -f)가 조용히 생략되어 바이패스
# 표식이 지워지지 않고 남는다(무한 재사용 가능 — 재현 완료). peek 권한은
# pre-edit-coverage-gate.sh 의 `_rein_precheck_would_block` 서브셸이
# 그 서브셸 수명 동안만 export 하는 내부 계약이며, 이 훅 자신의 진짜
# (enforcing) 호출이 그 값을 물려받아서는 안 된다 — 수리는 판정 lib 를
# source 하기 전에 `unset REIN_GATE_PEEK_MODE` 로 외부 유입값을 강제
# 제거하는 것이다.
#
# 재현 조건 (우회 표식 + 차단 조건): `.routing-missing-*` 마커(라우팅
# 섹션 누락 차단 조건, routing-gate.sh (a)) + `.skip-routing-gate` 1회성
# 바이패스 표식을 함께 심는다. 이 조합에서 routing-gate 는 WARNING 을
# 찍고 바이패스를 소비(rm -f)한 뒤 통과시킨다 — REIN_GATE_PEEK_MODE=1 이
# (버그로) 살아 있으면 그 rm -f 가 생략되어 표식이 남는다.
# ============================================================

test_repro1_leaked_peek_mode_env_must_not_suppress_bypass_consumption() {
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"
  touch "$SANDBOX/trail/dod/.routing-missing-sample"
  echo 'reason=test bypass' > "$SANDBOX/trail/dod/.skip-routing-gate"

  # 외부 오염 시뮬레이션: 이 값은 coverage-gate 의 서브셸이 export 하는
  # 내부 신호일 뿐, 이 프로세스가 절대 물려받아서는 안 된다.
  export REIN_GATE_PEEK_MODE=1
  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/foo.sh)"
  unset REIN_GATE_PEEK_MODE

  assert_exit 0 "missing-section 바이패스가 정상 적용되어 편집은 통과해야 함(경고만, 차단 아님)"
  # leaked REIN_GATE_PEEK_MODE=1 이 이 ENFORCING 호출에서 바이패스 소비(rm -f)
  # 를 억제하면 안 된다 — 표식이 남으면 무한 재사용 가능한 회귀(재현 완료).
  assert_file_missing "trail/dod/.skip-routing-gate"
}

# ============================================================
# REPRO-5 (Phase 7 wave 3 ③-b code review round 2, Medium) —
# hooks/lib/routing-gate.sh 는 함수 진입 시 무조건 `ACTIVE_DODS_TMP=$(mktemp)`
# 를 만들었는데, missing-section 바이패스 없이 차단하는 조기 exit 2 경로는
# 유일한 정리 지점(rm -f, 213행 부근)에 도달하지 못해 차단 1회당 임시파일이
# 하나씩 디스크에 남았다(재현 완료). 수리는 mktemp 호출 자체를 실제 사용
# 지점((b) approved_by_user 섹션 진입 직전)으로 옮겨, 이 조기 exit 경로가
# 임시파일을 아예 만들지 않고 끝나게 하는 것이다.
#
# round 4 갱신 (code review round 4, High): routing-gate.sh 는 이제 (b)
# 섹션에서도 mktemp 를 아예 호출하지 않는다(bash 배열로 대체 — 그 lib
# 파일의 (b) 섹션 head 주석 참조). 이 테스트 자체는 routing-gate 의 mktemp
# 호출을 직접 관측하지 않는다 — with_mktemp_tracker 는 PATH 를 전역으로
# 덮어써 이 프로세스 안에서 일어나는 모든 mktemp 호출(특히 run_hook 자신의
# `tmp_stdout=$(mktemp)` / `tmp_stderr=$(mktemp)`)을 기록하고, 검증하는
# 것은 "기록된 어떤 경로도 훅 실행 후에 남아있지 않다"는 일반적 누수
# 부재 성질이다. 그래서 routing-gate 가 이 시나리오에서 mktemp 를 아예
# 안 부르게 되어도 여전히 유효하게 남는다(415행의 sanity 체크는 run_hook
# 자신의 mktemp 호출로 계속 충족된다).
# ============================================================

test_repro5_routing_gate_no_mktemp_leak_on_missing_section_block() {
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"
  # 바이패스 없음 → routing-gate 의 (a) missing-section 분기가 exit 2 로
  # discipline-gate 전체를 차단한다(213행의 정리 지점에 도달하지 못하는
  # 조기 exit 경로).
  touch "$SANDBOX/trail/dod/.routing-missing-sample"

  local leak_log
  leak_log=$(mktemp)   # 이 훅 자신의 회계 파일 — with_mktemp_tracker 가
                        # PATH 를 바꾸기 전에 실제 시스템 mktemp 로 생성.
  with_mktemp_tracker "$leak_log"

  run_hook "pre-edit-discipline-gate.sh" "$(_make_input scripts/foo.sh)"

  cleanup_fakes

  assert_exit 2 "missing-section (바이패스 없음) → routing-gate 가 discipline-gate 를 통해 차단"

  if [ ! -s "$leak_log" ]; then
    fail "mktemp tracker 가 어떤 임시파일도 기록하지 못함 — routing-gate 가 이 경로에서 더 이상 mktemp 를 호출하지 않는지(수리 후 기대값) 재확인 필요, 아니면 tracker 배선 자체가 깨졌을 수 있음"
  fi
  while IFS= read -r tmp_path; do
    [ -n "$tmp_path" ] || continue
    if [ -e "$tmp_path" ]; then
      fail "routing-gate 의 조기 exit 2 경로에서 임시파일이 정리되지 않고 남음: $tmp_path"
      rm -f "$tmp_path" 2>/dev/null || true
    fi
  done < "$leak_log"
  rm -f "$leak_log"
}

# ============================================================
# REPRO-6 (Phase 7 wave 3 ③-b code review round 3 → round 4 로 대체) —
# routing-gate.sh 의 approved_by_user 판정은 원래 `ACTIVE_DODS_TMP=$(mktemp)`
# 로 만든 임시파일에 active DoD 경로를 모았다가 다시 읽어들이는 구조였다.
# round 3 는 mktemp 자체의 생성 실패(디스크 가득/TMPDIR 쓰기 불가 등)를
# 검사 없이 넘어가 while 루프가 한 번도 안 도는 fail-open 을 fail-closed
# 로 막았다. round 4 리뷰는 그 다음 단계 — "생성은 됐지만 그 뒤 append
# 쓰기가 실패"하는 경우가 여전히 검사되지 않아 같은 fail-open 이
# 재발함을 지적했다(REPRO-7 참조).
#
# 수리(hooks/lib/routing-gate.sh (b) 섹션)는 그 다음 검사를 하나 더
# 추가하는 대신 임시파일 자체를 없애고 bash 배열로 대체했다 — 생성
# 실패/쓰기 실패/읽기 실패라는 세 가지 실패 클래스 전부가 이제 이 함수에
# 존재하지 않는다(배열 append 는 디스크 I/O 가 아니다). 그 결과 이
# fixture(mktemp 자체를 전역으로 실패시키는 주입)는 routing-gate 의
# 승인 판정과 더 이상 아무 관계가 없다 — 그 자체가 이 수리의 증명이다:
# 미승인 DoD 시나리오는 mktemp 가 완전히 고장난 환경에서도 여전히(그리고
# 여전히 같은 이유로) 차단되어야 한다. round 3 전용이었던 "mktemp 실패 →
# fail-closed" 메시지 검증(stderr/blocks.jsonl 에 "mktemp" 문자열 요구)은
# 대상 코드 경로가 사라졌으므로 제거하고, 대신 차단 사유가 (mktemp 관련이
# 아니라) 원래의 승인 누락 사유 그대로임을 직접 단언한다.
#
# with_fake_mktemp_failing 은 PATH 를 전역으로 바꾸지 않는다(그 헬퍼의
# 주석 참조) — run_hook 자신의 `tmp_stdout=$(mktemp)` 호출과 훅 내부의
# `mktemp` 호출이 인자 없이 동일한 형태라 전역 PATH 오염은 테스트
# 하네스 자신도 함께 깨뜨린다. 대신 이 훅 프로세스 1회 실행에만 PATH
# 를 scope 하는 로컬 러너를 이 파일 안에 둔다(같은 패턴이 이미
# tests/hooks/test-bash-guard-log-redaction.sh 의 run_hook_env 에 있다).
# ============================================================

_run_hook_with_fake_mktemp() {
  local hook_name="$1"
  local stdin_json="$2"
  local fake_mktemp_dir="$3"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "$stdin_json" | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
    PATH="$fake_mktemp_dir:$PATH" \
    bash "$SANDBOX/.claude/hooks/$hook_name" \
    > "$tmp_stdout" 2> "$tmp_stderr"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_stdout")
  HOOK_STDERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr"
  return 0
}

test_repro6_routing_gate_unapproved_dod_blocks_even_with_mktemp_globally_broken() {
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  # 실제 위반: '## 라우팅 추천' 섹션은 있지만 approved_by_user: true 가
  # 없다(false). '.routing-missing-*' 마커도, '.spec-review-gen-failed'
  # 마커도 없으므로 (a)/(a2) 조기 차단은 건너뛰고 (b) 섹션(=배열 기반
  # 승인 검사)까지 도달한다.
  cat > "$SANDBOX/trail/dod/dod-2026-08-21-spike3-fixture.md" <<'EOF'
# DoD — spike3 mktemp-failure fixture

## 라우팅 추천
agent: feature-builder
approved_by_user: false
EOF

  local fake_mktemp_dir
  fake_mktemp_dir=$(with_fake_mktemp_failing)
  if [ -z "$fake_mktemp_dir" ]; then
    fail "with_fake_mktemp_failing 자체가 실패 — 테스트 인프라 준비 불능"
    return
  fi

  # mktemp 를 이 훅 프로세스 전체에서 전역으로 고장낸 채로 실행한다 —
  # 배열 기반 수리 후에는 routing-gate 의 승인 판정이 mktemp 를 아예
  # 호출하지 않으므로, 이 주입이 판정에 아무 영향을 주지 못해야 한다
  # (그것이 이 테스트가 증명하려는 성질이다).
  _run_hook_with_fake_mktemp "pre-edit-discipline-gate.sh" \
    "$(_make_input scripts/foo.sh)" "$fake_mktemp_dir"

  rm -rf "$fake_mktemp_dir"

  assert_exit 2 "미승인 active DoD 는 mktemp 전역 고장 여부와 무관하게 차단되어야 함"
  assert_stderr_contains "routing section without user approval"
  assert_file_contains "trail/incidents/blocks.jsonl" "routing"
}

# ============================================================
# REPRO-7 (Phase 7 wave 3 ③-b code review round 4, High) —
# 리뷰어의 정확한 재현 조건: 가짜 mktemp 가 rc=0 으로 "성공"하면서 읽기
# 전용 파일을 반환한다. round 3 수리가 검사하는 "mktemp 가 exit 0 이고
# 반환된 경로가 실제로 존재하는가"는 이 경우 둘 다 통과하지만, 그 다음
# `printf ... >> "$ACTIVE_DODS_TMP"` append 가 조용히(non-fatal) 실패해
# ROUTING_VIOLATIONS 가 빈 채로 남는 — REPRO-6/round 3 와는 다른 지점의
# — fail-open 이었다.
#
# 배열 기반 수리 후에는 routing-gate 가 이 fixture 를 아예 건드리지
# 않는다(mktemp 호출 자체가 없으므로) — 이 테스트는 리뷰어가 제시한
# 정확한 재현 조건을 그대로 재사용해 "미승인 DoD 는 여전히 차단된다"
# 는 동일한 성질을 다시 한번 직접 확인한다. REPRO-6 과 픽스처만 다를
# 뿐 검증하는 성질은 같다 — 두 픽스처 모두(생성 실패 / 생성 성공+쓰기
# 실패) 더 이상 판정에 영향을 줄 수 없음을 각각 증명해 두 실패 지점
# 모두가 막혔음을 보장한다.
# ============================================================

test_repro7_routing_gate_unapproved_dod_blocks_with_readonly_mktemp_fixture() {
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/scripts/foo.sh"

  cat > "$SANDBOX/trail/dod/dod-2026-08-21-spike4-fixture.md" <<'EOF'
# DoD — round 4 readonly-mktemp fixture

## 라우팅 추천
agent: feature-builder
approved_by_user: false
EOF

  local fake_mktemp_dir
  fake_mktemp_dir=$(with_fake_mktemp_succeeding_readonly)
  if [ -z "$fake_mktemp_dir" ]; then
    fail "with_fake_mktemp_succeeding_readonly 자체가 실패 — 테스트 인프라 준비 불능"
    return
  fi

  _run_hook_with_fake_mktemp "pre-edit-discipline-gate.sh" \
    "$(_make_input scripts/foo.sh)" "$fake_mktemp_dir"

  # 정리: 픽스처가 만든 파일이 읽기 전용이므로, 디렉토리 자체의 쓰기
  # 권한만으로 rm 은 되지만 안전하게 지우기 위해 명시적으로 쓰기 권한을
  # 되돌린 뒤 제거한다.
  chmod -R u+w "$fake_mktemp_dir" 2>/dev/null || true
  rm -rf "$fake_mktemp_dir"

  assert_exit 2 "미승인 active DoD 는 mktemp 가 읽기전용 파일을 성공 반환해도 차단되어야 함"
  assert_stderr_contains "routing section without user approval"
  assert_file_contains "trail/incidents/blocks.jsonl" "routing"
}

main() {
  run_test test_scenario_G_governance_invalid_fails_closed pre-edit-discipline-gate.sh
  run_test test_scenario_Z1_discipline_gate_always_allows_coverage_untouched pre-edit-discipline-gate.sh
  run_test test_scenario_Z2_coverage_gate_still_blocks_the_same_input pre-edit-discipline-gate.sh pre-edit-coverage-gate.sh
  run_test test_case_c_discipline_gate_never_judges_active_task_even_when_source_and_no_dod pre-edit-discipline-gate.sh
  # GMF-4: 정책 토글 fail-open 봉합
  run_test test_gmf4_python_absent_does_not_disable_gate pre-edit-discipline-gate.sh
  run_test test_gmf4_policy_disable_exits_zero         pre-edit-discipline-gate.sh
  run_test test_gmf4_policy_enable_enters_body         pre-edit-discipline-gate.sh
  run_test test_gmf4_loader_crash_fails_closed         pre-edit-discipline-gate.sh
  # SEC-1: 구분자(0x1F) 충돌로 인한 게이트 우회 회귀 방지 (malformed-extraction only)
  run_test test_sec1_embedded_separator_in_file_path_fails_closed pre-edit-discipline-gate.sh
  # REPRO-1/REPRO-5: code review round 2 재현 항목 회귀 방지
  run_test test_repro1_leaked_peek_mode_env_must_not_suppress_bypass_consumption pre-edit-discipline-gate.sh
  run_test test_repro5_routing_gate_no_mktemp_leak_on_missing_section_block pre-edit-discipline-gate.sh
  # REPRO-6/7: code review round 3/4 재현 항목 회귀 방지 (mktemp 생성 실패 /
  # 생성 성공+쓰기 실패 — 둘 다 배열 기반 수리 후 판정에 영향 없어야 함)
  run_test test_repro6_routing_gate_unapproved_dod_blocks_even_with_mktemp_globally_broken pre-edit-discipline-gate.sh
  run_test test_repro7_routing_gate_unapproved_dod_blocks_with_readonly_mktemp_fixture pre-edit-discipline-gate.sh
  summary
}

main "$@"
