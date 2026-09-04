#!/bin/bash
# tests/hooks/test-security-review-authority-switch.sh
#
# v2 Phase 6 Task 6.1 본작업 — security_review 축 판정 권한을 v1 에서 v2
# (`rein.engine.authority` + `bin/rein hook`)로 전환하는 배선을 행위 기반으로
# 검증한다. 코드 리뷰 축(tests/hooks/test-code-review-authority-switch.sh)과
# 정확히 같은 아키텍처 — "직접 위임"(사용자 결정 2026-08-18) — 를 따른다.
# 이 파일의 헤더는 그 파일과의 **차이점**만 설명한다; 아키텍처 배경 전체는
# 그 파일의 헤더 주석을 참조.
#
# ============================================================
# 코드 리뷰 축과의 차이 — 두 가지
# ============================================================
#
# 1. REIN_POLICY_DIR 주입. 코드 리뷰 축은 REIN_POLICY_DIR 을 주입하지
#    않는다 — 번들 기본 정책(policies/default/commit.yaml)이 이미
#    code_review 를 요구하므로 그대로 자립한다. security_review 는 번들
#    기본 정책에 요구 조항이 없다(2026-08-18 조사 D6) — 그래서 이 축의
#    위임(hooks/lib/security-review-gate.sh 의
#    rein_security_review_delegate())은 REIN_POLICY_DIR 을 추가로
#    `$PROJECT_DIR/.rein/policy/security-axis` 로 주입한다. 이 스위트는
#    그 폴더를 실제 저장소에서 그대로 복사해 샌드박스에 심는다
#    (_link_security_axis_policy) — 코드 리뷰 축에는 대응 헬퍼가 없다.
#
# 2. 면제 2종이 위임보다 선행한다. security_review 축은 v1 시절부터 두
#    가지 면제 경로(RT-1 경량 등급 + 보안-surface, 원본 pre-bash-test-
#    commit-gate.sh 의 _sx_* 함수 + tier-skip 블록, 이제
#    hooks/lib/security-review-gate.sh 로 이동)를 갖고 있었다 — 코드
#    리뷰 축에는 대응 개념이 없다. v2 legacy dual-read
#    (`_legacy_security_review_status`)는 이 두 면제를 전혀 모른다
#    (2026-08-18 조사 D2/D3) — 그래서 면제 판정은 전환 확인/위임보다
#    **먼저** 계산되고, 면제가 성립하면 위임 자체를 시도하지 않는다
#    (부모 확정 설계). 시나리오 (c)/(d)가 이 순서를 검증하고, 시나리오
#    (g)는 이 축 전용 정책 폴더 설계가 왜 필요한지(교차 오염 방지)를
#    직접 증명한다.
#
# "진짜 위임이 일어났는가" 를 증명하는 방법(v2 state db 부수 효과 관측)은
# 코드 리뷰 축의 스위트와 완전히 동일하다 — 그 파일의 "진짜 위임이
# 일어났는가" 절 참조.
#
# ============================================================
# Phase 7 웨이브 3 ③-c 갱신 (커밋 게이트 교대, 2026-08-23)
# ============================================================
#
# 구동 대상이 `pre-bash-test-commit-gate.sh`(삭제됨)에서
# `pre-bash-commit-review-gate.sh`(신설)로 바뀌었다. code_review 축의
# ③-c 갱신(tests/hooks/test-code-review-authority-switch.sh 헤더)과
# 동일한 원리 위에, 이 축 고유의 두 가지가 추가로 무효화됐다 —
#
#   1. **v1 폴백 소멸**: (e)/(f)/(j) 는 구 훅의 v1 M2 직접 판정으로
#      귀결됐었다. 신 훅은 그 폴백이 없다 — NOT_SWITCHED 는 축 skip(통과),
#      FAIL(위임 실행 실패·정책 파일 부재)은 훅 자신의 fail-closed exit 2
#      다(JSON deny 형식이 아니다).
#   2. **v1 면제 2종(RT-1 경량 등급 + 보안-surface) 소멸**: 구 훅은 이
#      면제가 성립하면 위임 **자체를 시도하지 않았다**(state db 부재로
#      증명). 신 훅은 이 면제를 전혀 계산하지 않는다(hooks/pre-bash-
#      commit-review-gate.sh 헤더 "의도된 방향 변화 (b)" 참조) — 위임은
#      **항상 시도된다**. 그 결과 (c)/(d)/(g)/(h) 는 전면 재설계됐다:
#      - (c) 문서-only 변경은 이제 subject-empty 로 v2 native 위임까지
#        진행되고, spec §3.6 판정 상태표(전환기 열)에 따라 **legacy
#        표식으로 위임**된다 — 표식이 전혀 없으면 이제도 BLOCK(구와
#        정반대), 신선한 legacy 표식(코드+보안 둘 다)이 있으면 그 legacy
#        경로로 PASS(v1 이 지켜온 엄격도가 약해지지 않았다는 것의 증거).
#        2026-08-23 scratchpad 실측(REIN_POLICY_DIR 를 태운 `bin/rein
#        hook` 직접 호출)으로 확인 — 상세 근거는 tests/hooks/test-pre-
#        bash-commit-review-gate.sh 의 "10. v2 네이티브 판정 실증" 절.
#      - (d) RT-1 경량 등급 면제는 명시 폐기됐다(선행 결정 3 — 6클래스
#        전수 열거로 판정 변경 입력 0건, tests/hooks/test-security-tier-
#        gate.sh 갱신 헤더 참조). DoD 의 `security_tier`/`approved_by_user`
#        필드는 이제 이 훅 어디에서도 읽히지 않는다 — light-tier DoD
#        여도 표식이 없으면 다른 어떤 DoD 와도 동일하게 BLOCK 된다.
#      - (g)/(h) 는 "위임이 시도조차 안 됨"을 전제로 한 시나리오였는데,
#        이제 위임은 항상 시도되므로 state db 존재/부재 단언이 뒤집히는
#        경우가 있다 — 각 테스트 자신의 갱신 주석 참조.
#
# ============================================================
# 시나리오 (a)~(i)
# ============================================================
#   (a) 전환 on + 미면제 + 양 표식 신선 → 통과 (위임 경유 — legacy 겸용 읽기)
#   (b) 전환 on + 미면제 + 보안 표식 없음 → 차단 (위임 relay, 로그 1건)
#   (c) 전환 on + 문서만 변경(보안-surface 면제) → 위임 없이 통과
#   (d) 전환 on + 경량 등급 면제(RT-1) → 위임 없이 통과
#   (e) 전환 off → v1 M2 종전 판정
#   (f) 위임 실패(엔진 스크립트 손상) → v1 M2 판정 (fail-closed)
#   (g) 교차 오염 방지(핵심) — 문서만 변경 + 보안 표식 없음 + 코드 표식
#       신선 + 코드/보안 축 둘 다 전환 → 코드 축 위임(번들 기본 정책,
#       security_review 무요구)이 보안 요구로 차단하지 않는다
#   (h) 활성 DoD 없음 → 아무 축도 안 물음 (v1 의미 보존)
#   (i) 축 전용 정책 폴더 손상(스키마 위반 주입) → 실측 확인된 실제 동작:
#       bin/rein hook 은 내부에서 PolicyLoadError 를 캐치해 그 자체를
#       fail-closed BLOCK(=DENY 형태) 으로 번역한다(rein/cli/__init__.py
#       ::_run_hook() 의 광범위 예외 처리기, 2026-08-18 실측) — 즉 정책
#       폴더 손상은 이 함수의 ALLOW/DENY/FAIL 3분류에서 FAIL 이 아니라
#       DENY 로 분류된다(엔진 자체가 죽는 시나리오 (f)와는 다른 경로).
#       이 테스트는 그 실측 동작(여전히 fail-closed — 차단은 유지된다)을
#       고정한다. 아래 (i) 테스트 함수 주석 참조.
#
# 전부 실제 실행(source 금지). 표식 상태·로그 건수·state db 존재까지
# 단언한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-commit-review-gate.sh"
COMMIT_CMD='git commit -m "feat: thing"'

# _event_payload CMD CWD — 코드 리뷰 축 스위트와 동일 (파일별 독립 사본).
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

# ------------------------------------------------------------
# Sandbox prep helpers (test-file-local — not added to the shared harness).
# ------------------------------------------------------------

# _link_rein_package / _link_rein_bin — 코드 리뷰 축 스위트와 동일한 self-
# location 원리(hooks/lib/security-review-gate.sh → ../.. = $SANDBOX/.claude
# — 코드 축의 code-review-gate.sh 와 정확히 같은 상대 위치이므로 같은
# 심볼릭 링크가 양쪽 축 모두를 만족시킨다).
_link_rein_package() {
  mkdir -p "$SANDBOX/.claude"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/rein" "$SANDBOX/.claude/rein"
}
_link_rein_bin() {
  mkdir -p "$SANDBOX/.claude/bin"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/bin/rein" "$SANDBOX/.claude/bin/rein"
}

# _link_security_axis_policy
#   rein_security_review_delegate() 가 주입하는 REIN_POLICY_DIR
#   ($SANDBOX/.rein/policy/security-axis) 을 실제 저장소의 축 전용 정책
#   폴더로 채운다(복사 — 심볼릭 링크가 아니다: 시나리오 (i)가 이 사본만
#   손상시키고 실제 저장소 파일은 절대 건드리지 않아야 하므로).
_link_security_axis_policy() {
  mkdir -p "$SANDBOX/.rein/policy"
  rm -rf "$SANDBOX/.rein/policy/security-axis"
  cp -R "$REAL_PROJECT_DIR/tests/fixtures/policy/security-axis" "$SANDBOX/.rein/policy/security-axis"
}

# _link_bundled_security_axis_policy — places the axis policy at the
# *bundled* location a real plugin install ships it to (plugin-root/
# policies/security-axis), NOT at the per-project override (.rein/policy/
# security-axis). Same self-location math as _link_rein_package/_link_rein_
# bin above: this hook's plugin root inside the sandbox is $SANDBOX/.claude.
# "policy folder absent = declared opt-out regardless of switched state" is
# no longer the contract; the pre-check now resolves project override →
# bundled default before the switched-check ever runs, so a scenario that
# wants "a genuine, undamaged install with no project override" (as opposed
# to "install itself is damaged") must link this.
_link_bundled_security_axis_policy() {
  mkdir -p "$SANDBOX/.claude/policies"
  rm -rf "$SANDBOX/.claude/policies/security-axis"
  cp -R "$REAL_PROJECT_DIR/tests/fixtures/policy/security-axis" "$SANDBOX/.claude/policies/security-axis"
}

# _write_broken_security_axis_policy
#   시나리오 (i) — 축 전용 정책 폴더의 commit-security.yaml 에 폐쇄
#   스키마 밖 필드(bogus_field)를 주입한다. 2026-08-18 실측(scratchpad):
#   이 손상은 `bin/rein hook` 내부에서 PolicyLoadError → 광범위 예외
#   처리기 → rc 0 + native BLOCK(deny 형태) JSON 으로 귀결된다(엔진
#   자체가 죽지 않는다 — 시나리오 (f)의 "엔진 스크립트 손상"과는 다른
#   실패 모드).
_write_broken_security_axis_policy() {
  mkdir -p "$SANDBOX/.rein/policy/security-axis"
  printf 'version: 1\n' > "$SANDBOX/.rein/policy/security-axis/_version.yaml"
  cat > "$SANDBOX/.rein/policy/security-axis/commit-security.yaml" <<'EOF'
trigger: tool.pre
when:
  command.type: git.commit
require:
  - security_review
failure_mode: closed
bogus_field: oops
EOF
}

# _write_broken_engine_script — 코드 리뷰 축 스위트와 동일한 기법(시나리오
# (f) "위임 실패(엔진 스크립트 손상)" 재현). 심볼릭 링크가 아니라 샌드박스
# 소유의 실제 파일 — 실제 저장소 파일을 건드리지 않는다.
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

# _write_authority_switched_on — security_review 축 하나만 전환. code_review
# 는 이 파일의 대다수 테스트에서 의도적으로 미전환 상태로 남긴다 — v1 이
# code_review 를 자기 P3~P5b 로 직접 판정하게 해, 이 스위트가 검증하려는
# security_review 축 하나만 변수로 남긴다(코드 리뷰 축 스위트가 반대
# 방향으로 같은 격리를 하는 것과 대칭).
_write_authority_switched_on() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - security_review\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
_write_authority_switched_off() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched: none\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
# _write_authority_switched_both — 시나리오 (g) 전용. code_review 와
# security_review 둘 다 전환해, 코드 축의 위임이 (번들 기본 정책만 보는데도)
# 보안 요구로 오염되지 않는지를 직접 검증한다.
_write_authority_switched_both() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - code_review\n  - security_review\n' > "$SANDBOX/.rein/policy/authority.yaml"
}

# Phase 7 웨이브 3 ③-d (2026-08-24): _write_code_stamp/_write_security_
# stamp(legacy marker 작성)는 제거됐다 — evaluator.py 의 legacy dual-read
# 대체 계층이 완전히 삭제되어 그 표식들은 더 이상 어떤 판정에도 관여하지
# 않는다. ALLOW 는 이제 실제 v2 증거 발급으로만 만들 수 있다 — 아래
# _seed_real_repo + _gitignore_rein_runtime + _issue_v2_evidence 가 그
# 대체 경로다 (tests/hooks/test-code-review-authority-switch.sh 의 동명
# 헬퍼와 동일).

_seed_real_repo() {
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  printf '# baseline\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  git -C "$SANDBOX" commit -q -m "chore: baseline"
}

# 실측(2026-08-24): 실제 rein 프로젝트는 `/.rein/state/`·`/.rein/logs/`
# 를 gitignore 한다 — 그래야 `bin/rein` 자신의 런타임 부수 효과(sqlite3
# state db, block 로그)가 매 호출마다 changeset digest 를 오염시키지
# 않는다. 반드시 baseline 커밋 이전에 호출한다.
_gitignore_rein_runtime() {
  cat >> "$SANDBOX/.gitignore" <<'EOF'
/.rein/state/
/.rein/logs/
EOF
}

# _issue_v2_evidence CAPABILITY [POLICY_DIR]
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

# _sx_git_docs_only_change — 시나리오 (c)/(g) 전용. 실제 git repo + baseline
# 커밋 + CHANGELOG.md 의 docs-only staged 변경. tests/hooks/test-pre-bash-
# test-commit-gate.sh 의 _sx_git_init_baseline 을 이 스위트 필요분만 축약한
# 사본(그 파일과 공유하지 않는다 — 각 테스트 파일이 자기 sandbox-prep 을
# 갖는 기존 관례).
_sx_git_docs_only_change() {
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  printf '# changelog\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  git -C "$SANDBOX" commit -q -m "baseline"
  printf '# changed\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
}

# _seed_light_tier_dod — 시나리오 (d) 전용. RT-1 경량 등급 면제가 성립하는
# DoD(## 라우팅 추천 에 security_tier: light + approved_by_user: true) +
# Tier 1 .active-dod 마커. tests/hooks/test-pre-bash-test-commit-gate.sh 의
# test_sx_light_tier_with_source_still_passes 와 동일한 내용 패턴.
_seed_light_tier_dod() {
  local content
  content=$(cat <<'DOD'
# DoD light
## 라우팅 추천
agent: rein:feature-builder
mcps: []
security_tier: light
approved_by_user: true
## 범위 연결
plan ref: docs/plans/test.md
covers: [test-id]
DOD
)
  seed_dod "dod-2026-08-18-srg-switch.md" "$content"
  printf 'path=trail/dod/dod-2026-08-18-srg-switch.md\n' > "$SANDBOX/trail/dod/.active-dod"
}

_blocks_log_count() {
  local f="$SANDBOX/trail/incidents/blocks.jsonl"
  [ -f "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0
}

# _v2_state_db_exists — 코드 리뷰 축 스위트와 동일한 부수효과 증거
# (rein/cli/__init__.py::_resolve_db_path() 가 평가 전에 항상 선생성).
_v2_state_db_exists() {
  [ -f "$SANDBOX/.rein/state/runtime.sqlite3" ]
}

# ------------------------------------------------------------
# v1-stdout assertions (코드 리뷰 축 스위트와 동일한 형태 — 파일별 독립 사본)
# ------------------------------------------------------------

assert_v1_silent() {
  assert_exit 0 "$1: exit code"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no denial, got stdout: $HOOK_STDOUT"
}

assert_v1_deny_reason_code() {
  assert_exit 0 "$2: exit code (JSON deny path exits 0)"
  case "$HOOK_STDOUT" in
    *"$1"*) ;;
    *) fail "$2: reason-code '$1' not found in stdout: $HOOK_STDOUT" ;;
  esac
}

assert_v1_deny_reason_code_absent() {
  case "$HOOK_STDOUT" in
    *"$1"*) fail "$2: v1 stdout unexpectedly contains '$1' (that axis should not have been judged directly by v1): $HOOK_STDOUT" ;;
    *) ;;
  esac
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

assert_fail_closed_exit2() {
  # ③-c: v1 폴백이 없는 경로(위임 FAIL·정책 파일 부재)의 공통 형태 —
  # 평문 stderr + exit 2, stdout 은 비어 있어야 한다.
  local msg="$1"
  assert_exit 2 "$msg"
  [ -z "$HOOK_STDOUT" ] || fail "$msg: fail-closed exit 2 must not also emit stdout: $HOOK_STDOUT"
}

assert_v1_relayed_v2_deny() {
  # $1=message. v1 이 v2 의 native deny JSON 을 "그대로" relay 했는지 —
  # v1 의 deny_emit 이 항상 붙이는 "[reason-code: ...]" 접미어가 없다(v2
  # 는 그 템플릿을 전혀 모른다).
  #
  # Phase 7 웨이브 3 ③-d 갱신: 예전에는 reason 문자열에 requirement 이름
  # ('security_review') 도 요구했다 — 그 이름은 evaluator.py 의 legacy
  # dual-read authority_note 산물이었다(v2 evidence 부재 시 항상 부착).
  # ③-d 로 그 note 부착 조건이 좁혀지면서 통상 DENY 는 이제 generic
  # `REASON_MISSING_EVIDENCE`("required evidence is missing")만 낸다 —
  # requirement 이름 확인은 더 이상 이 함수의 몫이 아니다.
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "$1: HOOK_STDOUT is not a PreToolUse deny envelope (permissionDecision='$decision'): $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"security_review"*) ;;
    *"required evidence is missing"*) ;;
    *) fail "$1: reason is neither v2's own substring 'security_review' nor the generic missing-evidence reason — this does not look like v2's real decision: $HOOK_STDOUT" ;;
  esac
  case "$HOOK_STDOUT" in
    *"[reason-code:"*) fail "$1: reason contains v1's own deny_emit '[reason-code:' marker — v1 must relay v2's JSON verbatim, not reconstruct it: $HOOK_STDOUT" ;;
    *) ;;
  esac
}

# ============================================================
# (a) 전환 on + 미면제 + 양 표식 신선 → 통과 (위임 경유 — legacy 겸용 읽기)
# ============================================================

test_a_switch_on_valid_v2_evidence_allows() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_on
  seed_dod "dod-2026-08-18-srg-switch.md"
  _gitignore_rein_runtime
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  mkdir -p "$SANDBOX/scripts"
  printf 'echo real change under review\n' > "$SANDBOX/scripts/reviewed-change.sh"
  git -C "$SANDBOX" add scripts/reviewed-change.sh
  _issue_v2_evidence "security_review" "$SANDBOX/.rein/policy/security-axis" \
    || fail "(a) security_review evidence issuance failed"

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(a) real security_review evidence + switch on → v1 fully silent (v2 delegate ALLOW; code_review not switched, opts out)"
  _v2_state_db_exists || fail "(a) expected v2 state db to exist — proves the security_review axis was genuinely delegated to bin/rein hook, not merely coincidentally passed by a v1 fallback"
}

# ============================================================
# (b) 전환 on + 미면제 + 실 v2 증거 전무 → 차단 (위임 relay, 로그 1건)
# ============================================================

test_b_switch_on_no_v2_evidence_blocks() {
  seed_dod "dod-2026-08-18-srg-switch.md"
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_on

  local before_count
  before_count=$(_blocks_log_count)

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_relayed_v2_deny "(b) v1 stdout is v2's own deny JSON, relayed verbatim"

  local after_count
  after_count=$(_blocks_log_count)
  [ "$after_count" -eq "$((before_count + 1))" ] || fail "(b) expected exactly 1 new block-log entry (no duplicate), got $((after_count - before_count))"
  assert_file_contains "trail/incidents/blocks.jsonl" "보안 리뷰 위임 차단"

  _v2_state_db_exists || fail "(b) expected v2 state db to exist — proves bin/rein hook actually ran and produced this decision"
}

# ============================================================
# (c) 전환 on + 문서만 변경(보안-surface 면제) → 위임 없이 통과 — 위임
#     부수효과 부재로 단언(면제가 위임보다 선행한다는 설계의 직접 증거)
# ============================================================

# Phase 7 웨이브 3 ③-d (2026-08-24) 전면 재조준. ③-c 시점(위 원 주석)에는
# evaluator.py 가 legacy dual-read 를 갖고 있어 "subject-empty 도 legacy
# 표식 존재를 요구한다"는 전환기 동작을 고정했다. ③-d 로 그 대체 계층이
# 완전히 제거되면서, subject-empty(문서-only 변경, 검토할 민감 대상
# 자체가 없음)는 **legacy 표식 존재 여부와 무관하게 항상 충족**이다 —
# 원 (c1)("표식 없으면 문서-only 도 차단")과 (c2)("신선한 legacy 표식이
# 있으면 통과") 는 이제 같은 결과(ALLOW)로 수렴하므로 **정당 소멸 +
# 통합**: 아래 test_c_docs_only_allows_via_subject_empty_no_evidence_
# needed 하나로 "표식/증거 유무와 무관하게 문서-only 는 통과한다"는
# 종국 계약을 고정한다.
test_c_docs_only_allows_via_subject_empty_no_evidence_needed() {
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_on
  seed_dod "dod-2026-08-18-srg-switch.md"
  _gitignore_rein_runtime
  # git init + 모든 test-infra 를 baseline 커밋으로 먼저 확정한 뒤에만
  # 문서-only 변경을 stage 한다 — tests/hooks/test-pre-bash-commit-
  # review-gate.sh 디버깅에서 발견된 self-pollution 함정(구 _sx_git_docs_
  # only_change 순서 그대로 쓰면 위 링크/설정 파일들이 untracked 채로
  # 남아 code_review/security_review digest 를 오염시킨다) 회피.
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  printf '# changelog\n' > "$SANDBOX/CHANGELOG.md"
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  printf '# changed\n' >> "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md

  local payload
  payload=$(_event_payload 'git commit -m "docs: update changelog"' "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(c) docs-only commit with no evidence anywhere still passes (subject-empty is unconditionally satisfied post-③-d)"
  _v2_state_db_exists || fail "(c) expected genuine delegation (subject-empty is a v2 verdict, not a skip)"
}

# ============================================================
# (d) 전환 on + 경량 등급 면제(RT-1) → 위임 없이 통과
# ============================================================

# ③-c 재설계 (원래 (d)) — RT-1 경량 등급 면제는 명시 폐기됐다(선행 결정
# 3, 파일 헤더 참조). 이 DoD 의 `security_tier: light`/`approved_by_user:
# true` 필드는 이제 이 훅 어디에서도 읽히지 않는다 — light-tier 라벨이
# 붙어 있어도 표식이 없으면 다른 어떤 DoD 와 동일하게 BLOCK 된다(죽은
# 입력 클래스임을 고정).
test_d_light_tier_label_no_longer_special_cased() {
  _seed_light_tier_dod
  # no security stamp
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "(d) a light-tier+approved DoD must no longer be special-cased — this commit should BLOCK exactly like a standard-tier DoD would, got exit=$HOOK_EXIT stdout=$HOOK_STDOUT"
  _v2_state_db_exists || fail "(d) expected genuine delegation — RT-1 no longer short-circuits before delegate"
}

# ============================================================
# (e) 전환 off → v1 이 종전대로 M2 판정 (기존 메시지·로그)
# ============================================================

test_e_switch_off_axis_skipped_passes() {
  seed_dod "dod-2026-08-18-srg-switch.md"
  # no security stamp
  _link_rein_package
  # 정책 위치 사전 점검(project override → 배포 번들)은 전환 여부와
  # 무관하게 먼저 실행되므로, 번들을 심어 둔다 — 그렇지 않으면 이
  # sandbox 는 "정책이 어디에도 없는 손상된 install" 로 보여 이 테스트가
  # 확인하려는 NOT_SWITCHED 분기가 아니라 엉뚱한 사유(damaged-install)로
  # 차단된다.
  _link_bundled_security_axis_policy
  _write_authority_switched_off

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # ③-c: NOT_SWITCHED → 축 skip(opt-out) → 통과. code_review 도 이
  # 파일의 `_write_authority_switched_off` 로 미전환이라 함께 skip.
  assert_v1_silent "(e) security_review NOT_SWITCHED → axis skip, overall pass (no v1 fallback judgment)"
  if _v2_state_db_exists; then
    fail "(e) v2 state db should NOT exist — delegation must never be attempted when the switch is off"
  fi
}

# ============================================================
# (f) 위임 실패(엔진 스크립트 손상) → v1 이 직접 판정 (fail-closed)
# ============================================================

test_f_delegate_exec_failure_fails_closed() {
  seed_dod "dod-2026-08-18-srg-switch.md"
  _link_rein_package
  _write_broken_engine_script
  _link_security_axis_policy
  _write_authority_switched_on
  # no security stamp — irrelevant now, FAIL fails closed regardless.

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # ③-c: 위임 FAIL → 훅 자신이 fail-closed exit 2 (v1 폴백 없음).
  assert_fail_closed_exit2 "(f) delegate exec failure must fail closed, no v1 fallback judgment"
  assert_stderr_contains "there is no v1 fallback judgment for this axis anymore"
  if _v2_state_db_exists; then
    fail "(f) v2 state db should NOT exist — the broken engine script exits before ever reaching rein.cli / opening state"
  fi
}

# ============================================================
# (g) 교차 오염 방지(핵심) — 문서만 변경 + 보안 표식 없음 + 코드 표식
#     신선 + 코드/보안 축 둘 다 전환 → 코드 축 위임(번들 기본 정책, security_
#     review 무요구)이 보안 요구로 차단하지 않는다. 이것이 축 전용 정책
#     폴더 설계(REIN_POLICY_DIR 을 security_review 축의 위임 호출에만
#     주입하고 code_review 축의 위임 호출에는 주입하지 않는 것)의 존재
#     이유다 — 만약 두 축의 위임이 실수로 같은(혹은 병합된) 정책을 본다면,
#     보안 표식이 없는 이 커밋에서 코드 축의 위임 응답까지 security_review
#     요구로 오염되어 차단됐을 것이다(위임 응답에는 축 귀속 정보가 없다,
#     2026-08-18 조사 C.2).
#
# 이 시나리오에서는 보안-surface 면제(docs-only)가 먼저 성립해 security_
# review 축 자신은 위임을 아예 시도하지 않는다 — 그래서 이 테스트가 실제로
# 관측하는 유일한 위임은 code_review 축의 것이다. code_review 축이 번들
# 기본 정책(code_review 만 요구)으로 올바르게 격리되어 있다면, 보안 표식이
# 전혀 없어도 이 커밋은 (코드 표식이 신선하므로) 조용히 통과해야 한다.
# ============================================================

# Phase 7 웨이브 3 ③-d 전면 재조준. ③-c 시점의 전제("문서-only 변경은
# security_review 도 subject-empty→legacy 경로로 실제 위임되지만 legacy
# 표식이 없어 DENY 한다")는 legacy dual-read 제거로 무효화됐다 —
# subject-empty 는 이제 legacy 표식과 무관하게 항상 충족이므로, 문서-only
# 변경으로는 이 시나리오가 원래 증명하려던 "교차 오염 방지" 자체를
# 재현할 수 없다(양 축 모두 subject-empty 로 조용히 ALLOW 해버려서 검증할
# 대상이 사라진다). 그래서 이 테스트를 **실제 소스 변경**(allowlist 밖)
# 으로 재조준한다.
#
# 추가로, DENY reason 문자열이 이제 requirement 이름을 담지 않으므로(양
# 축 모두 generic `REASON_MISSING_EVIDENCE`, assert_v1_relayed_v2_deny 의
# ③-d 주석 참조) "reason 에 security_review 는 있고 code_review 는
# 없다"는 텍스트 판별이 더 이상 성립하지 않는다. 이 스위트는 그 대신
# **정적 증거 + 행위 차등 비교**를 조합한다: (1) code_review 축의 위임
# 함수(hooks/lib/code-review-gate.sh)가 REIN_POLICY_DIR 을 아예 참조하지
# 않는다는 것을 소스에서 직접 확인한다(그 변수를 참조하지 않으면
# security 축 전용 정책 폴더를 구조적으로 볼 수가 없다 — 오염 경로
# 자체가 없다는 강한 증거). (2) code_review 증거만 발급한 상태에서는
# 여전히 DENY(보안 축이 독립적으로 요구된다는 증거) → security_review
# 증거까지 마저 발급하면 ALLOW 로 뒤집힌다(두 축 모두 만족돼야 함을
# 확인 — 사용자 결정, differential proof 는 test-code-review-authority-
# switch.sh 의 시나리오 (e) 와 동일 기법).
test_g_cross_axis_isolation_docs_only_no_security_stamp() {
  local delegate_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/code-review-gate.sh"
  if grep -q "REIN_POLICY_DIR" "$delegate_src"; then
    fail "(g) code-review-gate.sh now references REIN_POLICY_DIR — its delegate call could leak the security-axis-only policy folder, reopening the cross-axis contamination this test guards against"
  fi

  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_both
  seed_dod "dod-2026-08-18-srg-switch.md"
  _gitignore_rein_runtime
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  mkdir -p "$SANDBOX/scripts"
  printf 'echo real change under review\n' > "$SANDBOX/scripts/reviewed-change.sh"
  git -C "$SANDBOX" add scripts/reviewed-change.sh
  _issue_v2_evidence "code_review" \
    || fail "(g) code_review evidence issuance failed"
  # no security_review evidence yet

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "(g) step 1: code_review evidence alone should NOT be enough — security_review is independently required (permissionDecision='$decision'): $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"code_review"*) fail "(g) code_review delegate (bundled default policy, code_review-only) must not be contaminated by the security-axis-only policy — the deny reason must not mention code_review at all: $HOOK_STDOUT" ;;
    *) ;;
  esac
  _v2_state_db_exists || fail "(g) expected v2 state db to exist — the code_review axis's own delegation genuinely ran (bundled default policy, no REIN_POLICY_DIR injected for that axis) before the security axis denied"

  # Step 2: also issue security_review evidence for the SAME staged change
  # → both axes now satisfied, overall decision must flip to ALLOW. This
  # proves security_review's requirement was genuinely independent (not a
  # side effect of code_review's own delegate being contaminated into
  # requiring it too, which the step-1 grep-absence check above already
  # rules out structurally).
  _issue_v2_evidence "security_review" "$SANDBOX/.rein/policy/security-axis" \
    || fail "(g) security_review evidence issuance failed"
  run_hook "$HOOK" "$payload"
  assert_v1_silent "(g) step 2: once security_review evidence is ALSO issued, the same event now passes — code_review's own bundled-policy ALLOW was never blocked by anything, only the separate security axis was"
}

# ============================================================
# (h) 활성 DoD 없음 → 아무 축도 안 물음 (v1 의미 보존)
# ============================================================

# ③-c 방향 전환 (파일 헤더 참조) — 이 훅에는 DOD_EXISTS 선행조건이 없다.
# code_review 는 이제 task.exists 조건화로 v2 정책 자체가 미매칭돼
# ALLOW(genuine 위임) 한다. security_review 도(security-axis bundling
# hotfix 이후) 동형이다 — 배포 번들 정책이 실재하고 위임도 실제로
# 일어나지만, 그 정책도 code_review 의 번들 기본 정책과 마찬가지로
# task.exists 조건을 갖고 있어(활성 작업이 없으면 정직하게 발급할 리뷰
# 증거 자체가 없다) 미매칭돼 ALLOW 로 귀결된다 — "정책이 아예 없어서
# 축이 사라짐" 이 아니라 "정책은 있지만 조건부로 미요구" 다. 두 축
# 모두 실제로 위임되지만(state db 존재) 어느 쪽도 이 이벤트에 요구를
# 발동하지 않는다는 것이 이 시나리오의 핵심이다.
test_h_no_active_dod_allows_code_review_delegates_security_skips() {
  _link_rein_package
  _link_rein_bin
  # project override 는 만들지 않고 배포 번들만 심는다 — 오버라이드
  # 없는 프로젝트의 실제 형태(security-axis bundling hotfix 재현).
  _link_bundled_security_axis_policy
  _write_authority_switched_both

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(h) no active DoD → passes; code_review's own delegation genuinely runs and its policy simply does not match"
  _v2_state_db_exists || fail "(h) expected v2 state db to EXIST — code_review's switch-check+delegate is now unconditional (the intentional direction change from the old single hook)"
  local count
  count=$(_blocks_log_count)
  [ "$count" -eq 0 ] || fail "(h) expected 0 block-log entries, got $count"
}

# ============================================================
# (i) 축 전용 정책 폴더 손상(스키마 위반 주입) — 실측된 실제 동작을 고정.
#
# 2026-08-18 조사(scratchpad 실측, 이 DoD 작성 근거): 손상된 REIN_POLICY_DIR
# 으로 `bin/rein hook` 을 직접 호출하면 rc=0 + `hookSpecificOutput.
# permissionDecision == "deny"` 형태의 JSON 이 나온다 — `rein/cli/
# __init__.py::_run_hook()` 이 `run_hook_event()` 호출을 광범위
# `except Exception` 으로 감싸고 있어서, 정책 로더가 던지는
# `PolicyLoadError`(스키마 위반 필드)가 엔진 크래시가 아니라 엔진 자신의
# fail-closed BLOCK 판정으로 흡수되기 때문이다. 그 결과
# rein_security_review_delegate() 의 3분류(ALLOW/DENY/FAIL) 에서 이 경우는
# **DENY** 로 분류된다 — bin/rein 바이너리 자체가 죽거나 응답하지 못하는
# 시나리오 (f)의 FAIL 과는 다른 경로다. 두 경로 모두 fail-closed(차단)
# 라는 안전 속성은 동일하게 유지된다 — 이 테스트는 그 안전 속성(차단
# 유지, silent-allow 없음)과 함께 실제 관측된 분류(DENY-relay)를 그대로
# 고정한다.
# ============================================================

test_i_axis_policy_corrupted_fails_closed_via_v2_deny() {
  seed_dod "dod-2026-08-18-srg-switch.md"
  # no security stamp
  _link_rein_package
  _link_rein_bin
  _write_broken_security_axis_policy
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # Fail-closed core assertion: the corrupted axis-only policy folder must
  # NEVER result in a silent ALLOW. Whatever the exact classification, the
  # commit must be blocked.
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "(i) corrupted security-axis policy folder must fail closed (block), got permissionDecision='$decision', stdout: $HOOK_STDOUT"
  assert_exit 0 "(i) JSON deny path exits 0"

  # v2 genuinely ran (as opposed to scenario (f) where the engine crashes
  # before ever reaching rein.cli) — this is what distinguishes "policy
  # corrupted" from "engine broken" as failure modes.
  _v2_state_db_exists || fail "(i) expected v2 state db to exist — bin/rein hook ran far enough to attempt loading the corrupted policy (unlike scenario (f)'s broken-engine-script, which crashes before opening state)"

  local after_count
  after_count=$(_blocks_log_count)
  [ "$after_count" -ge 1 ] || fail "(i) expected at least 1 block-log entry, got $after_count"
}

# ============================================================
# (j) 축 정책 파일만 없음(폴더는 존재, commit-security.yaml 부재) — 위임을
#     아예 시도하지 않고 fail-closed exit 2 로 차단한다 (보안 검토 권고,
#     2026-08-18 — ③-c 갱신: v1 이 없으므로 "직접 판정"이 아니라 신 훅
#     자신의 FAIL 분기다).
#
# 왜 (i)와 다른 시나리오인가: (i)는 commit-security.yaml 이 스키마 위반
# 필드를 담고 있어(폴더는 정상 구성) bin/rein hook 내부에서
# PolicyLoadError → v2 자신의 native BLOCK(DENY) 로 귀결된다(v2 상태 db
# 존재 — 엔진이 실제로 로드를 "시도"는 했다는 증거). 이 시나리오 (j)는
# 폴더 자체는 있는데 commit-security.yaml 이 아예 없다(비어 있거나
# _version.yaml 만 남은 상태) — kernel/policy.py 의 load_policies() 는
# 예약 파일 _version.yaml 을 스킵하므로 매칭되는 policy 가 정확히 0개가
# 되고, "policy 0개 = 평가 기본 ALLOW"(다른 축·다른 트리거를 위해
# 의도된 설계, spec §3.4)에 걸려 v2 가 `{}`(ALLOW)를 반환한다 — 수정
# 전에는 이것이 v1 을 침묵시켜 보안 리뷰 요구 전체가 로그도 에러도 없이
# 사라지는 결과로 이어졌다(보안 검토가 샌드박스에서 재현 확정). 수정
# 후에는 lib/security-review-gate.sh 의 rein_security_review_delegate()
# 내부가 위임을 시도하기 전에 commit-security.yaml 자체의 존재를
# 확인해, 없으면 위임을 건너뛰고 결과를 FAIL 초기값 그대로 유지한다.
#
# ③-c 실측 정정 (2026-08-23): 신설 pre-bash-commit-review-gate.sh 는
# **그보다 먼저** 자신의 SECURITY_AXIS_DIR 가드에서 동일 조건("폴더는
# 있는데 commit-security.yaml 만 없다")을 이미 fail-closed 시킨다(그
# 훅 자신의 헤더 "축 설정 가드 선행" 절 — lib 내부 낙하 경로를 구조적으로
# 계승하되, 더 이른 지점에서 동일한 손상-설정 판정을 내린다). 그 결과
# 이 테스트가 실제로 관측하는 것은 lib 내부의 FAIL 낙하가 아니라 훅
# 자신의 축 설정 가드다 — 스텁 재현 없이 실제 훅으로 관통했을 때만
# 드러나는 차이이며, "위임 시도 자체가 없다"(v2 상태 db 미생성)는
# 안전 속성은 두 경로 모두 동일하게 보장한다.
# ============================================================

# _write_security_axis_policy_missing_commit_yaml
#   축 전용 정책 폴더는 만들되(디렉토리 자체는 존재) commit-security.yaml
#   은 두지 않는다 — _version.yaml 만 남긴다(버전 메타데이터 예약
#   파일이라 load_policies() 의 4필드 policy 스캔에서 스킵된다).
_write_security_axis_policy_missing_commit_yaml() {
  mkdir -p "$SANDBOX/.rein/policy/security-axis"
  rm -f "$SANDBOX/.rein/policy/security-axis/commit-security.yaml"
  printf 'version: 1\n' > "$SANDBOX/.rein/policy/security-axis/_version.yaml"
}

test_j_axis_policy_file_missing_fails_closed() {
  seed_dod "dod-2026-08-18-srg-switch.md"
  # no security stamp
  _link_rein_package
  _link_rein_bin
  _write_security_axis_policy_missing_commit_yaml
  _write_authority_switched_on

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # ③-c: 실측 정정 — 이 시나리오는 rein_security_review_delegate() 내부의
  # "정책 파일 없음 → FAIL 초기값 유지" 낙하 경로가 아니라, 그보다 먼저
  # 실행되는 신 훅 자신의 SECURITY_AXIS_DIR 가드("폴더는 있는데
  # commit-security.yaml 만 없다 = 설정 손상")에서 이미 fail-closed
  # 된다(2026-08-23 scratchpad 실측 — tests/hooks/test-pre-bash-commit-
  # review-gate.sh 의 `test_security_axis_file_missing_fails_closed` 와
  # 동일한 경로). 그래서 stderr 문구는 "v1 폴백 없음"이 아니라 그 가드
  # 고유의 손상-설정 메시지다.
  assert_fail_closed_exit2 "(j) missing commit-security.yaml (axis folder present) → damaged-config guard fires before delegate is ever attempted"
  assert_stderr_contains "commit-security.yaml"

  if _v2_state_db_exists; then
    fail "(j) v2 state db should NOT exist — the delegate must skip the bin/rein hook call entirely when the axis policy file itself is absent (no attempt at all, not even a failed one)"
  fi
}

run_test test_a_switch_on_valid_v2_evidence_allows "$HOOK"
run_test test_b_switch_on_no_v2_evidence_blocks "$HOOK"
run_test test_c_docs_only_allows_via_subject_empty_no_evidence_needed "$HOOK"
run_test test_d_light_tier_label_no_longer_special_cased "$HOOK"
run_test test_e_switch_off_axis_skipped_passes "$HOOK"
run_test test_f_delegate_exec_failure_fails_closed "$HOOK"
run_test test_g_cross_axis_isolation_docs_only_no_security_stamp "$HOOK"
run_test test_h_no_active_dod_allows_code_review_delegates_security_skips "$HOOK"
run_test test_i_axis_policy_corrupted_fails_closed_via_v2_deny "$HOOK"
run_test test_j_axis_policy_file_missing_fails_closed "$HOOK"

summary
