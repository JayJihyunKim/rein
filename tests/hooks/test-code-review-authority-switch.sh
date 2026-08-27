#!/bin/bash
# tests/hooks/test-code-review-authority-switch.sh
#
# v2 Phase 6 Task 6.1 본작업 — code_review 축 판정 권한을 v1 에서 v2
# (`rein.engine.authority` + `bin/rein hook`)로 전환하는 배선을 행위
# 기반으로 검증한다. 이 저장소는 source 방식 훅 테스트가 false-green
# 을 낸 전례(test-pre-bash-test-commit-gate.sh 헤더 주석 참조)가 있어,
# 이 스위트도 훅을 항상 실제로 실행한다 — 절대 source 하지 않는다.
#
# ============================================================
# 아키텍처 — "직접 위임" (사용자 결정 2026-08-18)
# ============================================================
#
# 코드 리뷰가 이전 배선("등록+양보" — hooks.json 에 v2 진입점을 별도
# PreToolUse(Bash) 그룹으로 등록하고, v1 은 전환이 확인되면 그 옆에서
# 조용히 통과만 시키는 구조)에 두 가지 차단급 결함을 지적했다:
#
#   [High-1] 지킴이 공백 창 — 훅 설정(hooks.json) 등록은 세션 시작
#     시점 스냅샷만 반영되는 반면(docs/reports/2026-05-19-cc-feature-
#     spike.md:170,174 실측 기록) v1 의 양보는 파일을 매번 읽어 즉시
#     발동한다. 그 결과 "v1 양보 + v2 미등록" 창이 세션·배포 경계마다
#     구조적으로 생긴다.
#   [High-2] 동작 갈라짐 — v1 은 활성 DoD 가 없으면 커밋 리뷰 판정을
#     아예 안 했는데, v2 기본 정책은 커밋에 무조건 code_review 를
#     요구한다.
#
# 해소책: hooks.json 등록 자체를 Phase 7(v1 제거 시점)로 미루고, v1
# 게이트가 전환 시 `bin/rein hook` 을 **동기 서브프로세스로 직접
# 호출**해 판정을 위임한다. 훅 설정 등록 없이도 매 호출 즉시 반영되는
# 경로라 [High-1] 의 공백 창이 원천적으로 없다. 위임 지점이 v1 의
# 기존 "활성 DoD 존재" 선행조건 **뒤**이므로 [High-2] 의 "활성 작업
# 없으면 통과" 의미론도 그대로 보존된다.
#
# 검증 대상 — 전부 `plugins/rein-core/hooks/lib/code-review-gate.sh`:
#   rein_code_review_authority_switched() — code_review 축이 v2 로
#     전환됐는지만 질의한다("위임해도 되는가" — 스스로 통과 여부를
#     결정하지 않는다, 이전 배선과의 핵심 차이).
#   rein_code_review_delegate()           — 전환이 확인된 뒤에만
#     호출된다. 이 훅이 받은 원본 이벤트 JSON($INPUT, 재조립 없음)을
#     `bin/rein hook` 의 stdin 에 그대로 흘려보내고, 결과를 ALLOW /
#     DENY / FAIL 세 갈래로 균일 해석한다.
#
# 이 스위트는 훅(원래 `pre-bash-test-commit-gate.sh`) 하나만 실행한다 —
# 이전 배선 초안과 달리 `bin/rein hook` 을 별도 진입점으로 다시 실행해
# "합성"을 검증하지 않는다: 위임이 이제 그 프로세스 **내부에서** 일어나므로,
# 그 프로세스의 stdout 자체가 곧 v2 의 판정 결과다(DENY 인 경우 v2 의 native
# JSON 원문이 그대로 그 stdout 이 된다).
#
# ============================================================
# Phase 7 웨이브 3 ③-c 갱신 (커밋 게이트 교대, 2026-08-23)
# ============================================================
#
# 구동 대상이 `pre-bash-test-commit-gate.sh`(삭제됨)에서
# `pre-bash-commit-review-gate.sh`(신설)로 바뀌었다 — code_review 축의
# 전환확인/위임 메커니즘 자체(lib/code-review-gate.sh 의 두 하위 함수)는
# 바이트 단위로 무변경이다. 바뀐 것은 **그 축을 소비하는 훅**이다: 구
# 훅은 미전환/위임FAIL 시 v1 이 자기 P3~P5b 로 직접 판정을 계속했지만
# (v1 폴백 존재), 신 훅은 그 폴백을 갖지 않는다(hooks/pre-bash-commit-
# review-gate.sh 자신의 헤더 판정 트리가 정본). 아래는 그로 인해 달라진
# 시나리오별 기대값이다 — (a)/(b) 는 무변경, (c)~(h) 는 이 절이 설명하는
# 대로 갱신됐다:
#   (c) 전환 off → 구: v1 이 CODEX_STAMP_MISSING 으로 직접 판정. 신:
#       NOT_SWITCHED → 축 skip(문서화된 opt-out) → 통과.
#   (d) 확인 실패 → 구: v1 이 CODEX_STAMP_MISSING 으로 직접 판정
#       (fail-closed 방향이지만 v1 의 JSON deny 형식). 신: 훅 자신이
#       fail-closed **exit 2**(평문 stderr) — v1 폴백이 없으므로 더 이상
#       JSON deny 형식이 아니다.
#   (e) 보안 축 무영향 → 구: 보안 축은 그 시점에도 여전히 v1 이 직접
#       판정했다(전환과 무관). 신: 보안 축도 이제 자신의 전환확인+위임을
#       거친다 — 이 시나리오를 "보안 축도 전환해 v2 로 독립 위임되고,
#       코드 축의 ALLOW 뒤에 보안 축만 자신의 이유로 DENY 한다"로
#       재설계했다(축 격리라는 원래 취지는 보존, 증명 경로만 v2 native
#       delegate 로 이동).
#   (f) 활성 DoD 없음 → **가장 큰 방향 전환**. 구: DOD_EXISTS 선행조건이
#       위임 시도 자체보다 먼저 걸러내(v1 이 계속 P3 진입 전에 조기
#       반환), delegation 인프라를 전혀 준비하지 않아도 통과했다(state db
#       부재가 그 증거). 신 훅은 그 선행조건을 갖지 않는다(hooks/pre-
#       bash-commit-review-gate.sh 헤더 "의도된 방향 변화 (a)" 참조) —
#       task.exists 조건화가 v1 의 "작업 없으면 리뷰 불요" 의미론을
#       v2 policy(`policies/default/commit.yaml`) 안으로 그대로 옮겼을
#       뿐, 위임 자체는 **항상 시도된다**. 그 결과 통과(ALLOW)라는 겉보기
#       결과는 같지만, 이제 state db 는 **존재해야** 한다(진짜 위임이
#       일어나 v2 자신이 task.exists 미매칭으로 ALLOW 를 낸 것) — 구
#       시나리오의 핵심 단언(state db 부재)이 정확히 뒤집힌다. 2026-08-23
#       scratchpad 실측(REIN_PROJECT_ROOT 를 태운 `bin/rein hook` 직접
#       호출, DoD 없음)으로 확인.
#   (g)/(h) 위임 실패/timeout → 구: v1 이 CODEX_STAMP_MISSING 으로 직접
#       판정(fail-closed 방향이지만 v1 형식). 신: fail-closed **exit 2**
#       (신 훅 자신의 "FAIL — v1 폴백 없음" stderr 문구).
#
# ============================================================
# "진짜 위임이 일어났는가" 를 어떻게 증명하는가
# ============================================================
#
# ALLOW 시나리오((a)/(e))는 까다로운 함정이 있다 — 위임이 성공해서
# 통과했는지, 아니면 위임이 (조용히) 실패해 v1 자신의 P3~P5b 로 폴백
# 했는데 그 로직이 우연히 같은 신선한 표식으로도 통과했는지, 겉보기
# 결과(exit 0 + 빈 stdout)만으로는 구분할 수 없다. 이 스위트는 부수
# 효과 하나를 관측해 이 모호함을 없앤다: `bin/rein hook` 이 실제로
# 실행되면(`run_hook_event()` → `_resolve_db_path()`) project_root 밑에
# `.rein/state/runtime.sqlite3` 를 항상 선생성한다(정책 평가 결과와
# 무관하게, 평가 전에 일어나는 부수 효과 — rein/cli/__init__.py 의
# `_resolve_db_path()`/`DB_FILENAME` 참조). v1 자신의 폴백 경로는 이
# 파일을 절대 만들지 않는다 — v2 를 아예 건드리지 않기 때문이다. 그래서
# 이 파일의 존재/부재가 "genuine subprocess 실행 여부"의 독립적인
# 증거가 된다: ALLOW/DENY 시나리오는 존재를 확인하고, off/check-실패/
# no-DoD/exec-실패/timeout 시나리오는 부재를 확인한다.
#
# ============================================================
# 시나리오 (a)~(h)
# ============================================================
#   (a) 전환 on + 신선한 표식 → 위임 결과 통과({}) → 보안 축 판정으로
#       정상 진행 (보안 축 폴더가 없어 그 축은 구조적으로 skip)
#   (b) 전환 on + 표식 없음(활성 DoD 있음) → 훅의 stdout 으로 v2 형식
#       차단 JSON 이 나온다 + 감사 로그 1건(중복 없음)
#   (c) 전환 off → NOT_SWITCHED → 축 skip(문서화된 opt-out) → 통과
#   (d) 전환 확인 실패(rein 패키지 조회 불가) → fail-closed exit 2
#       (v1 폴백 없음, 위 "③-c 갱신" 절 참조)
#   (e) 보안 축 무영향(재설계) — 코드 축은 신선한 표식으로 ALLOW, 보안
#       축은 자신도 전환되어 독립적으로 위임되고 자기 표식 부재로 DENY —
#       relay 된 JSON 의 사유가 code_review 가 아니라 security_review 임을
#       확인해 "코드 축 사유가 새지 않는다"는 원래 취지를 보존한다
#   (f) 전환 on + 활성 DoD 없음 + 표식 없음 → 통과 — 그러나 이제 위임은
#       **항상 시도된다**(state db 존재가 그 증거, 구 시나리오의 정반대)
#   (g) 위임 실행 실패(엔진 스크립트 손상 주입) → fail-closed exit 2
#       (v1 폴백 없음)
#   (h) 위임 timeout(가짜 지연 주입) → fail-closed exit 2 — 무한 대기가
#       아니라 제한 시간 안에 반환되는 것까지 단언
#
# 전부 실제 실행(source 금지). 표식 상태·로그 건수·state db 존재까지
# 단언한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK="pre-bash-commit-review-gate.sh"
COMMIT_CMD='git commit -m "feat: thing"'

# _event_payload CMD CWD
#   실제 Claude Code PreToolUse(Bash) hook 이 보내는 이벤트 JSON 모양을
#   최소 재현한다 — hook_event_name/tool_name/tool_input/cwd 네 필드.
#   v1(`bg_extract_command`)은 tool_input.command 만 읽지만, v2(`bin/rein
#   hook`)는 hook_event_name(이벤트 인식)·tool_name(command.type fact 게이팅)
#   ·cwd(REIN_PROJECT_ROOT 미설정 시의 project_root 유도)까지 읽는다 — v1
#   이 이 정확한 원문을 그대로 위임하므로($INPUT, 재조립 없음), 테스트
#   payload 도 두 소비자 모두가 필요로 하는 필드를 전부 갖춰야 실제
#   프로덕션 입력을 충실히 재현한다. python json.dumps 로 만든다(수동
#   문자열 보간은 COMMIT_CMD 안의 큰따옴표를 깨뜨린다).
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

# _link_rein_package
#   rein_code_review_authority_switched() 의 self-location(hooks/lib/
#   code-review-gate.sh → ../.. = $SANDBOX/.claude)이 실제 rein 패키지를
#   찾을 수 있도록 심볼릭 링크를 놓는다. 이 링크가 없으면 그 함수의
#   파이썬 프로브가 ModuleNotFoundError 로 실패해 "확인 자체가 불가능"
#   상태가 자연히 재현된다 — 시나리오 (d) 는 의도적으로 이 헬퍼를
#   호출하지 않는다.
_link_rein_package() {
  mkdir -p "$SANDBOX/.claude"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/rein" "$SANDBOX/.claude/rein"
}

# _link_rein_bin
#   rein_code_review_delegate() 가 여는 위임 대상($_REIN_CRG_PKG_PARENT/
#   bin/rein = $SANDBOX/.claude/bin/rein)을 실제 엔진 스크립트로 심볼릭
#   링크한다. bin/rein 자신의 self-location(`_locate_package_parent()`)
#   은 `os.path.realpath(__file__)` 을 쓰므로 심볼릭 링크를 그대로
#   따라가 진짜 plugin root(및 그 밑의 rein 패키지·policies/default)를
#   찾는다 — _link_rein_package() 와 별개로 동작한다(스모크 테스트로
#   실측 확인됨 — .claude/rein 심볼릭 링크가 전혀 없어도 이 링크
#   하나만으로 위임이 끝까지 성공한다).
_link_rein_bin() {
  mkdir -p "$SANDBOX/.claude/bin"
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/bin/rein" "$SANDBOX/.claude/bin/rein"
}

# _write_broken_engine_script
#   위임 대상 경로에 진짜 엔진이 아니라 즉시 비정상 종료하는 파이썬
#   스크립트를 심는다(심볼릭 링크가 아니라 sandbox 소유의 실제 파일 —
#   실제 저장소 파일을 건드리지 않는다). 시나리오 (g) "엔진 스크립트
#   손상" 재현.
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

# _write_sleeping_engine_script
#   위임 대상 경로에 무한정 잠드는 스크립트를 심는다. 시나리오 (h)
#   "위임 timeout" 재현 — REIN_CRG_DELEGATE_TIMEOUT_S 를 짧게 패치한
#   뒤에만 이 스크립트를 써야 테스트가 실제로 그 시간 안에 끝난다.
_write_sleeping_engine_script() {
  mkdir -p "$SANDBOX/.claude/bin"
  cat > "$SANDBOX/.claude/bin/rein" <<'PY'
#!/usr/bin/env python3
import time
time.sleep(9999)
PY
  chmod +x "$SANDBOX/.claude/bin/rein"
}

# _write_authority_switched_on / _off — 프로젝트 override
# (.rein/policy/authority.yaml, rein.engine.authority 스키마).
_write_authority_switched_on() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - code_review\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
_write_authority_switched_off() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched: none\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
# _write_authority_switched_both — 시나리오 (e) 전용 (③-c 재설계). 코드
# 축과 보안 축 둘 다 전환해, 보안 축도 이제 자신의 v2 위임을 독립적으로
# 거친다는 것을 증명한다.
_write_authority_switched_both() {
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched:\n  - code_review\n  - security_review\n' > "$SANDBOX/.rein/policy/authority.yaml"
}
# _link_security_axis_policy — 시나리오 (e) 전용. security_review 축
# 위임(rein_security_review_delegate())이 주입하는 REIN_POLICY_DIR
# 대상 폴더를 실제 저장소에서 그대로 복사한다(tests/hooks/test-security-
# review-authority-switch.sh 의 동명 헬퍼와 동일 기법).
_link_security_axis_policy() {
  mkdir -p "$SANDBOX/.rein/policy"
  rm -rf "$SANDBOX/.rein/policy/security-axis"
  cp -R "$REAL_PROJECT_DIR/tests/fixtures/policy/security-axis" "$SANDBOX/.rein/policy/security-axis"
}

# Phase 7 웨이브 3 ③-d (2026-08-24): _write_code_stamp/_write_security_
# stamp(legacy marker 작성)는 제거됐다 — evaluator.py 의 legacy dual-read
# 대체 계층이 완전히 삭제되어 그 표식들은 더 이상 어떤 판정에도 관여하지
# 않는다(authority.py/evaluator.py 자신의 "Phase 7 웨이브 3 ③-d" 주석
# 참조). "표식이 신선하면 ALLOW" 를 검증하던 시나리오는 이제 **실제 v2
# 증거 발급**으로만 ALLOW 를 만들 수 있다 — 아래 _seed_real_repo +
# _gitignore_rein_runtime + _issue_v2_evidence 가 그 대체 경로다.

# _seed_real_repo — 이 스위트의 ALLOW 시나리오가 실제 git 저장소를
# 필요로 한다(digest 산정이 git 상태에 의존) — tests/hooks/test-pre-bash-
# commit-review-gate.sh 의 동명 헬퍼와 동일.
_seed_real_repo() {
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "t"
  git -C "$SANDBOX" config commit.gpgsign false
  printf '# baseline\n' > "$SANDBOX/CHANGELOG.md"
  git -C "$SANDBOX" add CHANGELOG.md
  git -C "$SANDBOX" commit -q -m "chore: baseline"
}

# _gitignore_rein_runtime — 실측(2026-08-24, tests/hooks/test-pre-bash-
# commit-review-gate.sh 디버깅 과정에서 발견): 실제 rein 프로젝트는
# `/.rein/state/`·`/.rein/logs/` 를 gitignore 한다(이 저장소 자신의
# .gitignore 참조) — 그래야 `bin/rein hook`/`issue-evidence` 자신의 런타임
# 부수 효과(sqlite3 state db, block 로그)가 매 호출마다 changeset digest
# 를 오염시키지 않는다. 이 gitignore 가 없는 샌드박스에서는 **첫 위임
# 호출 자체가 자신이 만든 부수 효과 파일을 다음 digest 계산에서 "변경된
# 파일"로 오염**시켜 subject-empty/실 evidence 매칭이 깨진다 — 반드시
# baseline 커밋 이전에 호출한다.
_gitignore_rein_runtime() {
  cat >> "$SANDBOX/.gitignore" <<'EOF'
/.rein/state/
/.rein/logs/
EOF
}

# _issue_v2_evidence CAPABILITY [POLICY_DIR]
#   $SANDBOX 의 현재 changeset 에 대해 실제 v2 증거를 발급한다 (tests/
#   hooks/test-pre-bash-commit-review-gate.sh 의 동명 헬퍼와 동일 — 호출
#   시점의 staged 변경을 그대로 대상으로 삼는다). POLICY_DIR 는 security_
#   review 축 전용 정책 폴더(REIN_POLICY_DIR)를 넘길 때만 쓴다.
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

_blocks_log_count() {
  local f="$SANDBOX/trail/incidents/blocks.jsonl"
  [ -f "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0
}

# _v2_state_db_exists
#   진짜 위임(서브프로세스 실행)이 일어났는지의 독립 증거. 파일 상단
#   "진짜 위임이 일어났는가" 절 참조. DB_FILENAME 은
#   rein/platform/storage/local.py 의 상수(실측 확인, 2026-08-18) —
#   이 테스트가 그 내부 구현에 의존한다는 것은 알고 쓰는 트레이드오프
#   다(부수 효과를 관측하는 화이트박스 검증).
_v2_state_db_exists() {
  [ -f "$SANDBOX/.rein/state/runtime.sqlite3" ]
}

# ------------------------------------------------------------
# v1-stdout assertions
# ------------------------------------------------------------

assert_v1_silent() {
  # v1 must have judged NOTHING that resulted in a denial — exit 0, empty
  # stdout.
  assert_exit 0 "$1: exit code"
  [ -z "$HOOK_STDOUT" ] || fail "$1: expected no denial, got stdout: $HOOK_STDOUT"
}

assert_v1_deny_reason_code() {
  # $1=expected reason code substring, $2=message. v1's OWN deny_emit path
  # (P3/P4/P5/P5b/P6) — always exit 0 + JSON deny.
  assert_exit 0 "$2: exit code (JSON deny path exits 0)"
  case "$HOOK_STDOUT" in
    *"$1"*) ;;
    *) fail "$2: reason-code '$1' not found in stdout: $HOOK_STDOUT" ;;
  esac
}

assert_v1_deny_reason_code_absent() {
  # $1=reason code that must NOT appear (proves that axis was not judged
  # directly by v1), $2=message
  case "$HOOK_STDOUT" in
    *"$1"*) fail "$2: v1 stdout unexpectedly contains '$1' (that axis should not have been judged directly by v1): $HOOK_STDOUT" ;;
    *) ;;
  esac
}

# _hook_stdout_permission_decision
#   HOOK_STDOUT 을 PreToolUse native 스키마로 파싱해 permissionDecision
#   값만 뽑는다. 파싱 불가/스키마 밖이면 빈 문자열.
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
  # ③-c: v1 폴백이 없는 두 경로(확인 실패 / 위임 FAIL)의 공통 형태 —
  # 평문 stderr + exit 2, stdout 은 비어 있어야 한다(JSON deny 형식이
  # 아니다 — 그 형식은 v2 native DENY relay 전용).
  local msg="$1"
  assert_exit 2 "$msg"
  [ -z "$HOOK_STDOUT" ] || fail "$msg: fail-closed exit 2 must not also emit stdout: $HOOK_STDOUT"
}

assert_v1_relayed_v2_deny() {
  # $1=message. v1 이 v2 의 native deny JSON 을 "그대로" relay 했는지
  # 검증한다 — v1 자신이 deny_emit 으로 재구성한 것이 아니라는 증거로
  # v1 의 deny_emit 이 항상 붙이는 "[reason-code: ...]" 접미어가 없음을
  # 확인한다(json-deny-emitter.sh 의 REASON_CODE_TEMPLATE 참조 — v2 는
  # 그 템플릿을 전혀 모른다).
  #
  # Phase 7 웨이브 3 ③-d 갱신: 예전에는 여기서 reason 문자열에 requirement
  # 이름("code_review" 등) 이 담겨 있는지도 확인했다 — 그 이름은
  # evaluator.py 의 legacy dual-read authority_note(v2 evidence 부재 시
  # 항상 부착되던 주석)의 산물이었다. ③-d 로 그 note 부착 조건이 "v2 가
  # 판정할 재료 자체가 없는" 두 축(tests_passed/user_approval)으로
  # 좁혀지면서, code_review/security_review 의 통상 DENY 는 이제 generic
  # `REASON_MISSING_EVIDENCE`("required evidence is missing")만 낸다 —
  # requirement 이름 확인은 더 이상 이 함수의 몫이 아니다(호출자가 필요
  # 하면 _v2_state_db_exists 등 구조적 증거로 "어느 축이 진짜 위임됐는가"
  # 를 직접 규명한다).
  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "$1: HOOK_STDOUT is not a PreToolUse deny envelope (permissionDecision='$decision'): $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"code_review"*) ;;
    *"required evidence is missing"*) ;;
    *) fail "$1: reason is neither v2's own substring 'code_review' nor the generic missing-evidence reason — this does not look like v2's real decision: $HOOK_STDOUT" ;;
  esac
  case "$HOOK_STDOUT" in
    *"[reason-code:"*) fail "$1: reason contains v1's own deny_emit '[reason-code:' marker — v1 must relay v2's JSON verbatim, not reconstruct it: $HOOK_STDOUT" ;;
    *) ;;
  esac
}

# ============================================================
# (a) 전환 on + 실제 v2 code_review 증거 발급 → 위임 결과 통과({}) —
#     보안 축은 이 시나리오에서 전환하지 않으므로(opt-out) 관여하지
#     않는다.
#
# Phase 7 웨이브 3 ③-d 재조준 — legacy 표식은 더 이상 판정에 관여하지
# 않으므로(_write_code_stamp/_write_security_stamp 제거, 위 헬퍼 섹션의
# ③-d 주석 참조), ALLOW 는 이제 실제 git 변경 + 실제 v2 증거 발급으로만
# 만들 수 있다.
# ============================================================

test_a_switch_on_valid_v2_evidence_allows() {
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _write_authority_switched_on
  seed_dod "dod-2026-08-18-crg-switch.md"
  _gitignore_rein_runtime
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  mkdir -p "$SANDBOX/scripts"
  printf 'echo real change under review\n' > "$SANDBOX/scripts/reviewed-change.sh"
  git -C "$SANDBOX" add scripts/reviewed-change.sh
  _issue_v2_evidence "code_review" \
    || fail "(a) code_review evidence issuance failed"

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(a) real code_review evidence + switch on → v1 fully silent (v2 delegate ALLOW, security axis not switched)"
  _v2_state_db_exists || fail "(a) expected v2 state db to exist — proves the code_review axis was genuinely delegated to bin/rein hook, not merely coincidentally passed by a v1 fallback"
}

# ============================================================
# (b) 전환 on + 표식 없음(활성 DoD 있음) → v1 게이트의 stdout 으로
#     v2 형식 차단 JSON 이 나온다 + 감사 로그 1건(중복 없음)
# ============================================================

test_b_switch_on_no_v2_evidence_blocks() {
  seed_dod "dod-2026-08-18-crg-switch.md"
  _link_rein_package
  _link_rein_bin
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
  assert_file_contains "trail/incidents/blocks.jsonl" "코드 리뷰 위임 차단"

  _v2_state_db_exists || fail "(b) expected v2 state db to exist — proves bin/rein hook actually ran and produced this decision"
}

# ============================================================
# (c) 전환 off (오버라이드에 code_review 없음) → v1 이 종전대로 판정
#     (기존 메시지·로그)
# ============================================================

test_c_switch_off_axis_skipped_passes() {
  seed_dod "dod-2026-08-18-crg-switch.md"
  _link_rein_package
  _write_authority_switched_off

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # ③-c: NOT_SWITCHED 는 이제 문서화된 opt-out — v1 폴백 판정이 없으므로
  # 이 축은 조용히 통과한다(security axis 도 폴더 부재로 skip).
  assert_v1_silent "(c) code_review NOT_SWITCHED → axis skip, overall pass (no v1 fallback judgment)"
  if _v2_state_db_exists; then
    fail "(c) v2 state db should NOT exist — delegation must never be attempted when the switch is off"
  fi
}

# ============================================================
# (d) 전환 확인 실패(rein 패키지 조회 불가) → v1 이 계속 판정
#     (fail-closed)
#
# No _link_rein_package() call here — self-location cannot find the rein
# package inside the sandbox, so rein_code_review_authority_switched()'s
# python probe hits ModuleNotFoundError and returns "확인 자체가
# 불가능"(bash function returns 1). The authority.yaml override, if it
# COULD be read, would say "switched" — proving the fail-closed direction
# holds even when the underlying policy would have said otherwise.
# ============================================================

test_d_switch_check_unavailable_fails_closed() {
  seed_dod "dod-2026-08-18-crg-switch.md"
  _write_authority_switched_on   # would say switched, but unreachable (no rein package link)

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # ③-c: 확인 자체가 불가능(ERROR)하면 훅 자신이 fail-closed exit 2 —
  # v1 폴백이 없으므로 더 이상 CODEX_STAMP_MISSING 형식의 JSON deny 가
  # 아니다.
  assert_fail_closed_exit2 "(d) switch-check unavailable must fail closed via the hook's own ERROR branch"
  assert_stderr_contains "[rein]"
  if _v2_state_db_exists; then
    fail "(d) v2 state db should NOT exist — delegation must never be attempted when the switch-check itself fails"
  fi
}

# ============================================================
# (e) 보안 축은 전환과 무관하게 v1 이 계속 판정 — 코드 표식은 신선(위임
#     ALLOW 를 받는다)하지만 보안 표식이 없으면 보안 축만 차단한다
# ============================================================

test_e_security_axis_independently_delegated_and_denies() {
  # ③-c 재설계 (원 시나리오는 "보안 축은 v1 이 계속 직접 판정" — 그
  # 폴백이 제거됐으므로 더 이상 성립하지 않는다). 이제 코드 축은 실제
  # v2 증거로 ALLOW, 보안 축은 자신도 전환되어 독립적으로 위임되고 증거
  # 부재로 DENY 한다.
  #
  # Phase 7 웨이브 3 ③-d 재조준(2차): legacy 표식 제거에 더해, DENY
  # reason 문자열 자체도 이제 requirement 이름을 담지 않는다(양 축 모두
  # generic `REASON_MISSING_EVIDENCE`, 위 assert_v1_relayed_v2_deny 의
  # ③-d 주석 참조) — "reason 에 security_review 는 있고 code_review 는
  # 없다"는 텍스트 기반 판별이 더 이상 성립하지 않는다. 대신 **차등
  # 비교**로 같은 원리를 구조적으로 증명한다: (1) code_review 만 증거를
  # 발급한 상태에서 여전히 DENY 라면 — 보안 축이 code_review 의 ALLOW 와
  # 무관하게 독립적으로 차단하고 있다는 뜻이다(code_review 만으로
  # 충분했다면 이 시점에 이미 ALLOW 였을 것). (2) 이어서 security_review
  # 증거까지 마저 발급하면 ALLOW 로 뒤집힌다 — 그 남은 유일한 변수가
  # security_review 축이었음을 직접 증명한다.
  _seed_real_repo
  _link_rein_package
  _link_rein_bin
  _link_security_axis_policy
  _write_authority_switched_both
  seed_dod "dod-2026-08-18-crg-switch.md"
  _gitignore_rein_runtime
  ( cd "$SANDBOX" && git add -A && git commit -q -m "test-infra baseline" )
  mkdir -p "$SANDBOX/scripts"
  printf 'echo real change under review\n' > "$SANDBOX/scripts/reviewed-change.sh"
  git -C "$SANDBOX" add scripts/reviewed-change.sh
  _issue_v2_evidence "code_review" \
    || fail "(e) code_review evidence issuance failed"
  # no security_review evidence yet

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  local decision
  decision=$(_hook_stdout_permission_decision)
  [ "$decision" = "deny" ] || fail "(e) step 1: code_review evidence alone should NOT be enough — security_review is independently required (permissionDecision='$decision'): $HOOK_STDOUT"
  case "$HOOK_STDOUT" in
    *"[reason-code:"*) fail "(e) reason contains v1's own deny_emit '[reason-code:' marker — must relay v2's JSON verbatim: $HOOK_STDOUT" ;;
    *) ;;
  esac
  _v2_state_db_exists || fail "(e) expected v2 state db to exist — both axes were genuinely delegated (code_review ALLOWed before security_review ran)"

  # Step 2: also issue security_review evidence for the SAME staged change
  # (still staged — nothing has been re-staged since) → now both axes are
  # satisfied and the overall decision must flip to ALLOW.
  _issue_v2_evidence "security_review" "$SANDBOX/.rein/policy/security-axis" \
    || fail "(e) security_review evidence issuance failed"
  run_hook "$HOOK" "$payload"
  assert_v1_silent "(e) step 2: once security_review evidence is ALSO issued, the same event now passes — proves the security axis (and only it) was the remaining blocker"
}

# ============================================================
# (f) 전환 on + 활성 DoD 없음 + 표식 없음 → 통과 (v1 의미 보존).
#
# 의도적으로 delegation 인프라를 전혀 준비하지 않는다(패키지/엔진
# 링크도, authority override 도 없음) — 그럼에도 통과해야 한다는 것 자체
# 가, DOD_EXISTS 선행조건이 위임 시도(그리고 그 이전의 전환 확인)보다
# 먼저 이 이벤트를 걸러낸다는 가장 강한 증거다. v2 state db 부재로
# 재확인한다.
# ============================================================

test_f_no_active_dod_allows_via_genuine_delegation() {
  # ③-c 방향 전환 (파일 헤더 "③-c 갱신" 절 참조): 이 훅에는 DOD_EXISTS
  # 선행조건이 없다 — task.exists 조건화가 v1 의 "작업 없으면 리뷰 불요"
  # 의미론을 v2 policy 안으로 옮겼을 뿐, 위임은 **항상 시도된다**. 그래서
  # 이번엔 package/bin 을 링크하고 switched 로 만들어야 한다(구 시나리오의
  # 정반대 — 구는 의도적으로 아무것도 준비하지 않았다).
  _link_rein_package
  _link_rein_bin
  _write_authority_switched_on
  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  assert_v1_silent "(f) no active DoD → still passes, but now via genuine v2 delegation (task.exists absent → policy does not match)"
  _v2_state_db_exists || fail "(f) expected v2 state db to EXIST — delegation is attempted unconditionally now, this is the intentional direction change from the old single hook"
  local count
  count=$(_blocks_log_count)
  [ "$count" -eq 0 ] || fail "(f) expected 0 block-log entries, got $count"
}

# ============================================================
# (g) 위임 실행 실패(엔진 스크립트 손상 주입) → v1 이 직접 판정
#     (fail-closed)
# ============================================================

test_g_delegate_exec_failure_fails_closed() {
  seed_dod "dod-2026-08-18-crg-switch.md"
  _link_rein_package
  _write_broken_engine_script
  _write_authority_switched_on
  # no code stamp — irrelevant now (there is no v1 fallback that would read
  # it); FAIL fails closed regardless of what a v1 fallback would have said.

  local payload
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  run_hook "$HOOK" "$payload"

  # ③-c: 위임 FAIL → 훅 자신이 fail-closed exit 2 (v1 폴백 없음).
  assert_fail_closed_exit2 "(g) delegate exec failure must fail closed, no v1 fallback judgment"
  assert_stderr_contains "there is no v1 fallback judgment for this axis anymore"
  if _v2_state_db_exists; then
    fail "(g) v2 state db should NOT exist — the broken engine script exits before ever reaching rein.cli / opening state"
  fi
}

# ============================================================
# (h) 위임 timeout(가짜 지연 주입) → v1 이 직접 판정 — 무한 대기가
#     아니라 제한 시간 안에 반환되는 것까지 단언
# ============================================================

test_h_delegate_timeout_fails_closed_within_bound() {
  if ! command -v timeout >/dev/null 2>&1; then
    echo "  SKIP: timeout(1) not on PATH — scenario (h) not applicable"
    return
  fi

  seed_dod "dod-2026-08-18-crg-switch.md"
  _link_rein_package
  _write_sleeping_engine_script
  _write_authority_switched_on

  # Patch the sandboxed copy to use a short timeout for this test only —
  # same technique as tests/hooks/test-pre-edit-coverage-gate.sh's
  # tier1-timeout fixture (VALIDATOR_TIMEOUT_S=30 → =2).
  sed -i.bak \
    's/REIN_CRG_DELEGATE_TIMEOUT_S=30/REIN_CRG_DELEGATE_TIMEOUT_S=2/' \
    "$SANDBOX/.claude/hooks/lib/code-review-gate.sh"
  rm -f "$SANDBOX/.claude/hooks/lib/code-review-gate.sh.bak"

  local payload start_ts end_ts elapsed
  payload=$(_event_payload "$COMMIT_CMD" "$SANDBOX")
  start_ts=$(date +%s)
  run_hook "$HOOK" "$payload"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # ③-c: timeout → FAIL → fail-closed exit 2 (v1 폴백 없음).
  assert_fail_closed_exit2 "(h) delegation timeout must fail closed, no v1 fallback judgment"
  [ "$elapsed" -lt 15 ] || fail "(h) hook took ${elapsed}s to return — expected a bounded return (timeout patched to 2s), nowhere near the 9999s the fake engine sleeps for"
  if _v2_state_db_exists; then
    fail "(h) v2 state db should NOT exist — the sleeping engine script never reaches rein.cli / opens state before being killed by timeout"
  fi
}

run_test test_a_switch_on_valid_v2_evidence_allows "$HOOK"
run_test test_b_switch_on_no_v2_evidence_blocks "$HOOK"
run_test test_c_switch_off_axis_skipped_passes "$HOOK"
run_test test_d_switch_check_unavailable_fails_closed "$HOOK"
run_test test_e_security_axis_independently_delegated_and_denies "$HOOK"
run_test test_f_no_active_dod_allows_via_genuine_delegation "$HOOK"
run_test test_g_delegate_exec_failure_fails_closed "$HOOK"
run_test test_h_delegate_timeout_fails_closed_within_bound "$HOOK"

summary
