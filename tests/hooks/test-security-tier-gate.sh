#!/bin/bash
# tests/hooks/test-security-tier-gate.sh
#
# RT-1 (docs/specs/2026-05-19-cc-feature-adoption.md §RT-1) — 원래 이
# 스위트는 DoD `## 라우팅 추천` 의 `security_tier`/`approved_by_user`
# 필드가 `.security-reviewed` 표식 요구를 좌우하는지(light+approved →
# 요구 skip) 15케이스로 검증했다.
#
# ============================================================
# Phase 7 웨이브 3 ③-c 갱신 (커밋 게이트 교대, 2026-08-23) — RT-1 명시
# 폐기
# ============================================================
#
# 구동 대상이 `pre-bash-test-commit-gate.sh`(삭제됨)에서
# `pre-bash-commit-review-gate.sh`(신설)로 바뀌었을 뿐 아니라, 이
# 스위트가 검증하던 **메커니즘 자체가 폐기됐다**. 근거:
#
#   - RT-1 경량 등급 면제는 선행 결정 3(2026-08-19, spec §3.6 "경량
#     등급 면제(RT-1)의 이관" 절)으로 **명시 폐기**됐다 — "이관 후 RT-1
#     fact 가 판정을 실제로 바꾸는 입력 클래스가 존재하는지 구현
#     단계에서 열거하고 — 없으면 fact 신설 대신 명시 폐기로 처리한다"는
#     조건에 따라, 6클래스(이 파일의 구 케이스 a~f 가 바로 그 6클래스)
#     전수 열거 결과 판정을 바꾸는 입력이 0건이었다.
#   - 신설 `pre-bash-commit-review-gate.sh` 도, 그 훅이 소비하는
#     `lib/security-review-gate.sh` 도 DoD 의 `security_tier`/
#     `approved_by_user` 필드를 **어디에서도 읽지 않는다**(grep 으로
#     확인 가능 — 두 파일 어디에도 `security_tier` 문자열이 없다).
#
# 그래서 이 스위트는 "면제 성립 케이스가 신 훅에서 통과하는가"를
# 재작성하는 대신, **그 반대를 고정**한다 — 구 스위트의 6개 tier 클래스
# (light+approved / standard / light+not-approved / absent / garbage /
# deep) 전부가, 이제는 서로 구별되지 않고 **동일하게** 판정됨을 실제
# `pre-bash-commit-review-gate.sh` 관통으로 증명한다(죽은 입력 클래스
# 라는 선행 결정 3 의 주장 자체를 이 스위트가 실측 재현·고정한다). 대비
# 케이스로, 신선한 legacy 표식이 있으면 tier 값과 무관하게 동일하게
# 통과함도 고정한다 — "면제가 없어졌다"는 "더 엄격해졌다"는 뜻이지
# "표식이 필요 없다"는 뜻이 아니었다는 것과 구별하기 위함이다.
#
# 대체 근거(코드 리뷰/보안 축의 "판정 입력 정밀화" 자체는 이 파일이
# 검증하지 않는다 — 그건 v2 자신의 계약이며 아래 v2 pytest 스위트가
# 이미 관통 검증한다):
#   plugins/rein-core/tests/unit/test_security_digest_scope.py
#     DigestScopeProfileLoaderTest — profile 선언 로드(strict/sensitive)
#   plugins/rein-core/tests/migration/test_authority_dual_read.py
#     LegacySecurityReviewMarkerTest — subject-empty/unresolved 시
#     legacy 표식이 실제로 판정을 낸다는 것의 단위 계약
#
# 절대 source 하지 않는다 — 항상 실제 훅 프로세스를 실행한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-commit-review-gate.sh"
COMMIT_CMD='git commit -m "feat: thing"'

# ------------------------------------------------------------
# 헬퍼 (tests/hooks/test-pre-bash-commit-review-gate.sh 와 동일 기법의
# 파일-로컬 사본).
# ------------------------------------------------------------

_event_payload() {
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
_write_authority_switched_both() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - code_review\n  - security_review\n' > "$SANDBOX/.rein/policy/authority.yaml"
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

assert_pass() {
  assert_exit 0 "$1: should pass"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no JSON deny, got stdout: $HOOK_STDOUT"
}

assert_denied() {
  local msg="$1"
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "$msg: expected a deny, got exit=$HOOK_EXIT permissionDecision='$decision' stdout=$HOOK_STDOUT"
}

# Phase 7 웨이브 3 ③-d (2026-08-24): _write_code_stamp/_write_security_
# stamp(legacy marker 작성)는 제거됐다 — evaluator.py 의 legacy dual-read
# 대체 계층이 완전히 삭제되어 그 표식들은 더 이상 어떤 판정에도 관여하지
# 않는다. 6개 "여전히 차단" 클래스는 이미 (code/security 어느 쪽이든)
# evidence 가 없으므로 이 헬퍼 제거만으로 그대로 유효하다 — 유일하게
# ALLOW 를 요구하는 test_light_approved_label_with_valid_v2_evidence_
# still_passes_like_any_tier 만 실제 v2 증거 발급으로 재조준한다(아래
# _gitignore_rein_runtime/_issue_v2_evidence 헬퍼 참조).
_gitignore_rein_runtime() {
  cat >> "$SANDBOX/.gitignore" <<'EOF'
/.rein/state/
/.rein/logs/
EOF
}
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

# _dod_content_with_tier — 구 스위트의 동명 헬퍼와 동일한 YAML 모양
# (`## 라우팅 추천` 절 + `## 범위 연결`, select_active_dod 가 Tier 1
# 로 해석하도록).
_dod_content_with_tier() {
  local tier_val="$1"
  local approved="$2"
  if [ "$tier_val" = "absent" ]; then
    cat <<DOD
# DoD: security-tier-gate-test

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
rationale:
  - test fixture
approved_by_user: ${approved}

## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
  else
    cat <<DOD
# DoD: security-tier-gate-test

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: ${tier_val}
rationale:
  - test fixture
approved_by_user: ${approved}

## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
  fi
}

# _seed_real_repo_with_nonallowlisted_change — 실제 git repo + baseline +
# strict digest scope 에서도 허용목록 밖(문서/trail/버전-only 아님)인
# staged 변경. security_review 의 subject 가 확실히 non-empty 가 되도록
# 한다 — subject-empty 라면 legacy dual-read 로 새고, 이 스위트가
# 증명하려는 "tier 값 자체는 이제 무의미하다"는 논지가 subject-empty
# 라는 다른 변수와 섞인다.
_seed_real_repo_with_nonallowlisted_change() {
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  printf 'print("baseline")\n' > "$SANDBOX/src_module.py"
  git -C "$SANDBOX" add src_module.py
  git -C "$SANDBOX" commit -q -m "chore: baseline"
  printf 'print("changed logic")\n' >> "$SANDBOX/src_module.py"
  git -C "$SANDBOX" add src_module.py
}

# _seed_fixture TIER APPROVED — 구 스위트의 동명 헬퍼와 동일한 의도:
# 주어진 tier 값의 DoD + Tier1 .active-dod 마커 + 신선한 code 표식(PASS)
# + security 표식은 없음. 신 훅은 이 tier 값을 전혀 읽지 않으므로 6개
# 클래스 전부가 동일하게 판정돼야 한다.
_seed_fixture() {
  local tier_val="$1"
  local approved="$2"
  local content
  content="$(_dod_content_with_tier "$tier_val" "$approved")"
  seed_dod "dod-2026-08-23-security-tier-test.md" "$content"
  printf 'path=trail/dod/dod-2026-08-23-security-tier-test.md\n' \
    > "$SANDBOX/trail/dod/.active-dod"
  # 의도적으로 evidence 를 아무 축에도 발급하지 않는다(6클래스 전부
  # "여전히 차단"이 기대값이므로 legacy stamp 제거만으로 그대로 유효).
}

# _run_tier_class_expect_block TIER APPROVED LABEL — 6클래스 공통 로직.
_run_tier_class_expect_block() {
  local tier_val="$1" approved="$2" label="$3"
  _seed_real_repo_with_nonallowlisted_change
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_both
  _seed_fixture "$tier_val" "$approved"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_denied "$label: security_tier no longer read at all — must block exactly like any other DoD without a security stamp"
}

# ============================================================
# 6클래스 전수 — 전부 동일하게 BLOCK (선행 결정 3 의 "판정 변경 입력
# 0건" 주장을 실측으로 고정)
# ============================================================

test_class_light_approved_no_longer_exempts() {
  _run_tier_class_expect_block "light" "true" "(class: light+approved)"
}
test_class_standard_still_blocks() {
  _run_tier_class_expect_block "standard" "true" "(class: standard)"
}
test_class_light_not_approved_still_blocks() {
  _run_tier_class_expect_block "light" "false" "(class: light+not-approved)"
}
test_class_absent_field_still_blocks() {
  _run_tier_class_expect_block "absent" "true" "(class: security_tier field absent)"
}
test_class_garbage_value_still_blocks() {
  _run_tier_class_expect_block "INVALID_GARBAGE_VALUE_123" "true" "(class: garbage/malformed value)"
}
test_class_deep_still_blocks() {
  _run_tier_class_expect_block "deep" "true" "(class: deep)"
}

# ============================================================
# 대비 케이스 — tier 무관, 실제 v2 증거가 있으면 통과(엄격해진 것이지
# "기록 자체가 불필요"가 된 것은 아님을 구별).
#
# Phase 7 웨이브 3 ③-d 재조준: legacy stamp 는 더 이상 판정에 관여하지
# 않으므로 ALLOW 는 실제 v2 증거 발급으로만 만들 수 있다. 발급 호출
# 자체도 (fake evidence 발급 시 부산물로) untracked 파일을 만들 수 있어
# _gitignore_rein_runtime 이 필요하고, .claude/.rein/policy 같은 test-infra
# 를 baseline 커밋에 포함시켜야 code_review/security_review digest 가
# src_module.py 변경 하나만을 정확히 가리킨다 — 그래서 여기서는 공용
# _seed_real_repo_with_nonallowlisted_change 대신 직접 순서를 제어한다:
# 변경을 stage 했다가 잠시 unstage 하고 infra 를 baseline 커밋한 뒤 다시
# stage 한다.
test_light_approved_label_with_valid_v2_evidence_still_passes_like_any_tier() {
  _seed_real_repo_with_nonallowlisted_change
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_both
  # 굳이 "light+approved" 라벨을 쓴다 — 구 스위트에서 면제를 성립시키던
  # 바로 그 값이, 이제는 v2 증거 유무 앞에서 다른 어떤 tier 값과도
  # 구별되지 않는다는 것을 보이기 위함.
  _seed_fixture "light" "true"
  _gitignore_rein_runtime
  # src_module.py 의 staged 변경(검증 대상)은 baseline 커밋에서 제외한다
  # — 먼저 unstage 한 뒤 그 파일만 빼고 나머지(test-infra)를 stage+commit,
  # 그 다음 다시 stage 한다. `git checkout --`(destructive) 는 쓰지
  # 않는다 — pre-bash-safety-guard 의 DESTRUCTIVE_GIT_CONFIRM 대상이라
  # 사람 확인 없이는 이 스위트 자체가 막힌다.
  ( cd "$SANDBOX" \
    && git reset HEAD -- src_module.py >/dev/null \
    && git add -A -- ':!src_module.py' \
    && git commit -q -m "test-infra baseline" \
    && git add src_module.py )
  _issue_v2_evidence "code_review" \
    || fail "code_review evidence issuance failed"
  _issue_v2_evidence "security_review" "$SANDBOX/.rein/policy/security-axis" \
    || fail "security_review evidence issuance failed"
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"
  assert_pass "light+approved label + real v2 evidence (both axes) → passes exactly like standard/deep would (label carries no special weight anymore)"
}

# ============================================================
# 정적 확인 — security_tier/approved_by_user 는 신 훅·lib 어디에도 없다.
# ============================================================

test_static_security_tier_field_not_referenced_anywhere() {
  local hits
  hits=$(grep -rn "security_tier" \
    "$REAL_PROJECT_DIR/plugins/rein-core/hooks/pre-bash-commit-review-gate.sh" \
    "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/security-review-gate.sh" \
    "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/code-review-gate.sh" \
    2>/dev/null || true)
  [ -z "$hits" ] || fail "security_tier must not be referenced anywhere in the new review-gate hook or its axis libs (RT-1 dead field): $hits"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_class_light_approved_no_longer_exempts "$HOOK"
run_test test_class_standard_still_blocks "$HOOK"
run_test test_class_light_not_approved_still_blocks "$HOOK"
run_test test_class_absent_field_still_blocks "$HOOK"
run_test test_class_garbage_value_still_blocks "$HOOK"
run_test test_class_deep_still_blocks "$HOOK"
run_test test_light_approved_label_with_valid_v2_evidence_still_passes_like_any_tier "$HOOK"
run_test test_static_security_tier_field_not_referenced_anywhere "$HOOK"

summary
