#!/bin/bash
# tests/hooks/bench-state-fast-path.sh — Cycle X4.C.4 SPIKE measurement
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md §8.5 (X4.C.4)
# plan ref:   docs/plans/2026-05-20-integrated-roadmap.md §4.3 (영역 C)
#
# Production-isolated microbenchmark — REIN_PROJECT_DIR_OVERRIDE sandbox 안에서
# 각 4 hook 의 legacy vs fast-path latency 를 N 회 반복 측정.
#
# Scenarios:
#   M1-legacy             pre-edit-dod-gate, state.json 부재, validator subprocess 실행
#   M1-fast               pre-edit-dod-gate, mode=source_edit + file in dirty_files → skip
#   M2a-legacy            post-edit-design-plan-coverage-rule, state 부재 → envelope inject
#   M2a-fast-answer       post-edit-design-plan-coverage-rule, mode=answer → exit early
#   M2a-source_edit       post-edit-design-plan-coverage-rule, mode=source_edit → 정상 inject (state read overhead 만 추가)
#   M2b-legacy            post-edit-routing-procedure-rule, state 부재 → envelope inject
#   M2b-fast-answer       post-edit-routing-procedure-rule, mode=answer → exit early
#   M2b-source_edit       post-edit-routing-procedure-rule, mode=source_edit → 정상 inject
#   M3-legacy             post-edit-spec-review-gate, marker 부재 → body rewrite
#   M3-fast               post-edit-spec-review-gate, marker 존재 + path match → touch only
#
# Caveats (report 에 그대로 옮김):
#   - 단일 OS (macOS Darwin, BSD coreutils). flock 부재 환경은 mkdir-mutex.
#     Linux/CI 재측정은 별 cycle (영역 D release gate hedging).
#   - 단일 release 의 cold-start cost (python 인터프리터 로드, hook source) 가
#     매 invocation 에 포함. 같은 비용이 legacy/fast-path 양측에 포함되므로
#     상대 비교는 유효 — 절대값은 cold path 가중치 포함.
#   - microbenchmark — 실제 세션 latency 는 hook chain + claude code dispatch +
#     모델 처리가 누적. 본 측정은 hook 단독 cost 의 lower bound.

set -u

REAL_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="$REAL_PROJECT_DIR/plugins/rein-core"

# 반복 횟수 — overrideable for quick smoke runs.
N="${BENCH_N:-50}"
WARMUP="${BENCH_WARMUP:-3}"

echo "============================================================"
echo "Cycle X4.C.4 SPIKE — state fast-path latency microbenchmark"
echo "============================================================"
echo "N=$N (median/min/max from N samples after $WARMUP warmup runs)"
echo "OS=$(uname -srm)  python=$(python3 --version 2>&1)"
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
echo

# ---------- sandbox helpers ----------

SANDBOX=""

mk_sandbox() {
  SANDBOX=$(mktemp -d "/tmp/bench-state-fastpath-XXXXXX")
}

rm_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# Interrupt/exit cleanup — leftover /tmp dirs are a hygiene issue across
# repeated cancelled runs. codex Round 1 Low advisory + Round 2 Low: signal
# handlers must exit with the canonical signal status so caller scripts can
# detect interruption (128 + signo).
_cleanup_on_exit() {
  rm_sandbox
}
trap _cleanup_on_exit EXIT
trap 'rm_sandbox; exit 130' INT
trap 'rm_sandbox; exit 143' TERM

seed_state() {
  local mode="$1"; shift
  mkdir -p "$SANDBOX/.rein"
  python3 - "$mode" "$SANDBOX/.rein/state.json" "$@" <<'PY'
import json, sys
mode = sys.argv[1]
out_path = sys.argv[2]
paths = list(sys.argv[3:])
state = {
    "schema_version": 1,
    "mode": mode,
    "updated_at": "2026-05-21T00:00:00Z",
    "dirty_files": [{"path": p, "kind": "source"} for p in paths],
    "last_drain_seq": 0,
}
with open(out_path, "w") as f:
    json.dump(state, f)
PY
}

# Build minimal valid DoD + spec + plan scaffold so pre-edit-dod-gate legacy
# path runs through validator (rather than failing on missing scaffold which
# would short-circuit the cost we want to measure).
seed_dod_scaffold() {
  mkdir -p "$SANDBOX/trail/dod" "$SANDBOX/trail/inbox" "$SANDBOX/scripts" \
           "$SANDBOX/docs/plans" "$SANDBOX/docs/specs"
  cat > "$SANDBOX/scripts/foo.py" <<'PY'
print("hello")
PY
  cat > "$SANDBOX/trail/dod/dod-2026-05-21-bench.md" <<'EOF'
# DoD
- 날짜: 2026-05-21
## 범위 연결
plan ref: docs/plans/2026-05-21-bench.md
work unit: Phase 1
covers: [A1]
## 라우팅 추천
```yaml
agent: rein:feature-builder
skills: []
mcps: []
approved_by_user: true
```
EOF
  cat > "$SANDBOX/docs/specs/2026-05-21-bench.md" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  cat > "$SANDBOX/docs/plans/2026-05-21-bench.md" <<'EOF'
## Design 범위 커버리지 매트릭스
> design ref: docs/specs/2026-05-21-bench.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|-----------|
| A1 | implemented | Phase 1 |

## Phase 1
covers: [A1]
EOF
}

# ---------- timing helper ----------
#
# Each scenario is a self-contained bash block. We invoke it N+WARMUP times
# in a subshell; the python timer measures per-iteration wall clock. We
# capture the full latency list and emit median / min / max / mean.

bench_scenario() {
  local label="$1"
  local setup_fn="$2"   # sandbox + state seeding
  local invoke_fn="$3"  # hook invocation (must read $SANDBOX, $PLUGIN_ROOT)
  local expected_signal="${4:-}"  # codex Round 1 Medium fix — postcondition check.
                                  # one of: "fast-path", "no-envelope", "envelope",
                                  # "marker-created", "marker-touched", "" (skip)
  local samples=()
  local rc_failures=0
  local signal_failures=0
  local i

  # Each iteration freshly rebuilds the sandbox so we measure cold-cache cost
  # per invocation — closer to what the real hook sees (one Edit at a time).
  # codex Round 1 Medium fix: reset INVOKE_* per iteration so a setup failure
  # cannot leak the previous scenario's hook/file values.
  for ((i = 0; i < N + WARMUP; i++)); do
    INVOKE_HOOK=""
    INVOKE_FILE=""
    mk_sandbox
    "$setup_fn"
    if [ -z "$INVOKE_HOOK" ] || [ -z "$INVOKE_FILE" ]; then
      echo "  [$label] setup failure — INVOKE_HOOK/INVOKE_FILE unset after $setup_fn (iter=$i)" >&2
      rm_sandbox
      continue
    fi
    # codex Round 1+2 Medium fix + Round 3 Low comment fix: capture rc + stdout
    # + stderr + marker snapshot (pre/post) so we can reject samples where the
    # hook failed (exit != 0) and validate scenario-specific postconditions:
    #   - fast-path: state.fast-path NOTICE on stderr
    #   - no-envelope: stdout has no hookSpecificOutput  (cache fallback note: tool_use_id="bench" fails the toolu_ regex → hook falls back to stdout, so stdout absence is sufficient evidence of skip)
    #   - envelope: stdout has hookSpecificOutput
    #   - marker-created: marker absent before invoke + present after (sandbox 가
    #                     매 iteration 새 디렉토리이므로 "present after" 만으로
    #                     create 의미는 충족. marker path/content identity 검증은
    #                     본 benchmark 의 scope 아님 — `tests/hooks/test-state-fast-path-skip.sh` T4 가 별도로 cover)
    #   - marker-touched: marker present before + after, content unchanged, mtime advanced
    local result
    result=$(python3 -c '
import os, subprocess, sys, time, json, glob, hashlib

sandbox = sys.argv[1]
plugin_root = sys.argv[2]
hook = sys.argv[3]
file_path = sys.argv[4]

# Pre-invoke marker snapshot — directory may not exist on legacy scenarios.
marker_dir = os.path.join(sandbox, "trail", "dod", ".spec-reviews")
def snap_marker():
    if not os.path.isdir(marker_dir):
        return (None, None, None)  # (path, mtime, content_hash)
    files = sorted(glob.glob(os.path.join(marker_dir, "*.pending")))
    if not files:
        return (None, None, None)
    p = files[0]
    try:
        mtime = os.path.getmtime(p)
        with open(p) as f:
            data = f.read()
        return (p, mtime, hashlib.sha256(data.encode()).hexdigest())
    except OSError:
        return (None, None, None)

pre_path, pre_mtime, pre_hash = snap_marker()

env = os.environ.copy()
env["CLAUDE_PLUGIN_ROOT"] = plugin_root
env["REIN_PROJECT_DIR_OVERRIDE"] = sandbox
payload = json.dumps({"tool_input": {"file_path": file_path}, "tool_use_id": "bench"})

t0 = time.perf_counter()
r = subprocess.run(
    ["bash", os.path.join(plugin_root, "hooks", hook)],
    input=payload, env=env,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    check=False, text=True,
)
t1 = time.perf_counter()
elapsed_ms = (t1 - t0) * 1000

post_path, post_mtime, post_hash = snap_marker()

stdout = r.stdout or ""
stderr = r.stderr or ""
has_envelope = "1" if "hookSpecificOutput" in stdout else "0"
has_notice = "1" if "state.fast-path" in stderr else "0"
marker_existed_before = "1" if pre_path is not None else "0"
marker_exists_after = "1" if post_path is not None else "0"
# content unchanged: both present + same hash
marker_content_unchanged = "1" if (pre_hash is not None and pre_hash == post_hash) else "0"
# mtime advanced: both present + post > pre
if pre_mtime is not None and post_mtime is not None and post_mtime > pre_mtime:
    marker_mtime_advanced = "1"
else:
    marker_mtime_advanced = "0"

# Tab-separated for bash consumption.
print(f"{elapsed_ms:.3f}\t{r.returncode}\t{has_envelope}\t{has_notice}\t{marker_existed_before}\t{marker_exists_after}\t{marker_content_unchanged}\t{marker_mtime_advanced}")
' "$SANDBOX" "$PLUGIN_ROOT" "$INVOKE_HOOK" "$INVOKE_FILE")
    local elapsed_ms rc has_envelope has_notice m_before m_after m_unchanged m_advanced
    IFS=$'\t' read -r elapsed_ms rc has_envelope has_notice m_before m_after m_unchanged m_advanced <<<"$result"
    if [ "${rc:-}" != "0" ]; then
      rc_failures=$((rc_failures + 1))
      rm_sandbox
      continue
    fi
    # Validate expected postcondition signal for non-warmup iterations.
    if [ "$i" -ge "$WARMUP" ]; then
      local signal_ok=1
      case "$expected_signal" in
        fast-path)       [ "$has_notice" = "1" ] || signal_ok=0 ;;
        no-envelope)     [ "$has_envelope" = "0" ] || signal_ok=0 ;;
        envelope)        [ "$has_envelope" = "1" ] || signal_ok=0 ;;
        marker-created)
          # absent before + present after.
          { [ "$m_before" = "0" ] && [ "$m_after" = "1" ]; } || signal_ok=0
          ;;
        marker-touched)
          # present before + after, content unchanged, mtime advanced.
          { [ "$m_before" = "1" ] && [ "$m_after" = "1" ] \
            && [ "$m_unchanged" = "1" ] && [ "$m_advanced" = "1" ]; } || signal_ok=0
          ;;
        "") ;;  # no signal check
      esac
      if [ "$signal_ok" = "0" ]; then
        signal_failures=$((signal_failures + 1))
      fi
      samples+=("$elapsed_ms")
    fi
    rm_sandbox
  done

  if [ "$rc_failures" -gt 0 ]; then
    echo "  [$label] WARNING: ${rc_failures}/$((N + WARMUP)) iterations had non-zero hook exit — samples dropped" >&2
  fi
  if [ "$signal_failures" -gt 0 ]; then
    echo "  [$label] WARNING: ${signal_failures}/${N} sampled iterations failed signal check (expected=$expected_signal)" >&2
  fi
  if [ "${#samples[@]}" -eq 0 ]; then
    echo "  [$label] FAIL: zero usable samples — scenario rejected" >&2
    return 1
  fi

  python3 -c '
import sys, statistics
label = sys.argv[1]
xs = [float(x) for x in sys.argv[2:]]
xs.sort()
n = len(xs)
print(f"  {label:32s}  n={n}  median={statistics.median(xs):7.2f}ms  min={min(xs):7.2f}ms  max={max(xs):7.2f}ms  mean={statistics.mean(xs):7.2f}ms")
' "$label" "${samples[@]}"
}

# ---------- scenarios ----------

# M1-legacy: state 부재, valid DoD/spec/plan, FILE_PATH = scripts/foo.py
setup_m1_legacy() {
  seed_dod_scaffold
  INVOKE_HOOK="pre-edit-dod-gate.sh"
  INVOKE_FILE="$SANDBOX/scripts/foo.py"
}

# M1-fast: state mode=source_edit + dirty_files=[FILE]
setup_m1_fast() {
  seed_dod_scaffold
  seed_state "source_edit" "$SANDBOX/scripts/foo.py"
  INVOKE_HOOK="pre-edit-dod-gate.sh"
  INVOKE_FILE="$SANDBOX/scripts/foo.py"
}

# M2a-legacy: post-edit-design-plan-coverage-rule, state 부재, file = docs/specs/x.md
setup_m2a_legacy() {
  mkdir -p "$SANDBOX/docs/specs"
  printf "# spec\n" > "$SANDBOX/docs/specs/x.md"
  INVOKE_HOOK="post-edit-design-plan-coverage-rule.sh"
  INVOKE_FILE="$SANDBOX/docs/specs/x.md"
}

# M2a-fast-answer: state mode=answer → exit early
setup_m2a_fast_answer() {
  mkdir -p "$SANDBOX/docs/specs"
  printf "# spec\n" > "$SANDBOX/docs/specs/x.md"
  seed_state "answer"
  INVOKE_HOOK="post-edit-design-plan-coverage-rule.sh"
  INVOKE_FILE="$SANDBOX/docs/specs/x.md"
}

# M2a-source_edit: state mode=source_edit (fast-path skip 안 됨, state read overhead만 추가)
setup_m2a_source_edit() {
  mkdir -p "$SANDBOX/docs/specs"
  printf "# spec\n" > "$SANDBOX/docs/specs/x.md"
  seed_state "source_edit" "$SANDBOX/docs/specs/x.md"
  INVOKE_HOOK="post-edit-design-plan-coverage-rule.sh"
  INVOKE_FILE="$SANDBOX/docs/specs/x.md"
}

# M2b-legacy
setup_m2b_legacy() {
  mkdir -p "$SANDBOX/trail/dod"
  printf "# DoD\n" > "$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
  INVOKE_HOOK="post-edit-routing-procedure-rule.sh"
  INVOKE_FILE="$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
}

setup_m2b_fast_answer() {
  mkdir -p "$SANDBOX/trail/dod"
  printf "# DoD\n" > "$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
  seed_state "answer"
  INVOKE_HOOK="post-edit-routing-procedure-rule.sh"
  INVOKE_FILE="$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
}

setup_m2b_source_edit() {
  mkdir -p "$SANDBOX/trail/dod"
  printf "# DoD\n" > "$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
  seed_state "source_edit" "$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
  INVOKE_HOOK="post-edit-routing-procedure-rule.sh"
  INVOKE_FILE="$SANDBOX/trail/dod/dod-2026-05-21-bench.md"
}

# M3-legacy: spec marker 부재 → body rewrite
setup_m3_legacy() {
  mkdir -p "$SANDBOX/docs/specs"
  cat > "$SANDBOX/docs/specs/dummy.md" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  INVOKE_HOOK="post-edit-spec-review-gate.sh"
  INVOKE_FILE="$SANDBOX/docs/specs/dummy.md"
}

# M3-fast: marker 이미 존재 (path match) → touch only (mtime 갱신, body 불변).
# setup 에서 marker 를 pre-create 한 뒤 mtime 을 epoch 1 (1970) 로 backwards
# 설정해 post-invoke mtime > pre-mtime 검증을 deterministic 하게 만든다.
setup_m3_fast() {
  mkdir -p "$SANDBOX/docs/specs" "$SANDBOX/trail/dod/.spec-reviews"
  cat > "$SANDBOX/docs/specs/dummy.md" <<'EOF'
## Scope Items
| ID | 설명 |
|----|------|
| A1 | dummy |
EOF
  # spec-review-gate 를 한 번 invoke 해서 정확한 hash 의 marker 를 만든 뒤 mtime backwards.
  python3 -c '
import os, subprocess, sys, json, glob
sandbox = sys.argv[1]; plugin_root = sys.argv[2]; file_path = sys.argv[3]
env = os.environ.copy()
env["CLAUDE_PLUGIN_ROOT"] = plugin_root
env["REIN_PROJECT_DIR_OVERRIDE"] = sandbox
payload = json.dumps({"tool_input": {"file_path": file_path}})
subprocess.run(
    ["bash", os.path.join(plugin_root, "hooks", "post-edit-spec-review-gate.sh")],
    input=payload, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    check=False, text=True,
)
# mtime을 epoch 1로 돌려 post-invoke mtime이 반드시 증가하도록 함
for p in glob.glob(os.path.join(sandbox, "trail", "dod", ".spec-reviews", "*.pending")):
    os.utime(p, (1, 1))
' "$SANDBOX" "$PLUGIN_ROOT" "$SANDBOX/docs/specs/dummy.md"
  INVOKE_HOOK="post-edit-spec-review-gate.sh"
  INVOKE_FILE="$SANDBOX/docs/specs/dummy.md"
}

# ---------- run ----------

# expected_signal 4th arg (codex Round 1+2 Medium fix): rejects samples where
# the hook's externally-observable behaviour doesn't match the scenario's
# hypothesis. cache fallback note: tool_use_id="bench" fails the toolu_ regex
# in resolver_cache_sanitize_id, so output_cache_write returns rc=1 and the
# hook falls back to direct stdout emit — stdout has_envelope check is
# definitive for M2 scenarios.
echo "=== M1: pre-edit-dod-gate ==="
bench_scenario "M1-legacy"          setup_m1_legacy          _unused  ""
bench_scenario "M1-fast"            setup_m1_fast            _unused  "fast-path"
echo
echo "=== M2a: post-edit-design-plan-coverage-rule ==="
bench_scenario "M2a-legacy"         setup_m2a_legacy         _unused  "envelope"
bench_scenario "M2a-fast-answer"    setup_m2a_fast_answer    _unused  "no-envelope"
bench_scenario "M2a-source_edit"    setup_m2a_source_edit    _unused  "envelope"
echo
echo "=== M2b: post-edit-routing-procedure-rule ==="
bench_scenario "M2b-legacy"         setup_m2b_legacy         _unused  "envelope"
bench_scenario "M2b-fast-answer"    setup_m2b_fast_answer    _unused  "no-envelope"
bench_scenario "M2b-source_edit"    setup_m2b_source_edit    _unused  "envelope"
echo
echo "=== M3: post-edit-spec-review-gate ==="
bench_scenario "M3-legacy"          setup_m3_legacy          _unused  "marker-created"
bench_scenario "M3-fast"            setup_m3_fast            _unused  "marker-touched"
echo
echo "============================================================"
echo "측정 완료. 본 출력을 docs/reports/2026-05-21-area-c-state-machine-spike.md 에 첨부."
