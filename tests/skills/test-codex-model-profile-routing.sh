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
#   - stamp-evidence          (MP4, spec §4.4)  5 additive stamp fields + real source path
#   - commit-gate-regression  (MP4, spec §4.4)  pre-bash-test-commit-gate parser unbroken
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
#   D) hook sandbox: pre-bash-test-commit-gate.sh + hooks/lib copied, extended
#      (12-field) stamp fixtures, JSON-on-stdin behavioural run.
#
# The existing codex-review suites are NOT modified (separate regression).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"
CONF="$REAL_PROJECT_DIR/plugins/rein-core/config/codex-models.sh"
GATE_HOOK="$REAL_PROJECT_DIR/plugins/rein-core/hooks/pre-bash-test-commit-gate.sh"

TEST_COUNT=0
FAIL_COUNT=0
SANDBOX=""
HOOKSB=""
TMPROOT=""
WRAP_RC=0
GATE_RC=0

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
  ( cd "$SANDBOX" && CODEX_BIN="$SANDBOX/stub-codex.sh" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" CLAUDE_PLUGIN_ROOT="" \
      bash scripts/rein-codex-review.sh --non-interactive \
      <<<"$1" > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt" )
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
# Seam D — commit-gate hook sandbox (extended-stamp regression).
# ------------------------------------------------------------
hook_setup() {
  HOOKSB=$(mktemp -d "/tmp/codex-mpr-gate-XXXXXX")
  mkdir -p "$HOOKSB/.claude/hooks/lib" "$HOOKSB/trail/dod"
  cp "$GATE_HOOK" "$HOOKSB/.claude/hooks/pre-bash-test-commit-gate.sh"
  chmod +x "$HOOKSB/.claude/hooks/pre-bash-test-commit-gate.sh"
  if [ -d "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib" ]; then
    cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/." "$HOOKSB/.claude/hooks/lib/"
  elif [ -d "$REAL_PROJECT_DIR/.claude/hooks/lib" ]; then
    cp -R "$REAL_PROJECT_DIR/.claude/hooks/lib/." "$HOOKSB/.claude/hooks/lib/"
  fi
  printf '# DoD: mpr-gate-test\n- placeholder\n' \
    > "$HOOKSB/trail/dod/dod-2026-07-10-mpr-gate-test.md"
}

hook_teardown() {
  [ -n "$HOOKSB" ] && [ -d "$HOOKSB" ] && rm -rf "$HOOKSB"
  HOOKSB=""
}

# write_ext_code_stamp <verdict> <reviewed_at|skip> — the EXTENDED (12-field)
# stamp: existing 7 fields in original order + the 5 additive evidence fields
# (spec §4.4). The gate parser must keep reading only reviewed_at:/verdict:/
# cycle: and stay indifferent to the new trailing fields.
write_ext_code_stamp() {
  local ver="$1" rat="$2"
  local f="$HOOKSB/trail/dod/.codex-reviewed"
  : > "$f"
  if [ "$rat" != "skip" ]; then printf 'reviewed_at: %s\n' "$rat" >> "$f"; fi
  printf 'reviewer: codex\n' >> "$f"
  printf 'diff_base: N/A\n' >> "$f"
  printf 'verdict: %s\n' "$ver" >> "$f"
  printf 'cycle: mpr-cycle\n' >> "$f"
  printf 'scope: wrapper-generated\n' >> "$f"
  printf 'active_dod: trail/dod/dod-2026-07-10-mpr-gate-test.md\n' >> "$f"
  printf 'model: gpt-test-gate\n' >> "$f"
  printf 'effort: medium\n' >> "$f"
  printf 'effort_source: computed+floor\n' >> "$f"
  printf 'policy_version: 7\n' >> "$f"
  printf 'codex_version: codex-stub 9.9.9\n' >> "$f"
}

write_sec_stamp() {
  local f="$HOOKSB/trail/dod/.security-reviewed"
  : > "$f"
  printf 'reviewer=security-reviewer\n' >> "$f"
  printf 'reviewed=2026-06-16T02:00:00Z\n' >> "$f"
  printf 'security_level=standard\n' >> "$f"
  printf 'cycle=mpr-cycle\n' >> "$f"
  printf 'verdict=PASS\n' >> "$f"
  printf 'mechanism=llm-security-review\n' >> "$f"
}

run_gate() {
  printf '%s' '{"tool_input":{"command":"git commit -m \"feat: thing\""},"tool_result":{}}' \
    | REIN_PROJECT_DIR_OVERRIDE="$HOOKSB" \
      bash "$HOOKSB/.claude/hooks/pre-bash-test-commit-gate.sh" \
      > "$HOOKSB/gate-out.txt" 2> "$HOOKSB/gate-err.txt"
  GATE_RC=$?
}

cleanup() {
  sandbox_teardown
  hook_teardown
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
# (무모델 호출 0건) + stderr 경고 정확히 1회 + stamp policy_version: 0.
# Clean tree → effort 도 fail-closed 페어의 high 로 수렴.
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
assert_grep_e '^policy_version:[[:space:]]*0$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "canonical fallback 실행 → stamp policy_version: 0"
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
# spec §4.4 / §8 #7). PASS 도장에 5필드 추가 + 기존 7필드 잔존 +
# effort_source 가 시나리오별 실제 경로를 기록.
# ------------------------------------------------------------
echo "-- group 6: stamp-evidence"

# (a) computed 경로 + 전체 필드 세트.
sandbox_setup newconf
stage_file "util.sh" 5
run_wrapper "code review please"
STAMP="$SANDBOX/trail/dod/.codex-reviewed"
check '[ -f "$STAMP" ]' "PASS → 도장 생성"
# 기존 7필드 잔존 (additive 계약).
assert_grep_e '^reviewed_at: '            "$STAMP" "기존 필드 reviewed_at: 잔존"
assert_grep_e '^reviewer: '               "$STAMP" "기존 필드 reviewer: 잔존"
assert_grep_e '^diff_base: '              "$STAMP" "기존 필드 diff_base: 잔존"
assert_grep_e '^verdict: PASS$'           "$STAMP" "기존 필드 verdict: PASS 잔존"
assert_grep_e '^cycle:'                   "$STAMP" "기존 필드 cycle: 잔존"
assert_grep_e '^scope: wrapper-generated$' "$STAMP" "기존 필드 scope: 잔존"
assert_grep_e '^active_dod:'              "$STAMP" "기존 필드 active_dod: 잔존"
# 신규 5필드.
assert_grep_e '^model:[[:space:]]*gpt-test-gate$' "$STAMP" "신규 필드 model: 게이트 모델 기록"
assert_grep_e '^effort:[[:space:]]*low$'          "$STAMP" "신규 필드 effort: 실제 적용값(low)"
assert_grep_e '^effort_source:[[:space:]]*computed$' "$STAMP" "effort_source: computed (산출 경로)"
assert_grep_e '^policy_version:[[:space:]]*7$'    "$STAMP" "policy_version: config 값(7) 기록"
assert_grep_e '^codex_version:[[:space:]]*codex-stub 9\.9\.9$' "$STAMP" \
  "codex_version: CODEX_BIN --version 1행 기록"
sandbox_teardown

# (b) marker 경로.
sandbox_setup newconf
stage_file "util.sh" 5
run_wrapper "[EFFORT:high] code review please"
assert_grep_e '^effort:[[:space:]]*high$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "marker 시나리오 → effort: high"
assert_grep_e '^effort_source:[[:space:]]*marker$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "marker 시나리오 → effort_source: marker"
sandbox_teardown

# (c) computed+floor 경로.
sandbox_setup newconf
stage_file "hooks/x.sh" 5
run_wrapper "code review please"
assert_grep_e '^effort:[[:space:]]*medium$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "floor 승격 시나리오 → effort: medium"
assert_grep_e '^effort_source:[[:space:]]*computed\+floor$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "floor 승격 시나리오 → effort_source: computed+floor"
sandbox_teardown

# (d) fail_closed 경로 (clean tree → 측정 불가).
sandbox_setup newconf
run_wrapper "code review please"
assert_grep_e '^effort:[[:space:]]*high$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "fail-closed 시나리오 → effort: high (페어)"
assert_grep_e '^effort_source:[[:space:]]*fail_closed$' "$SANDBOX/trail/dod/.codex-reviewed" \
  "fail-closed 시나리오 → effort_source: fail_closed"
sandbox_teardown

# ------------------------------------------------------------
# Group 7 — commit-gate-regression (MP4-commit-gate-parser-unbroken,
# spec §4.4 / §8 #7). 확장(12필드) 도장으로 게이트 판정이 기존과 동일:
# PASS+fresh → 통과, NEEDS-FIX → 차단, 시각 파싱불가 → fail-closed 차단.
# 게이트 소스는 본 사이클에서 무변경 — 행위 회귀 고정.
# ------------------------------------------------------------
echo "-- group 7: commit-gate-regression"
hook_setup
write_ext_code_stamp "PASS" "2026-06-16T01:00:00Z"
write_sec_stamp
run_gate
assert_eq "$GATE_RC" "0" "확장 도장 PASS+fresh → 게이트 exit 0"
check '[ ! -s "$HOOKSB/gate-out.txt" ]' \
  "확장 도장 PASS+fresh → JSON deny 미발화 (커밋 통과)"

write_ext_code_stamp "NEEDS-FIX" "2026-06-16T01:00:00Z"
run_gate
assert_grep "CODE_REVIEW_NOT_PASSED" "$HOOKSB/gate-out.txt" \
  "확장 도장 verdict NEEDS-FIX → 기존 판정대로 차단"
assert_grep '"permissionDecision"' "$HOOKSB/gate-out.txt" \
  "NEEDS-FIX 차단이 JSON deny 로 발화"

write_ext_code_stamp "PASS" "skip"
run_gate
assert_grep "CODE_REVIEW_NOT_PASSED" "$HOOKSB/gate-out.txt" \
  "확장 도장 + reviewed_at 부재 → fail-closed 차단 (기존과 동일)"
hook_teardown

# 래퍼측 도장 파서 회귀: 확장 도장의 diff_base:/reviewed_at: 파싱이 기존과
# 동일하게 동작 (fresh stamp → 저장된 diff_base 채택).
mk_fixture "$FIX2"
( cd "$FIX2" && git commit --allow-empty -q -m second )
BASE_SHA=$(git -C "$FIX2" rev-parse HEAD~1)
cat > "$FIX2/trail/dod/.codex-reviewed" <<STAMP
reviewed_at: 2099-01-01T00:00:00Z
reviewer: codex
diff_base: ${BASE_SHA}
verdict: PASS
cycle: mpr-cycle
scope: wrapper-generated
active_dod: trail/dod/dod-x.md
model: gpt-test-gate
effort: medium
effort_source: computed+floor
policy_version: 7
codex_version: codex-stub 9.9.9
STAMP
_db_out=$(
  export REIN_PROJECT_DIR_OVERRIDE="$FIX2"
  # shellcheck disable=SC1090
  source "$WRAPPER" </dev/null >/dev/null 2>&1
  set +eu +o pipefail 2>/dev/null
  PROJECT_DIR="$FIX2"
  _resolve_diff_base
)
assert_eq "$_db_out" "$BASE_SHA" \
  "확장 도장에서 _resolve_diff_base 가 저장된 diff_base 를 그대로 채택 (파서 비파손)"

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
