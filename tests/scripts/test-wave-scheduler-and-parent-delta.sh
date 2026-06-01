#!/usr/bin/env bash
# tests/scripts/test-wave-scheduler-and-parent-delta.sh
#
# Phase 4 / Task 4.1 — behavioral (product-surface) regression for the two
# pieces whose determinism the rest of the wave-parallel design relies on:
#
#   Part 1 — Deterministic wave scheduler.
#     Calls the REAL emitter (`rein-validate-coverage-matrix.py schedule`),
#     the SSOT for wave ordering — the test does NOT re-implement the rule.
#     Asserts exact `step N:` lines for a mixed ready set and proves a
#     `mutating` task runs SOLO even when an `edit_only` task is ready
#     alongside it (earliest-plan-order mutating alone, then the edit_only).
#
#   Part 2 — Parent delta validation (subset check against the wave's scope
#     union). Reproduces the SAME command form the skill prescribes — see
#     plugins/rein-core/skills/parallel-execute/SKILL.md `## 부모 통합`:
#       git status --porcelain=v1 -z -uall --ignored=no
#     normalized to repo-relative literal file paths, then `delta ⊆ scope-union`.
#     (a) all changes within scope → PASS; (b) a change OUTSIDE scope, incl. a
#     file under a NEW untracked directory (proving `-uall` defeats untracked-
#     directory collapse hiding it) → REJECT.
#
# Scope ID: REGRESSION-TESTS-V2
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

VALIDATOR="scripts/rein-validate-coverage-matrix.py"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# Scratch root for all fixtures (plan files + temp git repo).
SCRATCH=$(mktemp -d -t wave-sched.XXXXXX)
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

# Shared minimal design fixture so the coverage matrix in each plan validates.
DESIGN_FIXTURE="$SCRATCH/design.md"
cat > "$DESIGN_FIXTURE" << 'EOF'
---
scope-id-version: v2
---

# Fixture Design

## Scope Items

| ID | 설명 |
|----|------|
| FX1-fixture-scope-id-for-wave-scheduler-test | fixture scope used by scheduler cases |
EOF

# write_plan <out> <exec_strategy_block> — wrap a `## 실행 전략` block in a
# coverage-valid plan (mirrors test-pln1-execution-strategy.sh's helper).
write_plan() {
  local out="$1"
  local exec_strategy_block="$2"
  cat > "$out" << PLAN
# Fixture Plan

## Design 범위 커버리지 매트릭스

> design ref: $DESIGN_FIXTURE

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| FX1-fixture-scope-id-for-wave-scheduler-test | implemented | Phase 1 |

$exec_strategy_block

## Phase 1
covers: [FX1-fixture-scope-id-for-wave-scheduler-test]

### Task 1.1
covers: [FX1-fixture-scope-id-for-wave-scheduler-test]
PLAN
}

# assert_schedule <label> <plan_file> <expected_full_stdout>
# Calls the REAL emitter and compares its complete stdout, exit 0 expected.
assert_schedule() {
  local label="$1" plan_file="$2" expected="$3"
  local actual exit_code
  actual=$(python3 "$VALIDATOR" schedule "$plan_file" 2>/dev/null)
  exit_code=$?
  if [ "$exit_code" = "0" ] && [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (exit=$exit_code)"
    {
      echo "    --- expected ---"
      printf '%s\n' "$expected" | sed 's/^/    /'
      echo "    --- actual ---"
      printf '%s\n' "$actual" | sed 's/^/    /'
    } >&2
  fi
}

echo "=== test-wave-scheduler-and-parent-delta ==="
echo "--- Part 1: deterministic scheduler (product surface = schedule emitter) ---"

# Case 1: mixed ready set — A (edit_only, no deps), B (edit_only, no deps,
# scope disjoint from A), C (mutating, depends_on [A, B]).
# Expect: step 1 = both ready edit_only in one wave (plan order "A B");
#         step 2 = C alone (mutating, after its deps).
PLAN_MIXED="$SCRATCH/plan-mixed.md"
write_plan "$PLAN_MIXED" "## 실행 전략

tasks:
  - id: A
    mode: edit_only
    scope:
      - plugins/rein-core/rules/a.md
  - id: B
    mode: edit_only
    scope:
      - plugins/rein-core/rules/b.md
  - id: C
    depends_on: [A, B]
    mode: mutating
    scope:
      - scripts/gen.py"
assert_schedule "case 1: A B parallel wave, then C mutating solo" "$PLAN_MIXED" \
"step 1: A B
step 2: C"

# Case 2: mutating runs SOLO even when an edit_only is ready alongside it.
# M (mutating, no deps) + E (edit_only, no deps) — both ready at step 1.
# Expect: step 1 = M alone (earliest-plan-order mutating, solo);
#         step 2 = E (the edit_only, after the mutating step).
PLAN_SOLO="$SCRATCH/plan-solo.md"
write_plan "$PLAN_SOLO" "## 실행 전략

tasks:
  - id: M
    mode: mutating
    scope:
      - scripts/gen.py
  - id: E
    mode: edit_only
    scope:
      - plugins/rein-core/rules/e.md"
assert_schedule "case 2: mutating M solo despite ready edit_only E, then E" "$PLAN_SOLO" \
"step 1: M
step 2: E"

# Case 3: absent `## 실행 전략` → empty output + exit 0 (sequential, no regression).
PLAN_ABSENT="$SCRATCH/plan-absent.md"
write_plan "$PLAN_ABSENT" ""
absent_out=$(python3 "$VALIDATOR" schedule "$PLAN_ABSENT" 2>/dev/null)
absent_rc=$?
if [ "$absent_rc" = "0" ] && [ -z "$absent_out" ]; then
  pass "case 3: absent exec strategy → empty output + exit 0"
else
  fail "case 3: absent exec strategy (exit=$absent_rc, out='$absent_out')"
fi

echo "--- Part 2: parent delta validation (subset of wave scope union) ---"

# --- delta-vs-scope helper ----------------------------------------------------
# Mirrors plugins/rein-core/skills/parallel-execute/SKILL.md `## 부모 통합`:
# the parent computes the since-start delta with the EXACT command form
#     git status --porcelain=v1 -z -uall --ignored=no
# (`-uall` lists each untracked file individually so a new untracked directory
# cannot collapse and hide an out-of-scope file), normalizes to repo-relative
# literal file paths, and checks `delta ⊆ union(scope)`. Out-of-scope → reject.
#
# delta_in_scope <repo_dir> <scope_path...>
#   exit 0 → all changed paths are within the declared scope union (PASS)
#   exit 1 → at least one changed path is OUTSIDE the scope union (REJECT)
delta_in_scope() {
  local repo="$1"; shift
  local scope=( "$@" )            # declared scope union (exact literal paths)
  local rc=0

  # Normalize: porcelain -z records are NUL-separated; each record is
  # "XY <path>". A renamed record (R) carries two NUL-separated paths; this
  # fixture exercises only add/modify/untracked, so the leading "XY " strip
  # per record yields one repo-relative literal path.
  #
  # NOTE: the NUL-delimited stream is piped DIRECTLY into `read -d ''` — it is
  # never captured into a `$(...)` string, because command substitution strips
  # NUL bytes (Bash), which would coalesce all records into one unsplittable
  # blob and silently defeat the per-path subset check.
  local rec path s in_scope
  # Identical command form to SKILL.md `## 부모 통합` step 2.
  while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    path="${rec:3}"               # strip 2-char status + 1 space
    # Exact per-path equality against each scope element. NOT substring /
    # space-delimited membership: a Git path may contain spaces (e.g.
    # "dir/a b"), and substring membership would false-green an out-of-scope
    # path that happens to appear as a token inside a scope string.
    in_scope=0
    for s in "${scope[@]}"; do
      if [ "$path" = "$s" ]; then in_scope=1; break; fi
    done
    [ "$in_scope" -eq 1 ] || rc=1   # outside declared scope → reject
  done < <(cd "$repo" && git status --porcelain=v1 -z -uall --ignored=no)
  return $rc
}

# Build an isolated temp git repo (absolute path, local identity, trap-cleaned).
REPO="$SCRATCH/repo"
mkdir -p "$REPO/src" "$REPO/docs"
(
  cd "$REPO"
  git init -q
  git config user.email "wave-test@example.invalid"
  git config user.name "Wave Test"
  printf 'base\n' > src/a.txt
  printf 'base\n' > docs/b.md
  git add -A
  git -c commit.gpgsign=false commit -q -m "base"
) || { echo "FAIL: could not initialize temp git repo" >&2; exit 1; }

# Declared wave scope union for both cases.
SCOPE_A="src/a.txt"
SCOPE_B="docs/b.md"

# Case (a): changes ONLY within the declared scope set → delta ⊆ scope → PASS.
(
  cd "$REPO"
  printf 'edit-in-scope\n' >> src/a.txt   # modify tracked, in scope
  printf 'edit-in-scope\n' >> docs/b.md    # modify tracked, in scope
)
if delta_in_scope "$REPO" "$SCOPE_A" "$SCOPE_B"; then
  pass "case (a): all changes within declared scope → subset check accepts"
else
  fail "case (a): in-scope changes were incorrectly rejected"
fi

# Reset working tree to clean before the negative case so (a)'s edits don't
# leak into (b)'s delta.
(cd "$REPO" && git checkout -q -- . )

# Case (b): a change OUTSIDE scope, including a file under a NEW untracked
# directory (proves `-uall` lists it individually rather than collapsing the
# directory and hiding the out-of-scope file) → subset check REJECTS.
(
  cd "$REPO"
  printf 'edit-in-scope\n' >> src/a.txt          # in scope (still present)
  mkdir -p newpkg/sub                            # brand-new untracked dir
  printf 'out-of-scope\n' > newpkg/sub/leak.txt  # under the new dir → OUTSIDE scope
)
if delta_in_scope "$REPO" "$SCOPE_A" "$SCOPE_B"; then
  fail "case (b): out-of-scope untracked-dir file was NOT rejected (subset check too loose)"
else
  pass "case (b): out-of-scope file under new untracked dir → subset check rejects"
fi

# Case (b'): sanity — confirm the porcelain command actually surfaced the
# nested untracked file as its own path (not a collapsed `newpkg/` directory).
leak_listed=$(
  cd "$REPO"
  git status --porcelain=v1 -z -uall --ignored=no \
    | tr '\0' '\n' \
    | grep -c 'newpkg/sub/leak.txt'
)
if [ "$leak_listed" -ge 1 ]; then
  pass "case (b'): -uall surfaced nested untracked file individually (no dir collapse)"
else
  fail "case (b'): -uall did NOT surface newpkg/sub/leak.txt (count=$leak_listed)"
fi

# Reset before the spaced-path case.
(cd "$REPO" && git checkout -q -- . && git clean -fdq)

# Case (c): path-with-spaces soundness (guards the substring-membership defect).
# A Git path may contain spaces. Declared scope = "src/a b.txt"; an out-of-scope
# file "b.txt" is a substring token of that scope string. Exact per-path
# equality must REJECT it — space-delimited substring membership would have
# false-greened it (the very class of bug this suite exists to catch).
SCOPE_SPACE="src/a b.txt"
(
  cd "$REPO"
  printf 'spaced\n' > "src/a b.txt"   # in-scope spaced path (untracked)
  printf 'leak\n'   > "b.txt"         # out-of-scope; token of the scope string
)
# (c1) out-of-scope "b.txt" present alongside the in-scope spaced path → REJECT.
if delta_in_scope "$REPO" "$SCOPE_SPACE"; then
  fail "case (c1): out-of-scope 'b.txt' false-greened (substring membership leak)"
else
  pass "case (c1): spaced-path scope — out-of-scope 'b.txt' correctly rejected"
fi

# (c2) reset, then change ONLY the in-scope spaced path → ACCEPT (exact match
# handles spaces correctly in the positive direction too).
(cd "$REPO" && git checkout -q -- . && git clean -fdq)
(cd "$REPO" && printf 'spaced\n' > "src/a b.txt")
if delta_in_scope "$REPO" "$SCOPE_SPACE"; then
  pass "case (c2): in-scope spaced path ('src/a b.txt') correctly accepted"
else
  fail "case (c2): in-scope spaced path was incorrectly rejected"
fi

echo ""
echo "======================================"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
