#!/bin/bash
# tests/hooks/test-pre-edit-task-gate.sh
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대, 2026-08-21): pre-edit-dod-gate.sh 는
# 삭제되고 pre-edit-discipline-gate.sh + pre-edit-task-gate.sh 로 교대된다.
#
# 이 파일은 이전 tests/hooks/test-pre-edit-dod-gate.sh 의 GMF-3(소스 분류
# 경계) + SEC-1 sanity + SEC-2(개행 임베딩) 를 물려받는다. 이 세 그룹은 모두
# "IS_SOURCE 판정이 실제로 차단을 좌우하는가" 를 관측하는 테스트인데,
# discipline-gate 는 더 이상 활성작업(active-task) 부재로 차단하지 않으므로
# (pre-edit-discipline-gate.sh 의 case (c) 참조 — 그 훅 단독으로는 소스/
# 비소스 여부와 무관하게 항상 exit 0) 이 관측을 discipline-gate 로는 더 이상
# 할 수 없다. task-gate 는 IS_SOURCE=true 인 경로에서만 v2 위임을 시도하고,
# "활성 작업 없음" 은 v2 가 실제로 DENY 하므로(JSON deny, exit 0), 이 축에서
# IS_SOURCE 경계를 관측하려면 "전환 on + 활성 작업 없음" 고정 fixture 로 v2
# 위임이 실제로 일어나는지(=DENY 관측 + v2 상태 db 존재) 를 봐야 한다 —
# tests/hooks/test-active-task-authority-switch.sh 의 시나리오 (b)/(c)/(d)
# 검증 방식(assert_v1_relayed_v2_deny + _v2_state_db_exists)을 그대로
# 재사용한다. 실제 bin/rein 엔진을 링크해서 쓴다(가짜 스텁이 아니다) —
# "IS_SOURCE=true 인 경로만 위임을 시도한다" 는 소스 분류 그 자체의 경계를
# 증명하는 것이 목적이지, v2 엔진의 판정 로직 자체를 재검증하는 것이 목적이
# 아니기 때문에, 실제 엔진의 실제 "활성 작업 없음 → DENY" 판정을 관측 신호로
# 그대로 빌려 쓴다.
#
# 신규 케이스 (a)/(b) (편집 게이트 교대 계약 필수 케이스)는 이 파일에서
# 중복 작성하지 않는다 — tests/hooks/test-active-task-authority-switch.sh 가
# 이미 그 정확한 시나리오를 전담한다:
#   (a) task-gate FAIL 경로 fail-closed exit 2 (bin/rein 부재 또는 정책 파일
#       부재) — 그 파일의 시나리오 (g)(엔진 스크립트 손상)·(h)(정책 파일
#       부재)가 이를 커버한다(2026-08-21, ③-b 갱신 시 hook 대상만
#       pre-edit-task-gate.sh 로 교체 + exit2 메시지 검증을 fail-closed
#       방향으로만 완화 — 그 파일 자체의 변경 이력 참조).
#   (b) 미전환 상태 exit 0 — 그 파일의 시나리오 (e)(2026-08-21 갱신: 구
#       "전환 off → v1 이 종전처럼 차단" 에서 "전환 off → exit 0" 로 방향
#       전환, 이 교대의 유일한 의도된 behavior 변화)가 이를 커버한다.
# 이 파일은 그 두 케이스와 겹치지 않는, 소스 분류 경계 + 추출 하드닝만
# 다룬다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-edit-task-gate.sh"

# ------------------------------------------------------------
# Sandbox prep helpers — mirrors tests/hooks/test-active-task-authority-
# switch.sh's own local helpers (same self-location principle, same real
# bin/rein + real rein package, not a fake stub).
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
_write_authority_switched_on() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - active_task\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
_v2_state_db_exists() {
  [ -f "$SANDBOX/.rein/state/runtime.sqlite3" ]
}

# _setup_switched_no_active_task — real engine, switched on, task-axis
# policy present, NO DoD seeded anywhere. Any Edit to an IS_SOURCE=true path
# reaches real v2 delegation and gets a genuine DENY ("no active task").
# Any Edit to a non-source/exempt path must exit before delegation is ever
# attempted (no v2 state db).
_setup_switched_no_active_task() {
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on
}

# _event_payload FILE_PATH — same shape test-active-task-authority-switch.sh
# builds (v1 extracts only tool_input.file_path, but v2 additionally reads
# tool_name + cwd from the SAME verbatim $INPUT forwarded to it).
_event_payload() {
  python3 - "$1" <<'PY'
import json
import sys

file_path = sys.argv[1]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": "Edit",
    "tool_input": {"file_path": file_path, "old_string": "a", "new_string": "b"},
    "cwd": "SANDBOX_CWD_PLACEHOLDER",
}))
PY
}

# _make_input REL — builds the event payload for a path relative to SANDBOX,
# with cwd correctly substituted (avoids embedding $SANDBOX at heredoc-build
# time before it may have changed across tests).
_make_input() {
  local abs="$SANDBOX/$1"
  _event_payload "$abs" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['cwd'] = '$SANDBOX'
print(json.dumps(data))
"
}

_mk_src_file() {
  # $1 = relative path inside sandbox
  local rel="$1"
  mkdir -p "$SANDBOX/$(dirname "$rel")"
  touch "$SANDBOX/$rel"
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

# assert_reaches_v2_deny — proves IS_SOURCE=true drove a genuine v2
# delegation that denied (no active task anywhere in this sandbox).
assert_reaches_v2_deny() {
  local label="$1"
  assert_exit 0 "$label: v2 deny relay always exits 0"
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "$label: HOOK_STDOUT is not a PreToolUse deny envelope (permissionDecision='$decision'): $HOOK_STDOUT"
  _v2_state_db_exists || fail "$label: expected v2 state db to exist — proves this path actually reached real delegation (IS_SOURCE=true), not merely a coincidental exit 0"
}

# assert_never_reaches_delegation — proves a non-source/exempt path exits
# via classification BEFORE the axis is ever attempted.
assert_never_reaches_delegation() {
  local label="$1"
  assert_exit 0 "$label: allowed"
  [ -z "$HOOK_STDOUT" ] || fail "$label: expected no denial JSON, got: $HOOK_STDOUT"
  if _v2_state_db_exists; then
    fail "$label: v2 state db should NOT exist — this path must be classified as non-source/exempt BEFORE the active-task axis is ever reached"
  fi
}

# ============================================================
# GMF-3: DoD 소스 판정 경계 (behavioral-contract, tightening-only) — 이
# 판정 자체는 lib/source-path-classify.sh 소유이며 discipline-gate/task-gate
# 양쪽이 동일 함수를 호출한다(그 lib 헤더 참조). 이 스위트는 task-gate 를
# 통해 그 경계가 실제로 "위임을 시도하는가"를 가르는지 관측한다.
# ============================================================

# ---- red: 디렉토리 화이트리스트 밖 + 소스 확장자 → 위임 시도 → v2 DENY
test_gmf3_red_root_internal_go_reaches_v2_deny() {
  _mk_src_file "internal/x.go"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input internal/x.go)"

  assert_reaches_v2_deny "internal/x.go (source-dir 밖, .go 소스 확장자)"
}

test_gmf3_red_cmd_main_go_reaches_v2_deny() {
  _mk_src_file "cmd/main.go"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input cmd/main.go)"

  assert_reaches_v2_deny "cmd/main.go (source-dir 밖, .go 소스 확장자)"
}

# ---- green(비소스 통과): 위임 자체가 시도되지 않음
test_gmf3_green_docs_md_never_delegates() {
  _mk_src_file "docs/README.md"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input docs/README.md)"

  assert_never_reaches_delegation "docs/README.md (문서 확장자)"
}

test_gmf3_green_root_config_json_never_delegates() {
  _mk_src_file "config.json"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input config.json)"

  assert_never_reaches_delegation "루트 config.json (데이터 확장자, source-dir 밖)"
}

test_gmf3_green_cargo_lock_never_delegates() {
  _mk_src_file "Cargo.lock"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input Cargo.lock)"

  assert_never_reaches_delegation "Cargo.lock (락 확장자)"
}

test_gmf3_green_vendor_go_never_delegates() {
  _mk_src_file "vendor/foo.go"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input vendor/foo.go)"

  assert_never_reaches_delegation "vendor/foo.go (vendored, source-dir 앞 제외)"
}

test_gmf3_green_src_generated_dir_never_delegates() {
  _mk_src_file "src/generated/api.ts"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input src/generated/api.ts)"

  assert_never_reaches_delegation "src/generated/api.ts (*/generated/*, source-dir 앞 제외)"
}

test_gmf3_green_src_generated_suffix_never_delegates() {
  _mk_src_file "src/api.generated.ts"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input src/api.generated.ts)"

  assert_never_reaches_delegation "src/api.generated.ts (*.generated.*, source-dir 앞 제외)"
}

# ---- green(불변): source-dir 내부는 여전히 위임 시도(→ DENY)
test_gmf3_green_src_api_ts_still_reaches_v2_deny() {
  _mk_src_file "src/api.ts"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input src/api.ts)"

  assert_reaches_v2_deny "src/api.ts (generated 미매칭 → source-dir 로 위임, 불변)"
}

test_gmf3_green_src_schema_json_still_reaches_v2_deny() {
  _mk_src_file "src/schema.json"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input src/schema.json)"

  assert_reaches_v2_deny "src/schema.json (source-dir 내부 → doc/data 제외가 통과시키면 안 됨, 불완화)"
}

test_gmf3_green_scripts_config_yaml_still_reaches_v2_deny() {
  _mk_src_file "scripts/config.yaml"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input scripts/config.yaml)"

  assert_reaches_v2_deny "scripts/config.yaml (source-dir 내부 → 불완화 유지)"
}

test_gmf3_green_src_app_ts_still_reaches_v2_deny() {
  _mk_src_file "src/app.ts"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input src/app.ts)"

  assert_reaches_v2_deny "src/app.ts (source-dir 소스 → 위임 유지, 불변)"
}

# ============================================================
# GMF-3 안내(emit_ext_source_notice, lib/ext-source-notice.sh 공유): 이제
# task-gate 의 v2-DENY relay 경로에서 emit_ext_source_notice 를 실제로
# 호출한다(그 lib 의 헤더 + pre-edit-task-gate.sh 의 DENY 분기 참조) — 구
# v1 인라인 차단 전용이 아니라 두 훅이 공유하는 lib 로 이전됐으므로, task-
# gate 를 통해 그대로 관측 가능하다.
# ============================================================

test_gmf3_ext_notice_first_block_emits_reason() {
  _mk_src_file "internal/x.go"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input internal/x.go)"

  assert_reaches_v2_deny "internal/x.go 첫 차단"
  assert_stderr_contains "소스 확장자"
}

test_gmf3_ext_notice_suppressed_second_block() {
  _mk_src_file "internal/x.go"
  _setup_switched_no_active_task

  # 1회차 — 안내 출력 + marker 생성
  run_hook "$HOOK" "$(_make_input internal/x.go)"
  assert_reaches_v2_deny "1회차 차단"
  assert_stderr_contains "소스 확장자"

  # 2회차 — 같은 경로 → 안내 억제(차단 자체는 여전히 DENY, 불변)
  run_hook "$HOOK" "$(_make_input internal/x.go)"
  assert_reaches_v2_deny "2회차도 차단(불변)"
  echo "$HOOK_STDERR" | grep -qF "소스 확장자" \
    && fail "같은 파일 2회차 차단에서 확장자 안내가 억제되지 않음(파일경로당 1회 위반)"
}

test_gmf3_ext_notice_per_path_distinct_files() {
  _mk_src_file "internal/x.go"
  _mk_src_file "cmd/main.go"
  _setup_switched_no_active_task

  # internal/x.go 첫 차단 → 안내 + marker
  run_hook "$HOOK" "$(_make_input internal/x.go)"
  assert_stderr_contains "소스 확장자"

  # cmd/main.go 는 다른 경로 → 첫 차단이므로 안내 있어야 함
  run_hook "$HOOK" "$(_make_input cmd/main.go)"
  assert_stderr_contains "소스 확장자"
}

test_gmf3_dir_match_block_no_ext_notice() {
  _mk_src_file "src/app.ts"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input src/app.ts)"

  assert_reaches_v2_deny "src/app.ts (디렉토리 매칭) → 위임 차단"
  echo "$HOOK_STDERR" | grep -qF "소스 확장자" \
    && fail "디렉토리 매칭 차단에서 확장자 안내가 잘못 출력됨(EXT_SOURCE_HIT 아님)"
}

# ============================================================
# SEC-1 sanity + SEC-2 (2026-08-19/08-19 보안 검토 실증) — 구분자(0x1F)/개행
# (LF) 임베딩으로 인한 게이트 우회가 IS_SOURCE 오분류로 이어지지 않는지를
# task-gate 를 통해 관측한다. malformed-extraction 카운트 검사 자체(구분자
# ≠ 1개)는 discipline-gate 스위트가 이미 커버한다(그 검사는 분류 이전에
# unconditionally 발동하므로 이 스위트에서 재검증할 필요가 없다) — 여기서는
# "검증을 통과한 정상/개행-포함 경로가 실제로 올바르게 소스 분류돼 위임에
# 도달하는가" 만 본다.
# ============================================================

_make_input_no_embedded_sep() {
  # 정상 경로(구분자 없음) — SEC-1 sanity: 절단 검증 자체가 오탐을 내지
  # 않는지 확인.
  local abs="$SANDBOX/$1"
  python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'PreToolUse',
    'tool_name': 'Edit',
    'tool_input': {'file_path': '$abs', 'old_string': 'a', 'new_string': 'b'},
    'cwd': '$SANDBOX',
}))
"
}

test_sec1_no_embedded_separator_reaches_v2_deny() {
  _mk_src_file "internal/notes.go"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input_no_embedded_sep internal/notes.go)"

  assert_reaches_v2_deny "internal/notes.go (구분자 없음) → 기존 확장자 판정대로 위임, 새 검증은 오탐하지 않음"
  echo "$HOOK_STDERR" | grep -qF "malformed field extraction" \
    && fail "정상 경로인데 malformed field extraction 오탐 발생"
}

# SEC-2: file_path 에 리터럴 LF 를 심어도(0x1F 구분자는 정확히 1개 유지)
# read 절단 없이 전체 경로가 보존돼 올바르게 소스로 분류, 위임까지 도달해야
# 한다(무음 우회 금지).
_make_input_embedded_newline() {
  # $1=구분자 이전 상대경로, $2=구분자 이후 접미사(확장자 포함)
  local abs="$SANDBOX/$1"
  python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'PreToolUse',
    'tool_name': 'Edit',
    'tool_input': {'file_path': '$abs\n$2', 'old_string': 'a', 'new_string': 'b'},
    'cwd': '$SANDBOX',
}))
"
}

test_sec2_embedded_newline_in_file_path_reaches_v2_deny() {
  # 전체 경로(개행 포함)가 실제로 디스크에 존재할 필요는 없다 — 경로 분류는
  # 문자열 매칭이므로. internal/ 은 디렉토리 화이트리스트 밖이라(GMF-3 red
  # 계열과 동일) 확장자가 사라지면 즉시 비소스로 오분류되는 것이 취약점의
  # 핵심이었다.
  mkdir -p "$SANDBOX/internal"
  _setup_switched_no_active_task

  run_hook "$HOOK" "$(_make_input_embedded_newline internal/notes backdoor.go)"

  assert_reaches_v2_deny "internal/notes<LF>backdoor.go → read 절단 클래스 제거, 전체 경로 .go 소스로 분류·위임(무음 통과 금지)"
  echo "$HOOK_STDERR" | grep -qF "malformed field extraction" \
    && fail "LF 케이스는 소스 판정으로 위임돼야 함(malformed 오탐 = 절단 회귀)"
}

# ============================================================
# 하드닝 사본 대칭 검증 (Phase 7 wave 3 ③-b code review round 1, Medium) —
# pre-edit-task-gate.sh 는 pre-edit-discipline-gate.sh 의 0x1F/LF 추출
# 하드닝 코드를 독립된 사본으로 갖는다(공유 lib 함수가 아니라 "바이트
# 동일한 처리"라는 계약만으로 두 파일에 각각 존재한다 — 이 훅 자신의
# 위쪽 "Security hardening 1/2, 2/2" 주석 참조). 사본이라는 것은 한쪽만
# 실수로 깨져도(예: 리팩토링 중 조건을 뒤집는 오타) 다른 쪽 테스트가 그
# 회귀를 잡아주지 못한다는 뜻이다. 위 SEC-1 sanity / SEC-2 는 "정상
# 입력(구분자 없음/LF 만 포함)이 올바르게 분류되는가"만 본다 — task-gate
# 자신의 사본이 실패 분기(① 구분자 개수 위반 → exit 2, ③ JSON 파싱 자체
# 실패 → exit 2)에서도 discipline-gate 의 사본과 동일하게 동작하는지는
# 지금까지 이 파일 어디에서도 독립 검증되지 않았다 —
# test-pre-edit-discipline-gate.sh 의 test_sec1_embedded_separator_in_
# file_path_fails_closed 하나만으로는 task-gate 사본의 회귀를 잡지 못한다.
# ============================================================

# ---- ① 0x1F 임베딩 → fail-closed exit 2. discipline-gate 사본의
# test_sec1_embedded_separator_in_file_path_fails_closed 과 동일 계약을
# task-gate 자신의 사본에 대해 독립 검증한다.
_make_input_embedded_sep() {
  local abs="$SANDBOX/$1"
  printf '{"tool_input":{"file_path":"%s\\u001f%s"},"tool_name":"Edit"}' "$abs" "$2"
}

test_sec1_copy_embedded_separator_in_file_path_fails_closed() {
  run_hook "$HOOK" "$(_make_input_embedded_sep internal/notes backdoor.go)"

  assert_exit 2 "internal/notes<0x1F>backdoor.go → task-gate 자신의 구분자 하드닝 사본이 fail-closed 차단해야 함(무음 통과 금지)"
  assert_stderr_contains "malformed field extraction"
  assert_file_contains "trail/incidents/blocks.jsonl" "json parse failure"
}

# ---- ② LF 포함 file_path 가 절단 없이 정상 분류됨: 이미 위
# test_sec2_embedded_newline_in_file_path_reaches_v2_deny 로 이 파일에
# 존재한다(discipline-gate 는 이 시나리오를 관측할 수 없어 애초에 이
# 파일로 전량 이관됐다 — 이 파일 헤더 참조). 여기서는 별도 함수를 새로
# 추가하지 않고, main() 에 이미 등록되어 있음을 유지한다.

# ---- ③ stdin 자체가 유효한 JSON 이 아님 → extract-hook-json.py 파싱
# 실패 → fail-closed exit 2. discipline-gate 쪽에도 이 실패 분기 자체를
# 독립 검증하는 테스트가 없었으므로(오직 0x1F 임베딩을 통한 간접 관측만
# 존재) task-gate 자신의 EXTRACT_RC 분기를 여기서 처음 독립 검증한다.
test_json_parse_failure_fails_closed() {
  run_hook "$HOOK" 'NOT_VALID_JSON { broken:'

  assert_exit 2 "malformed JSON stdin → task gate should fail closed"
  assert_stderr_contains "extract-hook-json.py exited"
}

# ============================================================
# 단위 계약 회귀 방지 — 디스패처 없이 직접 호출 (Phase 7 wave 3 ③-b code
# review round 2, Medium 도입 → round 6, High 수리로 "어느 계층을
# 검증하는가"가 갱신됨. 이 훅 자신의 헤더 "로그 계약" 절 참조).
#
# round 2 당시엔 discipline-gate/task-gate 가 hooks.json 에 개별
# 등록되어 병렬·순서 비보장으로 실행됐으므로, 이 테스트가 관측하는
# "직접 호출 시 각 훅이 독립적으로 자신의 log_block 을 남긴다"는 사실이
# 곧 프로덕션 카디널리티(이벤트당 최대 2건)이기도 했다.
#
# round 6(pre-edit-dispatcher.sh 신설)으로 hooks.json 등록이
# 디스패처 하나로 교체되면서, 프로덕션 카디널리티는 더 이상 이 테스트가
# 보여주는 것과 같지 않다 — 디스패처는 순차 실행 + 첫 차단 중단이므로
# discipline-gate 가 차단하면 task-gate 는 실행조차 되지 않는다(이벤트당
# 최대 1건). 이 테스트는 이제 "프로덕션에서 몇 건이 남는가"가 아니라
# "각 훅을 디스패처 없이 단독으로 호출해도 자신의 log_block 이
# self-contained 하게 동작하는가"(단위 계약)만 검증한다 — 그 사실
# 자체는 여전히 유효하고 유용하다(테스트 하네스나 향후 재사용 경로가
# 훅을 직접 호출할 수 있어야 하므로). 프로덕션 카디널리티(디스패처
# 경유 시 이벤트당 1건) 회귀 방지는
# tests/hooks/test-pre-edit-dispatcher.sh 의 동일 계열 테스트가
# 전담한다 — 같은 이중-차단 fixture 를 디스패처 경유로 실행해
# blocks.jsonl 에 정확히 1건만 남는 것을 단언한다.
# ============================================================

test_dual_axis_independent_logging_two_distinct_reasons() {
  _mk_src_file "scripts/foo.sh"
  # discipline-gate 축을 무조건 차단시키는 조건(governance-invalid) — 이
  # 훅(task-gate)과는 무관한 축이므로 서로 간섭하지 않는다.
  mkdir -p "$SANDBOX/.claude/.rein-state"
  echo 'not json at all' > "$SANDBOX/.claude/.rein-state/governance.json"
  # task-gate 축을 fail-closed 시키는 조건: rein 패키지를 링크하지 않아
  # 전환 확인 자체가 불가능(ERROR) — tests/hooks/test-active-task-
  # authority-switch.sh 의 test_f_switch_check_unavailable_fails_closed 와
  # 동일한 최소 fixture(그 테스트가 rein 패키지를 링크하지 않는 것과 동일 —
  # 이 파일에서는 _setup_switched_no_active_task 같은 헬퍼를 의도적으로
  # 호출하지 않는다).

  local payload
  payload="$(_make_input scripts/foo.sh)"

  run_hook "pre-edit-discipline-gate.sh" "$payload"
  assert_exit 2 "discipline-gate 축(governance-invalid)이 이 편집을 독립적으로 차단"

  run_hook "$HOOK" "$payload"
  assert_exit 2 "task-gate 축(전환 확인 실패)이 같은 편집을 독립적으로 차단"

  assert_file_contains "trail/incidents/blocks.jsonl" "governance config invalid"
  assert_file_contains "trail/incidents/blocks.jsonl" "활성 작업 전환 확인 실패"

  local reason_count
  reason_count=$(grep -c '"reason"' "$SANDBOX/trail/incidents/blocks.jsonl" 2>/dev/null || echo 0)
  [ "$reason_count" -eq 2 ] \
    || fail "dual-axis 차단은 정확히 서로 다른 사유 2건을 남겨야 함(단일화/dedup 이 조용히 도입되면 이 값이 1로 줄어든다) — got: $reason_count"
}

main() {
  # GMF-3: 소스 판정 경계가 위임 시도 여부를 가른다
  run_test test_gmf3_red_root_internal_go_reaches_v2_deny "$HOOK"
  run_test test_gmf3_red_cmd_main_go_reaches_v2_deny "$HOOK"
  run_test test_gmf3_green_docs_md_never_delegates "$HOOK"
  run_test test_gmf3_green_root_config_json_never_delegates "$HOOK"
  run_test test_gmf3_green_cargo_lock_never_delegates "$HOOK"
  run_test test_gmf3_green_vendor_go_never_delegates "$HOOK"
  run_test test_gmf3_green_src_generated_dir_never_delegates "$HOOK"
  run_test test_gmf3_green_src_generated_suffix_never_delegates "$HOOK"
  run_test test_gmf3_green_src_api_ts_still_reaches_v2_deny "$HOOK"
  run_test test_gmf3_green_src_schema_json_still_reaches_v2_deny "$HOOK"
  run_test test_gmf3_green_scripts_config_yaml_still_reaches_v2_deny "$HOOK"
  run_test test_gmf3_green_src_app_ts_still_reaches_v2_deny "$HOOK"
  # GMF-3 안내 (공유 lib/ext-source-notice.sh, task-gate DENY 경로에서 관측)
  run_test test_gmf3_ext_notice_first_block_emits_reason "$HOOK"
  run_test test_gmf3_ext_notice_suppressed_second_block "$HOOK"
  run_test test_gmf3_ext_notice_per_path_distinct_files "$HOOK"
  run_test test_gmf3_dir_match_block_no_ext_notice "$HOOK"
  # SEC-1 sanity + SEC-2: 추출 하드닝이 소스 분류를 오염시키지 않음
  run_test test_sec1_no_embedded_separator_reaches_v2_deny "$HOOK"
  run_test test_sec2_embedded_newline_in_file_path_reaches_v2_deny "$HOOK"
  # 하드닝 사본 대칭 검증: task-gate 자신의 사본을 실패 분기에서 독립 검증
  run_test test_sec1_copy_embedded_separator_in_file_path_fails_closed "$HOOK"
  run_test test_json_parse_failure_fails_closed "$HOOK"
  # 로그 계약: 축별 독립 감사 (dedup 하지 않음) 회귀 방지
  run_test test_dual_axis_independent_logging_two_distinct_reasons "$HOOK" pre-edit-discipline-gate.sh
  summary
}

main "$@"
