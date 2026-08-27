#!/usr/bin/env bash
# tests/hooks/test-post-agent-review-trigger.sh
#
# Test suite for plugins/rein-core/hooks/post-agent-review-trigger.sh (HK-3).
#
# Phase 7 웨이브 3 ③-d 재조준. 이전 계약(HK-3 원판)은 `trail/dod/.review-
# pending` marker 존재로 "리뷰 대기" 를 판정했다. 그 marker 의 유일한
# 생산자였던 post-edit-review-gate.sh 가 이 웨이브에서 삭제됐으므로(legacy
# 리뷰 표식 3종 write/read 경로 전면 제거), 이 훅은 실제 `bin/rein issue-
# evidence code_review --print-digest` 조회로 판정 수단을 이관했다 (훅
# 자신의 헤더가 판정 트리의 정본 — 이 스위트는 그 트리를 실제 실행으로
# 고정한다).
#
# 새 판정 (부작용 없는 조회 — 발급을 시도하지 않는다):
#   - 실 digest 문자열(센티널 아님) → "리뷰할 실제 코드 변경이 있다" →
#     PostToolUse block 안내 방출
#   - 두 닫힌 값 센티널(SUBJECT_EMPTY="empty:no-subject" / SUBJECT_
#     UNRESOLVED="unresolved:no-subject", rein/kernel/changeset.py) 중
#     하나, 빈 출력, 또는 CLI 비0 종료 → 침묵 (exit 0, 무출력)
#
# 절대 source 하지 않는다 — 항상 실제 훅 프로세스를 실행한다. bin/rein 은
# 실 symlink 로 연결해(self-location 이 os.path.realpath(__file__) 라
# symlink 만으로 실 plugins/rein-core 트리를 그대로 찾는다 — 별도로
# rein/ 패키지를 샌드박스에 복사할 필요 없음) --print-digest 가 진짜 v2
# kernel/platform digest 계산을 거치게 한다 (행위 기반 원칙 —
# reference_hook_test_behavioral_over_sourced 메모: source 방식은 SCRIPT_DIR
# 재계산으로 false-green 을 낸 전례가 있다).
#
# Scenarios:
#   (a) subagent_type "feature-builder" + real (non-sentinel) digest → block
#   (b) subagent_type "rein:feature-builder" (namespaced) + real digest → block
#   (c) subagent_type "researcher" (allowlist 밖) + real digest → silent
#   (d) subagent_type "feature-builder" + 변경 없음 (SUBJECT_EMPTY) → silent
#   (e) subagent_type "feature-builder-fix" + real digest → block
#   (f) subagent_type "feature-builder-refactor" + real digest → block
#   (g) subagent_type "feature-builder" + git repo 아님 (SUBJECT_UNRESOLVED) → silent
#   (h) subagent_type "feature-builder" + bin/rein 부재 → silent
#   (i) subagent_type "feature-builder" + bin/rein CLI 실패(비0 종료) → silent

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK_SRC="$REAL_PROJECT_DIR/plugins/rein-core/hooks/post-agent-review-trigger.sh"
REAL_BIN_REIN="$REAL_PROJECT_DIR/plugins/rein-core/bin/rein"
[ -f "$HOOK_SRC" ] || { echo "FAIL: $HOOK_SRC missing" >&2; exit 1; }
[ -f "$REAL_BIN_REIN" ] || { echo "FAIL: $REAL_BIN_REIN missing" >&2; exit 1; }

FAIL=0
note_fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# ------------------------------------------------------------
# Sandbox helpers
# ------------------------------------------------------------

_new_sandbox() { mktemp -d "/tmp/post-agent-review-trigger-XXXXXX"; }

# _link_hook SANDBOX — copies the hook + its lib/ siblings (it sources
# lib/python-runner.sh + lib/project-dir.sh) into a `.claude/hooks/` layout.
_link_hook() {
  local sbx="$1"
  mkdir -p "$sbx/.claude/hooks/lib"
  cp "$HOOK_SRC" "$sbx/.claude/hooks/post-agent-review-trigger.sh"
  cp -R "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/." "$sbx/.claude/hooks/lib/"
  chmod +x "$sbx/.claude/hooks/post-agent-review-trigger.sh"
}

# _link_real_bin_rein SANDBOX — symlink .claude/bin/rein → the REAL bin/rein.
# bin/rein's self-location uses os.path.realpath(__file__), so this resolves
# straight through to the real plugins/rein-core tree (rein/ package included)
# without any separate copy.
_link_real_bin_rein() {
  local sbx="$1"
  mkdir -p "$sbx/.claude/bin"
  ln -sfn "$REAL_BIN_REIN" "$sbx/.claude/bin/rein"
}

# _write_broken_bin_rein SANDBOX — a bin/rein stub that always fails (CLI
# failure scenario, distinct from bin/rein being absent).
_write_broken_bin_rein() {
  local sbx="$1"
  mkdir -p "$sbx/.claude/bin"
  cat > "$sbx/.claude/bin/rein" <<'PY'
#!/usr/bin/env python3
import sys
sys.stderr.write("[test] engine deliberately broken\n")
sys.exit(3)
PY
  chmod +x "$sbx/.claude/bin/rein"
}

# _gitignore_rein_runtime SANDBOX — real rein-managed repos gitignore
# `/.rein/cache/` (+ `/.rein/state/` + `/.rein/logs/`, see this repo's own
# .gitignore) so this hook's own dedup-cache side effect
# (`.rein/cache/review-nudge/last-digest`, written after every nudge) never
# shows up as untracked noise in `git status --untracked-files=all` — the
# same scan `bin/rein issue-evidence code_review --print-digest` performs
# to compute the changeset digest this hook's dedup check compares.
# Sandboxes here start with no .gitignore at all, so without this the
# FIRST hook invocation's own cache-file write pollutes the very digest a
# SECOND invocation recomputes — self-polluting the dedup detection
# scenario (j) below is meant to prove (real rein-managed repos are immune
# because that path is ignored). Same fix, same rationale, same function
# name as tests/hooks/test-pre-bash-commit-review-gate.sh's helper of the
# same name (동형 재작성 — this file's helpers all take an explicit sbx
# param rather than a shared-harness global $SANDBOX, so the body is
# adapted to that convention; the ignored paths are extended with
# `/.rein/cache/` since that is the path THIS hook actually writes, unlike
# the sibling hook which only touches `.rein/state/`).
_gitignore_rein_runtime() {
  local sbx="$1"
  cat >> "$sbx/.gitignore" <<'EOF'
/.rein/cache/
/.rein/state/
/.rein/logs/
EOF
}

# _seed_real_repo SANDBOX — turns SANDBOX into a real git repo with a
# baseline commit, so bin/rein's `_git_changeset_facts()` has a real
# toplevel to resolve against. MUST run AFTER _link_hook/_link_real_bin_rein
# (or _write_broken_bin_rein) — it `git add -A`s the WHOLE tree (including
# the just-copied .claude/hooks + .claude/bin) into the baseline commit, so
# those copied files never show up as untracked "review subject" noise that
# would corrupt the SUBJECT_EMPTY / real-digest distinction below. Also
# bakes in _gitignore_rein_runtime (see above) so this hook's own dedup
# cache write never pollutes that same digest computation later.
_seed_real_repo() {
  local sbx="$1"
  git -C "$sbx" init -q
  git -C "$sbx" config user.email "test@example.com"
  git -C "$sbx" config user.name "test"
  _gitignore_rein_runtime "$sbx"
  printf '# placeholder\n' > "$sbx/README.md"
  git -C "$sbx" add -A
  git -C "$sbx" commit -q -m "init" >/dev/null
}

_event_payload() {
  python3 -c "import json,sys; print(json.dumps({'tool_input':{'subagent_type': sys.argv[1]},'tool_result':{}}))" "$1"
}

# run_hook <sandbox> <subagent_type> — sets OUT, RC.
run_hook() {
  local sbx="$1" subagent_type="$2" payload out_file
  payload="$(_event_payload "$subagent_type")"
  out_file=$(mktemp)
  printf '%s' "$payload" | REIN_PROJECT_DIR_OVERRIDE="$sbx" \
    bash "$sbx/.claude/hooks/post-agent-review-trigger.sh" >"$out_file" 2>/dev/null
  RC=$?
  OUT=$(cat "$out_file")
  rm -f "$out_file"
}

assert_block() {
  # $1=label
  if [ "$RC" -ne 0 ]; then
    note_fail "($1) exit code should be 0, got $RC"
  fi
  if [ -z "$OUT" ]; then
    note_fail "($1): expected block envelope, got no output"
    return
  fi
  if ! echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('decision')=='block'" 2>/dev/null; then
    note_fail "($1): output decision != 'block' (got: $OUT)"
    return
  fi
  echo "  ok: ($1) -> {decision:block} JSON"
}

assert_silent() {
  # $1=label
  if [ "$RC" -ne 0 ]; then
    note_fail "($1) exit code should be 0, got $RC"
  fi
  if [ -n "$OUT" ]; then
    note_fail "($1): expected no output, got: $OUT"
    return
  fi
  echo "  ok: ($1) -> no output"
}

# ---- (a) feature-builder + real digest -> block ------------------------------
SBX_A=$(_new_sandbox)
_link_hook "$SBX_A"
_link_real_bin_rein "$SBX_A"
_seed_real_repo "$SBX_A"
mkdir -p "$SBX_A/scripts"
printf 'echo hi\n' > "$SBX_A/scripts/foo.sh"
run_hook "$SBX_A" "feature-builder"
assert_block "a: feature-builder + real digest"
rm -rf "$SBX_A"

# ---- (b) rein:feature-builder namespaced -> block ----------------------------
SBX_B=$(_new_sandbox)
_link_hook "$SBX_B"
_link_real_bin_rein "$SBX_B"
_seed_real_repo "$SBX_B"
mkdir -p "$SBX_B/scripts"
printf 'echo hi\n' > "$SBX_B/scripts/foo.sh"
run_hook "$SBX_B" "rein:feature-builder"
assert_block "b: rein:feature-builder namespaced strips prefix"
rm -rf "$SBX_B"

# ---- (c) researcher (allowlist 밖) -> silent ---------------------------------
SBX_C=$(_new_sandbox)
_link_hook "$SBX_C"
_link_real_bin_rein "$SBX_C"
_seed_real_repo "$SBX_C"
mkdir -p "$SBX_C/scripts"
printf 'echo hi\n' > "$SBX_C/scripts/foo.sh"
run_hook "$SBX_C" "researcher"
assert_silent "c: researcher not in allowlist"
rm -rf "$SBX_C"

# ---- (d) feature-builder + 변경 없음 (SUBJECT_EMPTY) -> silent ---------------
SBX_D=$(_new_sandbox)
_link_hook "$SBX_D"
_link_real_bin_rein "$SBX_D"
_seed_real_repo "$SBX_D"
# clean tree, no further changes at all.
run_hook "$SBX_D" "feature-builder"
assert_silent "d: feature-builder + no changes (SUBJECT_EMPTY)"
rm -rf "$SBX_D"

# ---- (e) feature-builder-fix + real digest -> block --------------------------
SBX_E=$(_new_sandbox)
_link_hook "$SBX_E"
_link_real_bin_rein "$SBX_E"
_seed_real_repo "$SBX_E"
mkdir -p "$SBX_E/scripts"
printf 'echo hi\n' > "$SBX_E/scripts/foo.sh"
run_hook "$SBX_E" "feature-builder-fix"
assert_block "e: feature-builder-fix + real digest"
rm -rf "$SBX_E"

# ---- (f) feature-builder-refactor + real digest -> block ---------------------
SBX_F=$(_new_sandbox)
_link_hook "$SBX_F"
_link_real_bin_rein "$SBX_F"
_seed_real_repo "$SBX_F"
mkdir -p "$SBX_F/scripts"
printf 'echo hi\n' > "$SBX_F/scripts/foo.sh"
run_hook "$SBX_F" "feature-builder-refactor"
assert_block "f: feature-builder-refactor + real digest"
rm -rf "$SBX_F"

# ---- (g) feature-builder + git repo 아님 (SUBJECT_UNRESOLVED) -> silent ------
SBX_G=$(_new_sandbox)
_link_hook "$SBX_G"
_link_real_bin_rein "$SBX_G"
# deliberately NOT a git repo.
run_hook "$SBX_G" "feature-builder"
assert_silent "g: feature-builder + not a git repo (SUBJECT_UNRESOLVED)"
rm -rf "$SBX_G"

# ---- (h) feature-builder + bin/rein 부재 -> silent ---------------------------
SBX_H=$(_new_sandbox)
_link_hook "$SBX_H"
# deliberately no .claude/bin/rein at all.
_seed_real_repo "$SBX_H"
mkdir -p "$SBX_H/scripts"
printf 'echo hi\n' > "$SBX_H/scripts/foo.sh"
run_hook "$SBX_H" "feature-builder"
assert_silent "h: bin/rein absent"
rm -rf "$SBX_H"

# ---- (i) feature-builder + bin/rein CLI 실패 -> silent -----------------------
SBX_I=$(_new_sandbox)
_link_hook "$SBX_I"
_write_broken_bin_rein "$SBX_I"
_seed_real_repo "$SBX_I"
mkdir -p "$SBX_I/scripts"
printf 'echo hi\n' > "$SBX_I/scripts/foo.sh"
run_hook "$SBX_I" "feature-builder"
assert_silent "i: bin/rein CLI failure (exit 3)"
rm -rf "$SBX_I"

# ---- (j) feature-builder + real digest, hook fires twice in a row with the
#          same unchanged digest -> first call blocks, second is silent
#          (코드리뷰 Medium 시정, 2026-08-24 — dedup cache). 코드리뷰 라운드
#          2 High 시정: 이 시나리오가 원래 여기서 FAIL 했다 — 샌드박스에
#          .gitignore 가 없어 (j1) 이 쓴 `.rein/cache/review-nudge/
#          last-digest` 자체가 (j2) 의 digest 계산에 섞여 들어가 dedup 이
#          안 걸렸다(실제 rein 프로젝트는 `.gitignore` 가 그 경로를 무시해
#          이 문제가 없다 — 샌드박스가 실제 환경을 재현하지 못한 것이
#          결함이었다). 위 `_gitignore_rein_runtime()` 로 수리 ---------------
SBX_J=$(_new_sandbox)
_link_hook "$SBX_J"
_link_real_bin_rein "$SBX_J"
_seed_real_repo "$SBX_J"
mkdir -p "$SBX_J/scripts"
printf 'echo hi\n' > "$SBX_J/scripts/foo.sh"
run_hook "$SBX_J" "feature-builder"
assert_block "j1: first completion with a real digest still blocks"
run_hook "$SBX_J" "feature-builder"
assert_silent "j2: second completion, same unchanged digest, is deduped silent"
# a genuinely new change after the dedup should nudge again.
printf 'echo bar\n' > "$SBX_J/scripts/bar.sh"
run_hook "$SBX_J" "feature-builder"
assert_block "j3: a real new change after dedup blocks again"
rm -rf "$SBX_J"

# ---- (k) digest 불변 회귀 핀 (코드리뷰 라운드 2 High 재발 방지) — the dedup
#          cache file's own creation must never change the changeset digest
#          this hook (and the commit gate) compute. This is the direct pin
#          for the bug (j) exercises indirectly via dedup behavior: capture
#          the digest via the SAME `bin/rein issue-evidence code_review
#          --print-digest` call the hook uses, both before and after the
#          hook writes its cache file, and assert they are identical. Also
#          confirms the cache file was actually created, so a "file never
#          appeared" failure mode cannot masquerade as digest-invariance. --
SBX_K=$(_new_sandbox)
_link_hook "$SBX_K"
_link_real_bin_rein "$SBX_K"
_seed_real_repo "$SBX_K"
mkdir -p "$SBX_K/scripts"
printf 'echo hi\n' > "$SBX_K/scripts/foo.sh"
DIGEST_BEFORE=$(REIN_PROJECT_ROOT="$SBX_K" "$SBX_K/.claude/bin/rein" issue-evidence code_review --print-digest 2>/dev/null)
run_hook "$SBX_K" "feature-builder"
NUDGE_CACHE_K="$SBX_K/.rein/cache/review-nudge/last-digest"
if [ -f "$NUDGE_CACHE_K" ]; then
  echo "  ok: (k1) dedup cache file was actually created by the hook run"
else
  note_fail "(k1): dedup cache file was not created at $NUDGE_CACHE_K — the digest-invariance check below would be vacuous"
fi
DIGEST_AFTER=$(REIN_PROJECT_ROOT="$SBX_K" "$SBX_K/.claude/bin/rein" issue-evidence code_review --print-digest 2>/dev/null)
if [ -z "$DIGEST_BEFORE" ]; then
  note_fail "(k2): pre-hook digest capture was empty — cannot assert invariance against a real digest"
elif [ "$DIGEST_BEFORE" = "$DIGEST_AFTER" ]; then
  echo "  ok: (k2) changeset digest unchanged after the cache file was created (digest=$DIGEST_BEFORE)"
else
  note_fail "(k2): changeset digest changed after cache file creation (before=[$DIGEST_BEFORE] after=[$DIGEST_AFTER]) — the dedup cache polluted governance digest computation"
fi
rm -rf "$SBX_K"

# ---- summary ------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-post-agent-review-trigger: OK (11 scenarios)"
  exit 0
else
  echo "test-post-agent-review-trigger: $FAIL scenario(s) FAILED"
  exit 1
fi
