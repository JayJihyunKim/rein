#!/bin/bash
# Hook: PreToolUse(Bash) - 위험 명령어 패턴 감지 및 차단
#
# Exit code protocol (2-tier):
#   정책 차단 11지점 [P1]~[P11]: exit 0 + JSON deny  (deny_emit via json-deny-emitter.sh)
#   인프라 무결성 5지점 [I1]~[I5]: exit 2 + stderr   (fail-closed infra errors, NOT converted)
#
# 분류 근거: docs/specs/2026-05-17-hook-message-assistant-tone.md §1
# 주의: exit 1 은 non-blocking error (통과됨). 차단은 exit 0+JSON deny 또는 exit 2

# --- Policy toggle (plugin mode only) ---
# .rein/policy/hooks.yaml can disable a hook via `<hook-name>: false`
# or `{ <hook-name>: { enabled: false } }`.
# Plugin mode: ${CLAUDE_PLUGIN_ROOT} is set, loader is invoked.
# Scaffold mode: env unset, check is skipped (preserves pre-policy behavior).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  if ! python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-bash-guard"; then
    exit 0  # disabled by user policy
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Optional libs for consumer-side coverage marker self-heal (DoD:
# dod-2026-05-15-pre-bash-guard-marker-self-heal). Source soft — if either is
# missing the revalidate helper falls back to "cannot revalidate" (rc=2),
# which preserves the legacy conservative block behavior.
. "$SCRIPT_DIR/lib/select-active-dod.sh" 2>/dev/null || true
. "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null || true
# shellcheck source=./lib/json-deny-emitter.sh
# [I6] infra integrity — emitter unavailable/corrupt, exit 2.
# Source the emitter and require it to define deny_emit as a shell FUNCTION.
# Using `declare -F deny_emit` (not `command -v`) is deliberate: command -v
# matches PATH executables, builtins, and aliases — any stray `deny_emit`
# binary on PATH would falsely pass the guard and then fail silently when
# called (rc=127, fail-open). declare -F only succeeds for shell functions
# defined in the current process, which is the sole valid form here.
# The source is NOT masked with `|| true`: if the file is missing or a
# parse error causes a non-zero exit, the `if !` condition catches it
# directly (set -e does not trigger inside an `if` condition expression).
if ! . "$SCRIPT_DIR/lib/json-deny-emitter.sh" 2>/dev/null \
   || ! declare -F deny_emit >/dev/null 2>&1; then
  echo "[rein] The Bash guard cannot run because the JSON deny emitter (lib/json-deny-emitter.sh) could not be loaded — it may be missing or corrupt. All policy checks are paused until the emitter is restored. Run 'rein update' to repair the installation." >&2
  exit 2
fi

BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"

log_block() {
  local reason="$1"
  local target="$2"
  # Guard: resolver 실패 경로에서 raw python3 재호출을 피함 (stderr noise 방지).
  # PYTHON_RUNNER 가 아직 set 되지 않았거나 비어있으면 logging 을 skip.
  if [ -z "${PYTHON_RUNNER+x}" ] || [ "${#PYTHON_RUNNER[@]}" -eq 0 ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  "${PYTHON_RUNNER[@]}" - "pre-bash-guard" "$reason" "$target" <<'PY' >> "$BLOCKS_LOG_JSONL" 2>/dev/null || true
import json, sys
from datetime import datetime, timezone
print(json.dumps({
  "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
  "hook": sys.argv[1],
  "reason": sys.argv[2],
  "target": sys.argv[3],
}, ensure_ascii=False))
PY

  # hook+reason 조합별로 카운트 (aggregate THRESHOLD 와 동일 기준).
  # 전체 hook 누적이 아닌 "동일 위반 패턴" 반복을 정확히 측정하기 위함.
  local count
  count=$("${PYTHON_RUNNER[@]}" -c "
import json, sys
target_hook = 'pre-bash-guard'
target_reason = sys.argv[1]
n = 0
try:
    with open(sys.argv[2]) as f:
        for line in f:
            try:
                e = json.loads(line)
                if e.get('hook') == target_hook and e.get('reason') == target_reason:
                    n += 1
            except Exception:
                continue
except OSError:
    pass
print(n)
" "$reason" "$BLOCKS_LOG_JSONL" 2>/dev/null || echo 0)
  if [ "$count" -ge 3 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

INPUT=$(cat)

# python3 필수 (JSON 파싱). 없으면 Bash gate 전체가 무력화되므로 fail-closed.
# 예전 `2>/dev/null` 방식은 python3 미설치 시 COMMAND="" → exit 0 으로 위험
# 명령어 차단 로직 전체가 비활성화됐음 (codex v0.7.2 review High).
# v0.10.1: Windows Git Bash/MSYS 의 `python3 exit 49` (= 9009 mod 256, App
# Execution Alias stub) 를 실제 JSON 파싱 실패와 구분하기 위해 strict
# resolver 기반으로 교체. exit code 10/11/12 로 원인 분기 + Windows 전용
# 진단 메시지. 파싱은 lib/extract-hook-json.py 로 위임 (inline python3 -c 제거).
# NOTE: bash `!` prefix resets $? to 0 after evaluation. To preserve the
# resolver's specific exit code (10/11/12) for diagnostic routing, capture
# $? immediately after the call BEFORE the conditional, not inside `if !`.
resolve_python
RESOLVER_RC=$?
if [ "$RESOLVER_RC" -ne 0 ]; then
  # [I1] infra integrity — exit 2 유지 (JSON deny 미전환): python3 resolver 실패
  # docs/specs/2026-05-17-hook-message-assistant-tone.md §1
  case "$RESOLVER_RC" in
    10) echo "[rein] The Bash guard cannot run because Python is not installed. Install Python 3 to restore all policy checks." >&2 ;;
    11) echo "[rein] The Bash guard cannot run because the Windows App Execution Alias Python stub was detected instead of a real Python installation. Install Python 3 from python.org or the Microsoft Store to proceed." >&2 ;;
    12) echo "[rein] The Bash guard cannot run because Python failed to launch (exit 9009 family) — this is common in Windows Git Bash or MSYS, or when REIN_PYTHON points to an invalid interpreter. Check your Python installation or unset REIN_PYTHON." >&2 ;;
  esac
  print_windows_diagnostics_if_applicable >&2
  log_block "python runtime unavailable" "unknown"
  exit 2
fi

COMMAND=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.command --default '')
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  # [I2] infra integrity — exit 2 유지 (JSON deny 미전환): hook 입력 JSON 파싱 실패
  echo "[rein] The Bash guard cannot read the tool input because the hook JSON could not be parsed (extract-hook-json.py exited $EXTRACT_RC). This is an installation issue — run 'rein update' to repair." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

if [ -z "$COMMAND" ]; then
  exit 0
fi

# command_invokes PATTERN
#   COMMAND 에서 PATTERN (명령 토큰들의 ERE alternation) 이 **명령 clause 시작
#   위치** 에 나타나면 0, 아니면 1 을 반환한다. clause 시작 = 문자열/행 시작
#   또는 shell 구분자 (`;` `&` `|` `(`, 그리고 `&&`/`||` 의 마지막 글자) 직후.
#   선행 `VAR=value` 환경 할당과 command wrapper (`env`/`sudo`/`command`/
#   `nohup`/`time`/`exec`) 를 허용한다 — `env FOO=1 pytest`,
#   `sudo git reset --hard` 같은 wrapper 가 붙은 실제 invocation 도 잡기 위함
#   (codex R1).
#
#   왜: 앵커 없는 substring 매칭은 키워드를 인자·값·텍스트로 담은 명령까지
#   분류기에 걸리게 해 과다 차단을 유발했다 — `grep "pytest"`,
#   `npm pkg set scripts.test=vitest`, `echo "git reset --hard"` (FU-4).
#   clause 시작 앵커는 실제 "실행" 과 단순 "언급" 을 구분해, 실제 invocation
#   (`pytest tests/`, `cd x && git commit`, `FOO=1 pytest`) 만 매치한다.
#
#   grep 은 입력을 행 단위로 처리하므로 `^` 가 각 행 시작에 대응한다. `[;&|(]`
#   한 글자 클래스가 단일 구분자와 `&&`/`||` 의 마지막 글자를 모두 포함한다.
#
#   알려진 한계 (codex R1): shell quoting 비인식 — quote 안의 `;`/`&&` 도
#   구분자로 본다. `echo "x; git reset --hard"` 처럼 quote 안에 구분자+키워드가
#   함께 든 드문 경우는 여전히 false-positive. 완전 해소는 shell 파서가 필요해
#   regex 분류기 범위 밖 (대다수 "언급" false-positive 는 이미 해소됨).
command_invokes() {
  local pattern="$1"
  printf '%s' "$COMMAND" | grep -qE \
    "(^|[;&|(])[[:space:]]*((env|sudo|command|nohup|time|exec)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*($pattern)"
}

# --- 즉시 차단: 파이프로 쉘 스크립트 실행 ---
# 정규식 의도:
#   - 파이프(`|`) **앞** 에 word-boundary (line 시작 또는 공백) → quote 안 substring
#     (`grep "x|bash y"`, `grep "x\\|bash y"`) false-positive 회피
#   - 파이프 뒤 bash/sh 토큰 + 공백 또는 라인 끝 → 'shadcn' 같이 sh-/bash- 로
#     시작하는 substring false-positive 회피 (기존 fix 유지)
# 차단 사유는 pipe 가 stdin 으로 임의 명령을 흘려넣어 hook 검증을 우회하는 경로이기 때문.
# 우회 (정상 패턴): file redirect 으로 명령 source 를 명시 — 'bash X.sh < /tmp/input.txt'.
if echo "$COMMAND" | grep -qE '(^|[[:space:]])\| *(bash|sh)( |$)'; then
  # [P1] policy block — JSON deny
  deny_emit "Piping a script into a shell was blocked because rein cannot verify where the piped command comes from. Use a file redirect instead: bash <script> < /tmp/<input>.txt" "PIPE_SHELL_BLOCKED" "$COMMAND"; rc=$?
  log_block "파이프 쉘 실행" "$COMMAND"
  exit "$rc"
fi

# --- 커밋 메시지 포맷 검증 ---
# merge/rebase commit은 면제
if echo "$COMMAND" | grep -qE "git (merge|rebase|am)"; then
  exit 0
fi

# --- Codex 리뷰 + 보안 리뷰 stamp 공통 검사 함수 ---
check_review_stamp() {
  local context="$1"  # "test" 또는 "commit"
  REVIEW_STAMP="$PROJECT_DIR/trail/dod/.codex-reviewed"
  SECURITY_STAMP="$PROJECT_DIR/trail/dod/.security-reviewed"
  DOD_DIR="$PROJECT_DIR/trail/dod"

  # DoD 파일이 없으면 (작업 중이 아니면) 검사 스킵
  DOD_EXISTS=false
  if [ -d "$DOD_DIR" ]; then
    for f in "$DOD_DIR"/dod-*.md; do
      [ -f "$f" ] || continue
      DOD_EXISTS=true
      break
    done
  fi
  [ "$DOD_EXISTS" = false ] && return 0

  # --- .review-pending 검증 (코드 편집 후 리뷰 필수) ---
  REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"
  if [ -f "$REVIEW_PENDING" ]; then
    if [ ! -f "$REVIEW_STAMP" ]; then
      # [P3] policy block — JSON deny. HIGH-2: exit directly (not return) so caller
      # cannot mistake "deny emitted (0)" for "stamp pass (0)".
      deny_emit "Source code was edited but the codex review has not been run yet. Run /codex-review to record the review before testing or committing." "REVIEW_PENDING_NO_STAMP" "$COMMAND"; rc=$?
      log_block "코드 편집 후 리뷰 미실행 (${context})" "$COMMAND"
      exit "$rc"
    fi

    # .codex-reviewed가 .review-pending보다 최신인지 검증
    PENDING_TIME=$(portable_mtime_epoch "$REVIEW_PENDING")
    REVIEW_TIME=$(portable_mtime_epoch "$REVIEW_STAMP")
    if [ "$REVIEW_TIME" -lt "$PENDING_TIME" ]; then
      # [P4] policy block — JSON deny. HIGH-2: exit directly.
      deny_emit "Code was edited after the last codex review. Re-run /codex-review to record a fresh review before testing or committing." "CODE_EDITED_AFTER_REVIEW" "$COMMAND"; rc=$?
      log_block "리뷰 후 코드 재수정 (${context})" "$COMMAND"
      exit "$rc"
    fi
  fi

  # --- escalated_to_human 감지 시 경고 (차단하지 않음) ---
  if grep -q "resolution: escalated_to_human" "$REVIEW_STAMP" 2>/dev/null; then
    echo "WARNING: 코드 리뷰가 사람 에스컬레이션 상태입니다. 수동 확인 후 진행하세요." >&2
  fi

  # --- Codex 리뷰 stamp 검사 ---
  # 시간 기반 TTL 은 제거 — .review-pending 비교가 "코드 변경 후 재리뷰" 를 정확히 담당한다
  if [ ! -f "$REVIEW_STAMP" ]; then
    # [P5] policy block — JSON deny. HIGH-2: exit directly.
    deny_emit "The codex review has not been recorded yet. Run /codex-review before ${context} — this creates the review record that rein requires before tests or commits." "CODEX_STAMP_MISSING" "$COMMAND"; rc=$?
    log_block "Codex 리뷰 미실행 (${context})" "$COMMAND"
    exit "$rc"
  fi

  # --- 보안 리뷰 stamp 검사 ---
  if [ ! -f "$SECURITY_STAMP" ]; then
    # [P6] policy block — JSON deny. HIGH-2: exit directly.
    deny_emit "The security review has not been recorded yet. Run the security-reviewer agent after codex review — this creates the security review record that rein requires before tests or commits." "SECURITY_STAMP_MISSING" "$COMMAND"; rc=$?
    log_block "보안 리뷰 미실행 (${context})" "$COMMAND"
    exit "$rc"
  fi


  return 0
}

# --- Coverage matrix gate (pytest/commit 차단, 리뷰 stamp 검사보다 선행) ---
# Plan A Phase 5 (GI-dod-mismatch-marker-consumer): BLOCK_MARKERS is an array
# so the guard consumes both the legacy plan-level marker and the new DoD-level
# marker. Advisory (non-blocking) markers like .dod-coverage-advisory must NOT
# be listed here — they are informational only and do not gate commits/tests.
# Iteration order determines which marker's message surfaces first when more
# than one is present; we keep legacy first for message stability.
BLOCK_MARKERS=(
  "$PROJECT_DIR/trail/dod/.coverage-mismatch"
  "$PROJECT_DIR/trail/dod/.dod-coverage-mismatch"
)

# Sanitize a path string read from a marker file before echoing to stderr.
# Defense-in-depth (security review INFO-1): although marker content already
# requires repo trust to modify, a hostile or corrupted marker could embed
# control chars / ANSI escapes / very long strings that pollute stderr +
# blocks.log. Normalize to a printable, length-bounded form before any echo.
#   - Strip non-printable / control chars (preserve normal whitespace handled
#     elsewhere; we only need a single-line target identifier here)
#   - Truncate to 200 chars (paths longer than this are almost certainly junk;
#     a real plan/DoD path fits well under this bound)
sanitize_marker_path() {
  printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200
}

# Consumer-side coverage marker self-heal. Returns:
#   0 — validator PASS for marker target(s); marker is stale and can be cleared
#   1 — validator FAIL; first failing target is echoed to stdout (sanitized)
#   2 — cannot revalidate (no target identifiable / lib missing / validator missing);
#       caller must conservatively block (legacy behavior)
# Rationale: prior behavior blocked any test/commit while the marker file existed,
# even when the underlying coverage failure had already been fixed (e.g. user
# fixed plan/DoD via a non-watching tool, or the marker was orphaned by a
# different work flow). consumer-side revalidate clears stale markers without
# weakening the discipline (real FAIL still blocks with target info).
revalidate_coverage_marker() {
  local marker="$1"
  local marker_basename
  marker_basename=$(basename "$marker")

  # plugin-aware validator resolution. If unavailable, fall back to legacy
  # conservative block.
  if ! command -v resolve_helper_script >/dev/null 2>&1; then
    return 2
  fi
  local validator
  validator=$(resolve_helper_script rein-validate-coverage-matrix.py 2>/dev/null || true)
  if [ -z "$validator" ] || [ ! -f "$validator" ]; then
    return 2
  fi

  case "$marker_basename" in
    .coverage-mismatch)
      # marker content: deduped lines of failed plan paths (post-edit-plan-coverage.sh).
      # Empty marker → cannot revalidate any target → conservative block.
      [ -s "$marker" ] || return 2
      local first_fail=""
      local validated_count=0
      local plan_path
      while IFS= read -r plan_path; do
        [ -z "$plan_path" ] && continue
        # If the plan file has been deleted, skip the validator call but DO NOT
        # treat the marker as healed — we have no positive PASS evidence for
        # this entry. The deleted path cannot block forever though: caller's
        # rc=2 path (returned below if no entry validated) preserves the
        # conservative block until a maintainer cleans up.
        [ -f "$plan_path" ] || continue
        validated_count=$((validated_count + 1))
        if ! "${PYTHON_RUNNER[@]}" "$validator" plan "$plan_path" >/dev/null 2>&1; then
          # Capture only the first failing path; full enumeration would
          # bloat the block message without adding actionable info.
          if [ -z "$first_fail" ]; then
            first_fail="$plan_path"
          fi
        fi
      done < "$marker"
      if [ -n "$first_fail" ]; then
        # INFO-1: sanitize before surfacing to caller (which echoes to stderr).
        sanitize_marker_path "$first_fail"
        return 1
      fi
      # Contract: rc=0 only when at least one validator invocation actually
      # PASSed. If every entry was skipped (all paths deleted), we have no
      # positive evidence and must fall through to conservative block.
      if [ "$validated_count" -eq 0 ]; then
        return 2
      fi
      return 0
      ;;
    .dod-coverage-mismatch)
      # Marker has no content (touch'd by pre-edit-dod-gate). Re-identify
      # active DoD via the shared selector and revalidate it.
      if ! command -v select_active_dod >/dev/null 2>&1; then
        return 2
      fi
      local result tier dod_path
      # selector reads trail/dod/.active-dod and walks trail/dod/ — both are
      # repo-relative, so cwd matters. Anchor to PROJECT_DIR.
      result=$(cd "$PROJECT_DIR" && select_active_dod 2>/dev/null) || return 2
      tier="${result%%$'\t'*}"
      dod_path=$(printf '%s' "$result" | awk -F'\t' '{print $2}')
      # Tier 0: no candidate. Tier 2: advisory fallback (the original Tier 1
      # active DoD that produced the marker may have been deleted/rotated).
      # Trust ONLY Tier 1 for self-heal — clearing the blocking marker based
      # on a Tier 2 fallback DoD risks healing a marker whose true source is
      # no longer identifiable.
      [ "$tier" = "1" ] || return 2
      [ -z "$dod_path" ] && return 2
      # Selector returns repo-relative path — anchor to PROJECT_DIR for
      # the on-disk check + validator invocation.
      local dod_abs="$PROJECT_DIR/$dod_path"
      [ -f "$dod_abs" ] || return 2
      if ! "${PYTHON_RUNNER[@]}" "$validator" dod "$dod_abs" >/dev/null 2>&1; then
        # INFO-1: sanitize before surfacing to caller.
        sanitize_marker_path "$dod_path"
        return 1
      fi
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

if command_invokes "pytest|jest|vitest|mocha|npm run test|npm test|yarn test|pnpm test|python -m pytest|npx jest|npx vitest|git commit|bash tests/"; then
  for marker in "${BLOCK_MARKERS[@]}"; do
    if [ -f "$marker" ]; then
      heal_target=$(revalidate_coverage_marker "$marker" 2>/dev/null)
      heal_rc=$?
      case "$heal_rc" in
        0)
          # Stale marker — validator now passes. Silent self-heal + continue
          # to the next marker (or fall through to remaining gates).
          rm -f "$marker"
          continue
          ;;
        1)
          # [P2] policy block — JSON deny: coverage validator FAIL (rc=1, identifiable target)
          marker_name=$(basename "$marker")
          deny_emit "The coverage check found that a plan or task record does not yet list this command's changes as implemented. Update the 'covers' list in the failing file to match what has actually been done, then re-run to clear the check automatically." "COVERAGE_MISMATCH" "$heal_target"; rc=$?
          log_block "coverage-mismatch" "$COMMAND"
          exit "$rc"
          ;;
        *)
          # [I3] infra integrity — exit 2 유지 (JSON deny 미전환): coverage marker target 식별 불가 (rc=2)
          # Cannot revalidate (no target / lib unavailable). Fall back to the
          # legacy conservative block — better to false-positive than silently
          # bypass coverage discipline.
          echo "[rein] A coverage check failure marker exists ($marker) but the target file inside it could not be identified. Fix the plan or task record so the validator can run, or remove the marker file directly if it is no longer relevant." >&2
          log_block "coverage-mismatch" "$COMMAND"
          exit 2
          ;;
      esac
    fi
  done
fi

# --- Codex 리뷰 stamp 검사 (테스트 실행 시) ---
if command_invokes "pytest|jest|vitest|mocha|npm run test|npm test|yarn test|pnpm test|python -m pytest|npx jest|npx vitest"; then
  if ! check_review_stamp "running tests"; then
    exit 2
  fi
fi

# --- Codex 리뷰 stamp 검사 (git commit 시) ---
if command_invokes "git commit"; then
  if ! check_review_stamp "committing"; then
    exit 2
  fi
fi

# 커밋 메시지 포맷 검증 (python3 helper 기반, 복합 명령 + heredoc + scope 지원)
# - 복합 명령에서 첫 "commit" 토큰 이후 구간만 분석 (다음 구분자 &&, ||, ;, | 전까지)
#   → 복합 명령의 tag 쪽 -m 을 오인하지 않음
# - heredoc 본문의 첫 줄을 multiline regex 로 정확히 추출
#   → $(cat <<'EOF' ... EOF) 형태 메시지도 올바로 검사됨
# - conventional commits scope 표기법 허용: type(scope)?: description
# 추출 로직 자체는 .claude/hooks/lib/extract-commit-msg.py 에 분리 (bash 의
# $(cmd <<HEREDOC) + `|| true` 파서 한계를 피하기 위함).
if command_invokes "git commit"; then
  EXTRACT_SCRIPT="$SCRIPT_DIR/lib/extract-commit-msg.py"
  # Helper 누락은 fail-open 으로 두지 않는다. heredoc 우회와 같은 silent
  # bypass 를 막기 위해, helper 가 없거나 python3 가 동작하지 않으면 BLOCK.
  if [ ! -f "$EXTRACT_SCRIPT" ]; then
    # [I4] infra integrity — exit 2 유지 (JSON deny 미전환): 커밋 메시지 검증 helper 누락
    echo "[rein] The commit message cannot be validated because the helper script is missing (expected at: $EXTRACT_SCRIPT). Run 'rein update' to restore the missing file." >&2
    log_block "commit msg helper 누락" "$EXTRACT_SCRIPT"
    exit 2
  fi
  # v0.10.1: python3 존재 여부는 파일 상단의 resolve_python() 이 이미 gate 했다.
  # 중복 `command -v python3` 체크 제거. PYTHON_RUNNER 배열은 이 시점에 set 되어
  # 있으며 strict-resolver 통과한 인터프리터이다. 배열 확장 `"${PYTHON_RUNNER[@]}"`
  # 로 token 경계를 보존해야 안전하다 (REIN_PYTHON 주입 방어).
  COMMIT_MSG=$("${PYTHON_RUNNER[@]}" "$EXTRACT_SCRIPT" "$COMMAND" 2>/dev/null)
  EXTRACT_RC=$?
  if [ "$EXTRACT_RC" -ne 0 ]; then
    # [I5] infra integrity — exit 2 유지 (JSON deny 미전환): 커밋 메시지 helper 실행 실패
    echo "[rein] The commit message could not be extracted because the helper script failed (exit $EXTRACT_RC). Check that Python is working correctly and run 'rein update' if the problem persists." >&2
    log_block "commit msg helper 실패" "$EXTRACT_SCRIPT"
    exit 2
  fi

  if [ -n "$COMMIT_MSG" ]; then
    FIRST_LINE=$(printf '%s' "$COMMIT_MSG" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$FIRST_LINE" ]; then
      if ! echo "$FIRST_LINE" | grep -qE "^(feat|fix|docs|refactor|test|chore)(\([a-zA-Z0-9_-]+\))?: .+"; then
        # Co-Authored-By 라인은 면제
        if ! echo "$FIRST_LINE" | grep -qE "^Co-Authored-By:"; then
          # [P7] policy block — JSON deny
          deny_emit "The commit message does not follow Conventional Commits format. Use: <type>(<scope>)?: <description> — where type is feat|fix|docs|refactor|test|chore and scope uses only letters, digits, underscores, or hyphens." "COMMIT_MSG_FORMAT" "$FIRST_LINE"; rc=$?
          log_block "커밋 메시지 포맷 위반" "$FIRST_LINE"
          exit "$rc"
        fi
      fi
    fi
  fi
fi

# --- .env 파일 읽기 차단 (cat, python 등으로 우회 방지) ---
# 분류기 clause-앵커링 + fail-closed (FU-4, codex R1): read verb 가 clause
# 시작에 있고 같은 clause 안에서 .env 계열 파일 (.env / .env.<무엇이든> /
# .envrc) 을 가리키면 차단한다. 단 키만 담은 안전한 템플릿
# (.env.example/.sample/.template/.dist — security rules §환경변수 관리) 만
# 참조하면 통과 — 안전 접미사 토큰을 명시 제거한 뒤에도 .env 계열이 남으면
# 시크릿 파일로 본다 (allow-by-omission 이 아니라 deny-by-default —
# .env.secret/.env.bak 같은 미등록 변형도 fail-closed 로 차단).
# strip 은 안전 접미사 **뒤에 token 경계** (`[^[:alnum:]._-]` 또는 행 끝) 를
# 요구한다 (codex R2): `.env.example.secret`·`.env.examples`·`.env.dist.bak`
# 처럼 안전 토큰을 prefix 로만 가진 더 긴 파일명은 제거되지 않아 차단된다.
if command_invokes "(cat|head|tail|less|more|python[23]?|node)[[:space:]]+[^;&|]*(\.envrc|\.env([^[:alnum:]._-]|\$|\.))"; then
  ENV_RESIDUAL=$(printf '%s' "$COMMAND" | sed -E 's/\.env\.(example|sample|template|dist)([^[:alnum:]._-]|$)/\2/g')
  if printf '%s' "$ENV_RESIDUAL" | grep -qE '\.envrc|\.env([^[:alnum:]._-]|$|\.)'; then
    # [P8] policy block — JSON deny
    deny_emit "Reading a .env file with a shell command was blocked to prevent secrets from leaking into the session. Access environment variables through your application's config loader instead." "ENV_READ_BLOCKED" "$COMMAND"; rc=$?
    log_block ".env Bash 읽기 시도" "$COMMAND"
    exit "$rc"
  fi
fi

# --- .env 파일 커밋 방지 ---
if echo "$COMMAND" | grep -qE "git add"; then
  if echo "$COMMAND" | grep -qE "git add (-A|\.(\s|$|\|)|\.env)"; then
    if [ -f "$PROJECT_DIR/.env" ] || ls "$PROJECT_DIR"/.env.* 1>/dev/null 2>&1; then
      # [P9] policy block — JSON deny
      deny_emit "A .env file exists in the repo root and this git add command would stage it. Stage files individually by name to avoid committing secrets." "ENV_STAGE_BLOCKED" "$COMMAND"; rc=$?
      log_block ".env 스테이징 시도" "$COMMAND"
      exit "$rc"
    fi
  fi
fi

# git commit -am
if echo "$COMMAND" | grep -qE "git commit.*-[a-z]*a[a-z]*m"; then
  if [ -f "$PROJECT_DIR/.env" ] || ls "$PROJECT_DIR"/.env.* 1>/dev/null 2>&1; then
    # [P10] policy block — JSON deny
    deny_emit "A .env file exists in the repo root and git commit -am would include it. Use git add <files> to stage only the files you intend to commit." "ENV_COMMIT_AM_BLOCKED" "$COMMAND"; rc=$?
    log_block ".env 포함 commit -am" "$COMMAND"
    exit "$rc"
  fi
fi

# --- 확인 요청: 파괴적 git 명령어 ---
# 분류기 clause-앵커링 (FU-4): 실제 git 명령 invocation 만 매치한다 — echo/grep
# 등에 텍스트로 들어간 "git reset --hard" 언급은 제외. push.*-f 의 `.*` 는
# clause 를 넘지 않도록 `[^;&|]*` 로 좁힌다 (다른 clause 의 `rm -rf` 오매치 방지).
if command_invokes "git (reset --hard|push --force|push[^;&|]*-f( |\$)|checkout -- |restore )"; then
  # [P11] policy block — JSON deny
  deny_emit "This git command permanently discards work and cannot be undone after it runs. Before proceeding, confirm with the user that the intention is clear: what will be lost and why that is acceptable. If the user confirms, re-issue the command." "DESTRUCTIVE_GIT_CONFIRM" "$COMMAND"; rc=$?
  log_block "파괴적 git 명령" "$COMMAND"
  exit "$rc"
fi

exit 0
