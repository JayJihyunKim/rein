#!/usr/bin/env bash
# tests/skills/test-codex-effort-deterministic.sh
#
# TDD (red) — Plan 2026-06-26-codex-effort-deterministic, Phase 1 Task 1.1.
#
# Fixes the contract of the deterministic effort computation that the wrapper
# (`plugins/rein-core/scripts/rein-codex-review.sh`) gains in Phase 2:
#   _compute_effort()                  — dispatcher keyed on REVIEW_SUBJECT.
#   _map_code_effort_from_numstat(src) — src ∈ {diff_head, range}; numstat → level.
#   _map_doc_effort(n)                 — doc line count → level.
# These functions DO NOT EXIST YET, so this file is expected to be RED until
# the wrapper-impl wave lands (parent confirms green after Phase 2). A handful
# of end-to-end asserts already match current behaviour (marker priority,
# fail-closed high) and stay green across the wave — that is intentional.
#
# Two seams (both idioms borrowed from test-codex-model-failsoft.sh /
# test-codex-review-wrapper.sh):
#
#  A) source-with-controlled-env (function-level). The wrapper is `source`d
#     with stdin redirected from /dev/null (neutralises the top-level
#     `PROMPT_BODY=$(cat)`); PROJECT_DIR is pointed at a fixture git repo via
#     REIN_PROJECT_DIR_OVERRIDE. The main orchestration block is guarded by
#     `[ "${BASH_SOURCE[0]}" = "$0" ]`, so sourcing only DEFINES functions and
#     resolves top-level context (no codex call). After sourcing we override
#     the globals (REVIEW_SUBJECT / SPEC_REVIEW_SUBJECT / DIFF_BASE) and call
#     the functions directly. Code-size numstat is controlled by a PATH-leading
#     stub `git` (canned numstat + per-call log); doc size by a real temp file
#     whose line count drives `wc -l`.
#
#  B) end-to-end (process + CODEX_BIN stub). The wrapper runs as a real process
#     against a failsoft-style sandbox; a stub codex captures the `--config
#     model_reasoning_effort="<level>"` argument (and the envelope on stdin) so
#     marker priority / invalid-marker strip / fail-closed final resolution can
#     be asserted on the actual flag the wrapper emits.
#
# The two existing codex-review suites are NOT modified (separate regression).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"

TEST_COUNT=0
FAIL_COUNT=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" = "$2" ]; then echo "  ok: $3"
  else fail "$3 (expected='$2' got='$1')"; fi
}
assert_empty() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ -z "$1" ]; then echo "  ok: $2"
  else fail "$2 (expected empty, got='$1')"; fi
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

find_lib() {
  if [ -f "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  elif [ -f "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  fi
}

# Build a tab-separated numstat from "added deleted path" specs.
mk_numstat() {
  local spec
  for spec in "$@"; do
    # shellcheck disable=SC2086
    set -- $spec
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  done
}

# ------------------------------------------------------------
# Shared fixtures (created once).
# ------------------------------------------------------------
TMPROOT=""
E2E=""

# mk_fixture <dir> <commit:0|1> — minimal rein project root the wrapper can
# source against (trail/ + bundled select-active-dod lib + git repo).
mk_fixture() {
  local dir="$1" commit="$2" lib
  mkdir -p "$dir/trail/dod" "$dir/.claude/hooks/lib"
  lib="$(find_lib)"
  [ -n "$lib" ] || { echo "mk_fixture: select-active-dod.sh not found" >&2; return 1; }
  cp "$lib" "$dir/.claude/hooks/lib/select-active-dod.sh"
  cp "$(dirname "$lib")/path-containment.sh" \
     "$dir/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  ( cd "$dir" && git init -q && git config user.email t@e.com && git config user.name t
    if [ "$commit" = "1" ]; then git commit --allow-empty -q -m init; fi )
}

# Stub `git`: logs every invocation to $STUB_GIT_LOG and, for any `--numstat`
# call, prints $STUB_NUMSTAT and exits $STUB_GIT_DIFF_RC. All other subcommands
# succeed silently. Used only AFTER sourcing (real git did the source), so the
# log captures exactly the calls _compute_effort itself makes.
mk_stub_git() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/git" <<'GIT'
#!/usr/bin/env bash
[ -n "${STUB_GIT_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_GIT_LOG"
for _a in "$@"; do
  if [ "$_a" = "--numstat" ]; then
    printf '%s' "${STUB_NUMSTAT:-}"
    exit "${STUB_GIT_DIFF_RC:-0}"
  fi
done
exit 0
GIT
  chmod +x "$dir/git"
}

# src_compute — source the wrapper against $FIX, override globals from env
# (SUBJECT / SPEC_SUBJ / DBASE), optionally front the PATH with the stub git
# (USE_STUB=1), then call _compute_effort and emit its stdout.
src_compute() {
  (
    export REIN_PROJECT_DIR_OVERRIDE="$FIX"
    # shellcheck disable=SC1090
    source "$WRAPPER" </dev/null >/dev/null 2>&1
    set +eu +o pipefail
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

# src_call — source the wrapper against $FIX, then eval an arbitrary function
# call (used for the pure _map_doc_effort threshold table).
src_call() {
  (
    export REIN_PROJECT_DIR_OVERRIDE="$FIX"
    # shellcheck disable=SC1090
    source "$WRAPPER" </dev/null >/dev/null 2>&1
    set +eu +o pipefail
    eval "$1"
  )
}

# ------------------------------------------------------------
# End-to-end sandbox (failsoft pattern).
# ------------------------------------------------------------
e2e_setup() {
  # $1 = small | large | clean (staged change size in the sandbox).
  E2E=$(mktemp -d "/tmp/codex-effort-e2e-XXXXXX")
  mkdir -p "$E2E/scripts" "$E2E/config" "$E2E/trail/dod" "$E2E/.claude/hooks/lib"
  cp "$WRAPPER" "$E2E/scripts/rein-codex-review.sh"
  chmod +x "$E2E/scripts/rein-codex-review.sh"
  local lib; lib="$(find_lib)"
  cp "$lib" "$E2E/.claude/hooks/lib/select-active-dod.sh"
  cp "$(dirname "$lib")/path-containment.sh" \
     "$E2E/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cat > "$E2E/config/codex-models.sh" <<'CONF'
ANALYSIS_MODEL="gpt-test-analysis"
CODE_MODEL="gpt-test-code"
ANALYSIS_EFFORT="high"
CODE_EFFORT="high"
CONF
  cat > "$E2E/stub-codex.sh" <<'STUB'
#!/usr/bin/env bash
set -u
[ -n "${STUB_ARGS_OUT:-}" ] && printf '%s\n' "$*" > "$STUB_ARGS_OUT"
if [ -n "${STUB_PROMPT_OUT:-}" ]; then cat > "$STUB_PROMPT_OUT"; else cat >/dev/null; fi
printf '%s\n' "${STUB_VERDICT:-PASS
clean}"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$E2E/stub-codex.sh"
  ( cd "$E2E" && git init -q && git config user.email t@e.com && git config user.name t \
    && git commit --allow-empty -q -m init )
  case "$1" in
    small) ( cd "$E2E" && seq 1 8   > small.sh && git add small.sh ) ;;
    large) ( cd "$E2E" && seq 1 200 > big.sh   && git add big.sh ) ;;
    clean) : ;;  # nothing staged → measurement impossible
  esac
}

# e2e_run <prompt> — caller passes STUB_ARGS_OUT / STUB_PROMPT_OUT via inline env.
e2e_run() {
  ( cd "$E2E" && CODEX_BIN="$E2E/stub-codex.sh" REIN_PROJECT_DIR_OVERRIDE="$E2E" \
      bash scripts/rein-codex-review.sh --non-interactive \
      <<<"$1" > "$E2E/out.txt" 2> "$E2E/err.txt" )
}

e2e_teardown() {
  [ -n "${E2E:-}" ] && [ -d "$E2E" ] && rm -rf "$E2E"
  E2E=""
}

cleanup() {
  [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
  e2e_teardown
}
trap cleanup EXIT

# ------------------------------------------------------------
# Setup.
# ------------------------------------------------------------
TMPROOT=$(mktemp -d "/tmp/codex-effort-XXXXXX")
FIX="$TMPROOT/fix"             # committed fixture (sourcing target)
FIX_NOHEAD="$TMPROOT/fix-nohead"  # pre-first-commit fixture (HEAD absent)
STUBDIR="$TMPROOT/stub"
LOG="$TMPROOT/gitcalls.log"

mk_fixture "$FIX" 1
mk_fixture "$FIX_NOHEAD" 0
mk_stub_git "$STUBDIR"
mkdir -p "$FIX/docs"
seq 1 120 > "$FIX/docs/spec120.md"   # 120-line doc for docsize-wc

echo "== codex deterministic effort tests =="

# ------------------------------------------------------------
# Group 1 — doc-thresholds (E2-doclen-maps-to-level).
#   low ≤150 ; medium 151–400 ; high >400.
# ------------------------------------------------------------
echo "-- group 1: doc-thresholds"
assert_eq "$(src_call '_map_doc_effort 150')" "low"    "doc 150줄 → low"
assert_eq "$(src_call '_map_doc_effort 151')" "medium" "doc 151줄 → medium"
assert_eq "$(src_call '_map_doc_effort 400')" "medium" "doc 400줄 → medium"
assert_eq "$(src_call '_map_doc_effort 401')" "high"   "doc 401줄 → high"

# ------------------------------------------------------------
# Group 2 — code-thresholds (E2-codesize-maps-to-level).
#   low=(≤10줄 AND ≤1파일) 또는 all-docs; medium=≤100줄 AND ≤3파일;
#   high=>100줄 또는 >3파일. numstat fed via stub git.
# ------------------------------------------------------------
echo "-- group 2: code-thresholds"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '8 0 f1.sh')" src_compute)" "low" \
  "code (a) 8줄/1파일 → low"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '70 0 a.md' '70 0 b.md' '60 0 c.md')" src_compute)" "low" \
  "code (b) .md 3파일 200줄 → low (all-docs)"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '100 0 docs/x.sh' '100 0 a.md')" src_compute)" "high" \
  "code (c) docs/x.sh+a.md 200줄 → high (.sh 가 all-docs 차단)"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '30 0 f1.sh' '30 0 f2.sh')" src_compute)" "medium" \
  "code (d) 60줄/2파일 → medium"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '60 0 f1.sh' '60 0 f2.sh')" src_compute)" "high" \
  "code (e) 120줄/2파일 → high (>100줄)"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '2 0 f1.sh' '2 0 f2.sh' '2 0 f3.sh' '2 0 f4.sh')" src_compute)" "high" \
  "code (f) 8줄/4파일 → high (>3파일)"

# ------------------------------------------------------------
# Group 3 — all-docs extension gate (spec §8 #13).
#   확장자 화이트리스트로만 판정 — .md/.markdown/.txt/.rst 전용 → 줄수 무관 low;
#   docs/ prefix 라도 코드 확장자 섞이면 줄수 임계로 분류.
# ------------------------------------------------------------
echo "-- group 3: all-docs extension gate"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '5000 0 big.md')" src_compute)" "low" \
  "all-docs: .md 5000줄 → low (줄수 무관)"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '120 0 README.md' '80 0 docs/guide.markdown')" src_compute)" "low" \
  "all-docs: .md/.markdown 전용 → low"
assert_eq "$(SUBJECT=working_tree USE_STUB=1 \
  STUB_NUMSTAT="$(mk_numstat '5 0 docs/x.sh' '5 0 a.md')" src_compute)" "medium" \
  "all-docs 차단: docs/.sh 포함 10줄/2파일 → medium (임계 분류)"

# ------------------------------------------------------------
# Group 4 — subject-mirror (E1-codesize-mirrors-subject).
#   working_tree → `git diff HEAD --numstat`;
#   commit_range → `git diff <DIFF_BASE>..HEAD --numstat`. Verify via call log.
# ------------------------------------------------------------
echo "-- group 4: subject-mirror"
: > "$LOG"
SUBJECT=working_tree USE_STUB=1 STUB_NUMSTAT="$(mk_numstat '5 0 f.sh')" \
  STUB_GIT_LOG="$LOG" src_compute >/dev/null
assert_grep    "diff HEAD --numstat" "$LOG" "working_tree → git diff HEAD --numstat"
assert_no_grep "..HEAD --numstat"    "$LOG" "working_tree → 범위 diff 미사용"
: > "$LOG"
SUBJECT=commit_range DBASE=BASEREF USE_STUB=1 STUB_NUMSTAT="$(mk_numstat '5 0 f.sh')" \
  STUB_GIT_LOG="$LOG" src_compute >/dev/null
assert_grep    "diff BASEREF..HEAD --numstat" "$LOG" "commit_range → git diff DIFF_BASE..HEAD --numstat"
assert_no_grep "diff HEAD --numstat"          "$LOG" "commit_range → working-tree diff 미사용"

# ------------------------------------------------------------
# Group 5 — docsize-wc (E1-docsize-wc).
#   spec 모드는 wc -l 경로 (git diff 호출 0건). 미존재 subject → 빈 출력.
# ------------------------------------------------------------
echo "-- group 5: docsize-wc"
: > "$LOG"
assert_eq "$(SUBJECT=spec SPEC_SUBJ="docs/spec120.md" USE_STUB=1 \
  STUB_GIT_LOG="$LOG" src_compute)" "low" \
  "spec 120줄 문서 → low (wc -l 경로)"
assert_no_grep "diff" "$LOG" "spec 산출 경로에서 git diff 호출 0건"
assert_empty "$(SUBJECT=spec SPEC_SUBJ="docs/NOPE.md" src_compute)" \
  "spec 미존재 subject → 빈 출력"

# ------------------------------------------------------------
# Group 6 — marker-priority (E1-compute-gated-on-empty-marker).
#   [EFFORT:low] + 대형 변경 → 최종 low (마커가 산출 high 를 덮음). end-to-end.
# ------------------------------------------------------------
echo "-- group 6: marker-priority"
e2e_setup large
STUB_ARGS_OUT="$E2E/args.txt" e2e_run "[EFFORT:low] code review please"
assert_grep 'model_reasoning_effort="low"' "$E2E/args.txt" \
  "marker [EFFORT:low] + 대형변경 → 최종 effort low"
e2e_teardown

# ------------------------------------------------------------
# Group 7 — invalid-marker (E3-invalid-marker-warn-compute).
#   [EFFORT:xyz] + 소형 → 최종 low + stderr warn + 프롬프트에서 strip.
# ------------------------------------------------------------
echo "-- group 7: invalid-marker"
e2e_setup small
STUB_ARGS_OUT="$E2E/args.txt" STUB_PROMPT_OUT="$E2E/prompt.txt" \
  e2e_run "[EFFORT:xyz] code review please"
assert_grep    'model_reasoning_effort="low"' "$E2E/args.txt"  "invalid marker + 소형 → 산출 low"
assert_grep    "invalid effort"               "$E2E/err.txt"   "invalid marker → stderr warn 1회"
assert_no_grep "[EFFORT:"                      "$E2E/prompt.txt" "invalid marker → codex 프롬프트에서 strip"
e2e_teardown

# ------------------------------------------------------------
# Group 8 — fail-closed (E3-fail-closed-high).
#   산출 빈 출력(측정 실패/불가) → 폴백 high. git 강제 실패 + unknown subject
#   → 빈 출력(전제); clean 샌드박스(측정 불가) → 최종 high(end-to-end 폴백).
# ------------------------------------------------------------
echo "-- group 8: fail-closed"
assert_empty "$(SUBJECT=working_tree USE_STUB=1 STUB_GIT_DIFF_RC=1 STUB_NUMSTAT="" src_compute)" \
  "fail-closed: git diff 강제 실패(stub rc=1) → 빈 출력"
assert_empty "$(SUBJECT=bogus_mode src_compute)" \
  "fail-closed: 알 수 없는 REVIEW_SUBJECT → 빈 출력"
e2e_setup clean
STUB_ARGS_OUT="$E2E/args.txt" e2e_run "code review please"
assert_grep 'model_reasoning_effort="high"' "$E2E/args.txt" \
  "fail-closed: 측정 불가(clean) + CODE_EFFORT=high → 최종 high"
e2e_teardown

# ------------------------------------------------------------
# Group 9 — reescalation-invariant (E5).
#   [EFFORT:high](재승급 모사) + 소형 → 최종 high (산출 low 가 못 덮음). e2e.
# ------------------------------------------------------------
echo "-- group 9: reescalation-invariant"
e2e_setup small
STUB_ARGS_OUT="$E2E/args.txt" e2e_run "[EFFORT:high] code review please"
assert_grep 'model_reasoning_effort="high"' "$E2E/args.txt" \
  "재승급 [EFFORT:high] + 소형 → 최종 high"
e2e_teardown

# ------------------------------------------------------------
# Group 10 — HEAD-부재 경로 (spec §8 #12).
#   pre-first-commit fixture(HEAD 미존재) + numstat 빈 출력 → 빈 출력
#   (--cached 강등 후에도 비어있음). 폴백 high 로 수렴; 스크립트 비-사망.
# ------------------------------------------------------------
echo "-- group 10: HEAD-absent path"
assert_empty "$(FIX="$FIX_NOHEAD" SUBJECT=working_tree src_compute)" \
  "HEAD-부재 + numstat 빈 출력 → _compute_effort 빈 출력 (폴백 high, 비-사망)"

# ------------------------------------------------------------
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
