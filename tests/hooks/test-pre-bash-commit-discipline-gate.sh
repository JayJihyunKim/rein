#!/bin/bash
# tests/hooks/test-pre-bash-commit-discipline-gate.sh
#
# Phase 7 웨이브 3 ③-c (커밋 게이트 교대) — 신설 훅
# `pre-bash-commit-discipline-gate.sh`(coverage-matrix [P2]/[I3] + 커밋
# 메시지 포맷 [P7]/[I4]/[I5] 등 v1 존속 규율 전담, 리뷰 stamp 판정은
# 전혀 하지 않는다)의 행위 기반 계약 테스트.
#
# 이관 범위 — 구 tests/hooks/test-pre-bash-test-commit-gate.sh(삭제)의
# 규율 절반만 여기로 옮긴다:
#   [GMF-1] 커밋 감지가 coverage-marker 게이팅에 닿는 케이스
#   [GMF-2] merge/rebase/am 면제
#   [GMF-4] 정책 토글(신 훅 자기 키 + 구 2단계 umbrella 승계)
#   [I6]    JSON deny emitter 부재/손상 fail-closed
#   [샌드박스 cd 면제] GSD-3
# [P7] 커밋 메시지 포맷은 tests/hooks/test-commit-msg.sh 가 이미
# `pre-bash-commit-discipline-gate.sh` 를 대상으로 포괄적으로(plain/
# scoped/heredoc/quoted/co-authored/compound 등) 검증하고 있어 이 파일은
# 재작성하지 않는다 — 대신 coverage-marker([P2]/[I3]) 라는, 그 파일이
# 다루지 않는 이 훅의 다른 절반을 검증한다.
#
# "genuinely gated vs exempted" 증명 기법: 매 테스트가 존재하지 않는
# plan 경로를 가리키는 `.coverage-mismatch` 마커를 미리 심어 둔다
# (`_seed_gated_marker`). 커밋이 실제로 GIT_COMMIT_GATED=true 로
# 판정되면 이 마커가 [I3]("target unidentifiable" — 경로가 존재하지
# 않아 재검증 불가) 로 반드시 exit 2 를 낸다. 면제/미감지 경로는 이
# 마커를 건드리지 않고 조용히 통과한다 — 결과(exit 2 vs exit 0)가 곧
# "게이트 본문에 도달했는가"의 독립 증거다. 이 기법은 python/v2 패키지
# 의존이 전혀 없어 리뷰 축(별도 파일)과 완전히 분리해 결정론적으로
# 돌아간다.
#
# 절대 source 하지 않는다 — 항상 실제 훅 프로세스를 실행한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-commit-discipline-gate.sh"

# ------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------

# _seed_gated_marker — a `.coverage-mismatch` pointing at a plan path that
# does not exist. `revalidate_coverage_marker()` skips validating any entry
# whose path is missing (no positive PASS evidence), so `validated_count`
# stays 0 and the function returns rc=2 ([I3] conservative block, exit 2).
# Any command that reaches GIT_COMMIT_GATED=true (or otherwise enters the
# coverage-marker scan) will hit this deterministically.
_seed_gated_marker() {
  mkdir -p "$SANDBOX/trail/dod"
  printf '%s\n' "$SANDBOX/docs/plans/nonexistent-plan.md" > "$SANDBOX/trail/dod/.coverage-mismatch"
}

_input_for() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps({"tool_input": {"command": sys.argv[1]}, "tool_result": {}}))
PY
}

_run_cmd() {
  run_hook "$HOOK" "$(_input_for "$1")"
}

assert_gated_blocked_i3() {
  local msg="$1"
  assert_exit 2 "$msg: must be gated and blocked by the seeded I3 marker"
  assert_stderr_contains "coverage-mismatch" 2>/dev/null || assert_stderr_contains "target inside it could not be identified"
}

assert_not_gated_passes() {
  local msg="$1"
  assert_exit 0 "$msg: must NOT be gated (the seeded marker must be untouched)"
  [ -z "$HOOK_STDOUT" ] || fail "$msg: unexpected stdout: $HOOK_STDOUT"
}

# ============================================================
# GMF-1 — canonical "git commit" recognition inside this gate's own
# recomputation of GIT_COMMIT_GATED.
# ============================================================

test_gmf1_dash_C_commit_enters_coverage_gate() {
  _seed_gated_marker
  _run_cmd 'git -C . commit -m "feat: thing"'
  assert_gated_blocked_i3 "git -C . commit"
}

test_gmf1_double_space_commit_enters_coverage_gate() {
  _seed_gated_marker
  _run_cmd 'git  commit -m "feat: thing"'
  assert_gated_blocked_i3 "git  commit (double space)"
}

test_gmf1_commit_graph_not_gated() {
  _seed_gated_marker
  _run_cmd 'git commit-graph write'
  assert_not_gated_passes "git commit-graph write (different subcommand)"
}

test_gmf1_bogus_option_commit_not_gated() {
  _seed_gated_marker
  _run_cmd 'git --bogus commit'
  assert_not_gated_passes "git --bogus commit (allowlist-outside option, conservative non-match)"
}

test_gmf1_dash_c_kv_commit_enters_coverage_gate() {
  _seed_gated_marker
  _run_cmd 'git -c user.name=x commit -m "feat: thing"'
  assert_gated_blocked_i3 "git -c user.name=x commit"
}

test_gmf1_gitdir_commit_enters_coverage_gate() {
  _seed_gated_marker
  _run_cmd 'git --git-dir=.git commit -m "feat: thing"'
  assert_gated_blocked_i3 "git --git-dir=.git commit"
}

test_gmf1_config_commit_arg_not_gated() {
  _seed_gated_marker
  _run_cmd 'git config commit.gpgsign true'
  assert_not_gated_passes "git config commit.gpgsign (commit is config's argument, not a subcommand)"
}

test_gmf1_missing_git_model_lib_fails_closed() {
  _seed_gated_marker
  rm -f "$SANDBOX/.claude/hooks/lib/git-subcommand-model.sh"
  _run_cmd 'git commit -m "feat: x"'
  assert_exit 2 "missing git-subcommand-model lib must fail closed (exit 2), independent of the marker"
  assert_stderr_contains "[rein]"
}

# ============================================================
# GMF-2 — merge/rebase/am exemption precision, anchored (not a substring
# match on the commit MESSAGE body).
# ============================================================

test_gmf2_real_merge_exempt() {
  _seed_gated_marker
  _run_cmd 'git merge --no-ff feature/x'
  assert_not_gated_passes "a real git merge remains exempt"
}

test_gmf2_commit_msg_literal_git_merge_not_exempted() {
  _seed_gated_marker
  _run_cmd 'git commit -m "fix: document git merge behavior"'
  assert_gated_blocked_i3 "a commit whose MESSAGE contains the literal substring 'git merge' must NOT be exempted (GMF-2 anchor regression)"
}

# ============================================================
# GSD-3 — sandbox cd exemption (literal absolute path outside this repo).
# ============================================================

test_gsd3_sandbox_outside_cd_exempt() {
  _seed_gated_marker
  _run_cmd 'cd /tmp/rein-discipline-gate-sandbox-x && git commit -m "x"'
  assert_not_gated_passes "a commit under a literal cd outside this repo is exempt"
  assert_stderr_contains "sandbox commit"
}

test_gsd3_literal_inside_cd_still_gated() {
  _seed_gated_marker
  _run_cmd "cd $SANDBOX && git commit -m \"w\""
  assert_gated_blocked_i3 "a literal cd back INTO the repo must stay gated"
}

# ============================================================
# [I3] coverage marker target unidentifiable — empty marker.
# ============================================================

test_i3_empty_marker_fails_closed() {
  mkdir -p "$SANDBOX/trail/dod"
  touch "$SANDBOX/trail/dod/.coverage-mismatch"
  _run_cmd 'git commit -m "feat: thing"'
  assert_exit 2 "empty coverage marker must fail closed (exit 2)"
  assert_stderr_contains ".coverage-mismatch"
}

# ============================================================
# [P2] coverage matrix mismatch — real target, validator FAILs → JSON deny.
# ============================================================

test_p2_coverage_mismatch_denies_with_target() {
  cat > "$SANDBOX/scripts/rein-validate-coverage-matrix.py" <<'PY'
import sys
sys.exit(1)
PY
  chmod +x "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  mkdir -p "$SANDBOX/docs/plans"
  echo "# plan" > "$SANDBOX/docs/plans/p.md"
  mkdir -p "$SANDBOX/trail/dod"
  echo "$SANDBOX/docs/plans/p.md" > "$SANDBOX/trail/dod/.coverage-mismatch"
  _run_cmd 'git commit -m "feat: thing"'
  assert_exit 0 "P2 coverage validator FAIL: JSON deny path exits 0"
  case "$HOOK_STDOUT" in
    *COVERAGE_MISMATCH*) ;;
    *) fail "P2 expected COVERAGE_MISMATCH in deny JSON, got: $HOOK_STDOUT" ;;
  esac
}

# ============================================================
# [I6] JSON deny emitter unavailable — common infra, fail-closed.
# ============================================================

test_i6_emitter_unavailable_fails_closed() {
  rm -f "$SANDBOX/.claude/hooks/lib/json-deny-emitter.sh"
  _run_cmd 'git commit -m "feat: x"'
  assert_exit 2 "missing emitter must fail closed (exit 2)"
  assert_stderr_contains "[rein]"
}

# [I5] — 커밋 메시지 helper 가 "부재"(I4, test-commit-msg.sh 소관)가 아니라
# "존재하되 실행 실패"하는 절반. 구 스위트 test_i5_commit_msg_helper_exec_
# failure_fails_closed 계승 (③-c 처분 대장의 판단 보류 1 해소 — 부모 추가).
# helper 를 non-zero exit 스텁으로 바꿔치기하면 heredoc 우회류 silent
# bypass 방지 계약대로 fail-closed (exit 2) 여야 한다.
test_i5_commit_msg_helper_exec_failure_fails_closed() {
  cat > "$SANDBOX/.claude/hooks/lib/extract-commit-msg.py" <<'PY'
import sys
sys.exit(3)
PY
  _run_cmd 'git commit -m "feat: x"'
  assert_exit 2 "helper exec failure must fail closed (exit 2)"
  assert_stderr_contains "could not be extracted"
}

# ============================================================
# GMF-4 — policy-toggle fail-open seal (own key form).
# Same technique as the old suite's GMF-4 tests: a stub loader isolates the
# gate's rc-handling contract from the real loader's yaml parsing.
#
# STRICT contract (Phase 7 wave 3 ③-c code review round 1 High fix): the
# hook now calls the loader's `--strict <hook-name>` mode, where rc 78
# (EX_CONFIG) means "explicitly disabled" and every other rc (0=enabled
# aside) means "loader failure -> fail-closed, gate stays active". The stub
# below therefore exits 78 for "disabled" (not 1 anymore — 1 is now a
# loader-failure rc, exercised separately by test_gmf4_rc1_stub_fails_closed
# and test_gmf4_syntax_error_loader_fails_closed below).
# ============================================================

_seed_policy_loader() {
  local rc="$1"
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<PY
import sys
sys.exit($rc)
PY
}

# _seed_broken_policy_loader — a GENUINE python SyntaxError, not a clean
# sys.exit() stub. This is the exact reproduction from review round 1
# (High): a syntactically broken loader also exits rc 1 (interpreter
# failure), and the OLD `if rc==1: exit 0` contract misread that crash as
# "user explicitly disabled this hook" (fail-open hole). The STRICT contract
# fix must NOT exit 0 here — rc 1 (whatever its source) must fall through to
# the gate body (fail-closed active), proven the same way the rest of this
# suite proves "gate body reached": the seeded I3 marker fires exit 2.
_seed_broken_policy_loader() {
  mkdir -p "$SANDBOX/.claude/scripts"
  cat > "$SANDBOX/.claude/scripts/rein-policy-loader.py" <<'PY'
def broken(:
PY
}

_run_hook_missing_python() {
  local stdin_json="$1"
  local out rc
  out=$(
    with_missing_python
    printf '%s' "$stdin_json" \
      | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
        REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
        bash "$SANDBOX/.claude/hooks/$HOOK" 2>&1
    printf '_RC=%s\n' "$?"
    cleanup_fakes
  )
  HOOK_EXIT=$(printf '%s' "$out" | awk -F= '/^_RC=/{print $2}' | tail -1)
  HOOK_STDERR=$(printf '%s' "$out" | grep -v '^_RC=' || true)
}

_run_hook_real_python() {
  local stdin_json="$1"
  local tmp_out tmp_err
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  printf '%s' "$stdin_json" \
    | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/$HOOK" >"$tmp_out" 2>"$tmp_err"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_out")
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"
}

test_gmf4_python_absent_does_not_disable_gate() {
  _seed_gated_marker
  _seed_policy_loader 0
  _run_hook_missing_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" != "0" ] \
    || fail "GMF-4 python absent must NOT disable the gate (got exit 0 = fail-open)"
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 python absent should fail closed via resolver (expected exit 2, got: $HOOK_EXIT)"
}

test_gmf4_own_key_disable_exits_zero() {
  _seed_gated_marker
  _seed_policy_loader 78
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "0" ] \
    || fail "GMF-4 own-key disable (loader rc78=EX_CONFIG) should exit 0 (got: $HOOK_EXIT; stderr: $HOOK_STDERR)"
  [ -z "$HOOK_STDOUT" ] \
    || fail "GMF-4 own-key disable should emit no JSON deny (stdout: $HOOK_STDOUT)"
}

test_gmf4_own_key_enable_enters_body() {
  _seed_gated_marker
  _seed_policy_loader 0
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 own-key enable should enter the gate body (I3 marker block), got exit=$HOOK_EXIT stderr=$HOOK_STDERR"
}

test_gmf4_loader_crash_fails_closed() {
  _seed_gated_marker
  _seed_policy_loader 3
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 loader crash (rc3) must fall through to the gate body (fail-closed active), got exit=$HOOK_EXIT stderr=$HOOK_STDERR"
}

# --- ③-c review round 1 High fix: rc 1 is no longer "disabled" ---

test_gmf4_rc1_stub_fails_closed() {
  # A clean `sys.exit(1)` stub — distinct from a genuine SyntaxError (next
  # test) — pinned as its own case so the two rc-1 sources (deliberate stub
  # vs. real interpreter crash) both independently prove the STRICT contract
  # never treats rc 1 as "disabled" anymore.
  _seed_gated_marker
  _seed_policy_loader 1
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 rc1 stub (STRICT contract: rc1 != 78) must fall through to the gate body (fail-closed active), got exit=$HOOK_EXIT stderr=$HOOK_STDERR"
}

test_gmf4_syntax_error_loader_fails_closed() {
  # The exact review round 1 (High) reproduction: a genuinely broken (real
  # SyntaxError, not a sys.exit() stub) loader must NOT be read as an
  # explicit policy disable. Proven by reaching the gate body (I3 marker
  # fires exit 2), i.e. the gate stayed active despite the crash.
  _seed_gated_marker
  _seed_broken_policy_loader
  _run_hook_real_python '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "2" ] \
    || fail "GMF-4 syntax-error loader must fall through to the gate body (fail-closed active), NOT be read as explicit-disable, got exit=$HOOK_EXIT stderr=$HOOK_STDERR"
}

# --- Legacy umbrella key succession (신 훅 자기 이름 -> 구 1-hop -> 구
# 2-hop). 실제 rein-policy-loader.py 를 그대로 써서(스텁 아님) UMBRELLA_KEYS
# 매핑 자체를 검증한다 — hooks.yaml 은 CWD 상대경로로 로드되므로 이 두
# 테스트만 서브셸에서 sandbox 로 cd 한다.
_run_hook_real_loader_cwd_sandbox() {
  local stdin_json="$1"
  local tmp_out tmp_err
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  (
    cd "$SANDBOX" \
      && printf '%s' "$stdin_json" \
        | CLAUDE_PLUGIN_ROOT="$SANDBOX/.claude" \
          REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
          bash "$SANDBOX/.claude/hooks/$HOOK"
  ) >"$tmp_out" 2>"$tmp_err"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_out")
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"
}

test_gmf4_legacy_umbrella_one_hop_disables() {
  _seed_gated_marker
  cp "$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py" \
     "$SANDBOX/.claude/scripts/rein-policy-loader.py" 2>/dev/null \
    || { mkdir -p "$SANDBOX/.claude/scripts"; cp "$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py" "$SANDBOX/.claude/scripts/rein-policy-loader.py"; }
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'pre-bash-test-commit-gate: false\n' > "$SANDBOX/.rein/policy/hooks.yaml"
  _run_hook_real_loader_cwd_sandbox '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "0" ] \
    || fail "legacy 1-hop umbrella key 'pre-bash-test-commit-gate: false' must still disable this successor hook (got exit=$HOOK_EXIT stderr=$HOOK_STDERR)"
  [ -z "$HOOK_STDOUT" ] \
    || fail "1-hop umbrella disable should emit no JSON deny (stdout: $HOOK_STDOUT)"
}

test_gmf4_legacy_umbrella_two_hop_disables() {
  _seed_gated_marker
  mkdir -p "$SANDBOX/.claude/scripts"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py" \
     "$SANDBOX/.claude/scripts/rein-policy-loader.py"
  mkdir -p "$SANDBOX/.rein/policy"
  # the ORIGINAL single hook's key, two splits back — the umbrella chain
  # must not lose depth as the hook keeps splitting (hook header docstring).
  printf 'pre-bash-guard: false\n' > "$SANDBOX/.rein/policy/hooks.yaml"
  _run_hook_real_loader_cwd_sandbox '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  [ "$HOOK_EXIT" = "0" ] \
    || fail "legacy 2-hop umbrella key 'pre-bash-guard: false' must still disable this successor hook (got exit=$HOOK_EXIT stderr=$HOOK_STDERR)"
  [ -z "$HOOK_STDOUT" ] \
    || fail "2-hop umbrella disable should emit no JSON deny (stdout: $HOOK_STDOUT)"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_gmf1_dash_C_commit_enters_coverage_gate "$HOOK"
run_test test_gmf1_double_space_commit_enters_coverage_gate "$HOOK"
run_test test_gmf1_commit_graph_not_gated "$HOOK"
run_test test_gmf1_bogus_option_commit_not_gated "$HOOK"
run_test test_gmf1_dash_c_kv_commit_enters_coverage_gate "$HOOK"
run_test test_gmf1_gitdir_commit_enters_coverage_gate "$HOOK"
run_test test_gmf1_config_commit_arg_not_gated "$HOOK"
run_test test_gmf1_missing_git_model_lib_fails_closed "$HOOK"
run_test test_gmf2_real_merge_exempt "$HOOK"
run_test test_gmf2_commit_msg_literal_git_merge_not_exempted "$HOOK"
run_test test_gsd3_sandbox_outside_cd_exempt "$HOOK"
run_test test_gsd3_literal_inside_cd_still_gated "$HOOK"
run_test test_i3_empty_marker_fails_closed "$HOOK"
run_test test_p2_coverage_mismatch_denies_with_target "$HOOK"
run_test test_i6_emitter_unavailable_fails_closed "$HOOK"
run_test test_i5_commit_msg_helper_exec_failure_fails_closed "$HOOK"
run_test test_gmf4_python_absent_does_not_disable_gate "$HOOK"
run_test test_gmf4_own_key_disable_exits_zero "$HOOK"
run_test test_gmf4_own_key_enable_enters_body "$HOOK"
run_test test_gmf4_loader_crash_fails_closed "$HOOK"
run_test test_gmf4_rc1_stub_fails_closed "$HOOK"
run_test test_gmf4_syntax_error_loader_fails_closed "$HOOK"
run_test test_gmf4_legacy_umbrella_one_hop_disables "$HOOK"
run_test test_gmf4_legacy_umbrella_two_hop_disables "$HOOK"

summary
