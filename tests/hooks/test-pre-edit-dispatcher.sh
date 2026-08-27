#!/bin/bash
# tests/hooks/test-pre-edit-dispatcher.sh
#
# Phase 7 웨이브 3 ③-b (편집 게이트 순차 디스패처, 2026-08-23) — code review
# round 6 High 의 근본 수리 회귀 테스트.
#
# pre-edit-dispatcher.sh 는 hooks.json 의 PreToolUse Edit|Write|MultiEdit
# 매처 그룹에서 pre-edit-discipline-gate.sh / pre-edit-task-gate.sh /
# pre-edit-coverage-gate.sh 세 훅을 대신하는 단일 등록 진입점이다 — 그
# 세 훅을 정확히 이 순서로 순차 실행하고 첫 차단에서 즉시 중단한다.
#
# 이 파일이 다루는 것:
#   - 디스패처 계약 4종: discipline 차단(①), task DENY relay(②), 전체
#     통과(③), 자식 비정상 exit(④)
#   - 로그 카디널리티: 이중 축 동시 차단이 디스패처 경유 시 정확히 1건만
#     남는가 (sibling test-pre-edit-task-gate.sh 의 동명 시나리오는 개별
#     훅 직접 호출 — 단위 계약 — 을 검증한다; 이 파일이 프로덕션 카디널
#     리티를 검증한다)
#   - 로그 계약 정밀화(round 7, High): "차단 판정" 은 이벤트당 최대 1건
#     이지만, 선행 게이트의 우회-허용 감사 기록은 별개 클래스로 추가
#     기록될 수 있다 — 두 클래스가 같은 이벤트에서 함께 발생하면 정확히
#     2건(우회 계열 1 + 차단 판정 1)이 남아야 한다
#   - 핵심 회귀(round 6, High): invalid covers + 미리뷰 스펙 +
#     .skip-spec-gate 우회가 함께 있을 때, 디스패처 경유 실행이면
#     discipline-gate 가 스펙 바이패스를 real 로 소비한 "이후"에도
#     coverage-gate 가 실제로 자신의 validator 를 실행해 잘못된
#     covers 를 잡아내는가 (구 병렬·peek 구조에서는 fail-open 이었다 —
#     수동 재현 증거는 이 사이클의 리뷰 요청서 참조).
#
# 자식 훅 자체의 판정 로직(소스 분류, GMF-3, 활성 DoD 선택, coverage
# validator tier 표 등)은 각자의 전용 테스트(test-pre-edit-discipline-
# gate.sh, test-pre-edit-task-gate.sh, test-pre-edit-coverage-gate.sh)가
# 이미 다룬다 — 이 파일은 오직 디스패처 자신의 오케스트레이션 계약만
# 다룬다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-edit-dispatcher.sh"
# 디스패처를 run_hook() 으로 실행하려면 세 자식 파일도 같은 샌드박스
# 디렉토리에 함께 있어야 한다 (디스패처가 $SCRIPT_DIR 상대경로로 찾는다).
DISPATCHER_FILES="pre-edit-dispatcher.sh pre-edit-discipline-gate.sh pre-edit-task-gate.sh pre-edit-coverage-gate.sh"

_make_input() {
  # $1 = source file path inside sandbox (relative). Includes tool_name
  # ("Edit") — pre-edit-task-gate.sh needs it to pick the tool-specific
  # task-axis policy file (_rein_atg_policy_file_for_tool); a bare
  # tool_input.file_path-only payload (sufficient for discipline-gate/
  # coverage-gate) makes task-gate's v2 delegation attempt silently
  # no-op (empty TOOL_NAME never matches a policy file name) and fall to
  # its FAIL/fail-closed branch instead of genuinely reaching v2 — matches
  # the fuller payload shape tests/hooks/test-pre-edit-task-gate.sh's own
  # _event_payload() builds.
  local abs="$SANDBOX/$1"
  python3 - "$abs" <<'PY'
import json
import sys

file_path = sys.argv[1]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": "Edit",
    "tool_input": {"file_path": file_path, "old_string": "a", "new_string": "b"},
    "cwd": file_path.rsplit("/", 1)[0],
}))
PY
}

# ------------------------------------------------------------
# task-gate 축 고정 helper — tests/hooks/test-pre-edit-task-gate.sh 의
# 동명 helper 와 동일한 원리(실제 rein 패키지/bin 을 링크, 가짜 스텁 아님).
# ------------------------------------------------------------
_link_rein_package() {
  mkdir -p "$SANDBOX/.claude"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/rein" "$SANDBOX/.claude/rein"
}
_link_rein_bin() {
  mkdir -p "$SANDBOX/.claude/bin"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/bin/rein" "$SANDBOX/.claude/bin/rein"
}
_link_task_axis_policy() {
  mkdir -p "$SANDBOX/.rein/policy"
  rm -rf "$SANDBOX/.rein/policy/task-axis"
  cp -R "$REAL_PROJECT_DIR/tests/fixtures/policy/task-axis" "$SANDBOX/.rein/policy/task-axis"
}

# _task_gate_opt_out — 활성-작업 축을 v2 로 전환하지 않은 상태로 고정해
# pre-edit-task-gate.sh 가 NOT_SWITCHED 판정으로 조용히 exit 0 하게 한다
# (문서화된 opt-out — 그 훅 자신의 헤더 판정 트리 참조). is_switched() 는
# override 파일을 읽기 전에 rein.engine.authority 모듈을 import 해야 하고
# (실패하면 무조건 ERROR → fail-closed), 그 import 는 이 lib 자신의 위치
# 기준 self-location 으로 rein 패키지를 찾으므로(hooks/lib/active-task-
# gate.sh 헤더 참조) 패키지 자체는 링크해야 한다 — 대신 authority.yaml 에서
# active_task 를 제외해 "확인 성공 + 미전환"으로 귀결시킨다.
_task_gate_opt_out() {
  _link_rein_package
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - code_review\n  - security_review\n' > "$SANDBOX/.rein/policy/authority.yaml"
}

# _task_gate_switched_deny_no_active_task — 활성-작업 축을 v2 로 전환하고,
# 어떤 활성 작업도 세팅하지 않아 v2 위임이 실제 DENY("no active task
# record")를 내도록 고정한다 (tests/hooks/test-active-task-authority-
# switch.sh 의 시나리오 (b) 와 동일한 fixture 원리).
_task_gate_switched_deny_no_active_task() {
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - active_task\n' > "$SANDBOX/.rein/policy/authority.yaml"
}

_hook_stdout_permission_decision() {
  printf '%s' "$HOOK_STDOUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("")
else:
    hso = data.get("hookSpecificOutput")
    print(hso.get("permissionDecision", "") if isinstance(hso, dict) else "")
' 2>/dev/null
}

# ------------------------------------------------------------
# coverage 축 fixture helper — tests/hooks/test-pre-edit-coverage-gate.sh
# 의 _mk_sandbox_extras 와 동일한 원리(같은 validator/design/plan 형태)를
# 이 파일 전용으로 축약 이식. kind: valid(Tier1 pass) | invalid(Tier1 fail,
# covers 에 미지 ID 포함).
# ------------------------------------------------------------
_mk_coverage_fixture() {
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

  case "$kind" in
    valid)
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1]
EOF
      ;;
    invalid)
      cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD sample
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, UNKNOWN]
EOF
      ;;
  esac
  cat > "$SANDBOX/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-04-21-sample.md
EOF
}

# ============================================================
# ① discipline 차단 → dispatcher exit 2 + 후속 자식 미실행
# ============================================================
test_dispatcher_discipline_block_stops_chain() {
  local src="scripts/foo.sh"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/$src"
  # governance-invalid — discipline-gate 를 무조건 차단시키는 조건. task-
  # gate/coverage-gate 축과는 무관해 서로 간섭하지 않는다(sibling
  # test-pre-edit-task-gate.sh 의 dual-axis 테스트와 같은 fixture). rein
  # 패키지도 링크하지 않는다 — discipline-gate 가 먼저 차단해 dispatcher
  # 가 즉시 중단하므로 task-gate 자체가 실행되지 않아야 하고, 실행되지
  # 않는다면 그 설정 여부는 무관하다(그것이 바로 이 테스트가 증명하려는
  # 것).
  mkdir -p "$SANDBOX/.claude/.rein-state"
  echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"

  run_hook "$HOOK" "$(_make_input "$src")"

  assert_exit 2 "discipline-gate 축(governance-invalid)이 디스패처를 통해 편집을 차단해야 함"
  assert_file_contains "trail/incidents/blocks.jsonl" "governance config invalid"
  # 후속 자식 미실행 증거: task-gate 자신의 차단 사유 문자열이 로그에
  # 전혀 없어야 한다 (실행됐다면 이 문자열이 남았을 것 — ERROR 조건이든
  # opt-out 이든, opt-out 이라면 애초에 로그를 안 남기지만 그건 이 훅이
  # 실행됐는지 여부와 무관하게 참일 수 있으므로, 여기서는 미링크 rein
  # 패키지로 인해 실행됐다면 반드시 남았을 fail-closed 사유 문자열의
  # 부재로 "실행 안 됨"을 관측한다).
  assert_file_not_contains "trail/incidents/blocks.jsonl" "활성 작업"
  # coverage-gate 미실행 증거: 이벤트당 정확히 1건만 남아야 한다 (기존
  # 병렬 모델이었다면 discipline/task/coverage 각자 독립적으로 실행되어
  # 여러 건이 남을 수 있었다 — 디스패처의 첫-차단-중단이 이를 1건으로
  # 되돌린다).
  local count
  count=$(grep -c '"reason"' "$SANDBOX/trail/incidents/blocks.jsonl" 2>/dev/null || echo 0)
  [ "$count" -eq 1 ] || fail "디스패처 경유 차단은 정확히 1건만 남아야 함 (첫 차단 중단) — got: $count"
}

# ============================================================
# ② task DENY 조건 → JSON relay + exit 0 + coverage 미실행
# ============================================================
test_dispatcher_task_deny_relay_skips_coverage() {
  local src="scripts/foo.sh"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/$src"

  # discipline-gate 는 깨끗하게 통과해야 한다 — 사건/스펙/라우팅 조건
  # 없음, governance.json 없음(기본값 유효).
  #
  # task-gate 는 전환 on + 활성 작업 없음 → v2 REAL DENY. 의도적으로
  # trail/dod/dod-*.md 를 전혀 만들지 않는다 — Tier-1 DoD 파일이 하나라도
  # 존재하면 v2 active_task 판정 자체가 "활성 작업 있음"으로 바뀌어
  # "활성 작업 없음" DENY 가 나오지 않는다(실측: _mk_coverage_fixture 를
  # 여기서 같이 쓰면 이 시나리오가 무너진다 — DENY 대신 ALLOW 로 넘어가
  # 버림). Phase 7 웨이브 3 ③-d 갱신: 이전 판은 이 흡수를 "v1 legacy
  # marker dual-read"(`rein.engine.authority` 의 `legacy_status`/
  # `_legacy_active_task_status`) 탓으로 서술했으나, 그 두 함수는 이
  # 웨이브로 authority.py 에서 완전히 삭제됐다(legacy read 계층 전체
  # 제거) — 이 흡수는 v2 자신의 active_task 판정 로직이 DoD 파일 존재를
  # 직접 관측하는 것이지 legacy 대체가 아니었다는 뜻이다(실측 확인:
  # 이 테스트는 그 함수들 제거 이후에도 동일하게 통과한다 — 관측 결과
  # 자체는 무변경, 서술만 정정). 그래서
  # coverage-gate 미실행을 증명하는 방법을 fixture 상태(마커 유무)가
  # 아니라 **coverage-gate 자체를 관측 스텁으로 교체**하는 쪽으로
  # 바꾼다 — 실행됐다면 무조건 흔적을 남기고, DoD 파일 유무와 무관하다.
  cat > "$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh" <<EOF
#!/bin/bash
touch "$SANDBOX/coverage-gate-ran.marker"
exit 0
EOF
  chmod +x "$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh"

  _task_gate_switched_deny_no_active_task

  run_hook "$HOOK" "$(_make_input "$src")"

  assert_exit 0 "v2 relay 는 항상 exit 0 (JSON deny 관례)"
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "디스패처가 v2 DENY 를 relay 하지 않음 (permissionDecision='$decision'): $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"required evidence is missing"*) ;;
    *) fail "relay 된 JSON 이 v2 evaluator 고유 문구를 포함하지 않음 — 진짜 v2 판정이 아닐 수 있음: $HOOK_STDOUT" ;;
  esac

  # coverage-gate 미실행 증거: 관측 스텁이 흔적을 남기지 않아야 한다.
  [ -f "$SANDBOX/coverage-gate-ran.marker" ] \
    && fail "task-gate 의 DENY 이후에도 coverage-gate 가 실행됨 (디스패처가 중단하지 않음)"
  # 로그 카디널리티: task-gate 의 DENY 사유 1건만 남아야 한다.
  assert_file_contains "trail/incidents/blocks.jsonl" "활성 작업 위임 차단 (v2)"
  local count
  count=$(grep -c '"reason"' "$SANDBOX/trail/incidents/blocks.jsonl" 2>/dev/null || echo 0)
  [ "$count" -eq 1 ] || fail "디스패처 경유 DENY relay 는 정확히 1건만 남아야 함 (coverage-gate 미실행) — got: $count"
}

# ============================================================
# ③ 전 축 통과 → exit 0 (coverage-gate 가 실제로 실행되어 자가치유했음을
#    증명 — 유효한 covers 로 이전 상태의 stale marker 를 실제로 지운다)
# ============================================================
test_dispatcher_full_pass_clears_stale_marker() {
  local src="scripts/foo.sh"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/$src"

  _task_gate_opt_out
  _mk_coverage_fixture valid
  # 이전의 잘못된 상태에서 남은 stale marker — Tier1 이 실제로 통과하면
  # coverage-gate 가 이를 지워야 한다(§4.2 outcome table 1:0 분기). 이
  # marker 가 사라지는 것 자체가 "coverage-gate 가 진짜로 실행됐다"는
  # 증거다(단순히 아무것도 안 해도 exit 0 은 나올 수 있으므로).
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_hook "$HOOK" "$(_make_input "$src")"

  assert_exit 0 "유효한 covers + task-gate opt-out 이면 디스패처는 조용히 통과해야 함"
  [ -z "$HOOK_STDOUT" ] || fail "전 축 통과는 stdout 이 비어 있어야 함 (JSON deny 없음): $HOOK_STDOUT"
  assert_file_missing "trail/dod/.dod-coverage-mismatch"
}

# ============================================================
# ④ 자식 비정상 exit(1 등) → fail-closed exit 2 + 명확한 stderr
# ============================================================
test_dispatcher_abnormal_child_exit_fails_closed() {
  local src="scripts/foo.sh"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/$src"

  # discipline-gate 는 깨끗하게 통과 — task-gate 자리를 손상된 스텁으로
  # 교체해 비정상 종료(exit 1)를 시뮬레이션한다.
  cat > "$SANDBOX/.claude/hooks/pre-edit-task-gate.sh" <<'EOF'
#!/bin/bash
echo "simulated crash" >&2
exit 1
EOF
  chmod +x "$SANDBOX/.claude/hooks/pre-edit-task-gate.sh"

  run_hook "$HOOK" "$(_make_input "$src")"

  assert_exit 2 "자식이 비정상 종료(rc=1)하면 디스패처는 fail-closed 해야 함"
  assert_stderr_contains "exited abnormally"
  assert_stderr_contains "pre-edit-task-gate.sh"
}

# ============================================================
# ⑤ 핵심 회귀 (round 6, High) — invalid covers + 미리뷰 스펙 +
#    .skip-spec-gate 우회. discipline-gate 가 스펙 바이패스를 REAL 로
#    소비한 뒤에도 coverage-gate 가 실제로 자신의 validator 를 실행해
#    잘못된 covers 를 잡아내야 한다.
#
# 구 구조(병렬 등록 + coverage-gate 의 same-process peek) 에서는 이
# 시나리오가 fail-open 이었다 — 수동 재현: discipline-gate 를 real 로
# 먼저 실행해 .skip-spec-gate 를 소비시킨 뒤, 그 OLD pre-edit-coverage-
# gate.sh(peek 포함, git HEAD 커밋 09595e0 시점)를 단독 실행하면 peek 가
# "스펙 게이트가 여전히 차단 중"이라고 오판(바이패스가 이미 사라졌으므로
# 재평가 시 차단 조건처럼 보임)해 자신의 validator 를 건너뛰고 exit 0 —
# invalid covers [S1, UNKNOWN] 이 완전히 무검증 통과했다(마커도 생성되지
# 않음). 디스패처 경유(순차 실행 + 이 훅이 실행됐다는 것 자체가 선행
# 게이트 통과의 증명)에서는 coverage-gate 가 애초에 형제 판정을 추론할
# 필요가 없어 정상적으로 자신의 validator 를 실행한다.
# ============================================================
test_scenario_round6_dispatcher_catches_invalid_covers_despite_spec_bypass() {
  local src="scripts/foo.sh"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/$src"

  _task_gate_opt_out
  _mk_coverage_fixture invalid

  # 미리뷰 스펙 — DoD 의 plan 이 가리키는 design 문서에 대한 pending
  # 마커. discipline-gate 의 spec-review-gate 축이 이걸 보고 정상적으로
  # 차단하려 하지만, 아래 .skip-spec-gate 일회성 우회가 그 차단을
  # 면제시킨다(그리고 REAL 로 소비된다).
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  cat > "$SANDBOX/trail/dod/.spec-reviews/round6-spec-block.pending" <<EOF
path=$SANDBOX/docs/specs/sample-design.md
created=2020-01-01T00:00:00
EOF
  echo "reason=test bypass" > "$SANDBOX/trail/dod/.skip-spec-gate"

  run_hook "$HOOK" "$(_make_input "$src")"

  assert_exit 2 "디스패처는 스펙 바이패스와 무관하게 invalid covers 를 잡아내야 함 (round 6 회귀)"
  assert_file_exists "trail/dod/.dod-coverage-mismatch"
  assert_file_contains "trail/incidents/blocks.jsonl" "dod covers mismatch (tier 1)"
  # 스펙 바이패스는 discipline-gate 의 ENFORCING 호출에 의해 REAL 로
  # 소비되어야 한다(일회성 계약 보존 — 디스패처가 이걸 건드리는 것이
  # 아니라 discipline-gate 자신의 정상 동작이다).
  assert_file_missing "trail/dod/.skip-spec-gate"
}

# ============================================================
# ⑥ 로그 계약 정밀화 회귀 (round 7, High) — "이벤트당 차단 로그 최대
#    1건"은 실제로는 **차단 판정**에만 적용되는 서술인데, 이전 리비전은
#    이를 명시하지 않아 과대 서술이었다: 선행 게이트가 사용자의 1회성
#    우회 표식을 소비하며 편집을 **허용**할 때 남기는 감사 기록(우회
#    소비 사실 자체의 로그 — lib/routing-gate.sh 의 MISSING_MARKERS
#    분기, 그 파일 약 95행의 log_block 호출 참조)과, 후행 게이트가 완전히
#    다른 사유로 실제 **차단**할 때 남기는 로그는 서로 다른 클래스다.
#    같은 이벤트에서 둘 다 발생하면 blocks.jsonl 에 정확히 2건(우회
#    계열 1 + 차단 판정 1)이 남아야 한다 — 이것이 회귀가 아니라 계약임을
#    이 테스트로 고정한다(pre-edit-dispatcher.sh / pre-edit-task-gate.sh
#    헤더의 이번 정밀화 참조).
# ============================================================
test_scenario_bypass_allow_plus_downstream_block_yields_two_log_entries() {
  local src="scripts/foo.sh"
  mkdir -p "$SANDBOX/scripts"
  touch "$SANDBOX/$src"

  _task_gate_opt_out
  _mk_coverage_fixture invalid

  # discipline-gate 가 소싱하는 lib/routing-gate.sh 의 (a) 분기: '## 라우팅
  # 추천' 섹션 누락 마커가 있고 1회성 바이패스(.skip-routing-gate)도 함께
  # 있으면, 차단하지 않고 통과시키되 그 우회 소비 사실을 log_block 으로
  # 감사 기록한다("routing missing section bypass"). ACTIVE_DODS 검사(b)는
  # _mk_coverage_fixture 가 만드는 DoD 에 '## 라우팅 추천' 섹션 자체가
  # 없어 opt-in 조건에 걸리지 않으므로 간섭하지 않는다 — discipline-gate
  # 는 결국 이 편집을 허용(exit 0)한다.
  touch "$SANDBOX/trail/dod/.routing-missing-sample"
  echo "reason=test bypass" > "$SANDBOX/trail/dod/.skip-routing-gate"

  run_hook "$HOOK" "$(_make_input "$src")"

  # coverage-gate 가 invalid covers [S1, UNKNOWN] 을 실제로 잡아 디스패처가
  # 차단해야 한다 — discipline-gate 자신은 위 바이패스로 통과했을 뿐 어떤
  # 축도 차단하지 않았다.
  assert_exit 2 "coverage 축의 실제 차단 판정으로 디스패처가 exit 2 해야 함"
  assert_file_contains "trail/incidents/blocks.jsonl" "routing missing section bypass"
  assert_file_contains "trail/incidents/blocks.jsonl" "dod covers mismatch (tier 1)"

  local total_count
  total_count=$(grep -c '"reason"' "$SANDBOX/trail/incidents/blocks.jsonl" 2>/dev/null || echo 0)
  [ "$total_count" -eq 2 ] || fail "우회-허용 감사 기록 1건 + 차단 판정 1건, 합 2건이어야 함 — got: $total_count"

  local block_count
  block_count=$(grep -c '"reason": "dod covers mismatch (tier 1)"' "$SANDBOX/trail/incidents/blocks.jsonl" 2>/dev/null || echo 0)
  [ "$block_count" -eq 1 ] || fail "실제 차단 판정 사유는 정확히 1건이어야 함 (첫-차단-중단) — got: $block_count"

  local bypass_count
  bypass_count=$(grep -c '"reason": "routing missing section bypass"' "$SANDBOX/trail/incidents/blocks.jsonl" 2>/dev/null || echo 0)
  [ "$bypass_count" -eq 1 ] || fail "우회-허용 감사 기록은 정확히 1건이어야 함 — got: $bypass_count"

  # 1회성 바이패스는 discipline-gate 의 ENFORCING 호출에 의해 REAL 로
  # 소비되어야 한다(일회성 계약 보존).
  assert_file_missing "trail/dod/.skip-routing-gate"
}

main() {
  run_test test_dispatcher_discipline_block_stops_chain $DISPATCHER_FILES
  run_test test_dispatcher_task_deny_relay_skips_coverage $DISPATCHER_FILES
  run_test test_dispatcher_full_pass_clears_stale_marker $DISPATCHER_FILES
  run_test test_dispatcher_abnormal_child_exit_fails_closed $DISPATCHER_FILES
  run_test test_scenario_round6_dispatcher_catches_invalid_covers_despite_spec_bypass $DISPATCHER_FILES
  run_test test_scenario_bypass_allow_plus_downstream_block_yields_two_log_entries $DISPATCHER_FILES
  summary
}

main "$@"
