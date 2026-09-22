#!/usr/bin/env bash
# tests/skills/test-review-events.sh
#
# 리뷰 이벤트 로그 스위트 (spec docs/specs/2026-09-11-review-cycle-wallclock.md
# §4.1).
#
# 목적: 리뷰 회차 하나를 닫는 실제 wall-clock 시간을 재는 삭제되지 않는
# 이벤트 로그(trail/review-events/<key-hash>.jsonl)를 검증한다. wall_clock_ms
# 는 wrapper 진입(t0)부터 판정 및 그 후처리(카운터 정리·v2 evidence 발급)까지
# 사용자가 실제로 기다린 시간이다 — codex 실행 시간만이 아니다.
#
# 범위: 판정(PASS/NEEDS-FIX/REJECT)으로 끝난 호출만 로그를 남긴다. 거절·타임아웃·예산 초과·신호 종료 같은
# 비판정 종료 경로는 로그를 거치지 않는다 — 이 로그로 "모든 호출의 총 대기" 를 집계하면 안 된다.
#
# 검증 축:
#   EV1a 판정 outcome(PASS/NEEDS-FIX/REJECT × code/spec) 의 필수 8필드 로그
#        (RW1-event-log-per-call-required-fields)
#   EV3a 판정 경로의 후처리(카운터 정리·v2 evidence)가 wall_clock_ms 안에
#        포함된다 (RW1-wallclock-includes-postverdict-bookkeeping)
#   EV-JSON  _json_str 이스케이프 안전성 (JSON 왕복·구조 주입 차단)
#   EV-SEAM  _test_delay_at 형식 방어 (잘못된 값은 무시, set -e 안전)
#   EV-TOCTOU  _review_event_commit append 직전 재검사
#
# EV3a 임계값 비고: 이 하네스의 code-review 경로 baseline 은 샌드박스마다
# (mktemp -d + git init + python3 subject 조회 등) 흔들린다 — 고정 절대
# 임계값 대신 baseline 상대 오라클을 쓴다. 각 조합마다 지연 없는 판정을
# 비교 직전에 먼저 측정해 baseline(wall_clock_ms) 을 재고, 그 기준으로
# 양성/음성을 가른다.
#
# Wrapper under test: plugin SSOT plugins/rein-core/scripts/rein-codex-review.sh
# (mirror parity 는 tests/scripts/test-plugin-scripts-bundle.sh 소관).
# Idiom: e2e 샌드박스 = tests/skills/test-review-round-budget.sh 의
# e2e_setup/run_wrapper/assert_* 복제 + tests/skills/test-review-selfverify-gate.sh
# 의 mk_fake_rein_bin 복제(FAKE_REIN_DELAY 옵션 + issue-evidence code_review
# 분기 추가).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WRAPPER_SRC="$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

TEST_COUNT=0
FAIL_COUNT=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" = "$2" ]; then echo "  ok: $3"
  else fail "$3 (expected='$2' got='$1')"; fi
}
assert_contains() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    *"$2"*) echo "  ok: $3" ;;
    *) fail "$3 (missing '$2')" ;;
  esac
}
assert_not_contains() {
  TEST_COUNT=$((TEST_COUNT + 1))
  case "$1" in
    *"$2"*) fail "$3 (unexpected '$2')" ;;
    *) echo "  ok: $3" ;;
  esac
}
assert_matches() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if printf '%s' "$1" | grep -qE "$2"; then echo "  ok: $3"
  else fail "$3 (does not match /$2/: '$1')"; fi
}
assert_ge() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" -ge "$2" ] 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (expected >= $2, got '$1')"; fi
}
assert_lt() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" -lt "$2" ] 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (expected < $2, got '$1')"; fi
}
assert_le() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$1" -le "$2" ] 2>/dev/null; then echo "  ok: $3"
  else fail "$3 (expected <= $2, got '$1')"; fi
}

# _test_now_ms — 래퍼의 _now_ms 와 동일한 폴백 순서(EPOCHREALTIME →
# python3 → date). 테스트 쪽에서 run_wrapper 호출을 감싸 총 소요를 재는
# 용도 — 래퍼가 로그에 적은 wall_clock_ms 의 상한 비교 기준이 된다.
_test_now_ms() {
  local t="${EPOCHREALTIME:-}"   # 한 번만 캡처 — 초 경계를 넘나드는 이중 참조 방지.
  t="${t//[^0-9]/}"
  if [ "${#t}" -ge 13 ]; then printf '%s' "${t:0:13}"; return 0; fi
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return 0
  printf '%s000' "$(date +%s)"
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
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

e2e_setup() {
  SANDBOX=$(mktemp -d "/tmp/rein-revevents-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/scripts" \
           "$SANDBOX/trail/dod" "$SANDBOX/tmpdir" "$SANDBOX/docs/specs"
  cp "$LIB" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$LIB_DIR/path-containment.sh" "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$WRAPPER_SRC" "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  for n in a b; do
    cat > "$SANDBOX/docs/specs/sample-$n.md" <<DOC
# 샘플 설계 문서 $n

## Scope Items

| Scope ID | 설명 |
|---|---|
| \`sample-$n-does-thing-when-condition\` | 조건 시 동작 |
DOC
  done
  # (a) bin/ 을 untracked 관측(A1/A6/selfverify untracked probe)에서 제외 —
  # mk_fake_rein_bin 스텁이 dirty-tree 판정을 오염시키지 않게 한다.
  # .rein/cache/ 도 제외한다 — CLAUDE_PLUGIN_ROOT 가 설정된 환경에서는
  # select-active-dod 의 세션 선택 기록(active-dod-choice.log·session-*.flag)
  # 이 .claude/cache/ 가 아니라 여기로 간다(rein-state-paths.py 의
  # scaffold-relative 해소 경로). 빠지면 두 번째 이상 호출이 이 새 untracked
  # 파일을 selfverify A1 로 감지해 readiness-reject 로 조기 종료된다.
  cat > "$SANDBOX/.gitignore" <<'IGN'
.gitignore
.stdin.txt
.out.txt
.err.txt
.capture*
tmpdir/
trail/
.claude/cache/
.rein/cache/
bin/
IGN
  ( cd "$SANDBOX" && git init -q && git config user.email t@e.com \
    && git config user.name t && git add -A && git commit -q -m base \
    && git commit --allow-empty -q -m head )
}
e2e_teardown() {
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# fake bin/rein 스텁 — tests/skills/test-review-selfverify-gate.sh::mk_fake_rein_bin
# 복제 + FAKE_REIN_DELAY(초 — --print-subject·issue-evidence
# 분기 진입 시 sleep) + issue-evidence code_review 분기({"issued": true} +
# exit 0). 래퍼 self-location($_script_dir/../bin/rein, $_script_dir =
# $SANDBOX/scripts)이 $SANDBOX/bin/rein 을 찾는다.
mk_fake_rein_bin() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/rein" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys
import time


def main():
    argv = sys.argv[1:]
    delay = os.environ.get("FAKE_REIN_DELAY", "")
    if len(argv) < 2 or argv[0] != "issue-evidence" or argv[1] != "code_review":
        sys.stderr.write("fake-bin-rein: unsupported invocation: %r\n" % (argv,))
        return 2
    rest = argv[2:]
    if "--print-subject" in rest:
        if delay:
            time.sleep(float(delay))
        raw_json = os.environ.get("FAKE_REIN_SUBJECT_JSON", "")
        rc = int(os.environ.get("FAKE_REIN_DIGEST_RC", "0"))
        if raw_json:
            sys.stdout.write(raw_json)
            if not raw_json.endswith("\n"):
                sys.stdout.write("\n")
        return rc
    if "--verdict" in rest:
        if delay:
            time.sleep(float(delay))
        sys.stdout.write('{"issued": true}\n')
        return 0
    sys.stderr.write("fake-bin-rein: unrecognized args: %r\n" % (rest,))
    return 2


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "$SANDBOX/bin/rein"
}

# run_wrapper <stdin-content> [extra wrapper args...]
# (b) WRAP_PATH_PREFIX seam — set 이면 PATH 맨 앞에 꽂는다 (다른 스위트의
# git shim 재사용 대비 — 이 스위트 자체는 아직 사용하지 않는다).
RC=""; OUT=""; ERR=""; CAPTURE=""
run_wrapper() {
  local stdin_content="$1"; shift
  CAPTURE="$SANDBOX/.capture.txt"
  rm -f "$CAPTURE"
  printf '%s' "$stdin_content" > "$SANDBOX/.stdin.txt"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$CAPTURE"
    export TMPDIR="$SANDBOX/tmpdir"
    if [ -n "${WRAP_PATH_PREFIX:-}" ]; then export PATH="$WRAP_PATH_PREFIX:$PATH"; fi
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive "$@" \
      < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
  )
  RC=$?
  OUT=$(cat "$SANDBOX/.out.txt")
  ERR=$(cat "$SANDBOX/.err.txt")
}

# ============================================================
# 공통 이벤트 로그 헬퍼.
# ============================================================
last_event_field() {   # $1=field — 키 파일 하나뿐인 샌드박스 전제. 없으면 빈 문자열.
  # 계약: 값을 JSON 으로 파싱해 뽑는다 — null 은 문자열 "null" 로 반환해 진짜 빈 문자열과 구분한다.
  local f; f=$(ls "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null | head -1); [ -n "$f" ] || { printf ''; return 0; }
  tail -1 "$f" | python3 -c '
import json, sys
d = json.loads(sys.stdin.readline())
v = d.get(sys.argv[1])
print("null" if v is None else v)
' "$1" 2>/dev/null
}
last_event_key_order() {
  local f; f=$(ls "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null | head -1); [ -n "$f" ] || { printf ''; return 0; }
  tail -1 "$f" | grep -o '"[a-z_]*":' | tr -d '":' | paste -sd, -
}
event_line_count() { cat "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }
snapshot_streams() { mkdir -p "$1"; cp "$SANDBOX"/trail/review-events/*.jsonl "$1"/ 2>/dev/null || true; }
assert_prefix_preserved() {   # $1=이전 스냅샷 dir $2=label — 이전 파일이 현재 파일의 정확한 prefix 인지
  local f base cur; for f in "$1"/*.jsonl; do [ -f "$f" ] || continue; base=$(basename "$f")
    cur="$SANDBOX/trail/review-events/$base"; TEST_COUNT=$((TEST_COUNT + 1))
    if [ -f "$cur" ] && cmp -s -n "$(wc -c < "$f" | tr -d ' ')" "$f" "$cur"; then echo "  ok: prefix $base ($2)"; else fail "$2: $base 가 이전 스트림의 prefix 를 깼다"; fi; done
}

# src_eval <snippet> — 래퍼를 source 해(함수만 — 하단 main 블록은
# BASH_SOURCE[0]!=$0 이라 실행되지 않는다, PROMPT_BODY 는 </dev/null 라 빈
# 값) snippet 을 eval (test-review-evidence-manifest.sh::src_eval 복제).
# SANDBOX 가 REIN_PROJECT_DIR_OVERRIDE 대상 — e2e_setup 이 먼저 있어야 한다.
src_eval() {
  (
    export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
    export TMPDIR="$SANDBOX/tmpdir"
    mkdir -p "$TMPDIR"
    # shellcheck disable=SC1090
    source "$WRAPPER_SRC" </dev/null >/dev/null 2>&1
    set +e; set +u; set +o pipefail
    eval "$1"
  )
}

NEEDS_FIX_BODY='리뷰 본문.
FINAL_VERDICT: NEEDS-FIX'
PASS_BODY='리뷰 본문.
FINAL_VERDICT: PASS'
REJECT_BODY='리뷰 본문.
FINAL_VERDICT: REJECT'

PROMPT_A='[NON_INTERACTIVE] spec review for design: docs/specs/sample-a.md
Validate technical soundness.'
CODE_PROMPT='code review please'

KEY_ORDER_EXPECT="ts,mode,cycle_key,outcome,round_count_at_call,wall_clock_ms,extension_declared,subject_fingerprint"

echo "== review event log tests (spec §4.1) =="

# ============================================================
# EV1a — 판정 outcome 6조합의 필수 8필드 로그
# (RW1-event-log-per-call-required-fields)
# ============================================================

EV1A_SHA='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
EV1A_SUBJ_JSON="{\"subject\": \"$EV1A_SHA\", \"paths\": [], \"changeset_paths\": []}"

ev1a_case() {
  # $1=label $2=mode(code|spec) $3=verdict-body $4=expected-outcome $5=prompt
  # 8필드 값 전부를 직접 단언한다. code 모드는
  # mk_fake_rein_bin 으로 REIN_REVIEWED_DIGEST 를 실제로 채워
  # subject_fingerprint 가 sha256:… 로 나오는 것까지 확인한다 — code 분기는
  # code 분기는 배선돼 있고 spec 분기는 지문 미산출이라 null 이다.
  local label="$1" mode="$2" body="$3" expect_outcome="$4" prompt="$5"
  e2e_setup
  local expect_fp expect_key t0 t1 total_ms
  t0=$(_test_now_ms)
  if [ "$mode" = "code" ]; then
    mk_fake_rein_bin
    FAKE_REIN_SUBJECT_JSON="$EV1A_SUBJ_JSON" FAKE_CODEX_VERDICT="$body" run_wrapper "$prompt"
    expect_key="code:(no-dod)"
    expect_fp="$EV1A_SHA"
  else
    FAKE_CODEX_VERDICT="$body" run_wrapper "$prompt"
    expect_key="spec:$(realpath "$SANDBOX/docs/specs/sample-a.md" 2>/dev/null || printf '%s' "$SANDBOX/docs/specs/sample-a.md")"
    expect_fp="null"
  fi
  t1=$(_test_now_ms)
  total_ms=$((t1 - t0))
  assert_eq "$(event_line_count)" "1" "$label: event_line_count == 1 (정확히 +1)"
  assert_eq "$(last_event_key_order)" "$KEY_ORDER_EXPECT" "$label: 8키 고정 순서"
  assert_matches "$(last_event_field ts)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$label: ts ISO-8601 Z"
  assert_eq "$(last_event_field mode)" "$mode" "$label: mode=$mode"
  assert_eq "$(last_event_field cycle_key)" "$expect_key" "$label: cycle_key 기대 키와 일치"
  assert_eq "$(last_event_field outcome)" "$expect_outcome" "$label: outcome=$expect_outcome"
  assert_eq "$(last_event_field round_count_at_call)" "0" "$label: round_count_at_call=0 (새 샌드박스 첫 호출)"
  assert_eq "$(last_event_field extension_declared)" "null" "$label: extension_declared=null (미선언)"
  assert_eq "$(last_event_field subject_fingerprint)" "$expect_fp" "$label: subject_fingerprint"
  # wall_clock_ms 는 정수이며 0 이상, 그리고 이 함수가 run_wrapper 호출을
  # 감싸 직접 잰 총 소요(t0=호출 직전 ~ t1=반환 직후) 를 넘을 수 없다 —
  # 래퍼 내부 구간(t0=wrapper 진입 ~ t_end=commit 직전)은 이 바깥 구간의
  # 부분집합이어야 한다.
  assert_matches "$(last_event_field wall_clock_ms)" '^[0-9]+$' "$label: wall_clock_ms 정수"
  assert_le "$(last_event_field wall_clock_ms)" "$total_ms" "$label: wall_clock_ms <= 테스트 측 총 소요(${total_ms}ms)"
  if [ "$expect_outcome" = "verdict:PASS" ]; then
    local f; f=$(ls "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null | head -1)
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ -n "$f" ] && [ -f "$f" ]; then echo "  ok: $label: PASS 뒤 로그 파일 존재"
    else fail "$label: PASS 뒤 로그 파일 소멸"; fi
    assert_eq "$(event_line_count)" "1" "$label: PASS 뒤 로그 줄수 불변 (카운터 정리가 로그를 건드리지 않음)"
  fi
  e2e_teardown
}

echo "-- EV1a: code × (PASS|NEEDS-FIX|REJECT)"
ev1a_case "EV1a-code-PASS"       "code" "$PASS_BODY"       "verdict:PASS"       "$CODE_PROMPT"
ev1a_case "EV1a-code-NEEDS-FIX"  "code" "$NEEDS_FIX_BODY"  "verdict:NEEDS-FIX"  "$CODE_PROMPT"
ev1a_case "EV1a-code-REJECT"     "code" "$REJECT_BODY"     "verdict:REJECT"     "$CODE_PROMPT"

echo "-- EV1a: spec × (PASS|NEEDS-FIX|REJECT)"
ev1a_case "EV1a-spec-PASS"       "spec" "$PASS_BODY"       "verdict:PASS"       "$PROMPT_A"
ev1a_case "EV1a-spec-NEEDS-FIX"  "spec" "$NEEDS_FIX_BODY"  "verdict:NEEDS-FIX"  "$PROMPT_A"
ev1a_case "EV1a-spec-REJECT"     "spec" "$REJECT_BODY"     "verdict:REJECT"     "$PROMPT_A"

echo "-- EV1a: [MAX_ROUNDS:8] 선언 변형 — extension_declared=8"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "[MAX_ROUNDS:8]
$CODE_PROMPT"
assert_eq "$(event_line_count)" "1" "EV1a-declared: event_line_count == 1"
assert_eq "$(last_event_field outcome)" "verdict:NEEDS-FIX" "EV1a-declared: outcome"
assert_eq "$(last_event_field extension_declared)" "8" "EV1a-declared: extension_declared=8"
e2e_teardown

# ============================================================
# EV3a — 판정 경로의 후처리(카운터 정리·v2 evidence)가 wall_clock_ms 안에
# 포함된다 (RW1-wallclock-includes-postverdict-bookkeeping)
# ============================================================

# 지연은 이 하네스의 샌드박스 지터에 묻히지 않을 만큼 크게 잡고, 문턱은
# 주입량 대비 비율(양성/음성)로 상대 오라클을 구성한다.
EV3A_DELAY_S="3.0"
EV3A_DELAY_MS=3000

# baseline 은 비교 직전에 짝지어 재고(측정~비교 시간차를 최소화해 같은
# 부하 조건을 공유), 2회 표본의 최소값을 쓴다 — 표본 하나가 부하로 튀어도
# 다른 하나가 정상이면 최소값이 정상값에 수렴한다.
EV3A_POS_FRAC_NUM=3; EV3A_POS_FRAC_DEN=4     # 양성 문턱 = baseline + 0.75×delay
EV3A_NEG_FRAC_NUM=1; EV3A_NEG_FRAC_DEN=4     # 음성 문턱 = baseline + 0.25×delay

ev3a_baseline() {   # $1=mode $2=body $3=prompt → 지연 없는 판정 2회 표본 중 최소 wall_clock_ms (새 샌드박스씩)
  local m="$1" b="$2" p="$3" w1 w2
  e2e_setup; FAKE_CODEX_VERDICT="$b" run_wrapper "$p"; w1=$(last_event_field wall_clock_ms); e2e_teardown
  e2e_setup; FAKE_CODEX_VERDICT="$b" run_wrapper "$p"; w2=$(last_event_field wall_clock_ms); e2e_teardown
  if [ "$w1" -le "$w2" ] 2>/dev/null; then printf '%s' "$w1"; else printf '%s' "$w2"; fi
}
ev3a_baseline_with_rein() {   # $1=body $2=prompt $3=subject_json → code 모드 + mk_fake_rein_bin 존재, 2회 표본 중 최소
  local b="$1" p="$2" subj="$3" w1 w2
  e2e_setup; mk_fake_rein_bin; FAKE_REIN_SUBJECT_JSON="$subj" FAKE_CODEX_VERDICT="$b" run_wrapper "$p"; w1=$(last_event_field wall_clock_ms); e2e_teardown
  e2e_setup; mk_fake_rein_bin; FAKE_REIN_SUBJECT_JSON="$subj" FAKE_CODEX_VERDICT="$b" run_wrapper "$p"; w2=$(last_event_field wall_clock_ms); e2e_teardown
  if [ "$w1" -le "$w2" ] 2>/dev/null; then printf '%s' "$w1"; else printf '%s' "$w2"; fi
}

ev3a_seam_case() {
  # $1=label $2=mode(code|spec) $3=verdict-body $4=prompt $5=site $6=expect(ge|lt)
  # baseline 을 이 자리에서 직접 재고(짝지어 측정) 곧바로 비교한다.
  local label="$1" mode="$2" body="$3" prompt="$4" site="$5" expect="$6"
  local baseline; baseline=$(ev3a_baseline "$mode" "$body" "$prompt")
  e2e_setup
  REIN_REVIEW_TEST_DELAY_AT="${site}:${EV3A_DELAY_S}" FAKE_CODEX_VERDICT="$body" run_wrapper "$prompt"
  local wall; wall=$(last_event_field wall_clock_ms)
  if [ "$expect" = "ge" ]; then
    local thr=$((baseline + EV3A_DELAY_MS * EV3A_POS_FRAC_NUM / EV3A_POS_FRAC_DEN))
    assert_ge "$wall" "$thr" "$label: wall_clock_ms >= baseline+0.75*delay ($thr, baseline=${baseline}ms) — site=$site 정확"
  else
    local thr=$((baseline + EV3A_DELAY_MS * EV3A_NEG_FRAC_NUM / EV3A_NEG_FRAC_DEN))
    assert_lt "$wall" "$thr" "$label: wall_clock_ms < baseline+0.25*delay ($thr, baseline=${baseline}ms) — site=$site 미스매치 → 지연 없음"
  fi
  e2e_teardown
}

echo "-- EV3a: 지점별 seam (REIN_REVIEW_TEST_DELAY_AT=<site>:${EV3A_DELAY_S}) — 짝지은 baseline 상대 오라클"
# PASS → counter-clear (양 모드) + evidence (code) — 3 콤보.
ev3a_seam_case "EV3a-code-PASS-counter-clear" "code" "$PASS_BODY" "$CODE_PROMPT" "counter-clear" ge
ev3a_seam_case "EV3a-code-PASS-evidence"      "code" "$PASS_BODY" "$CODE_PROMPT" "evidence"      ge
ev3a_seam_case "EV3a-spec-PASS-counter-clear" "spec" "$PASS_BODY" "$PROMPT_A"   "counter-clear" ge

# NEEDS-FIX/REJECT → counter-commit (양 모드 + 두 outcome) — 3 콤보.
ev3a_seam_case "EV3a-code-NEEDSFIX-counter-commit" "code" "$NEEDS_FIX_BODY" "$CODE_PROMPT" "counter-commit" ge
ev3a_seam_case "EV3a-spec-NEEDSFIX-counter-commit" "spec" "$NEEDS_FIX_BODY" "$PROMPT_A"   "counter-commit" ge
ev3a_seam_case "EV3a-code-REJECT-counter-commit"   "code" "$REJECT_BODY"    "$CODE_PROMPT" "counter-commit" ge

echo "-- EV3a: 지점 이름 미스매치 — 지연이 그 판정 경로에 붙지 않음"
# evidence 는 code PASS 전용 — spec PASS 에 지정하면 그 지점에 도달하지 않아
# 지연이 없어야 한다 (seam 이 실제 지점에만 붙어 있다는 증거).
ev3a_seam_case "EV3a-spec-PASS-evidence-mismatch" "spec" "$PASS_BODY" "$PROMPT_A" "evidence" lt
# counter-commit 은 미통과 경로 전용 — code PASS 는 counter-clear 로 가므로
# counter-commit 을 지정해도 지연이 없어야 한다.
ev3a_seam_case "EV3a-code-PASS-counter-commit-mismatch" "code" "$PASS_BODY" "$CODE_PROMPT" "counter-commit" lt

echo "-- EV3a: 자연 주입 (i) — NEEDS-FIX 카운터 락 선점 (프로세스 생존 확인 방식)"
# 두 독립 타이머(래퍼 내부 워밍업 vs 보류 해제 시각)를 서로 맞추는 방식은
# 시스템 부하가 흔들리면 경합이 온전히 재현되지 않을 수 있다. 대신 락을
# 미리 잡고 래퍼를 백그라운드로 띄운 뒤, 이 하네스의 정상 baseline 보다
# 충분히 긴 절대 시간이 지나도 프로세스가 **살아 있는지**(kill -0) 직접
# 확인한다 — 그 시점까지 안 끝났다는 사실 자체가 락 대기 중이라는 증거다.
# 그 뒤 락을 풀어 완료시키고, 최종 wall_clock_ms·exit 코드·로그 줄 수로
# 2회차가 readiness 단계가 아니라 실제 verdict/commit 경로까지 도달했음을
# 확인한다. run_wrapper 와 동일한 파일명(.stdin.txt 등)을 써야 한다 —
# 샌드박스 .gitignore 패턴과 어긋나는 임시파일명은 untracked 로 남아
# 2회차 selfverify 관문을 오발동시킨다.
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
for f in "$SANDBOX"/trail/dod/.review-rounds/*; do
  [ -f "$f" ] && mkdir -p "${f}.lock"
done
printf '%s' "$CODE_PROMPT" > "$SANDBOX/.stdin.txt"
(
  cd "$SANDBOX"
  export CODEX_BIN="$FAKE_CODEX"
  export FAKE_CODEX_CAPTURE="$SANDBOX/.capture.txt"
  export TMPDIR="$SANDBOX/tmpdir"
  export FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY"
  bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
    < "$SANDBOX/.stdin.txt" > "$SANDBOX/.out.txt" 2> "$SANDBOX/.err.txt"
) &
_ev_nat1_pid=$!
sleep 3.5
TEST_COUNT=$((TEST_COUNT + 1))
if kill -0 "$_ev_nat1_pid" 2>/dev/null; then
  echo "  ok: EV3a-natural-i: 3.5s 뒤에도 래퍼가 살아 있음 (락 대기 경합 재현 확인)"
else
  fail "EV3a-natural-i: 래퍼가 락 경합 없이 3.5s 안에 끝나버림 (경합이 재현되지 않음)"
fi
for f in "$SANDBOX"/trail/dod/.review-rounds/*.lock; do
  [ -d "$f" ] && rmdir "$f" 2>/dev/null
done
wait "$_ev_nat1_pid"
_ev_nat1_rc=$?
assert_eq "$_ev_nat1_rc" "1" "EV3a-natural-i: 2회차가 readiness 단계가 아니라 verdict 경로에 도달 (exit=1, readiness-reject=4 아님)"
assert_eq "$(event_line_count)" "2" "EV3a-natural-i: 2회차 판정도 로그에 추가 기록됨(1회차+2회차)"
assert_ge "$(last_event_field wall_clock_ms)" "3000" "EV3a-natural-i: 락 대기가 wall_clock_ms 에 포함 (3.5s 생존 확인 근거)"
e2e_teardown

echo "-- EV3a: 자연 주입 (iv) — 초기화(selector 로드) 지연도 t0 뒤 구간에 포함 (짝지은 baseline 상대)"
_ev_nat4_base=$(ev3a_baseline spec "$PASS_BODY" "$PROMPT_A")
e2e_setup
# 첫 줄(shebang) 뒤에 sleep 줄을 끼운 새 파일로 교체한다 — sed 의 제자리 편집
# 옵션과 한 줄 형식 `1a text` 는 GNU sed 전용이라 BSD sed 에서는 주입 없이 지나간다.
_ev_nat4_lib="$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
{ head -n 1 "$_ev_nat4_lib"; printf 'sleep %s\n' "$EV3A_DELAY_S"; tail -n +2 "$_ev_nat4_lib"; } > "$_ev_nat4_lib.new" \
  && mv "$_ev_nat4_lib.new" "$_ev_nat4_lib"
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$PROMPT_A"
assert_ge "$(last_event_field wall_clock_ms)" "$((_ev_nat4_base + EV3A_DELAY_MS * EV3A_POS_FRAC_NUM / EV3A_POS_FRAC_DEN))" "EV3a-natural-iv: selector 로드 지연이 wall_clock_ms 에 포함 (baseline=${_ev_nat4_base}ms, t0=wrapper 진입)"
e2e_teardown

echo "-- EV3a: 자연 주입 (ii) — code PASS 의 v2 evidence 발급 지연(FAKE_REIN_DELAY, 짝지은 baseline 상대)"
# mk_fake_rein_bin 스텁은 --print-subject·--verdict(issue-evidence) 두 분기
# 모두에서 FAKE_REIN_DELAY 만큼 sleep 한다 — code-review PASS 사이클은 두
# 분기를 모두 거치므로 실제 추가 지연은 2×delay 다.
_EV_NAT2_SUBJ='{"subject": "sha256:2222222222222222222222222222222222222222222222222222222222222222", "paths": [], "changeset_paths": []}'
_ev_nat2_base=$(ev3a_baseline_with_rein "$PASS_BODY" "$CODE_PROMPT" "$_EV_NAT2_SUBJ")
e2e_setup
mk_fake_rein_bin
FAKE_REIN_SUBJECT_JSON="$_EV_NAT2_SUBJ" FAKE_REIN_DELAY="$EV3A_DELAY_S" FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$CODE_PROMPT"
assert_ge "$(last_event_field wall_clock_ms)" "$((_ev_nat2_base + EV3A_DELAY_MS * 2 * EV3A_POS_FRAC_NUM / EV3A_POS_FRAC_DEN))" "EV3a-natural-ii: v2 evidence 발급 지연이 wall_clock_ms 에 포함 (baseline=${_ev_nat2_base}ms, ×2 분기)"
e2e_teardown

echo "-- EV3a: 자연 주입 (iii) — spec PASS 뒤 caller 표식(rein-mark-spec-reviewed.sh)은 구간 밖 (짝지은 baseline 상대)"
# 로그 값은 caller 표식(외부 sleep + mark 스크립트)이 끝난 **뒤**에 읽는다
# — 미리 읽어두면 "그 시점까지는 당연히 반영 안 됨" 이라는 자명한 사실만
# 확인하는 셈이라, 실제 관찰 시점을 뒤로 미뤄야 경계 계약을 제대로 본다.
_ev_nat3_base=$(ev3a_baseline spec "$PASS_BODY" "$PROMPT_A")
e2e_setup
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$PROMPT_A"
sleep 4
REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$REAL_PROJECT_DIR/scripts/rein-mark-spec-reviewed.sh" docs/specs/sample-a.md t >/dev/null 2>&1 || true
_ev_nat3_wall=$(last_event_field wall_clock_ms)
assert_lt "$_ev_nat3_wall" "$((_ev_nat3_base + 1500))" "EV3a-natural-iii: caller 표식(sleep 4 뒤)은 구간 밖이라 로그 값에 반영되지 않음 (baseline=${_ev_nat3_base}ms)"
e2e_teardown

# ============================================================
# EV-JSON — _json_str 이스케이프 라운드트립 안전성.
# 계약: 백슬래시·따옴표·개행·탭·제어문자·끝 개행이 JSON 문자열로 왕복(json.loads)해 원문과 일치하고, 값에 이스케이프된 따옴표가 있어도 다른 필드 경계를 열지 못한다.

echo "-- EV-JSON: _json_str 라운드트립"
e2e_setup
json_str_of() {   # $1=input → _json_str 결과 (source-and-call)
  BODY="$1" src_eval 'printf "%s" "$(_json_str "$BODY")"'
}
assert_json_roundtrip() {   # $1=label $2=input
  local label="$1" input="$2" out rt
  out=$(json_str_of "$input")
  TEST_COUNT=$((TEST_COUNT + 1))
  if ! printf '%s' "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
    fail "$label: 유효 JSON 아님 (raw=$out)"; return 0
  fi
  echo "  ok: $label: 유효 JSON"
  rt=$(printf '%s' "$out" | python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.stdin.read()))')
  assert_eq "$rt" "$input" "$label: 라운드트립 일치"
}
assert_json_roundtrip 'EV-JSON-quote-backslash' 'he said "hi"\'
assert_json_roundtrip 'EV-JSON-injection' 'x\", "injected": "PWNED'
printf -v _ev_json_nl 'line1\nline2'
assert_json_roundtrip 'EV-JSON-newline' "$_ev_json_nl"
printf -v _ev_json_tab 'a\tb'
assert_json_roundtrip 'EV-JSON-tab' "$_ev_json_tab"
printf -v _ev_json_ctrl 'a\x01b'
assert_json_roundtrip 'EV-JSON-ctrl' "$_ev_json_ctrl"
assert_eq "$(json_str_of '')" "null" "EV-JSON-empty: 빈 문자열 → null"
e2e_teardown

echo "-- EV-JSON: e2e — 문서 경로에 \\\" 포함(정규화 실패로 원문 통과) 시에도 로그 줄이 유효 JSON 유지"
e2e_setup
INJECT_PROMPT='[NON_INTERACTIVE] spec review for design: docs/specs/x\", "injected": "PWNED.md
Validate technical soundness.'
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$INJECT_PROMPT"
_ev_json_e2e_line=$(tail -1 "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null)
TEST_COUNT=$((TEST_COUNT + 1))
if printf '%s' "$_ev_json_e2e_line" | python3 -c 'import json,sys; json.loads(sys.stdin.readline())' >/dev/null 2>&1; then
  echo "  ok: EV-JSON-e2e: 로그 마지막 줄이 유효 JSON (경로 주입 문자열 포함)"
else
  fail "EV-JSON-e2e: 로그 마지막 줄 JSON 파싱 실패 (line=$_ev_json_e2e_line)"
fi
_ev_json_e2e_outcome=$(printf '%s' "$_ev_json_e2e_line" \
  | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["outcome"], end="")' 2>/dev/null)
assert_eq "$_ev_json_e2e_outcome" "verdict:PASS" "EV-JSON-e2e: outcome 필드가 주입 문자열에 오염되지 않고 원래 값 유지"
e2e_teardown

# ============================================================
# EV-SEAM — _test_delay_at 형식 방어.
# 계약: 값이 `<site>:<sec>`(sec 는 숫자) 형식이 아니면 sleep 없이 WARNING 1줄 후 return 0 — set -e 아래에서도 _review_exit 경로가 끊기지 않는다.

echo "-- EV-SEAM: REIN_REVIEW_TEST_DELAY_AT 형식 오류는 판정을 죽이지 않는다"
ev_seam_malformed_case() {
  local label="$1" body="$2" prompt="$3" bad_value="$4" expect_rc="$5"
  e2e_setup
  REIN_REVIEW_TEST_DELAY_AT="$bad_value" FAKE_CODEX_VERDICT="$body" run_wrapper "$prompt"
  assert_eq "$RC" "$expect_rc" "$label: exit 코드가 verdict 그대로 (seam 오류가 판정을 죽이지 않음)"
  assert_eq "$(event_line_count)" "1" "$label: 로그 줄이 그대로 남음"
  assert_contains "$ERR" "WARNING: [codex-review][test-seam]" "$label: 형식 오류 WARNING 앵커"
  e2e_teardown
}
ev_seam_malformed_case "EV-SEAM-no-colon"     "$PASS_BODY"      "$CODE_PROMPT" "counter-clear"     "0"
ev_seam_malformed_case "EV-SEAM-nonnumeric"   "$NEEDS_FIX_BODY" "$CODE_PROMPT" "counter-commit:abc" "1"

# ============================================================
# EV-TOCTOU — _review_event_commit append 직전 재검사.
#  최초 심볼릭 링크 검사와 실제 append 사이에
# 경로가 바뀌면(mkdir -p 뒤, 또는 파일 자리에 디렉토리가 놓이면) 원래
# 검사는 이미 지나간 뒤였다. append 직전에 링크 여부를 재검사하고, 대상이
# 존재하는데 정규 파일이 아니면 거부한다.
# ============================================================

echo "-- EV-TOCTOU: 로그 파일 자리에 디렉토리가 있으면 append 직전 재검사가 거부한다"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$RC" "1" "EV-TOCTOU-dir: 사전 호출로 로그 파일 생성 (NEEDS-FIX exit 1)"
_ev_toctou_f=$(ls "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null | head -1)
TEST_COUNT=$((TEST_COUNT + 1))
if [ -n "$_ev_toctou_f" ] && [ -f "$_ev_toctou_f" ]; then echo "  ok: EV-TOCTOU-dir: 로그 파일 경로 확보"
else fail "EV-TOCTOU-dir: 로그 파일 부재"; fi
rm -f "$_ev_toctou_f"
mkdir -p "$_ev_toctou_f"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$RC" "1" "EV-TOCTOU-dir: 2회차가 readiness 단계가 아니라 verdict 경로에 도달 (exit=1, readiness-reject=4 아님)"
assert_contains "$ERR" "ERROR: [codex-review][review-events]" "EV-TOCTOU-dir: 이벤트 기록 실패 ERROR 앵커"
e2e_teardown

echo "-- EV-TOCTOU: 로그 파일 자리에 심볼릭 링크가 있으면 append 직전 재검사가 거부한다"
e2e_setup
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
_ev_toctou_f2=$(ls "$SANDBOX"/trail/review-events/*.jsonl 2>/dev/null | head -1)
_ev_toctou_outside="$SANDBOX/../rein-events-outside-$$.txt"
: > "$_ev_toctou_outside"
rm -f "$_ev_toctou_f2"
ln -s "$_ev_toctou_outside" "$_ev_toctou_f2"
FAKE_CODEX_VERDICT="$NEEDS_FIX_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$RC" "1" "EV-TOCTOU-link: 2회차가 readiness 단계가 아니라 verdict 경로에 도달 (exit=1, readiness-reject=4 아님)"
assert_contains "$ERR" "ERROR: [codex-review][review-events]" "EV-TOCTOU-link: 이벤트 기록 실패 ERROR 앵커"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -s "$_ev_toctou_outside" ]; then echo "  ok: EV-TOCTOU-link: 저장소 밖 파일 무변조"
else fail "EV-TOCTOU-link: 링크를 따라가 외부 파일에 기록됨"; fi
rm -f "$_ev_toctou_outside"
e2e_teardown

# ============================================================
# EV-TRAIL-LINK — trail 자체가 심볼릭 링크일 때의 저장소 경계 containment.
# _review_event_commit 의 -L 검사는 review-events 와 그 직계 부모(trail)
# 만 본다 — trail 자체가 링크면 mkdir -p 가 그 링크를 따라 저장소 밖에
# 로그 디렉토리를 만든다. canonical 경로 비교로 막는다.
# ============================================================

echo "-- EV-TRAIL-LINK: trail 자체가 심볼릭 링크면 저장소 경계 검사가 거부한다"
e2e_setup
_ev_trail_outside="$SANDBOX/../rein-trail-outside-$$"
mkdir -p "$_ev_trail_outside"
rm -rf "$SANDBOX/trail"
ln -s "$_ev_trail_outside" "$SANDBOX/trail"
# .gitignore 의 `trail/` 패턴은 디렉토리에만 매치한다 — 심볼릭 링크로
# 바뀌면 더 이상 매치하지 않아 git 이 untracked 로 본다. selfverify 관문이
# 이 변경 자체를 감지해 조기 종료하지 않도록 커밋해 트리를 다시 깨끗하게
# 만든다(테스트 대상은 이벤트 로그의 경계 검사이지 selfverify 가 아니다).
# e2e_setup 과 같은 이유로 그 뒤에 빈 커밋을 하나 더 쌓는다 — 작업 트리가
# clean 이면 diff_base 가 직전 커밋 범위로 내려가므로, link 커밋을 마지막
# 커밋으로 남겨두면 그 자체가 "검토 대상 변경" 으로 다시 잡힌다.
( cd "$SANDBOX" && git add -A && git commit -q -m link && git commit --allow-empty -q -m head2 )
FAKE_CODEX_VERDICT="$PASS_BODY" run_wrapper "$CODE_PROMPT"
assert_eq "$RC" "0" "EV-TRAIL-LINK: trail 링크여도 판정 exit 는 verdict 그대로 (PASS=0)"
assert_contains "$ERR" "ERROR: [codex-review][review-events]" "EV-TRAIL-LINK: 이벤트 기록 실패 ERROR 앵커"
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -d "$_ev_trail_outside/review-events" ]; then echo "  ok: EV-TRAIL-LINK: 링크 대상 밖 디렉토리에 review-events 미생성"
else fail "EV-TRAIL-LINK: 링크를 따라가 밖 디렉토리에 review-events 가 생성됨"; fi
TEST_COUNT=$((TEST_COUNT + 1))
if [ ! -e "$SANDBOX/trail/review-events" ]; then echo "  ok: EV-TRAIL-LINK: 링크를 통해서도 review-events 가 보이지 않음(무기록)"
else fail "EV-TRAIL-LINK: review-events 가 생성됨"; fi
rm -rf "$_ev_trail_outside"
e2e_teardown

# ============================================================
# EV-TIME — _now_ms 의 EPOCHREALTIME 단일 캡처.
# 정수부(%.*)와 소수부(#*.)를 한 식 안에서 EPOCHREALTIME 을 두 번 참조하면,
# 그 사이 초 경계를 넘을 때 서로 다른 초의 값이 섞여 최대 1초까지 부풀 수
# 있다. 로컬 변수로 한 번만 캡처해야 한다.
# ============================================================

echo "-- EV-TIME: _now_ms 단조 증가 + EPOCHREALTIME 단일 캡처 정적 검사"
e2e_setup
_ev_time_pair=$(src_eval 'a=$(_now_ms); b=$(_now_ms); printf "%s %s" "$a" "$b"')
_ev_time_a=$(printf '%s' "$_ev_time_pair" | awk '{print $1}')
_ev_time_b=$(printf '%s' "$_ev_time_pair" | awk '{print $2}')
assert_le "$_ev_time_a" "$_ev_time_b" "EV-TIME: _now_ms 연속 호출이 단조 비감소"
TEST_COUNT=$((TEST_COUNT + 1))
_ev_time_delta=$((_ev_time_b - _ev_time_a))
if [ "$_ev_time_delta" -lt 50 ] 2>/dev/null; then echo "  ok: EV-TIME: 연속 호출 간격이 50ms 미만"
else fail "EV-TIME: 연속 호출 간격이 50ms 이상 (${_ev_time_delta}ms)"; fi
# 정적 검사 — 초 경계 재현이 어려우므로 구현 자체가 이중 참조를 하지
# 않는지 소스를 직접 검사한다.
_ev_now_ms_body=$(awk '/^_now_ms\(\)/,/^}/' "$WRAPPER_SRC")
# 순수 주석 줄(첫 비공백 문자가 #)은 세지 않는다 — 설명 문구 안에 식별자
# 이름이 등장해도 실제 참조 횟수로 오산되지 않게.
_ev_epochrealtime_refs=$(printf '%s' "$_ev_now_ms_body" | grep -v '^[[:space:]]*#' | grep -o 'EPOCHREALTIME' | wc -l | tr -d ' ')
assert_eq "$_ev_epochrealtime_refs" "1" "EV-TIME: _now_ms 안 EPOCHREALTIME 참조가 정확히 1회"
# 소수점 문자가 쉼표인 로케일 — 특수 변수 속성을 떼고 값을 주입해 검사한다.
_ev_time_comma=$(src_eval 'unset EPOCHREALTIME; EPOCHREALTIME="1700000000,123456"; _now_ms')
assert_eq "$_ev_time_comma" "1700000000123" "EV-TIME: 소수점이 쉼표여도 ms 값이 숫자 13자리"
_ev_time_dot=$(src_eval 'unset EPOCHREALTIME; EPOCHREALTIME="1700000000.123456"; _now_ms')
assert_eq "$_ev_time_dot" "1700000000123" "EV-TIME: 소수점이 마침표일 때도 같은 값"
# 시계 값 한쪽만 비었거나 숫자가 아니면 소요는 null — 나머지 필드와 판정 exit 는 그대로.
_ev_wall_of() {   # $1=_review_exit 직전에 실행할 준비 코드
  src_eval "$1"'; ( _review_exit "verdict:PASS" 0 ); printf "rc=%s " "$?"; tail -1 "$REVIEW_EVENTS_DIR"/*.jsonl' \
    | python3 -c 'import json,sys; raw=sys.stdin.read(); rc,line=raw.split(" ",1); d=json.loads(line); print(rc, "null" if d["wall_clock_ms"] is None else d["wall_clock_ms"], d["outcome"])'
}
assert_eq "$(_ev_wall_of 'REVIEW_EVENT_T0_MS=""')" "rc=0 null verdict:PASS" "EV-TIME: 시작 시각이 비면 소요 null, exit·판정 불변"
assert_eq "$(_ev_wall_of '_now_ms() { printf ""; }')" "rc=0 null verdict:PASS" "EV-TIME: 종료 시각이 비면 소요 null, exit·판정 불변"
assert_eq "$(_ev_wall_of 'REVIEW_EVENT_T0_MS="12a"')" "rc=0 null verdict:PASS" "EV-TIME: 시작 시각이 숫자가 아니면 소요 null"
e2e_teardown

# ============================================================
# EV-JSON-TRAILNL — _json_str 의 끝 개행 보존.
# awk 는 기본 RS="\n" 로 레코드를 나누므로 입력이 개행으로 끝나면 그
# 개행 뒤에 빈 레코드가 없다고 보고 아무 것도 출력하지 않는다 — bash 의
# `$(...)` 는 그 자체로도 끝 개행을 지우므로, 이 라운드트립은 파일 비교
# (cmp) 로 검증한다(명령치환을 거치면 버그 유무와 무관하게 끝 개행이
# 사라져 오탐/누락이 생긴다).
# ============================================================

echo "-- EV-JSON: 끝 개행 보존 라운드트립"
e2e_setup
printf -v _ev_trailnl_in 'line1\n'
printf '%s' "$_ev_trailnl_in" > "$SANDBOX/.trailnl-in.bin"
json_str_of "$_ev_trailnl_in" > "$SANDBOX/.trailnl-out.json"
python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    val = json.loads(f.read())
with open(sys.argv[2], "wb") as f:
    f.write(val.encode("utf-8"))
' "$SANDBOX/.trailnl-out.json" "$SANDBOX/.trailnl-rt.bin"
TEST_COUNT=$((TEST_COUNT + 1))
if cmp -s "$SANDBOX/.trailnl-in.bin" "$SANDBOX/.trailnl-rt.bin"; then echo "  ok: EV-JSON-trailing-newline: 끝 개행 보존 라운드트립 일치"
else fail "EV-JSON-trailing-newline: 끝 개행 유실 (cmp mismatch)"; fi
e2e_teardown

# ============================================================
echo ""
echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
