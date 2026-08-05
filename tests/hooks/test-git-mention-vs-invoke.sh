#!/bin/bash
# tests/hooks/test-git-mention-vs-invoke.sh
# GSD-3 (dod-2026-08-05-gate-scope-defects) — 커밋 게이트의 "문자열 vs 실행" 구분.
#
# 결함: 커밋 탐지가 grep 행 단위 평가라 (a) heredoc 으로 파일에 기록될 텍스트의
# `git commit` 줄머리가 실행 절로 오인되고 (b) `cd <샌드박스> && git commit` 의
# 대상 저장소를 판별할 수단이 없어 샌드박스 재현 스크립트가 차단됐다 (2026-08-04
# 실측). 수리 계약:
#   - heredoc 본문은 매칭 입력에서 소거 (미종결 heredoc 은 fail-closed 로 원문 유지)
#   - 리터럴 절대경로 cd 가 저장소 밖이면 커밋 게이트 면제, 변수/불명 cd 는 차단 유지
#   - 서브셸 닫힘(`)`) 이후는 면제 해제 (실제 저장소 커밋 FN 금지)
#
# 행위 기반: 실제 pre-bash-test-commit-gate.sh 실행 + 종료코드/JSON deny 단언.
# 차단 = exit 2 + stderr 또는 exit 0 + JSON deny (게이트의 2-tier 프로토콜).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-test-commit-gate.sh"

# 스탬프를 심지 않은 상태에서 커밋으로 판정되면 반드시 차단된다 — 차단 형태는
# exit 2(stderr) 또는 exit 0 + JSON deny 둘 다 인정.
assert_blocked() {
  local msg="$1"
  if [ "$HOOK_EXIT" = "2" ]; then return 0; fi
  if [ "$HOOK_EXIT" = "0" ] && printf '%s' "$HOOK_STDOUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    return 0
  fi
  fail "$msg (exit=$HOOK_EXIT, stdout=$HOOK_STDOUT)"
}

assert_allowed() {
  local msg="$1"
  [ "$HOOK_EXIT" = "0" ] || { fail "$msg: expected pass, exit=$HOOK_EXIT stderr=$HOOK_STDERR"; return; }
  if printf '%s' "$HOOK_STDOUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    fail "$msg: unexpected JSON deny: $HOOK_STDOUT"
  fi
}

_input_for() {
  # $1 = command string (JSON 문자열로 이스케이프)
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "tool_result": {}}))
PY
}

_run_cmd() {
  run_hook "$HOOK" "$(_input_for "$1")"
}

# M1: heredoc 본문에 기록될 뿐인 git commit 텍스트는 커밋이 아니다.
#     Pre-fix: 줄머리 `git commit` 이 행 앵커에 걸려 차단. Post-fix: 통과.
test_heredoc_body_git_commit_is_mention() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cat > /tmp/repro.sh <<'\''EOF'\''
cd "$SB"
git init -q
git commit -m "test: sandbox repro"
EOF
bash /tmp/repro.sh'
  assert_allowed "heredoc body git commit text must not trigger the commit gate"
}

# M1b: 여는 줄은 유지 — heredoc 을 쓰는 진짜 커밋(-F <(...) 아님, 메시지
#      heredoc)은 여전히 커밋으로 판정된다. 소거가 실행 절을 지우지 않는다.
test_real_commit_with_heredoc_message_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'git commit -m "$(cat <<'\''EOF'\''
feat(x): message body
EOF
)"'
  assert_blocked "a real git commit whose message uses a heredoc must stay gated"
}

# M2: 미종결 heredoc 은 fail-closed — 본문 소거를 포기하고 기존 판정 유지
#     (본문 줄의 git commit 이 여전히 잡혀 차단 방향).
test_unterminated_heredoc_fails_closed() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cat > /tmp/x.sh <<EOF
git commit -m "text"'
  assert_blocked "unterminated heredoc must fail closed (no body elision)"
}

# M3: 리터럴 절대경로 cd 가 저장소 밖 → 커밋 게이트 면제 (샌드박스 커밋).
test_literal_outside_cd_commit_exempt() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd /tmp/rein-sandbox-x && git init -q && git commit -m "x"'
  assert_allowed "a commit under a literal cd outside the repo must be exempt"
  assert_stderr_contains "outside this repository" "exemption should be announced via NOTICE"
}

# M3b: 인용된 리터럴 경로도 면제.
test_quoted_literal_outside_cd_commit_exempt() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd "/tmp/rein-sandbox-y" && git commit -m "y"'
  assert_allowed "a quoted literal outside cd must also be exempt"
}

# M4: 변수 cd 는 면제 불가 — 기존대로 차단 (사용자 확정: 확실할 때만 면제).
test_variable_cd_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd "$SB" && git commit -m "z"'
  assert_blocked "a commit after a variable cd must stay gated (target unknown)"
}

# M4b: 저장소 안으로의 리터럴 cd 는 면제 불가.
test_literal_inside_cd_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd "cd $SANDBOX && git commit -m \"w\""
  assert_blocked "a commit after a literal cd INTO the repo must stay gated"
}

# M5: 서브셸 닫힘 이후의 커밋은 면제 해제 — `(cd /tmp/x; ...); git commit` 의
#     뒤쪽 커밋은 실제로 저장소에서 실행된다 (FN 금지).
test_commit_after_subshell_close_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd '(cd /tmp/rein-sandbox-z && git init -q); git commit -m "real"'
  assert_blocked "a commit after a closed subshell must stay gated"
}

# M5b (R1 High 반영 — 좁힘): 서브셸 형태는 면제하지 않는다. 괄호가 있으면
#     절 구조 증명이 복잡해지므로 면제 형태에서 제외 (보수 방향 — 게이트 유지).
test_commit_inside_subshell_not_exempt() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd '(cd /tmp/rein-sandbox-w && git init -q && git commit -m "in-sandbox")'
  assert_blocked "subshell form is outside the narrow exemption shape (conservative)"
}

# M8 (R1 High 재현): cd 성공에 종속되지 않는 구분자는 면제 불가 — `;` 는 cd
#     실패에도 뒤 절이 저장소에서 실행된다.
test_semicolon_cd_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd /missing; git commit -m "x"'
  assert_blocked "cd /missing; git commit must stay gated (commit not conditioned on cd)"
}

# M8b (R1 High 재현): `||` 는 cd 실패 경로에서 커밋이 저장소에서 실행된다.
test_or_cd_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd /missing || git commit -m "x"'
  assert_blocked "cd || git commit must stay gated (commit runs on cd FAILURE)"
}

# M8c (R1 High 재현): 단독 `&` 백그라운드는 cd 와 절연된다.
test_background_amp_cd_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd /tmp/rein-sandbox-a & git commit -m "x"'
  assert_blocked "cd & git commit must stay gated (background decouples cd)"
}

# M8d (R1 High 재현): 인용 속 구분자가 절 경계를 위조하는 조합 — `$`/`;` 금지로
#     면제 형태에서 제외된다.
test_quoted_separator_cd_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'printf "%s" "x; cd /tmp/rein-sandbox-b; x" && git commit -m "y"'
  assert_blocked "quoted separators must not fabricate an exempting cd clause"
}

# M8e (R1 High 재현): `cd /tmp && git -C <이 저장소> commit` 은 명시적으로 현재
#     저장소를 커밋한다 — -C/--git-dir/--work-tree/GIT_DIR 토큰은 면제 불가.
test_dash_c_redirect_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd "cd /tmp/rein-sandbox-c && git -C $SANDBOX commit -m \"x\""
  assert_blocked "git -C back into the repo must stay gated despite outside cd"
}

# M9 (R1 High 재현 — 소거기 FN): 인용 문자열 속의 <<WORD 는 heredoc 이 아니다.
#     이걸 heredoc 으로 오인하면 뒤따르는 **실제 커밋**이 본문으로 소거된다.
test_quoted_fake_heredoc_does_not_hide_commit() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'printf "%s\n" '\''<<EOF'\''
git commit -m "fix: real"
EOF
:'
  assert_blocked "a quoted <<EOF string must not absorb the following real commit"
}

# M10: 한 줄 다중 heredoc (`cat <<A <<B`) — 두 본문이 순서대로 소거되고
#      (본문 속 git commit 텍스트 비발동), 여는 줄의 실행 절은 유지된다.
test_multiple_heredocs_one_line() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cat <<A <<B
git commit -m "textA"
A
git commit -m "textB"
B'
  assert_allowed "both heredoc bodies from one opener line must be elided (mentions only)"
}

# M6: 맨 커밋(cd 없음)은 종전과 동일하게 차단 — 핵심 무회귀.
test_bare_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'git commit -m "feat(x): plain"'
  assert_blocked "a bare git commit without stamps must stay gated (core no-regression)"
}

# M7: 샌드박스 커밋은 커밋 메시지 포맷 게이트도 건너뛴다 (rein 포맷 비강제).
test_sandbox_commit_message_format_not_enforced() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd /tmp/rein-sandbox-m && git commit -m "no conventional format here"'
  assert_allowed "sandbox commit must not be subject to the commit-message format gate"
}

# M12 (R2 High 재현): 저장소를 가리키는 symlink 별칭으로의 cd 는 면제 불가 —
#      텍스트로는 밖이지만 물리적으로는 이 저장소다.
test_symlink_alias_of_repo_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  local alias_link="/tmp/rein-alias-$$"
  ln -s "$SANDBOX" "$alias_link"
  _run_cmd "cd $alias_link && git commit -m \"x\""
  rm -f "$alias_link"
  assert_blocked "a symlink alias resolving into the repo must stay gated (realpath containment)"
}

# M13 (R2 High 재현): 산술 문맥의 `<<` 는 비트 시프트 — heredoc 오인으로
#      뒤따르는 실제 커밋이 소거되면 안 된다.
test_arith_shift_does_not_hide_commit() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd '(( x << EOF ))
git commit -m "fix: real"
EOF
:'
  assert_blocked "an arithmetic << must not open a heredoc that absorbs a real commit"
}

# M14 (R2 High 재현): 정상 인용 heredoc 뒤의 인용 상태가 오염되면, 이후 인용
#      문자열 속 <<WORD 가 진짜 표식으로 오인돼 실제 커밋이 소거된다 — 인용
#      종결부호 소비를 검증.
test_quoted_heredoc_then_fake_opener_does_not_hide_commit() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cat <<'\''EOF'\''
mention: git commit -m "text"
EOF
printf "%s\n" '\''<<BAD'\''
git commit -m "fix: real2"'
  assert_blocked "quote state after a quoted heredoc must not corrupt later opener detection"
}

# M15 (R2 지적 반영): 후속 절의 pushd/popd/builtin cd 도 디렉토리 이동 — 면제 불가.
test_pushd_after_outside_cd_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  _run_cmd 'cd /tmp/rein-sandbox-p && pushd /tmp/rein-elsewhere && git commit -m "x"'
  assert_blocked "a pushd after the exempting cd must void the exemption"
}

# M16 (보안 리뷰 2026-08-05 Medium 재현): 이 저장소의 **연결형 워크트리**로의
#      cd 커밋은 면제 불가 — 경로는 밖이지만 커밋은 이 저장소 브랜치에 실린다.
test_linked_worktree_commit_still_gated() {
  seed_dod "dod-2026-08-05-gsd3.md"
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git add -A >/dev/null 2>&1 \
    && git commit -qm base >/dev/null 2>&1 )
  local wt="/tmp/rein-wt-$$"
  ( cd "$SANDBOX" && git worktree add -q "$wt" >/dev/null 2>&1 )
  if [ ! -d "$wt" ]; then
    fail "worktree setup failed (git worktree add)"
    return
  fi
  _run_cmd "cd $wt && git commit -m \"x\""
  ( cd "$SANDBOX" && git worktree remove --force "$wt" >/dev/null 2>&1 )
  rm -rf "$wt"
  assert_blocked "a linked worktree of this repo must stay gated (its commits land in this repo)"
}

# M16b (대조): 독립 저장소(자체 .git 디렉토리)는 여전히 면제 — 워크트리 판별이
#       진짜 샌드박스를 오차단하지 않는다.
test_independent_repo_still_exempt() {
  seed_dod "dod-2026-08-05-gsd3.md"
  local ext="/tmp/rein-extrepo-$$"
  mkdir -p "$ext"
  ( cd "$ext" && git init -q )
  _run_cmd "cd $ext && git commit -m \"x\""
  rm -rf "$ext"
  assert_allowed "an independent repo outside remains exempt (own .git directory)"
}

# M11: 매처 쌍둥이 동등성 — 모델 lib 의 git_clause_invokes(classifier/dispatcher
#      경로)와 인프라 lib 의 command_invokes(게이트 경로)가 같은 배터리에서
#      같은 판정을 내린다 (소거 헬퍼 공유 검증).
test_twin_matcher_equivalence() {
  local libdir="$SANDBOX/.claude/hooks/lib"
  local out
  out=$(bash -c '
    set -u
    libdir="$1"
    . "$libdir/git-subcommand-model.sh" || { echo "SOURCE-FAIL model"; exit 0; }
    . "$libdir/bash-guard-infra.sh" 2>/dev/null || true
    declare -F command_invokes >/dev/null || { echo "SOURCE-FAIL infra"; exit 0; }
    battery=(
      "git commit -m \"x\""
      "echo \"git commit\""
      "grep git commit -m x"
      "git commit-graph write"
      "true; git commit -m x"
      "cd /tmp/sb && git commit -m x"
      "cat > /tmp/r.sh <<EOF
git commit -m \"text\"
EOF"
      "cat > /tmp/r.sh <<EOF
git commit -m \"unterminated\""
    )
    for cmd in "${battery[@]}"; do
      a=1; b=1
      git_clause_invokes "$GIT_COMMIT_ERE" "$cmd" && a=0
      COMMAND="$cmd"
      command_invokes "$GIT_COMMIT_ERE" && b=0
      [ "$a" = "$b" ] || printf "MISMATCH a=%s b=%s cmd=[%s]\n" "$a" "$b" "$cmd"
    done
  ' _ "$libdir" 2>&1)
  [ -z "$out" ] || fail "twin matchers disagree or libs failed to load: $out"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_heredoc_body_git_commit_is_mention "$HOOK"
run_test test_real_commit_with_heredoc_message_still_gated "$HOOK"
run_test test_unterminated_heredoc_fails_closed "$HOOK"
run_test test_literal_outside_cd_commit_exempt "$HOOK"
run_test test_quoted_literal_outside_cd_commit_exempt "$HOOK"
run_test test_variable_cd_commit_still_gated "$HOOK"
run_test test_literal_inside_cd_commit_still_gated "$HOOK"
run_test test_commit_after_subshell_close_still_gated "$HOOK"
run_test test_commit_inside_subshell_not_exempt "$HOOK"
run_test test_bare_commit_still_gated "$HOOK"
run_test test_sandbox_commit_message_format_not_enforced "$HOOK"
run_test test_semicolon_cd_commit_still_gated "$HOOK"
run_test test_or_cd_commit_still_gated "$HOOK"
run_test test_background_amp_cd_commit_still_gated "$HOOK"
run_test test_quoted_separator_cd_commit_still_gated "$HOOK"
run_test test_dash_c_redirect_still_gated "$HOOK"
run_test test_quoted_fake_heredoc_does_not_hide_commit "$HOOK"
run_test test_multiple_heredocs_one_line "$HOOK"
run_test test_symlink_alias_of_repo_still_gated "$HOOK"
run_test test_arith_shift_does_not_hide_commit "$HOOK"
run_test test_quoted_heredoc_then_fake_opener_does_not_hide_commit "$HOOK"
run_test test_pushd_after_outside_cd_still_gated "$HOOK"
run_test test_linked_worktree_commit_still_gated "$HOOK"
run_test test_independent_repo_still_exempt "$HOOK"
run_test test_twin_matcher_equivalence "$HOOK"

summary
