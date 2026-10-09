#!/usr/bin/env bash
# tests/skills/test-review-precheck-hook.sh
#
# 리뷰 전 프로젝트 사전 검사 훅 행위 계약 스위트 (PC1~PC19).
# (spec docs/specs/2026-10-08-affected-tests-and-precheck.md §3.3 · §3.6.1 (3),
#  plan docs/plans/2026-10-08-affected-tests-and-precheck.md Task 1.8)
#
# Scope 매핑:
#   ATP-PRECHECK          실패·시간 초과·실행 불가·비일반 mode → exit 4, 환경 변수, 출력 상한  → PC2~PC4·PC9·PC11~PC16
#   ATP-PRECHECK-TRUST    working_tree=HEAD 판 / commit_range=DIFF_BASE 판, 작업 트리 판 미실행 → PC5·PC6·PC10·PC17·PC18
#                         (기준 판 트리 전체를 임시 디렉터리로 꺼내 cwd 로 실행 — source 하는 helper 도 기준 판,
#                          BASH_ENV·내보낸 함수 차단, 작업 트리는 REIN_PRECHECK_TARGET 데이터로만,
#                          트리 밖을 가리키는 심볼릭 링크는 추출 전에 거부 → PC18, PC18(f))
#   (정리)                사전 검사가 권한을 바꿔도 임시 트리 삭제                           → PC19
#   ATP-PRECHECK-TIMEOUT  setsid/perl 프로세스 그룹 + 1초 폴링, timeout/pgrep 비의존         → PC4·PC7·PC8
#   ATP-PRECHECK-NOOP     스크립트 부재·spec-review 모드 무변경                              → PC1·PC13
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh
# Idiom: e2e sandbox = mktemp -d + git init + CODEX_BIN fake-codex
# (test-review-selfverify-gate.sh 와 같은 하니스).
# 표식 파일(ran-*)·env.log·gc.pid 는 샌드박스 밖($OUTSIDE)에 둔다 — 샌드박스 안에
# 쓰면 미추적 변경이 되어 리뷰 대상이 바뀐다.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER_REL="plugins/rein-core/scripts/rein-codex-review.sh"
WRAPPER_SRC="$REAL_PROJECT_DIR/$WRAPPER_REL"
WRAPPER_ROOT_COPY="$REAL_PROJECT_DIR/scripts/rein-codex-review.sh"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"
BASE_REF="eab97a1"
BASH_BIN="$(command -v bash)"
REAL_GIT="$(command -v git)"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
nok()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else nok "$3 (expected='$2' got='$1')"; fi
}
assert_contains() {
  case "$1" in *"$2"*) ok "$3" ;; *) nok "$3 (missing '$2')" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) nok "$3 (unexpected '$2')" ;; *) ok "$3" ;; esac
}
assert_capture_exists() {
  if [ -f "$CAPTURE" ]; then ok "$1"; else nok "$1 (fake codex 미호출 — 캡처 없음)"; fi
}
assert_no_capture() {
  if [ ! -f "$CAPTURE" ]; then ok "$1"; else nok "$1 (fake codex 가 호출됨 — spawn 이전 종료 계약 위반)"; fi
}
assert_marker() {   # <표식> <설명>
  if [ -e "$OUTSIDE/$1" ]; then ok "$2"; else nok "$2 (표식 $1 없음 — 스크립트 미실행)"; fi
}
assert_no_marker() {   # <표식> <설명>
  if [ ! -e "$OUTSIDE/$1" ]; then ok "$2"; else nok "$2 (표식 $1 존재 — 실행되면 안 되는 판이 실행됨)"; fi
}
assert_err_line() {   # <grep -E 패턴> <설명>  (stderr 의 라인 앵커 존재)
  if grep -Eq -- "$1" "$SANDBOX/.err.txt" 2>/dev/null; then ok "$2"; else nok "$2 (stderr 에 패턴 없음: $1)"; fi
}
assert_subject() {   # <mode> <설명>  (fake codex 캡처의 review_subject: 줄)
  if grep -q "^review_subject: $1\$" "$CAPTURE" 2>/dev/null; then ok "$2"; else nok "$2 (캡처의 review_subject 가 $1 아님)"; fi
}

find_lib() {
  if [ -f "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  elif [ -f "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  fi
}
LIB="$(find_lib)"
[ -n "$LIB" ] || { echo "FATAL: select-active-dod.sh not found" >&2; exit 1; }
LIB_DIR="$(dirname "$LIB")"

SANDBOX=""
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/rein-precheck-out-XXXXXX")"
MON_PID=""
cleanup() {
  [ -n "${MON_PID:-}" ] && kill "$MON_PID" 2>/dev/null
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  [ -n "${OUTSIDE:-}" ] && [ -d "$OUTSIDE" ] && rm -rf "$OUTSIDE"
}
trap cleanup EXIT

# 요청서 고정 문자열 (자가검증 관문 통과용)
REQ=$'review please\nverification_commands: none\ndiff_self_review: checked every hunk by hand\n'

e2e_setup() {
  SANDBOX=$(mktemp -d "/tmp/rein-precheck-e2e-XXXXXX")
  rm -rf "$OUTSIDE"; mkdir -p "$OUTSIDE"   # 케이스마다 비운다
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  cat > "$SANDBOX/.gitignore" <<'IGN'
.gitignore
.stdin.txt
.out.txt
.err.txt
.capture*
tmpdir/
trail/
.claude/cache/
bin/
.restricted-bin/
scripts/rein-codex-review-base.sh
IGN
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git add -A && git commit -q -m base \
    && git commit --allow-empty -q -m head )
}
e2e_teardown() {
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# 추적 변경 1개 (working_tree 모드 전제)
mk_dirty() {
  echo change > "$SANDBOX/f.txt"
  ( cd "$SANDBOX" && git add f.txt )
}

# commit_precheck "<본문>" — .rein/review-precheck.sh 를 쓰고 커밋한다.
# 본문의 @OUT@ 은 쓸 때 $OUTSIDE 값으로 펼친다.
write_precheck() {
  mkdir -p "$SANDBOX/.rein"
  printf '%s\n' "${1//@OUT@/$OUTSIDE}" > "$SANDBOX/.rein/review-precheck.sh"
}
commit_precheck() {
  write_precheck "$1"
  ( cd "$SANDBOX" && git add -f .rein/review-precheck.sh && git commit -q -m "precheck: ${2:-update}" )
}

# 제한 PATH 디렉터리 — /usr/bin·/bin 실행 파일을 링크하되 인자로 준 이름은 뺀다.
mk_restricted_bin() {
  local rb="$SANDBOX/.restricted-bin" omit=" $* " d f name p
  mkdir -p "$rb"
  for d in /usr/bin /bin; do
    for f in "$d"/*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      name="${f##*/}"
      case "$omit" in *" $name "*) continue ;; esac
      [ -e "$rb/$name" ] || ln -sf "$f" "$rb/$name"
    done
  done
  for name in git python3 bash; do
    case "$omit" in *" $name "*) continue ;; esac
    [ -e "$rb/$name" ] && continue
    p="$(command -v "$name" 2>/dev/null)" || continue
    ln -sf "$p" "$rb/$name"
  done
}

# 프로세스 생존 (좀비는 죽은 것으로 본다)
proc_alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  if [ -r "/proc/$1/stat" ]; then
    st=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)
    [ "$st" != "Z" ]
  else
    return 0
  fi
}

# run_wrapper <stdin-content> [extra wrapper args...]
#   WRAPPER_PATH   : 실행할 래퍼 (기본 샌드박스 사본)
#   WRAP_PATH_ONLY : 있으면 PATH 를 그 디렉터리 하나로 대체
RC=""; OUT=""; ERR=""; CAPTURE=""; ELAPSED=0
run_wrapper() {
  local stdin_content="$1" t0 t1; shift
  CAPTURE="$SANDBOX/.capture.txt"
  rm -f "$CAPTURE"
  printf '%s' "$stdin_content" > "$SANDBOX/.stdin.txt"
  t0=$(date +%s)
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$CAPTURE"
    export TMPDIR="$SANDBOX/tmpdir"
    if [ -n "${WRAP_PATH_ONLY:-}" ]; then export PATH="$WRAP_PATH_ONLY"; fi
    "$BASH_BIN" "${WRAPPER_PATH:-$SANDBOX/scripts/rein-codex-review.sh}" --non-interactive "$@" \
      < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
  )
  RC=$?
  t1=$(date +%s)
  ELAPSED=$((t1 - t0))
  OUT=$(cat "$SANDBOX/.out.txt")
  ERR=$(cat "$SANDBOX/.err.txt")
}

# 꺼낸 기준 판 트리 임시 디렉터리 잔존 수 (정리 계약)
tree_dirs_left() {
  find "$SANDBOX/tmpdir" -maxdepth 1 -name 'rein-precheck-tree.*' 2>/dev/null | wc -l | tr -d ' '
}

review_round_files() {
  find "$SANDBOX/trail/dod/.review-rounds" -type f 2>/dev/null | wc -l | tr -d ' '
}

echo "== review precheck hook tests =="

# ============================================================
echo "-- PC1: 부재 (기준 ref·작업 트리 모두 없음) → 무변경 (ATP-PRECHECK-NOOP)"
e2e_setup
mk_dirty
run_wrapper "$REQ"
assert_capture_exists "PC1 codex 도달 (캡처 존재)"
assert_not_contains "$ERR" "사전 검사" "PC1 stderr 에 '사전 검사' 0건"
assert_subject "working_tree" "PC1 working_tree 모드"
new_rc="$RC"; new_err="$ERR"
if "$REAL_GIT" -C "$REAL_PROJECT_DIR" cat-file -e "$BASE_REF:$WRAPPER_REL" 2>/dev/null; then
  "$REAL_GIT" -C "$REAL_PROJECT_DIR" show "$BASE_REF:$WRAPPER_REL" > "$SANDBOX/scripts/rein-codex-review-base.sh"
  WRAPPER_PATH="$SANDBOX/scripts/rein-codex-review-base.sh" run_wrapper "$REQ"
  assert_eq "$new_rc" "$RC" "PC1 rc 가 같은 샌드박스의 base 판 실행과 같음"
  assert_eq "$new_err" "$ERR" "PC1 stderr 가 base 판 실행과 같음"
else
  assert_eq "$new_rc" "0" "PC1 base 판을 못 꺼내는 환경 — rc 0 비교로 대체"
fi
e2e_teardown

# ============================================================
echo "-- PC2: 실패 → exit 4 + 라인 앵커 진단 + 발췌, codex 미호출, 회차 비소모"
e2e_setup
commit_precheck 'echo "lint: fd not closed at a.py:3"; exit 1'
mk_dirty
run_wrapper "$REQ"
assert_eq "$RC" "4" "PC2 rc 4"
assert_err_line '^ERROR: \[codex-review\]\[readiness-reject\] 프로젝트 사전 검사 실패 — rc=1' "PC2 거부 진단행 (라인 앵커)"
assert_err_line '^ERROR: \[codex-review\]\[readiness-reject\]   .*lint: fd not closed' "PC2 발췌 줄에 스크립트 출력"
assert_no_capture "PC2 codex 미호출"
assert_eq "$(review_round_files)" "0" "PC2 회차 파일 0개 (회차 비소모)"
assert_eq "$(tree_dirs_left)" "0" "PC2 실패 경로에서도 기준 판 트리 임시 디렉터리 삭제"
e2e_teardown

# ============================================================
echo "-- PC3: 통과 → codex 도달, 사전 검사 출력 없음"
e2e_setup
commit_precheck 'exit 0'
mk_dirty
run_wrapper "$REQ"
assert_capture_exists "PC3 codex 도달"
assert_not_contains "$ERR" "프로젝트 사전 검사" "PC3 stderr 에 '프로젝트 사전 검사' 0건"
assert_subject "working_tree" "PC3 working_tree 모드"
e2e_teardown

# ============================================================
echo "-- PC4: 시간 초과 → exit 4, 15초 안에 종료"
e2e_setup
commit_precheck 'sleep 30'
mk_dirty
export REIN_REVIEW_PRECHECK_TIMEOUT=1
run_wrapper "$REQ"
unset REIN_REVIEW_PRECHECK_TIMEOUT
assert_eq "$RC" "4" "PC4 rc 4"
assert_contains "$ERR" "시간 초과 — 1초" "PC4 시간 초과 진단"
if [ "$ELAPSED" -lt 15 ]; then ok "PC4 경과 ${ELAPSED}초 < 15초"; else nok "PC4 경과 ${ELAPSED}초 (15초 이상)"; fi
assert_no_capture "PC4 codex 미호출"
e2e_teardown

# ============================================================
echo "-- PC5: working_tree 3케이스 — HEAD 판만 실행 (D12)"
echo "   (a-1) 작업 트리 수정본 (미스테이지)"
e2e_setup
commit_precheck 'touch "@OUT@/ran-head"; exit 0'
write_precheck 'touch "@OUT@/ran-wt"; exit 1'
mk_dirty
run_wrapper "$REQ"
assert_marker "ran-head" "PC5(a) 미스테이지 수정본 — HEAD 판 실행됨"
assert_no_marker "ran-wt" "PC5(a) 미스테이지 수정본 — 작업 트리 판 미실행"
assert_capture_exists "PC5(a) 미스테이지 — codex 도달"
assert_subject "working_tree" "PC5(a) 미스테이지 — working_tree 모드"
e2e_teardown
echo "   (a-2) 작업 트리 수정본 (스테이지)"
e2e_setup
commit_precheck 'touch "@OUT@/ran-head"; exit 0'
write_precheck 'touch "@OUT@/ran-wt"; exit 1'
( cd "$SANDBOX" && git add -f .rein/review-precheck.sh )
mk_dirty
run_wrapper "$REQ"
assert_marker "ran-head" "PC5(a) 스테이지 수정본 — HEAD 판 실행됨"
assert_no_marker "ran-wt" "PC5(a) 스테이지 수정본 — 작업 트리 판 미실행"
assert_capture_exists "PC5(a) 스테이지 — codex 도달"
e2e_teardown
echo "   (b) 작업 트리에서 스크립트 삭제"
e2e_setup
commit_precheck 'touch "@OUT@/ran-head"; exit 0'
rm -f "$SANDBOX/.rein/review-precheck.sh"
mk_dirty
run_wrapper "$REQ"
assert_marker "ran-head" "PC5(b) 작업 트리 삭제 — HEAD 판 실행됨"
assert_capture_exists "PC5(b) codex 도달"
e2e_teardown
echo "   (c-1) HEAD 에 없는 새 스크립트 (미추적)"
e2e_setup
write_precheck 'touch "@OUT@/ran-wt"; exit 1'
mk_dirty
run_wrapper "$REQ"
assert_no_marker "ran-wt" "PC5(c) 미추적 새 스크립트 — 미실행"
assert_capture_exists "PC5(c) 미추적 — codex 도달"
assert_err_line '^WARNING: \[codex-review\]\[readiness-advisory\] 사전 검사 스크립트 \.rein/review-precheck\.sh 가 검토 기준\(HEAD\)에 없다' "PC5(c) 미추적 — advisory 경고"
e2e_teardown
echo "   (c-2) HEAD 에 없는 새 스크립트 (신규 스테이징)"
e2e_setup
write_precheck 'touch "@OUT@/ran-wt"; exit 1'
( cd "$SANDBOX" && git add -f .rein/review-precheck.sh )
mk_dirty
run_wrapper "$REQ"
assert_no_marker "ran-wt" "PC5(c) 신규 스테이징 스크립트 — 미실행"
assert_capture_exists "PC5(c) 신규 스테이징 — codex 도달"
assert_err_line '^WARNING: \[codex-review\]\[readiness-advisory\] 사전 검사 스크립트 \.rein/review-precheck\.sh 가 검토 기준\(HEAD\)에 없다' "PC5(c) 신규 스테이징 — advisory 경고"
e2e_teardown

# ============================================================
echo "-- PC6: commit_range 3케이스 — DIFF_BASE 판만 실행 (D12)"
echo "   (a) 검토 대상 커밋이 스크립트를 추가"
e2e_setup
commit_precheck 'touch "@OUT@/ran-new"; exit 1' "add"
run_wrapper "$REQ"
assert_no_marker "ran-new" "PC6(a) 추가된 판 미실행"
assert_capture_exists "PC6(a) codex 도달"
assert_subject "commit_range" "PC6(a) commit_range 모드"
assert_err_line '^WARNING: \[codex-review\]\[readiness-advisory\] 사전 검사 스크립트 \.rein/review-precheck\.sh 가 검토 기준\(.*\)에 없다' "PC6(a) advisory 경고"
e2e_teardown
echo "   (b) 검토 대상 커밋이 스크립트를 수정"
e2e_setup
commit_precheck 'touch "@OUT@/ran-base"; exit 0' "base version"
commit_precheck 'touch "@OUT@/ran-new"; exit 1' "modify"
run_wrapper "$REQ"
assert_marker "ran-base" "PC6(b) DIFF_BASE 판 실행됨"
assert_no_marker "ran-new" "PC6(b) 수정된 판 미실행"
assert_capture_exists "PC6(b) codex 도달"
assert_subject "commit_range" "PC6(b) commit_range 모드"
e2e_teardown
echo "   (c) 검토 대상 커밋이 스크립트를 삭제"
e2e_setup
commit_precheck 'touch "@OUT@/ran-base"; exit 1' "base version"
( cd "$SANDBOX" && git rm -q -f .rein/review-precheck.sh && git commit -q -m "delete precheck" )
run_wrapper "$REQ"
assert_marker "ran-base" "PC6(c) DIFF_BASE 판 실행됨"
assert_eq "$RC" "4" "PC6(c) DIFF_BASE 판이 실패 → rc 4"
assert_no_capture "PC6(c) codex 미호출"
e2e_teardown

# ============================================================
echo "-- PC7: 프로세스 그룹·도구 부재 경로 (D13) — timeout·gtimeout·setsid·pgrep 없는 PATH"
echo "   (a) sleep 30 + 제한 1초"
e2e_setup
commit_precheck 'sleep 30'
mk_dirty
mk_restricted_bin timeout gtimeout setsid pgrep
export REIN_REVIEW_PRECHECK_TIMEOUT=1
WRAP_PATH_ONLY="$SANDBOX/.restricted-bin" run_wrapper "$REQ"
unset REIN_REVIEW_PRECHECK_TIMEOUT
assert_eq "$RC" "4" "PC7(a) rc 4"
assert_contains "$ERR" "시간 초과" "PC7(a) 시간 초과 진단"
if [ "$ELAPSED" -lt 15 ]; then ok "PC7(a) 경과 ${ELAPSED}초 < 15초"; else nok "PC7(a) 경과 ${ELAPSED}초 (15초 이상)"; fi
e2e_teardown
echo "   (b) 손자 프로세스 정리"
e2e_setup
commit_precheck "bash -c 'sleep 30' & echo \$! > \"@OUT@/gc.pid\"; sleep 30"
mk_dirty
mk_restricted_bin timeout gtimeout setsid pgrep
export REIN_REVIEW_PRECHECK_TIMEOUT=1
WRAP_PATH_ONLY="$SANDBOX/.restricted-bin" run_wrapper "$REQ"
unset REIN_REVIEW_PRECHECK_TIMEOUT
gc_pid="$(cat "$OUTSIDE/gc.pid" 2>/dev/null || true)"
if [ -z "$gc_pid" ]; then
  nok "PC7(b) 손자 pid 기록 없음 (스크립트 미실행)"
else
  n=0; while proc_alive "$gc_pid" && [ "$n" -lt 6 ]; do sleep 0.5; n=$((n + 1)); done
  if proc_alive "$gc_pid"; then nok "PC7(b) 래퍼 종료 후에도 손자 프로세스 생존 (pid=$gc_pid)"; kill -KILL "$gc_pid" 2>/dev/null
  else ok "PC7(b) 래퍼 종료 후 손자 프로세스 없음"; fi
fi
assert_eq "$RC" "4" "PC7(b) rc 4"
e2e_teardown
echo "   (c) 통과 스크립트"
e2e_setup
commit_precheck 'exit 0'
mk_dirty
mk_restricted_bin timeout gtimeout setsid pgrep
WRAP_PATH_ONLY="$SANDBOX/.restricted-bin" run_wrapper "$REQ"
assert_capture_exists "PC7(c) codex 도달"
assert_not_contains "$ERR" "프로젝트 사전 검사" "PC7(c) 사전 검사 출력 없음"
e2e_teardown
echo "   (d) perl 도 없음 → 거부"
e2e_setup
commit_precheck 'exit 0'
mk_dirty
mk_restricted_bin timeout gtimeout setsid pgrep perl
WRAP_PATH_ONLY="$SANDBOX/.restricted-bin" run_wrapper "$REQ"
assert_eq "$RC" "4" "PC7(d) rc 4"
assert_contains "$ERR" "프로세스 그룹 도구(setsid·perl)가 없어" "PC7(d) 도구 부재 진단"
assert_no_capture "PC7(d) codex 미호출"
e2e_teardown

# ============================================================
echo "-- PC8: setsid 가 있는 기본 PATH 에서도 손자 프로세스 정리"
e2e_setup
commit_precheck "bash -c 'sleep 30' & echo \$! > \"@OUT@/gc.pid\"; sleep 30"
mk_dirty
export REIN_REVIEW_PRECHECK_TIMEOUT=1
run_wrapper "$REQ"
unset REIN_REVIEW_PRECHECK_TIMEOUT
gc_pid="$(cat "$OUTSIDE/gc.pid" 2>/dev/null || true)"
if [ -z "$gc_pid" ]; then
  nok "PC8 손자 pid 기록 없음 (스크립트 미실행)"
else
  n=0; while proc_alive "$gc_pid" && [ "$n" -lt 6 ]; do sleep 0.5; n=$((n + 1)); done
  if proc_alive "$gc_pid"; then nok "PC8 래퍼 종료 후에도 손자 프로세스 생존 (pid=$gc_pid)"; kill -KILL "$gc_pid" 2>/dev/null
  else ok "PC8 래퍼 종료 후 손자 프로세스 없음"; fi
fi
assert_eq "$RC" "4" "PC8 rc 4"
e2e_teardown

# ============================================================
echo "-- PC9: 기준 판이 심볼릭 링크 → 거부, 링크 대상 미실행"
e2e_setup
printf '%s\n' "touch \"$OUTSIDE/ran-link\"" > "$OUTSIDE/p.sh"
mkdir -p "$SANDBOX/.rein"
ln -s "$OUTSIDE/p.sh" "$SANDBOX/.rein/review-precheck.sh"
( cd "$SANDBOX" && git add -f .rein/review-precheck.sh && git commit -q -m "symlink precheck" )
mk_dirty
run_wrapper "$REQ"
assert_eq "$RC" "4" "PC9 rc 4"
assert_contains "$ERR" "일반 파일이 아니다" "PC9 비일반 파일 진단"
assert_no_marker "ran-link" "PC9 링크 대상 미실행"
assert_no_capture "PC9 codex 미호출"
e2e_teardown

# ============================================================
echo "-- PC10: 작업 트리 .rein 이 밖으로 가는 심볼릭 링크 → HEAD 판만 실행"
e2e_setup
commit_precheck 'touch "@OUT@/ran-head"; exit 0'
mkdir -p "$OUTSIDE/outrein"
printf '%s\n' "touch \"$OUTSIDE/ran-out\"" > "$OUTSIDE/outrein/review-precheck.sh"
rm -rf "$SANDBOX/.rein"
ln -s "$OUTSIDE/outrein" "$SANDBOX/.rein"
mk_dirty
run_wrapper "$REQ"
assert_no_marker "ran-out" "PC10 링크 대상 미실행"
assert_marker "ran-head" "PC10 HEAD 판 실행됨"
e2e_teardown

# ============================================================
echo "-- PC11: 환경 변수 전달"
ENV_BODY='{
  echo "PROJECT_DIR=$REIN_PRECHECK_PROJECT_DIR"
  echo "CHANGED_RC=$REIN_PRECHECK_CHANGED_FILES_RC"
  echo "SUBJECT=$REIN_PRECHECK_REVIEW_SUBJECT"
  echo "DIFF_BASE=$REIN_PRECHECK_DIFF_BASE"
  echo "PWD=$(pwd)"
  echo "TARGET=$REIN_PRECHECK_TARGET"
  [ -f .rein/review-precheck.sh ] && echo "CWD_HAS_SCRIPT=y"
  [ -e .git ] || echo "CWD_NO_GIT=y"
  echo "TARGET_F=$(cat "$REIN_PRECHECK_TARGET/f.txt" 2>/dev/null)"
  echo "--files"
  cat "$REIN_PRECHECK_CHANGED_FILES"
} > "@OUT@/env.log"
exit 0'
echo "   (a) working_tree"
e2e_setup
commit_precheck "$ENV_BODY"
mk_dirty
run_wrapper "$REQ"
envlog="$(cat "$OUTSIDE/env.log" 2>/dev/null || true)"
sb_real="$(cd "$SANDBOX" && pwd -P)"
assert_capture_exists "PC11(a) codex 도달"
pd="$(printf '%s\n' "$envlog" | sed -n 's/^PROJECT_DIR=//p')"
if [ "$pd" = "$SANDBOX" ] || [ "$pd" = "$sb_real" ]; then ok "PC11(a) REIN_PRECHECK_PROJECT_DIR 가 샌드박스 경로"; else nok "PC11(a) PROJECT_DIR='$pd'"; fi
pw="$(printf '%s\n' "$envlog" | sed -n 's/^PWD=//p')"
if [ -n "$pw" ] && [ "$pw" != "$SANDBOX" ] && [ "$pw" != "$sb_real" ]; then ok "PC11(a) pwd 가 샌드박스가 아님 (기준 판 트리)"; else nok "PC11(a) pwd='$pw'"; fi
case "$pw" in */rein-precheck-tree.*) ok "PC11(a) pwd 가 rein-precheck-tree 임시 디렉터리" ;; *) nok "PC11(a) pwd='$pw' 가 임시 트리 아님" ;; esac
if [ -n "$pw" ] && [ ! -e "$pw" ]; then ok "PC11(a) 실행 뒤 임시 트리 삭제됨"; else nok "PC11(a) 임시 트리 잔존 ('$pw')"; fi
assert_contains "$envlog" "CWD_HAS_SCRIPT=y" "PC11(a) cwd 에 기준 판 스크립트 존재"
assert_contains "$envlog" "CWD_NO_GIT=y" "PC11(a) cwd 에 .git 없음 (archive 트리)"
tg="$(printf '%s\n' "$envlog" | sed -n 's/^TARGET=//p')"
if [ "$tg" = "$SANDBOX" ] || [ "$tg" = "$sb_real" ]; then ok "PC11(a) REIN_PRECHECK_TARGET 가 샌드박스 경로"; else nok "PC11(a) TARGET='$tg'"; fi
assert_contains "$envlog" "TARGET_F=change" "PC11(a) \$REIN_PRECHECK_TARGET 로 현재 작업 트리 파일 읽기"
assert_contains "$envlog" "f.txt" "PC11(a) 변경 목록에 바뀐 파일"
assert_contains "$envlog" "CHANGED_RC=0" "PC11(a) REIN_PRECHECK_CHANGED_FILES_RC=0"
assert_contains "$envlog" "SUBJECT=working_tree" "PC11(a) REIN_PRECHECK_REVIEW_SUBJECT=working_tree"
cap_base="$(sed -n 's/^diff_base: //p' "$CAPTURE" 2>/dev/null | head -1)"
env_base="$(printf '%s\n' "$envlog" | sed -n 's/^DIFF_BASE=//p')"
if [ -n "$cap_base" ] && [ "$env_base" = "$cap_base" ]; then ok "PC11(a) REIN_PRECHECK_DIFF_BASE 가 캡처의 diff_base 와 같음"; else nok "PC11(a) DIFF_BASE env='$env_base' capture='$cap_base'"; fi
e2e_teardown
echo "   (b) commit_range"
e2e_setup
commit_precheck "$ENV_BODY" "env logger"
echo g > "$SANDBOX/g.txt"
( cd "$SANDBOX" && git add g.txt && git commit -q -m "add g" )
run_wrapper "$REQ"
envlog="$(cat "$OUTSIDE/env.log" 2>/dev/null || true)"
assert_capture_exists "PC11(b) codex 도달"
assert_contains "$envlog" "SUBJECT=commit_range" "PC11(b) REIN_PRECHECK_REVIEW_SUBJECT=commit_range"
cap_base="$(sed -n 's/^diff_base: //p' "$CAPTURE" 2>/dev/null | head -1)"
env_base="$(printf '%s\n' "$envlog" | sed -n 's/^DIFF_BASE=//p')"
if [ -n "$cap_base" ] && [ "$env_base" = "$cap_base" ]; then ok "PC11(b) REIN_PRECHECK_DIFF_BASE 가 캡처의 diff_base 와 같음"; else nok "PC11(b) DIFF_BASE env='$env_base' capture='$cap_base'"; fi
e2e_teardown

# ============================================================
echo "-- PC12: 출력 상한 — 2 MiB 출력해도 임시 파일 ≤ 1 MiB, rc 는 스크립트 rc"
e2e_setup
commit_precheck 'yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -c 2097152; sleep 2; exit 1'
mk_dirty
echo 0 > "$OUTSIDE/mon.max"
(
  max=0
  while [ ! -f "$OUTSIDE/mon.stop" ]; do
    for f in "$SANDBOX"/tmpdir/rein-readiness.*; do
      [ -f "$f" ] || continue
      s=$(wc -c < "$f" | tr -d ' ')
      [ "$s" -gt "$max" ] && max="$s"
    done
    echo "$max" > "$OUTSIDE/mon.max"
    sleep 0.2
  done
) &
MON_PID=$!
run_wrapper "$REQ"
touch "$OUTSIDE/mon.stop"
wait "$MON_PID" 2>/dev/null
MON_PID=""
max_size="$(cat "$OUTSIDE/mon.max" 2>/dev/null || echo 0)"
if [ "$max_size" -le 1048576 ]; then ok "PC12 임시 파일 최대 크기 ${max_size} ≤ 1048576"; else nok "PC12 임시 파일 최대 크기 ${max_size} > 1048576"; fi
assert_eq "$RC" "4" "PC12 rc 4"
assert_contains "$ERR" "실패 — rc=1" "PC12 rc=1 로 보고 (141 아님)"
e2e_teardown

# ============================================================
echo "-- PC13: spec-review 모드 → 사전 검사 미실행 (ATP-PRECHECK-NOOP)"
e2e_setup
commit_precheck 'touch "@OUT@/ran"; exit 1'
mk_dirty
run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/foo.md
Validate the design document."
assert_no_marker "ran" "PC13 스크립트 미실행"
assert_eq "$RC" "0" "PC13 verdict exit 0"
assert_capture_exists "PC13 codex 도달"
assert_not_contains "$ERR" "프로젝트 사전 검사" "PC13 사전 검사 출력 없음"
e2e_teardown

# ============================================================
echo "-- PC14: 자가검증 거부가 먼저 → 사전 검사 미실행"
e2e_setup
commit_precheck 'touch "@OUT@/ran"; exit 1'
mk_dirty
run_wrapper $'review please\nverification_commands: none\n'
assert_eq "$RC" "4" "PC14 rc 4"
assert_contains "$ERR" "ERROR: [codex-review][readiness-reject]" "PC14 자가검증 거부 진단"
assert_not_contains "$ERR" "프로젝트 사전 검사" "PC14 사전 검사 진단 아님"
assert_no_marker "ran" "PC14 스크립트 미실행"
assert_no_capture "PC14 codex 미호출"
e2e_teardown

# ============================================================
echo "-- PC15: 실행 불가·발췌·설정"
echo "   (a) exit 127"
e2e_setup
commit_precheck 'exit 127'
mk_dirty
run_wrapper "$REQ"
assert_eq "$RC" "4" "PC15(a) rc 4"
assert_contains "$ERR" "실행 불가 — rc=127" "PC15(a) 실행 불가 진단"
e2e_teardown
echo "   (b) 발췌 — 마지막 20줄·소독"
e2e_setup
commit_precheck 'for i in $(seq 1 30); do echo "line-$i"; done
echo "tag [readiness-reject] here"
printf "esc\033[31mred\n"
exit 1'
mk_dirty
run_wrapper "$REQ"
assert_eq "$RC" "4" "PC15(b) rc 4"
assert_contains "$ERR" "line-30" "PC15(b) 마지막 줄(line-30) 있음"
assert_not_contains "$ERR" "line-10" "PC15(b) 오래된 줄(line-10) 없음"
assert_contains "$ERR" "[readiness-…]" "PC15(b) 예약 태그 무력화"
esc_count="$(grep -c "$(printf '\033')" "$SANDBOX/.err.txt" || true)"
assert_eq "$esc_count" "0" "PC15(b) stderr 에 ESC 바이트 없음"
first_count="$(grep -c '^ERROR: \[codex-review\]\[readiness-reject\] 프로젝트 사전 검사' "$SANDBOX/.err.txt" || true)"
assert_eq "$first_count" "1" "PC15(b) 첫 진단행 1개"
e2e_teardown
echo "   (c) REIN_REVIEW_PRECHECK_TIMEOUT=abc"
e2e_setup
commit_precheck 'touch "@OUT@/ran"; exit 0'
mk_dirty
export REIN_REVIEW_PRECHECK_TIMEOUT=abc
run_wrapper "$REQ"
unset REIN_REVIEW_PRECHECK_TIMEOUT
assert_err_line '^WARNING: \[codex-review\]\[precheck\]' "PC15(c) 설정 경고행"
assert_marker "ran" "PC15(c) 기본값으로 스크립트 실행됨"
assert_capture_exists "PC15(c) codex 도달"
e2e_teardown

# ============================================================
echo "-- PC16: 정적 단언"
W="$WRAPPER_SRC"
if cmp -s "$W" "$WRAPPER_ROOT_COPY"; then ok "PC16 두 사본 cmp 동일"; else nok "PC16 두 사본이 다름"; fi
a=$(grep -n '^  _selfverify_check || exit 4$' "$W" | cut -d: -f1 | head -1)
b=$(grep -n '^  _review_precheck_run || exit 4$' "$W" | cut -d: -f1 | head -1)
c=$(grep -n '_round_budget_check || _rb_rc=\$?' "$W" | cut -d: -f1 | head -1)
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then
  ok "PC16 호출 순서 자가검증($a) < 사전 검사($b) < 회차 예산($c)"
else
  nok "PC16 호출 순서 위반 (a='$a' b='$b' c='$c')"
fi
S=$(grep -n '^# ---- 프로젝트 사전 검사 훅' "$W" | cut -d: -f1 | head -1)
if [ -n "$S" ] && [ -n "$b" ]; then
  block="$(sed -n "${S},${b}p" "$W")"
  tool_calls="$(printf '%s\n' "$block" | grep -v '^[[:space:]]*#' | grep -cE '(^|[[:space:];|&(])(timeout|gtimeout|pgrep)[[:space:]]' || true)"
  assert_eq "$tool_calls" "0" "PC16 블록 안 timeout·gtimeout·pgrep 호출 0건"
  direct_exec="$(printf '%s\n' "$block" | grep -cF 'bash "$PROJECT_DIR/$REIN_REVIEW_PRECHECK_REL"' || true)"
  assert_eq "$direct_exec" "0" "PC16 작업 트리 직접 실행 0건"
  arch_calls="$(printf '%s\n' "$block" | grep -cF 'git -C "$PROJECT_DIR" archive' || true)"
  if [ "$arch_calls" -ge 1 ]; then ok "PC16 ref 트리를 꺼내는 git archive 호출 ${arch_calls}건"; else nok "PC16 git -C \"\$PROJECT_DIR\" archive 호출 없음"; fi
  cd_proj="$(printf '%s\n' "$block" | grep -cF 'cd "$PROJECT_DIR"' || true)"
  assert_eq "$cd_proj" "0" "PC16 작업 트리를 cwd 로 쓰는 cd \$PROJECT_DIR 0건"
  for v in BASH_ENV ENV CDPATH; do
    if printf '%s\n' "$block" | grep -qE -- "-u $v( |\))"; then ok "PC16 env -u $v"; else nok "PC16 env -u $v 없음"; fi
  done
else
  nok "PC16 사전 검사 블록 앵커를 찾지 못함 (S='$S' b='$b')"
fi

# ============================================================
echo "-- PC17: 신뢰 경계 — source 하는 helper·셸 시작 환경 (ATP-PRECHECK-TRUST)"
# write_helper "<본문>" — .rein/precheck-helper.sh (@OUT@ 펼침)
write_helper() {
  mkdir -p "$SANDBOX/.rein"
  printf '%s\n' "${1//@OUT@/$OUTSIDE}" > "$SANDBOX/.rein/precheck-helper.sh"
}
HELPER_ENTRY='. .rein/precheck-helper.sh
exit 0'
echo "   (a) working_tree — 작업 트리에서만 바뀐 helper 는 실행되지 않는다"
e2e_setup
write_helper 'touch "@OUT@/ran-helper-base"'
( cd "$SANDBOX" && git add -f .rein/precheck-helper.sh )
commit_precheck "$HELPER_ENTRY" "entry + helper"
write_helper 'touch "@OUT@/ran-helper-wt"'
mk_dirty
run_wrapper "$REQ"
assert_marker "ran-helper-base" "PC17(a) HEAD 판 helper 실행됨"
assert_no_marker "ran-helper-wt" "PC17(a) 작업 트리 helper 미실행"
assert_capture_exists "PC17(a) codex 도달"
assert_eq "$(tree_dirs_left)" "0" "PC17(a) 기준 판 트리 임시 디렉터리 삭제"
e2e_teardown
echo "   (a-2) working_tree — 스테이지된 helper 변경도 실행되지 않는다"
e2e_setup
write_helper 'touch "@OUT@/ran-helper-base"'
( cd "$SANDBOX" && git add -f .rein/precheck-helper.sh )
commit_precheck "$HELPER_ENTRY" "entry + helper"
write_helper 'touch "@OUT@/ran-helper-wt"'
( cd "$SANDBOX" && git add -f .rein/precheck-helper.sh )
mk_dirty
run_wrapper "$REQ"
assert_marker "ran-helper-base" "PC17(a-2) HEAD 판 helper 실행됨"
assert_no_marker "ran-helper-wt" "PC17(a-2) 스테이지된 helper 미실행"
e2e_teardown
echo "   (b) BASH_ENV·내보낸 함수가 사전 검사에 닿지 않는다"
e2e_setup
commit_precheck 'rein_pc_probe 2>/dev/null
touch "@OUT@/ran-pc"
exit 0'
mk_dirty
# 래퍼 자신도 BASH_ENV 를 source 하므로, 사전 검사 환경에만 있는 변수로 조건을 건다.
printf '%s\n' "[ -n \"\${REIN_PRECHECK_REVIEW_SUBJECT:-}\" ] && touch \"$OUTSIDE/ran-bashenv\"; true" > "$OUTSIDE/bashenv.sh"
rein_pc_probe() { touch "$OUTSIDE/ran-func"; }
export -f rein_pc_probe
export BASH_ENV="$OUTSIDE/bashenv.sh"
run_wrapper "$REQ"
unset BASH_ENV
export -nf rein_pc_probe; unset -f rein_pc_probe
assert_marker "ran-pc" "PC17(b) 사전 검사 실행됨"
assert_no_marker "ran-bashenv" "PC17(b) BASH_ENV 파일 미실행"
assert_no_marker "ran-func" "PC17(b) 내보낸 함수 미상속"
assert_capture_exists "PC17(b) codex 도달"
e2e_teardown
echo "   (c) commit_range — DIFF_BASE 판 helper 가 쓰인다"
e2e_setup
write_helper 'touch "@OUT@/ran-helper-base"'
( cd "$SANDBOX" && git add -f .rein/precheck-helper.sh )
commit_precheck "$HELPER_ENTRY" "entry + helper base"
write_helper 'touch "@OUT@/ran-helper-new"'
( cd "$SANDBOX" && git add -f .rein/precheck-helper.sh && git commit -q -m "modify helper" )
run_wrapper "$REQ"
assert_subject "commit_range" "PC17(c) commit_range 모드"
assert_marker "ran-helper-base" "PC17(c) DIFF_BASE 판 helper 실행됨"
assert_no_marker "ran-helper-new" "PC17(c) 검토 대상 커밋의 helper 미실행"
assert_capture_exists "PC17(c) codex 도달"
e2e_teardown
echo "   (d) 트리 추출 불가 (python3 없음 — 검사·추출은 python3 tarfile 단일 호출) → 실행 불가 거부"
e2e_setup
commit_precheck 'touch "@OUT@/ran"; exit 0'
mk_dirty
mk_restricted_bin python3
WRAP_PATH_ONLY="$SANDBOX/.restricted-bin" run_wrapper "$REQ"
assert_eq "$RC" "4" "PC17(d) rc 4"
assert_err_line '^ERROR: \[codex-review\]\[readiness-reject\] 프로젝트 사전 검사 실행 불가 — 검토 기준\(HEAD\) 트리를' "PC17(d) 실행 불가 진단행"
assert_no_marker "ran" "PC17(d) 스크립트 미실행"
assert_no_capture "PC17(d) codex 미호출"
assert_eq "$(tree_dirs_left)" "0" "PC17(d) 거부 경로에서도 임시 디렉터리 삭제"
e2e_teardown

# ============================================================
echo "-- PC18: 신뢰 경계 — 기준 판 트리의 심볼릭 링크 (ATP-PRECHECK-TRUST)"
# commit_helper_link "<링크 대상>" — .rein/precheck-helper.sh 를 심볼릭 링크로 커밋하고
# 엔트리가 그 helper 를 source 하게 한다.
commit_helper_link() {
  mkdir -p "$SANDBOX/.rein"
  rm -f "$SANDBOX/.rein/precheck-helper.sh"
  ln -s "$1" "$SANDBOX/.rein/precheck-helper.sh"
  ( cd "$SANDBOX" && git add -f .rein/precheck-helper.sh )
  commit_precheck ". .rein/precheck-helper.sh
touch \"@OUT@/ran-entry\"
exit 0" "entry + helper link"
}
# pc18_reject <설명 접두> — 거부 계약 공통 단언
pc18_reject() {
  assert_eq "$RC" "4" "$1 rc 4"
  assert_err_line '^ERROR: \[codex-review\]\[readiness-reject\] 프로젝트 사전 검사 실행 불가 — 검토 기준\(HEAD\) 트리에 밖을 가리키는 링크' "$1 실행 불가 진단행"
  assert_no_marker "ran-entry" "$1 사전 검사 미실행"
  assert_no_marker "ran-ext" "$1 링크 대상 helper 미실행"
  assert_no_capture "$1 codex 미호출"
  assert_eq "$(review_round_files)" "0" "$1 회차 비소모"
  assert_eq "$(tree_dirs_left)" "0" "$1 임시 트리 미잔존"
}
echo "   (a) helper 가 작업 트리 밖 파일을 가리키는 절대 경로 링크 → 거부"
e2e_setup
printf '%s\n' "touch \"$OUTSIDE/ran-ext\"" > "$OUTSIDE/ext-helper.sh"
commit_helper_link "$OUTSIDE/ext-helper.sh"
mk_dirty
run_wrapper "$REQ"
pc18_reject "PC18(a)"
e2e_teardown
echo "   (a-2) helper 가 작업 트리 파일을 가리키는 절대 경로 링크 → 거부"
e2e_setup
printf '%s\n' "touch \"$OUTSIDE/ran-ext\"" > "$SANDBOX/wt-helper.sh"
( cd "$SANDBOX" && git add -f wt-helper.sh && git commit -q -m "wt helper" )
commit_helper_link "$SANDBOX/wt-helper.sh"
mk_dirty
run_wrapper "$REQ"
pc18_reject "PC18(a-2)"
e2e_teardown
echo "   (b) helper -> /dev/null → 거부"
e2e_setup
commit_helper_link "/dev/null"
mk_dirty
run_wrapper "$REQ"
pc18_reject "PC18(b)"
e2e_teardown
echo "   (c) 상대 경로로 루트를 벗어나는 링크 → 거부"
e2e_setup
commit_helper_link "../../../ext-helper.sh"
mk_dirty
run_wrapper "$REQ"
pc18_reject "PC18(c)"
e2e_teardown
echo "   (d) 다른 링크를 거쳐 밖으로 나가는 링크 (.rein/up -> .. , helper -> up/../x) → 거부"
e2e_setup
mkdir -p "$SANDBOX/.rein"
ln -s .. "$SANDBOX/.rein/up"
( cd "$SANDBOX" && git add -f .rein/up )
commit_helper_link "up/../ext-helper.sh"
mk_dirty
run_wrapper "$REQ"
pc18_reject "PC18(d)"
e2e_teardown
echo "   (e) 트리 안을 가리키는 상대 링크는 허용되어 실행된다"
e2e_setup
mkdir -p "$SANDBOX/.rein"
printf '%s\n' "touch \"$OUTSIDE/ran-helper-base\"" > "$SANDBOX/.rein/real-helper.sh"
( cd "$SANDBOX" && git add -f .rein/real-helper.sh )
commit_helper_link "real-helper.sh"
mk_dirty
run_wrapper "$REQ"
assert_marker "ran-helper-base" "PC18(e) 링크 대상(트리 안) helper 실행됨"
assert_marker "ran-entry" "PC18(e) 사전 검사 끝까지 실행됨"
assert_capture_exists "PC18(e) codex 도달"
assert_eq "$(tree_dirs_left)" "0" "PC18(e) 임시 트리 미잔존"
e2e_teardown
echo "   (f) 밖을 가리키는 링크가 있는 아카이브는 아무것도 꺼내지 않고 거부한다 (검사 → 추출 순서)"
e2e_setup
printf '%s\n' "touch \"$OUTSIDE/ran-ext\"" > "$OUTSIDE/ext-helper.sh"
printf 'sentinel\n' > "$SANDBOX/pc18f-sentinel.txt"
( cd "$SANDBOX" && git add -f pc18f-sentinel.txt )
commit_helper_link "$OUTSIDE/ext-helper.sh"
mk_dirty
mk_restricted_bin
# rm 대리: 임시 트리를 지우기 직전 그 안의 항목 수를 기록한다 (추출 후 거부면 0 이 아니다)
rm -f "$SANDBOX/.restricted-bin/rm"
REAL_RM="$(command -v rm)"
cat > "$SANDBOX/.restricted-bin/rm" <<SHIM
#!$BASH_BIN
for a in "\$@"; do
  case "\$a" in
    */rein-precheck-tree.*) [ -d "\$a" ] && find "\$a" -mindepth 1 2>/dev/null | wc -l | tr -d ' ' >> "$OUTSIDE/tree-entries-at-drop" ;;
  esac
done
exec "$REAL_RM" "\$@"
SHIM
chmod +x "$SANDBOX/.restricted-bin/rm"
WRAP_PATH_ONLY="$SANDBOX/.restricted-bin" run_wrapper "$REQ"
pc18_reject "PC18(f)"
if [ -f "$OUTSIDE/tree-entries-at-drop" ]; then
  assert_eq "$(sort -u "$OUTSIDE/tree-entries-at-drop" | tr '\n' ' ')" "0 " "PC18(f) 거부 시점 임시 트리에 꺼낸 항목 0개"
else
  assert_eq "missing" "present" "PC18(f) 임시 트리 삭제 관찰 기록 존재"
fi
e2e_teardown

# ============================================================
echo "-- PC19: 정리 — 사전 검사가 권한을 바꿔도 임시 트리가 남지 않는다"
echo "   (a) 자기 cwd(트리 루트)를 chmod 000"
e2e_setup
commit_precheck 'touch "@OUT@/ran"
chmod 000 .
exit 0'
mk_dirty
run_wrapper "$REQ"
assert_marker "ran" "PC19(a) 사전 검사 실행됨"
assert_capture_exists "PC19(a) codex 도달"
assert_eq "$(tree_dirs_left)" "0" "PC19(a) 임시 트리 미잔존"
assert_not_contains "$ERR" "임시 트리를 지우지 못했다" "PC19(a) 정리 실패 경고 없음"
find "$SANDBOX/tmpdir" -maxdepth 1 -name 'rein-precheck-tree.*' -exec chmod -R u+rwx {} + 2>/dev/null
e2e_teardown
echo "   (b) 하위 디렉터리 chmod 000 + 실패 종료 (거부 경로)"
e2e_setup
commit_precheck 'touch "@OUT@/ran"
chmod 000 .rein
exit 3'
mk_dirty
run_wrapper "$REQ"
assert_eq "$RC" "4" "PC19(b) rc 4"
assert_marker "ran" "PC19(b) 사전 검사 실행됨"
assert_no_capture "PC19(b) codex 미호출"
assert_eq "$(tree_dirs_left)" "0" "PC19(b) 임시 트리 미잔존"
find "$SANDBOX/tmpdir" -maxdepth 1 -name 'rein-precheck-tree.*' -exec chmod -R u+rwx {} + 2>/dev/null
e2e_teardown

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
