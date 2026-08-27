#!/bin/bash
# tests/hooks/test-pre-bash-commit-review-gate.sh
#
# Phase 7 웨이브 3 ③-c (커밋 게이트 교대) — 신설 훅
# `pre-bash-commit-review-gate.sh`(code_review + security_review 두
# 리뷰 축의 v2 위임 전용 래퍼)의 행위 기반 계약 테스트. 이 훅 자신의
# 헤더(plugins/rein-core/hooks/pre-bash-commit-review-gate.sh)가 판정
# 트리의 정본이다 — 이 스위트는 그 트리를 실제 실행으로 고정한다.
#
# 절대 source 하지 않는다 — 항상 실제 훅 프로세스를 실행하고 exit
# code/stdout JSON 을 단언한다(tests/hooks/test-pre-bash-test-commit-
# gate.sh 헤더가 남긴 교훈 — source 방식은 SCRIPT_DIR 재계산으로
# false-green 을 낸 전례가 있다).
#
# 차단 단언은 두 형태를 구분한다:
#   exit 2            — fail-closed (인프라/전환확인/위임 FAIL)
#   exit 0 + JSON deny — v2 native DENY relay (assert_json_deny_relay)
#
# "진짜 위임이 일어났는가"는 tests/hooks/test-code-review-authority-
# switch.sh 와 동일한 부수효과 관측(`.rein/state/runtime.sqlite3` 선생성)
# 으로 증명한다 — `_v2_state_db_exists`.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-commit-review-gate.sh"
COMMIT_CMD='git commit -m "feat: thing"'

# ------------------------------------------------------------
# Payload + sandbox prep helpers (파일 로컬 — 공유 하네스에 없음).
# tests/hooks/test-code-review-authority-switch.sh 의 동명 헬퍼와 동일한
# 기법(self-location 심볼릭 링크) — 이 파일에서 독립 사본으로 정의한다
# (기존 관례: 각 테스트 파일이 자기 sandbox-prep 을 갖는다).
# ------------------------------------------------------------

_event_payload() {
  # $1=command $2=cwd
  python3 - "$1" "$2" <<'PY'
import json
import sys

command, cwd = sys.argv[1], sys.argv[2]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": command},
    "cwd": cwd,
}))
PY
}

_link_rein_package() {
  mkdir -p "$SANDBOX/.claude"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/rein" "$SANDBOX/.claude/rein"
}
_link_rein_bin() {
  mkdir -p "$SANDBOX/.claude/bin"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/bin/rein" "$SANDBOX/.claude/bin/rein"
}
_link_security_axis_policy() {
  mkdir -p "$SANDBOX/.rein/policy"
  rm -rf "$SANDBOX/.rein/policy/security-axis"
  cp -R "$REAL_PROJECT_DIR/tests/fixtures/policy/security-axis" "$SANDBOX/.rein/policy/security-axis"
}
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
_write_authority_switched() {
  # $1... = capability names to include in `switched:`
  mkdir -p "$SANDBOX/.rein/policy"
  {
    printf 'switched:\n'
    for cap in "$@"; do
      printf '  - %s\n' "$cap"
    done
  } > "$SANDBOX/.rein/policy/authority.yaml"
}
_write_authority_switched_none() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched: none\n' > "$SANDBOX/.rein/policy/authority.yaml"
}

_v2_state_db_exists() {
  [ -f "$SANDBOX/.rein/state/runtime.sqlite3" ]
}

# _gitignore_rein_runtime — real rein-managed repos gitignore
# `/.rein/state/` and `/.rein/logs/` (see this repo's own .gitignore) so
# `bin/rein hook`'s own runtime side effects (sqlite3 state db, block log)
# never show up as untracked noise in `git status`. Sandboxes here start
# with no .gitignore at all, so without this the FIRST hook invocation's
# own bootstrap writes would pollute the very changeset digest that same
# invocation computes — self-polluting the subject-empty/genuine-evidence
# scenarios below (real repos are immune because those paths are ignored).
_gitignore_rein_runtime() {
  cat >> "$SANDBOX/.gitignore" <<'EOF'
/.rein/state/
/.rein/logs/
EOF
}

# _seed_real_repo — turn $SANDBOX into a real git repo with a baseline
# commit, so `git -C "$PROJECT_DIR" diff --cached` (digest-scope resolution)
# and `git_commit_outside_repo_cd` both have a real repo to inspect.
_seed_real_repo() {
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  printf '# baseline\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  git -C "$SANDBOX" commit -q -m "chore: baseline"
}

_write_code_stamp() {
  local rat="$1" cyc="$2" ver="$3"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'reviewed_at: %s\nreviewer: codex\ndiff_base: N/A\nverdict: %s\ncycle: %s\nscope: wrapper-generated\n' \
    "$rat" "$ver" "$cyc" > "$SANDBOX/trail/dod/.codex-reviewed"
}
_write_security_stamp() {
  local rev="$1" cyc="$2" ver="$3"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'reviewer=security-reviewer\nreviewed=%s\nsecurity_level=standard\ncycle=%s\nverdict=%s\nmechanism=llm-security-review\n' \
    "$rev" "$cyc" "$ver" > "$SANDBOX/trail/dod/.security-reviewed"
}

# ------------------------------------------------------------
# Assertions
# ------------------------------------------------------------

assert_pass() {
  assert_exit 0 "$1: should pass"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no JSON deny, got stdout: $HOOK_STDOUT"
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

# assert_json_deny_relay — v2 native DENY relay contract: exit 0, exactly one
# JSON object on stdout, permissionDecision == deny, and (unless the caller
# passes "any" as $1) the reason text contains the given substring.
assert_json_deny_relay() {
  local expect_substring="$1"
  local msg="$2"
  assert_exit 0 "$msg: JSON deny relay exits 0"
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "$msg: permissionDecision not deny (got '$decision', stdout: $HOOK_STDOUT)"
  # exactly one JSON object: the whole stdout must parse as a single value.
  printf '%s' "$HOOK_STDOUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1 \
    || fail "$msg: stdout is not exactly one JSON value: $HOOK_STDOUT"
  if [ "$expect_substring" != "any" ]; then
    case "$HOOK_STDOUT" in
      *"$expect_substring"*) ;;
      *) fail "$msg: expected substring '$expect_substring' not found in: $HOOK_STDOUT" ;;
    esac
  fi
}

assert_fail_closed_exit2() {
  local msg="$1"
  assert_exit 2 "$msg"
  [ -z "$HOOK_STDOUT" ] || fail "$msg: exit 2 fail-closed must not also emit JSON on stdout: $HOOK_STDOUT"
}

# ============================================================
# 1. code_review × commit — 짝 테스트 (§3.6 진입점별 짝 계약)
# ============================================================

# 미전환 → 통과. security 축은 폴더 자체를 안 심어 구조적으로 skip 시켜,
# 오직 code_review 의 NOT_SWITCHED 분기만 변수로 남긴다.
test_code_review_not_switched_allows_axis_skip() {
  _seed_real_repo
  _link_rein_package
  # code_review 를 switched 목록에서 제외 (security_review 도 제외 —
  # 그 축은 폴더 부재로 어차피 switch-check 까지 가지도 않는다).
  _write_authority_switched_none
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "code_review NOT_SWITCHED (+ security axis folder absent) → overall pass"
}

# 전환확인 자체가 실패(rein 패키지 조회 불가) → 차단. 이 훅은 code_review
# 를 먼저 평가하므로 패키지 부재는 항상 code_review 축에서 먼저 잡힌다
# — 아래 절 "축별 ERROR 격리가 구조적으로 불가능한 이유" 참조.
test_switch_check_unavailable_fails_closed_even_when_policy_would_allow() {
  _seed_real_repo
  # 의도적으로 _link_rein_package 를 호출하지 않는다 — self-location 이
  # rein 패키지를 못 찾아 is_switched() 의 python 프로브가
  # ModuleNotFoundError 로 실패한다.
  # DoD 를 전혀 심지 않는다 — task.exists 가 부재라 만약 전환확인이
  # 정상적으로 진행됐다면(NOT_SWITCHED 든 SWITCHED+ALLOW 든) 이 커밋은
  # 결국 통과했을 상황이다. 그럼에도 fail-closed 로 차단된다는 것이,
  # ERROR 가 "확인 불가하면 무조건 거부"임을(다른 어떤 결과로도 override
  # 되지 않음을) 증명한다.
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_fail_closed_exit2 "switch-check unavailable (no rein package) must fail closed even though the eventual policy verdict would have allowed"
  assert_stderr_contains "[rein]"
  if _v2_state_db_exists; then
    fail "switch-check ERROR must never reach delegation — v2 state db should not exist"
  fi
}

# ============================================================
# GMF-4 — policy-toggle STRICT contract 회귀 (③-c 리뷰 1회차 High 수리).
# 이 훅의 정책 토글 블록이 이제 rein-policy-loader.py 의 `--strict` 모드를
# 쓴다 (rc 78=명시적 비활성 / rc 0=활성 / 그 외(rc 1 포함)=로더 호출 실패
# → fail-closed). 이 테스트는 "진짜 SyntaxError 로더" 를 심어, 그 rc 1 이
# 더 이상 "비활성"으로 오독되지 않는지 증명한다 — 위
# test_switch_check_unavailable_fails_closed_even_when_policy_would_allow
# 픽스처를 그대로 재사용한다(_link_rein_package 를 호출하지 않아 전환확인
# 자체가 ERROR 로 fail-closed 되는 경로). 이 테스트가 그 픽스처에 추가하는
# 유일한 변수는 CLAUDE_PLUGIN_ROOT(정책 토글 블록을 활성화하는 데 필요) +
# 구문 오류 로더뿐이다 — 로더 rc 1 이 조기 exit 0(fail-open)을 만들지
# 않고, 흐름이 그대로 흘러내려가 기존 fail-closed 지점에서 exit 2 로
# 귀결되는지를 본다.
# ============================================================

_seed_broken_policy_loader() {
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<'PY'
def broken(:
PY
}

test_gmf4_syntax_error_loader_falls_through_to_fail_closed() {
  _seed_real_repo
  _seed_broken_policy_loader
  # 의도적으로 _link_rein_package 를 호출하지 않는다 — 위
  # test_switch_check_unavailable_fails_closed_even_when_policy_would_allow
  # 와 동일하게 switch-check 자체가 ERROR 로 fail-closed 되는 경로를
  # 재사용한다.
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" run_hook "$HOOK" "$payload"
  assert_fail_closed_exit2 "syntax-error policy loader (rc=1 SyntaxError) must NOT be read as explicit-disable — falls through to the existing switch-check-unavailable fail-closed path"
  assert_stderr_contains "[rein]"
  if _v2_state_db_exists; then
    fail "gate must not reach v2 delegation when the policy loader crashes and switch-check is unavailable"
  fi
}

# ============================================================
# 2. security_review × commit — 짝 테스트
# ============================================================

test_security_review_not_switched_allows_axis_skip() {
  _seed_real_repo
  _link_rein_package
  _link_security_axis_policy
  # task.exists 부재(DoD 없음) → code_review 축은 정책 자체가 미매칭돼
  # switched 여부와 무관하게 항상 ALLOW. security_review 만 NOT_SWITCHED
  # 로 변수화된다.
  _write_authority_switched_none
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "security_review NOT_SWITCHED (axis folder present, policy file present) → overall pass"
}

# ============================================================
# 3. active_task × commit — 이 훅이 직접 위임하지 않는 축의 간접 실증
# (v2 기본 commit.yaml 의 task.exists 조건화, Phase 7 선행 결정 1)
# ============================================================

# (a) 활성 작업 없음 → 통과. code_review 는 switched 지만 commit.yaml
# 의 `when: task.exists: "true"` 가 미매칭돼 요구 자체가 발동하지 않는다
# — v1 "작업 없으면 리뷰 불요" 의미 보존의 v2 경로 실증.
test_active_task_pair_a_no_active_task_allows() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  # trail/dod/ 를 비운다(0개 dod-*.md) — sandbox_setup 이 만드는 빈
  # trail/dod/ 그대로 둔다.
  _write_authority_switched "code_review"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "no active task (task.exists absent) + code_review switched → commit passes without any review evidence"
  _v2_state_db_exists || fail "expected genuine delegation to have occurred (state db) even though the policy ultimately did not match"
}

# (b) 작업 존재 판정 재료 자체를 읽을 수 없음(trail/dod 권한 000) → 차단.
# teardown 에서 권한을 반드시 복구한다 (run_test 의 sandbox_teardown 이
# rm -rf 를 시도하므로, 그 전에 복구하지 않으면 잔여 디렉토리가 남는다).
test_active_task_pair_b_task_material_unreadable_blocks() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _write_authority_switched "code_review"
  chmod 000 "$SANDBOX/trail/dod"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  chmod 755 "$SANDBOX/trail/dod"
  # 차단 형식은 어느 쪽이든 인정 — 관찰된 실제 형식은 v2 native DENY
  # relay(exit 0 + JSON deny, task.exists fact 해석 실패가 evaluator 안에서
  # BLOCK 으로 흡수됨)지만, 계약은 형식을 고정하지 않는다.
  if [ "$HOOK_EXIT" = "2" ]; then
    :
  elif [ "$HOOK_EXIT" = "0" ] && [ "$(_hook_stdout_permission_decision)" = "deny" ]; then
    :
  else
    fail "unreadable trail/dod must block (exit 2 or JSON deny), got exit=$HOOK_EXIT stdout=$HOOK_STDOUT stderr=$HOOK_STDERR"
  fi
}

# ============================================================
# 4. 위임 FAIL → fail-closed exit 2, v1 폴백 부재 확인
# ============================================================

test_delegate_fail_no_v1_fallback_fails_closed() {
  _seed_real_repo
  _link_rein_package
  _write_broken_engine_script
  _write_authority_switched "code_review"
  # DoD 를 심어 task.exists=true 로 만든다 — 위임이 성공했다면 v2 가
  # 실제로 code_review 요구를 발동시켰을 상황을 만들어, "위임 실패가
  # 조용히 통과로 새지 않는다"를 더 강하게 증명한다.
  seed_dod "dod-2026-08-23-review-gate-test.md"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_fail_closed_exit2 "delegate FAIL (broken engine script) must fail closed, no v1 fallback judgment"
  assert_stderr_contains "there is no v1 fallback judgment for this axis anymore"
}

# ============================================================
# 5. DENY relay — v2 native JSON 그대로, 정확히 1개
# ============================================================

test_deny_relay_is_exactly_one_v2_json() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _write_authority_switched "code_review"
  seed_dod "dod-2026-08-23-review-gate-test.md"
  # 코드 리뷰 evidence 전무 — 번들 기본 commit.yaml 이 code_review 를
  # 요구(task.exists=true)하므로 v2 native DENY 가 나야 한다.
  #
  # Phase 7 웨이브 3 ③-d 재조준: reason 문자열에 더 이상 "code_review"
  # 부분문자열이 없다 — 그 부분문자열은 evaluator.py 의 legacy dual-read
  # authority_note(v2 evidence 부재 시 항상 부착되던 주석)의 산물이었다.
  # ③-d 로 그 note 부착 조건이 "v2 가 판정할 재료 자체가 없는" 두 축
  # (tests_passed/user_approval) 으로 좁혀지면서, code_review/security_
  # review 처럼 v2 가 명확히 "미충족"을 판정한 통상 DENY 는 이제 generic
  # `REASON_MISSING_EVIDENCE`("required evidence is missing")만 낸다
  # (evaluator.py 자신의 "Authority 배선" 절 참조). "any" 로 완화하고,
  # 대신 아래 state db 존재 확인이 "진짜 v2 위임이었다"는 증거를 그대로
  # 담당한다(이 단언은 ③-d 와 무관하게 원래도 별도 증거였다).
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_json_deny_relay "any" "code_review DENY relay must be v2's own JSON verbatim"
  _v2_state_db_exists || fail "expected genuine delegation for the DENY relay to be observed"
}

# ============================================================
# 6. 보안 축 설정 가드 (전환 확인보다 선행)
# ============================================================

test_security_axis_folder_absent_skips_axis() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  # .rein/policy/security-axis/ 자체를 만들지 않는다.
  _write_authority_switched "code_review" "security_review"
  # code_review 도 통과하도록 task.exists 부재 유지(DoD 없음).
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "security-axis policy folder absent → axis skipped entirely (declared opt-out)"
}

test_security_axis_file_missing_fails_closed() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  mkdir -p "$SANDBOX/.rein/policy/security-axis"
  printf 'version: 1\n' > "$SANDBOX/.rein/policy/security-axis/_version.yaml"
  # commit-security.yaml 은 의도적으로 두지 않는다.
  _write_authority_switched "code_review" "security_review"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_fail_closed_exit2 "security-axis folder present but commit-security.yaml missing → damaged-config fail-closed"
  assert_stderr_contains "commit-security.yaml"
}

# ============================================================
# 7. 조기 종료 3종 (v1 의미 보존)
# ============================================================

test_non_commit_command_passes_immediately() {
  _seed_real_repo
  local payload
  payload=$(_event_payload 'ls -la' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "non-commit command passes immediately (never reaches switch-check)"
  if _v2_state_db_exists; then
    fail "non-commit command must never attempt delegation"
  fi
}

test_real_merge_exempt_no_delegation() {
  _seed_real_repo
  _link_rein_package
  _write_authority_switched "code_review" "security_review"
  local payload
  payload=$(_event_payload 'git merge --no-ff feature/x' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "real git merge is exempt from both review axes"
  if _v2_state_db_exists; then
    fail "a real merge must never attempt delegation for either axis"
  fi
}

test_commit_msg_literal_git_merge_not_exempted() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  # code_review 축이 트리거되도록 하되(task.exists=true), 통과하도록
  # evidence 는 비운다 — GMF-2 회귀 검증은 "면제되지 않고 축에 도달했는가"
  # (state db 존재)가 핵심이므로, 결과가 ALLOW 든 DENY 든 무방하다.
  seed_dod "dod-2026-08-23-review-gate-test.md"
  local payload
  payload=$(_event_payload 'git commit -m "fix: document git merge behavior"' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  _v2_state_db_exists || fail "a commit message containing the literal substring 'git merge' must NOT be exempted — the review axis must have been genuinely entered (GMF-2 anchor regression)"
}

# ============================================================
# 8. GMF-1 커밋 감지 회귀 (review-gate 자신의 독립 재계산)
# ============================================================

test_gmf1_dash_C_commit_enters_axis() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  seed_dod "dod-2026-08-23-review-gate-test.md"
  local payload
  payload=$(_event_payload 'git -C . commit -m "feat: thing"' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  _v2_state_db_exists || fail "git -C . commit must enter the review axis (delegation attempted)"
}

test_gmf1_double_space_commit_enters_axis() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  seed_dod "dod-2026-08-23-review-gate-test.md"
  local payload
  payload=$(_event_payload 'git  commit -m "feat: thing"' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  _v2_state_db_exists || fail "git  commit (double space) must enter the review axis (delegation attempted)"
}

test_gmf1_commit_graph_not_gated() {
  _seed_real_repo
  _link_rein_package
  local payload
  payload=$(_event_payload 'git commit-graph write' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "git commit-graph write is a different subcommand — must not enter the review axis"
  if _v2_state_db_exists; then
    fail "git commit-graph write must never attempt delegation"
  fi
}

# ============================================================
# 9. 샌드박스 cd 면제 (GSD-3)
# ============================================================

test_sandbox_outside_cd_commit_exempt_with_notice() {
  _seed_real_repo
  _link_rein_package
  local payload
  payload=$(_event_payload 'cd /tmp/rein-review-gate-sandbox-x && git init -q && git commit -m "x"' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "a commit under a literal cd outside this repo is exempt from both review axes"
  assert_stderr_contains "outside this repository"
  if _v2_state_db_exists; then
    fail "a sandboxed commit must never attempt delegation for either axis"
  fi
}

# ============================================================
# 10. v2 네이티브 판정 실증 (문서-only 커밋 / 실 v2 증거 발급)
#
# Phase 7 웨이브 3 ③-d (2026-08-24) 전면 재조준. ③-c 시점(위 원 주석,
# 삭제됨)에는 evaluator.py 가 여전히 legacy dual-read 를 갖고 있어
# "subject-empty 도 legacy 표식 부재/존재에 좌우된다"는 전환기 동작을
# 실측 고정했다. ③-d 로 evaluator.py 의 legacy 대체 계층이 완전히
# 제거되면서 spec §3.6 판정 상태표의 "legacy 제거 후 (종국)" 열이 유일한
# 경로가 됐다: subject-empty(문서-only 변경, 검토할 대상 자체가 없음)는
# **legacy 표식 존재 여부와 무관하게 항상 충족**이다. 원 (실측 A)("표식
# 없으면 문서-only 도 차단")는 **정당 소멸**(그 전환기 판정 분기 자체가
# 코드에서 사라짐, evaluator.py 자신의 "Phase 7 웨이브 3 ③-d" 주석 참조)
# — 아래 test_docs_only_allows_via_subject_empty_no_evidence_needed 로
# 대체하며, 기대값이 정반대로 뒤집힌다(이제 ALLOW). 원 (실측 B)("신선한
# legacy 표식이 있으면 통과")도 legacy 표식이 더 이상 판정에 관여하지
# 않으므로 정당 소멸이지만, 그 항목이 실제로 규명하던 더 넓은 가치 —
# "이 훅이 실제 v2 증거 발급을 실증 가능한 형태로 관통해 통과시킬 수
# 있다"— 는 아래 test_real_code_change_allows_via_genuine_v2_evidence_
# both_axes 로 대체 계승한다: legacy 표식 대신 `bin/rein issue-evidence`
# 로 **진짜** code_review/security_review 증거를 발급해 실 콘텐츠 변경을
# 통과시킨다 — 이 파일에서 지금까지 유일하게 비어있던 "genuine ALLOW
# via v2 evidence" 커버리지 공백을 메운다(기존 ALLOW 케이스는 전부
# 축-미전환/axis-skip 경유였다).
# ============================================================

# _issue_v2_evidence CAPABILITY [POLICY_DIR]
#   $SANDBOX 의 현재 changeset 에 대해 실제 v2 증거를 발급한다(호출 시점의
#   staged 변경을 그대로 대상으로 삼는다 — 발급 후 트리를 더 바꾸면 훅이
#   재계산하는 digest 와 어긋난다). POLICY_DIR 는 security_review 축 전용
#   정책 폴더(REIN_POLICY_DIR, _link_security_axis_policy 참조)를 넘길 때만
#   쓴다 — code_review 는 번들 기본 정책으로 자립한다.
_issue_v2_evidence() {
  local capability="$1" policy_dir="${2:-}"
  local digest
  if [ -n "$policy_dir" ]; then
    digest=$(REIN_PROJECT_ROOT="$SANDBOX" REIN_POLICY_DIR="$policy_dir" \
      "$SANDBOX/.claude/bin/rein" issue-evidence "$capability" --print-digest 2>/dev/null)
  else
    digest=$(REIN_PROJECT_ROOT="$SANDBOX" \
      "$SANDBOX/.claude/bin/rein" issue-evidence "$capability" --print-digest 2>/dev/null)
  fi
  if [ -z "$digest" ]; then
    echo "_issue_v2_evidence: empty digest for $capability" >&2
    return 1
  fi
  if [ -n "$policy_dir" ]; then
    REIN_PROJECT_ROOT="$SANDBOX" REIN_POLICY_DIR="$policy_dir" \
      "$SANDBOX/.claude/bin/rein" issue-evidence "$capability" --verdict PASS --reviewed-digest "$digest" >/dev/null 2>&1
  else
    REIN_PROJECT_ROOT="$SANDBOX" \
      "$SANDBOX/.claude/bin/rein" issue-evidence "$capability" --verdict PASS --reviewed-digest "$digest" >/dev/null 2>&1
  fi
}

# (종국 계약, 원 실측 A 의 후계 — 기대값 반전) 문서-only + 증거 전무(둘 다)
# + 양축 전환 → 통과. subject-empty 는 이제 legacy 표식과 무관하게 항상
# 충족이다.
test_docs_only_allows_via_subject_empty_no_evidence_needed() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched "code_review" "security_review"
  seed_dod "dod-2026-08-23-review-gate-test.md"
  _gitignore_rein_runtime
  # Bake all of the above test-infra (.rein/policy/*, .claude/*, trail/dod/*,
  # .gitignore) into a baseline commit BEFORE staging the actual docs-only
  # change under test — otherwise those untracked setup files (none of them
  # under .md/docs//trail/) would themselves count as non-allowlisted
  # subject paths and the code_review digest would never be subject-empty.
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  printf '# changed\n' >> "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  local payload
  payload=$(_event_payload 'git commit -m "docs: update changelog"' "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "docs-only commit with no evidence anywhere still passes (subject-empty is unconditionally satisfied post-③-d)"
  _v2_state_db_exists || fail "expected genuine delegation on both axes (subject-empty is a v2 verdict, not a skip)"
}

# (종국 계약, 원 실측 B 가 지키던 "genuine ALLOW via real evidence" 가치의
# 후계 — 메커니즘을 legacy 표식에서 실 v2 발급으로 교체) 실제 소스 변경
# (allowlist 밖) + 양축 전환 + 양축 모두 실제 v2 evidence 발급(PASS) →
# 통과. legacy 표식은 어디에도 등장하지 않는다.
test_real_code_change_allows_via_genuine_v2_evidence_both_axes() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched "code_review" "security_review"
  seed_dod "dod-2026-08-23-review-gate-test.md"
  _gitignore_rein_runtime
  # Same baseline-commit rationale as test_docs_only_allows_via_subject_
  # empty_no_evidence_needed above — also required so the axis policy's
  # _version.yaml is committed (not merely staged/untracked), which is a
  # precondition for it to have "operating authority" for digest-scope
  # resolution (rein.platform.git.facts warns otherwise).
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  mkdir -p "$SANDBOX/scripts"
  printf 'echo real change under review\n' > "$SANDBOX/scripts/reviewed-change.sh"
  git -C "$SANDBOX" add scripts/reviewed-change.sh
  _issue_v2_evidence "code_review" \
    || fail "code_review evidence issuance failed"
  _issue_v2_evidence "security_review" "$SANDBOX/.rein/policy/security-axis" \
    || fail "security_review evidence issuance failed"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "real (non-allowlisted) change with genuine v2 evidence issued on both axes passes — no legacy marker involved anywhere"
  _v2_state_db_exists || fail "expected genuine delegation on both axes"
}

# ============================================================
# 11. TOCTOU 가드(명령 형태 검사) 비계승 — 정적 확인 (spec §3.6)
# ============================================================

test_toctou_no_sx_function_definitions_anywhere_in_hooks() {
  local hits
  hits=$(grep -rnE '^\s*_sx_[a-zA-Z0-9_]*\s*\(\)\s*\{' \
    "$REAL_PROJECT_DIR/plugins/rein-core/hooks/" 2>/dev/null || true)
  [ -z "$hits" ] || fail "found _sx_* function DEFINITIONS still present (TOCTOU guard must not have been re-inherited): $hits"
}

# ============================================================
# 12. security-reviewer.md 의 리뷰 기록 지침 (Phase 7 웨이브 3 ③-d 재조준
# — 구 T1.4 이관분의 후계). 원래는 이 훅이 legacy dual-read 로 소비하던
# `.security-reviewed` 3필드 스키마(reviewed=/cycle=/verdict=PASS)의
# content-rich 작성을 검증했다. ③-d 로 그 표식의 write/read 경로가 전부
# 제거되면서 이 검증 대상은 **정당 소멸**했다 — security-reviewer.md 는
# 이제 어떤 stamp 필드도 지시하지 않는다(agents/security-reviewer.md §6
# "리뷰 결과 기록 — v2 발급 전용" 참조). 후계: 그 문서가 실제로 v2 발급
# 호출(`bin/rein issue-evidence security_review ... --verdict PASS`)을
# 정확히 지시하고, 제거된 legacy 필드/파일명을 더 이상 언급하지 않는지로
# 재조준한다.
# ============================================================

test_security_reviewer_doc_issues_v2_evidence_not_legacy_stamp() {
  local doc="$REAL_PROJECT_DIR/plugins/rein-core/agents/security-reviewer.md"
  [ -f "$doc" ] || { fail "security-reviewer.md not found at $doc"; return; }
  if grep -q '\.security-reviewed' "$doc"; then
    fail "security-reviewer.md still references the removed legacy .security-reviewed marker"
  fi
  # security-reviewer.md delegates the actual `bin/rein issue-evidence
  # security_review` call to rein-mark-security-reviewed.sh (scripts/ —
  # sibling worker's territory) rather than invoking it directly; verify the
  # doc instructs that delegated call with the v2 verdict/digest args.
  grep -q 'rein-mark-security-reviewed.sh' "$doc" \
    || fail "doc must instruct calling rein-mark-security-reviewed.sh (the v2 issuance path)"
  grep -q -- '--verdict PASS' "$doc" \
    || fail "doc must instruct --verdict PASS on the issuance call"
  grep -q -- '--reviewed-digest' "$doc" \
    || fail "doc must instruct passing --reviewed-digest (review-start capture) on the issuance call"
}

test_toctou_new_hooks_have_no_command_form_guard() {
  local f hits
  for f in "$REAL_PROJECT_DIR/plugins/rein-core/hooks/pre-bash-commit-review-gate.sh" \
           "$REAL_PROJECT_DIR/plugins/rein-core/hooks/pre-bash-commit-discipline-gate.sh"; do
    hits=$(grep -inE '_sx_[a-zA-Z0-9_]*\s*\(\)' "$f" 2>/dev/null || true)
    [ -z "$hits" ] || fail "$f defines a command-form guard function (TOCTOU-style) — must not exist in the new hooks: $hits"
  done
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_code_review_not_switched_allows_axis_skip "$HOOK"
run_test test_switch_check_unavailable_fails_closed_even_when_policy_would_allow "$HOOK"
run_test test_gmf4_syntax_error_loader_falls_through_to_fail_closed "$HOOK"
run_test test_security_review_not_switched_allows_axis_skip "$HOOK"
run_test test_active_task_pair_a_no_active_task_allows "$HOOK"
run_test test_active_task_pair_b_task_material_unreadable_blocks "$HOOK"
run_test test_delegate_fail_no_v1_fallback_fails_closed "$HOOK"
run_test test_deny_relay_is_exactly_one_v2_json "$HOOK"
run_test test_security_axis_folder_absent_skips_axis "$HOOK"
run_test test_security_axis_file_missing_fails_closed "$HOOK"
run_test test_non_commit_command_passes_immediately "$HOOK"
run_test test_real_merge_exempt_no_delegation "$HOOK"
run_test test_commit_msg_literal_git_merge_not_exempted "$HOOK"
run_test test_gmf1_dash_C_commit_enters_axis "$HOOK"
run_test test_gmf1_double_space_commit_enters_axis "$HOOK"
run_test test_gmf1_commit_graph_not_gated "$HOOK"
run_test test_sandbox_outside_cd_commit_exempt_with_notice "$HOOK"
run_test test_docs_only_allows_via_subject_empty_no_evidence_needed "$HOOK"
run_test test_real_code_change_allows_via_genuine_v2_evidence_both_axes "$HOOK"
run_test test_security_reviewer_doc_issues_v2_evidence_not_legacy_stamp "$HOOK"
run_test test_toctou_no_sx_function_definitions_anywhere_in_hooks "$HOOK"
run_test test_toctou_new_hooks_have_no_command_form_guard "$HOOK"

summary
