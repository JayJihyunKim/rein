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
#   W3  정지 임계 창(기본 6, 2026-07-27~) 연속 무활동 → exit 5 + 앵커 + 부분 스풀
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
#   W13~W16 자식 명령 실행 중은 정지가 아니다 — 두 축 동시 / 축 A 단독 /
#       축 B 단독(환경 프로브 후 skip 가능) / 완료 표식 짝 맞으면 다시 정지 판정
#       (2026-07-27 false-stall 수리, dod-2026-07-27-review-watchdog-false-stall)
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
# assert_not_contains — Phase 7 웨이브 3 ③-d 재조준 신설. legacy stamp 파일
# 부재 검사(assert_file_absent)가 항상 참이라 더 이상 아무것도 구분하지
# 못하게 된 시나리오(W3/W11 등, verdict 판정 전 종료)에서, "v2 발급 경로
# 자체에 진입하지 않았다"를 stderr 신호(있었다면 반드시 남았을 문구의
# 부재)로 규명하는 데 쓴다.
assert_not_contains() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    *"$2"*) fail "$3 (unexpectedly present: '$2')" ;;
    *) echo "  ok: $3" ;;
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
.childpid
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

probe_child_visibility() {
  sleep 5 &
  local sp=$! seen
  seen=$(pgrep -P $$ 2>/dev/null | grep -c "^${sp}\$" || true)
  kill "$sp" 2>/dev/null || true
  wait "$sp" 2>/dev/null || true
  [ "${seen:-0}" -ge 1 ]
}

sandbox_residue() {
  # 결정론적 잔존 oracle (R5 High): `pgrep` 은 격리 샌드박스에서 관측 자체가 실패해
  # (RC>1) fail-open 도 fail-closed 도 옳지 않다. fixture 가 기록한 PID 파일 +
  # `kill -0` 로 **프로세스 열거 없이** 생존을 직접 확인한다 — 환경 비의존.
  # 반환: 살아있는 child 수 (0 또는 1). PID 파일이 없으면 spawn 자체가 없었으므로 0.
  local pf="$SANDBOX/.childpid" pid
  # PID 파일 부재 = fixture 가 spawn 되지 않았거나 주입이 누락된 것 → **공검사 금지**.
  # -1 을 돌려 호출부의 `assert_eq 0` 이 반드시 깨지게 한다 (R6 Medium).
  [ -f "$pf" ] || { echo -1; return 0; }
  pid=$(cat "$pf" 2>/dev/null)
  [ -n "$pid" ] || { echo 0; return 0; }
  if kill -0 "$pid" 2>/dev/null; then echo 1; else echo 0; fi
}

readiness_listing() {
  ls "$SANDBOX/tmpdir"/rein-readiness.* 2>/dev/null | sort
}

# Phase 7 웨이브 3 ③-d — legacy 리뷰 표식 3종(.codex-reviewed/.review-
# pending/.security-reviewed) 의 write 경로가 전부 제거되어 이 두 항목은
# 항상 부재다(cksum 대상에서 자연 소멸). .spec-reviews 는 존속 예외라
# 그대로 스냅샷 대상으로 남는다.
dod_snapshot() {
  (
    cd "$SANDBOX" || exit 0
    {
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
    export FAKE_CODEX_PIDFILE="$SANDBOX/.childpid"
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
# Phase 7 웨이브 3 ③-d: 래퍼는 더 이상 trail/dod/.codex-reviewed legacy
# stamp 를 쓰지 않는다 — PASS 시 v2 code_review 증거 발급 시도가 유일한
# 기록 경로다. 이 스위트는 bin/rein 을 링크하지 않으므로(watchdog 생존
# 계약이 검증 대상이지 v2 발급 자체가 아니다) 발급은 "캡처된 digest
# 없음" 경로로 빠진다 — non-fatal 이며 stderr 에 ERROR 로그만 남는다.
assert_contains "$ERR" "no review-start subject digest was captured" \
  "W1 v2 발급 경로 진입(bin/rein 미링크로 캡처없음 ERROR, non-fatal)"
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
echo "-- W3: 정지 임계 창 연속 무활동 → exit 5 + 앵커 + 부분 스풀 + 표식 무접촉"
e2e_setup
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_eq "$RC" "5" "W3 정지 판정 → exit 5"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W3 라인 시작 review-timeout 앵커행 ≥1"
assert_contains "$ERR" "effort=" "W3 앵커행에 effort 포함"
assert_contains "$ERR" "elapsed=" "W3 앵커행에 elapsed 포함"
assert_contains "$ERR" "after 1s primary cap" "W3 앵커행에 cap 값 포함 (계약 필드 완결 — codex R1 Test PARTIAL)"
assert_contains "$OUT" "partial-marker" "W3 부분 스풀 best-effort 방출"
# Phase 7 웨이브 3 ③-d: legacy stamp 파일은 애초에 어디서도 쓰이지 않으므로
# (write 경로 전면 제거) 이 두 파일 부재 검사는 항상 참이라 더 이상 아무
# 것도 구분하지 못한다 — 이 시나리오가 실제로 규명해야 하는 것은
# "verdict 판정 전에 종료됐으니 write_code_review_stamp() 자체가 호출되지
# 않았다"는 사실이다. bin/rein 미링크 스위트라 호출됐다면 반드시
# "no review-start subject digest was captured" ERROR 가 stderr 에 남는다
# — 그 부재가 후계 증거다.
assert_not_contains "$ERR" "no review-start subject digest was captured" \
  "W3 v2 발급 경로 미진입 (verdict 판정 전 종료 — write_code_review_stamp 미호출)"
e2e_teardown

# ============================================================
echo "-- W4: TERM 무시 child → grace 초과 → KILL → 잔존 0"
e2e_setup
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 FAKE_CODEX_IGNORE_TERM=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 \
  run_wrapper_supervised 15 "code review please"
assert_eq "$RC" "5" "W4 TERM 무시에도 정지 판정 → exit 5"
assert_eq "$(sandbox_residue)" "0" "W4 sandbox 경로 참조 프로세스 잔존 0 (KILL 종료 고정)"
e2e_teardown

# ============================================================
echo "-- W5: 1창 무성장 후 성장 재개 = 카운터 리셋 (drip 3s — 창 2s < drip < 창 2개 4s)"
e2e_setup
FAKE_CODEX_DRIP=3 FAKE_CODEX_DRIP_COUNT=3 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=2 REIN_WATCHDOG_GRACE_OVERRIDE=1 \
  REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
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
  REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
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
read -r WD_CAP WD_INTERVAL WD_GRACE WD_STALL_WINDOWS <<<"$(_watchdog_resolve_timings low)"
echo "W9A_TIMINGS=$WD_CAP $WD_INTERVAL $WD_GRACE $WD_STALL_WINDOWS"
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
assert_eq "$(src_val W9A_TIMINGS)" "1 1 1 6" "W9a resolver 4종을 4변수로 분리 수신 (필드 병합 사고 차단)"
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
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 \
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
  export FAKE_CODEX_PIDFILE="$SANDBOX/.childpid"
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
  export FAKE_CODEX_PIDFILE="$SANDBOX/.childpid"
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
# Phase 7 웨이브 3 ③-d: .review-pending 은 어디서도 쓰이지 않으므로(write
# 경로 전면 제거) 더 이상 시드할 대상이 아니다 — dod_snapshot() 도 이제
# .spec-reviews 만 관측한다(존속 예외).
w11_snap_before=$(dod_snapshot)
FAKE_CODEX_PARTIAL="partial-marker" FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 \
  run_wrapper_supervised 15 "[NON_INTERACTIVE] spec review for plan: docs/plans/foo.md
Validate the plan document."
assert_eq "$RC" "5" "W11 spec-review 모드도 동일 override 소비 → 정지 판정 exit 5"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W11 review-timeout 앵커행 ≥1"
# spec-review 가 code-review 와 같은 resolver 출력을 소비했음을 앵커 cap 값으로
# 직접 관측 (codex R1 Test PARTIAL — 기본 120/180/300 매핑 자체는 모드 무분기
# 공용 함수라 W12 단위 seam 이 고정).
assert_contains "$ERR" "after 1s primary cap" "W11 앵커행에 cap 값 포함 (동일 resolver 소비 직접 관측)"
# Phase 7 웨이브 3 ③-d: legacy stamp 부재 검사는 항상 참이라 더 이상
# 아무것도 구분하지 못한다 — verdict 판정 전 정지 종료이므로
# write_code_review_stamp() 자체가 호출되지 않았음을 stderr 신호(있었다면
# 반드시 남았을 문구의 부재)로 규명한다.
assert_not_contains "$ERR" "no review-start subject digest was captured" \
  "W11 v2 발급 경로 미진입 (정지 판정 — write_code_review_stamp 미호출)"
assert_eq "$(dod_snapshot)" "$w11_snap_before" "W11 표식 스냅샷 불변 (.spec-reviews 무접촉)"
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
unset REIN_WATCHDOG_CAP_OVERRIDE REIN_WATCHDOG_INTERVAL_OVERRIDE REIN_WATCHDOG_GRACE_OVERRIDE REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE
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
assert_eq "$(src_val T_LOW)" "[120 30 10 6]" "W12a effort low → 120 30 10"
assert_eq "$(src_val T_MED)" "[180 30 10 6]" "W12a effort medium → 180 30 10"
assert_eq "$(src_val T_HIGH)" "[300 30 10 6]" "W12a effort high → 300 30 10"
assert_eq "$(src_val T_ODD)" "[300 30 10 6]" "W12b 예상 외 effort → cap 300 방어 매핑"
assert_eq "$(src_val T_OVR)" "[2 1 3 6]" "W12c 유효 override 3종 그대로 반영"
assert_eq "$(src_val B1)" "[120 30 10 6]|warns=1" "W12d 무효 override 'abc' → 경고 정확히 1줄 + 정책값 폴백"
assert_eq "$(src_val B2)" "[120 30 10 6]|warns=1" "W12d 무효 override '0' → 경고 정확히 1줄 + 정책값 폴백"
assert_eq "$(src_val B3)" "[120 30 10 6]|warns=1" "W12d 무효 override '-5' → 경고 정확히 1줄 + 정책값 폴백"
assert_eq "$(src_val B4)" "[120 30 10 6]|warns=1" "W12d 초대형 override → 경고 정확히 1줄 (정수 범위 오류 추가 방출 없음)"
e2e_teardown

# ============================================================
# W13~W15 (2026-07-27 watchdog false-stall): 자식 명령 실행 중은 정지가 아니다.
#
# 배경 실측: codex 는 자식 명령 실행 동안 출력을 내지 않고 완료 시점에 일괄
# 방출한다. 219초짜리 테스트를 돌리던 정상 리뷰가 "무성장" 으로 오판돼 종료됐다.
# 생존 신호를 2축(자식 명령 진행 표식 / 자식 프로세스 활동)으로 확장한 뒤,
# 각 축이 **단독으로도** 오판을 막는지 분리 검증한다.
# 정지 임계는 override 로 2창으로 낮춰 케이스 소요를 짧게 유지한다.
echo "-- W13: 자식 명령 진행 중(두 축 모두) → 종료되지 않고 완주"
e2e_setup
FAKE_CODEX_EXEC_MARKER=1 FAKE_CODEX_CHURN=6 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
  REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
  run_wrapper_supervised 25 "code review please"
assert_eq "$RC" "0" "W13 자식 명령 대기 중 종료 안 됨 → exit 0"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W13 review-timeout 앵커행 0 (오판 없음)"
assert_ge "$WALL" 6 "W13 무성장 구간을 상한 초과 상태로 통과 (≥6s)"
e2e_teardown

echo "-- W14: 축 A 단독 — 진행 표식만 있고 프로세스는 안정 → 완주"
e2e_setup
FAKE_CODEX_EXEC_MARKER=1 FAKE_CODEX_DELAY=6 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
  REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
  run_wrapper_supervised 25 "code review please"
assert_eq "$RC" "0" "W14 진행 표식 단독으로 오판 차단 → exit 0"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W14 앵커행 0"
e2e_teardown

# W15 는 축 B 단독 검증이므로 **자식 프로세스 관측이 가능한 환경**에서만 유효하다.
# 격리 샌드박스(예: codex 의 sandbox-exec) 안에서는 pgrep 이 형제 프로세스를
# 보지 못해 축 B 가 설계대로 조용히 비활성화되고, 그 환경의 W15 실패는
# 결함이 아니라 전제 불충족이다 (2026-07-27 codex R1 이 실제로 이 실패를 보고).
# 따라서 전제를 먼저 프로브하고, 불충족이면 skip 으로 명시한다 — 조용한 통과도,
# 환경 탓 오탐 실패도 만들지 않는다.
echo "-- W15: 축 B 단독 — 표식 없이 자식 프로세스만 활동 → 완주"
if probe_child_visibility; then
  e2e_setup
  FAKE_CODEX_CHURN=6 \
    REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
    REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
    run_wrapper_supervised 25 "code review please"
  assert_eq "$RC" "0" "W15 자식 프로세스 활동 단독으로 오판 차단 → exit 0"
  assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W15 앵커행 0"
  e2e_teardown
else
  echo "  skip: W15 — 이 환경은 자식 프로세스를 관측할 수 없어 축 B 전제 불충족 (축 A 는 W13/W14 가 커버)"
fi

echo "-- W17: 활동 분류 단위 seam — edge/level/무활동 (환경 비의존, W15 skip 보완)"
e2e_setup
W17_BODY=$(cat <<'W17_EOF'
cd "$1" || exit 97
export REIN_PROJECT_DIR_OVERRIDE="$2"
export TMPDIR="$2/tmpdir"
. ./rein-codex-review.sh
set +e
set +u
if ! declare -F _watchdog_classify_activity >/dev/null 2>&1 \
   || ! declare -F _watchdog_exec_inflight >/dev/null 2>&1; then
  echo "W17_FUNCS=missing"; exit 0
fi
echo "W17_FUNCS=present"
# classify(size, baseline, inflight, dcount, dmin, dset, dprev) — 순수 입력 주입.
_watchdog_classify_activity 200 100 0 0 0 "" "";           echo "C_GROWTH=$?"
_watchdog_classify_activity 100 100 0 1 1 "7 8" "7";       echo "C_PIDSET=$?"
_watchdog_classify_activity 100 100 1 0 0 "" "";           echo "C_INFLIGHT=$?"
_watchdog_classify_activity 100 100 0 3 1 "7 8 9" "7 8 9"; echo "C_DCOUNT=$?"
_watchdog_classify_activity 100 100 0 1 1 "7" "7";         echo "C_IDLE=$?"
# 표식 파서: 열린 exec 만 진행 중, 짝이 맞으면 아님, 본문의 exec 문자열은 오인 금지.
printf 'exec\n/bin/zsh -lc %s in /tmp\n' "'x'" > "$2/sp_open.txt"
_watchdog_exec_inflight "$2/sp_open.txt";  echo "P_OPEN=$?"
printf 'exec\n/bin/zsh -lc %s in /tmp\n succeeded in 12ms:\n' "'x'" > "$2/sp_done.txt"
_watchdog_exec_inflight "$2/sp_done.txt";  echo "P_DONE=$?"
printf 'some output mentioning exec\nnot a command line\n' > "$2/sp_noise.txt"
_watchdog_exec_inflight "$2/sp_noise.txt"; echo "P_NOISE=$?"
printf 'exec\nprose in /tmp is only mentioned here, not a workdir suffix\n' > "$2/sp_prose.txt"
_watchdog_exec_inflight "$2/sp_prose.txt"; echo "P_PROSE=$?"
# 공백 있는 작업 디렉토리에서도 축 A 가 살아 있어야 한다 (R4 Medium — 라인 끝 앵커로
# 좁히면 여기서 축 A 가 통째로 죽고, 자손 관측 불가 환경과 겹치면 오판이 재현된다).
printf 'exec\n/bin/zsh -lc %s in /tmp/dir with space\n' "'x'" > "$2/sp_space.txt"
_watchdog_exec_inflight "$2/sp_space.txt"; echo "P_SPACE=$?"
# 자손 집합 정규형: production helper 를 직접 호출한다 (재작성 금지 — helper 에서
# 정렬·중복 제거를 지워도 통과하던 vacuous oracle 을 제거, R4 Medium).
_watchdog_descendants() { printf '10\n2\n10\n'; }   # stub — 열거 순서·중복 주입
echo "N_SET=[$(_watchdog_descendant_set 12345)]"
# 신규 override 계약 (유효값 반영 + 무효값 경고 정확히 1줄 + 단위 라벨).
echo "OVR_OK=[$(REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=4 _watchdog_resolve_timings low)]"
echo "LEASE_DEF=$(_watchdog_pick_override "REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE" "" 20 " windows")"
echo "LEASE_OVR=$(_watchdog_pick_override "REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE" "7" 20 " windows")"
_e="$2/.w17err"
_o=$(REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=abc _watchdog_resolve_timings low 2>"$_e")
echo "OVR_BAD=[$_o]|warns=$(wc -l < "$_e" | tr -d ' ')|unit=$(grep -c 'default 6 windows' "$_e")"
_rein_cleanup_tmp
exit 0
W17_EOF
)
run_sourced_supervised 15 "$W17_BODY"
assert_eq "$(src_val W17_FUNCS)" "present" "W17 분류·파서 함수 정의 존재"
assert_eq "$(src_val C_GROWTH)"   "0" "W17 출력 성장 → edge(0)"
assert_eq "$(src_val C_PIDSET)"   "0" "W17 자손 PID 집합 변동 → edge(0)"
assert_eq "$(src_val C_INFLIGHT)" "1" "W17 미완료 진행 표식만 → level(1)"
assert_eq "$(src_val C_DCOUNT)"   "1" "W17 자손 수 최소치 초과만 → level(1)"
assert_eq "$(src_val C_IDLE)"     "2" "W17 무활동 → 2"
assert_eq "$(src_val P_OPEN)"     "0" "W17 열린 exec 표식 → 진행 중"
assert_eq "$(src_val P_DONE)"     "1" "W17 완료 표식 짝 → 진행 중 아님"
assert_eq "$(src_val P_NOISE)"    "1" "W17 본문의 exec 문자열은 시작 표식으로 오인 안 함"
assert_eq "$(src_val P_PROSE)"    "1" "W17 exec 직후 산문에 ' in /' 가 섞여도 시작 표식 아님 (명령행 구조 요구)"
assert_eq "$(src_val P_SPACE)"    "0" "W17 공백 있는 작업 디렉토리에서도 시작 표식 인식 (축 A 생존)"
assert_eq "$(src_val N_SET)" "[2 10 ]" "W17 자손 정규형 — production helper 가 순서·중복을 접는다 (10 2 10 → 2 10)"
assert_eq "$(src_val OVR_OK)" "[120 30 10 4]" "W17 신규 override 유효값 반영"
assert_eq "$(src_val OVR_BAD)" "[120 30 10 6]|warns=1|unit=1" "W17 무효 override → 경고 1줄 + 창 단위 문구"
assert_eq "$(src_val LEASE_DEF)" "20" "W17 기본 lease 20창 exact oracle (기본값 변경 시 즉시 FAIL)"
assert_eq "$(src_val LEASE_OVR)" "7" "W17 lease override 반영"
e2e_teardown

echo "-- W18: level 신호만 유지되는 진짜 멈춤은 lease 소진 후 종료 → exit 5"
e2e_setup
FAKE_CODEX_EXEC_MARKER=1 FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
  REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
  run_wrapper_supervised 25 "code review please"
assert_eq "$RC" "5" "W18 진행 표식이 남아도 lease 소진 후에는 정지 판정 → exit 5"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W18 앵커행 ≥1"
e2e_teardown

echo "-- W20: 실제 루프의 기준선 0 — 자손 열거 stub 으로 환경 비의존 검증"
e2e_setup
W20_BODY=$(cat <<'W20_EOF'
cd "$1" || exit 97
export REIN_PROJECT_DIR_OVERRIDE="$2"
export TMPDIR="$2/tmpdir"
. ./rein-codex-review.sh
set +e
set +u
if ! declare -F _watchdog_wait >/dev/null 2>&1; then echo "W20_FUNCS=missing"; exit 0; fi
echo "W20_FUNCS=present"
# 상한 전부터 존재해 **변하지 않는** 자손 1개를 주입한다 (열거는 stub — pgrep 미사용).
# dmin=0 구현: 매 창 level 활동 → lease 안에서 생존 → child 자연 종료로 0 반환.
# 관측 기반 기준선 구현: dcount==dmin → level 없음 → 무활동 2창에 정지 판정(5).
_watchdog_descendants() { printf '4242\n'; }
export REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
       REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
       REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=8
read -r WD_CAP WD_INTERVAL WD_GRACE WD_STALL_WINDOWS <<<"$(_watchdog_resolve_timings low)"
WD_LEVEL_LEASE=$(_watchdog_pick_override "REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE" "${REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE:-}" 20 " windows")
: > "$2/w20.spool"
sleep 6 &   # 출력이 자라지 않는 상태로 6초 생존하는 child
W20_CHILD=$!
WD_RC=0
_watchdog_wait "$W20_CHILD" "$2/w20.spool" || WD_RC=$?
echo "W20_RC=$WD_RC"
_rein_cleanup_tmp
exit 0
W20_EOF
)
run_sourced_supervised 25 "$W20_BODY"
assert_eq "$(src_val W20_FUNCS)" "present" "W20 워치독 루프 함수 존재"
assert_eq "$(src_val W20_RC)" "0" "W20 안정된 자손 1개가 lease 안에서 생존 → 정지 판정 없음 (기준선 0 계약)"
e2e_teardown

echo "-- W19: 상한 전 시작해 변화 없이 유지되는 장기 자식 → lease 안에서 완주 (dmin=0 회귀)"
# W15 와 동일하게 자손 관측을 전제한다 — 격리 샌드박스에서는 축 B 가 설계대로
# 비활성화되어 이 케이스가 성립하지 않는다 (전제 불충족이지 결함 아님).
if probe_child_visibility; then
e2e_setup
# 관측 기반 기준선 구현이면 dcount==dmin 이라 level 신호가 없어 무활동 2창에 죽고,
# dmin=0 구현이면 매 창 level 로 계수돼 lease(8) 안에서 완주한다.
FAKE_CODEX_DELAY=6 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
  REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
  REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=8 \
  run_wrapper_supervised 25 "code review please"
assert_eq "$RC" "0" "W19 상한 전 시작된 안정 자식이 lease 안에서 완주 → exit 0"
assert_eq "$(count_anchor "$SANDBOX/.err.txt")" "0" "W19 앵커행 0"
e2e_teardown
else
  echo "  skip: W19 — 이 환경은 자식 프로세스를 관측할 수 없어 축 B 전제 불충족"
fi

echo "-- W16: 진행 표식이 짝을 맞추면(완료) 다시 정지 판정 대상 → exit 5"
e2e_setup
FAKE_CODEX_EXEC_MARKER=1 FAKE_CODEX_EXEC_DONE=1 FAKE_CODEX_STALL=1 \
  REIN_WATCHDOG_CAP_OVERRIDE=1 REIN_WATCHDOG_INTERVAL_OVERRIDE=1 \
  REIN_WATCHDOG_GRACE_OVERRIDE=1 REIN_WATCHDOG_LEVEL_LEASE_OVERRIDE=1 REIN_WATCHDOG_STALL_WINDOWS_OVERRIDE=2 \
  run_wrapper_supervised 25 "code review please"
assert_eq "$RC" "5" "W16 완료 표식으로 짝이 맞으면 진짜 정지로 판정 → exit 5"
assert_ge "$(count_anchor "$SANDBOX/.err.txt")" 1 "W16 앵커행 ≥1"
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
