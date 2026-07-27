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

# 잔존 검사용 PID 기록 (2026-07-27): `pgrep` 은 격리 샌드박스에서 관측 실패하므로
# 프로세스 열거에 의존하지 않는 결정론적 oracle 을 테스트에 제공한다.
if [ -n "${FAKE_CODEX_PIDFILE:-}" ]; then printf '%s\n' "$$" > "$FAKE_CODEX_PIDFILE" 2>/dev/null || true; fi

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
# 자식 명령 실행 시뮬레이션 (2026-07-27 watchdog false-stall).
# 실제 codex 는 자식 명령 실행 **중에는 출력을 내지 않고** 완료 시점에
# ` succeeded in <N>ms:` 로 일괄 방출한다 (2026-07-27 실측). 아래 두 축을
# 개별/조합으로 재현한다.
#   - FAKE_CODEX_EXEC_MARKER=1 : 시작 표식만 방출(완료 표식 없음) → 축 A
#   - FAKE_CODEX_EXEC_DONE=1   : 완료 표식까지 방출 → 축 A 해제(짝 맞춤)
#   - FAKE_CODEX_CHURN=<sec>   : N초간 매초 단발성 자식 생성 → 축 B (테스트 스위트 모사)
if [ "${FAKE_CODEX_EXEC_MARKER:-}" = "1" ]; then
  printf 'exec\n'
  printf "/bin/zsh -lc 'sleep 30' in %s\n" "$PWD"
fi
if [ -n "${FAKE_CODEX_CHURN:-}" ]; then
  _c=0
  while [ "$_c" -lt "${FAKE_CODEX_CHURN}" ]; do
    sh -c 'exit 0'              # 단발성 자식 — 자손 PID 집합이 매초 바뀐다
    sleep 1
    _c=$((_c + 1))
  done                          # 무출력 — 출력 성장 축은 계속 0
fi
if [ "${FAKE_CODEX_EXEC_DONE:-}" = "1" ]; then
  printf ' succeeded in 100ms:\n'
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
  # 무한 정지 — verdict 미방출 (정지 판정 경로).
  # 긴 sleep 을 쓰는 이유(2026-07-27 watchdog false-stall): `sleep 1` 반복은
  # 매초 새 자식 PID 를 만들어 워치독의 자식-활동 축에 "활동 중"으로 보인다.
  # 진짜 hang 은 프로세스 트리가 정지해 있어야 하므로 안정된 단일 자식으로
  # 모델링한다 (테스트 deadline 은 모두 이보다 짧다).
  #
  # background + `wait` 인 이유: foreground `sleep 30` 중에는 bash 가 TERM 트랩을
  # 자식 완료까지 **지연**시켜 W10 의 TERM_PROBE 가 grace 안에 기록되지 못한다.
  # `wait` 중에는 트랩이 즉시 실행되므로 안정된 트리와 TERM 응답성을 동시에 만족.
  # 고아 정리(2026-07-27 codex R1): 부모가 TERM 으로 죽으면 background sleep 이
  # 남는다. residue 검사는 argv 에 sandbox 경로가 있는 프로세스만 세므로 일반
  # `sleep 30` 을 놓친다 — EXIT 트랩으로 직접 거둔다. SIGKILL 경로(W4)는 트랩이
  # 돌지 않으므로 최대 30초 자연 소멸이 남는 알려진 한계다.
  _stall_pid=""
  # kill 후 wait 로 거둔다 (R2 Low) — kill 만으로는 좀비가 남을 수 있다.
  trap '[ -n "$_stall_pid" ] && { kill "$_stall_pid" 2>/dev/null; wait "$_stall_pid" 2>/dev/null; }; true' EXIT
  while :; do
    sleep 30 &
    _stall_pid=$!
    wait "$_stall_pid" 2>/dev/null || true
  done
fi

if [ -n "$verdict_file" ] && [ -r "$verdict_file" ]; then
  cat "$verdict_file"
else
  printf '%s\n' "$verdict"
fi
exit "$exit_code"
