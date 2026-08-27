#!/bin/bash
# tests/hooks/test-active-task-authority-switch.sh
#
# v2 Phase 6 Task 6.1 본작업 — active_task 축 판정 권한을 v1 에서 v2
# (`rein.engine.authority` + `bin/rein hook`)로 전환하는 배선을 행위
# 기반으로 검증한다. code_review/security_review 축(tests/hooks/
# test-code-review-authority-switch.sh / test-security-review-authority-
# switch.sh)과 같은 "직접 위임" 아키텍처(사용자 결정 2026-08-18)를
# 따른다 — 이 파일의 헤더는 그 두 파일과의 **차이점**만 설명한다;
# 아키텍처 배경 전체는 code-review 스위트의 헤더 주석을 참조.
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대, 2026-08-21) 갱신: 이 축의 집행
# 지점이 pre-edit-dod-gate.sh(삭제됨)에서 pre-edit-task-gate.sh(신설, 이
# 축 전담)로 이동했다. lib/active-task-gate.sh 의 하위 함수(rein_active_
# task_authority_switched, rein_active_task_delegate)는 바이트 동일하게
# 재사용되지만, 그 파일의 옛 진입점 rein_check_active_task() 의 "v1 폴백"
# (미전환이거나 위임 FAIL 일 때 DOD_FOUND 로 v1 이 직접 판정하던 분기)은
# 새 훅에서 아예 호출되지 않는다 — 판정 트리가 다음과 같이 바뀐다:
#   전환됨 + ALLOW → exit 0 (불변)
#   전환됨 + DENY  → v2 JSON relay + log_block + exit 0 (불변)
#   전환됨 + FAIL  → **fail-closed exit 2** (구: v1 이 DOD_FOUND 로 직접
#     판정 — DOD_FOUND=true 면 ALLOW 도 가능했다. 신: FAIL 은 DOD_FOUND
#     값과 무관하게 항상 차단. 시나리오 (g)/(h) 갱신)
#   미전환         → **exit 0** (구: v1 이 DOD_FOUND 로 직접 판정 — 이
#     스위트의 나머지 테스트는 DoD 를 안 심으므로 구 동작은 항상 차단이었다.
#     신: 무조건 통과. 이 교대의 유일한 의도된 방향 변화 — 시나리오 (e) 갱신)
#   확인 자체 실패 → fail-closed exit 2 (구와 동일 방향, 메시지만 새 훅
#     전용으로 교체 — 시나리오 (f) 갱신)
# 아래 헤더의 "v1 자신의 차단 형식" 절과 각 시나리오 주석은 이 갱신을
# 반영해 손을 봤다 — 원 파일의 (a)~(d), (i), (j) 는 무변경(이 축의
# ALLOW/DENY 위임 매커니즘 자체는 훅 이름만 바뀌었을 뿐 그대로다).
#
# ============================================================
# 이 축이 다른 두 축과 구조적으로 다른 점
# ============================================================
#
# 1. 집행 지점이 다른 훅이다 — `pre-edit-task-gate.sh` (PreToolUse
#    Edit|Write|MultiEdit), 다른 두 축의 `pre-bash-commit-review-gate.sh`
#    (PreToolUse Bash, git commit 서브커맨드 한정 — Phase 7 웨이브 3
#    ③-c 갱신: 이전엔 `pre-bash-test-commit-gate.sh` 단일 파일이었으나
#    그 파일은 삭제되고 리뷰 축(code_review/security_review)만 이
#    훅으로, 그 외 v1 존속 규율은 sibling `pre-bash-commit-discipline-
#    gate.sh` 로 분리됐다) 가 아니다.
#
# 2. "활성 DoD 존재"를 위임 전제로 못 쓴다(순환) — code_review/
#    security_review 는 "DoD 가 하나라도 있는가"라는, 판정 자체와는
#    다른 질문을 선행조건으로 위임 여부를 가른다. active_task 는 그
#    선행조건 자체가 판정 대상이라 위임 여부를 가르는 데 쓸 수 없다
#    (hooks/lib/active-task-gate.sh 헤더의 "순환 회피" 절 참조). 그래서
#    이 축은 (경로 면제·소스 분류를 통과한 뒤) 항상 위임을 시도하고,
#    도구별 축 전용 정책 파일 존재만 delegate 내부에서 확인한다.
#
# 3. REIN_POLICY_DIR 이 도구마다 다른 파일 3개로 나뉜다 — security_review
#    축은 단일 트리거(git.commit)라 파일 1개였지만, 이 축은 Edit/Write/
#    MultiEdit 세 tool 이벤트를 다 요구해야 하고 kernel D3 `when:` 절이
#    OR 를 지원하지 않아 도구별 파일(edit-task.yaml/write-task.yaml/
#    multiedit-task.yaml)로 나뉜다(`.rein/policy/task-axis/_version.yaml`
#    참조). 시나리오 (i)가 세 파일 각각의 유효성을 확인한다.
#
# 4. 차단 형식 — 이 축의 fail-closed 경로(미전환 확인 실패/위임 FAIL)는
#    처음부터 평문 stderr 안내 + `exit 2` 였다(`deny_emit` 을 pre-edit-
#    task-gate.sh 가 아예 source 하지 않는다). Phase 7 웨이브 3 ③-c
#    (커밋 게이트 교대) 이후 code_review/security_review 축도 v1 폴백이
#    제거되며 정확히 같은 형식(평문 stderr + exit 2)으로 수렴했다 —
#    ③-c 이전엔 이 항목이 "이 축만 다르다"는 차이점이었지만, 이제는 세
#    축 모두 동일한 계약(FAIL/확인실패 → exit 2, 전환됨+DENY → v2 native
#    JSON relay)을 공유한다. 그래서 이 스위트의 fail-closed 시나리오
#    ((f)/(g)/(h))는 stdout 이 아니라 stderr 문구 + exit 2 를 단언한다 —
#    이는 이제 이 축에 국한된 특수 사례가 아니라 세 축 공통 계약의 한
#    사례다(hooks/lib/active-task-gate.sh 헤더의 "편집 차단 방식 주의"
#    절 참조).
#
# "진짜 위임이 일어났는가" 를 증명하는 방법(v2 state db 부수 효과 관측)은
# code_review/security_review 축의 스위트와 완전히 동일하다 — `bin/rein
# hook` 이 실제로 실행되면 project_root 밑에 `.rein/state/runtime.sqlite3`
# 를 항상 선생성한다(rein/cli/__init__.py::_resolve_db_path()).
#
# ============================================================
# 시나리오 (a)~(j)
# ============================================================
#   (a) 전환 on + 활성 작업 있음 + 소스 편집(Edit) → 통과 (위임 경유)
#   (b) 전환 on + 활성 작업 없음 + 소스 편집(Edit) → 차단 (v2 deny
#       relay, 로그 1건, 중복 없음)
#   (c) 전환 on + 활성 작업 없음 + 무관 파일(비소스, NOTES.md) 편집 →
#       통과 — 위임 자체가 없음(소스 분류가 이 축보다 먼저 걸러낸다,
#       v2 상태 db 부재로 증명)
#   (d) 전환 on + 면제 경로(trail/ 하위 기록 파일) 편집 → 통과, 위임
#       없음(경로 면제가 이 축보다 먼저 걸러낸다)
#   (e) 전환 off → **exit 0**(문서화된 opt-out — 편집 게이트 교대의 유일한
#       의도된 방향 변화. 구: v1 종전 차단(평문 stderr + exit 2))
#   (f) 전환 확인 실패(rein 패키지 조회 불가) → fail-closed exit 2 (신설
#       전용 메시지 — "확인 자체가 불가능함". 구: v1 이 DOD_FOUND 로 계속
#       판정)
#   (g) 위임 실행 실패(엔진 스크립트 손상 주입) → fail-closed exit 2 (신설
#       전용 메시지 — "v1 폴백 없음". 구: v1 이 DOD_FOUND 로 직접 판정)
#   (h) 축 전용 정책 파일만 없음(폴더는 존재, 이 도구의 파일만 부재) →
#       위임을 아예 시도하지 않고 fail-closed exit 2(신설 전용 메시지,
#       security_review 축 시나리오 (j)의 교훈을 이 축에 사전 적용)
#   (i) Write/MultiEdit 도구에서도 (a)/(b) 와 동일하게 동작 — 정책
#       3파일이 각각 유효함을 증명
#   (j) 교차 무영향 — 이 축의 위임(축 전용 정책, active_task 만 요구)이
#       code_review/security_review 요구를 집행하지 않는다(리뷰 표식이
#       전혀 없어도 Edit 이벤트가 통과)
#
# 전부 실제 실행(source 금지). 표식 상태·로그 건수·state db 존재까지
# 단언한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-edit-task-gate.sh"

# _event_payload FILE_PATH TOOL CWD
#   실제 Claude Code PreToolUse(Edit/Write/MultiEdit) hook 이 보내는
#   이벤트 JSON 모양을 최소 재현한다. pre-edit-task-gate.sh 자신은
#   tool_input.file_path + tool_name 만 읽지만, v2(bin/rein hook)는
#   tool_name(command.type 대신 이 축이 쓰는 `tool` fact) 과 cwd
#   (REIN_PROJECT_ROOT 미설정 시의 project_root 유도)까지 읽는다 —
#   pre-edit-task-gate.sh 가 이 정확한 원문을 그대로 위임하므로($INPUT,
#   재조립 없음), 테스트 payload 도 두 소비자 모두가 필요로 하는 필드를
#   전부 갖춰야 한다.
_event_payload() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

file_path, tool, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": tool,
    "tool_input": {"file_path": file_path, "old_string": "a", "new_string": "b"},
    "cwd": cwd,
}))
PY
}

# ------------------------------------------------------------
# Sandbox prep helpers (test-file-local — not added to the shared harness).
# ------------------------------------------------------------

# _link_rein_package / _link_rein_bin — code_review/security_review 축
# 스위트와 동일한 self-location 원리(hooks/lib/active-task-gate.sh →
# ../.. = $SANDBOX/.claude — 같은 lib/ 디렉토리에 있으므로 다른 두 축과
# 정확히 같은 상대 위치).
_link_rein_package() {
  mkdir -p "$SANDBOX/.claude"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/rein" "$SANDBOX/.claude/rein"
}
_link_rein_bin() {
  mkdir -p "$SANDBOX/.claude/bin"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/bin/rein" "$SANDBOX/.claude/bin/rein"
}

# _link_task_axis_policy
#   rein_active_task_delegate() 가 주입하는 REIN_POLICY_DIR
#   ($SANDBOX/.rein/policy/task-axis) 을 실제 저장소의 축 전용 정책
#   폴더로 채운다(복사 — 심볼릭 링크가 아니다: 시나리오 (h)가 이 사본의
#   파일 하나만 지우고 실제 저장소 파일은 절대 건드리지 않아야 하므로).
_link_task_axis_policy() {
  mkdir -p "$SANDBOX/.rein/policy"
  rm -rf "$SANDBOX/.rein/policy/task-axis"
  cp -R "$REAL_PROJECT_DIR/tests/fixtures/policy/task-axis" "$SANDBOX/.rein/policy/task-axis"
}

# _write_broken_engine_script — 다른 두 축 스위트와 동일한 기법(시나리오
# (g) "위임 실패(엔진 스크립트 손상)" 재현). 샌드박스 소유의 실제
# 파일(심볼릭 링크 아님) — 실제 저장소 파일을 절대 건드리지 않는다.
_write_broken_engine_script() {
  mkdir -p "$SANDBOX/.claude/bin"
  cat > "$SANDBOX/.claude/bin/rein" <<'PY'
#!/usr/bin/env python3
import sys
sys.stderr.write("[test] engine script deliberately broken\n")
sys.exit(3)
PY
  chmod +x "$SANDBOX/.claude/bin/rein"
}

# _write_authority_switched_on — active_task 축 하나만 전환(다른 두
# 축은 이 스위트의 대다수 테스트에서 미전환으로 남긴다 — 이 스위트가
# 검증하려는 active_task 축 하나만 변수로 남기는, 다른 두 축 스위트와
# 대칭인 격리).
_write_authority_switched_on() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - active_task\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
_write_authority_switched_off() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched: none\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
# _write_authority_switched_all_three — 시나리오 (j) 전용. code_review/
# security_review/active_task 셋 다 전환해, active_task 축의 위임(축
# 전용 정책, active_task 만 요구)이 다른 두 축의 요구로 오염되지
# 않는지를 직접 검증한다.
_write_authority_switched_all_three() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - code_review\n  - security_review\n  - active_task\n' \
    > "$SANDBOX/.rein/policy/authority.yaml"
}

_blocks_log_count() {
  local f="$SANDBOX/trail/incidents/blocks.jsonl"
  [ -f "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0
}

# _v2_state_db_exists — 다른 두 축 스위트와 동일한 부수효과 증거.
_v2_state_db_exists() {
  [ -f "$SANDBOX/.rein/state/runtime.sqlite3" ]
}

# _seed_source_file REL
#   소스 디렉토리 화이트리스트(`*/src/*`)에 걸리는 파일을 만든다. Write
#   시나리오는 대상 파일이 실제로 존재할 필요가 없다(경로 분류는 문자열
#   매칭이라 존재 여부와 무관) — 그런 시나리오는 이 헬퍼를 쓰지 않고
#   경로 문자열만 구성한다.
_seed_source_file() {
  local rel="$1"
  mkdir -p "$SANDBOX/$(dirname "$rel")"
  printf 'x = 1\n' > "$SANDBOX/$rel"
}

# ------------------------------------------------------------
# assertions (다른 두 축 스위트와 동일한 형태 — 파일별 독립 사본)
# ------------------------------------------------------------

assert_v1_silent() {
  assert_exit 0 "$1: exit code"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no denial, got stdout: $HOOK_STDOUT"
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

assert_v1_relayed_v2_deny() {
  # $1=message. v1 이 v2 의 native deny JSON 을 "그대로" relay 했는지 —
  # (1) exit 0. 이 훅 자신의 v1 폴백은 이 축 전환 이전부터 항상 평문
  # stderr + `exit 2` 였다(deny_emit 을 이 훅이 아예 source 하지 않는다
  # — 다른 두 축의 훅과 달리 JSON deny 자체를 낼 수 있는 경로가 v1 에
  # 없다). 그래서 exit 0 + 유효한 PreToolUse deny envelope 조합 자체가
  # 이미 "v1 자신의 판정이 아니다"의 결정적 증거다 — 코드/보안 리뷰
  # 축처럼 v2 고유 requirement 이름을 reason 텍스트에서 찾을 필요가
  # 없다(active_task 는 fact 판정형이라 v2 가 이겼을 때 authority note
  # 를 reason 에 남기지 않는다 — rein/engine/evaluator.py
  # `_requirement_satisfied()` 의 "SOURCE_V2 는 reason 에 남길 새 사실이
  # 없다" 분기, 2026-08-18 실측 확인. reason 텍스트는 항상 evaluator 의
  # 범용 상수 REASON_MISSING_EVIDENCE 그대로다). (2) reason 텍스트가 그
  # 상수 그대로인지도 확인해 "진짜 evaluator 산출물"임을 보강한다.
  assert_exit 0 "$1: exit code (v2 relay always exits 0, unlike this hook's own v1 exit-2 block)"
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "$1: HOOK_STDOUT is not a PreToolUse deny envelope (permissionDecision='$decision'): $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"required evidence is missing"*) ;;
    *) fail "$1: reason missing v2 evaluator's own constant text 'required evidence is missing' — this does not look like v2's real decision: $HOOK_STDOUT" ;;
  esac
}

# ============================================================
# (a) 전환 on + 활성 작업 있음 + 소스 편집(Edit) → 통과 (위임 경유)
# ============================================================

test_a_switch_on_active_task_source_edit_allows() {
  seed_dod "dod-2026-08-18-atg-switch.md"
  _seed_source_file "src/existing.py"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(a) active task present + source edit + switch on → allowed via delegation"
  _v2_state_db_exists || fail "(a) expected v2 state db to exist — proves the active_task axis was genuinely delegated to bin/rein hook, not merely coincidentally passed by a v1 fallback"
}

# ============================================================
# (b) 전환 on + 활성 작업 없음 + 소스 편집(Edit) → 차단 (v2 deny relay,
#     로그 1건, 중복 없음)
# ============================================================

test_b_switch_on_no_active_task_source_edit_blocks() {
  _seed_source_file "src/existing.py"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local before_count
  before_count=$(_blocks_log_count)

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_relayed_v2_deny "(b) no active task + source edit + switch on → v2 deny, relayed verbatim"

  local after_count
  after_count=$(_blocks_log_count)
  [ "$after_count" -eq "$((before_count + 1))" ] || fail "(b) expected exactly 1 new block-log entry (no duplicate), got $((after_count - before_count))"
  assert_file_contains "trail/incidents/blocks.jsonl" "활성 작업 위임 차단"

  _v2_state_db_exists || fail "(b) expected v2 state db to exist — proves bin/rein hook actually ran and produced this decision"
}

# ============================================================
# (c) 전환 on + 활성 작업 없음 + 무관 파일(비소스, NOTES.md) 편집 →
#     통과 — 위임 자체가 없음(소스 분류가 이 축보다 먼저 걸러낸다)
# ============================================================

test_c_switch_on_nonsource_edit_allows_no_delegation() {
  printf '# notes\n' > "$SANDBOX/NOTES.md"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/NOTES.md" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(c) non-source path + no active task + switch on → allowed, source classification exits first"
  if _v2_state_db_exists; then
    fail "(c) v2 state db should NOT exist — non-source path classification (an earlier gating precondition, not part of this axis) exits before the active_task axis is ever reached"
  fi
}

# ============================================================
# (d) 전환 on + 면제 경로(trail/ 하위 기록 파일) 편집 → 통과, 위임 없음
# ============================================================

test_d_switch_on_exempt_path_allows_no_delegation() {
  mkdir -p "$SANDBOX/trail/decisions"
  printf '# decision\n' > "$SANDBOX/trail/decisions/note.md"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/trail/decisions/note.md" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(d) exempt (trail/) path + switch on → allowed, path exemption exits first"
  if _v2_state_db_exists; then
    fail "(d) v2 state db should NOT exist — the path exemption (an earlier gating precondition, not part of this axis) exits before the active_task axis is ever reached"
  fi
}

# ============================================================
# (e) 전환 off → exit 0 (문서화된 opt-out — Phase 7 웨이브 3 ③-b 의 유일한
#     의도된 방향 변화. 구: v1 이 DOD_FOUND 로 직접 판정, DoD 없음 →
#     exit 2. 신: pre-edit-task-gate.sh 는 v1 폴백을 아예 갖지 않으므로
#     "미전환"은 곧 "이 축이 아직 활성화되지 않음" 으로 그대로 통과된다.)
# ============================================================

test_e_switch_off_allows_no_v1_fallback() {
  _seed_source_file "src/existing.py"
  _link_rein_package
  _write_authority_switched_off

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(e) switch off → allowed (documented opt-out, no v1 fallback judgment exists anymore)"
  if _v2_state_db_exists; then
    fail "(e) v2 state db should NOT exist — delegation must never be attempted when the switch is off"
  fi
}

# ============================================================
# (f) 전환 확인 실패(rein 패키지 조회 불가) → fail-closed exit 2
#
# No _link_rein_package() call here — self-location cannot find the rein
# package inside the sandbox, so rein_active_task_authority_switched()'s
# python probe hits ModuleNotFoundError, sets
# rein_active_task_switch_check_kind=ERROR, and returns 1. The
# authority.yaml override, if it COULD be read, would say "switched" —
# proving the fail-closed direction holds even when the underlying policy
# would have said otherwise.
# ============================================================

test_f_switch_check_unavailable_fails_closed() {
  _seed_source_file "src/existing.py"
  _write_authority_switched_on   # would say switched, but unreachable (no rein package link)

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_exit 2 "(f) fails closed when the switch check itself is unavailable (rein_active_task_switch_check_kind=ERROR)"
  assert_stderr_contains "could not be determined"
  assert_file_contains "trail/incidents/blocks.jsonl" "활성 작업 전환 확인 실패"
  if _v2_state_db_exists; then
    fail "(f) v2 state db should NOT exist — delegation must never be attempted when the switch-check itself fails"
  fi
}

# ============================================================
# (g) 위임 실행 실패(엔진 스크립트 손상 주입) → fail-closed exit 2 (v1
#     폴백 없음 — DOD_FOUND 값과 무관하게 항상 차단)
# ============================================================

test_g_delegate_exec_failure_fails_closed() {
  _seed_source_file "src/existing.py"
  _link_rein_package
  _write_broken_engine_script
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_exit 2 "(g) fails closed when the delegated engine script itself fails — no v1 fallback judgment exists anymore"
  assert_stderr_contains "there is no v1 fallback judgment for this axis anymore"
  assert_file_contains "trail/incidents/blocks.jsonl" "활성 작업 위임 실패"
  if _v2_state_db_exists; then
    fail "(g) v2 state db should NOT exist — the broken engine script exits before ever reaching rein.cli / opening state"
  fi
}

# ============================================================
# (h) 축 전용 정책 파일만 없음(폴더는 존재, 이 도구의 파일만 부재) →
#     위임을 아예 시도하지 않고 fail-closed exit 2 (security_review 축
#     시나리오 (j)의 교훈을 이 축에 사전 적용). delegate() 는 이 경우도
#     결과를 FAIL 로 남기므로 (g) 와 동일한 fail-closed 분기·메시지를 탄다.
# ============================================================

_remove_edit_task_policy_file() {
  rm -f "$SANDBOX/.rein/policy/task-axis/edit-task.yaml"
}

test_h_policy_file_missing_fails_closed() {
  _seed_source_file "src/existing.py"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _remove_edit_task_policy_file
  _write_authority_switched_on

  local before_count
  before_count=$(_blocks_log_count)

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_exit 2 "(h) missing edit-task.yaml (axis folder present) → delegation skipped entirely, fails closed"
  assert_stderr_contains "there is no v1 fallback judgment for this axis anymore"
  assert_file_contains "trail/incidents/blocks.jsonl" "활성 작업 위임 실패"

  if _v2_state_db_exists; then
    fail "(h) v2 state db should NOT exist — the delegate must skip the bin/rein hook call entirely when this tool's axis policy file is absent (no attempt at all, not even a failed one)"
  fi

  local after_count
  after_count=$(_blocks_log_count)
  [ "$after_count" -eq "$((before_count + 1))" ] || fail "(h) expected exactly 1 new block-log entry (no duplicate), got $((after_count - before_count))"
}

# ============================================================
# (i) Write/MultiEdit 도구에서도 (a)/(b) 와 동일하게 동작 — 정책 3파일이
#     각각 유효함을 증명. Write 대상 파일은 아직 존재하지 않아도
#     된다(경로 분류·tool_name fact 는 문자열 매칭이라 파일 존재와
#     무관) — 실제 Write 이벤트도 대상 파일이 아직 없는 것이 정상이다.
# ============================================================

test_i_write_tool_allows_with_active_task() {
  seed_dod "dod-2026-08-18-atg-switch.md"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/src/brand-new.py" "Write" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(i-write-allow) active task present + Write + switch on → allowed via delegation"
  _v2_state_db_exists || fail "(i-write-allow) expected v2 state db to exist — Write tool's own axis policy file (write-task.yaml) was genuinely used"
}

test_i_write_tool_blocks_without_active_task() {
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/src/brand-new.py" "Write" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_relayed_v2_deny "(i-write-block) no active task + Write + switch on → v2 deny, relayed verbatim"
}

test_i_multiedit_tool_allows_with_active_task() {
  seed_dod "dod-2026-08-18-atg-switch.md"
  _seed_source_file "src/existing.py"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "MultiEdit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(i-multiedit-allow) active task present + MultiEdit + switch on → allowed via delegation"
  _v2_state_db_exists || fail "(i-multiedit-allow) expected v2 state db to exist — MultiEdit tool's own axis policy file (multiedit-task.yaml) was genuinely used"
}

test_i_multiedit_tool_blocks_without_active_task() {
  _seed_source_file "src/existing.py"
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "MultiEdit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_relayed_v2_deny "(i-multiedit-block) no active task + MultiEdit + switch on → v2 deny, relayed verbatim"
}

# ============================================================
# (j) 교차 무영향 — 이 축의 위임(축 전용 정책, active_task 만 요구)이
#     code_review/security_review 요구를 집행하지 않는다(리뷰 표식이
#     전혀 없어도 Edit 이벤트가 통과).
# ============================================================

test_j_cross_axis_no_review_stamps_required() {
  seed_dod "dod-2026-08-18-atg-switch.md"
  _seed_source_file "src/existing.py"
  # No code_review/security_review evidence issued at all (③-d: no legacy
  # stamp exists to seed even if we wanted to — the write path is gone).
  _link_rein_package
  _link_rein_bin
  _link_task_axis_policy
  _write_authority_switched_all_three

  local payload
  payload=$(_event_payload "$SANDBOX/src/existing.py" "Edit" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(j) active_task delegate (axis-only policy, active_task-only) must not be contaminated by code_review/security_review requirements — Edit passes despite no review stamps at all"
  _v2_state_db_exists || fail "(j) expected v2 state db to exist — the active_task axis's own delegation genuinely ran"
}

run_test test_a_switch_on_active_task_source_edit_allows "$HOOK"
run_test test_b_switch_on_no_active_task_source_edit_blocks "$HOOK"
run_test test_c_switch_on_nonsource_edit_allows_no_delegation "$HOOK"
run_test test_d_switch_on_exempt_path_allows_no_delegation "$HOOK"
run_test test_e_switch_off_allows_no_v1_fallback "$HOOK"
run_test test_f_switch_check_unavailable_fails_closed "$HOOK"
run_test test_g_delegate_exec_failure_fails_closed "$HOOK"
run_test test_h_policy_file_missing_fails_closed "$HOOK"
run_test test_i_write_tool_allows_with_active_task "$HOOK"
run_test test_i_write_tool_blocks_without_active_task "$HOOK"
run_test test_i_multiedit_tool_allows_with_active_task "$HOOK"
run_test test_i_multiedit_tool_blocks_without_active_task "$HOOK"
run_test test_j_cross_axis_no_review_stamps_required "$HOOK"

summary
