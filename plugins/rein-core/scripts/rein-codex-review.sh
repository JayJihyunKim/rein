#!/usr/bin/env bash
# scripts/rein-codex-review.sh
#
# /codex-review wrapper — context assembly + envelope + codex exec + stamp.
#
# Scope IDs:
#   - GI-codex-review-context-assembly
#   - GI-codex-review-envelope-slots
#   - GI-codex-review-diff-base
#   - GI-codex-review-envelope-context-missing
#   - GI-codex-review-wrapper-script
#
# CRITICAL invariant (Plan A Phase 6 Task 6.3 Step 3, spec B / SKILL §6.6):
#   In spec-review mode, this wrapper MUST NOT create or modify
#   trail/dod/.codex-reviewed, and MUST NOT touch trail/dod/.review-pending.
#   The test/commit Bash gate depends on .codex-reviewed as a
#   code-review stamp — spec-review writes would let reviewers bypass the
#   gate without a real code review. Regression tests live in
#   tests/skills/test-codex-review-wrapper.sh (verifications 5 + 6).
#
# Injection seam (test hook):
#   CODEX_BIN — path to the codex binary. Defaults to the first `codex`
#   on PATH. Tests override with tests/fixtures/fake-codex.sh.
#
# Usage:
#   bash scripts/rein-codex-review.sh
#       Interactive code review. Caller provides the prompt body on stdin.
#   bash scripts/rein-codex-review.sh --non-interactive
#       Automated call (agent). Prefix [NON_INTERACTIVE] added to envelope.
#   echo "[NON_INTERACTIVE] spec review for plan: docs/plans/foo.md" \
#     | bash scripts/rein-codex-review.sh --non-interactive
#       Spec-review mode (plan). No stamp written.
#   echo "[NON_INTERACTIVE] spec review for design: docs/specs/foo.md" \
#     | bash scripts/rein-codex-review.sh --non-interactive
#       Spec-review mode (design). No stamp written.

set -euo pipefail

# ---- Locate project dir + select-active-dod library. -----------------
#
# Layout probe: plugin tree has hooks/lib as sibling of scripts/. Legacy
# scaffold tree has .claude/hooks/lib at the project root. We pick the
# plugin-bundled lib whenever it exists so the wrapper is self-contained
# (user repo no longer needs scaffold files after v1.0.1 declarative drop).
#
# PROJECT_DIR is the user repo (trail/dod, .rein/, .claude/cache target).
# - REIN_PROJECT_DIR_OVERRIDE: test sandbox override.
# - Plugin mode: CLAUDE_PROJECT_DIR (set by Claude Code) → CWD fallback.
# - Scaffold mode (legacy): script's parent IS the project root.

_script_dir=$(cd "$(dirname "$0")" && pwd)

if [ -f "$_script_dir/../hooks/lib/select-active-dod.sh" ]; then
  _select_active_dod_lib=$(cd "$_script_dir/.." && pwd)/hooks/lib/select-active-dod.sh
  PROJECT_DIR="${REIN_PROJECT_DIR_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$PWD}}"
else
  PROJECT_DIR="${REIN_PROJECT_DIR_OVERRIDE:-$(cd "$_script_dir/.." && pwd)}"
  if [ -f "$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    _select_active_dod_lib="$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  else
    _select_active_dod_lib="$PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  fi
fi

# PD-2 (2026-05-19): sanity-check PROJECT_DIR before cd'ing into it and
# stamping there. The inline resolution above falls back to $PWD when
# CLAUDE_PROJECT_DIR is unset — if the wrapper is invoked from the wrong
# directory that silently makes codex review an unrelated tree and writes
# the .codex-reviewed stamp outside the repo. Fail loudly instead.
#   - trail/ must exist (every rein project root has it).
#   - if PROJECT_DIR is inside a git repo, it must BE the toplevel (a
#     subdirectory would put trail/dod writes off the repo root).
#   - if PROJECT_DIR is not a git repo at all (scaffold / test sandbox),
#     skip the toplevel check — the trail/ check alone is sufficient.
if [ ! -d "$PROJECT_DIR/trail" ]; then
  echo "ERROR: [codex-review] resolved PROJECT_DIR has no trail/ directory: $PROJECT_DIR" >&2
  echo "ERROR: [codex-review] set CLAUDE_PROJECT_DIR or run from the repo root before invoking codex review." >&2
  exit 2
fi
_pd_toplevel=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$_pd_toplevel" ]; then
  # Canonicalize both sides so /tmp vs /private/tmp symlinks don't false-flag.
  _pd_canon=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P || printf '%s' "$PROJECT_DIR")
  _pd_top_canon=$(cd "$_pd_toplevel" 2>/dev/null && pwd -P || printf '%s' "$_pd_toplevel")
  if [ "$_pd_canon" != "$_pd_top_canon" ]; then
    echo "ERROR: [codex-review] PROJECT_DIR ($PROJECT_DIR) is not the git repo root ($_pd_toplevel)." >&2
    echo "ERROR: [codex-review] set CLAUDE_PROJECT_DIR or run from the repo root before invoking codex review." >&2
    exit 2
  fi
fi

# If invoked from outside PROJECT_DIR, still operate on PROJECT_DIR so
# select_active_dod reads the correct trail/dod.
cd "$PROJECT_DIR"

# ---- Inject the shared DoD selector (Phase 4.1 library). --------------

# Fail-closed if library missing, unreadable, or broken (BUG-WRAP-SOURCE,
# 2026-05-29). The earlier `if ! . <lib> 2>/dev/null` form did NOT fail
# closed under `set -e`: the `source` builtin's "cannot read source file"
# error path interacts with errexit so the script exits BEFORE reaching the
# then-block — yielding a silent exit 1 with no diagnostic, instead of the
# intended ERROR + exit 2. (codex 실측: `set +e` 통과, `set -e` 차단.)
# Robust fix (codex-recommended): an `[ ! -r ]` readability precheck PLUS a
# subshell that both sources the lib and verifies the core function is
# defined. `[ ! -f ]` alone leaves unreadable / syntax-error / internal-fail
# holes; the subshell check closes them. The real `. <lib>` then runs at top
# level so the function is available to the rest of the wrapper.
if [ ! -r "$_select_active_dod_lib" ] || \
   ! ( . "$_select_active_dod_lib"; declare -F select_active_dod >/dev/null ) 2>/dev/null; then
  echo "ERROR: [codex-review] missing or invalid select-active-dod library at $_select_active_dod_lib" >&2
  exit 2
fi
. "$_select_active_dod_lib"

# ---- Load codex model single-source-of-truth. -------------------------
#
# 모델명은 plugins/rein-core/config/codex-models.sh 한 곳에서 관리한다
# (역할 프로필 구조 — spec 2026-07-10 §4.1). 래퍼는 게이트 프로필
# CODE_GATE_MODEL(고정 모델) / CODE_FAIL_CLOSED_EFFORT(측정 실패 폴백) 를
# 읽어 codex 호출에 반영한다. config 전 후보 부재 시에도 무모델 호출로
# degrade 하지 않는다 — 아래 래퍼 내장 canonical 상수로 명시 폴백한다
# (canonical fallback, spec §4.2).
#
# 경로 해석은 location-agnostic — 이 스크립트는 두 위치에 byte-identical
# 사본으로 존재한다(plugin SSOT `plugins/rein-core/scripts/` + 메인테이너
# repo fallback `scripts/`, test-plugin-scripts-bundle.sh 가 동일성 강제).
# 따라서 *같은* 코드가 두 레이아웃 모두에서 SSOT 를 찾아야 한다:
#   - plugin 위치: $_script_dir/../config (plugins/rein-core/scripts → plugins/rein-core/config)
#   - repo 루트 위치: $_script_dir/../plugins/rein-core/config (scripts → plugins/rein-core/config)
#   - 설치 사용자: $CLAUDE_PLUGIN_ROOT/config (설정 시에만 시도)
# 첫 readable 후보에서 source 후 break. 모두 부재면 canonical fallback.

# 래퍼 내장 canonical 상수 — config 전 후보 부재 시의 명시 폴백.
# 게이트가 "codex 기본 모델" 이라는 외부 가변값에 좌우되지 않도록
# (게이트 예측 가능성), 무모델 호출을 금지한다.
REIN_CANONICAL_GATE_MODEL="gpt-5.6-sol"
REIN_CANONICAL_GATE_EFFORT="high"

CODE_GATE_MODEL=""; CODE_FAIL_CLOSED_EFFORT=""
CODE_MODEL=""; CODE_EFFORT=""; CODE_ROUTING_POLICY_VERSION=""
# Candidates built into a real array so each element survives whitespace in the
# install path (B-quote, Round 5 2026-06-09): the earlier `for ... in` list used
# `${CLAUDE_PLUGIN_ROOT:+"…"}` UNQUOTED, so a CLAUDE_PLUGIN_ROOT containing a
# space word-split into multiple bogus candidates (and the real path was never
# tried). The CLAUDE_PLUGIN_ROOT candidate is appended only when the variable is
# set+non-empty, preserving the "try only when configured" semantics.
_codex_models_candidates=(
  "$_script_dir/../config/codex-models.sh"
  "$_script_dir/../plugins/rein-core/config/codex-models.sh"
)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _codex_models_candidates+=("$CLAUDE_PLUGIN_ROOT/config/codex-models.sh")
fi
for _codex_models_conf in "${_codex_models_candidates[@]}"; do
  if [ -r "$_codex_models_conf" ]; then
    # shellcheck source=/dev/null
    . "$_codex_models_conf"
    break
  fi
done
unset _codex_models_candidates

# 이름 해석 우선순위: 신 변수 → legacy(구버전 사용자 config 호환) → canonical.
# stderr 경고는 전 후보 부재 시 정확히 1회 — config 정상 로드 시 무발화.
CODE_GATE_MODEL="${CODE_GATE_MODEL:-${CODE_MODEL:-}}"
CODE_FAIL_CLOSED_EFFORT="${CODE_FAIL_CLOSED_EFFORT:-${CODE_EFFORT:-}}"
if [ -z "$CODE_GATE_MODEL" ]; then
  echo "WARNING: [codex-review] codex-models.sh not found/empty in all candidates; falling back to built-in canonical ${REIN_CANONICAL_GATE_MODEL} + ${REIN_CANONICAL_GATE_EFFORT}" >&2
  CODE_GATE_MODEL="$REIN_CANONICAL_GATE_MODEL"
fi
CODE_FAIL_CLOSED_EFFORT="${CODE_FAIL_CLOSED_EFFORT:-$REIN_CANONICAL_GATE_EFFORT}"

# ---- Review-readiness precheck (spec 2026-07-13 review-evidence-manifest).
#
# Scope IDs: EV1~EV6 (evidence block parser / quant-claim scanner /
# readiness disposition / exit 4 contract / envelope manifest slots).
#
# 함수 3종(_parse_evidence_blocks / _scan_quant_claims / _readiness_check)은
# 호출 지점(모드 감지 직후)보다 반드시 **위**에 정의한다 — bash 는 후행 정의
# 함수를 호출할 수 없다 (command not found → 오거부).
#
# 규율 (plan Phase 1 계약):
#   - awk → shell 결과 전달은 구획별 **별도 임시파일** (요약 key=value /
#     블록당 3줄 레코드 / 마스킹 본문 통짜). 단일 파일 구분선 방식 금지.
#   - 임시파일은 생성 즉시 cleanup 목록 등록 + trap EXIT 전 경로 정리.
#   - errexit 억제 대응: 호출부가 `_readiness_check || exit 4` 이므로 이
#     스택 전체에서 set -e 가 억제된다 — 모든 외부 명령에 명시 전파.
#   - 인프라 실패(awk/mktemp 비정상 종료)는 [readiness-reject] 태그 **없는**
#     plain ERROR + 실패 반환 (fail-open 금지 + 판별 계약 오분류 방지).
#   - 파이프라인 내 grep -q 금지 (SIGPIPE fail-open 클래스). 바이트 계수는
#     LC_ALL=C awk length() (UTF-8 원시 바이트 + 줄당 LF 포함).

_REIN_TMP_FILES=()
_rein_cleanup_tmp() {
  local _f
  for _f in ${_REIN_TMP_FILES[@]+"${_REIN_TMP_FILES[@]}"}; do
    rm -f "$_f" 2>/dev/null || true
  done
}
# source-and-call(테스트) 경로에서는 호출자 shell 의 기존 EXIT trap 을 덮어쓰지
# 않는다 — 실행형 경로에서만 등록. sourced 호출자는 함수 사용 후
# _rein_cleanup_tmp 를 직접 호출해 정리할 책임을 진다 (codex 통합리뷰 R1 Low).
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  trap _rein_cleanup_tmp EXIT
fi

# 공용 awk 함수 (parser/scanner 두 awk 프로그램 앞에 문자열 결합으로 주입) —
# LC_ALL=C byte substr 절단 후 끝의 불완전 UTF-8 시퀀스를 제거해 문자 경계를
# 보존한다 (codex 통합리뷰 R3/R6 Medium: 발췌·진단의 invalid UTF-8 전파 차단).
_REIN_AWK_UTF8TRIM='
function utf8trim(ex,   exlen, ti, b, ntail, conts) {
  exlen = length(ex); ti = exlen
  while (ti > 0) { b = substr(ex, ti, 1); if (b >= "\200" && b < "\300") ti--; else break }
  ntail = exlen - ti
  if (ti == 0) return ""
  b = substr(ex, ti, 1)
  if (b >= "\300") { conts = (b >= "\360") ? 3 : (b >= "\340") ? 2 : 1; if (ntail < conts) return substr(ex, 1, ti - 1) }
  else if (ntail > 0) return substr(ex, 1, ti)
  return ex
}'

# _rein_mktemp <varname> — 임시파일 생성 + cleanup 목록 등록 + 경로를 varname 에
# 저장. 값 반환에 command substitution 을 쓰면 등록이 서브셸에 갇히므로
# printf -v 로 부모 셸 변수에 직접 쓴다.
_rein_mktemp() {
  local __f rc
  __f=$(mktemp "${TMPDIR:-/tmp}/rein-readiness.XXXXXX") || {
    rc=$?
    echo "ERROR: [codex-review] readiness precheck: mktemp failed (rc=$rc)" >&2
    return "$rc"
  }
  _REIN_TMP_FILES+=("$__f")
  printf -v "$1" '%s' "$__f"
}

# _parse_evidence_blocks — [EVIDENCE] 블록 파서 + 형식 검증 (spec §4.1 규칙 0~8).
# 단일 좌→우 라인 스캔 4상태 상태기계: outside / outside-fence-open /
# in-block-fields / in-block-output. fence 토글은 블록 밖에서만 유효, 블록 안의
# ``` 는 일반 텍스트.
#
# 입력: PROMPT_BODY (전역 — [EFFORT:] strip 이후 원문, spec §4.3).
# 성공(return 0) 시 전역 산출:
#   EVIDENCE_BLOCK_COUNT   — 유효 블록 수
#   EVIDENCE_BLOCK_SUMMARY — 블록당 3줄(claim/command/exit_code) 레코드
#   REIN_EV_MASKED_FILE    — 마스킹 본문 (블록 내부 + fence 내부 치환, 라인수 보존)
# 형식 위반(return 1): anchored 접두사 거부 진단행을 stderr 로 방출.
# 인프라 실패(return rc≠0): 태그 없는 plain ERROR + 실패 전파.
_parse_evidence_blocks() {
  local rc in_f="" sum_f="" blk_f="" mask_f="" vio_f=""
  _rein_mktemp in_f   || return $?
  _rein_mktemp sum_f  || return $?
  _rein_mktemp blk_f  || return $?
  _rein_mktemp mask_f || return $?
  _rein_mktemp vio_f  || return $?

  printf '%s' "$PROMPT_BODY" > "$in_f" || {
    rc=$?
    echo "ERROR: [codex-review] readiness precheck: prompt spool write failed (rc=$rc)" >&2
    return "$rc"
  }

  LC_ALL=C awk -v maskf="$mask_f" -v blkf="$blk_f" -v sumf="$sum_f" -v viof="$vio_f" "$_REIN_AWK_UTF8TRIM"'
    function fldname(i) {
      if (i == 1) return "claim:"
      if (i == 2) return "command:"
      if (i == 3) return "exit_code:"
      return "output:"
    }
    function san(s) {
      gsub(/\[readiness-reject\]/, "[readiness-…]", s)
      gsub(/\[readiness-advisory\]/, "[readiness-…]", s)
      return s
    }
    BEGIN { state = 0; f = 0; nb = 0; vc = 0; open_line = 0 }
    {
      line = $0
      if (state == 0) {
        if (line ~ /^[[:space:]]*\[EVIDENCE\][[:space:]]*$/) {
          state = 2; f = 1; bclaim = ""; bcmd = ""; bec = ""; open_line = NR
          print "" > maskf; next
        }
        if (line ~ /^[[:space:]]*\[\/EVIDENCE\][[:space:]]*$/) {
          vc++; print "L" NR ": 고아 [/EVIDENCE] — 대응하는 [EVIDENCE] 없음" > viof
          print "" > maskf; next
        }
        if (line ~ /^ {0,3}```/) {
          # 여는 fence (CommonMark): 선행 공백 0~3칸 + 백틱 런 ≥3, backtick
          # fence 의 info string 에는 백틱 금지 — 아니면 fence 가 아니라 일반
          # 텍스트다 (codex 통합리뷰 R7 High: 과도한 opener 가 EOF 까지
          # 마스킹해 EV2 우회). 런 길이는 닫는 fence 판정에 기억 (R4).
          tmpl = line; sub(/^ {0,3}/, "", tmpl)
          fl = 0
          while (substr(tmpl, fl + 1, 1) == "`") fl++
          info = substr(tmpl, fl + 1)
          if (info !~ /`/) {
            fence_len = fl
            state = 1; print "" > maskf; next
          }
          # info string 에 백틱 → fence 아님 — 일반 텍스트로 계속 처리.
        }
        print line > maskf; next
      }
      if (state == 1) {
        # 닫는 fence: 선행 공백 0~3칸 + 백틱 런 길이 >= 여는 길이 + 뒤에 공백만.
        if (line ~ /^ {0,3}`/) {
          tmpl = line; sub(/^ {0,3}/, "", tmpl)
          run = 0
          while (substr(tmpl, run + 1, 1) == "`") run++
          rest_after = substr(tmpl, run + 1)
          if (run >= fence_len && rest_after ~ /^[[:space:]]*$/) state = 0
        }
        print "" > maskf; next
      }
      if (state == 2) {
        print "" > maskf
        if (line ~ /^[[:space:]]*\[EVIDENCE\][[:space:]]*$/) {
          vc++; print "L" NR ": 블록 중첩 금지 — L" open_line " 블록이 닫히기 전 [EVIDENCE] 재등장" > viof
          next
        }
        if (line ~ /^[[:space:]]*\[\/EVIDENCE\][[:space:]]*$/) {
          vc++; print "L" NR ": 필수 필드 누락 — L" open_line " 블록이 " fldname(f) " 필드 전에 폐쇄됨" > viof
          state = 0; next
        }
        d = 0
        if (line ~ /^[[:space:]]*claim:/) d = 1
        else if (line ~ /^[[:space:]]*command:/) d = 2
        else if (line ~ /^[[:space:]]*exit_code:/) d = 3
        else if (line ~ /^[[:space:]]*output:/) d = 4
        if (d == 0) {
          vc++; print "L" NR ": 필드 순서 위반 — 기대 " fldname(f) " 위치에 알 수 없는 라인: " san(utf8trim(substr(line, 1, 80))) > viof
          next
        }
        if (d < f) {
          vc++; print "L" NR ": 필드 중복/순서 위반 — " fldname(d) " 재등장 (기대: " fldname(f) ")" > viof
          next
        }
        if (d > f) {
          vc++; print "L" NR ": 필드 순서 위반/누락 — 기대 " fldname(f) " 이전에 " fldname(d) " 등장" > viof
          f = d + 1
          if (d == 4) { state = 3; olines = 0; obytes = 0 }
          next
        }
        val = line
        sub(/^[[:space:]]*[a-z_]+:[[:space:]]*/, "", val)
        if (d == 1) {
          if (val == "") { vc++; print "L" NR ": claim: 비어있음" > viof }
          bclaim = val; f = 2; next
        }
        if (d == 2) {
          if (val == "") { vc++; print "L" NR ": command: 비어있음" > viof }
          bcmd = val; f = 3; next
        }
        if (d == 3) {
          if (val !~ /^[0-9]+$/ || val + 0 > 255) {
            vc++; print "L" NR ": exit_code: 0–255 정수가 아님 (" san(utf8trim(substr(val, 1, 20))) ")" > viof
          }
          bec = val; f = 4; next
        }
        if (val != "") { vc++; print "L" NR ": output: 라인에 내용 — 출력 원문은 다음 줄부터 (형식 위반)" > viof }
        state = 3; olines = 0; obytes = 0; next
      }
      # state == 3 (output 영역 — fence 토글 없음, ``` 는 일반 텍스트)
      print "" > maskf
      if (line ~ /^[[:space:]]*\[\/EVIDENCE\][[:space:]]*$/) {
        if (olines > 60) {
          vc++; print "L" open_line ": output " olines "줄 — 상한 60줄 초과. tail/grep 으로 관련 발췌만 남겨라 (래퍼는 요청서를 절단하지 않는다)" > viof
        }
        if (obytes > 8000) {
          vc++; print "L" open_line ": output " obytes "바이트 — 상한 8000바이트 초과 (줄당 LF 포함 UTF-8 바이트). tail/grep 으로 관련 발췌만 남겨라" > viof
        }
        nb++
        print bclaim > blkf; print bcmd > blkf; print bec > blkf
        state = 0; next
      }
      if (line ~ /^[[:space:]]*\[EVIDENCE\][[:space:]]*$/) {
        vc++; print "L" NR ": 블록 중첩 금지 — output 영역 안 [EVIDENCE] 단독 라인" > viof
        next
      }
      olines++; obytes += length(line) + 1
      next
    }
    END {
      if (state == 2 || state == 3) { vc++; print "L" open_line ": 미폐쇄 블록 — [/EVIDENCE] 없음" > viof }
      if (nb > 16) { vc++; print "블록 수 " nb "개 — 상한 16개 초과 (요청서당 유효 블록 16개 이하)" > viof }
      print "count=" nb > sumf
      print "violations=" vc > sumf
    }
  ' "$in_f" || {
    rc=$?
    echo "ERROR: [codex-review] readiness precheck: evidence parser (awk) failed (rc=$rc)" >&2
    return "$rc"
  }

  local count="" viol="" line
  while IFS= read -r line; do
    case "$line" in
      count=*) count="${line#count=}" ;;
      violations=*) viol="${line#violations=}" ;;
    esac
  done < "$sum_f"
  case "$count" in
    '' | *[!0-9]*)
      echo "ERROR: [codex-review] readiness precheck: parser summary corrupt (count='$count')" >&2
      return 1 ;;
  esac
  case "$viol" in
    '' | *[!0-9]*)
      echo "ERROR: [codex-review] readiness precheck: parser summary corrupt (violations='$viol')" >&2
      return 1 ;;
  esac

  if [ "$viol" -gt 0 ]; then
    echo "ERROR: [codex-review][readiness-reject] 증거 블록 형식 위반 ${viol}건 (codex 미호출)" >&2
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "ERROR: [codex-review][readiness-reject]   $line" >&2
    done < "$vio_f"
    echo "ERROR: [codex-review][readiness-reject]   → [EVIDENCE] claim/command/exit_code/output 블록 문법을 교정 후 재호출하라. 문법: SKILL.md §4.1" >&2
    return 1
  fi

  EVIDENCE_BLOCK_COUNT="$count"
  EVIDENCE_BLOCK_SUMMARY=$(cat "$blk_f" 2>/dev/null) || {
    rc=$?
    echo "ERROR: [codex-review] readiness precheck: block summary read failed (rc=$rc)" >&2
    return "$rc"
  }
  REIN_EV_MASKED_FILE="$mask_f"
  return 0
}

# _scan_quant_claims — 정량/PASS 패턴 엔진 (spec §4.2). 입력은 파서가 남긴
# 마스킹 본문(블록 내부 + fence 내부 치환 완료). 인라인 백틱 스팬 마스킹은
# 이 함수가 첫 단계로 자체 수행 (spec §4.1 규칙 0 — 패턴 스캐너 전용).
# 제외 마스킹(스캔 전): 경로 토큰(순수 [0-9]+/[0-9]+ 비율은 예외), ISO 날짜,
# semver/§절 참조, L<n>, exit (code )?<n>, 영숫자·하이픈 전용 + 하이픈 ≥2 토큰.
# 매칭: Q1 수량+단위 / Q2 비율·백분율 / Q3 PASS 공존 (case-insensitive, 라인 단위).
# 성공(return 0) 시 전역 산출:
#   QUANT_MATCH_COUNT — 매칭 라인 총계
#   QUANT_FLAGS       — "L<n>: <발췌 80자>" 목록 (최대 10건, 예약 태그 소독)
_scan_quant_claims() {
  local rc sum_f="" flg_f=""
  _rein_mktemp sum_f || return $?
  _rein_mktemp flg_f || return $?

  LC_ALL=C awk -v sumf="$sum_f" -v flgf="$flg_f" "$_REIN_AWK_UTF8TRIM"'
    BEGIN { m = 0; kept = 0; nrl = 0 }
    { nrl++; origbuf[nrl] = $0; docbuf[nrl] = $0 }
    END {
      # 인라인 코드 스팬 마스킹 (패턴 스캐너 전용, spec §4.1 규칙 0) —
      # CommonMark 규약대로 **문서 전체** 에서 임의 길이 백틱 런을 정확히
      # 같은 길이의 닫는 런과 짝짓는다. 스팬은 여러 줄에 걸칠 수 있으므로
      # (codex 통합리뷰 R5 Medium) 라인 경계를 넘어 마스킹하되 개행은
      # 보존해 라인 번호를 유지한다. 닫는 런이 문서 어디에도 없으면
      # 불균형 — 런만 제거하고 내용은 노출 (실주장 탐지 유지, R3 합의).
      doc = ""
      for (r = 1; r <= nrl; r++) doc = doc origbuf[r] ((r < nrl) ? "\n" : "")
      maskeddoc = ""
      rest0 = doc
      while (match(rest0, /`+/)) {
        # backslash-escape (CommonMark): opener 후보 런 직전의 연속 백슬래시가
        # 홀수면 escaped 리터럴 — delimiter 아님, 내용 노출 유지 (codex 통합
        # 리뷰 R6 Medium: \` 우회 차단). 스팬 내부(closer 탐색)에는 escape 가
        # 없다 — CommonMark 코드 스팬 내부는 escape 비적용.
        nbs = 0
        while (RSTART - 1 - nbs >= 1 && substr(rest0, RSTART - 1 - nbs, 1) == "\\") nbs++
        if (nbs % 2 == 1) {
          maskeddoc = maskeddoc substr(rest0, 1, RSTART + RLENGTH - 1)
          rest0 = substr(rest0, RSTART + RLENGTH)
          continue
        }
        pre = substr(rest0, 1, RSTART - 1)
        dl = RLENGTH
        rest = substr(rest0, RSTART + RLENGTH)
        p = 0; cl = 0; base = 0; tmp = rest
        while (match(tmp, /`+/)) {
          if (RLENGTH == dl) { p = base + RSTART; cl = RLENGTH; break }
          base += RSTART + RLENGTH - 1
          tmp = substr(tmp, RSTART + RLENGTH)
        }
        if (p > 0) {
          span = substr(rest, 1, p - 1)
          gsub(/[^\n]/, " ", span)
          maskeddoc = maskeddoc pre " " span " "
          rest0 = substr(rest, p + cl)
        } else {
          maskeddoc = maskeddoc pre " "
          rest0 = rest
        }
      }
      maskeddoc = maskeddoc rest0
      nml = split(maskeddoc, mline, /\n/)
      for (r = 1; r <= nrl; r++) {
        orig = origbuf[r]
        line = (r <= nml) ? mline[r] : ""
        scan_line(line, orig, r)
      }
      print "matches=" m > sumf
    }
    function scan_line(line, orig, lnum,   low, n, tok, out, i, t, h, matched, ex, exlen, b, ntail, conts) {
      low = tolower(line)
      # 제외 규칙 6 (다단어): exit <n> / exit code <n>.
      gsub(/exit ?(code ?)?[0-9]+/, " ", low)
      n = split(low, tok, /[[:space:]]+/)
      out = ""
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "") continue
        if (t ~ /\//) {
          # 제외 규칙 3 예외: 토큰 전체가 순수 비율이면 경로 마스킹 제외 (Q2 대상).
          if (t ~ /^[0-9]+\/[0-9]+$/) out = out " " t
          continue
        }
        if (t ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) continue
        if (t ~ /^v?[0-9]+\.[0-9]+(\.[0-9]+)?$/) continue
        if (t ~ /^§[0-9]+(\.[0-9]+)*$/) continue
        if (t ~ /^l[0-9]+$/) continue
        if (t ~ /^[a-z0-9_.-]*\.[a-z][a-z0-9]*$/) continue
        if (t ~ /^[a-z0-9-]+$/) { h = t; if (gsub(/-/, "-", h) >= 2) continue }
        out = out " " t
      }
      matched = 0
      if (out ~ /[0-9]+ ?(건|개소|개|회|줄|파일|케이스)/) matched = 1
      else if (out ~ /[0-9]+ ?(tests?|files?|lines?|cases?|checks?|functions?)([^a-z0-9]|$)/) matched = 1
      else if (out ~ /[0-9]+\/[0-9]+/) matched = 1
      else if (out ~ /[0-9]+(\.[0-9]+)?%/) matched = 1
      else if (out ~ /(^|[^a-z0-9])(테스트|tests?|suites?|검증|빌드|builds?|lints?|typechecks?|회귀|regressions?)([^a-z0-9]|$)/ \
            && out ~ /(^|[^a-z0-9])(pass(ed)?|green|통과|성공)([^a-z0-9]|$)/) matched = 1
      if (matched) {
        m++
        if (kept < 10) {
          # utf8trim: byte 절단 후 문자 경계 보존 (공용 함수 — parser 진단과 동일).
          ex = utf8trim(substr(orig, 1, 80))
          ex = "L" lnum ": " ex
          gsub(/\[readiness-reject\]/, "[readiness-…]", ex)
          gsub(/\[readiness-advisory\]/, "[readiness-…]", ex)
          print ex > flgf
          kept++
        }
      }
    }
  ' "$REIN_EV_MASKED_FILE" || {
    rc=$?
    echo "ERROR: [codex-review] readiness precheck: quant scanner (awk) failed (rc=$rc)" >&2
    return "$rc"
  }

  local matches="" line
  while IFS= read -r line; do
    case "$line" in
      matches=*) matches="${line#matches=}" ;;
    esac
  done < "$sum_f"
  case "$matches" in
    '' | *[!0-9]*)
      echo "ERROR: [codex-review] readiness precheck: scanner summary corrupt (matches='$matches')" >&2
      return 1 ;;
  esac

  QUANT_MATCH_COUNT="$matches"
  QUANT_FLAGS=$(cat "$flg_f" 2>/dev/null) || {
    rc=$?
    echo "ERROR: [codex-review] readiness precheck: flags read failed (rc=$rc)" >&2
    return "$rc"
  }
  return 0
}

# _readiness_check — 처분 (spec §4.2):
#   블록 0 + 매칭 ≥1 → 거부(실패 반환, [readiness-reject] 진단행)
#   블록 ≥1 + 매칭 ≥1 → advisory([readiness-advisory] 경고) + 성공
#   매칭 0 → 무발화 성공
# 파싱 결과(전역)는 build_envelope 가 §4.3 슬롯 방출에 재사용 — 파싱 1회,
# 이중 조립 없음.
_readiness_check() {
  _parse_evidence_blocks || return $?
  _scan_quant_claims || return $?
  if [ "${QUANT_MATCH_COUNT:-0}" -ge 1 ]; then
    local flag_line extra
    extra=$((QUANT_MATCH_COUNT - 10))
    if [ "${EVIDENCE_BLOCK_COUNT:-0}" -eq 0 ]; then
      echo "ERROR: [codex-review][readiness-reject] 정량/PASS 주장 감지 — 증거 블록 0개 (codex 미호출)" >&2
      while IFS= read -r flag_line; do
        [ -n "$flag_line" ] || continue
        echo "ERROR: [codex-review][readiness-reject]   $flag_line" >&2
      done <<< "${QUANT_FLAGS:-}"
      if [ "$extra" -gt 0 ]; then
        echo "ERROR: [codex-review][readiness-reject]   ... (+${extra} more)" >&2
      fi
      echo "ERROR: [codex-review][readiness-reject]   → [EVIDENCE] claim/command/exit_code/output 블록으로 각 주장의 재현 증거를 선언하거나, 주장 표현을 제거 후 재호출하라. 문법: SKILL.md §4.1" >&2
      return 1
    fi
    echo "WARNING: [codex-review][readiness-advisory] 블록 밖 정량/PASS 패턴 ${QUANT_MATCH_COUNT}건 — 증거 블록 미결박 (비차단)" >&2
    while IFS= read -r flag_line; do
      [ -n "$flag_line" ] || continue
      echo "WARNING: [codex-review][readiness-advisory]   $flag_line" >&2
    done <<< "${QUANT_FLAGS:-}"
    if [ "$extra" -gt 0 ]; then
      echo "WARNING: [codex-review][readiness-advisory]   ... (+${extra} more)" >&2
    fi
  fi
  return 0
}

# _emit_evidence_manifest — envelope context 슬롯 (spec §4.3). 유효 블록 ≥1
# 일 때만 방출 — 0 이면 코드 경로 자체가 실행되지 않아 기존과 byte 동일.
_emit_evidence_manifest() {
  [ "${EVIDENCE_BLOCK_COUNT:-0}" -ge 1 ] 2>/dev/null || return 0
  printf '\nevidence_manifest:\n  blocks: %s\n' "$EVIDENCE_BLOCK_COUNT"
  local line i=0 field=0
  while IFS= read -r line; do
    field=$((field % 3 + 1))
    case "$field" in
      1) i=$((i + 1)); printf '  block %s:\n    claim: %s\n' "$i" "$line" ;;
      2) printf '    command: %s\n' "$line" ;;
      3) printf '    exit_code: %s\n' "$line" ;;
    esac
  done <<< "${EVIDENCE_BLOCK_SUMMARY:-}"
}

# _emit_unbacked_quant_flags — advisory 매칭 ≥1 일 때만 방출 (spec §4.3).
_emit_unbacked_quant_flags() {
  [ "${QUANT_MATCH_COUNT:-0}" -ge 1 ] 2>/dev/null || return 0
  [ -n "${QUANT_FLAGS:-}" ] || return 0
  printf '\nunbacked_quant_flags:\n'
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %s\n' "$line"
  done <<< "$QUANT_FLAGS"
}

# ---- Parse CLI options + read stdin prompt. ---------------------------

NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    *) ;;  # pass-through args reserved for future codex options; ignored here
  esac
done

# Read the entire prompt body from stdin. If no stdin (tty), PROMPT_BODY
# is empty — this is the interactive case where the caller will type below.
PROMPT_BODY=""
if [ ! -t 0 ]; then
  PROMPT_BODY=$(cat)
fi

# ---- Parse [EFFORT:<level>] marker (SKILL.md §6.1/6.2). ---------------
# Supported values: low | medium | high. Invalid (e.g. [EFFORT:low2],
# [EFFORT:low-high], [EFFORT: ], [EFFORT:]) → stderr warning + leave
# REIN_EFFORT empty so the main block computes effort from change size
# (_compute_effort), exactly as if no marker were present. All [EFFORT:...]
# occurrences are stripped from PROMPT_BODY regardless of validity so codex
# never receives the marker (§6.2 contract).
#
# The outer capture uses [^]]* (any non-']' content) so malformed values
# are captured too, triggering the documented warn-and-fallback path.
# The inner value is whitespace-trimmed before whitelist check so
# "[EFFORT: medium ]" is accepted as medium.
REIN_EFFORT=""
if [ -n "$PROMPT_BODY" ]; then
  _effort_raw=$(printf '%s' "$PROMPT_BODY" | grep -oE '\[EFFORT:[^]]*\]' 2>/dev/null | head -1 || true)
  if [ -n "$_effort_raw" ]; then
    # Strip leading/trailing whitespace around the inner value.
    _effort_val=$(printf '%s' "$_effort_raw" | sed -E 's/^\[EFFORT:[[:space:]]*//; s/[[:space:]]*\]$//')
    case "$_effort_val" in
      low|medium|high)
        REIN_EFFORT="$_effort_val"
        ;;
      # ultra/max/xhigh 사유별 명시 거부 (spec 2026-07-10 §4.5) — 처리 결과는
      # 기존 무효값 경로와 동일(strip + REIN_EFFORT 빈 채 산출 진입), 사유
      # 메시지만 분리. 자동 산출 어휘는 low|medium|high 3종 유지.
      ultra)
        echo "WARNING: [codex-review] [EFFORT:ultra] is rejected at the gate — ultra delegates to auto subagents (non-deterministic verdicts, quota/timeout conflicts). Computing effort from change size instead." >&2
        ;;
      max|xhigh)
        echo "WARNING: [codex-review] [EFFORT:${_effort_val}] is not supported yet — pending timeout measurement (follow-up). Computing effort from change size instead." >&2
        ;;
      *)
        echo "WARNING: [codex-review] invalid effort '$_effort_val' in [EFFORT:...] marker; computing effort from change size instead" >&2
        ;;
    esac
    # Strip ALL [EFFORT:...] occurrences (valid or not, any inner content).
    PROMPT_BODY=$(printf '%s' "$PROMPT_BODY" | sed -E 's/\[EFFORT:[^]]*\][[:space:]]*//g')
  fi
  unset _effort_raw _effort_val
fi

# ---- Mode detection (Task 6.1 Step 2a). -------------------------------

# Marker patterns anchored to the start of the prompt.
SPEC_REVIEW_PLAN_RE='^\[NON_INTERACTIVE\][[:space:]]+spec review for plan:'
SPEC_REVIEW_DESIGN_RE='^\[NON_INTERACTIVE\][[:space:]]+spec review for design:'

REIN_REVIEW_MODE="code-review"  # default
# SPEC_REVIEW_SUBJECT — the reviewed document path parsed from the marker.
# Used in spec-review mode to scope changed_files to the document itself
# (G8-3, 2026-05-23) instead of letting `git diff` infer unrelated files.
SPEC_REVIEW_SUBJECT=""
# D2 (2026-06-11, Round 2 High): first line via pure-bash parameter expansion.
# The previous `printf "$PROMPT_BODY" | head -1 | grep -q` chain was the same
# pipefail/SIGPIPE class as D1 — `head -1` exits after the first line, so a
# prompt larger than the pipe buffer SIGPIPEs printf (141) and the if-condition
# goes false DESPITE a marker match. Worst case: a large spec-review prompt is
# misclassified as code-review and writes the code-gate stamp (.codex-reviewed)
# — gate pollution. Parameter expansion has no pipeline (no SIGPIPE window);
# the downstream grep/sed then run on a single small line.
PROMPT_FIRST_LINE="${PROMPT_BODY%%$'\n'*}"
if printf '%s' "$PROMPT_FIRST_LINE" | grep -qE "$SPEC_REVIEW_PLAN_RE"; then
  REIN_REVIEW_MODE="spec-review"
  SPEC_REVIEW_SUBJECT=$(printf '%s' "$PROMPT_FIRST_LINE" \
    | sed -E 's/^\[NON_INTERACTIVE\][[:space:]]+spec review for plan:[[:space:]]*//' \
    | sed -E 's/[[:space:]]+$//')
elif printf '%s' "$PROMPT_FIRST_LINE" | grep -qE "$SPEC_REVIEW_DESIGN_RE"; then
  REIN_REVIEW_MODE="spec-review"
  SPEC_REVIEW_SUBJECT=$(printf '%s' "$PROMPT_FIRST_LINE" \
    | sed -E 's/^\[NON_INTERACTIVE\][[:space:]]+spec review for design:[[:space:]]*//' \
    | sed -E 's/[[:space:]]+$//')
fi

# ---- Review-readiness precheck 삽입 지점 (spec §4.5/§4.6). -------------
#
# code-review 모드 한정 — spec-review 는 사전검사·휴리스틱·manifest 슬롯 전부
# skip (자동 spec 경로의 구조적 false-positive 차단). interactive 모드
# (PROMPT_BODY 빈 값)는 조건식으로 자연 통과 — 별도 분기 없음.
# exit 4 는 codex spawn 이전에만 발생한다 (EV5 — 컨텍스트 조립보다도 앞).
# 위반 상세는 _readiness_check 가 stderr 로 방출: 거부 진단행은 라인 시작
# anchored `ERROR: [codex-review][readiness-reject]`, 인프라 실패는 태그 없는
# plain ERROR (호출자 판별 계약, spec §4.4).
if [ "$REIN_REVIEW_MODE" = "code-review" ] && [ -n "$PROMPT_BODY" ]; then
  _readiness_check || exit 4
fi

# ---- Context assembly (Task 6.1 Step 4). ------------------------------

# 4a. diff_base.
#   Preference: latest .codex-reviewed stamp's diff_base: line → HEAD~1 →
#   empty tree (pre-commit, no HEAD).
EMPTY_TREE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

_resolve_diff_base() {
  local stamp="$PROJECT_DIR/trail/dod/.codex-reviewed"
  if [ -f "$stamp" ]; then
    # Staleness self-healing (묶음 C Phase 2):
    # stamp.reviewed_at < HEAD commit ISO → ignore stamp + fall through to HEAD~1.
    # NOTE: actual wrapper schema field is `reviewed_at:` (write_code_review_stamp L772).
    # python3 exit: 0 = stale (s < h), 1 = fresh, 2 = parse failure (fail-safe = stale).
    local stamp_iso head_iso
    stamp_iso=$(grep -E '^reviewed_at:' "$stamp" | head -1 | sed 's/^reviewed_at:[[:space:]]*//')
    head_iso=$(git -C "$PROJECT_DIR" log -1 --format=%cI HEAD 2>/dev/null || true)
    if [ -n "$stamp_iso" ] && [ -n "$head_iso" ]; then
      python3 -c '
import sys
from datetime import datetime
try:
  s = datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
  h = datetime.fromisoformat(sys.argv[2])
  sys.exit(0 if s < h else 1)
except Exception:
  sys.exit(2)
' "$stamp_iso" "$head_iso" 2>/dev/null
      local rc=$?
      # rc=1 (fresh) → use stamp's diff_base. rc=0 (stale) or rc=2 (parse fail) → fall through.
      if [ "$rc" = "1" ]; then
        local base
        base=$(grep -E '^diff_base:' "$stamp" | head -1 | sed 's/^diff_base:[[:space:]]*//' || true)
        # GE-2: a fresh stamp's stored diff_base must be a real commit reachable
        # from HEAD. Verify object existence + commit type (rev-parse ^{commit})
        # AND HEAD-ancestry (merge-base --is-ancestor). A forged / orphan /
        # other-branch SHA fails one of these → fall through to HEAD~1 (same
        # fail-safe as OQ-3) so it cannot be injected as the review diff base.
        if [ -n "$base" ] \
           && git -C "$PROJECT_DIR" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
           && git -C "$PROJECT_DIR" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
          printf '%s' "$base"
          return 0
        fi
      fi
    fi
  fi
  # HEAD~1 if it exists.
  if git -C "$PROJECT_DIR" rev-parse HEAD~1 >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" rev-parse HEAD~1
    return 0
  fi
  # Pre-commit / shallow: fall back to empty tree so diff vs. this is
  # "everything tracked" — better than erroring out.
  printf '%s' "$EMPTY_TREE_SHA"
}

DIFF_BASE=$(_resolve_diff_base)

# G8-3 (2026-05-23): a fresh spec review has no code diff to anchor on. Force
# diff_base = N/A so the envelope does not invite codex to diff an unrelated
# commit range (which previously surfaced unrelated changed files + a stale
# active DoD). The reviewed document itself is the only "changed file".
if [ "$REIN_REVIEW_MODE" = "spec-review" ]; then
  DIFF_BASE="N/A"
fi

# 4a.1 Timestamp metadata for Claim Audit evidence-freshness rule.
#   diff_base_iso = commit time of DIFF_BASE (ISO-8601 %cI).
#   head_iso      = commit time of HEAD.
#   Empty stdout on exit 0 (empty-tree SHA, untracked file) → "(unavailable)".
#   `||` shortcut fallback is NOT used because git log returns 0 with empty
#   stdout for those cases; explicit `-z` check is required.
_resolve_commit_iso() {
  local ref="$1"
  local out
  out=$(git -C "$PROJECT_DIR" log -1 --format=%cI "$ref" -- 2>/dev/null || true)
  if [ -z "$out" ]; then
    printf '(unavailable)'
  else
    printf '%s' "$out"
  fi
}
DIFF_BASE_ISO=$(_resolve_commit_iso "$DIFF_BASE")
HEAD_ISO=$(_resolve_commit_iso "HEAD")

# 4b. Changed files. We prefer the WORKING TREE first: the union of staged
# (--cached) and unstaged (working-tree) changes, deduplicated. This matches
# rein's review-before-commit flow, where the real review subject is staged
# (uncommitted) — reviewing it is the whole point of the gate. Only when the
# working tree is CLEAN (PR flow: everything already committed) do we degrade
# to the committed range `<DIFF_BASE>..HEAD`, so a PR review still sees its
# diff. The previous order put the committed range first; when an unrelated
# file was already committed (DIFF_BASE..HEAD non-empty) the wrapper reviewed
# that stale range and never looked at the staged subject (B4, 2026-06-09).
# Failures degrade to an empty list.
_changed_files() {
  local staged unstaged worktree out
  staged=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null || true)
  unstaged=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null || true)
  # Union of staged + unstaged, drop blank lines, dedup (stable order).
  worktree=$(printf '%s\n%s\n' "$staged" "$unstaged" \
    | grep -v '^$' | awk '!seen[$0]++' || true)
  if [ -n "$worktree" ]; then
    out="$worktree"
  else
    # Working tree clean → degrade to the committed range (PR flow).
    out=$(git -C "$PROJECT_DIR" diff --name-only "$DIFF_BASE"..HEAD 2>/dev/null || true)
  fi
  printf '%s' "$out"
}
CHANGED_FILES=$(_changed_files)

# Review subject mode (B5/B6, 2026-06-09 — codex-ask D: bounded consistency
# fix). Decide ONCE what this review is actually about, then make every
# downstream slot follow it: the changed_files label, the claim_sources
# comparison basis, and (via CLAIM_SOURCES) the freshness hints. This closes
# the structural mismatch where rein's review-before-commit flow stages the
# real subject (uncommitted) while HEAD is an unrelated prior commit — using
# HEAD as the claim/label basis produced false NEEDS-FIX and (when staged
# claims were never compared) false PASS.
#
#   - spec        : spec-review mode (the reviewed document is the subject).
#   - working_tree: the working tree is dirty (staged ∪ unstaged non-empty).
#                   This is rein's review-before-commit flow; the staged diff
#                   is the subject, NOT HEAD.
#   - commit_range: working tree clean (PR flow) → <DIFF_BASE>..HEAD is the
#                   subject (a normal post-commit / PR review).
#
# The working_tree vs commit_range split mirrors _changed_files's own
# preference (working tree first, committed range as the clean-tree degrade)
# so the label, claim source, and file list never disagree.
_resolve_review_subject() {
  local staged unstaged worktree
  staged=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null || true)
  unstaged=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null || true)
  worktree=$(printf '%s\n%s\n' "$staged" "$unstaged" | grep -v '^$' || true)
  if [ -n "$worktree" ]; then
    printf 'working_tree'
  else
    printf 'commit_range'
  fi
}
if [ "$REIN_REVIEW_MODE" = "spec-review" ]; then
  REVIEW_SUBJECT="spec"
else
  REVIEW_SUBJECT=$(_resolve_review_subject)
fi

# ---- Deterministic effort computation (Plan 2026-06-26 Phase 2). ------
#
# Derive the codex reasoning effort from the size of the change instead of a
# static default. REVIEW_SUBJECT is the single authority for which size signal
# to use (mirrors the review-subject split used everywhere else):
#   - spec        : reviewed document length (wc -l). NO git diff — spec mode
#                   keeps DIFF_BASE=N/A.
#   - working_tree: git diff HEAD --numstat (HEAD absent → --cached).
#   - commit_range: git diff DIFF_BASE..HEAD --numstat.
# Each emits a level (low|medium|high) on success, or EMPTY on any failure /
# unknown mode so the main block falls back to CODE_FAIL_CLOSED_EFFORT=high
# (fail-closed).
# Defined at top level (outside the main block) so tests can source the wrapper
# and call these directly — same idiom as _resolve_diff_base / _changed_files.

# Map a document line count to an effort level (E2-doclen).
_map_doc_effort() {
  local n="$1"
  if   [ "$n" -le 150 ]; then printf 'low'
  elif [ "$n" -le 400 ]; then printf 'medium'
  else printf 'high'
  fi
}

# Map a git numstat-derived change size to an effort level (E1-codesize-mirrors
# + E2-codesize). $1 selects the numstat source: "diff_head" | "range".
_map_code_effort_from_numstat() {
  # $1 = source selector: "diff_head" | "range"
  local src="$1" numstat
  case "$src" in
    diff_head)
      # working_tree: HEAD 기준 staged+unstaged 결합. HEAD 부재 시 --cached 강등.
      numstat=$(git -C "$PROJECT_DIR" diff HEAD --numstat 2>/dev/null \
        || git -C "$PROJECT_DIR" diff --cached --numstat 2>/dev/null || true)
      ;;
    range)
      numstat=$(git -C "$PROJECT_DIR" diff "$DIFF_BASE"..HEAD --numstat 2>/dev/null || true)
      ;;
    *) printf ''; return 0 ;;
  esac
  [ -n "$numstat" ] || { printf ''; return 0; }
  local files=0 lines=0 all_docs=1 added deleted path
  while IFS=$'\t' read -r added deleted path; do
    [ -n "$path" ] || continue
    files=$((files + 1))
    if [ "$added" = "-" ] || [ "$deleted" = "-" ]; then
      :  # binary 행: 파일수 +1, 줄수 +0
    else
      lines=$((lines + added + deleted))
    fi
    case "$path" in
      *.md|*.markdown|*.txt|*.rst) ;;
      *) all_docs=0 ;;
    esac
  done <<< "$numstat"
  [ "$files" -gt 0 ] || { printf ''; return 0; }
  if [ "$all_docs" = "1" ]; then printf 'low'; return 0; fi
  if [ "$lines" -le 10 ]  && [ "$files" -le 1 ]; then printf 'low';    return 0; fi
  if [ "$lines" -le 100 ] && [ "$files" -le 3 ]; then printf 'medium'; return 0; fi
  printf 'high'
}

# Dispatch by REVIEW_SUBJECT to the right size signal (E1-compute-emits +
# E1-docsize-wc). Emits a level on success, or empty on failure / unknown mode.
_compute_effort() {
  case "$REVIEW_SUBJECT" in
    spec)
      # 문서 길이 (git diff 금지 — spec 모드 DIFF_BASE=N/A).
      local subj f lines
      subj="$SPEC_REVIEW_SUBJECT"
      [ -n "$subj" ] || { printf ''; return 0; }
      if   [ -f "$PROJECT_DIR/$subj" ]; then f="$PROJECT_DIR/$subj"
      elif [ -f "$subj" ];              then f="$subj"
      else printf ''; return 0; fi
      lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ' || true)
      [ -n "$lines" ] || { printf ''; return 0; }
      _map_doc_effort "$lines"
      ;;
    working_tree)
      _map_code_effort_from_numstat "diff_head"
      ;;
    commit_range)
      _map_code_effort_from_numstat "range"
      ;;
    *)
      printf ''   # 알 수 없는 모드 → 폴백(high)
      ;;
  esac
}

# Risk-path floor predicate (spec 2026-07-10 §4.3 — MP3). 변경 크기≠위험도의
# 보완: 입력은 이미 해소된 CHANGED_FILES(규모 신호와 동일 집합)이며, 한 줄이라도
# 아래 패턴에 매칭되면 0(true). 메인 블록이 code-review 모드 + 산출 low 일 때만
# medium 승격에 사용한다 (low→medium 단방향; 마커 > floor; spec 모드 skip).
# 패턴 의미: hooks/**·security/**·config/** 는 임의 깊이 디렉토리 세그먼트
# (메인테이너 repo plugins/rein-core/hooks/… 와 사용자 repo .claude/hooks/…
# 모두 커버), scripts/rein-*.sh 는 scripts/ 세그먼트 하위 rein-*.sh,
# .github/workflows/** 는 repo 루트 앵커. top-level 정의 — 테스트가 래퍼를
# source 해 직접 호출 가능 (기존 _compute_effort idiom).
_risk_floor_matches() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      hooks/*|*/hooks/*|security/*|*/security/*|config/*|*/config/*| \
      .github/workflows/*|scripts/rein-*.sh|*/scripts/rein-*.sh)
        return 0 ;;
    esac
  done <<< "$CHANGED_FILES"
  return 1
}

# ENV-SUBJ A2/A3 (2026-06-11): the ISO slots follow REVIEW_SUBJECT. Before this,
# head_iso was ALWAYS the HEAD commit time — but in working_tree mode the staged
# diff (not HEAD) is the subject, and in spec mode there is no commit diff at
# all, so reporting a real HEAD time invited the reviewer to anchor freshness
# judgments on an unrelated prior commit. diff_base_iso stays real in
# working_tree mode (the base commit time is truthful information; its USE is
# qualified by the freshness-mode note below), but in spec mode the generic
# "(unavailable)" sentinel is replaced with an explicit reason.
case "$REVIEW_SUBJECT" in
  working_tree)
    HEAD_ISO="(N/A: working-tree review — HEAD is not the subject)"
    ;;
  spec)
    DIFF_BASE_ISO="(N/A: spec review has no commit diff)"
    HEAD_ISO="(N/A: spec review has no commit diff)"
    ;;
esac

# ENV-SUBJ A5 (2026-06-11): the Claim Audit evidence-freshness rule compares
# per-file last-commit ISO against diff_base_iso. That comparison only means
# "stale" when the subject IS a commit range. For working_tree the subject is
# uncommitted (a file committed before diff_base can be the live claim source),
# and for spec there is no commit diff — in both, the HIGH flag must not apply.
case "$REVIEW_SUBJECT" in
  working_tree)
    FRESHNESS_MODE_NOTE='[review subject = working tree (uncommitted)] diff_base 는 staged/unstaged 변경의 기준점이 아니다 — stale-evidence HIGH flag 비적용, advisory 기록만.'
    ;;
  spec)
    FRESHNESS_MODE_NOTE='[review subject = spec] commit diff 없음 — freshness 비교 전체 skip.'
    ;;
  *)
    FRESHNESS_MODE_NOTE=''
    ;;
esac

# changed_files slot label — reflects REVIEW_SUBJECT so the reviewer is never
# told it is looking at a committed range when the content is the working tree
# (B6). Built here as a variable so the envelope heredoc just substitutes it.
case "$REVIEW_SUBJECT" in
  working_tree) CHANGED_FILES_LABEL="working tree — staged+unstaged" ;;
  spec)         CHANGED_FILES_LABEL="spec review subject" ;;
  *)            CHANGED_FILES_LABEL="${DIFF_BASE}..HEAD" ;;
esac

# Claim Audit sub-item 4 instruction — the claim-source PRIORITY that the slot
# tells the reviewer to apply. It MUST match _claim_sources's actual,
# REVIEW_SUBJECT-aware behavior (B5); a static order would tell the reviewer to
# false-flag the intended mode behavior as a priority violation. Built here as
# a variable (same pattern as CHANGED_FILES_LABEL above) so the otherwise
# single-quoted SLOTS heredoc just substitutes the right line.
#   - working_tree: staged diff is the subject; HEAD is an unrelated prior
#     commit, so it is intentionally NOT a claim source (PR env > DoD title).
#   - commit_range: the committed change IS the subject (HEAD commit > DoD).
#   - spec: spec-review keeps SAD_PATH="" / no commit diff, so only the PR env
#     (if any) and the explicit no-source sentinel apply.
case "$REVIEW_SUBJECT" in
  working_tree)
    CLAIM_SOURCE_PRIORITY_NOTE='PR title/body > DoD/plan top > (no claim sources available)  [working tree: the HEAD-revision message is intentionally skipped — the staged diff, not the prior commit, is the subject]'
    ;;
  spec)
    CLAIM_SOURCE_PRIORITY_NOTE='PR title/body > (no claim sources available)  [spec review: no commit diff to anchor a claim]'
    ;;
  *)
    CLAIM_SOURCE_PRIORITY_NOTE='PR title/body > HEAD commit > DoD/plan top > (pre-commit) "unavailable"  [commit range: committed change is the subject]'
    ;;
esac

# G8-3 (2026-05-23): in spec-review mode the reviewed document is the only
# subject of the review. Scope changed_files to it (parsed from the marker)
# instead of whatever `git diff` infers from an unrelated commit range.
if [ "$REIN_REVIEW_MODE" = "spec-review" ]; then
  if [ -n "$SPEC_REVIEW_SUBJECT" ]; then
    CHANGED_FILES="$SPEC_REVIEW_SUBJECT"
  else
    CHANGED_FILES=""
  fi
fi

# 4c. Active DoD via shared selector.
#
# G8-3 (2026-05-23): in spec-review mode the active-DoD Tier-2 fallback is
# DISABLED. A fresh design/plan review has no related DoD yet; the latest-mtime
# DoD belongs to an unrelated in-flight task. Adopting it as Tier-2 context
# made the Design Alignment slot report the unrelated Scope IDs as MISSING →
# a recurring (5+) false NEEDS-FIX. We therefore represent the active DoD as
# an explicit N/A sentinel and skip the selector entirely. The reviewed
# document itself is the subject (see SPEC_REVIEW_SUBJECT below). This only
# affects spec-review mode; code-review keeps the Tier-1/Tier-2 selection.
# SAD_PATH stays empty in spec-review mode so the downstream plan_ref /
# design_ref / covers parsing (all guarded on `[ -n "$SAD_PATH" ]`) correctly
# skips — there is no related DoD to derive them from. SAD_PATH_DISPLAY is the
# value shown in the envelope context block; it carries the N/A sentinel so
# the reviewer sees an explicit "no active DoD" signal rather than a blank.
SPEC_REVIEW_NA="(N/A for fresh spec review)"
if [ "$REIN_REVIEW_MODE" = "spec-review" ]; then
  SAD_TIER="$SPEC_REVIEW_NA"
  SAD_PATH=""
  SAD_PATH_DISPLAY="$SPEC_REVIEW_NA"
  SAD_REASON="$SPEC_REVIEW_NA"
else
  SAD_LINE=$(select_active_dod)
  SAD_TIER=$(printf '%s' "$SAD_LINE" | cut -f1)
  SAD_PATH=$(printf '%s' "$SAD_LINE" | cut -f2)
  SAD_PATH_DISPLAY="$SAD_PATH"
  SAD_REASON=$(printf '%s' "$SAD_LINE" | cut -f3)
fi

# ENV-SUBJ A4 (2026-06-11): the selector itself declares Tier 2 as "advisory
# fallback / non-blocking authority" (select-active-dod.sh header) — it is a
# most-recent-mtime GUESS made without an explicit marker. The envelope used to
# erase that confidence level: Tier-2 DoD context (plan_ref/design_ref/covers/
# scope_items) fed the Design Alignment slot with the same blocking authority
# as a Tier-1 marker, so an unrelated DoD produced false MISSING/CONTRADICTS
# against the staged diff. Propagate the tier honestly: qualify the display and
# demote DoD-derived findings to advisory when (and only when) tier=2. Tier 1
# (explicit marker) and spec-mode N/A keep the full blocking policy.
SAD_TIER_DISPLAY="$SAD_TIER"
TIER2_DESIGN_ADVISORY_NOTE=""
TIER2_CLAIM_ADVISORY_NOTE=""
if [ "$SAD_TIER" = "2" ]; then
  SAD_TIER_DISPLAY="2 (advisory fallback guess — unconfirmed for this change)"
  TIER2_DESIGN_ADVISORY_NOTE='   [Tier 2 advisory guess] active DoD 는 명시 marker 없이 최신-mtime 추측으로 선택됐다 — 이 DoD 유래 컨텍스트(plan_ref/design_ref/covers/scope_items)는 현재 변경과 무관한 작업의 것일 수 있다. 본 slot 의 MISSING/CONTRADICTS 는 blocking 근거로 쓰지 말고 "advisory (Tier 2 guess)" Low 로만 보고하라. 이 slot 단독으로 FINAL_VERDICT 를 NEEDS-FIX 로 승격하지 마라.'
  TIER2_CLAIM_ADVISORY_NOTE='      [Tier 2 advisory guess] sub-item 2 의 "active DoD covers 존재" 확인은 추측 DoD 기준이다 — 부재/불일치를 High 근거로 쓰지 말고 advisory 기록만.'
fi

# ---- Shared path resolver (H1, 2026-04-22 retro-review-sweep). --------
#
# Mirrors scripts/rein-validate-coverage-matrix.py::_resolve_plan_ref.
# Both tools must resolve file references the same way so the envelope
# and validator agree on "does this file exist?". Divergence was the
# root cause of the v1.1.0 `design_ref: ../specs/...` silent failure.
#
# Args: $1=reference string, $2=base file used for relative resolution.
# Stdout: absolute path of first existing candidate (or empty if none).
# Exit: 0 if resolved, 1 if no candidate exists.
# Candidates tried in order:
#   1. <dirname($2)>/$1          (base-file-relative; most specific)
#   2. $PROJECT_DIR/$1           (repo-relative)
#   3. $1                        (CWD-relative / absolute)
# Project-root containment check (그룹 6 P1, 2026-04-25): refuse candidates
# that resolve outside PROJECT_DIR — `../../../etc/passwd` style refs from
# DoD `plan ref:` / `design ref:` are rejected so envelope never reads
# external files.
#
# Round 3 fix (codex review High, 2026-04-25): use python3 os.path.realpath
# on BOTH target and PROJECT_DIR so leaf-symlink escapes (e.g. target itself
# being `repo/foo.md → /private/tmp/foo.md`) resolve through. The earlier
# `pwd -P` only canonicalized `dirname(target)` and reattached `basename`
# as text, leaving leaf-symlinks bypassable. commonpath comparison aligns
# with the python validator's `relative_to` semantics for behavioral parity.
_path_within_project() {
  local target="$1"
  python3 -c '
import os, sys
try:
    project = os.path.realpath(sys.argv[1])
    target = os.path.realpath(sys.argv[2])
    common = os.path.commonpath([project, target])
    sys.exit(0 if common == project else 1)
except (ValueError, OSError):
    sys.exit(1)
' "$PROJECT_DIR" "$target" 2>/dev/null
}

_resolve_relative_path() {
  local ref="$1"
  local base_file="$2"
  local candidate
  local base_dir

  if [ -z "$ref" ]; then
    return 1
  fi

  if [ -n "$base_file" ] && [ -f "$base_file" ]; then
    base_dir=$(cd "$(dirname "$base_file")" 2>/dev/null && pwd)
    if [ -n "$base_dir" ]; then
      candidate="$base_dir/$ref"
      if [ -f "$candidate" ] && _path_within_project "$candidate"; then
        (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")")
        return 0
      fi
    fi
  fi

  candidate="$PROJECT_DIR/$ref"
  if [ -f "$candidate" ] && _path_within_project "$candidate"; then
    (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")")
    return 0
  fi

  if [ -f "$ref" ] && _path_within_project "$ref"; then
    (cd "$(dirname "$ref")" && printf '%s/%s\n' "$(pwd)" "$(basename "$ref")")
    return 0
  fi

  return 1
}

# 4d. Plan ref from active DoD `## 범위 연결` section.
#
# Single-plan contract (per plugins/rein-core/rules/design-plan-coverage.md). Phase 2
# (integration DoD) will lift this; until then we return the first plan_ref
# only and use `_count_dod_plan_refs` + gap header to flag duplicates.
#
# Annotation strip (H2, 2026-04-22): only the canonical annotations
# `(Team [A-Z])` or `(<bare identifier>)` are stripped. A path that itself
# contains parentheses (e.g. `docs/plans/foo(v2).md`) is preserved — the
# previous greedy `\(.*\)` strip would have truncated it.
_parse_dod_plan_ref() {
  local dod="$1"
  [ -f "$dod" ] || return 0
  awk '
    /^## 범위 연결/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec && /^plan[[:space:]]*ref:/ {
      line=$0
      sub(/^plan[[:space:]]*ref:[[:space:]]*/, "", line)
      # Strip only recognized annotation suffixes.
      if (match(line, /[[:space:]]+\((Team[[:space:]]+[A-Z]|[A-Za-z0-9_-]+)\)[[:space:]]*$/) > 0) {
        line=substr(line, 1, RSTART-1)
      }
      # Trim trailing whitespace if any remains.
      sub(/[[:space:]]+$/, "", line)
      print line; exit
    }
  ' "$dod"
}

# Count plan_ref lines within the DoD `## 범위 연결` section.
# Used to flag MULTIPLE_FAIL_CLOSED state when a DoD carries more than one.
_count_dod_plan_refs() {
  local dod="$1"
  [ -f "$dod" ] || { echo 0; return 0; }
  awk '
    BEGIN {count=0}
    /^## 범위 연결/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec && /^plan[[:space:]]*ref:/ {count++}
    END {print count+0}
  ' "$dod"
}

PLAN_REF=""
PLAN_REF_COUNT=0
PLAN_REF_RAW=""  # first ref string as parsed (no resolve applied yet)
if [ -n "$SAD_PATH" ]; then
  PLAN_REF_RAW=$(_parse_dod_plan_ref "$SAD_PATH" 2>/dev/null || true)
  PLAN_REF_COUNT=$(_count_dod_plan_refs "$SAD_PATH" 2>/dev/null || echo 0)
  if [ -n "$PLAN_REF_RAW" ]; then
    PLAN_REF=$(_resolve_relative_path "$PLAN_REF_RAW" "$SAD_PATH" || true)
  fi
fi

# H2 warning — duplicate plan refs are Phase-2 territory. Wrapper proceeds
# with first ref only and records state in the envelope gap header.
if [ "$PLAN_REF_COUNT" -gt 1 ]; then
  echo "WARNING: [codex-review] '$SAD_PATH' declares $PLAN_REF_COUNT plan refs; using first only (integration DoD is Phase 2)" >&2
fi

# 4e. Design ref from plan. Supports two equivalent syntaxes observed in
# the spec corpus:
#   - `> design ref: <path>`          (blockquote form; Plan A canonical)
#   - `Design Reference: <path>`      (top-level form; seen in some specs)
# Returned path is resolved against the plan file's parent → PROJECT_DIR →
# as-is (`_resolve_relative_path`). If the target file does not exist, we
# return empty so `design_state` becomes MISSING (H1 truthful detection).
_parse_plan_design_ref() {
  local plan="$1"
  [ -f "$plan" ] || return 0
  local raw
  raw=$(grep -iE '^>[[:space:]]*design[[:space:]]*ref:' "$plan" 2>/dev/null \
    | head -1 \
    | sed -E 's/^>[[:space:]]*design[[:space:]]*ref:[[:space:]]*//I' || true)
  if [ -z "$raw" ]; then
    raw=$(grep -iE '^design[[:space:]]*reference:' "$plan" 2>/dev/null \
      | head -1 \
      | sed -E 's/^design[[:space:]]*reference:[[:space:]]*//I' || true)
  fi
  [ -z "$raw" ] && return 0
  _resolve_relative_path "$raw" "$plan" || true
}
DESIGN_REF=""
DESIGN_REF_RAW=""
if [ -n "$PLAN_REF" ]; then
  # Preserve raw string for diagnostics, resolve for real use.
  DESIGN_REF_RAW=$(grep -iE '^>[[:space:]]*design[[:space:]]*ref:|^design[[:space:]]*reference:' "$PLAN_REF" 2>/dev/null \
    | head -1 \
    | sed -E 's/^>?[[:space:]]*design[[:space:]]*(ref|reference):[[:space:]]*//I' || true)
  DESIGN_REF=$(_parse_plan_design_ref "$PLAN_REF" 2>/dev/null || true)
fi

# 4f. Scope items from design's `## Scope Items` table.
_parse_scope_items_table() {
  local design="$1"
  [ -f "$design" ] || return 0
  awk '
    /^## Scope Items/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec { print }
  ' "$design"
}
SCOPE_ITEMS=""
if [ -n "$DESIGN_REF" ]; then
  SCOPE_ITEMS=$(_parse_scope_items_table "$DESIGN_REF" 2>/dev/null || true)
fi

# 4g. Covers list from DoD `## 범위 연결` section.
_parse_dod_covers() {
  local dod="$1"
  [ -f "$dod" ] || return 0
  awk '
    /^## 범위 연결/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec && /^covers:/ {
      sub(/^covers:[[:space:]]*/, "");
      print; exit
    }
  ' "$dod"
}
COVERS=""
if [ -n "$SAD_PATH" ]; then
  COVERS=$(_parse_dod_covers "$SAD_PATH" 2>/dev/null || true)
fi

# 4h. Claim sources — follows REVIEW_SUBJECT (B5, 2026-06-09). Priority:
#   1. REIN_PR_TITLE/REIN_PR_BODY env — explicit PR claim, always top priority.
#   2. review subject basis:
#        - working_tree: the staged diff is the subject, NOT HEAD. HEAD is
#          almost always an unrelated prior commit in rein's review-before-
#          commit flow, so using its message poisons the Claim Audit (false
#          NEEDS-FIX, and false PASS when the real staged claim is never
#          compared). Use the DoD (work-definition) title instead; if no DoD,
#          emit the explicit "(no claim sources available)" sentinel rather
#          than the unrelated HEAD message.
#        - spec: a fresh spec review has NO commit diff to anchor a claim on
#          (G8-3 forces diff_base=N/A, SAD_PATH=""). HEAD is an unrelated prior
#          commit, so it is intentionally skipped — emit the explicit
#          "(no claim sources available)" sentinel. This matches the spec-mode
#          instruction text (CLAIM_SOURCE_PRIORITY_NOTE); the prior code had no
#          spec branch and fell through to the HEAD-commit tail, contradicting
#          that text (B5-spec, Round 5 2026-06-09).
#        - commit_range: keep the prior order (HEAD commit > DoD). For a
#          clean-tree / PR review the committed change IS the subject, so its
#          message is the right claim source.
# We degrade gracefully — claim source is best-effort.
_claim_sources() {
  if [ -n "${REIN_PR_TITLE:-}" ] || [ -n "${REIN_PR_BODY:-}" ]; then
    printf 'title=%s\nbody=%s\n' "${REIN_PR_TITLE:-}" "${REIN_PR_BODY:-}"
    return 0
  fi
  if [ "${REVIEW_SUBJECT:-commit_range}" = "spec" ]; then
    # Spec-review subject (B5-spec, Round 5 2026-06-09): a fresh design/plan
    # review has NO commit diff to anchor a claim on. G8-3 already forces
    # diff_base=N/A and keeps SAD_PATH="" (no related DoD yet). The HEAD commit
    # is an unrelated prior change; reading its message would contradict the
    # spec-mode instruction text ("PR title/body > (no claim sources
    # available)" — HEAD skipped) and poison the Claim Audit with an unrelated
    # claim. PR env was already handled above (top priority in every mode), so
    # here the only correct output is the explicit no-source sentinel.
    printf '(no claim sources available)\n'
    return 0
  fi
  if [ "${REVIEW_SUBJECT:-commit_range}" = "working_tree" ]; then
    # Staged subject: do NOT read the (unrelated) HEAD commit message. DoD
    # title is the claim basis; fall through to the explicit no-source sentinel
    # when there is no DoD.
    if [ -n "$SAD_PATH" ]; then
      local title
      title=$(head -1 "$SAD_PATH" 2>/dev/null | sed 's/^#[[:space:]]*//')
      printf 'dod_title=%s\n' "$title"
      return 0
    fi
    printf '(no claim sources available)\n'
    return 0
  fi
  local head_msg
  head_msg=$(git -C "$PROJECT_DIR" log -1 --pretty=%B 2>/dev/null || true)
  if [ -n "$head_msg" ]; then
    printf 'head_commit=\n%s\n' "$head_msg"
    return 0
  fi
  if [ -n "$SAD_PATH" ]; then
    local title
    title=$(head -1 "$SAD_PATH" 2>/dev/null | sed 's/^#[[:space:]]*//')
    printf 'dod_title=%s\n' "$title"
    return 0
  fi
  printf '(no claim sources available)\n'
}
CLAIM_SOURCES=$(_claim_sources)

# 4h.1 Claim source file-reference extraction for evidence-freshness rule.
#
# Scans CLAIM_SOURCES for repo-relative file paths matching a conservative
# whitelist (.md/.sh/.py/.ya?ml/.json/.txt). Each candidate is filtered:
#   1. regex must match as a whole token (surrounded by whitespace/BOL/EOL
#      or markdown delimiters to avoid false positives inside words)
#   2. security filter: paths containing ../, shell metachars (; ` $(), or
#      newlines are skipped — prevents command injection into later git log
#   3. existence check: `[ -f "$PROJECT_DIR/$path" ]` must succeed — a
#      non-existent path would only yield noise in the envelope
# At most 20 items are kept to bound envelope size.
_extract_claim_source_file_refs() {
  local input="$1"
  [ -z "$input" ] && return 0
  local count=0
  local limit=20
  # Extract candidate tokens using grep -oE on a permissive pattern, then
  # apply security + existence filters in a pure-bash loop.
  # The pattern requires at least one slash OR a leading dir-looking prefix
  # so we don't pick up bare filenames that happen to end in .md.
  local pattern='[A-Za-z0-9_./-]+\.(md|sh|py|yaml|yml|json|txt)'
  local candidate
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    # Security filter: skip ../ traversal, shell metachars, newlines.
    case "$candidate" in
      *../*|*\;*|*\`*|*'$('*|*$'\n'*) continue ;;
    esac
    # Existence check against project root.
    [ -f "$PROJECT_DIR/$candidate" ] || continue
    printf '%s\n' "$candidate"
    count=$((count + 1))
    [ "$count" -ge "$limit" ] && break
  done < <(printf '%s' "$input" | grep -oE "$pattern" 2>/dev/null || true)
}

# Emit `claim_source_iso_hints:` block if at least one extracted reference
# exists. Each line shows `  <path>: <iso-or-unavailable>`. Mirrors
# _resolve_commit_iso semantics for the empty-stdout-on-success case.
_emit_claim_source_iso_hints() {
  local paths
  paths=$(_extract_claim_source_file_refs "$CLAIM_SOURCES")
  [ -z "$paths" ] && return 0
  printf '\nclaim_source_iso_hints:\n'
  local p iso
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    iso=$(git -C "$PROJECT_DIR" log -1 --format=%cI -- "$p" 2>/dev/null || true)
    if [ -z "$iso" ]; then
      iso='(unavailable)'
    fi
    printf '  %s: %s\n' "$p" "$iso"
  done <<< "$paths"
}

# ---- Envelope builder (Task 6.2). -------------------------------------

# build_envelope → emits the full prompt to stdout. The heading literals
# below are owned by Spec A §5; internal heuristics (bad-test, numeric
# mapping) are defined by Spec B and are allowed to be light here.
build_envelope() {
  # 6.2 Step 5: [NON_INTERACTIVE] banner for automated calls.
  if [ "$NON_INTERACTIVE" = "1" ]; then
    printf '[NON_INTERACTIVE]\n\n'
  fi

  # 6.2 Step 2: "High process gap" header when context is incomplete.
  # H1 (2026-04-22): design_state is judged on BOTH resolved path AND scope
  # items extraction success. Previous behavior judged only on raw string
  # non-emptiness, silently reporting "present" for unresolvable refs.
  # H2 (2026-04-22): plan_state flags MULTIPLE_FAIL_CLOSED when DoD carries
  # duplicate `plan ref:` lines (integration DoD is Phase 2).
  local gap_lines=""
  local plan_state="present"
  local design_state="present"
  local covers_state="present"
  local base_state="present"
  if [ -z "$PLAN_REF" ]; then
    plan_state="MISSING"
  fi
  if [ "$PLAN_REF_COUNT" -gt 1 ]; then
    plan_state="MULTIPLE_FAIL_CLOSED (using first of $PLAN_REF_COUNT)"
  fi
  if [ -z "$DESIGN_REF" ]; then
    if [ -n "$DESIGN_REF_RAW" ]; then
      design_state="MISSING (unresolved ref: $DESIGN_REF_RAW)"
    else
      design_state="MISSING"
    fi
  elif [ -z "$SCOPE_ITEMS" ]; then
    design_state="UNUSABLE (resolved to $DESIGN_REF but no '## Scope Items' section)"
  fi
  [ -z "$COVERS" ] && covers_state="MISSING"
  [ -z "$DIFF_BASE" ] && base_state="MISSING"
  if [ "$plan_state" != "present" ] || [ "$design_state" != "present" ] \
     || [ "$covers_state" = "MISSING" ]; then
    cat <<HDR
High process gap — required context missing:
- plan_ref: ${plan_state}
- design_ref: ${design_state}
- covers: ${covers_state}
- diff_base: ${base_state}
Proceed with partial checks only.

HDR
  fi

  # Preserve caller prompt body (spec-review marker etc.) immediately
  # after any gap header. The marker must stay in the envelope so the
  # downstream reviewer (real codex) sees the same context the wrapper
  # used for mode detection.
  if [ -n "$PROMPT_BODY" ]; then
    printf '%s\n\n' "$PROMPT_BODY"
  fi

  # 6.2 Step 3: 4 fixed slots.
  cat <<'SLOTS'
Required review sections (모두 응답에 포함해야 한다):

1. Code defects and regressions
   - 기존 코드리뷰 체크 (look-ahead, 타입, 경계, resource leak 등)

2. Design Alignment  [Spec B policy]
SLOTS
  # ENV-SUBJ A4: Tier-2 fallback context is a guess — demote to advisory.
  # Emitted between the single-quoted heredocs so the $-note expands; empty
  # (Tier 1 / spec N/A) emits nothing and the slot text is byte-identical to
  # the pre-A4 envelope.
  if [ -n "$TIER2_DESIGN_ADVISORY_NOTE" ]; then
    printf '%s\n' "$TIER2_DESIGN_ADVISORY_NOTE"
  fi
  cat <<'SLOTS'
   각 active DoD covers 의 Scope ID 에 대해 아래 4 status 중 하나로 분류 + 근거 제시:

   - MATCH: 해당 ID 가 기술한 entity/direction/scenario 가 diff 의 코드 변경 또는
            test 변경에서 명확히 반영됐다. direction 의 부등호/boolean/exact
            값이 assertion 이나 조건문에 관찰됨.
   - PARTIAL: entity 는 반영됐으나 direction/scenario 중 일부가 누락.
   - MISSING: 해당 ID 를 구현해야 하는 commit 인데 diff 에 entity 관련 변경이 없음.
   - CONTRADICTS: direction 이 반대로 구현됨. 예: design 이 "A < B" 인데
                  코드/test 가 "A == B" 또는 "A > B".

   covers 외 Scope ID 는 "out of scope of this change".

   TO-scope-id-measurable-contract-required 자기 강제: Scope ID 자체가
   direction/scenario 가 결여된 서술이면 MEDIUM 으로 플래그 ("ID 포맷 미달").
   bad ID 가 slot 을 오염시키는 것을 막는다.

3. Test Alignment  [Spec B policy — 단일 deterministic rule, parent/child 분리 구조 사용 금지]

   --- Step 1: Status 판정 ---

   test 함수 이름이 design term (mode name, state name, action name 등) 을
   사용하는가? 예: test_caution_*, test_defense_*, test_rotation_bearish_*.

   사용하면 assertion 을 design 의 해당 term 정의와 대조하여 status 분류:

   - MATCH: assertion 이 design 의 서술과 같은 방향/값
   - PARTIAL: assertion 이 term 의 일부만 검증
   - CONTRADICTS: assertion 이 design 이 명시한 동작과 상충 — 다음 중 하나:
     * 방향 반전 (design 이 A < B 인데 assertion 이 A > B 또는 A == B)
     * 임계값 누락 (design 이 수치 threshold 를 요구하는데 assertion 이 equality 만)
     * same-result 패턴 (expected == <other_mode_literal> 또는 다른 mode 의 상수와
       일치) — 단, same-result 는 design 이 divergence 를 요구하는 경우에만
       CONTRADICTS. design 이 두 mode 의 동일 결과를 허용하거나 divergence
       요구가 없으면 MATCH (false-positive 원천 차단).

   CONTRADICTS 는 status 일 뿐 severity 가 아님. severity 는 Step 2 로 결정.

   --- Step 2: Severity 판정 (corroboration matrix) ---

   status = MATCH 또는 PARTIAL: Low signal, detection log 기록 안 함.

   status = CONTRADICTS: test 에서 3 요소 추출 후 corroboration 으로 severity 결정:

   - test_entity: test 함수명에서 design term 부분 (예: test_caution_nav_* → "caution-nav")
   - test_direction: assertion 이 요구하는 방향 (부등호, boolean, exact value)
   - test_scenario: test 함수명/fixture/parameter 에서 추출된 scenario token
                    (예: *_s1_2020_03_* → "s1-2020-03")

   3 요소 중 하나라도 추출 불가능하면 corroboration 0 으로 처리 (fail-safe).

   Corroboration 출처 3 종 — 각 출처에서 entity + direction + scenario
   세 축이 모두 일치해야 1 건으로 count:

   1. design 서술체: design 본문이 test_entity 의 direction 을 명시 + test_scenario
      를 언급. generic 서술 (scenario 미언급) 은 scenario 축 fail → count 안 됨.
      다른 scenario 서술도 scenario 불일치 → count 안 됨.
   2. design Scope Items: test_entity prefix + test_direction keyword + test_scenario
      suffix 를 모두 포함하는 Scope ID 존재. scenario 다른 ID 는 count 안 됨.
   3. plan matrix covers: active DoD covers 에 출처 2 의 entity+direction+scenario
      일치 Scope ID 가 implemented 로 포함. 애매한 match 는 권한 없음 (fail-safe).

   severity matrix:
   | corroboration 건수 | severity |
   |------------------|----------|
   | 0                | Low signal, detection log ONLY (envelope 에 기록, verdict = warning) |
   | 1 이상           | High (corroboration 증거를 envelope 에 인용)                       |

   예시 1 (High — corroboration 1): design 본문 "CAUTION 은 S1 2020-03 에서
   ATTACK 보다 drawdown 작다" + Scope ID "caution-nav-drawdown-less-than-attack-in-s1-2020-03"
   존재. test_caution_nav_drawdown_less_than_attack_in_s1_2020_03 이 nav_caution
   == nav_attack 를 assert → CONTRADICTS + corroboration 2 출처 매칭 → High.

   예시 2 (Low signal): design 이 두 mode 동일 결과를 허용. test_caution_mode_nav
   이 nav == 101_000_000 assert → status 는 MATCH (divergence 요구 없음). 기록
   대상 아님.

4. Claim Audit  [Spec B policy]

   1. Claim 에 숫자가 포함된 경우 (예: "3 선행지표", "5단계 포지션", "4 ETF 쌍"):
      - 각 숫자 항목에 대해 코드/config/design 에서 1:1 mapping 을 찾아 제시.
      - 예: "3 선행지표" → 선행지표 1 (path), 선행지표 2 (path), 선행지표 3 (path).
      - mapping 이 불완전하면 High severity.

   2. 기능 이름 claim (예: "CAUTION mode 구현 완료"):
      - 해당 mode/기능의 Scope ID 가 active DoD covers 에 존재하는지 확인.
      - 존재 + Design Alignment MATCH → 통과.
      - 존재 + MISSING/CONTRADICTS → High.

   3. Matrix `deferred` 행의 사유:
      - plan matrix 의 deferred 행 "위치/사유" 가 PR/commit claim 과 일치하는가?
      - changelog 에 언급된 항목인데 matrix 에 없으면 "claim vs tracking drift" High.

   4. Claim source 우선순위 (Spec A GI-codex-review-context-assembly 에서 주입,
      현재 review subject 모드에 맞춰 동적 생성 — B5):
SLOTS
  # The priority line is REVIEW_SUBJECT-aware (B5). Emitted outside the
  # single-quoted heredoc so $CLAIM_SOURCE_PRIORITY_NOTE expands; the 6-space
  # indent matches the surrounding slot-4 sub-items.
  printf '      %s\n' "$CLAIM_SOURCE_PRIORITY_NOTE"
  # ENV-SUBJ A4: Tier-2 covers must not back a High claim-audit finding.
  if [ -n "$TIER2_CLAIM_ADVISORY_NOTE" ]; then
    printf '%s\n' "$TIER2_CLAIM_ADVISORY_NOTE"
  fi
  cat <<'SLOTS'

   5. Evidence freshness

SLOTS
  # ENV-SUBJ A5: the staleness comparison is only meaningful when the subject
  # is a commit range — qualify (working_tree) or skip (spec) otherwise.
  if [ -n "$FRESHNESS_MODE_NOTE" ]; then
    printf '      %s\n' "$FRESHNESS_MODE_NOTE"
  fi
  cat <<'SLOTS'
      context block 의 claim_source_iso_hints 각 항목에 대해 last-commit ISO 를
      diff_base_iso 와 비교:

      - last-commit ISO < diff_base_iso → "stale evidence", HIGH severity flag
      - ISO = (unavailable) → freshness 판정 skip + advisory 기록만 (severity Low)

      본 slot 응답에 plaintext 로 entity + timestamp + 판정을 명시.
      (verdict 승격 강제는 sub-item 6 의 discrepancy 기준만 적용 —
      freshness HIGH 는 slot 내부 severity flag 일 뿐 verdict 강제 아님)

   6. Claim discrepancy escalation

      sub-item 1 (numeric mapping) 에만 적용. expected 값과 관찰 값 관계에서
      다음 중 하나 충족 시 **응답 첫 줄에 NEEDS-FIX 출력**:

      (a) |expected - observed| / max(|expected|, 1) > 0.20
      (b) 1:1 mapping 누락 항목 수 ≥ 1

      sub-item 2 (feature name) / sub-item 3 (Matrix deferred 사유) 는
      boolean/qualitative 이므로 본 rule 대상 아님 — 기존 High 판정 규칙 유지.
      Evidence freshness (sub-item 5) 의 HIGH 판정도 본 rule 의 verdict 승격
      대상이 **아님** (numeric mapping claim 전용).
SLOTS
  # Evidence manifest cross-check (EV6, 2026-07-13): additive sub-item 7 —
  # evidence_manifest: 슬롯 방출 시(유효 블록 ≥1)에만 함께 방출. 미방출 시
  # 앞뒤 heredoc 이 그대로 이어져 기존 slot 텍스트와 byte 동일 (하위호환).
  if [ "${EVIDENCE_BLOCK_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    cat <<'SLOTS'

   7. Evidence manifest cross-check

      context 블록의 evidence_manifest 를 sub-item 1(numeric mapping) 판정의
      1차 증거로 사용하라 — claim 의 숫자가 output 발췌·exit_code 와 정합하는지
      대조. unbacked_quant_flags 의 라인은 증거 미결박 주장 후보다 — manifest
      블록·코드·config 어디에서도 근거를 찾지 못하면 기존 sub-item 1 규칙대로
      High. manifest 블록의 output 이 claim 과 모순되면(예: claim "21건" vs
      output "20 passed") sub-item 6 discrepancy 기준을 그대로 적용한다.
SLOTS
  fi
  cat <<'SLOTS'

응답 출력 형식 (필수 — P2 verdict parser hardening, 2026-04-25):

응답의 **마지막 줄**에 반드시 아래 한 줄을 출력한다 (parser 가 이 라인을 우선
매칭한다):

  FINAL_VERDICT: <PASS|NEEDS-FIX|REJECT>

위 라인이 없으면 wrapper 는 첫 줄 keyword 매칭으로 fallback 하며, 둘 다 부재
시 NEEDS-FIX 로 처리한다. 본문에서 판정을 분석한 뒤에도 마지막에 위 한 줄을
반드시 다시 출력하라.

SLOTS

  # 6.2 Step 4: structured context block.
  cat <<CTX
---
Context:

review_subject: ${REVIEW_SUBJECT}
diff_base: ${DIFF_BASE}
diff_base_iso: ${DIFF_BASE_ISO}
head_iso: ${HEAD_ISO}
active_dod_tier: ${SAD_TIER_DISPLAY}
active_dod_path: ${SAD_PATH_DISPLAY}
active_dod_reason: ${SAD_REASON}
plan_ref: ${PLAN_REF:-(none)}
design_ref: ${DESIGN_REF:-(none)}

covers (from DoD):
${COVERS:-(none)}

scope_items (from design):
${SCOPE_ITEMS:-(none)}

changed_files (${CHANGED_FILES_LABEL}):
${CHANGED_FILES:-(none)}

claim_sources:
${CLAIM_SOURCES}
CTX
  # Optional per-file ISO hints (only emitted if any file ref detected).
  _emit_claim_source_iso_hints
  # Evidence manifest + unbacked quant flags (EV1/EV3, 2026-07-13): 준비도
  # 사전검사가 남긴 전역을 재사용해 조건부 방출 — 둘 다 0 이면 방출 코드
  # 경로 자체가 실행되지 않아 envelope 은 기존과 byte 동일 (EV2 하위호환).
  _emit_evidence_manifest
  _emit_unbacked_quant_flags
  printf -- '---\n'
}

# ---- Codex invocation (Task 6.3). -------------------------------------

CODEX_BIN="${CODEX_BIN:-codex}"

# Verdict parser — 3-stage chain (P2 hardening, 2026-04-25).
#
# Stage 1: dedicated `FINAL_VERDICT: <keyword>` line (envelope 가 출력 형식
#          섹션에서 codex 에게 명시 지시; parser 가 line-anchored 로 가장
#          우선 매칭). REJECT > NEEDS-FIX > PASS 우선순위는 tail -1 의 단일
#          매치 라인 안에서만 결정 — 마지막(tail) FINAL_VERDICT 라인이
#          verdict 다. envelope 규칙이 codex 에게 "응답 끝에 FINAL_VERDICT" 를
#          지시하므로 진짜 결론은 응답 끝의 라인이고, 본문 앞쪽에 인용/예시로
#          섞인 FINAL_VERDICT(예: 테스트 stub 인용)는 결론이 아니다
#          (B3, 2026-06-09 — first-match 가 인용 노이즈를 결론으로 오인하던
#          버그의 근본 수정).
#
# Stage 2: legacy first-position keyword on any line (backward-compat —
#          transition 기간에 envelope 지시 도달 전후 응답 패턴 동시 지원).
#          Priority: REJECT > NEEDS-FIX > PASS. 본문에 'PASS analysis' 같은
#          서술을 첫 컬럼이 아니라 들여써서 작성하면 false-match 방지.
#
# Stage 3: 둘 다 부재 → NEEDS-FIX (보수적 fallback 유지).
#
# 두 세션 연속 false-verdict 재현 (2026-04-24 claim-audit-hardening +
# 2026-04-25 spec-flow-policy-hardening) 의 근본 해결.
_parse_verdict() {
  local out="$1"
  local fv_line
  # Stage 1: FINAL_VERDICT line. case-insensitive, REJECT > NEEDS-FIX > PASS
  # within the matched line (each line carries exactly one keyword anyway).
  fv_line=$(printf '%s' "$out" \
    | grep -iE '^[[:space:]]*FINAL_VERDICT:[[:space:]]*(REJECT|NEEDS[-_ ]?FIX|PASS)\b' \
    | tail -1 || true)
  if [ -n "$fv_line" ]; then
    if printf '%s' "$fv_line" | grep -qiE 'REJECT\b'; then
      printf 'REJECT'; return 0
    elif printf '%s' "$fv_line" | grep -qiE 'NEEDS[-_ ]?FIX\b'; then
      printf 'NEEDS-FIX'; return 0
    elif printf '%s' "$fv_line" | grep -qiE 'PASS\b'; then
      printf 'PASS'; return 0
    fi
  fi
  # Stage 2: legacy first-position keyword on any line.
  # D1 (2026-06-11): `grep -q` 금지 — pipefail + 대용량 $out 에서 -q 조기종료가
  # printf SIGPIPE(141)를 유발해 "매치했는데도" 조건이 거짓이 된다 (_detect_
  # model_error 의 동일 결함 클래스). 키워드가 출력 앞부분일수록(legacy 첫 줄
  # verdict 가 정확히 그 형태) 오판으로 NEEDS-FIX 강등. 전 입력 소비로 수정.
  if printf '%s' "$out" | grep -iE '^[[:space:]]*REJECT\b' >/dev/null 2>&1; then
    printf 'REJECT'
  elif printf '%s' "$out" | grep -iE '^[[:space:]]*NEEDS[-_ ]?FIX\b' >/dev/null 2>&1; then
    printf 'NEEDS-FIX'
  elif printf '%s' "$out" | grep -iE '^[[:space:]]*PASS\b' >/dev/null 2>&1; then
    printf 'PASS'
  else
    # Stage 3: unknown → NEEDS-FIX.
    printf 'NEEDS-FIX'
  fi
}

# Invoke codex. stdin = envelope. stdout = verdict body.
_invoke_codex() {
  # Use `exec` subcommand by default (same as SKILL.md examples).
  "$CODEX_BIN" exec "$@" || return $?
}

# ---- Model fail-soft (DoD codex-model-profile-routing). ---------------
#
# codex 가 요청 모델을 모르면 (upstream rename 등) exit≠0 + JSON
# invalid_request_error / "... is not supported when using Codex" 를 낸다
# (2026-06-08 실측). 이 경우 sonnet fallback 으로 넘기면 잘못된 모델을
# 영구히 못 쓰고 문제만 숨겨지므로, 전용 종료 코드 3 으로 신호하고
# 단일 출처(codex-models.sh) 수정을 안내한다 (SKILL.md §4 참조).

# _detect_model_error <output> → 0(true) if codex rejected the model.
# codex/OpenAI 의 모델 거부 메시지 변형을 포괄한다:
#   - invalid_request_error : OpenAI JSON 에러 타입(모델/요청 설정 거부)
#   - model_not_found / "model not found" : 모델 미존재
#   - "is not supported when using ..." : ChatGPT 계정 등에서 모델 미지원(실측)
#   - "is not supported by this (api|model)" : API/모델 미지원 변형
# 정상 리뷰 본문 오탐을 줄이려고 일반 "is not supported" 단독은 매칭하지 않는다.
_detect_model_error() {
  local out="${1:-}"
  # 오탐 방지: 정상 리뷰 출력은 FINAL_VERDICT 라인을 포함한다. codex 가 모델
  # 거부로 응답 자체를 생성하지 못하면 verdict 가 없고 ERROR JSON 만 남는다.
  # 따라서 verdict 가 있으면 — 리뷰 본문이 거부 문구를 단지 인용/논의한 경우
  # 포함 — 모델 거부가 아니다. (이 가드가 없으면 fail-soft 자체를 리뷰할 때
  # 본문의 패턴 언급을 거부로 오인해 정상 PASS 가 차단된다.)
  #
  # D1 (2026-06-11): `grep -q` 금지 — 본 스크립트는 pipefail 이므로 -q 의
  # 조기종료가 대용량 $out 을 쓰던 printf 에 SIGPIPE(141)를 일으켜 파이프라인
  # status 가 141 이 되고, if 조건이 "매치했는데도" 거짓이 되어 가드 전체가
  # 무력화된다 (출력 앞부분의 envelope verdict-양식 인용 + 출력 > pipe buffer
  # 일 때 실측 재발 — 본 사이클 Round 1 self-review). -q 없는 grep 은 전 입력을
  # 소비하므로 조기종료가 없다. 출력은 /dev/null 로 버린다.
  if printf '%s' "$out" | grep -E '^[[:space:]]*FINAL_VERDICT:' >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$out" | grep -iE 'invalid_request_error|model_not_found|model not found|is not supported when using|is not supported by this (api|model)' >/dev/null 2>&1
}

# _emit_model_failsoft <role-var-name> <model-value>
_emit_model_failsoft() {
  local role_var="${1:-CODE_GATE_MODEL}" model_val="${2:-}"
  echo "ERROR: [codex-review] codex 가 요청한 모델을 거부했습니다 — 모델명이 변경되었을 수 있습니다." >&2
  echo "  현재 ${role_var}=\"${model_val}\"" >&2
  echo "  → plugins/rein-core/config/codex-models.sh 의 ${role_var} 를 codex 의 최신 모델명으로 수정하세요." >&2
  if [ "$role_var" = "CODE_GATE_MODEL" ]; then
    echo "  (구버전 config 는 legacy alias CODE_MODEL 로 정의할 수 있습니다 — 그 경우 CODE_MODEL 을 수정하세요.)" >&2
  fi
}

# ---- Stamp writer (Task 6.3 Step 3). ----------------------------------

# write_code_review_stamp <verdict> <reviewer>
#   Only invoked when REIN_REVIEW_MODE="code-review" AND verdict="PASS".
#   Creates trail/dod/.codex-reviewed with the mandatory fields,
#   including diff_base: (GI-codex-review-diff-base).
write_code_review_stamp() {
  local verdict="$1"
  local reviewer="${2:-codex}"
  local stamp="$PROJECT_DIR/trail/dod/.codex-reviewed"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local cycle=""
  if [ -n "$SAD_PATH" ]; then
    cycle=$(basename "$SAD_PATH" .md | sed 's/^dod-//')
  fi
  # codex_version 증빙 — 메인 블록이 리뷰 호출 *이전에* best-effort 1회
  # 해석해 둔 CODEX_VERSION_STR 를 사용한다 (spec 2026-07-10 §4.4). 게이트
  # 판정에 영향 없는 순수 증빙 필드이므로 미해석/빈 값이 stamp 작성을
  # 막으면 안 된다 — "(unavailable)" 로 표기.
  local codex_ver="${CODEX_VERSION_STR:-}"
  [ -n "$codex_ver" ] || codex_ver="(unavailable)"
  mkdir -p "$(dirname "$stamp")"
  # 신규 5필드는 기존 7필드 **뒤에** additive (기존 필드 이름·순서·포맷
  # 불변 — pre-bash-test-commit-gate.sh 파서는 reviewed_at:/diff_base: 만
  # 읽으므로 비의존). policy_version 은 canonical fallback 실행 시 0.
  cat > "$stamp" <<STAMP
reviewed_at: ${ts}
reviewer: ${reviewer}
diff_base: ${DIFF_BASE}
verdict: ${verdict}
cycle: ${cycle}
scope: wrapper-generated
active_dod: ${SAD_PATH}
model: ${CODE_GATE_MODEL}
effort: ${REIN_EFFORT}
effort_source: ${EFFORT_SOURCE}
policy_version: ${CODE_ROUTING_POLICY_VERSION:-0}
codex_version: ${codex_ver}
STAMP
  # Clear .review-pending only in code-review mode (never in spec-review).
  rm -f "$PROJECT_DIR/trail/dod/.review-pending" 2>/dev/null || true
}

# ---- Main orchestration. ----------------------------------------------

# Run only when invoked directly (not sourced) so tests of individual
# functions remain feasible. The `BASH_SOURCE[0]` vs. `$0` check is the
# canonical portable idiom.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Build envelope.
  ENVELOPE=$(build_envelope)

  # Invoke codex (real or fake via CODEX_BIN).
  CODEX_OUT=""
  CODEX_RC=0
  # Assemble optional codex flags from parsed markers.
  #   REIN_EFFORT → --config model_reasoning_effort="<level>" (TOML-quoted).
  # Empty array is safely expanded with ${arr[@]+...} under `set -u`.
  CODEX_ARGS=()
  # Model: 단일 출처의 CODE_GATE_MODEL 을 -m 으로 **항상** 전달한다
  # (unconditional — spec 2026-07-10 §4.2). config 전 후보 부재 시에도
  # 로드 블록의 canonical fallback 이 값을 보장하므로 무모델 호출 경로는
  # 존재하지 않는다. 빈값 방어는 아래 명시적 fatal assert 로만 둔다 —
  # 조용한 -m 생략(codex 기본 모델 degrade)은 어떤 형태로도 금지.
  [ -n "$CODE_GATE_MODEL" ] || {
    echo "FATAL: [codex-review] CODE_GATE_MODEL is empty after canonical fallback — refusing model-less codex call." >&2
    exit 3
  }
  CODEX_ARGS+=(-m "$CODE_GATE_MODEL")
  # Effort 4단계 결정 체인 (spec 2026-07-10 §4.3) — EFFORT_SOURCE 가 실제
  # 경로를 기록한다 (도장 증빙 §4.4):
  #   1) 유효 [EFFORT:] 마커 (marker) — floor 미적용. 마커 경로는 산출/floor
  #      블록에 진입조차 하지 않는다 (마커 > floor, E5 재승급 불변식 보존).
  #   2) 변경 규모 산출 (computed — _compute_effort).
  #   3) 위험도 floor (computed+floor) — code-review 모드 + 산출 low +
  #      위험 경로 매칭 시에만 medium 승격. low→medium 단방향(하한선이지
  #      가산기가 아니다 — medium/high 산출은 무변경). spec-review 모드는
  #      skip — 문서 리뷰는 코드 경로가 아니다.
  #   4) 측정 실패(빈 산출) → fail-closed 페어 (fail_closed —
  #      CODE_FAIL_CLOSED_EFFORT, canonical 해석 후 항상 non-empty).
  EFFORT_SOURCE=""
  if [ -n "$REIN_EFFORT" ]; then
    EFFORT_SOURCE="marker"
  else
    _eff="$(_compute_effort || true)"
    if [ -n "$_eff" ]; then
      EFFORT_SOURCE="computed"
      if [ "$REIN_REVIEW_MODE" != "spec-review" ] && [ "$_eff" = "low" ] \
         && _risk_floor_matches; then
        _eff="medium"; EFFORT_SOURCE="computed+floor"
      fi
      REIN_EFFORT="$_eff"
    fi
  fi
  if [ -z "$REIN_EFFORT" ]; then
    REIN_EFFORT="$CODE_FAIL_CLOSED_EFFORT"; EFFORT_SOURCE="fail_closed"
  fi
  if [ -n "$REIN_EFFORT" ]; then
    CODEX_ARGS+=(--config "model_reasoning_effort=\"$REIN_EFFORT\"")
  fi
  # codex_version 증빙 — best-effort 1회 해석 (spec 2026-07-10 §4.4).
  # guarded assignment: `|| true` 가 파이프라인 전체(set -euo pipefail 의
  # pipefail 포함)를 흡수해 해석 실패가 실행을 막지 않는다. 리뷰 본 호출
  # *이전*에 해석한다 — 테스트 fake codex(CODEX_BIN 주입)의 인자/프롬프트
  # 캡처는 "마지막 호출" 기준이므로, 리뷰 호출 뒤에 --version 프로브를
  # 두면 캡처가 프로브로 덮여 오염된다 (증빙 의미는 동일 — 같은 실행의
  # 같은 바이너리 버전).
  CODEX_VERSION_STR=$("$CODEX_BIN" --version 2>/dev/null | head -1 || true)
  [ -n "$CODEX_VERSION_STR" ] || CODEX_VERSION_STR="(unavailable)"
  # Feed envelope on stdin. Args forwarded to `codex exec` via _invoke_codex.
  # B2 (2026-06-09): capture codex 의 *실제* exit code. 이전 `if ! CMD; then
  # CODEX_RC=$?` 는 `$?` 가 `! CMD`(항상 0)를 캡처해 codex 비모델 실패에도
  # exit 0 으로 성공 위장했다. 여기서는 `$()` 를 단독 평가하고 `|| CODEX_RC=$?`
  # 로 codex 의 종료 코드를 그대로 받는다 (`set -e` 가 non-zero `$()` 에서
  # 스크립트를 죽이지 않도록 `||` 로 분리. pipefail 이라 _invoke_codex 의
  # return $? 가 파이프 exit status 로 전파된다).
  CODEX_RC=0
  CODEX_OUT=$(printf '%s' "$ENVELOPE" | _invoke_codex ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} 2>&1) || CODEX_RC=$?
  if [ "$CODEX_RC" -ne 0 ]; then
    # Best-effort: emit output so caller can see what went wrong.
    printf '%s\n' "$CODEX_OUT"
    # Fail-soft: 모델 거부면 sonnet fallback 으로 새지 말고(잘못된 모델을
    # 숨기지 않도록) 전용 exit 3 + 단일 출처 수정 안내.
    if _detect_model_error "$CODEX_OUT"; then
      _emit_model_failsoft "CODE_GATE_MODEL" "$CODE_GATE_MODEL"
      exit 3
    fi
    echo "ERROR: [codex-review] codex invocation failed (exit $CODEX_RC)." >&2
    exit "$CODEX_RC"
  fi

  # Emit codex output unchanged for the caller.
  printf '%s\n' "$CODEX_OUT"

  # Fail-soft (방어): codex 가 exit 0 으로 와도 출력에 모델 거부가 섞였으면
  # 통과 표시(.codex-reviewed)를 만들지 않고 단일 출처 수정을 안내한다.
  if _detect_model_error "$CODEX_OUT"; then
    _emit_model_failsoft "CODE_GATE_MODEL" "$CODE_GATE_MODEL"
    exit 3
  fi

  # Parse verdict.
  VERDICT=$(_parse_verdict "$CODEX_OUT")

  # Mode-aware stamp handling.
  if [ "$REIN_REVIEW_MODE" = "code-review" ]; then
    if [ "$VERDICT" = "PASS" ]; then
      write_code_review_stamp "$VERDICT" "codex"
    fi
    # NEEDS-FIX / REJECT → no stamp.
  else
    # spec-review mode (CRITICAL): never write .codex-reviewed, never
    # touch .review-pending. The caller (plan-writer) is responsible for
    # writing the spec-review stamp via scripts/rein-mark-spec-reviewed.sh.
    :
  fi

  # Signal verdict via exit code for scripted callers.
  case "$VERDICT" in
    PASS) exit 0 ;;
    NEEDS-FIX) exit 1 ;;
    REJECT) exit 2 ;;
    *) exit 1 ;;
  esac
fi
