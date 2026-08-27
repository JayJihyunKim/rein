#!/usr/bin/env bash
# tests/skills/test-codex-model-profile-routing.sh
#
# TDD (red) — Plan 2026-07-10-codex-model-profile-routing, Phase 1 Task 1.1.
# spec: docs/specs/2026-07-10-codex-model-profile-routing.md §7~8.
#
# Fixes the behavioural contract of the codex model-profile routing that the
# config (Task 2.1) and the wrapper (Phase 4, Task 4.1~4.4) gain:
#   - profile-load            (MP1, spec §4.1)  config scalar profiles + legacy alias
#   - canonical-fallback      (MP2, spec §4.2)  config absent → built-in sol+high, no
#                                               model-less call, stderr warn exactly once
#   - floor-promote           (MP3, spec §4.3)  risk-path floor: computed low → medium
#   - marker-over-floor       (MP3, spec §4.3)  valid [EFFORT:] marker beats floor (E5)
#   - spec-mode-skip          (MP3, spec §4.3)  spec-review mode never applies the floor
#   - stamp-evidence          (MP4, spec §4.4)  RETIRED Phase 7 웨이브 3 ③-d — legacy
#                                               stamp write 경로 자체가 제거됨 (Group 6
#                                               자신의 헤더 — 정당 소멸, 부재 증명으로 대체)
#   - commit-gate-regression  (MP4, spec §4.4)  RETIRED Phase 7 웨이브 3 ③-d — Part A(legacy
#                                               파서 직접 호출)는 정당 소멸, Part B(diff_base
#                                               파싱)는 test-codex-review-stale-stamp.sh 로
#                                               대체 (Group 7 자신의 헤더 참조)
#   - marker-rejection        (MP5, spec §4.5)  ultra/max/xhigh rejected with own reason
#   - auto-vocab              (MP5, spec §4.5)  _compute_effort vocabulary stays low|medium|high
#
# The NEW-contract groups are expected to be RED until the wrapper-impl wave
# lands (the parent confirms red after Wave 1, green after Wave 2). A handful
# of asserts intentionally match CURRENT behaviour (marker priority / E5,
# spec-mode low, commit-gate parsing, auto-vocab) and stay green across the
# wave — they pin the invariants the change must not break.
#
# Seams (idioms borrowed from test-codex-model-failsoft.sh — e2e sandbox with
# fake codex via CODEX_BIN — and test-codex-effort-deterministic.sh —
# source-with-controlled-env for function-level calls):
#   A) config source in an isolated shell (profile-load: values + zero side
#      effects).
#   B) e2e sandbox: wrapper copy + lib + fixture git repo + stub codex that
#      captures args/prompt and supports --version. CLAUDE_PLUGIN_ROOT is
#      pinned empty so a host plugin root can never leak a real config in.
#   C) source seam: `source` the wrapper with stdin </dev/null, override
#      globals (CHANGED_FILES / REVIEW_SUBJECT / ...) and call
#      _risk_floor_matches / _compute_effort / _resolve_diff_base directly.
#   D) RETIRED (Phase 7 웨이브 3 ③-d, 2026-08-24) — was: v2 authority module,
#      extended (12-field) stamp fixtures parsed via a direct Python import
#      of rein.engine.authority._legacy_code_review_status. That import
#      target no longer exists — the legacy dual-read layer was fully
#      deleted from authority.py this wave. Group 7's own header records the
#      정당 소멸 (Part A) / 대체 (Part B, → test-codex-review-stale-stamp.sh)
#      disposition.
#
# The existing codex-review suites are NOT modified (separate regression).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"
CONF="$REAL_PROJECT_DIR/plugins/rein-core/config/codex-models.sh"
# Phase 7 웨이브 3 ③-d: AUTHORITY_MODULE_PARENT / HOOKSB / GATE_STATUS
# (Seam D — extended-stamp legacy parser regression) 는 그 import 대상
# (rein.engine.authority._legacy_code_review_status) 자체가 삭제되어
# 함께 제거됐다 — Group 7 자신의 헤더(정당 소멸 Part A) 참조.

TEST_COUNT=0
FAIL_COUNT=0
SANDBOX=""
TMPROOT=""
WRAP_RC=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }
check() { TEST_COUNT=$((TEST_COUNT + 1)); if eval "$1"; then echo "  ok: $2"; else fail "$2"; fi; }

assert_eq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" = "$2" ]; then echo "  ok: $3"
  else fail "$3 (expected='$2' got='$1')"; fi
}
assert_grep() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qF -- "$1" "$2" 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (pattern '$1' not found in $2)"; fi
}
assert_no_grep() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qF -- "$1" "$2" 2>/dev/null; then fail "$3 (unexpected '$1' in $2)"
  else echo "  ok: $3"; fi
}
assert_grep_e() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qE -- "$1" "$2" 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (ERE '$1' not found in $2)"; fi
}

find_lib() {
  if [ -f "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  elif [ -f "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  fi
}

# ------------------------------------------------------------
# Seam B — e2e sandbox (failsoft pattern + profile-shaped config fixture).
# ------------------------------------------------------------

# sandbox_setup <newconf|noconf>
#   newconf: profile-structured config (spec §4.1 shape, test model names +
#            legacy aliases) so the wrapper resolves CODE_GATE_MODEL=gpt-test-gate.
#   noconf : no config candidate anywhere → canonical fallback path.
sandbox_setup() {
  SANDBOX=$(mktemp -d "/tmp/codex-mpr-XXXXXX")
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/config" "$SANDBOX/trail/dod" \
           "$SANDBOX/.claude/hooks/lib"
  cp "$WRAPPER" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  local lib; lib="$(find_lib)"
  if [ -z "$lib" ]; then
    echo "sandbox_setup: select-active-dod.sh not found" >&2; return 1
  fi
  cp "$lib" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$(dirname "$lib")/path-containment.sh" \
     "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  case "${1:-newconf}" in
    newconf)
      cat > "$SANDBOX/config/codex-models.sh" <<'CONF'
CODE_GATE_MODEL="gpt-test-gate"
CODE_FAIL_CLOSED_MODEL="gpt-test-gate"
CODE_FAIL_CLOSED_EFFORT="high"
ANALYSIS_FAST_MODEL="gpt-test-fast"
ANALYSIS_FAST_EFFORT="low"
ANALYSIS_DEFAULT_MODEL="gpt-test-default"
ANALYSIS_DEFAULT_EFFORT="medium"
ANALYSIS_DEEP_MODEL="gpt-test-deep"
ANALYSIS_DEEP_EFFORT="high"
CODE_ROUTING_POLICY_VERSION="7"
CODE_MODEL="$CODE_GATE_MODEL"
CODE_EFFORT="$CODE_FAIL_CLOSED_EFFORT"
ANALYSIS_MODEL="$ANALYSIS_DEFAULT_MODEL"
ANALYSIS_EFFORT="$ANALYSIS_DEFAULT_EFFORT"
CONF
      ;;
    noconf)
      rm -f "$SANDBOX/config/codex-models.sh"
      ;;
  esac
  # args + prompt capture, --version support (spec §4.4 codex_version seam).
  cat > "$SANDBOX/stub-codex.sh" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--version" ]; then
  printf 'codex-stub 9.9.9\n'
  exit 0
fi
[ -n "${STUB_ARGS_OUT:-}" ] && printf '%s\n' "$*" > "$STUB_ARGS_OUT"
if [ -n "${STUB_PROMPT_OUT:-}" ]; then cat > "$STUB_PROMPT_OUT"; else cat > /dev/null; fi
printf '%s\n' "${STUB_VERDICT:-PASS
clean}"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$SANDBOX/stub-codex.sh"
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git commit --allow-empty -q -m init )
}

sandbox_teardown() {
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# run_wrapper <prompt> — STUB_* / STUB_ARGS_OUT / STUB_PROMPT_OUT passed by
# caller as inline env. CLAUDE_PLUGIN_ROOT pinned empty (host leak guard).
run_wrapper() {
  # 자가검증 관문(2026-07-21 review-cycle-efficiency A축) fixture 통행증:
  # effort/도장 계약 검증이 목적인 스위트라 dirty-tree 시나리오가 관문에
  # 막히지 않게 none 폴백 선언을 항상 덧붙인다 (관문 자체 계약은
  # test-review-selfverify-gate.sh 소유).
  local _p="$1
verification_commands: none
diff_self_review: harness fixture pass"
  ( cd "$SANDBOX" && CODEX_BIN="$SANDBOX/stub-codex.sh" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" CLAUDE_PLUGIN_ROOT="" \
      bash scripts/rein-codex-review.sh --non-interactive \
      <<<"$_p" > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt" )
  WRAP_RC=$?
}

# stage_file <relpath> <lines> — seed + git add a file inside the sandbox.
stage_file() {
  ( cd "$SANDBOX" && mkdir -p "$(dirname "$1")" && seq 1 "$2" > "$1" && git add "$1" )
}

# ------------------------------------------------------------
# Seam C — source-with-controlled-env fixtures.
# ------------------------------------------------------------
TMPROOT=$(mktemp -d "/tmp/codex-mpr-src-XXXXXX")
FIX="$TMPROOT/fix"
FIX2="$TMPROOT/fix2"
STUBDIR="$TMPROOT/stub"

mk_fixture() {
  local dir="$1" lib
  mkdir -p "$dir/trail/dod" "$dir/.claude/hooks/lib"
  lib="$(find_lib)"
  [ -n "$lib" ] || { echo "mk_fixture: select-active-dod.sh not found" >&2; return 1; }
  cp "$lib" "$dir/.claude/hooks/lib/select-active-dod.sh"
  cp "$(dirname "$lib")/path-containment.sh" \
     "$dir/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  ( cd "$dir" && git init -q && git config user.email t@e.com \
    && git config user.name t && git commit --allow-empty -q -m init )
}

mk_stub_git() {
  mkdir -p "$STUBDIR"
  cat > "$STUBDIR/git" <<'GIT'
#!/usr/bin/env bash
for _a in "$@"; do
  if [ "$_a" = "--numstat" ]; then
    printf '%s' "${STUB_NUMSTAT:-}"
    exit "${STUB_GIT_DIFF_RC:-0}"
  fi
done
exit 0
GIT
  chmod +x "$STUBDIR/git"
}

mk_numstat() {
  local spec
  for spec in "$@"; do
    # shellcheck disable=SC2086
    set -- $spec
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  done
}

# src_compute — source the wrapper against $FIX, override globals from env
# (SUBJECT / SPEC_SUBJ / DBASE), optionally front PATH with the stub git.
src_compute() {
  (
    export REIN_PROJECT_DIR_OVERRIDE="$FIX"
    # shellcheck disable=SC1090
    source "$WRAPPER" </dev/null >/dev/null 2>&1
    set +eu +o pipefail 2>/dev/null
    if [ "${USE_STUB:-0}" = "1" ]; then
      PATH="$STUBDIR:$PATH"; hash -r 2>/dev/null || true
    fi
    PROJECT_DIR="$FIX"
    REVIEW_SUBJECT="${SUBJECT:-}"
    SPEC_REVIEW_SUBJECT="${SPEC_SUBJ:-}"
    DIFF_BASE="${DBASE:-}"
    _compute_effort
  )
}

# floor_match <changed-files> — echoes yes/no from _risk_floor_matches.
# Function absence (pre-impl red) degrades to "no".
floor_match() {
  (
    export REIN_PROJECT_DIR_OVERRIDE="$FIX"
    # shellcheck disable=SC1090
    source "$WRAPPER" </dev/null >/dev/null 2>&1
    set +eu +o pipefail 2>/dev/null
    PROJECT_DIR="$FIX"
    CHANGED_FILES="$1"
    if _risk_floor_matches >/dev/null 2>&1; then echo yes; else echo no; fi
  )
}

# ------------------------------------------------------------
# Seam D — RETIRED (Phase 7 웨이브 3 ③-d, 2026-08-24).
#
# 이전에는 여기서 rein.engine.authority 의 legacy dual-read 파서
# (_legacy_code_review_status 등)를 직접 import 하는 헬퍼 3종(hook_setup/
# hook_teardown/write_ext_code_stamp)과 legacy_code_review_status() 를
# 정의했다. ③-d 로 그 함수들이 authority.py 에서 완전히 삭제되면서 이
# 헬퍼들은 import 자체가 실패하는 죽은 코드가 됐다 — Group 7 자신의 헤더
# (정당 소멸 Part A) 참조. 완전히 제거한다.
# ------------------------------------------------------------

cleanup() {
  sandbox_teardown
  [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

mk_fixture "$FIX"
mk_stub_git

echo "== codex model profile routing tests =="

# ------------------------------------------------------------
# Group 1 — profile-load (MP1-config-source-exposes-scalar-profiles +
# MP1-legacy-alias-tracks-new, spec §4.1 / §8 #1).
# Isolated-shell source of the REAL config: new scalar values, legacy aliases
# exposing the new values, and zero side effects (stdout/stderr/files).
# ------------------------------------------------------------
echo "-- group 1: profile-load"

conf_get() {
  bash -c "source '$CONF' >/dev/null 2>&1; printf '%s' \"\${$1:-}\""
}

assert_eq "$(conf_get CODE_GATE_MODEL)"        "gpt-5.6-sol"   "CODE_GATE_MODEL=gpt-5.6-sol"
assert_eq "$(conf_get CODE_FAIL_CLOSED_MODEL)" "gpt-5.6-sol"   "CODE_FAIL_CLOSED_MODEL=gpt-5.6-sol"
assert_eq "$(conf_get CODE_FAIL_CLOSED_EFFORT)" "high"         "CODE_FAIL_CLOSED_EFFORT=high"
assert_eq "$(conf_get ANALYSIS_FAST_MODEL)"    "gpt-5.6-luna"  "ANALYSIS_FAST_MODEL=gpt-5.6-luna"
assert_eq "$(conf_get ANALYSIS_FAST_EFFORT)"   "low"           "ANALYSIS_FAST_EFFORT=low"
assert_eq "$(conf_get ANALYSIS_DEFAULT_MODEL)" "gpt-5.6-terra" "ANALYSIS_DEFAULT_MODEL=gpt-5.6-terra"
assert_eq "$(conf_get ANALYSIS_DEFAULT_EFFORT)" "medium"       "ANALYSIS_DEFAULT_EFFORT=medium"
assert_eq "$(conf_get ANALYSIS_DEEP_MODEL)"    "gpt-5.6-sol"   "ANALYSIS_DEEP_MODEL=gpt-5.6-sol"
assert_eq "$(conf_get ANALYSIS_DEEP_EFFORT)"   "high"          "ANALYSIS_DEEP_EFFORT=high"
assert_eq "$(conf_get CODE_ROUTING_POLICY_VERSION)" "1"        "CODE_ROUTING_POLICY_VERSION=1"
# Legacy alias 4종 — 신값 노출 (MP1-legacy-alias-tracks-new).
assert_eq "$(conf_get CODE_MODEL)"      "gpt-5.6-sol"   "legacy CODE_MODEL → 신값 gpt-5.6-sol"
assert_eq "$(conf_get CODE_EFFORT)"     "high"          "legacy CODE_EFFORT → 신값 high"
assert_eq "$(conf_get ANALYSIS_MODEL)"  "gpt-5.6-terra" "legacy ANALYSIS_MODEL → default tier terra"
assert_eq "$(conf_get ANALYSIS_EFFORT)" "medium"        "legacy ANALYSIS_EFFORT → default tier medium"
# 부작용 0건: stdout/stderr 출력 0 + 파일 생성 0.
_SEDIR=$(mktemp -d "/tmp/codex-mpr-se-XXXXXX")
_conf_out=$( cd "$_SEDIR" && bash -c "source '$CONF'" 2>&1 )
check '[ -z "$_conf_out" ]' "config source stdout/stderr 출력 0 (got: '$_conf_out')"
check '[ -z "$(ls -A "$_SEDIR")" ]' "config source 파일 생성 0 (부작용 없음)"
rm -rf "$_SEDIR"

# ------------------------------------------------------------
# Group 2 — canonical-fallback (MP2-canonical-fallback-on-config-absent,
# spec §4.2 / §8 #2). Config 전 후보 부재 → 내장 canonical 로 -m 항상 전달
# (무모델 호출 0건) + stderr 경고 정확히 1회.
# Clean tree → effort 도 fail-closed 페어의 high 로 수렴.
#
# "stamp policy_version: 0" 항목 처분 (Phase 7 웨이브 3 ③-d, 정당 소멸):
# write_code_review_stamp() 는 더 이상 파일을 쓰지 않고, v2 발급이 받는
# 인자는 verdict/reviewed-digest 뿐이라 policy_version 을 실을 곳이 없다
# (codex-review SKILL §5.1 "실행 증빙 필드는 더 이상 durable 하게 저장되지
# 않는다" 참조) — 이 특정 필드값의 durable 기록은 후계가 없는 정보
# 손실이며, ③-d 가 받아들인 설계 결정이다. 대신 이 시나리오가 "발급
# 경로에 도달했다"는 사실만 stderr 로 규명한다(이 스위트는 bin/rein 을
# 링크하지 않으므로 항상 캡처 없음 ERROR 로 빠진다).
# ------------------------------------------------------------
echo "-- group 2: canonical-fallback"
sandbox_setup noconf
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "code review please"
assert_eq "$WRAP_RC" "0" "config 부재 → 래퍼 exit 0 (canonical 로 정상 진행)"
assert_grep "-m gpt-5.6-sol" "$SANDBOX/args.txt" \
  "config 부재 → -m gpt-5.6-sol 항상 전달 (무모델 호출 0건)"
assert_grep 'model_reasoning_effort="high"' "$SANDBOX/args.txt" \
  "config 부재 + 측정불가 → canonical effort high"
_warns=$(grep -c "canonical" "$SANDBOX/err.txt" 2>/dev/null || true)
assert_eq "$_warns" "1" "config 전 후보 부재 → canonical 경고 정확히 1회"
assert_grep "no review-start subject digest was captured" "$SANDBOX/err.txt" \
  "canonical fallback 실행 → v2 발급 경로 진입(bin/rein 미링크로 캡처없음 ERROR, non-fatal)"
sandbox_teardown

sandbox_setup newconf
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "code review please"
assert_grep "-m gpt-test-gate" "$SANDBOX/args.txt" \
  "config 존재 → CODE_GATE_MODEL 이 -m 으로 전달"
_warns=$(grep -c "canonical" "$SANDBOX/err.txt" 2>/dev/null || true)
assert_eq "$_warns" "0" "config 정상 로드 → canonical 경고 0회"
sandbox_teardown

# ------------------------------------------------------------
# Group 3 — floor-promote (MP3-risk-floor-promotes-low-to-medium,
# spec §4.3 / §8 #3-4). 위험 경로 + 산출 low → medium 승격 (단방향);
# 산출 high 는 무변경; 비위험 경로 소형은 low 유지.
# ------------------------------------------------------------
echo "-- group 3: floor-promote"
sandbox_setup newconf
stage_file "hooks/x.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "code review please"
assert_grep 'model_reasoning_effort="medium"' "$SANDBOX/args.txt" \
  "hooks/ 1파일 5줄 (산출 low) → floor 승격 medium"
sandbox_teardown

sandbox_setup newconf
stage_file "hooks/big.sh" 200
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "code review please"
assert_grep 'model_reasoning_effort="high"' "$SANDBOX/args.txt" \
  "위험 경로 + 200줄 (산출 high) → high 유지 (floor 는 하한선)"
sandbox_teardown

sandbox_setup newconf
stage_file "util.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "code review please"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "비위험 경로 소형 변경 → low 유지 (floor 미발동)"
sandbox_teardown

# _risk_floor_matches 패턴 테이블 (spec §4.3 매칭 규칙 — source seam).
assert_eq "$(floor_match 'hooks/a.sh')"                       "yes" "floor 패턴: hooks/* 매칭"
assert_eq "$(floor_match 'plugins/rein-core/hooks/a.sh')"     "yes" "floor 패턴: */hooks/* 매칭 (임의 깊이)"
assert_eq "$(floor_match 'security/base.md')"                 "yes" "floor 패턴: security/* 매칭"
assert_eq "$(floor_match '.claude/security/rules/x.md')"      "yes" "floor 패턴: */security/* 매칭"
assert_eq "$(floor_match 'config/codex-models.sh')"           "yes" "floor 패턴: config/* 매칭"
assert_eq "$(floor_match 'plugins/rein-core/config/m.sh')"    "yes" "floor 패턴: */config/* 매칭"
assert_eq "$(floor_match '.github/workflows/ci.yml')"         "yes" "floor 패턴: .github/workflows/* 매칭 (루트 앵커)"
assert_eq "$(floor_match 'scripts/rein-foo.sh')"              "yes" "floor 패턴: scripts/rein-*.sh 매칭"
assert_eq "$(floor_match 'sub/scripts/rein-foo.sh')"          "yes" "floor 패턴: */scripts/rein-*.sh 매칭"
assert_eq "$(floor_match "$(printf 'docs/a.md\nhooks/x.sh')")" "yes" "floor 패턴: 다중 파일 중 한 줄만 매칭해도 true"
assert_eq "$(floor_match 'docs/a.md')"                        "no"  "floor 패턴: 비위험 경로 비매칭"
assert_eq "$(floor_match 'myhooks/a.sh')"                     "no"  "floor 패턴: myhooks/ 는 hooks 세그먼트 아님"
assert_eq "$(floor_match 'scripts/other.sh')"                 "no"  "floor 패턴: scripts/ 의 비-rein 스크립트 비매칭"

# ------------------------------------------------------------
# Group 4 — marker-over-floor (MP3-marker-overrides-floor, spec §4.3 / §8 #5).
# 유효 마커는 산출/floor 블록에 진입조차 하지 않는다 (마커 > floor, E5 보존).
# ------------------------------------------------------------
echo "-- group 4: marker-over-floor"
sandbox_setup newconf
stage_file "hooks/x.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "[EFFORT:low] code review please"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "[EFFORT:low] + 위험 경로 → 최종 low (마커 > floor)"
sandbox_teardown

sandbox_setup newconf
stage_file "util.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "[EFFORT:high] code review please"
assert_grep 'model_reasoning_effort="high"' "$SANDBOX/args.txt" \
  "[EFFORT:high] + 소형 변경 → 최종 high (E5 재승급 불변식)"
sandbox_teardown

# ------------------------------------------------------------
# Group 5 — spec-mode-skip (MP3-spec-mode-floor-skipped, spec §4.3 / §8 #6).
# spec 모드 + 단문 문서(산출 low) → floor 미적용. 위험 경로 신호(staged
# hooks 파일 + 문서 자체의 hooks/ 경로)가 있어도 low 유지.
# ------------------------------------------------------------
echo "-- group 5: spec-mode-skip"
sandbox_setup newconf
( cd "$SANDBOX" && mkdir -p hooks && seq 1 50 > hooks/spec50.md )
stage_file "hooks/x.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" \
  run_wrapper "[NON_INTERACTIVE] spec review for design: hooks/spec50.md"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "spec 모드 + 50줄 문서 → 최종 low (floor 미발동)"
check '[ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]' \
  "spec 모드 → .codex-reviewed 미생성 (기존 불변식)"
sandbox_teardown

# ------------------------------------------------------------
# Group 6 — stamp-evidence (MP4-stamp-evidence-fields-additive,
# spec §4.4 / §8 #7). 원래 취지: PASS 도장에 실행 증빙 5필드(model/effort/
# effort_source/policy_version/codex_version)가 추가되고 기존 7필드가
# 잔존하는지 검증.
#
# Phase 7 웨이브 3 ③-d (2026-08-24) 처분: **정당 소멸**. write_code_review_
# stamp() 는 더 이상 어떤 파일도 쓰지 않는다(rein-codex-review.sh 자신의
# "Phase 7 wave 3 ③-d retired the legacy code-review stamp file" 주석
# 참조) — v2 발급이 받는 인자는 verdict/reviewed-digest 뿐이라 model/
# effort/effort_source/policy_version/codex_version 을 실을 필드 자체가
# 없다. 이 정보의 "기록" 은 이제 durable 하지 않다(사람 대면 stderr 로만
# 노출, codex-review SKILL §5.1 참조) — 되살릴 후계 파일 계약이 없으므로
# 무대체가 아니라 "그 계약 자체가 스펙 결정으로 소멸"이다.
#
# 하지만 **"effort 값이 올바르게 계산된다"는 사실 자체는 후계 커버리지가
# 있다** — Group 2~5 가 이미 같은 4개 시나리오(computed/marker/computed+
# floor/fail_closed) 각각에서 codex 실행 인자(`--config model_reasoning_
# effort="..."`, STUB_ARGS_OUT/args.txt)로 정확히 같은 값을 고정한다.
# 도장에 "기록"되는지는 소멸했지만 "계산·전달"되는지는 그대로 잠겨 있다.
# 아래는 그 소멸 자체(파일이 이제 전혀 생성되지 않음)를 고정하는 부재
# 증명 회귀 가드다.
# ------------------------------------------------------------
echo "-- group 6: stamp-evidence (정당 소멸 — 부재 증명으로 대체, effort 값 자체는 Group 2~5 커버)"

sandbox_setup newconf
stage_file "util.sh" 5
run_wrapper "code review please"
check '[ ! -e "$SANDBOX/trail/dod/.codex-reviewed" ]' \
  "PASS 이후에도 legacy stamp 파일이 전혀 생성되지 않음 (③-d write 경로 전면 제거)"
sandbox_teardown

# ------------------------------------------------------------
# Group 7 — commit-gate-regression (MP4-commit-gate-parser-unbroken,
# spec §4.4 / §8 #7). 원래 취지: 확장(12필드) 도장으로 파서 판정이 기존과
# 동일한지(PASS+fresh → pass, NEEDS-FIX → fail, 시각 파싱불가 →
# fail(fail-closed)) 검증.
#
# Phase 7 웨이브 3 ③-d (2026-08-24) 처분: **정당 소멸(Part A) + 대체
# (Part B)**.
#
# Part A (Seam D — legacy_code_review_status() 로 rein.engine.authority.
# _legacy_code_review_status 를 직접 호출하는 파서 무결성 검사)는 정당
# 소멸이다: ③-d 로 authority.py 의 legacy dual-read 계층 전체(`legacy_
# status`/`_legacy_code_review_status`/`_legacy_security_review_status`/
# `_parse_codex_marker`/`_parse_stamp_field`/`_normalize_iso`, 타입
# `LegacyStatus`/`LEGACY_PASS`/`LEGACY_FAIL`/`LEGACY_ABSENT`/`SOURCE_
# LEGACY`)가 코드에서 완전히 삭제됐다(authority.py 자신의 "Phase 7 웨이브
# 3 ③-d — legacy read 계층 전체 제거" 주석 참조, 실측: `grep -n "^def "
# authority.py` 에 이 함수들이 더 이상 없음) — import 자체가 실패하므로
# 이 Part 는 근본적으로 재현 불가능하다. 확장 필드가 붙어도 파서가
# 깨지지 않는다는 취지의 판정부 자체가 소멸했다 — 재도입하려면 spec §3.6
# 자체의 재개정(수동 governance acceptance)이 선행돼야 한다(authority.py
# 자신의 주석이 명시).
#
# Part B (_resolve_diff_base() 가 확장 도장의 diff_base: 필드를 그대로
# 채택하는지 검증)는 **대체** — tests/skills/test-codex-review-stale-
# stamp.sh 의 Test C("plausible_legacy_marker_content_is_fully_ignored")
# 가 정확히 같은 함수를 정확히 같은 방식(BASE_SHA=HEAD~1, .codex-reviewed
# 에 fresh + 유효 조상 SHA 시드)으로 실행해, ③-d 이후 이 함수가 stamp
# 내용과 무관하게 항상 HEAD~1 을 채택함을 고정한다 — 이 Group 이 만들던
# 것과 같은 BASE_SHA=HEAD~1 픽스처였으므로 원래도 "파서가 stamp 를 읽어서
# 우연히 같은 값에 도달"했는지 "무조건 HEAD~1 이라 같은 값"인지 이
# assertion 하나만으로는 구분되지 않았다 — stale-stamp 스위트의 Test A(
# stamp 없음)/Test D(적대적 stamp)가 그 구분을 실제로 제공한다.
# ------------------------------------------------------------
echo "-- group 7: commit-gate-regression (정당 소멸 Part A — import 대상 소멸 / 대체 Part B — test-codex-review-stale-stamp.sh Test C가 계승)"

# ------------------------------------------------------------
# Group 8 — marker-rejection (MP5-ultra-max-xhigh-rejected-with-reason,
# spec §4.5 / §8 #8). 각자 사유의 전용 메시지 + 산출 진입 + strip
# (codex 인자/프롬프트에 토큰 미전달). 기타 무효값은 기존 generic 유지.
# ------------------------------------------------------------
echo "-- group 8: marker-rejection"
sandbox_setup newconf
stage_file "util.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" STUB_PROMPT_OUT="$SANDBOX/prompt.txt" \
  run_wrapper "[EFFORT:ultra] code review please"
assert_grep "[EFFORT:ultra]" "$SANDBOX/err.txt" \
  "[EFFORT:ultra] → 전용 거부 메시지 (마커 명시)"
assert_grep_e '[Ss]ubagent' "$SANDBOX/err.txt" \
  "[EFFORT:ultra] → ultra 사유(자동위임/subagent) 명시"
assert_no_grep "invalid effort 'ultra'" "$SANDBOX/err.txt" \
  "[EFFORT:ultra] → generic invalid 메시지 아님 (사유 분리)"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "[EFFORT:ultra] 거부 후 산출 진입 → 최종 low (소형 변경)"
assert_no_grep "ultra" "$SANDBOX/args.txt" "ultra 토큰 codex 인자 미전달"
assert_no_grep "ultra" "$SANDBOX/prompt.txt" "ultra 토큰 codex 프롬프트에서 strip"
sandbox_teardown

sandbox_setup newconf
stage_file "util.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" STUB_PROMPT_OUT="$SANDBOX/prompt.txt" \
  run_wrapper "[EFFORT:max] code review please"
assert_grep "[EFFORT:max]" "$SANDBOX/err.txt" \
  "[EFFORT:max] → 전용 거부 메시지 (마커 명시)"
assert_grep "not supported yet" "$SANDBOX/err.txt" \
  "[EFFORT:max] → timeout 실측 전 미지원 사유"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "[EFFORT:max] 거부 후 산출 진입 → 최종 low"
assert_no_grep "[EFFORT:" "$SANDBOX/prompt.txt" "[EFFORT:max] 프롬프트에서 strip"
sandbox_teardown

sandbox_setup newconf
stage_file "util.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" STUB_PROMPT_OUT="$SANDBOX/prompt.txt" \
  run_wrapper "[EFFORT:xhigh] code review please"
assert_grep "[EFFORT:xhigh]" "$SANDBOX/err.txt" \
  "[EFFORT:xhigh] → 전용 거부 메시지 (마커 명시)"
assert_grep "not supported yet" "$SANDBOX/err.txt" \
  "[EFFORT:xhigh] → timeout 실측 전 미지원 사유"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "[EFFORT:xhigh] 거부 후 산출 진입 → 최종 low"
assert_no_grep "[EFFORT:" "$SANDBOX/prompt.txt" "[EFFORT:xhigh] 프롬프트에서 strip"
sandbox_teardown

sandbox_setup newconf
stage_file "util.sh" 5
STUB_ARGS_OUT="$SANDBOX/args.txt" run_wrapper "[EFFORT:low2] code review please"
assert_grep "invalid effort 'low2'" "$SANDBOX/err.txt" \
  "기타 무효값 [EFFORT:low2] → 기존 generic 메시지 유지"
assert_grep 'model_reasoning_effort="low"' "$SANDBOX/args.txt" \
  "기타 무효값 → 산출 진입 (기존 경로)"
sandbox_teardown

# ------------------------------------------------------------
# Group 9 — auto-vocab (MP5-auto-vocab-low-medium-high-only,
# spec §4.5 / §8 #9). 산출 fixture 전 구간에서 _compute_effort 출력이
# {low, medium, high, 빈문자열} 을 벗어나지 않는다 (xhigh/max/ultra 부재).
# ------------------------------------------------------------
echo "-- group 9: auto-vocab"

check_vocab() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    low|medium|high|"") echo "  ok: $2 (got '${1:-<empty>}')" ;;
    *) fail "$2 (out-of-vocab output '$1')" ;;
  esac
}

check_vocab "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '3 0 a.sh')" src_compute)" \
  "소형 변경 산출 ∈ vocab"
check_vocab "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '40 0 a.sh' '40 0 b.sh')" src_compute)" \
  "중형 변경 산출 ∈ vocab"
check_vocab "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '500 0 a.sh')" src_compute)" \
  "대형 변경 산출 ∈ vocab (xhigh 미출력)"
check_vocab "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '10000 0 a.sh' '10000 0 b.sh' '1 0 c.sh' '1 0 d.sh' '1 0 e.sh')" \
  src_compute)" \
  "초대형 변경 산출 ∈ vocab (max/ultra 미출력)"
check_vocab "$(SUBJECT=working_tree USE_STUB=1 STUB_GIT_DIFF_RC=1 STUB_NUMSTAT="" src_compute)" \
  "측정 실패 → 빈 출력 ∈ vocab"
check_vocab "$(SUBJECT=bogus_mode src_compute)" \
  "알 수 없는 subject → 빈 출력 ∈ vocab"

# ------------------------------------------------------------
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
