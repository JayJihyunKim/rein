#!/bin/bash
# plugins/rein-core/scripts/rein-mark-security-reviewed.sh
#
# 중앙 v2 보안 증거 발급기 (Phase 7 웨이브 3 ③-a 로 신설, ③-d 로 정체성
# 확정). Phase 7 웨이브 3 ③-a 시점에는 이 스크립트가 "레거시 표식(구분자
# `=`) 을 쓰는 김에 v2 evidence 도 병행 발급"하는 writer 였다 — 그 레거시
# 표식(당시 유일한 writer 는 agents/security-reviewer.md 안의 인라인 heredoc
# 지시였고, 두 차례의 스키마 drift 사고(필드 누락/구분자 오타) 때문에 쓰기
# 로직을 이 스크립트 하나로 중앙화했었다)의 write 경로는 ③-d 에서 완전히
# 제거됐다 — `bin/rein issue-evidence security_review` 를 통한 v2 증거
# 발급이 이제 보안 리뷰의 유일한 기록 경로다. 이 스크립트의 역할은 그
# 발급을 (a) 안전하게 시도하고 (b) 실패/거부/스킵을 정직한 방향으로
# 알리는 것으로 좁혀졌다 — 더 이상 아무 파일도 쓰지 않는다.
#
# Usage:
#   rein-mark-security-reviewed.sh --level <base|standard|strict> \
#     --cycle <dod-slug> --verdict PASS [--reviewed-digest <D>]
#   rein-mark-security-reviewed.sh --print-digest
#
# verdict 가 PASS 가 아니면(또는 누락되면) 발급을 시도하지 않고 exit 1 —
# "재검토 필요" 상태를 그대로 보존한다.
#
# 발급 실패 방향 (Phase 7 웨이브 3 ③-d 갱신 — 레거시 표식이 있던 시절엔
# 아래 항목 대부분이 "발급 실패해도 레거시 표식이 그대로 있으니 non-fatal"
# 이었다. 이제 발급이 유일한 기록이므로, 성공(exit 0)과 "지금 리뷰할
# 민감 대상이 없음"(subject-empty, 정상 스킵) 을 제외한 모든 경로가
# 이 사이클에 아무 기록도 남기지 못했다는 뜻이고, 그래서 전부 ERROR +
# 비0 exit 로 통일했다):
#   - subject-empty(민감 대상 없음)       → 정상 스킵, exit 0 (NOTICE)
#   - subject-unresolved(대상 판정 불능)  → ERROR, exit 1
#   - `--reviewed-digest` 미지정           → ERROR, exit 1
#   - digest-mismatch(리뷰 도중 트리 변경) → ERROR, exit 1
#   - 그 외 명확한 거부 사유               → ERROR, exit 1
#   - 발급 인프라 실패 (bin/rein·python3 부재, CLI 비정상 종료 등) → ERROR, exit 1
#
# --reviewed-digest <D> — High finding (code review round 1, Phase 7 웨이브
# 3 ③-a): "security evidence must bind to review-START state". 이 스크립트는
# digest 를 자체적으로 (호출 시점에) 캡처하지 않는다 — 캡처가 리뷰 종료 후
# 일어나면, 리뷰 도중에 stage 된 변경까지 "리뷰됨"으로 축복하는 결과가
# 된다. 호출자(security-reviewer.md)가 리뷰 시작 시점에 캡처해 둔 digest 를
# 이 플래그로 넘겨야 발급을 시도한다 — `bin/rein issue-evidence` 가 현재
# digest 를 재계산해 불일치 시 거부하므로, 그 재계산-대조가 곧 "review-start
# state 에 결속" 이다. 생략하면 정직하게 ERROR 로 거부한다(스타트 시점 값이
# 없으니 결속할 수 없고, 이제는 결속 없이 진행할 대체 경로도 없다).
#
# --print-digest — High finding (code review round 2, Phase 7 웨이브 3
# ③-a): "capture/review/issuance must see the SAME profile+subject". 호출자
# (security-reviewer.md 2.5단계)가 리뷰 시작 시점의 digest 를 캡처할 때 이
# 스크립트가 아니라 `bin/rein` 을 REIN_POLICY_DIR 없이 직접 호출했었다 —
# 그러면 default(sensitive) 프로필 digest 를 캡처하는데, 아래 issuance 경로는
# `.rein/policy/security-axis`(이 저장소는 strict) 를 쓰므로 캡처와 발급이
# 서로 다른 프로필/subject 를 본다(재현됨: staged plain-code 변경 → 캡처는
# default 프로필의 sentinel, 발급은 strict 의 실 sha). 고쳐서 이 스크립트가
# env 구성(PROJECT_DIR + POLICY_DIR)의 유일한 지점이 되고, `--print-digest`
# 와 실제 발급(`_msr_issue_evidence`) 둘 다 그 지점을 공유한다 — 아래
# "shared env for issue-evidence calls" 절 참조. `--level`/`--cycle`/
# `--verdict`/`--reviewed-digest` 와는 함께 쓸 수 없다(부작용 없는 조회
# 전용 모드 — trail/dod 생성도, 발급 시도도 하지 않는다).

set -u

usage() {
  echo "Usage: bash scripts/rein-mark-security-reviewed.sh --level <base|standard|strict> --cycle <dod-slug> --verdict PASS [--reviewed-digest <D>]" >&2
  echo "       bash scripts/rein-mark-security-reviewed.sh --print-digest" >&2
  echo "       bash scripts/rein-mark-security-reviewed.sh --print-subject" >&2
}

LEVEL=""
CYCLE=""
VERDICT=""
REVIEWED_DIGEST=""
PRINT_DIGEST=0
PRINT_SUBJECT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --print-digest)
      PRINT_DIGEST=1
      shift
      ;;
    --print-subject)
      PRINT_SUBJECT=1
      shift
      ;;
    --level|--cycle|--verdict|--reviewed-digest)
      _msr_flag="$1"
      if [ $# -lt 2 ]; then
        echo "ERROR: [mark-security-reviewed] $_msr_flag requires a value" >&2
        usage
        exit 1
      fi
      _msr_val="$2"
      case "$_msr_flag" in
        --level) LEVEL="$_msr_val" ;;
        --cycle) CYCLE="$_msr_val" ;;
        --verdict) VERDICT="$_msr_val" ;;
        --reviewed-digest) REVIEWED_DIGEST="$_msr_val" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: [mark-security-reviewed] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ "$PRINT_DIGEST" -eq 1 ] && [ "$PRINT_SUBJECT" -eq 1 ]; then
  echo "ERROR: [mark-security-reviewed] --print-digest and --print-subject are mutually exclusive" >&2
  usage
  exit 1
fi

if [ "$PRINT_DIGEST" -eq 1 ]; then
  if [ -n "$LEVEL" ] || [ -n "$CYCLE" ] || [ -n "$VERDICT" ] || [ -n "$REVIEWED_DIGEST" ]; then
    echo "ERROR: [mark-security-reviewed] --print-digest cannot be combined with --level/--cycle/--verdict/--reviewed-digest" >&2
    usage
    exit 1
  fi
elif [ "$PRINT_SUBJECT" -eq 1 ]; then
  if [ -n "$LEVEL" ] || [ -n "$CYCLE" ] || [ -n "$VERDICT" ] || [ -n "$REVIEWED_DIGEST" ]; then
    echo "ERROR: [mark-security-reviewed] --print-subject cannot be combined with --level/--cycle/--verdict/--reviewed-digest" >&2
    usage
    exit 1
  fi
else
  if [ -z "$LEVEL" ] || [ -z "$CYCLE" ]; then
    echo "ERROR: [mark-security-reviewed] --level and --cycle are required" >&2
    usage
    exit 1
  fi

  case "$LEVEL" in
    base|standard|strict) ;;
    *)
      echo "ERROR: [mark-security-reviewed] --level must be base|standard|strict (got: $LEVEL)" >&2
      exit 1
      ;;
  esac

  # CYCLE flows unquoted into a log line ("level=$LEVEL cycle=$CYCLE") below
  # — a raw control character (most dangerously LF) could inject or corrupt
  # that diagnostic output. Reject the whole control-character class
  # (0x00-0x1F, 0x7F) rather than enumerating just LF — closing the
  # boundary by construction instead of by listing individual bad bytes.
  case "$CYCLE" in
    *[[:cntrl:]]*)
      echo "ERROR: [mark-security-reviewed] --cycle contains a control character — refusing to proceed (the value flows into log output; a raw control character could inject or corrupt lines)" >&2
      exit 1
      ;;
  esac

  # Only a PASS verdict may attempt issuance — any other value (including a
  # missing --verdict) refuses and exits non-zero. This keeps the
  # "no evidence == needs review" invariant the gate relies on.
  if [ "$VERDICT" != "PASS" ]; then
    echo "ERROR: [mark-security-reviewed] refusing to issue evidence for a non-PASS verdict (got: '${VERDICT}') — only --verdict PASS issues" >&2
    exit 1
  fi
fi

# --- PROJECT_DIR 해소 (rein-mark-spec-reviewed.sh 와 동일 원리) ---
# PROJECT_DIR 은 v2 증거를 발급받는 rein 프로젝트 루트여야 하며, 그 증거를
# 읽는 게이트(security-review-gate.sh / authority.py)와 반드시 동일하게
# 해소되어야 한다. --print-digest 모드도 동일한 PROJECT_DIR 해소를 거친다 —
# 발급이 볼 project_root 와 캡처가 보는 project_root 가 갈라지면 High
# finding(code review round 2)이 그대로 재발한다.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for _msr_pd_lib in \
  "$SCRIPT_DIR/../hooks/lib/project-dir.sh" \
  "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/project-dir.sh" \
  "$SCRIPT_DIR/../plugins/rein-core/hooks/lib/project-dir.sh"; do
  if [ -n "$_msr_pd_lib" ] && [ -f "$_msr_pd_lib" ]; then
    # shellcheck source=/dev/null
    . "$_msr_pd_lib"
    break
  fi
done
if declare -F resolve_project_dir >/dev/null 2>&1; then
  PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
else
  # Conservative fallback — lib 미발견. resolve_project_dir 의 env-override +
  # git-root-from-cwd 순서를 그대로 모사한다 (rein-mark-spec-reviewed.sh 와
  # 동일 fallback — 두 스크립트가 같은 계약을 공유한다).
  if [ -n "${REIN_PROJECT_DIR_OVERRIDE:-}" ]; then
    PROJECT_DIR="$REIN_PROJECT_DIR_OVERRIDE"
  elif [ -n "${REIN_PROJECT_DIR:-}" ]; then
    PROJECT_DIR="$REIN_PROJECT_DIR"
  else
    PROJECT_DIR="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      git rev-parse --show-toplevel 2>/dev/null)" || PROJECT_DIR=""
    [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"
  fi
fi

if [ ! -d "$PROJECT_DIR/trail" ]; then
  echo "ERROR: [mark-security-reviewed] resolved PROJECT_DIR has no trail/ directory: $PROJECT_DIR" >&2
  echo "ERROR: [mark-security-reviewed] this is not a rein project root." >&2
  echo "ERROR: [mark-security-reviewed] set REIN_PROJECT_DIR_OVERRIDE or run from the project root." >&2
  exit 1
fi

# ============================================================================
# --- Shared env for issue-evidence calls (Finding 2, code review round 2) ---
# ============================================================================
# ONE construction point for PLUGIN_ROOT/BIN_REIN/POLICY_DIR, used by BOTH
# `--print-digest` (below, early exit) and the write-mode issuance attempt
# further down (`_msr_issue_evidence`). Before this fix the two paths lived
# in different places (the agent's step 2.5 called the raw CLI with no
# REIN_POLICY_DIR; this script's issuance call set REIN_POLICY_DIR to the
# security-axis dir) and could disagree on which profile's digest to
# compute. No duplication now — there is exactly one place that builds this
# env, and both modes call through it.
#
# plugin root 는 이 스크립트 자신의 위치에서 유도한다 — CLAUDE_PLUGIN_ROOT
# 환경변수에 기대지 않는다. 스킬/에이전트가 Bash 로 스크립트를 호출하는
# 환경에는 CLAUDE_PLUGIN_ROOT 가 비어 있는 경우가 있어(알려진 저장소
# 함정 — 로더가 조용히 빈 값으로 계속 진행) 이 변수에 의존하면 evidence
# 발급이 조용히 무의미해질 수 있다. 이 스크립트는
# plugins/rein-core/scripts/ 아래에 상주하므로, SCRIPT_DIR 의 부모가 곧
# plugin root(plugins/rein-core)다.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_REIN="$PLUGIN_ROOT/bin/rein"

# security-review-gate.sh 의 v1 위임과 정확히 동일한 env 계산
# (REIN_PROJECT_ROOT + REIN_POLICY_DIR=.rein/policy/security-axis) —
# bin/rein hook 이 `bin/rein hook` 을 통해 사용하는 것과 동일한
# 축 전용 정책 폴더를 가리켜야 v2 가 이 커밋의 security_review 요구를
# 올바르게 본다.
POLICY_DIR="$PROJECT_DIR/.rein/policy/security-axis"

# _msr_resolve_python — python3 탐색 하나로 통일 (print-digest / issuance
# 둘 다 사용).
_msr_resolve_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3'
    return 0
  fi
  return 1
}

if [ "$PRINT_DIGEST" -eq 1 ]; then
  # --print-digest — 부작용 없는 조회 전용. trail/dod 생성도, 표식 쓰기도,
  # 발급 시도도 하지 않는다. 위와 정확히 같은 PROJECT_DIR/POLICY_DIR/
  # BIN_REIN 을 써서 `bin/rein issue-evidence security_review --print-digest`
  # 를 호출하고 결과를 그대로 stdout 에 낸다.
  if [ ! -f "$BIN_REIN" ]; then
    echo "ERROR: [mark-security-reviewed] bin/rein not found at $BIN_REIN — cannot compute the review-start digest." >&2
    exit 1
  fi
  _msr_py="$(_msr_resolve_python)" || {
    echo "ERROR: [mark-security-reviewed] python3 not found — cannot compute the review-start digest." >&2
    exit 1
  }
  _msr_digest=""
  _msr_digest=$(REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$POLICY_DIR" \
    "$_msr_py" "$BIN_REIN" issue-evidence security_review --print-digest 2>/dev/null)
  _msr_rc=$?
  if [ "$_msr_rc" -ne 0 ] || [ -z "$_msr_digest" ]; then
    echo "ERROR: [mark-security-reviewed] failed to compute the review-start digest (bin/rein issue-evidence security_review --print-digest exited ${_msr_rc})." >&2
    exit 1
  fi
  printf '%s\n' "$_msr_digest"
  exit 0
fi

if [ "$PRINT_SUBJECT" -eq 1 ]; then
  # --print-subject — passthrough mode (Phase 7 웨이브 3 ③-a code review
  # round 3, Finding 2). 부작용 없는 조회 전용 — trail/dod 생성도, 표식
  # 쓰기도, 발급 시도도 하지 않는다(`--print-digest` 와 동일 성격). 위와
  # 정확히 같은 shared env 구성(PROJECT_DIR/POLICY_DIR/BIN_REIN, "Shared
  # env for issue-evidence calls" 절)을 써서 `bin/rein issue-evidence
  # security_review --print-subject` 를 호출하고, 그 stdout(`{"subject":
  # ..., "paths": [...]}` JSON 한 줄)을 그대로 통과시킨다 — 이 스크립트가
  # JSON 을 파싱·재가공하지 않는다(passthrough, 호출자인 `agents/
  # security-reviewer.md` 가 직접 파싱한다). `--print-digest` 는 이
  # 블록 도입 이후에도 계속 그대로 동작한다(기존 소비처 하위호환 —
  # digest 문자열 하나만 필요한 호출자는 여전히 `--print-digest` 를
  # 쓴다).
  if [ ! -f "$BIN_REIN" ]; then
    echo "ERROR: [mark-security-reviewed] bin/rein not found at $BIN_REIN — cannot compute the review-start subject snapshot." >&2
    exit 1
  fi
  _msr_py="$(_msr_resolve_python)" || {
    echo "ERROR: [mark-security-reviewed] python3 not found — cannot compute the review-start subject snapshot." >&2
    exit 1
  }
  _msr_subject_json=""
  _msr_subject_json=$(REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$POLICY_DIR" \
    "$_msr_py" "$BIN_REIN" issue-evidence security_review --print-subject 2>/dev/null)
  _msr_rc=$?
  if [ "$_msr_rc" -ne 0 ] || [ -z "$_msr_subject_json" ]; then
    echo "ERROR: [mark-security-reviewed] failed to compute the review-start subject snapshot (bin/rein issue-evidence security_review --print-subject exited ${_msr_rc})." >&2
    exit 1
  fi
  printf '%s\n' "$_msr_subject_json"
  exit 0
fi

# ============================================================================
# --- v2 evidence issuance (the sole record of a security review) ---
# ============================================================================
# Phase 7 웨이브 3 ③-d: this used to decide only whether a legacy stamp file
# (written unconditionally just above this point, in every earlier revision
# of this script) could be trusted — most outcomes were non-fatal because
# that file already sat on disk regardless of what v2 said. That write path
# is gone. v2 evidence issuance IS the review record now. Any outcome other
# than a clean issuance (rc=0) or the legitimate "nothing sensitive to
# review" no-op (digest=empty:no-subject) means NOTHING was recorded this
# cycle — the commit gate will see an unreviewed tree and block. This
# function therefore terminates the whole script (`exit`, not `return`) for
# every branch — once issuance has been attempted, there is no more
# "proceed anyway, the fallback still stands" path, because there is no
# fallback.
_msr_issue_evidence() {
  if [ ! -f "$BIN_REIN" ]; then
    echo "ERROR: [mark-security-reviewed] bin/rein not found at $BIN_REIN — cannot issue v2 evidence, so this cycle has NO review record. Fix the plugin install and re-run; the commit gate will block until evidence is issued." >&2
    exit 1
  fi

  local _msr_py=""
  _msr_py="$(_msr_resolve_python)" || {
    echo "ERROR: [mark-security-reviewed] python3 not found — cannot issue v2 evidence, so this cycle has NO review record. Install python3 and re-run; the commit gate will block until evidence is issued." >&2
    exit 1
  }

  # High finding (code review round 1) — this function does not self-
  # capture a digest at issuance time (after the review). A digest captured
  # here, at issuance time, would bless a mid-review staged change instead
  # of binding evidence to the state that was actually reviewed. The caller
  # (security-reviewer.md) captures the digest at review START (via this
  # script's own --print-digest mode, so it shares the exact same env) and
  # passes it via --reviewed-digest — issuance is attempted only when that
  # value is present and not a sentinel.
  if [ -z "$REVIEWED_DIGEST" ]; then
    echo "ERROR: [mark-security-reviewed] no --reviewed-digest was provided — cannot issue v2 evidence (no review-start digest to bind evidence to honestly). Nothing was recorded this cycle; re-run with --reviewed-digest set to the digest captured at review start." >&2
    exit 1
  fi

  case "$REVIEWED_DIGEST" in
    empty:no-subject)
      echo "NOTICE: [mark-security-reviewed] no sensitive target for this cycle right now (digest=empty:no-subject) — skipping v2 evidence issuance. This is expected when nothing security-sensitive is staged or changed; no record is needed." >&2
      exit 0
      ;;
    unresolved:no-subject)
      echo "ERROR: [mark-security-reviewed] the review subject could not be determined (digest=unresolved:no-subject) — cannot issue v2 evidence, so this cycle has NO review record. In a strict-profile repo, stage the reviewed changes (git add) and re-run." >&2
      exit 1
      ;;
  esac

  # bin/rein 이 발급 시점에 현재 digest 를 재계산해 위 REVIEWED_DIGEST(리뷰
  # 시작 시점 값)와 대조한다 — 불일치 시 exit 2 + reason=digest-mismatch 로
  # 거부한다. 그 재계산-대조 자체가 "리뷰 시작 시점 상태에 결속" 계약이다
  # (이 스크립트는 별도 대조 로직을 두지 않는다 — 중복 구현 금지).
  #
  # stdout/stderr 를 분리 포집한다 (합쳐 포집하면 refusal JSON 의 reason
  # 필드를 안정적으로 파싱할 수 없다 — stderr 진단 줄과 stdout JSON 줄이
  # 뒤섞일 수 있다). mktemp 실패 시에는 합쳐 포집(2>&1)으로 degrade — 발급
  # 자체는 계속 시도하되 reason 판별만 못 한다(비-digest-mismatch 로 간주,
  # fail-open 이 아니라 기존 방침대로 최대한 구체적 사유로 보고하려 시도한다
  # — 발급이 이미 실패했다는 사실 자체는 그대로 stderr 에 남는다).
  local _msr_err_f=""
  _msr_err_f="$(mktemp "${TMPDIR:-/tmp}/rein-msr-err.XXXXXX" 2>/dev/null)" || _msr_err_f=""

  local _msr_stdout _msr_stderr _msr_rc
  if [ -n "$_msr_err_f" ]; then
    _msr_stdout=$(REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$POLICY_DIR" \
      "$_msr_py" "$BIN_REIN" issue-evidence security_review --verdict PASS --reviewed-digest "$REVIEWED_DIGEST" 2>"$_msr_err_f")
    _msr_rc=$?
    _msr_stderr=$(cat "$_msr_err_f" 2>/dev/null)
    rm -f "$_msr_err_f"
  else
    _msr_stdout=$(REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$POLICY_DIR" \
      "$_msr_py" "$BIN_REIN" issue-evidence security_review --verdict PASS --reviewed-digest "$REVIEWED_DIGEST" 2>&1)
    _msr_rc=$?
    _msr_stderr=""
  fi
  local _msr_combined="$_msr_stdout"
  if [ -n "$_msr_stderr" ]; then
    _msr_combined="$_msr_combined
$_msr_stderr"
  fi

  case "$_msr_rc" in
    0)
      echo "OK: [mark-security-reviewed] v2 evidence issued for security_review (digest=${REVIEWED_DIGEST}) — level=$LEVEL cycle=$CYCLE." >&2
      exit 0
      ;;
    2)
      # High finding (code review round 3): fail-closed on an unparseable
      # exit-2 response. A parse failure (e.g. the tempfile-creation-
      # failure fallback above merging stdout+stderr, which corrupts the
      # JSON) must NOT fall through to "reason we can positively rule out
      # as digest-mismatch" — the only sound default when we cannot
      # POSITIVELY parse a reason other than digest-mismatch is to treat it
      # exactly like digest-mismatch. This is not limited to the
      # tempfile-failure path: any output-separation failure (or a
      # genuinely malformed/non-JSON response from bin/rein itself) hits
      # the same fail-closed branch, because `_msr_reason_ok` only flips to
      # 0 on a clean positive parse.
      local _msr_reason="" _msr_reason_ok=1
      _msr_reason=$(printf '%s' "$_msr_stdout" | "$_msr_py" -c '
import json, sys
try:
    obj = json.load(sys.stdin)
    reason = obj.get("reason")
    if not isinstance(reason, str) or not reason:
        raise ValueError("reason missing or not a non-empty string")
except Exception:
    sys.exit(1)
sys.stdout.write(reason)
' 2>/dev/null) && _msr_reason_ok=0
      if [ "$_msr_reason_ok" -ne 0 ] || [ "$_msr_reason" = "digest-mismatch" ]; then
        if [ "$_msr_reason_ok" -ne 0 ]; then
          echo "ERROR: [mark-security-reviewed] v2 evidence issuance refused (exit 2) but the response could not be positively parsed to a reason OTHER than digest-mismatch — treating as digest-mismatch (fail-closed). Nothing was recorded this cycle: $_msr_combined" >&2
        else
          echo "ERROR: [mark-security-reviewed] v2 evidence issuance refused (digest-mismatch) — the reviewed tree changed during the security review. Nothing was recorded this cycle; re-review the current tree: $_msr_combined" >&2
        fi
        exit 1
      fi
      # Any other POSITIVELY-parsed refusal reason (verdict-not-pass/
      # malformed/etc.) is an issuance-machinery condition, not evidence
      # the reviewed tree changed — but there is no legacy fallback left to
      # soften it with either. Nothing was recorded this cycle.
      echo "ERROR: [mark-security-reviewed] v2 evidence issuance was refused — nothing was recorded this cycle: $_msr_combined" >&2
      exit 1
      ;;
    *)
      echo "ERROR: [mark-security-reviewed] v2 evidence issuance did not complete (exit ${_msr_rc}) — nothing was recorded this cycle: $_msr_combined" >&2
      exit 1
      ;;
  esac
}

_msr_issue_evidence
# Unreachable — _msr_issue_evidence always terminates the script via `exit`.
exit 1
