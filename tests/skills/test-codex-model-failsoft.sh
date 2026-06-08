#!/usr/bin/env bash
# tests/skills/test-codex-model-failsoft.sh
#
# DoD codex-model-profile-routing 검증.
#
# 검증 항목:
#   T1. 래퍼가 단일 출처(config/codex-models.sh)의 CODE_MODEL 을 -m 으로 전달.
#   T2. 모델 거부(invalid_request_error / is not supported, exit 1) 시
#       래퍼가 exit 3 + 단일 출처 경로/변수 안내 + 통과 표시 미생성.
#   T3. codex exit 0 이어도 출력에 모델 거부가 섞이면 동일 처리(방어).
#   T4. config 부재 시 -m 생략(graceful degrade) + 정상 통과 표시 생성.
#   T5. 정상 모델 PASS → 기존대로 통과 표시 생성(회귀).
#
# 주입 seam: 래퍼는 CODEX_BIN 으로 codex 바이너리를 대체한다. 본 테스트는
# args 캡처 + 출력/종료코드 제어가 가능한 자체 stub 을 sandbox 에 만든다.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

TEST_COUNT=0
FAIL_COUNT=0
SANDBOX=""

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }
check() { TEST_COUNT=$((TEST_COUNT + 1)); if eval "$1"; then echo "  ok: $2"; else fail "$2"; fi; }

find_lib() {
  if [ -f "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  elif [ -f "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
    echo "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  fi
}

sandbox_setup() {
  SANDBOX=$(mktemp -d "/tmp/codex-failsoft-XXXXXX")
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/config" "$SANDBOX/trail/dod" \
           "$SANDBOX/.claude/hooks/lib"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh" \
     "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"
  local lib; lib="$(find_lib)"
  if [ -z "$lib" ]; then
    echo "sandbox_setup: select-active-dod.sh not found" >&2; return 1
  fi
  cp "$lib" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  cp "$(dirname "$lib")/path-containment.sh" \
     "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  # 단일 출처 (테스트 제어용 모델명).
  cat > "$SANDBOX/config/codex-models.sh" <<'CONF'
ANALYSIS_MODEL="gpt-test-analysis"
CODE_MODEL="gpt-test-code"
ANALYSIS_EFFORT="high"
CODE_EFFORT="high"
CONF
  # args 캡처 + 출력/종료코드 제어 stub.
  cat > "$SANDBOX/stub-codex.sh" <<'STUB'
#!/usr/bin/env bash
set -u
[ -n "${STUB_ARGS_OUT:-}" ] && printf '%s\n' "$*" > "$STUB_ARGS_OUT"
cat > /dev/null
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
trap sandbox_teardown EXIT

# run_wrapper <stderr-file> — env STUB_* / STUB_ARGS_OUT passed by caller.
run_wrapper() {
  ( cd "$SANDBOX" && CODEX_BIN="$SANDBOX/stub-codex.sh" \
      REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash scripts/rein-codex-review.sh --non-interactive \
      < /dev/null > "$SANDBOX/out.txt" 2> "$1" )
}

echo "== codex model fail-soft tests =="

# ---- T1 + T5: 정상 모델 → -m 전달 + 통과 표시 생성 --------------------
sandbox_setup
STUB_ARGS_OUT="$SANDBOX/args.txt" STUB_VERDICT="PASS
clean" STUB_EXIT=0 run_wrapper "$SANDBOX/err.txt"
T1_RC=$?
check '[ "$T1_RC" = "0" ]' "T1/T5 정상 모델 → exit 0 (got $T1_RC)"
check '[ -f "$SANDBOX/trail/dod/.codex-reviewed" ]' "T5 정상 PASS → 통과 표시 생성"
check 'grep -q -- "-m gpt-test-code" "$SANDBOX/args.txt"' \
  "T1 CODE_MODEL 이 -m 으로 전달됨 (args: $(cat "$SANDBOX/args.txt" 2>/dev/null))"
sandbox_teardown

# ---- T2: 모델 거부 (exit 1) → exit 3 + 안내 + 통과 표시 미생성 --------
sandbox_setup
STUB_VERDICT='ERROR: {"type":"error","error":{"type":"invalid_request_error","message":"The model is not supported when using Codex with a ChatGPT account."}}' \
  STUB_EXIT=1 run_wrapper "$SANDBOX/err.txt"
T2_RC=$?
check '[ "$T2_RC" = "3" ]' "T2 모델 거부(exit1) → 래퍼 exit 3 (got $T2_RC)"
check '[ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]' "T2 통과 표시 미생성"
check 'grep -q "codex-models.sh" "$SANDBOX/err.txt"' "T2 안내에 단일 출처 경로 포함"
check 'grep -q "CODE_MODEL" "$SANDBOX/err.txt"' "T2 안내에 수정 대상 변수명 포함"
sandbox_teardown

# ---- T3: 방어 — exit 0 이지만 출력에 모델 거부 → exit 3 --------------
sandbox_setup
STUB_VERDICT='ERROR: invalid_request_error: the model is not supported' \
  STUB_EXIT=0 run_wrapper "$SANDBOX/err.txt"
T3_RC=$?
check '[ "$T3_RC" = "3" ]' "T3 exit0+거부출력 → 래퍼 exit 3 (got $T3_RC)"
check '[ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]' "T3 통과 표시 미생성"
sandbox_teardown

# ---- T4: config 부재 → -m 생략(graceful) + 정상 통과 -----------------
sandbox_setup
rm -f "$SANDBOX/config/codex-models.sh"
STUB_ARGS_OUT="$SANDBOX/args.txt" STUB_VERDICT="PASS
clean" STUB_EXIT=0 run_wrapper "$SANDBOX/err.txt"
T4_RC=$?
check '[ "$T4_RC" = "0" ]' "T4 config 부재 → exit 0 (got $T4_RC)"
check '! grep -q -- "-m " "$SANDBOX/args.txt"' \
  "T4 config 부재 시 -m 생략 (args: $(cat "$SANDBOX/args.txt" 2>/dev/null))"
sandbox_teardown

# ---- T6: 다른 거부 문구(model_not_found)도 감지 ----------------------
sandbox_setup
STUB_VERDICT='{"error":{"code":"model_not_found","message":"The model does not exist"}}' \
  STUB_EXIT=1 run_wrapper "$SANDBOX/err.txt"
T6_RC=$?
check '[ "$T6_RC" = "3" ]' "T6 model_not_found 문구 → exit 3 (got $T6_RC)"
check '[ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ]' "T6 통과 표시 미생성"
sandbox_teardown

# ---- T7: 정상 PASS 리뷰가 거부 문구를 본문에 인용해도 오탐하지 않음 --
# (FINAL_VERDICT 가 있으면 모델 거부 아님. fail-soft 자체를 리뷰할 때 실제
#  발생한 오탐의 회귀 방지 — codex review round 3.)
sandbox_setup
STUB_VERDICT='## Code defects
The invalid_request_error / model_not_found / is not supported when using Codex
patterns are discussed in this review body.
FINAL_VERDICT: PASS' STUB_EXIT=0 run_wrapper "$SANDBOX/err.txt"
T7_RC=$?
check '[ "$T7_RC" = "0" ]' "T7 거부 문구 인용한 정상 PASS → exit 0 (오탐 없음, got $T7_RC)"
check '[ -f "$SANDBOX/trail/dod/.codex-reviewed" ]' "T7 정상 PASS → 통과 표시 생성"
sandbox_teardown

echo "TESTS: $TEST_COUNT, FAILS: $FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
