#!/usr/bin/env bash
# tests/skills/test-review-watchdog.sh
#
# 워치독(리뷰 시간상한 + 생존 검진) 행위 계약 스위트 — RED-first authoring.
# (spec docs/specs/2026-07-22-review-time-cap.md §4/§8,
#  plan docs/plans/2026-07-22-review-time-cap.md Task 1.2)
#
# Scope 매핑 (케이스 ↔ behavior Scope ID):
#   W1  상한 전 완료 무회귀 + capture 계약 + 조기 완료 무지연
#       → wrapper-enforces-per-effort-primary-cap-… / wrapper-feeds-envelope-…
#   W2  성장 유예 후 완료 (유예 회귀 가드, baseline GREEN)
#       → watchdog-defers-kill-indefinitely-… / completed-run-restores-codex-out-…
#   W3  연속 2창 정지 → exit 5 + 앵커 + 부분 스풀
#       → watchdog-terminates-codex-after-two-consecutive-… / timeout-verdict-exits-5-…
#   W4  TERM 무시 → KILL → 잔존 0        → wrapper-terminates-stalled-codex-with-term-…
#   W5  1창 무성장 후 성장 재개 = 카운터 리셋 (오탐 회귀 가드, baseline GREEN)
#       → watchdog-terminates-codex-after-two-consecutive-… (카운터 리셋 절)
#   W5b 정지 판정 직전 자연 종료 경계 (R2 High-A) → watchdog-terminates-… 경계
#   W6  raw codex exit 5 passthrough (앵커 0) → caller-discriminates-…
#   W7  예약 앵커 리터럴 소독            → emitted-spool-sanitizes-…
#   W8  --version 프로브 면역            → fake-codex-version-probe-…
#   W9a 내부 오류 정규화 (단위 seam)     → watchdog-internal-failure-normalizes-…
#   W9b 내부 오류 정규화 (e2e, wc shim)  → watchdog-internal-failure-normalizes-…
#   W10 비정상 래퍼 종료 cleanup (TERM/INT) → abnormal-wrapper-exit-reaps-…
#       / wrapper-clears-child-pid-immediately-after-every-reap-…
#   W11 spec-review timeout 표식 무접촉  → timeout-path-touches-no-review-stamp-…
#       / spec-review-mode-applies-identical-effort-caps-…
#   W12 resolver 단위 seam               → watchdog-timing-resolver-rejects-invalid-…
#
# 하니스 규율 (plan Task 1.2):
#   - sandbox 관용구 = test-review-selfverify-gate.sh 동일 (mktemp -d + git init
#     + CODEX_BIN 주입 + REIN_PROJECT_DIR_OVERRIDE). code-review 케이스는 전부
#     CLEAN tree — v1.6.2 자가검증 관문이 skip 되어 spawn 에 도달한다.
#   - fake-codex fixture 는 케이스 sandbox 안으로 **복사**해 CODEX_BIN 으로
#     주입한다 (plan 리뷰 Medium-2 + R2 High-B) — argv 에 sandbox 경로가 들어가
#     `pgrep -f "$SANDBOX"` 잔존 검사가 실제 child 를 식별한다.
#   - STALL 계열(W3/W4/W9b/W10/W11)은 감독자 run_wrapper_supervised 관할:
#     background 실행 + 1초 폴링 + deadline 초과 시 TERM→KILL + pkill 정리 후
#     sentinel RC 124 — assert 가 FAIL 로 집계한다 (워치독 부재 RED 단계에서도
#     스위트는 절대 행에 빠지지 않는다).
#   - 행위 케이스는 전부 REIN_WATCHDOG_{CAP,INTERVAL,GRACE}_OVERRIDE 유효값 —
#     정책 기본값(120s~) 실시간 대기 금지 (R2 Medium-3).
#   - 타이밍 마진 (plan 리뷰 Medium-1): 성장 지속 W2 = drip(1s) < 창(2s),
#     카운터 리셋 W5 = 창(2s) < drip(3s) < 창 2개(4s).
#   - 러너 등록은 Task 4.1 (GREEN 전환 후) — run-all.sh 에 미리 걸지 않는다.
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh
# (mirror parity 는 tests/scripts/test-plugin-scripts-bundle.sh 소관).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER_SRC="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"
WRAPPER_SCRIPTS_DIR="$REAL_PROJECT_DIR/plugins/rein-core/scripts"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

TEST_COUNT=0
FAIL_COUNT=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" = "$2" ]; then echo "  ok: $3"
  else fail "$3 (expected='$2' got='$1')"; fi
}
assert_neq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" != "$2" ]; then echo "  ok: $3"
  else fail "$3 (unexpected '$2')"; fi
}
assert_contains() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    *"$2"*) echo "  ok: $3" ;;
    *) fail "$3 (missing '$2')" ;;
  esac
}
assert_ge() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" -ge "$2" ] 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (expected >= $2, got '$1')"; fi
}
assert_le() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" -le "$2" ] 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (expected <= $2, got '$1')"; fi
}
assert_file_exists() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ -f "$1" ]; then echo "  ok: $2"
  else fail "$2 (file missing: $1)"; fi
}
assert_file_absent() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ ! -f "$1" ]; then echo "  ok: $2"
  else fail "$2 (file unexpectedly exists: $1)"; fi
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
cleanup() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    pkill -9 -f "$SANDBOX" 2>/dev/null
    rm -rf "$SANDBOX"
  fi
  return 0
}
trap cleanup EXIT

# 케이스 sandbox: clean tree (자가검증 관문 skip — A6-empty 관용구 재사용).
# 케이스 전용 TMPDIR = $SANDBOX/tmpdir (케이스마다 fresh — rein-readiness.*
# 잔존 비교는 이 안에서만).
e2e_setup() {
  SANDBOX=$(mktemp -d "/tmp/rein-watchdog-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  # fake-codex 를 sandbox 안으로 복사 — pgrep -f "$SANDBOX" 잔존 검사가 실제
  # child argv 를 식별하게 한다 (저장소 fixture 경로 직접 주입 금지).
  cp "$FAKE_CODEX" "$SANDBOX/fake-codex.sh"
  chmod +x "$SANDBOX/fake-codex.sh"
  # 하네스 준비물은 커밋, 런타임 부산물은 .gitignore — clean tree 유지
  # (test-review-selfverify-gate.sh 관용구).
  cat > "$SANDBOX/.gitignore" <<'IGN'
.gitignore
.stdin.txt
.out.txt
.err.txt
.capture*
.src.*
.sup.err
.wpid
.w12err.*
fake-codex.sh
probe.txt
empty.txt
stub/
tmpdir/
trail/
.claude/cache/
IGN
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git add -A && git commit -q -m base \
    && git commit --allow-empty -q -m head )
}
e2e_teardown() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    pkill -9 -f "$SANDBOX" 2>/dev/null
    rm -rf "$SANDBOX"
  fi
  SANDBOX=""
}

count_anchor() {
  # $1 = file. 라인 시작 anchored 매치만 (substring 검색 금지 — spec §4.3).
  if [ -f "$1" ]; then
    grep -c '^ERROR: \[codex-review\]\[review-timeout\]' "$1" || true
  else
    echo 0
  fi
}

sandbox_residue() {
  pgrep -f "$SANDBOX" 2>/dev/null | wc -l | tr -d ' '
}

readiness_listing() {
  ls "$SANDBOX/tmpdir"/rein-readiness.* 2>/dev/null | sort
}

dod_snapshot() {
  (
    cd "$SANDBOX" || exit 0
    {
      [ -f trail/dod/.codex-reviewed ] && cksum trail/dod/.codex-reviewed
      [ -f trail/dod/.review-pending ] && cksum trail/dod/.review-pending
      [ -d trail/dod/.spec-reviews ] && find trail/dod/.spec-reviews -type f -exec cksum {} \; 2>/dev/null
      true
    } | sort
  )
}

# ---------------------------------------------------------------
# 감독자 러너 (plan 리뷰 High-1 — 테스트 하니스 전용, production 아님):
# 래퍼를 background 실행 → deadline 까지 1초 폴링 → 초과 시 TERM→KILL +
# `pkill -f "$SANDBOX"` 잔존 정리 + wait reap → sentinel RC 124 보고.
# ---------------------------------------------------------------
RC=""; OUT=""; ERR=""; CAPTURE=""; WALL=""
run_wrapper_supervised() {
  local deadline="$1"; shift
  local stdin_content="$1"; shift
  CAPTURE="$SANDBOX/.capture.txt"
  rm -f "$CAPTURE"
  printf '%s' "$stdin_content" > "$SANDBOX/.stdin.txt"
  local t0 t1 wpid waited=0
  t0=$(date +%s)
  (
    cd "$SANDBOX"
    export CODEX_BIN="$SANDBOX/fake-codex.sh"
    export FAKE_CODEX_CAPTURE="$CAPTURE"
    export TMPDIR="$SANDBOX/tmpdir"
    export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
    exec bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive "$@" \
      < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
  ) &
  wpid=$!
  while kill -0 "$wpid" 2>/dev/null && [ "$waited" -lt "$deadline" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$wpid" 2>/dev/null; then
    kill -TERM "$wpid" 2>/dev/null || true
    sleep 1
    kill -KILL "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    pkill -9 -f "$SANDBOX" 2>/dev/null || true
    RC=124
  else
    wait "$wpid" 2>/dev/null
    RC=$?
  fi
  t1=$(date +%s)
  WALL=$((t1 - t0))
  OUT=$(cat "$SANDBOX/.out.txt" 2>/dev/null)
  ERR=$(cat "$SANDBOX/.err.txt" 2>/dev/null)
}

# 단위 seam 러너 (W9a/W12): 래퍼를 source 하는 child bash 를 감독자 deadline
# 관할로 실행. body 는 $1 = 래퍼 scripts 디렉토리, $2 = sandbox 를 받는다.
SRC_RC=""; SRC_OUT=""; SRC_ERR=""
run_sourced_supervised() {
  local deadline="$1" body="$2"
  local outf="$SANDBOX/.src.out" errf="$SANDBOX/.src.err"
  local pid waited=0
  bash -c "$body" bash "$WRAPPER_SCRIPTS_DIR" "$SANDBOX" \
    </dev/null > "$outf" 2> "$errf" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$deadline" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pkill -9 -f "$SANDBOX" 2>/dev/null || true
    SRC_RC=124
  else
    wait "$pid" 2>/dev/null
    SRC_RC=$?
  fi
  SRC_OUT=$(cat "$outf" 2>/dev/null)
  SRC_ERR=$(cat "$errf" 2>/dev/null)
}
src_val() { printf '%s\n' "$SRC_OUT" | sed -n "s/^${1}=//p" | tail -1; }

echo "== review watchdog tests =="

# ============================================================
echo "-- W1: 상한 전 완료 → 무회귀 + capture 계약 + 조기 완료 무지연"
e2e_setup
FAKE_CODEX_DELAY=1 FAKE_CODEX_VERDICT='FINAL_VERDICT: PASS' \
  REIN_WATCHDOG_CAP_OVERRIDE=20 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_eq "$RC" "0" "W1 상한 전 완료 → exit 0"
assert_contains "$OUT" "FINAL_VERDICT: PASS" "W1 stdout 에 verdict"
assert_file_exists "$SANDBOX/trail/dod/.codex-reviewed" "W1 .codex-reviewed 생성"
TEST_COUNT=$((TEST_COUNT + 1))
if [ -s "$CAPTURE" ]; then echo "  ok: W1 FAKE_CODEX_CAPTURE 에 envelope 존재 (파일 redirect 하 stdin 계약 동일)"
else fail "W1 FAKE_CODEX_CAPTURE 에 envelope 존재 (캡처 비어있음/없음)"; fi
# 조기 완료 무지연: 정밀 벽시계(≤3s)는 envelope 조립·git 검사 포함 시 부하에
# 따라 4s+ 로 흔들려 비결정 FAIL (codex R1 High). "cap(20s) 근처까지 기다리지
# 않는다" 수준의 넉넉한 smoke 상한(10s)만 고정 — 폴링이 cap 을 소진하는 오구현은
# 감독자 deadline(15s)에 먼저 걸려 RC=124 로도 깨진다 (이중 관측).
assert_le "$WALL" 10 "W1 총 소요 ≤10s (조기 완료 — cap 20s 를 향해 대기하지 않음)"
e2e_teardown

# ============================================================
echo "-- W2: 성장 유예 후 완료 (drip 1s < 창 2s — 매 창 성장, kill 없이 완주)"
e2e_setup
FAKE_CODEX_DRIP=1 FAKE_CODEX_DRIP_COUNT=6 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=2 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 20 "code review please"
assert_eq "$RC" "0" "W2 유예 후 자연 완료 → exit 0 (유예 회귀 가드)"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W2 review-timeout 앵커행 0"
assert_ge "$WALL" 6 "W2 총 소요 ≥6s (상한 초과 상태로 워치독 관할 구간 통과)"
e2e_teardown

# ============================================================
echo "-- W3: 연속 2창 정지 → exit 5 + 앵커 + 부분 스풀 + 표식 무접촉"
e2e_setup
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_eq "$RC" "5" "W3 정지 판정 → exit 5"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W3 라인 시작 review-timeout 앵커행 ≥1"
assert_contains "$ERR" "effort=" "W3 앵커행에 effort 포함"
assert_contains "$ERR" "elapsed=" "W3 앵커행에 elapsed 포함"
assert_contains "$ERR" "after 1s primary cap" "W3 앵커행에 cap 값 포함 (계약 필드 완결 — codex R1 Test PARTIAL)"
assert_contains "$OUT" "partial-marker" "W3 부분 스풀 best-effort 방출"
assert_file_absent "$SANDBOX/trail/dod/.codex-reviewed" "W3 .codex-reviewed 미생성"
assert_file_absent "$SANDBOX/trail/dod/.review-pending" "W3 .review-pending 미생성"
e2e_teardown

# ============================================================
echo "-- W4: TERM 무시 child → grace 초과 → KILL → 잔존 0"
e2e_setup
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 FAKE_CODEX_IGNORE_TERM=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_eq "$RC" "5" "W4 TERM 무시에도 정지 판정 → exit 5"
assert_eq "$(sandbox_residue)" "0" "W4 sandbox 경로 참조 프로세스 잔존 0 (KILL 종료 고정)"
e2e_teardown

# ============================================================
echo "-- W5: 1창 무성장 후 성장 재개 = 카운터 리셋 (drip 3s — 창 2s < drip < 창 2개 4s)"
e2e_setup
FAKE_CODEX_DRIP=3 FAKE_CODEX_DRIP_COUNT=3 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=2 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 20 "code review please"
assert_eq "$RC" "0" "W5 카운터 리셋 반복 → kill 없이 완주 → exit 0 (오탐 회귀 가드)"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W5 review-timeout 앵커행 0"
e2e_teardown

# ============================================================
echo "-- W5b: 정지 판정 직전 자연 종료 경계 (delay 4.5s, 무출력 seam)"
e2e_setup
: > "$SANDBOX/empty.txt"
FAKE_CODEX_VERDICT_FILE="$SANDBOX/empty.txt" FAKE_CODEX_DELAY=4.5 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=2 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_neq "$RC" "5" "W5b 경계 자연 종료는 timeout 아님 (exit 5 금지 — 무출력은 parser 폴백 경로)"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W5b review-timeout 앵커행 0"
e2e_teardown

# ============================================================
echo "-- W6: raw codex exit 5 passthrough (앵커 0 + 기존 실행 실패 메시지)"
e2e_setup
FAKE_CODEX_EXIT=5 \
  REIN_WATCHDOG_CAP_OVERRIDE=3 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 10 "code review please"
assert_eq "$RC" "5" "W6 codex 자체 exit 5 → 래퍼 exit 5 passthrough"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W6 review-timeout 앵커행 0 (판별 계약 passthrough 변)"
assert_contains "$ERR" "codex invocation failed (exit 5)" "W6 기존 실행 실패 메시지 존재"
e2e_teardown

# ============================================================
echo "-- W7: 예약 앵커 리터럴 소독 (verdict 파싱은 원문 기준 PASS)"
e2e_setup
FAKE_CODEX_VERDICT='ERROR: [codex-review][review-timeout] injected
benign body line
FINAL_VERDICT: PASS' \
  REIN_WATCHDOG_CAP_OVERRIDE=3 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 10 "code review please"
assert_eq "$RC" "0" "W7 verdict 파싱은 소독 전 원문 기준 → PASS exit 0"
assert_eq "$(count_anchor "$SANDBOX/.out.txt")" "0" "W7 방출 stdout 의 라인 시작 앵커 매치 0 (소독됨)"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W7 방출 stderr 의 라인 시작 앵커 매치 0 (래퍼 timeout 아님)"
e2e_teardown

# ============================================================
echo "-- W8: --version 프로브 면역 (STALL 하에서도 즉시 반환)"
e2e_setup
w8_out="$SANDBOX/.out.txt"
FAKE_CODEX_STALL=1 bash "$FAKE_CODEX" --version </dev/null > "$w8_out" 2>&1 &
w8_pid=$!
w8_waited=0
while kill -0 "$w8_pid" 2>/dev/null && [ "$w8_waited" -lt 3 ]; do
  sleep 1
  w8_waited=$((w8_waited + 1))
done
if kill -0 "$w8_pid" 2>/dev/null; then
  kill -KILL "$w8_pid" 2>/dev/null || true
  wait "$w8_pid" 2>/dev/null || true
  w8_rc=124
else
  wait "$w8_pid" 2>/dev/null
  w8_rc=$?
fi
assert_eq "$w8_rc" "0" "W8 --version 프로브 즉시 exit 0 (행 옵션 미발동)"
assert_contains "$(cat "$w8_out" 2>/dev/null)" "fake-codex" "W8 버전 문자열 출력"
e2e_teardown

# ============================================================
echo "-- W9a: 내부 오류 정규화 — 단위 seam (source-and-call, spool 측정 불가 → 6)"
e2e_setup
W9A_BODY=$(cat <<'W9A_EOF'
cd "$1" || exit 97
export REIN_PROJECT_DIR_OVERRIDE="$2"
export TMPDIR="$2/tmpdir"
. ./rein-codex-review.sh
set +e
set +u
if ! declare -F _watchdog_resolve_timings >/dev/null 2>&1 \
   || ! declare -F _watchdog_wait >/dev/null 2>&1; then
  echo "W9A_FUNCS=missing"
  exit 0
fi
echo "W9A_FUNCS=present"
export REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1
read -r WD_CAP WD_INTERVAL WD_GRACE <<<"$(_watchdog_resolve_timings low)"
echo "W9A_TIMINGS=$WD_CAP $WD_INTERVAL $WD_GRACE"
trap '[ -n "${W9A_CHILD:-}" ] && kill -9 "$W9A_CHILD" 2>/dev/null || true' EXIT
sleep 30 &
W9A_CHILD=$!
WD_PID=$W9A_CHILD
rc=0
_watchdog_wait "$WD_PID" /nonexistent/spool || rc=$?
echo "W9A_RC=$rc"
if kill -0 "$W9A_CHILD" 2>/dev/null; then
  echo "W9A_CHILD_ALIVE=1"
  kill -9 "$W9A_CHILD" 2>/dev/null
else
  echo "W9A_CHILD_ALIVE=0"
fi
echo "W9A_WDPID=[${WD_PID:-}]"
W9A_CHILD=""
_rein_cleanup_tmp
exit 0
W9A_EOF
)
run_sourced_supervised 15 "$W9A_BODY"
assert_eq "$(src_val W9A_FUNCS)" "present" "W9a 워치독 함수 정의 존재 (source seam)"
assert_eq "$(src_val W9A_TIMINGS)" "1 1 1" "W9a resolver 로 전역 3종 확정 (호출 전제 구성)"
assert_eq "$(src_val W9A_RC)" "6" "W9a 스풀 측정 불가 → 내부 오류 6 정규화"
assert_eq "$(src_val W9A_CHILD_ALIVE)" "0" "W9a child kill·reap 완료 (kill -0 실패)"
assert_eq "$(src_val W9A_WDPID)" "[]" "W9a reap 직후 WD_PID 해제 (빈 값)"
e2e_teardown

# ============================================================
echo "-- W9b: 내부 오류 정규화 — e2e (wc shim 주입 → 종료 시퀀스 → exit 5 + 사유 앵커)"
e2e_setup
STUBDIR="$SANDBOX/stub"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/wc" <<'EOF'
#!/bin/bash
# 테스트 전용 주입: REIN_TEST_WC_FAIL=1 이면 `wc -c` 만 실패시킨다.
if [ "${REIN_TEST_WC_FAIL:-}" = "1" ]; then
  for _a in "$@"; do [ "$_a" = "-c" ] && exit 1; done
fi
exec /usr/bin/wc "$@"
EOF
chmod +x "$STUBDIR/wc"
PATH="$STUBDIR:$PATH" REIN_TEST_WC_FAIL=1 \
  FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_eq "$RC" "5" "W9b 스풀 측정 실패 → 종료 시퀀스 → exit 5 (fail-closed)"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W9b review-timeout 앵커행 ≥1"
assert_contains "$ERR" "watchdog internal failure" "W9b 내부 오류 사유 명시"
assert_eq "$(sandbox_residue)" "0" "W9b fake-codex 프로세스 잔존 없음"
e2e_teardown

# ============================================================
echo "-- W10a: 비정상 래퍼 종료 cleanup — SIGTERM 변형 (reap→cleanup 순서 oracle)"
e2e_setup
w10_readiness_before=$(readiness_listing)
printf '%s' "code review please" > "$SANDBOX/.stdin.txt"
(
  cd "$SANDBOX"
  export CODEX_BIN="$SANDBOX/fake-codex.sh"
  export TMPDIR="$SANDBOX/tmpdir"
  export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
  export FAKE_CODEX_STALL=1
  export FAKE_CODEX_TERM_PROBE="$SANDBOX/probe.txt"
  export FAKE_CODEX_CAPTURE="$SANDBOX/.capture.txt"
  export REIN_WATCHDOG_CAP_OVERRIDE=30
  export REIN_WATCHDOG_INTERVAL_OVERRIDE=1
  # grace 3s: child 의 TERM trap 은 진행 중이던 sleep 1 이 끝나야 실행 —
  # grace 1s 면 trap(probe 기록) 전에 KILL 이 먼저 도달하는 race (재현됨).
  # KILL 승격 자체는 W4 소관 — 여기선 TERM 정상 수신 경로를 고정한다.
  export REIN_WATCHDOG_GRACE_OVERRIDE=3
  exec bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
    < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
) &
w10_pid=$!
# child 기동 폴링 (최대 8s) — pgrep 만으로는 exec 직후~TERM trap 등록 사이의
# 틈에 신호가 도착해 probe 미기록 flake (재현됨). capture 파일 비공백 =
# stdin 소비 완료 = trap 등록 완료 이후 — 그때 신호를 보낸다.
w10_waited=0
while [ "$w10_waited" -lt 8 ]; do
  if [ -s "$SANDBOX/.capture.txt" ] && pgrep -f "$SANDBOX/fake-codex.sh" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$w10_pid" 2>/dev/null || break
  sleep 1
  w10_waited=$((w10_waited + 1))
done
kill -TERM "$w10_pid" 2>/dev/null || true
w10_waited=0
while kill -0 "$w10_pid" 2>/dev/null && [ "$w10_waited" -lt 15 ]; do
  sleep 1
  w10_waited=$((w10_waited + 1))
done
if kill -0 "$w10_pid" 2>/dev/null; then
  kill -KILL "$w10_pid" 2>/dev/null || true
  wait "$w10_pid" 2>/dev/null || true
  w10_rc=124
else
  wait "$w10_pid" 2>/dev/null
  w10_rc=$?
fi
w10_residue=$(sandbox_residue)
assert_neq "$w10_rc" "124" "W10a TERM 후 deadline 내 래퍼 종료 (sentinel 124 아님)"
assert_eq "$w10_residue" "0" "W10a sandbox 경로 참조 프로세스 잔존 0 (EXIT trap 이 child reap)"
assert_file_exists "$SANDBOX/probe.txt" "W10a TERM_PROBE 기록 존재 (child 가 TERM 수신)"
w10_probe_count=""
if [ -f "$SANDBOX/probe.txt" ]; then
  w10_probe_count=$(tr -d ' \n' < "$SANDBOX/probe.txt")
fi
assert_ge "${w10_probe_count:-0}" 1 "W10a child TERM 시점 rein-readiness 잔존 ≥1 (reap 이 cleanup 보다 먼저)"
assert_eq "$(readiness_listing)" "$w10_readiness_before" "W10a rein-readiness 신규 잔존 없음"
pkill -9 -f "$SANDBOX" 2>/dev/null
e2e_teardown

# ============================================================
echo "-- W10b: 비정상 래퍼 종료 cleanup — SIGINT 변형 (set -m 별도 process group)"
e2e_setup
w10b_readiness_before=$(readiness_listing)
printf '%s' "code review please" > "$SANDBOX/.stdin.txt"
rm -f "$SANDBOX/.wpid" "$SANDBOX/.deadline-hit"
# 비대화형 셸의 async 자식은 SIGINT=SIG_IGN 상속 — 감독자 서브셸 자체를
# background 로 띄우면 set -m 이어도 **진입 시점 disposition(SIG_IGN)** 이
# 래퍼까지 상속되어 커널이 INT 를 버린다 (wave-2 실측: trap -p INT 공란 +
# kill -INT 무기한 생존, ignored-at-entry 는 trap 도 불가). 그래서 set -m
# 감독자는 **foreground** 로 실행하고, INT 발사 + deadline 강제 종료는
# background helper 가 맡는다 (R2 High-C 재설계).
(
  # capture 파일 비공백 조건 포함 — pgrep 단독은 exec~trap 등록 틈 race (W10a 주석 참조)
  h_waited=0
  while [ "$h_waited" -lt 8 ]; do
    if [ -s "$SANDBOX/.wpid" ] && [ -s "$SANDBOX/.capture.txt" ] \
       && pgrep -f "$SANDBOX/fake-codex.sh" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    h_waited=$((h_waited + 1))
  done
  h_wpid=$(cat "$SANDBOX/.wpid" 2>/dev/null)
  if [ -n "$h_wpid" ]; then
    kill -INT "$h_wpid" 2>/dev/null || true
  fi
  h_waited=0
  while [ "$h_waited" -lt 15 ]; do
    if [ -z "$h_wpid" ] || ! kill -0 "$h_wpid" 2>/dev/null; then
      exit 0
    fi
    sleep 1
    h_waited=$((h_waited + 1))
  done
  # deadline 초과 — 하니스 강제 종료 (sentinel 파일 → 124 집계)
  touch "$SANDBOX/.deadline-hit"
  kill -TERM "$h_wpid" 2>/dev/null || true
  sleep 1
  kill -KILL "$h_wpid" 2>/dev/null || true
  pkill -9 -f "$SANDBOX" 2>/dev/null || true
) > /dev/null 2>&1 &
w10b_helper=$!
# foreground set -m 감독자: 래퍼는 job control 하 별도 process group(기본
# disposition 복원) — INT 전달 가능. job 통지는 .sup.err 로 흡수.
(
  set -m
  cd "$SANDBOX"
  export CODEX_BIN="$SANDBOX/fake-codex.sh"
  export TMPDIR="$SANDBOX/tmpdir"
  export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
  export FAKE_CODEX_STALL=1
  export FAKE_CODEX_TERM_PROBE="$SANDBOX/probe.txt"
  export FAKE_CODEX_CAPTURE="$SANDBOX/.capture.txt"
  export REIN_WATCHDOG_CAP_OVERRIDE=30
  export REIN_WATCHDOG_INTERVAL_OVERRIDE=1
  # grace 3s — W10a 와 동일 사유 (TERM trap 실행 여유, KILL race 배제)
  export REIN_WATCHDOG_GRACE_OVERRIDE=3
  bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
    < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt" &
  w=$!
  echo "$w" > "$SANDBOX/.wpid"
  wait "$w"
) > /dev/null 2> "$SANDBOX/.sup.err"
w10b_rc=$?
if [ -f "$SANDBOX/.deadline-hit" ]; then
  w10b_rc=124
fi
wait "$w10b_helper" 2>/dev/null || true
w10b_residue=$(sandbox_residue)
assert_neq "$w10b_rc" "124" "W10b INT 후 deadline 내 래퍼 종료 (sentinel 124 아님)"
assert_eq "$w10b_residue" "0" "W10b sandbox 경로 참조 프로세스 잔존 0 (EXIT trap 이 child reap)"
assert_eq "$(readiness_listing)" "$w10b_readiness_before" "W10b rein-readiness 신규 잔존 없음"
# INT 경로도 reap→cleanup 순서 oracle (codex R1 Test PARTIAL — W10a 와 동일 관측):
# EXIT trap 의 kill sequence 가 child 에 TERM 을 보내는 시점의 임시파일 잔존
# 개수를 child 가 기록 — ≥1 이면 cleanup 이전에 reap 이 수행됐다는 증거.
assert_file_exists "$SANDBOX/probe.txt" "W10b TERM_PROBE 기록 존재 (child 가 TERM 수신)"
w10b_probe_count=""
if [ -f "$SANDBOX/probe.txt" ]; then
  w10b_probe_count=$(tr -d ' \n' < "$SANDBOX/probe.txt")
fi
assert_ge "${w10b_probe_count:-0}" 1 "W10b child TERM 시점 rein-readiness 잔존 ≥1 (reap 이 cleanup 보다 먼저)"
pkill -9 -f "$SANDBOX" 2>/dev/null
e2e_teardown

# ============================================================
echo "-- W11: spec-review timeout — exit 5 + 앵커 + 표식 무접촉 (동일 상한 매핑)"
e2e_setup
mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
printf 'path=/x/plan-foo.md\nreviewer=t\nreviewed=2026-07-22T00:00:00\n' \
  > "$SANDBOX/trail/dod/.spec-reviews/plan-foo.reviewed"
printf 'pending\n' > "$SANDBOX/trail/dod/.review-pending"
w11_snap_before=$(dod_snapshot)
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  run_wrapper_supervised 15 "[NON_INTERACTIVE] spec review for plan: docs/plans/foo.md
Validate the plan document."
assert_eq "$RC" "5" "W11 spec-review 모드도 동일 override 소비 → 정지 판정 exit 5"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W11 review-timeout 앵커행 ≥1"
# spec-review 가 code-review 와 같은 resolver 출력을 소비했음을 앵커 cap 값으로
# 직접 관측 (codex R1 Test PARTIAL — 기본 120/180/300 매핑 자체는 모드 무분기
# 공용 함수라 W12 단위 seam 이 고정).
assert_contains "$ERR" "after 1s primary cap" "W11 앵커행에 cap 값 포함 (동일 resolver 소비 직접 관측)"
assert_file_absent "$SANDBOX/trail/dod/.codex-reviewed" "W11 .codex-reviewed 미생성"
assert_eq "$(dod_snapshot)" "$w11_snap_before" "W11 표식 스냅샷 불변 (.review-pending/.spec-reviews 무접촉)"
e2e_teardown

# ============================================================
echo "-- W12: resolver 단위 seam — effort 매핑 + 방어 매핑 + override 검증"
e2e_setup
W12_BODY=$(cat <<'W12_EOF'
cd "$1" || exit 97
export REIN_PROJECT_DIR_OVERRIDE="$2"
export TMPDIR="$2/tmpdir"
. ./rein-codex-review.sh
set +e
set +u
unset REIN_WATCHDOG_CAP_OVERRIDE REIN_WATCHDOG_INTERVAL_OVERRIDE REIN_WATCHDOG_GRACE_OVERRIDE
if ! declare -F _watchdog_resolve_timings >/dev/null 2>&1; then
  echo "W12_FUNCS=missing"
  exit 0
fi
echo "W12_FUNCS=present"
echo "T_LOW=[$(_watchdog_resolve_timings low)]"
echo "T_MED=[$(_watchdog_resolve_timings medium)]"
echo "T_HIGH=[$(_watchdog_resolve_timings high)]"
echo "T_ODD=[$(_watchdog_resolve_timings unexpected-effort)]"
echo "T_OVR=[$(REIN_WATCHDOG_CAP_OVERRIDE=2 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=3 _watchdog_resolve_timings low)]"
i=0
for bad in abc 0 -5 99999999999999999999; do
  i=$((i+1))
  errf="$2/.w12err.$i"
  out=$(REIN_WATCHDOG_CAP_OVERRIDE="$bad" _watchdog_resolve_timings low 2>"$errf")
  warns=$(wc -l < "$errf" | tr -d ' ')
  echo "B$i=[$out]|warns=$warns"
done
_rein_cleanup_tmp
exit 0
W12_EOF
)
run_sourced_supervised 15 "$W12_BODY"
assert_eq "$(src_val W12_FUNCS)" "present" "W12 resolver 함수 정의 존재 (source seam)"
assert_eq "$(src_val T_LOW)" "[120 30 10]" "W12a effort low → 120 30 10"
assert_eq "$(src_val T_MED)" "[180 30 10]" "W12a effort medium → 180 30 10"
assert_eq "$(src_val T_HIGH)" "[300 30 10]" "W12a effort high → 300 30 10"
assert_eq "$(src_val T_ODD)" "[300 30 10]" "W12b 예상 외 effort → cap 300 방어 매핑"
assert_eq "$(src_val T_OVR)" "[2 1 3]" "W12c 유효 override 3종 그대로 반영"
assert_eq "$(src_val B1)" "[120 30 10]|warns=1" "W12d 무효 override 'abc' → 경고 정확히 1줄 + 정책값 폴백"
assert_eq "$(src_val B2)" "[120 30 10]|warns=1" "W12d 무효 override '0' → 경고 정확히 1줄 + 정책값 폴백"
assert_eq "$(src_val B3)" "[120 30 10]|warns=1" "W12d 무효 override '-5' → 경고 정확히 1줄 + 정책값 폴백"
assert_eq "$(src_val B4)" "[120 30 10]|warns=1" "W12d 초대형 override → 경고 정확히 1줄 (정수 범위 오류 추가 방출 없음)"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
