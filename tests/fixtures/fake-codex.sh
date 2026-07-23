#!/usr/bin/env bash
# tests/fixtures/fake-codex.sh
# Fake `codex` binary for testing rein-codex-review.sh.
#
# Injection seam: wrapper reads CODEX_BIN env var. Tests set
# CODEX_BIN=./tests/fixtures/fake-codex.sh to substitute this stub
# for the real codex CLI.
#
# Contract with the wrapper:
#   - Receives the envelope on stdin (the wrapper pipes it with `| codex exec`).
#   - Ignores all CLI args (model, sandbox, etc.).
#   - Writes the captured stdin prompt to $FAKE_CODEX_CAPTURE (if set).
#   - Emits the verdict body configured via $FAKE_CODEX_VERDICT
#     (default: "PASS\nAll checks clean.") on stdout.
#   - $FAKE_CODEX_VERDICT_FILE (set + readable) overrides $FAKE_CODEX_VERDICT —
#     body is read from the file. Large payloads (>100KB, e.g. the D1 SIGPIPE
#     regression test) cannot ride an env var without hitting ARG_MAX in the
#     wrapper's child processes; a file path keeps the env small.
#   - Exits with $FAKE_CODEX_EXIT (default: 0).
#
# Hang-simulation options (2026-07-22 review-time-cap — all opt-in; unset
# means the legacy flow above is unchanged):
#   - $FAKE_CODEX_PARTIAL: emit this string immediately after stdin is
#     consumed (partial output before delay/drip/stall — combinable).
#   - $FAKE_CODEX_DELAY: sleep this long before emitting the verdict.
#     Positive integer or decimal string (delegated to sleep; BSD/GNU both
#     accept decimals — no integer-only [ -gt ] validation).
#   - $FAKE_CODEX_DRIP + $FAKE_CODEX_DRIP_COUNT (default: 10): emit a
#     "drip-line N" every $FAKE_CODEX_DRIP seconds, $FAKE_CODEX_DRIP_COUNT
#     times, then fall through to the verdict (bounded — no infinite drip).
#   - $FAKE_CODEX_STALL=1: hang forever after partial/delay/drip — verdict
#     never emitted (stall-detection path).
#   - $FAKE_CODEX_IGNORE_TERM=1: ignore SIGTERM (grace-exceeded → KILL path).
#   - $FAKE_CODEX_TERM_PROBE=<file>: on SIGTERM, record the count of
#     surviving ${TMPDIR:-/tmp}/rein-readiness.* files to <file>, then
#     exit 143 (reap-before-cleanup ordering oracle). Mutually exclusive
#     with IGNORE_TERM (IGNORE_TERM wins).
#   - `--version` anywhere in argv: print a version string and exit 0
#     immediately, ignoring ALL hang/delay options and without reading
#     stdin (the wrapper's pre-flight probe must never hang).
#
# The wrapper parses stdout for PASS / NEEDS-FIX / REJECT.

set -u

# --version 프로브 (R1 High-4): 래퍼가 본 호출 전 `$CODEX_BIN --version` 을
# 실행한다 (도장 증빙 필드). 행/지연 시뮬레이션 옵션 전부 무시하고 즉시 반환
# — stdin 도 읽지 않는다 (프로브는 envelope 를 소비하지 않음).
for _arg in "$@"; do
  if [ "$_arg" = "--version" ]; then
    printf 'fake-codex 0.0.0 (probe)\n'
    exit 0
  fi
done

# Subcommand might be `exec`, `exec resume`, etc. — swallow everything.
# Read all stdin (prompt/envelope).
capture_file="${FAKE_CODEX_CAPTURE:-}"
verdict_file="${FAKE_CODEX_VERDICT_FILE:-}"
verdict="${FAKE_CODEX_VERDICT:-PASS
All checks clean.}"
exit_code="${FAKE_CODEX_EXIT:-0}"
partial="${FAKE_CODEX_PARTIAL:-}"
delay="${FAKE_CODEX_DELAY:-}"
stall="${FAKE_CODEX_STALL:-}"
drip="${FAKE_CODEX_DRIP:-}"
drip_count="${FAKE_CODEX_DRIP_COUNT:-10}"   # DRIP 종료 조건 필수 (R1 Medium-6) — 무한 drip 방지
term_probe="${FAKE_CODEX_TERM_PROBE:-}"
if [ "${FAKE_CODEX_IGNORE_TERM:-}" = "1" ]; then
  trap '' TERM   # SIGTERM 무시 — grace 초과 → KILL 경로 검증
elif [ -n "$term_probe" ]; then
  # W10 순서 oracle (R3/R4 Medium): TERM 받는 시점의 케이스 TMPDIR 내
  # rein-readiness.* 잔존 개수를 기록 후 종료. reap→cleanup 순서가
  # 지켜지면 child TERM 시점에 스풀/envelope 이 아직 존재(개수 ≥1),
  # cleanup 이 먼저면 0 — 최종 상태 비교로는 볼 수 없는 순서를 관찰.
  trap 'ls "${TMPDIR:-/tmp}"/rein-readiness.* 2>/dev/null | wc -l | tr -d " " > "$term_probe"; exit 143' TERM
fi

if [ -n "$capture_file" ]; then
  # Write stdin (the envelope) to the capture file for golden asserts.
  cat > "$capture_file"
else
  # Discard stdin if no capture requested.
  cat > /dev/null
fi

# 행 시뮬레이션 (2026-07-22 review-time-cap): 순서 = 부분 출력 → 지연 → drip → stall.
if [ -n "$partial" ]; then
  printf '%s\n' "$partial"     # 즉시 부분 출력 (STALL/DRIP 과 조합)
fi
# 지연값은 양의 정수/소수 문자열 모두 허용 (R4 High — `[ -gt 0 ]` 정수
# 비교는 4.5 같은 소수에서 false 가 되어 sleep 이 조용히 생략된다. 존재
# 검사 + sleep 위임: BSD/GNU sleep 모두 소수 지원).
if [ -n "$delay" ]; then
  sleep "$delay"               # verdict 출력 전 지연 — 상한 전/후 완료 경로
fi
if [ -n "$drip" ]; then
  _i=0
  while [ "$_i" -lt "$drip_count" ]; do
    sleep "$drip"
    printf 'drip-line %d\n' "$_i"   # 주기 출력 — 성장 유예(무기한) 경로
    _i=$((_i + 1))
  done                          # count 소진 후 fall-through → verdict 방출 + 정상 종료
fi
if [ "$stall" = "1" ]; then
  while :; do sleep 1; done     # 무한 정지 — verdict 미방출 (정지 판정 경로)
fi

if [ -n "$verdict_file" ] && [ -r "$verdict_file" ]; then
  cat "$verdict_file"
else
  printf '%s\n' "$verdict"
fi
exit "$exit_code"
