#!/bin/bash
# tests/hooks/test-sandbox-teardown-retry.sh
#
# Phase 7 wave 3 ③-b code review round 3 (Medium) — 재현 완료: 여러
# tests/hooks/*.sh (예: test-active-task-authority-switch.sh) 는 실제
# `rein` 파이썬 패키지를 샌드박스에 심볼릭 링크한다
# (`$SANDBOX/.claude/rein` → plugins/rein-core/rein). 그 상태에서 훅이
# hooks/lib/shadow-capture.sh 의 fire-and-forget 배경 서브셸(disown 된
# python 프로세스)을 태우면, 그 프로세스는 훅 자신이 exit 한 뒤에도 살아
#남아 `$SANDBOX/.rein/...` 에 corpus 기록을 계속 시도한다 — 바로 다음에
# 실행되는 tests/hooks/lib/test-harness.sh 의 `sandbox_teardown()` 의
# 즉시 `rm -rf` 와 경쟁해 "Directory not empty" 오류 + 잔존 디렉토리를
# 남긴다(2026-08-23 재현: `bash tests/hooks/run-all.sh` 1회 실행에서 9건
# 관측, `/tmp/dod-test-*` 잔존 7건 신규 발생).
#
# 이 경쟁은 훅 자신의 exit code/판정과 무관한 순수 관측 지연이다(shadow
# capture 계약: 실패/지연이 훅 판정에 영향을 주지 않는다 — hooks/lib/
# shadow-capture.sh 헤더 참조). 따라서 수리는 그 계약이나 판정 로직을
# 건드리지 않고, teardown 자체를 몇 차례 짧게 재시도해 비동기 기록의
# 꼬리를 흡수하는 것이다(총 상한 ~2초, tests/hooks/lib/test-harness.sh
# 의 sandbox_teardown() 참조).
#
# 이 테스트는 그 실제 경쟁을 타이밍에 의존해 재현하지 않는다(비결정적).
# 대신 sandbox_teardown() 의 재시도 로직 자체를 결정론적으로 고정한다:
# `rm` 을 처음 N 회는 실패시키고 그 다음에는 성공시키는 스텁으로 교체해,
# teardown 이 (a) 그 일시적 실패를 넘겨 결국 디렉토리를 지우고 (b) 무한
# 대기 없이 상한 내에서 끝나는지 확인한다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# _with_fake_rm_failing_n_times N
#   Build a tmpdir containing an `rm` that fails (exit 1, no deletion) for
#   the first N invocations, then delegates to the real `rm` for every
#   call after that. Prints the fake dir path (for a caller-scoped PATH
#   prefix — NOT exported globally, since almost everything in this test
#   process calls `rm`, unlike the narrow bare-`mktemp` case in
#   with_fake_mktemp_failing).
_with_fake_rm_failing_n_times() {
  local n="$1" d real_rm
  real_rm=$(command -v rm) || return 1
  d=$(mktemp -d "/tmp/fake-rm-fail-XXXXXX") || return 1
  printf '0\n' > "$d/.count"
  cat > "$d/rm" <<EOF
#!/usr/bin/env bash
count_file="$d/.count"
limit=$n
n=\$(cat "\$count_file" 2>/dev/null || echo 0)
if [ "\$n" -lt "\$limit" ]; then
  n=\$((n + 1))
  printf '%s\n' "\$n" > "\$count_file"
  echo "rm: fake transient failure (\$n/\$limit)" >&2
  exit 1
fi
exec '$real_rm' "\$@"
EOF
  chmod +x "$d/rm"
  printf '%s\n' "$d"
}

test_teardown_retries_past_transient_rm_failures() {
  local victim fake_rm_dir before after
  victim=$(mktemp -d "/tmp/dod-test-teardown-XXXXXX")
  mkdir -p "$victim/sub"
  touch "$victim/sub/file.txt"

  fake_rm_dir=$(_with_fake_rm_failing_n_times 2)
  if [ -z "$fake_rm_dir" ]; then
    fail "_with_fake_rm_failing_n_times 자체가 실패 — 테스트 인프라 준비 불능"
    rm -rf "$victim" 2>/dev/null || true
    return
  fi

  before=$(date +%s)
  (
    PATH="$fake_rm_dir:$PATH"
    SANDBOX="$victim"
    sandbox_teardown
  )
  local rc=$?
  after=$(date +%s)

  rm -rf "$fake_rm_dir" 2>/dev/null || true

  [ "$rc" -eq 0 ] || fail "sandbox_teardown 서브셸이 비정상 종료(rc=$rc) — 일시적 rm 실패를 넘기지 못함"
  if [ -d "$victim" ]; then
    fail "sandbox_teardown 이 일시적 rm 실패 2회를 넘기고도 디렉토리를 결국 지우지 못함: $victim"
    rm -rf "$victim" 2>/dev/null || true
  fi
  local elapsed=$((after - before))
  if [ "$elapsed" -gt 5 ]; then
    fail "sandbox_teardown 재시도가 상한(~2초) 을 크게 초과함: ${elapsed}s — 무한/과도 대기 회귀"
  fi
}

test_teardown_gives_up_gracefully_when_rm_never_succeeds() {
  local victim fake_rm_dir
  victim=$(mktemp -d "/tmp/dod-test-teardown-XXXXXX")
  touch "$victim/file.txt"

  # 상한 회수(20)보다 많은 실패를 강제 — teardown 이 영원히 재시도하지
  # 않고 상한 내에서 (실패를 삼키고) 리턴하는지 확인한다. 판정에
  # 타이밍을 쓰지 않는다 — 상한 도달 후 리턴했는지만 확인.
  fake_rm_dir=$(_with_fake_rm_failing_n_times 9999)
  if [ -z "$fake_rm_dir" ]; then
    fail "_with_fake_rm_failing_n_times 자체가 실패 — 테스트 인프라 준비 불능"
    rm -rf "$victim" 2>/dev/null || true
    return
  fi

  (
    PATH="$fake_rm_dir:$PATH"
    SANDBOX="$victim"
    sandbox_teardown
  )
  local rc=$?

  rm -rf "$fake_rm_dir" 2>/dev/null || true
  # 실제 rm 으로 최종 정리 (fake 는 위 서브셸 종료로 이미 원상복구된 PATH 밖).
  rm -rf "$victim" 2>/dev/null || true

  [ "$rc" -eq 0 ] || fail "sandbox_teardown 이 rm 이 계속 실패해도 정상적으로(exit 0) 리턴해야 함(테스트 판정을 흔들면 안 됨) — rc=$rc"
}

main() {
  run_test test_teardown_retries_past_transient_rm_failures
  run_test test_teardown_gives_up_gracefully_when_rm_never_succeeds
  summary
}

main "$@"
