#!/usr/bin/env bash
# tests/hooks/test-post-edit-meta-check.sh — G3 Phase 4 Task 4.1
#
# Functional + behavioral test for plugins/rein-core/hooks/post-edit-meta-check.sh.
#
# Each fixture creates an isolated PROJECT_DIR (git repo + DoD + policy + .active-dod
# marker), then invokes the hook with a synthetic PostToolUse envelope on stdin
# and asserts (action, stdout, stderr, inbox jsonl).
#
# Fixture coverage (spec §5):
#   1. FASTPATH                 — state.json effective_mode=answer → 0 envelope + 0 inbox
#   2. NO-ACTIVE-DOD            — marker missing → silent skip
#   3. POLICY-FALSE-YAML        — .rein/policy/meta-check.yaml enabled:false → skip
#   4. POLICY-FALSE-DOD         — DoD 의 meta_check: false → skip
#   5. POLICY-AUTO-NO-HINT      — auto + DoD '## 변경 파일' 부재 → NOTICE + silent skip
#   6. POLICY-TRUE-NO-HINT      — true + 부재 → H=∅, 전체 diff mismatch + inbox
#   7. DETECT-POSITIVE          — H 보다 D 큰 set → advisory + inbox count>0
#   8. DETECT-EQUALITY          — D == H → no advisory, inbox count=0
#   9. DETECT-SUBSET            — D ⊂ H → no advisory, inbox count=0
#  10. ADVISORY-TOP5-CAP        — mismatch 6개 → '... (+1 more)' cap
#  11. INBOX-APPEND-TWICE       — 2회 호출 → jsonl 2 line
#  12. INBOX-ZERO-RECORDED      — D==H 도 inbox 1 line
#  13. PERF                     — 5회 평균 ≤ 250ms (lightweight smoke)
#
# Scope IDs: G3-MC-FASTPATH G3-MC-NO-ACTIVE-DOD G3-MC-POLICY
#            G3-MC-DOD-MISSING-HINT G3-MC-DETECT G3-MC-ADVISORY G3-MC-INBOX
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$REPO_ROOT/plugins/rein-core/hooks/post-edit-meta-check.sh"
PLUGIN_ROOT="$REPO_ROOT/plugins/rein-core"

[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

FAILED=0

# ---------- helpers --------------------------------------------------------

make_project() {
  local proj="$1"
  mkdir -p "$proj/trail/dod" "$proj/trail/inbox" "$proj/.rein/policy"
  (
    cd "$proj"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    echo "seed" > seed.txt
    git add seed.txt
    git commit -q -m "seed"
  )
}

write_dod_with_hint() {
  local proj="$1"
  local hint_files="$2"   # newline-separated bullet contents
  cat > "$proj/trail/dod/dod-2026-05-27-test.md" << DODEOF
# G3 meta-check test DoD

## 범위

test.

## 변경 파일

$hint_files

## 라우팅 추천

agent: rein:feature-builder
approved_by_user: true
DODEOF
  echo "path=trail/dod/dod-2026-05-27-test.md" > "$proj/trail/dod/.active-dod"
}

write_dod_without_hint() {
  local proj="$1"
  cat > "$proj/trail/dod/dod-2026-05-27-test.md" << 'DODEOF'
# G3 meta-check test DoD (no changed-files section)

## 범위

test.

## 라우팅 추천

agent: rein:feature-builder
approved_by_user: true
DODEOF
  echo "path=trail/dod/dod-2026-05-27-test.md" > "$proj/trail/dod/.active-dod"
}

write_dod_with_meta_check_false() {
  local proj="$1"
  cat > "$proj/trail/dod/dod-2026-05-27-test.md" << 'DODEOF'
# G3 meta-check test DoD (meta_check:false)

## 범위

test.

## 변경 파일

- a.txt

## 라우팅 추천

agent: rein:feature-builder
meta_check: false
approved_by_user: true
DODEOF
  echo "path=trail/dod/dod-2026-05-27-test.md" > "$proj/trail/dod/.active-dod"
}

# Make N working-tree changes (tracked + modified so `git diff --name-only HEAD`
# lists them). Untracked files do NOT appear in `git diff HEAD` by design, so
# the test seeds + commits each file first, then modifies it.
make_dirty_files() {
  local proj="$1"; shift
  for f in "$@"; do
    echo "initial" > "$proj/$f"
  done
  (cd "$proj" && git add -A >/dev/null 2>&1 && git commit -q -m "track" >/dev/null 2>&1)
  for f in "$@"; do
    echo "modified" > "$proj/$f"
  done
}

run_hook() {
  local proj="$1"
  local stdin_payload="${2:-{}}"
  (cd "$proj" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" <<< "$stdin_payload")
}

assert_eq() {
  local name="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    echo "OK [$name]"
  else
    echo "FAIL [$name]: expected '$expected' got '$got'" >&2
    FAILED=$((FAILED+1))
  fi
}

inbox_count() {
  local proj="$1"
  local f
  f=$(ls "$proj/trail/inbox/"*-meta-check.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0
}

inbox_mismatch_field() {
  local proj="$1" line_no="$2"
  local f
  f=$(ls "$proj/trail/inbox/"*-meta-check.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || { echo ""; return; }
  sed -n "${line_no}p" "$f" | python3 -c 'import sys,json;d=json.loads(sys.stdin.read());print(d.get("mismatch_count",-1))' 2>/dev/null
}

# ---------- Fixture 1: FASTPATH (answer mode) ------------------------------
# state.json 의 schema-v1 valid + mode=answer 면 hook 은 stdin 도 안 읽고
# git 도 안 부르고 즉시 exit 0. inbox 도 0 line.
F1=$(mktemp -d "/tmp/meta-f1-XXXXXX")
make_project "$F1"
write_dod_with_hint "$F1" "- a.txt"
make_dirty_files "$F1" "a.txt" "b.txt"
mkdir -p "$F1/.rein"
printf '%s' '{"schema_version":1,"mode":"answer","updated_at":"","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":0}' > "$F1/.rein/state.json"
# Spy on git via PATH override to verify 0 invocations
SPY_BIN=$(mktemp -d "/tmp/git-spy-XXXXXX")
SPY_LOG=$(mktemp)
cat > "$SPY_BIN/git" << SPYEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SPY_LOG"
exec /usr/bin/git "\$@"
SPYEOF
chmod +x "$SPY_BIN/git"
F1_STDOUT=$(mktemp)
(cd "$F1" && PATH="$SPY_BIN:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" <<< "{}" >"$F1_STDOUT" 2>/dev/null) || true
INBOX=$(inbox_count "$F1")
# state-machine.sh 가 project-dir lookup 으로 `git rev-parse --show-toplevel` 1회
# 호출하는 건 정상. 본 assertion 은 meta-check 본체의 `git diff --name-only HEAD` /
# `git ls-files --others --exclude-standard` 가 호출되지 않음을 확인한다.
if grep -E "^(diff |ls-files)" "$SPY_LOG" >/dev/null 2>&1; then
  echo "FAIL [F1-FASTPATH-git-diff-or-lsfiles-called]: $(cat "$SPY_LOG")" >&2
  FAILED=$((FAILED+1))
else
  echo "OK [F1-FASTPATH-git-diff-and-lsfiles-not-called]"
fi
assert_eq "F1-FASTPATH-stdout-empty" "" "$(cat "$F1_STDOUT")"
assert_eq "F1-FASTPATH-inbox-zero" "0" "$INBOX"
rm -rf "$F1" "$SPY_BIN" "$SPY_LOG" "$F1_STDOUT"

# ---------- Fixture 2: NO-ACTIVE-DOD ---------------------------------------
F2=$(mktemp -d "/tmp/meta-f2-XXXXXX")
make_project "$F2"
# no .active-dod marker created
OUT=$(run_hook "$F2" 2>&1 || true)
INBOX=$(inbox_count "$F2")
assert_eq "F2-NO-ACTIVE-DOD-stdout-empty" "" "$OUT"
assert_eq "F2-NO-ACTIVE-DOD-inbox-empty" "0" "$INBOX"
rm -rf "$F2"

# ---------- Fixture 3: POLICY-FALSE-YAML -----------------------------------
F3=$(mktemp -d "/tmp/meta-f3-XXXXXX")
make_project "$F3"
write_dod_with_hint "$F3" "- a.txt"
echo "enabled: false" > "$F3/.rein/policy/meta-check.yaml"
make_dirty_files "$F3" "extra.txt"
OUT=$(run_hook "$F3" 2>&1 || true)
INBOX=$(inbox_count "$F3")
assert_eq "F3-POLICY-FALSE-YAML-stdout" "" "$OUT"
assert_eq "F3-POLICY-FALSE-YAML-inbox" "0" "$INBOX"
rm -rf "$F3"

# ---------- Fixture 4: POLICY-FALSE-DOD ------------------------------------
F4=$(mktemp -d "/tmp/meta-f4-XXXXXX")
make_project "$F4"
write_dod_with_meta_check_false "$F4"
make_dirty_files "$F4" "extra.txt"
OUT=$(run_hook "$F4" 2>&1 || true)
INBOX=$(inbox_count "$F4")
assert_eq "F4-POLICY-FALSE-DOD-stdout" "" "$OUT"
assert_eq "F4-POLICY-FALSE-DOD-inbox" "0" "$INBOX"
rm -rf "$F4"

# ---------- Fixture 5: POLICY-AUTO-NO-HINT ---------------------------------
F5=$(mktemp -d "/tmp/meta-f5-XXXXXX")
make_project "$F5"
write_dod_without_hint "$F5"
make_dirty_files "$F5" "extra.txt"
STDERR_FILE=$(mktemp)
STDOUT_FILE=$(mktemp)
(cd "$F5" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" <<< "{}" >"$STDOUT_FILE" 2>"$STDERR_FILE") || true
INBOX=$(inbox_count "$F5")
assert_eq "F5-AUTO-NO-HINT-stdout-empty" "" "$(cat "$STDOUT_FILE")"
assert_eq "F5-AUTO-NO-HINT-inbox-zero" "0" "$INBOX"
if grep -q "silent skip" "$STDERR_FILE"; then
  echo "OK [F5-AUTO-NO-HINT-stderr-notice]"
else
  echo "FAIL [F5-AUTO-NO-HINT-stderr-notice]: expected 'silent skip' in stderr, got:" >&2
  cat "$STDERR_FILE" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F5" "$STDERR_FILE" "$STDOUT_FILE"

# ---------- Fixture 6: POLICY-TRUE-NO-HINT ---------------------------------
F6=$(mktemp -d "/tmp/meta-f6-XXXXXX")
make_project "$F6"
write_dod_without_hint "$F6"
echo "enabled: true" > "$F6/.rein/policy/meta-check.yaml"
make_dirty_files "$F6" "extra1.txt" "extra2.txt"
OUT=$(run_hook "$F6" 2>&1 || true)
INBOX=$(inbox_count "$F6")
MC=$(inbox_mismatch_field "$F6" 1)
assert_eq "F6-TRUE-NO-HINT-inbox-1line" "1" "$INBOX"
assert_eq "F6-TRUE-NO-HINT-inbox-mismatch-2" "2" "$MC"
if printf '%s' "$OUT" | grep -q "meta-check"; then
  echo "OK [F6-TRUE-NO-HINT-advisory-emitted]"
else
  echo "FAIL [F6-TRUE-NO-HINT-advisory-emitted]: expected '[meta-check]' substring in stdout, got: $OUT" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F6"

# ---------- Fixture 7: DETECT-POSITIVE -------------------------------------
F7=$(mktemp -d "/tmp/meta-f7-XXXXXX")
make_project "$F7"
write_dod_with_hint "$F7" "- a.txt"
make_dirty_files "$F7" "a.txt" "b.txt"
OUT=$(run_hook "$F7" 2>&1 || true)
INBOX=$(inbox_count "$F7")
MC=$(inbox_mismatch_field "$F7" 1)
assert_eq "F7-DETECT-POSITIVE-inbox-1line" "1" "$INBOX"
assert_eq "F7-DETECT-POSITIVE-mismatch-count-1" "1" "$MC"
if printf '%s' "$OUT" | grep -q "b.txt"; then
  echo "OK [F7-DETECT-POSITIVE-advisory-mentions-b.txt]"
else
  echo "FAIL [F7-DETECT-POSITIVE-advisory-mentions-b.txt]: expected 'b.txt' in advisory, got: $OUT" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F7"

# ---------- Fixture 8: DETECT-EQUALITY -------------------------------------
F8=$(mktemp -d "/tmp/meta-f8-XXXXXX")
make_project "$F8"
write_dod_with_hint "$F8" "- a.txt"
make_dirty_files "$F8" "a.txt"
OUT=$(run_hook "$F8" 2>&1 || true)
INBOX=$(inbox_count "$F8")
MC=$(inbox_mismatch_field "$F8" 1)
assert_eq "F8-EQUALITY-inbox-1line" "1" "$INBOX"
assert_eq "F8-EQUALITY-mismatch-count-0" "0" "$MC"
assert_eq "F8-EQUALITY-no-advisory" "" "$OUT"
rm -rf "$F8"

# ---------- Fixture 9: DETECT-SUBSET ---------------------------------------
F9=$(mktemp -d "/tmp/meta-f9-XXXXXX")
make_project "$F9"
write_dod_with_hint "$F9" "- a.txt
- b.txt"
make_dirty_files "$F9" "a.txt"
OUT=$(run_hook "$F9" 2>&1 || true)
MC=$(inbox_mismatch_field "$F9" 1)
assert_eq "F9-SUBSET-mismatch-count-0" "0" "$MC"
assert_eq "F9-SUBSET-no-advisory" "" "$OUT"
rm -rf "$F9"

# ---------- Fixture 10: ADVISORY-TOP5-CAP ----------------------------------
F10=$(mktemp -d "/tmp/meta-f10-XXXXXX")
make_project "$F10"
write_dod_with_hint "$F10" "- a.txt"
make_dirty_files "$F10" "a.txt" "b.txt" "c.txt" "d.txt" "e.txt" "f.txt" "g.txt"
OUT=$(run_hook "$F10" 2>&1 || true)
if printf '%s' "$OUT" | grep -q "+1 more"; then
  echo "OK [F10-TOP5-CAP-suffix]"
else
  echo "FAIL [F10-TOP5-CAP-suffix]: expected '+1 more' in advisory, got: $OUT" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F10"

# ---------- Fixture 7b: DETECT-UNTRACKED-WRITE -----------------------------
# Codex Round 2 Medium: Fix B (untracked file union) needs a direct regression.
# User Write 으로 신규 untracked file 생성 시 meta-check 가 detection 하는지 확인.
F7B=$(mktemp -d "/tmp/meta-f7b-XXXXXX")
make_project "$F7B"
write_dod_with_hint "$F7B" "- a.txt"
# DoD + active-dod 마커 자체도 untracked 이므로 ls-files 에 잡혀 mismatch 가 부풀어진다 —
# fixture 의 의도 (c.txt 만 신규 untracked) 와 다른 행동. seed-then-create 패턴으로 격리.
(cd "$F7B" && git add -A >/dev/null 2>&1 && git commit -q -m "seed-fixture" >/dev/null 2>&1)
# 이제 working tree 는 깨끗. c.txt 만 untracked 생성.
echo "new-untracked" > "$F7B/c.txt"
OUT=$(run_hook "$F7B" 2>&1 || true)
INBOX=$(inbox_count "$F7B")
MC=$(inbox_mismatch_field "$F7B" 1)
assert_eq "F7B-UNTRACKED-WRITE-inbox-1line" "1" "$INBOX"
assert_eq "F7B-UNTRACKED-WRITE-mismatch-1" "1" "$MC"
if printf '%s' "$OUT" | grep -q "c.txt"; then
  echo "OK [F7B-UNTRACKED-WRITE-advisory-mentions-c.txt]"
else
  echo "FAIL [F7B-UNTRACKED-WRITE-advisory-mentions-c.txt]: expected 'c.txt' in advisory, got: $OUT" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F7B"

# ---------- Fixture 7c: EMPTY-SECTION-NOT-MISSING --------------------------
# Codex Round 2 Medium: spec §3.2 step 6 distinguishes "section absent" from
# "section present but empty". 본 fixture 는 `## 변경 파일` 헤더만 있고 본문 비어 →
# H=∅ 로 처리되어 모든 diff 가 mismatch (auto 모드여도 SKIP_NO_HINT_AUTO 아님).
F7C=$(mktemp -d "/tmp/meta-f7c-XXXXXX")
make_project "$F7C"
cat > "$F7C/trail/dod/dod-2026-05-27-test.md" << 'DODEOF'
# Empty section test
## 범위
test.

## 변경 파일

## 라우팅 추천
agent: x
approved_by_user: true
DODEOF
echo "path=trail/dod/dod-2026-05-27-test.md" > "$F7C/trail/dod/.active-dod"
make_dirty_files "$F7C" "x.txt"
OUT=$(run_hook "$F7C" 2>&1 || true)
INBOX=$(inbox_count "$F7C")
MC=$(inbox_mismatch_field "$F7C" 1)
assert_eq "F7C-EMPTY-SECTION-inbox-1line" "1" "$INBOX"
assert_eq "F7C-EMPTY-SECTION-mismatch-1" "1" "$MC"
if printf '%s' "$OUT" | grep -q "meta-check"; then
  echo "OK [F7C-EMPTY-SECTION-advisory-emitted]"
else
  echo "FAIL [F7C-EMPTY-SECTION-advisory-emitted]: expected '[meta-check]' substring, got: $OUT" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F7C"

# ---------- Fixture 11: INBOX-APPEND-TWICE ---------------------------------
F11=$(mktemp -d "/tmp/meta-f11-XXXXXX")
make_project "$F11"
write_dod_with_hint "$F11" "- a.txt"
make_dirty_files "$F11" "a.txt"
run_hook "$F11" >/dev/null 2>&1 || true
run_hook "$F11" >/dev/null 2>&1 || true
INBOX=$(inbox_count "$F11")
assert_eq "F11-INBOX-APPEND-TWICE" "2" "$INBOX"
rm -rf "$F11"

# ---------- Fixture 12: INBOX-ZERO-RECORDED (covered by F8) ---------------
echo "OK [F12-INBOX-ZERO-RECORDED-covered-by-F8]"

# ---------- Fixture 13: PERF (20-run p95, smoke) ---------------------------
# G3-perf-NFR cycle (2026-05-27) updated this fixture:
#   - Original spec target 150ms was unachievable (Python cold-start +
#     git binary overhead is irreducible at ~160ms floor)
#   - Phase 1 (policy-loader → shell awk) + Phase 2 (heredoc tool_use_id
#     merge) reduced p95 from 209ms baseline to ~168ms (-41ms / -20%)
#   - New NFR target 180ms p95 — verified strictly in
#     tests/hooks/test-post-edit-meta-check-perf.sh
#   - This F13 fixture now stays as smoke ≤ 250ms (cadence separation)
F13=$(mktemp -d "/tmp/meta-f13-XXXXXX")
make_project "$F13"
write_dod_with_hint "$F13" "- a.txt
- b.txt
- c.txt"
make_dirty_files "$F13" "a.txt" "b.txt" "c.txt"
SAMPLES=$(mktemp)
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  T0=$(python3 -c 'import time; print(int(time.time_ns()))')
  run_hook "$F13" >/dev/null 2>&1 || true
  T1=$(python3 -c 'import time; print(int(time.time_ns()))')
  echo $(( (T1 - T0) / 1000000 )) >> "$SAMPLES"
done
P95_MS=$(sort -n "$SAMPLES" | sed -n '19p')
if [ "${P95_MS:-9999}" -le 180 ]; then
  echo "OK [F13-PERF-p95-${P95_MS}ms<=180ms-NFR-target]"
elif [ "${P95_MS:-9999}" -le 250 ]; then
  echo "OK [F13-PERF-p95-${P95_MS}ms<=250ms-smoke] (strict 180ms in test-post-edit-meta-check-perf.sh)"
else
  echo "FAIL [F13-PERF-p95-${P95_MS}ms>250ms — investigate]" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$F13" "$SAMPLES"

# ---------- Result ---------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
  echo "test-post-edit-meta-check: FAIL ($FAILED assertion(s))" >&2
  exit 1
fi
echo "test-post-edit-meta-check: OK (13 fixtures covered)"
