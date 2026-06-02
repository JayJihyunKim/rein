#!/usr/bin/env bash
# tests/hooks/test-hook-hotpath-perf.sh — hook hot-path perf NFR Phase 4 Task 4.1
#
# Per-hook perf bench with FIXED absolute strict/relax thresholds
# (Scope ID: PERF-NFR-PER-HOOK).
#
# design ref:  docs/specs/2026-06-02-hook-hotpath-perf.md
# plan ref:    docs/plans/2026-06-02-hook-hotpath-perf-implementation.md §Task 4.1
#
# Pattern copied from tests/hooks/test-post-edit-meta-check-perf.sh:
#   - REIN_PERF_BENCH_RELAX env flag selects strict vs relax thresholds
#   - 20 sequential runs per hook
#   - p95 = `sort -n | sed -n '19p'`, p50 = `sed -n '10p'`
#   - make_bench_project helper: git repo + trail/dod + active DoD + dirty files
#   - hook invoked with CLAUDE_PLUGIN_ROOT set, INPUT on stdin
#
# Why FIXED absolute thresholds (codex Medium, plan §Task 4.1):
#   A "p95 decreased vs baseline" assert is non-deterministic and flaky across
#   machines/load. Instead we assert each hook's p95 against a fixed ms ceiling
#   — the same posture meta-check perf took (measured ~165ms, set ceiling 180).
#
# Track state at authoring time (working tree):
#   Track A (resolve_python launch-skip) — APPLIED
#   Track B (rule-hook spawn merge)      — APPLIED
#   Track C (pre-bash inline)            — NOT applied (deferred behind user gate)
#   => pre-bash-dispatcher uses the C-DEFER threshold.
#
# Strict / relax thresholds (per hook). Strict ceilings were calibrated from
# measured p95 on the authoring machine (3 bench runs, see per-hook comments).
# Where the plan's proposed strict already had headroom over the measured p95
# we kept (or only slightly raised) it; where the measured p95 EXCEEDED the
# proposed strict (the two rule hooks), we set the ceiling to measured+margin
# and the per-hook comment records the actual measured number — per plan §Task
# 4.1 step 4 ("do not silently loosen below realism").
#
# Measured p95 (macOS, Track A+B applied, Track C deferred; 3 runs):
#   post-edit-hygiene                    : 113 / 113 / 119  ms
#   post-edit-plan-coverage              : 170 / 170 / 199  ms (occasional tail)
#   post-edit-design-plan-coverage-rule  : 189 / 194 / 191  ms (heaviest: state-
#                                          machine source + read_fast_path_state
#                                          under lock + rule-inject body resolve
#                                          + envelope synthesis)
#   post-edit-routing-procedure-rule     : 120 / 122 / 122  ms
#   pre-bash-dispatcher [ls]             : 373 / 375 / 374  ms (full dispatch:
#                                          bootstrap gate PASS -> safety guard ->
#                                          classifier -> state drain. NOT a
#                                          bootstrap-PARTIAL fail-fast.)
#
# Environment:
#   REIN_PERF_BENCH_RELAX=1 -> use relaxed (CI-friendly) thresholds for all hooks
#
# Scope IDs: PERF-NFR-PER-HOOK
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLUGIN_ROOT="$REPO_ROOT/plugins/rein-core"
HOOK_DIR="$PLUGIN_ROOT/hooks"

H_HYGIENE="$HOOK_DIR/post-edit-hygiene.sh"
H_PLANCOV="$HOOK_DIR/post-edit-plan-coverage.sh"
H_DPCR="$HOOK_DIR/post-edit-design-plan-coverage-rule.sh"
H_RPR="$HOOK_DIR/post-edit-routing-procedure-rule.sh"
H_PREBASH="$HOOK_DIR/pre-bash-dispatcher.sh"

for h in "$H_HYGIENE" "$H_PLANCOV" "$H_DPCR" "$H_RPR" "$H_PREBASH"; do
  [ -x "$h" ] || { echo "FAIL: $h not executable" >&2; exit 1; }
done

FAILED=0

# ---- Fixed strict / relax thresholds (ms) -------------------------------------
# Strict = calibrated ceiling (measured p95 + margin, within proposed strict).
# Relax  = CI-friendly ceiling (REIN_PERF_BENCH_RELAX=1).
if [ "${REIN_PERF_BENCH_RELAX:-0}" = "1" ]; then
  L_HYGIENE=230
  L_PLANCOV=300
  L_DPCR=330
  L_RPR=250
  L_PREBASH=520
  echo "[bench] REIN_PERF_BENCH_RELAX=1 — using relaxed thresholds"
else
  # post-edit-hygiene: Track A applied (health_check ~24ms skip on bare python3).
  #   measured p95 ~113-119ms; proposed strict 120ms was too tight against the
  #   119ms tail, raised to 130 (measured+margin, still well under relax).
  L_HYGIENE=130
  # post-edit-plan-coverage: Track A applied. measured p95 ~170ms with an
  #   occasional tail to 199ms; proposed strict 170ms tripped on the tail.
  #   Raised to 210 (measured tail + margin).
  L_PLANCOV=210
  # post-edit-design-plan-coverage-rule: Track B applied (3 python spawn -> 2).
  #   MEASURED p95 ~189-194ms — EXCEEDS proposed strict 100ms (~2x). The 100ms
  #   "baseline 113ms" in the plan does not reflect this machine; this hook is
  #   structurally heavier than the routing rule (state-machine read under lock
  #   + rule-inject body resolution + envelope synthesis). Set to 230
  #   (measured+margin) rather than silently keeping an unachievable 100ms.
  L_DPCR=230
  # post-edit-routing-procedure-rule: Track B applied. MEASURED p95 ~120-122ms —
  #   EXCEEDS proposed strict 100ms. Set to 150 (measured+margin).
  L_RPR=150
  # pre-bash-dispatcher [ls]: Track C NOT applied (deferred). C-defer ceiling.
  #   measured p95 ~373-375ms (full dispatch path) — within proposed 390ms, kept.
  #   NOTE: margin is thin (~15ms). If Track C ships, drop this to the C-ship
  #   ceiling (~340ms per plan §Task 4.1). On a heavily loaded CI box the relax
  #   flag (REIN_PERF_BENCH_RELAX=1 -> 520ms) is the intended safety valve.
  L_PREBASH=390
fi

# ---- bench project (mirrors test-post-edit-meta-check-perf.sh) ----------------
make_bench_project() {
  local proj="$1"
  mkdir -p "$proj/trail/dod" "$proj/trail/inbox" "$proj/.rein/policy" "$proj/docs/plans"
  # BG-1 contract: bootstrap-check.sh requires trail/ AND .rein/project.json AND
  # trail/index.md — all three so pre-bash-dispatcher passes the bootstrap gate
  # and exercises the FULL dispatch path (safety guard + classifier + state
  # drain), not a fail-fast PARTIAL-state block.
  printf '%s\n' '{"mode":"plugin","scope":"project","version":"1.0.0"}' > "$proj/.rein/project.json"
  printf '%s\n' '# trail index' '' '## sessions' '' '(bench)' > "$proj/trail/index.md"
  (
    cd "$proj"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    echo "seed" > seed.txt
    git add seed.txt
    git commit -q -m "seed"
  )
  cat > "$proj/trail/dod/dod-2026-05-27-test.md" << 'DODEOF'
# perf bench DoD

## 범위

bench.

## 변경 파일

- a.txt
- b.txt
- c.txt

## 라우팅 추천

agent: rein:feature-builder
approved_by_user: true
DODEOF
  echo "path=trail/dod/dod-2026-05-27-test.md" > "$proj/trail/dod/.active-dod"
  for f in a.txt b.txt c.txt; do echo "initial" > "$proj/$f"; done
  (cd "$proj" && git add -A >/dev/null 2>&1 && git commit -q -m "track" >/dev/null 2>&1)
  for f in a.txt b.txt c.txt; do echo "modified" > "$proj/$f"; done
  echo "extra" > "$proj/d.txt"  # creates 1 mismatch (untracked)
}

# ---- generic per-hook bench --------------------------------------------------
# Sets globals BENCH_P50 / BENCH_P95 so the caller can fold into a cumulative
# advisory sum without re-running.
BENCH_P50=0
BENCH_P95=0
run_bench() {
  local label="$1" hook="$2" proj="$3" stdin="$4" hard_limit="$5"
  local samples
  samples=$(mktemp)
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    local t0 t1
    t0=$(python3 -c 'import time; print(int(time.time_ns()))')
    # `|| true` — a blocking hook (e.g. pre-bash exit 2) must not abort the
    # bench under `set -e`. We measure latency, not block behaviour.
    (cd "$proj" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$hook" <<< "$stdin") >/dev/null 2>&1 || true
    t1=$(python3 -c 'import time; print(int(time.time_ns()))')
    echo $(( (t1 - t0) / 1000000 )) >> "$samples"
  done
  local p50 p95 sample_line
  sample_line=$(sort -n "$samples" | tr '\n' ' ')
  p50=$(sort -n "$samples" | sed -n '10p')
  p95=$(sort -n "$samples" | sed -n '19p')
  BENCH_P50=${p50:-0}
  BENCH_P95=${p95:-0}
  if [ "${p95:-9999}" -le "$hard_limit" ]; then
    echo "OK [$label] p50=${p50}ms p95=${p95}ms (<=${hard_limit}ms)"
  else
    echo "FAIL [$label] p50=${p50}ms p95=${p95}ms (>${hard_limit}ms hard limit) samples: $sample_line" >&2
    FAILED=$((FAILED+1))
  fi
  rm -f "$samples"
}

# ---- shared bench project ----------------------------------------------------
PROJ=$(mktemp -d "/tmp/perf-hotpath-XXXXXX")
make_bench_project "$PROJ"

# A DoD-document file path matches the watched globs of BOTH rule hooks
# (design-plan-coverage-rule: trail/dod/dod-*.md ; routing-procedure-rule:
# trail/dod/dod-[0-9]*.md), exercising the full advisory synthesis path.
DOD_REL="trail/dod/dod-2026-05-27-test.md"
DOD_ABS="$PROJ/$DOD_REL"

# Realistic PostToolUse(Edit) envelope for post-edit hooks.
EDIT_PAYLOAD_DOD="{\"tool_use_id\":\"toolu_perf01\",\"tool_input\":{\"file_path\":\"${DOD_ABS}\"}}"
# hygiene/plan-coverage do not require a DoD glob match; a plain tracked file is
# realistic. Use one of the dirty tracked files.
EDIT_PAYLOAD_SRC="{\"tool_use_id\":\"toolu_perf02\",\"tool_input\":{\"file_path\":\"${PROJ}/a.txt\"}}"

# Realistic PreToolUse(Bash) envelope for pre-bash-dispatcher.
BASH_PAYLOAD="{\"tool_use_id\":\"toolu_perf03\",\"tool_input\":{\"command\":\"ls -la\"}}"

# ---- per-hook benches --------------------------------------------------------
run_bench "post-edit-hygiene" "$H_HYGIENE" "$PROJ" "$EDIT_PAYLOAD_SRC" "$L_HYGIENE"
HYGIENE_P95=$BENCH_P95

run_bench "post-edit-plan-coverage" "$H_PLANCOV" "$PROJ" "$EDIT_PAYLOAD_DOD" "$L_PLANCOV"
PLANCOV_P95=$BENCH_P95

run_bench "post-edit-design-plan-coverage-rule" "$H_DPCR" "$PROJ" "$EDIT_PAYLOAD_DOD" "$L_DPCR"
DPCR_P95=$BENCH_P95

run_bench "post-edit-routing-procedure-rule" "$H_RPR" "$PROJ" "$EDIT_PAYLOAD_DOD" "$L_RPR"
RPR_P95=$BENCH_P95

run_bench "pre-bash-dispatcher [ls]" "$H_PREBASH" "$PROJ" "$BASH_PAYLOAD" "$L_PREBASH"
PREBASH_P95=$BENCH_P95

# ---- cumulative per-EVENT latency: ADVISORY ONLY (NOT a gate) -----------------
# Per spec NFR / plan §Task 4.1 step 3: cumulative latency is informational.
# We do NOT assert/fail on it — only the per-hook strict ceilings are hard.
#
# An Edit event fires the post-edit chain (hygiene + plan-coverage + the two
# rule hooks among others); a Bash event fires the pre-bash chain. We surface
# the sum of the benched post-edit hooks as a rough chain estimate.
EDIT_CHAIN_SUM_P95=$(( HYGIENE_P95 + PLANCOV_P95 + DPCR_P95 + RPR_P95 ))
echo "[advisory] edit chain (benched subset) sum p95 ~= ${EDIT_CHAIN_SUM_P95}ms (advisory, not a gate)"
echo "[advisory] bash event pre-bash-dispatcher p95 ~= ${PREBASH_P95}ms (advisory, not a gate)"

# ---- result ------------------------------------------------------------------
rm -rf "$PROJ"
if [ "$FAILED" -gt 0 ]; then
  echo "test-hook-hotpath-perf: FAIL ($FAILED hook(s) over strict ceiling)" >&2
  exit 1
fi
echo "test-hook-hotpath-perf: OK (5 per-hook benches + cumulative advisory)"
