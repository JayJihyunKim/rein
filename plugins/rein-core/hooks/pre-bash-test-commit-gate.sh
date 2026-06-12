#!/bin/bash
# Hook: PreToolUse(Bash) — test/commit review gate (if-gated).
#
# HK-2 (docs/specs/2026-05-19-cc-feature-adoption.md §HK-2): this script is the
# test/commit half of the former single Bash guard. hooks.json registers it
# with `if` permission-rule filters so it only spawns on test-runner / commit
# command patterns — the always-on safety checks live in
# pre-bash-safety-guard.sh. On older Claude Code that ignores `if`, this hook
# runs unconditionally and degrades to the legacy always-spawn behavior (spec
# R6) — still correct, just less lean.
#
# Block points enforced here:
#   [P2]  coverage matrix mismatch  — plan/DoD `covers` list out of date
#   [P3]  review pending, no stamp  — code edited, codex review not run
#   [P4]  code edited after review  — stamp older than .review-pending
#   [P5]  codex review stamp missing
#   [P6]  security review stamp missing
#   [P7]  commit message format     — not Conventional Commits
# Infra integrity (paired with the policy points above):
#   [I3]  coverage marker target unidentifiable (pairs with P2)
#   [I4]  commit-msg helper absent  (pairs with P7)
#   [I5]  commit-msg helper exec failure (pairs with P7)
# Common infra (shared with pre-bash-safety-guard.sh via lib/bash-guard-infra.sh):
#   [I1]  python3 resolver failure
#   [I2]  hook input JSON parse failure
#   [I6]  JSON deny emitter unavailable/corrupt
#
# Exit code protocol (2-tier):
#   정책 차단 [P2]/[P3]/[P4]/[P5]/[P6]/[P7]: exit 0 + JSON deny (deny_emit)
#   인프라 무결성 [I1]~[I6]:                 exit 2 + stderr   (fail-closed)
# 분류 근거: docs/specs/2026-05-17-hook-message-assistant-tone.md §1
# 주의: exit 1 은 non-blocking error (통과됨). 차단은 exit 0+JSON deny 또는 exit 2

# --- Policy toggle moved below the python resolver (GMF-4) ---
# The policy-toggle block used to live HERE (top of file) and hard-coded
# `python3`. When python3 was absent (127) or a Windows stub (49), the
# `if ! python3 <loader>; then exit 0` form treated interpreter-absence as a
# user policy disable and silently turned the gate OFF (fail-open). GMF-4
# (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4) moves the policy check
# to AFTER bg_resolve_python_or_die (which already exit-2s on interpreter
# absence) and calls the loader via "${PYTHON_RUNNER[@]}", so a missing
# interpreter never disables the gate. See the policy block after [I1].

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Optional libs for consumer-side coverage marker self-heal (DoD:
# dod-2026-05-15-marker-self-heal). Source soft — if either is
# missing the revalidate helper falls back to "cannot revalidate" (rc=2),
# which preserves the legacy conservative block behavior.
. "$SCRIPT_DIR/lib/select-active-dod.sh" 2>/dev/null || true
. "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null || true

# Identity for blocks.jsonl + THRESHOLD counting. Must be set BEFORE sourcing
# bash-guard-infra.sh.
BG_GUARD_NAME="pre-bash-test-commit-gate"

# shellcheck source=./lib/bash-guard-infra.sh
# Shared infra (I1·I2·I6 + log_block + command_invokes). Sourced with the
# `if !` form so a parse error in the lib fail-closes (exit 2) — same fail-
# closed posture the [I6] emitter check uses.
if ! . "$SCRIPT_DIR/lib/bash-guard-infra.sh" 2>/dev/null; then
  echo "[rein] The Bash guard cannot run because its shared infrastructure (lib/bash-guard-infra.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# canonical git subcommand token model (SSOT) — GMF-1/GMF-2. Of the three
# model consumers (classifier / dispatcher / this gate) this gate is the only
# HARD-FAIL consumer: a missing/corrupt lib or empty $GIT_COMMIT_ERE/
# $GIT_MERGE_ERE is an integrity defect → exit 2 (fail-closed). Passing an
# empty ERE to command_invokes makes the matcher untrustworthy (per-environment
# error / match-all / misclassification) — an empty $GIT_MERGE_ERE could exempt
# EVERY command (fail-open) and an empty $GIT_COMMIT_ERE could drop the commit
# check. So we hard-fail before any empty ERE reaches the body below.
# (bash-guard-infra / safety-guard are NOT touched: safety-guard does not use
# these ERE constants — its P10 GIT_COMMIT_PREFIX is out of scope — so sourcing
# the model there would couple safety-guard to a lib it never reads.)
if ! { [ -f "$SCRIPT_DIR/lib/git-subcommand-model.sh" ] \
       && . "$SCRIPT_DIR/lib/git-subcommand-model.sh" \
       && [ -n "${GIT_COMMIT_ERE:-}" ] && [ -n "${GIT_MERGE_ERE:-}" ]; }; then
  echo "[rein] The commit gate cannot run because its git-subcommand token model (lib/git-subcommand-model.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# [I6] infra integrity — load + verify the JSON deny emitter (exit 2 on fail).
bg_infra_init "$SCRIPT_DIR"

INPUT=$(cat)

# [I1] infra integrity — resolve python3 (exit 2 on fail).
bg_resolve_python_or_die

# --- Policy toggle (plugin mode only) — GMF-4 resolver-after form ---
# .rein/policy/hooks.yaml can disable this hook via `<hook-name>: false` or
# `{ <hook-name>: { enabled: false } }`. The loader also honours the legacy
# umbrella key `pre-bash-guard` (rein-policy-loader.py UMBRELLA_KEYS) so a
# project that disabled the old single hook keeps both halves disabled.
# Requires plugin mode (${CLAUDE_PLUGIN_ROOT} set). Skipped otherwise.
#
# GMF-4 contract: bg_resolve_python_or_die above already exit-2s (fail-closed)
# when the interpreter is absent, so reaching here means PYTHON_RUNNER is a
# real interpreter. We call the loader through it and distinguish:
#   rc == 1        → loader ran cleanly + reported "disabled" → exit 0 (OFF)
#   rc == 0        → enabled → fall through to the gate body (active)
#   rc ∉ {0,1}     → loader crash / OS fault → fail-closed (gate active)
# Interpreter-absence can no longer reach this block, so it never disables
# the gate.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-bash-test-commit-gate"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 1 ]; then
    exit 0  # loader ran cleanly + disabled by user policy
  fi
  # rc 0 = enabled (continue); rc ∉ {0,1} = loader call failure → fail-closed.
fi

# [I2] infra integrity — parse tool_input.command (exit 2 on parse failure).
# Called WITHOUT command substitution so its fail-close reaches the top level;
# bg_extract_command sets the global COMMAND on success.
COMMAND=""
bg_extract_command "$SCRIPT_DIR" "$INPUT" || exit 2

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- merge/rebase/am commit 은 메시지 포맷 검증에서 면제 ---
# merge/rebase 는 메시지를 자동 생성하므로 Conventional Commits 검증 대상이
# 아니다. 면제는 stamp/coverage gate 보다 앞서야 한다 — 그 commit 들도 통과.
# GMF-2 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.2): 이전의 비앵커
# substring grep (`echo "$COMMAND" | grep -qE "git (merge|rebase|am)"`) 은
# 커밋 *메시지* 안에 든 리터럴 `git merge`/`git rebase`/`git am` substring 까지
# 매칭해, 그 *일반 커밋* 을 진짜 merge 로 오인하고 전 검사를 통째로 면제했다
# (false-negative). canonical $GIT_MERGE_ERE 를 command_invokes 로 소비하면
# clause-start 앵커가 첫 서브커맨드만 본다 — 글로벌 옵션 skip 후 첫 non-옵션
# 토큰이 merge/rebase/am 일 때만 면제. `-m "...git merge..."` 의 메시지 본문
# substring 은 비매칭(첫 서브커맨드는 commit). $GIT_MERGE_ERE 는 GMF-1 신설
# lib (git-subcommand-model.sh, 위에서 hard-fail source 됨) 의 SSOT 정의를
# 소비만 한다 — 여기서 재정의하지 않는다.
if command_invokes "$GIT_MERGE_ERE"; then
  exit 0
fi

# --- Codex 리뷰 + 보안 리뷰 stamp 공통 검사 함수 ([P3]~[P6]) ---
check_review_stamp() {
  local context="$1"  # "test" 또는 "commit"
  REVIEW_STAMP="$PROJECT_DIR/trail/dod/.codex-reviewed"
  SECURITY_STAMP="$PROJECT_DIR/trail/dod/.security-reviewed"
  DOD_DIR="$PROJECT_DIR/trail/dod"

  # DoD 파일이 없으면 (작업 중이 아니면) 검사 스킵
  DOD_EXISTS=false
  if [ -d "$DOD_DIR" ]; then
    for f in "$DOD_DIR"/dod-*.md; do
      [ -f "$f" ] || continue
      DOD_EXISTS=true
      break
    done
  fi
  [ "$DOD_EXISTS" = false ] && return 0

  # --- .review-pending 검증 (코드 편집 후 리뷰 필수) ---
  REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"
  if [ -f "$REVIEW_PENDING" ]; then
    if [ ! -f "$REVIEW_STAMP" ]; then
      # [P3] policy block — JSON deny. HIGH-2: exit directly (not return) so caller
      # cannot mistake "deny emitted (0)" for "stamp pass (0)".
      deny_emit "Source code was edited but the codex review has not been run yet. Run /codex-review to record the review before committing." "REVIEW_PENDING_NO_STAMP" "$COMMAND"; rc=$?
      log_block "코드 편집 후 리뷰 미실행 (${context})" "$COMMAND"
      exit "$rc"
    fi

    # .codex-reviewed가 .review-pending보다 최신인지 검증
    PENDING_TIME=$(portable_mtime_epoch "$REVIEW_PENDING")
    REVIEW_TIME=$(portable_mtime_epoch "$REVIEW_STAMP")
    if [ "$REVIEW_TIME" -lt "$PENDING_TIME" ]; then
      # [P4] policy block — JSON deny. HIGH-2: exit directly.
      deny_emit "Code was edited after the last codex review. Re-run /codex-review to record a fresh review before committing." "CODE_EDITED_AFTER_REVIEW" "$COMMAND"; rc=$?
      log_block "리뷰 후 코드 재수정 (${context})" "$COMMAND"
      exit "$rc"
    fi
  fi

  # --- escalated_to_human 감지 시 경고 (차단하지 않음) ---
  if grep -q "resolution: escalated_to_human" "$REVIEW_STAMP" 2>/dev/null; then
    echo "WARNING: 코드 리뷰가 사람 에스컬레이션 상태입니다. 수동 확인 후 진행하세요." >&2
  fi

  # --- Codex 리뷰 stamp 검사 ---
  # 시간 기반 TTL 은 제거 — .review-pending 비교가 "코드 변경 후 재리뷰" 를 정확히 담당한다
  if [ ! -f "$REVIEW_STAMP" ]; then
    # [P5] policy block — JSON deny. HIGH-2: exit directly.
    deny_emit "The codex review has not been recorded yet. Run /codex-review before ${context} — this creates the review record that rein requires before commits." "CODEX_STAMP_MISSING" "$COMMAND"; rc=$?
    log_block "Codex 리뷰 미실행 (${context})" "$COMMAND"
    exit "$rc"
  fi

  # --- 보안 리뷰 stamp 검사 ([P6] — RT-1) ---
  # Skip ONLY when the active DoD's ## 라우팅 추천 YAML has BOTH:
  #   security_tier: light   AND   approved_by_user: true
  # Fail-closed: absent DoD, unparseable YAML, Tier 0, any other value → require stamp.
  # .codex-reviewed (P5) is NEVER skipped regardless of security_tier.
  #
  # DoD selection uses the canonical select_active_dod resolver (already sourced
  # at the top of this hook via lib/select-active-dod.sh). This prevents the
  # stale-DoD bypass: a glob last-match over dod-*.md could pick an alphabetically-
  # later stale DoD with security_tier:light even when .active-dod marker points at
  # a standard-tier DoD. select_active_dod honours Tier 1 (explicit marker) first,
  # then Tier 2 (mtime-latest with ## 범위 연결). Tier 0 → fail-closed (require stamp).
  _security_tier_skip=false
  if [ ! -f "$SECURITY_STAMP" ]; then
    # Resolve the active DoD via the canonical selector. select_active_dod reads
    # relative paths (trail/dod/.active-dod, trail/dod/*.md) so we must anchor to
    # PROJECT_DIR — same pattern used in the .dod-coverage-mismatch branch above.
    _active_dod=""
    if command -v select_active_dod >/dev/null 2>&1; then
      _sad=$(cd "$PROJECT_DIR" && select_active_dod 2>/dev/null) || _sad=""
      _sad_tier=$(printf '%s' "$_sad" | cut -f1)
      _sad_path=$(printf '%s' "$_sad" | cut -f2)
      # B1 (v1.3.4): accept ONLY Tier 1 (explicit .active-dod marker —
      # "blocking authority" per lib/select-active-dod.sh). Tier 2 is the
      # advisory mtime-latest fallback ("non-blocking authority") and must
      # NOT authorise skipping the security stamp, which is itself a blocking
      # decision. This aligns with the coverage-marker self-heal path below,
      # which already trusts ONLY Tier 1. A real approved DoD always carries an
      # .active-dod marker (auto-written by post-edit-dod-routing-check), so
      # the legitimate light-tier skip stays Tier 1. Tier 0/2, empty path, or
      # missing file → fail-closed (require stamp).
      if [ "$_sad_tier" = "1" ] && [ -n "$_sad_path" ]; then
        # select_active_dod returns repo-relative path; anchor to PROJECT_DIR.
        _sad_abs="$PROJECT_DIR/$_sad_path"
        [ -f "$_sad_abs" ] && _active_dod="$_sad_abs"
      fi
    fi
    # If select_active_dod is unavailable or returned Tier 0 / empty / absent file,
    # _active_dod remains empty and we fall through to the fail-closed deny below.

    if [ -n "$_active_dod" ] && [ -f "$_active_dod" ]; then
      # Section-scoped extraction (codex review R2 HIGH fix): security_tier and
      # approved_by_user MUST be read only from inside the `## 라우팅 추천`
      # section. A global grep also matches an out-of-section `security_tier:
      # light` placed anywhere in the DoD (prose, examples, 비범위 notes, a
      # second section) — a fail-open bypass. awk emits only routing-section
      # body lines; an absent section yields an empty string → both values
      # stay empty → fail-closed (no skip).
      _routing_section=$(awk '
        /^## / { in_routing = ($0 ~ /^## 라우팅 추천/) }
        in_routing { print }
      ' "$_active_dod" 2>/dev/null)
      # Only accept exactly "light" (trimmed); anything else → fail-closed.
      _st_raw=$(printf '%s\n' "$_routing_section" \
                | grep -m1 '^[[:space:]]*security_tier:[[:space:]]*' \
                | sed 's/^[[:space:]]*security_tier:[[:space:]]*//' \
                | tr -d '[:space:]"'"'"'' \
                | head -c 20)
      # Extract approved_by_user: must be exactly "true" (trimmed).
      _approved_raw=$(printf '%s\n' "$_routing_section" \
                      | grep -m1 '^[[:space:]]*approved_by_user:[[:space:]]*' \
                      | sed 's/^[[:space:]]*approved_by_user:[[:space:]]*//' \
                      | tr -d '[:space:]"'"'"'' \
                      | head -c 10)

      if [ "$_st_raw" = "light" ] && [ "$_approved_raw" = "true" ]; then
        _security_tier_skip=true
      fi
    fi

    if [ "$_security_tier_skip" = "false" ]; then
      # [P6] policy block — JSON deny. HIGH-2: exit directly.
      deny_emit "The security review has not been recorded yet. Run the security-reviewer agent after codex review — this creates the security review record that rein requires before committing." "SECURITY_STAMP_MISSING" "$COMMAND"; rc=$?
      log_block "보안 리뷰 미실행 (${context})" "$COMMAND"
      exit "$rc"
    fi
    # security_tier: light + approved_by_user: true → P6 skipped (RT-1)
  fi


  return 0
}

# --- Coverage matrix gate ([P2] / [I3], 리뷰 stamp 검사보다 선행) ---
# Plan A Phase 5 (GI-dod-mismatch-marker-consumer): BLOCK_MARKERS is an array
# so the gate consumes both the legacy plan-level marker and the new DoD-level
# marker. Advisory (non-blocking) markers like .dod-coverage-advisory must NOT
# be listed here — they are informational only and do not gate commits/tests.
# Iteration order determines which marker's message surfaces first when more
# than one is present; we keep legacy first for message stability.
BLOCK_MARKERS=(
  "$PROJECT_DIR/trail/dod/.coverage-mismatch"
  "$PROJECT_DIR/trail/dod/.dod-coverage-mismatch"
)

# Sanitize a path string read from a marker file before echoing to stderr.
# Defense-in-depth (security review INFO-1): although marker content already
# requires repo trust to modify, a hostile or corrupted marker could embed
# control chars / ANSI escapes / very long strings that pollute stderr +
# blocks.log. Normalize to a printable, length-bounded form before any echo.
#   - Strip non-printable / control chars
#   - Truncate to 200 chars
sanitize_marker_path() {
  printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200
}

# Consumer-side coverage marker self-heal. Returns:
#   0 — validator PASS for marker target(s); marker is stale and can be cleared
#   1 — validator FAIL; first failing target is echoed to stdout (sanitized)
#   2 — cannot revalidate (no target identifiable / lib missing / validator missing);
#       caller must conservatively block (legacy behavior)
# Rationale: prior behavior blocked any test/commit while the marker file existed,
# even when the underlying coverage failure had already been fixed. consumer-side
# revalidate clears stale markers without weakening the discipline (real FAIL
# still blocks with target info).
revalidate_coverage_marker() {
  local marker="$1"
  local marker_basename
  marker_basename=$(basename "$marker")

  # plugin-aware validator resolution. If unavailable, fall back to legacy
  # conservative block.
  if ! command -v resolve_helper_script >/dev/null 2>&1; then
    return 2
  fi
  local validator
  validator=$(resolve_helper_script rein-validate-coverage-matrix.py 2>/dev/null || true)
  if [ -z "$validator" ] || [ ! -f "$validator" ]; then
    return 2
  fi

  case "$marker_basename" in
    .coverage-mismatch)
      # marker content: deduped lines of failed plan paths (post-edit-plan-coverage.sh).
      # Empty marker → cannot revalidate any target → conservative block.
      [ -s "$marker" ] || return 2
      local first_fail=""
      local validated_count=0
      local plan_path
      while IFS= read -r plan_path; do
        [ -z "$plan_path" ] && continue
        # If the plan file has been deleted, skip the validator call but DO NOT
        # treat the marker as healed — we have no positive PASS evidence for
        # this entry. The deleted path cannot block forever though: caller's
        # rc=2 path (returned below if no entry validated) preserves the
        # conservative block until a maintainer cleans up.
        [ -f "$plan_path" ] || continue
        validated_count=$((validated_count + 1))
        if ! "${PYTHON_RUNNER[@]}" "$validator" plan "$plan_path" >/dev/null 2>&1; then
          # Capture only the first failing path; full enumeration would
          # bloat the block message without adding actionable info.
          if [ -z "$first_fail" ]; then
            first_fail="$plan_path"
          fi
        fi
      done < "$marker"
      if [ -n "$first_fail" ]; then
        # INFO-1: sanitize before surfacing to caller (which echoes to stderr).
        sanitize_marker_path "$first_fail"
        return 1
      fi
      # Contract: rc=0 only when at least one validator invocation actually
      # PASSed. If every entry was skipped (all paths deleted), we have no
      # positive evidence and must fall through to conservative block.
      if [ "$validated_count" -eq 0 ]; then
        return 2
      fi
      return 0
      ;;
    .dod-coverage-mismatch)
      # Marker has no content (touch'd by pre-edit-dod-gate). Re-identify
      # active DoD via the shared selector and revalidate it.
      if ! command -v select_active_dod >/dev/null 2>&1; then
        return 2
      fi
      local result tier dod_path
      # selector reads trail/dod/.active-dod and walks trail/dod/ — both are
      # repo-relative, so cwd matters. Anchor to PROJECT_DIR.
      result=$(cd "$PROJECT_DIR" && select_active_dod 2>/dev/null) || return 2
      tier="${result%%$'\t'*}"
      dod_path=$(printf '%s' "$result" | awk -F'\t' '{print $2}')
      # Tier 0: no candidate. Tier 2: advisory fallback (the original Tier 1
      # active DoD that produced the marker may have been deleted/rotated).
      # Trust ONLY Tier 1 for self-heal — clearing the blocking marker based
      # on a Tier 2 fallback DoD risks healing a marker whose true source is
      # no longer identifiable.
      [ "$tier" = "1" ] || return 2
      [ -z "$dod_path" ] && return 2
      # Selector returns repo-relative path — anchor to PROJECT_DIR for
      # the on-disk check + validator invocation.
      local dod_abs="$PROJECT_DIR/$dod_path"
      [ -f "$dod_abs" ] || return 2
      if ! "${PYTHON_RUNNER[@]}" "$validator" dod "$dod_abs" >/dev/null 2>&1; then
        # INFO-1: sanitize before surfacing to caller.
        sanitize_marker_path "$dod_path"
        return 1
      fi
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# X3.B.2: Area B plan-coverage deferral — flush .plan-coverage-dirty *before*
# the legacy BLOCK_MARKERS scan so dirty entries surface as the existing
# .coverage-mismatch marker (which BLOCK_MARKERS then handles via the standard
# P2 path). design ref: docs/specs/2026-05-20-area-b-post-edit-deferral.md §5.2
# + §7 Scope ID 2 (commit-gate-flushes-plan-coverage-dirty-list-...).
#
# Returns:
#   0 — all validated entries PASSed, .processing removed
#   1 — at least one FAIL → .coverage-mismatch has the entry, .processing removed
#       (caller falls through to BLOCK_MARKERS which fires the existing P2 deny)
#   2 — cannot validate anything (deleted-only dirty list, or infra failure) →
#       caller MUST block conservatively
#
# Atomic rename protocol (§5.1.r1):
#   1. mv .plan-coverage-dirty → .plan-coverage-dirty.processing (atomic)
#   2. New post-edit appends create a fresh .plan-coverage-dirty (disjoint)
#   3. flush only reads .processing
#   4. On PASS/FAIL terminal state, .processing is removed
#   5. On crash mid-flush, .processing remains stale → next flush detects and
#      retries (no age-based GC; stale data still needs processing)
flush_plan_coverage_dirty() {
  local dirty="$PROJECT_DIR/trail/dod/.plan-coverage-dirty"
  local processing="$PROJECT_DIR/trail/dod/.plan-coverage-dirty.processing"
  local marker="$PROJECT_DIR/trail/dod/.coverage-mismatch"
  local lock_dir="$PROJECT_DIR/trail/dod/.plan-coverage-dirty.lock"
  local lock_timeout_ms=2000
  local lock_held=0

  # codex Round 1 HIGH fix — acquire the same mkdir-based mutex the
  # post-edit hook uses for its append. This serializes our `mv` with
  # concurrent post-edit appends so a writer's open()→write() window
  # cannot land in the just-renamed `.processing` inode and then be
  # removed when flush completes.
  local waited_ms=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$waited_ms" -ge "$lock_timeout_ms" ]; then
      # Lock contended beyond budget — fail-closed. A 2s window is far
      # beyond any legitimate hook execution; persistent contention almost
      # certainly means a stale lock dir from a crashed hook. Manual
      # cleanup (rmdir "$lock_dir") is required.
      echo "[rein] flush: dirty-list lock contended >${lock_timeout_ms}ms ($lock_dir). Possible stale lock from a crashed prior hook — rmdir manually if no other hook is running, then retry." >&2
      return 2
    fi
    sleep 0.05
    waited_ms=$((waited_ms + 50))
  done
  lock_held=1
  # Lock-released-on-return helper — every path below MUST release before
  # returning. We use explicit `rmdir "$lock_dir"` rather than a trap to
  # keep this readable; the few return points are clearly visible.

  # Step 1: stage everything that is currently dirty into `.processing` as a
  # single set. codex Round 2 HIGH fix — a stale `.processing` (crashed
  # prior flush) MUST NOT mask a fresh `.plan-coverage-dirty` from THIS
  # commit's invocations. We hold the lock so no concurrent append can
  # slip between the merge steps.
  #
  # Three input cases:
  #   - dirty present, processing absent          → mv dirty → processing
  #   - dirty absent,  processing present (stale) → use as-is
  #   - both present                              → append dirty into
  #     processing (preserving stale entries) then rm dirty
  #
  # In all three cases, the post-merge `.processing` is the complete set
  # of dirty paths for this flush invocation, and `.plan-coverage-dirty`
  # is absent so subsequent post-edit appends create a brand-new file.
  if [ -f "$dirty" ]; then
    if [ -f "$processing" ]; then
      # Merge fresh dirty into stale processing. Order does not matter —
      # awk dedup at Step 4 produces a unique set regardless.
      if ! cat "$dirty" >> "$processing" 2>/dev/null; then
        echo "[rein] flush: failed to merge .plan-coverage-dirty into .processing (filesystem error). Re-run after checking $DOD_DIR is writable." >&2
        [ "$lock_held" = 1 ] && rmdir "$lock_dir" 2>/dev/null
        return 2
      fi
      rm -f "$dirty"
    else
      if ! mv -f "$dirty" "$processing" 2>/dev/null; then
        # [I-flush] infra failure — fs error. Fail-closed.
        echo "[rein] flush: failed to rename .plan-coverage-dirty to .processing (filesystem error). Re-run after checking $DOD_DIR is writable." >&2
        [ "$lock_held" = 1 ] && rmdir "$lock_dir" 2>/dev/null
        return 2
      fi
    fi
  fi
  # Lock can be released as soon as the merge is complete — subsequent
  # post-edit appends now hit the fresh (recreated) `.plan-coverage-dirty`
  # and cannot interfere with our validator loop. The processing snapshot
  # we hold is closed off from further mutation.
  [ "$lock_held" = 1 ] && rmdir "$lock_dir" 2>/dev/null
  lock_held=0

  # Step 2: nothing to flush.
  [ -f "$processing" ] || return 0

  # Step 3: resolve validator (fail-closed if missing — same posture as the
  # existing revalidate_coverage_marker path).
  local validator=""
  if command -v resolve_helper_script >/dev/null 2>&1; then
    validator=$(resolve_helper_script rein-validate-coverage-matrix.py 2>/dev/null || true)
  fi
  if [ -z "$validator" ] || [ ! -f "$validator" ]; then
    echo "[rein] flush: coverage validator not found — re-run 'rein update' or restore plugin installation." >&2
    return 2
  fi

  # Step 4: read unique paths (dedup at flush time — §7 ID 2 set-equality
  # contract: validated path set == unique dirty path set).
  local unique_paths
  unique_paths=$(awk 'NF && !seen[$0]++' "$processing" 2>/dev/null)

  local first_fail=""
  local validated_count=0
  local fail_count=0
  local runtime_err_count=0
  local first_runtime_err=""
  local first_runtime_rc=""
  local plan_path
  while IFS= read -r plan_path; do
    [ -z "$plan_path" ] && continue
    # Deleted plan → skip (no positive PASS evidence accrued for this entry).
    [ -f "$plan_path" ] || continue
    validated_count=$((validated_count + 1))
    "${PYTHON_RUNNER[@]}" "$validator" "$plan_path" >/dev/null 2>&1
    local v_rc=$?
    # X3.B.5 — validator rc 의 두 부류 분리 (codex Round 1 Advisory 반영):
    #   rc 0 → PASS (validator ran cleanly, matrix valid)
    #   rc 2 → validation FAIL (validator ran cleanly, detected mismatch). 본
    #          분기는 .coverage-mismatch 에 기록 → BLOCK_MARKERS 의 P2 deny.
    #   rc != 0,2 → runtime error (Python import 실패, validator script crash,
    #          OS-level fault). 본 분기는 infra integrity 문제 — flush 전체가
    #          fail-closed (validation discipline 의 false-negative 위험).
    # 동일 flush 내에서 두 부류가 섞이면 runtime error 가 우선 — 단, FAIL 기록은
    # 다음 flush 시도를 위해 .coverage-mismatch 에 보존한다 (evidence 유지).
    case "$v_rc" in
      0)
        :
        ;;
      2)
        fail_count=$((fail_count + 1))
        mkdir -p "$(dirname "$marker")"
        if ! { [ -f "$marker" ] && grep -qxF "$plan_path" "$marker"; }; then
          # Single-line append, O_APPEND atomic (consistent with the post-edit
          # hook's append posture). The legacy revalidate path will then pick
          # this entry up as the first failing target.
          echo "$plan_path" >> "$marker"
        fi
        [ -z "$first_fail" ] && first_fail="$plan_path"
        ;;
      *)
        runtime_err_count=$((runtime_err_count + 1))
        if [ -z "$first_runtime_err" ]; then
          first_runtime_err="$plan_path"
          first_runtime_rc="$v_rc"
        fi
        ;;
    esac
  done <<< "$unique_paths"

  # Step 5: decide terminal state.
  if [ "$runtime_err_count" -gt 0 ]; then
    # X3.B.5 — runtime error 가 발생하면 flush 전체가 infra-broken. .processing
    # 은 retain (다음 commit 시 stale 로 재시도). FAIL 기록도 marker 에 이미
    # 적재돼 evidence 보존. 본 분기는 [I-flush] infra integrity 분류와 일관.
    echo "[rein] flush: validator runtime error (rc=$first_runtime_rc) on $first_runtime_err — validator subprocess failed to complete validation. Re-run 'rein update' or restore plugin installation; the dirty list ($processing) is retained for retry." >&2
    return 2
  fi
  if [ "$fail_count" -gt 0 ]; then
    # At least one FAIL recorded in .coverage-mismatch → terminal for this
    # flush. Remove .processing; the legacy BLOCK_MARKERS scan will pick up
    # .coverage-mismatch and emit P2 deny on the *first* failing target.
    rm -f "$processing"
    return 1
  fi
  if [ "$validated_count" -eq 0 ]; then
    # Conservative block: no validator was actually invoked (all paths
    # deleted). .processing retained so a future flush can retry once the
    # paths exist again (e.g., user un-deletes or fixes path).
    return 2
  fi
  # All PASS.
  rm -f "$processing"
  return 0
}

# Command patterns that gate test/commit checks. This SAME token set is
# mirrored in hooks.json `if` entries (one entry per pattern) so the script
# only spawns on these commands; here it also re-classifies for the in-script
# coverage-marker scan. `git commit` is the hard gate (spec R6).
# GMF-1: `git commit` split out of the alternation into its own canonical
# matcher — embedding the ERE inside the literal alternation would mis-order
# alternation precedence. The canonical $GIT_COMMIT_ERE skips git global
# options + multi-space and closes `commit` on a shell-token boundary.
if command_invokes "pytest|jest|vitest|mocha|npm run test|npm test|yarn test|pnpm test|python -m pytest|npx jest|npx vitest|bash tests/" \
   || command_invokes "$GIT_COMMIT_ERE"; then
  # X3.B.2: flush plan-coverage dirty list BEFORE legacy marker scan.
  flush_plan_coverage_dirty
  flush_rc=$?
  if [ "$flush_rc" -eq 2 ]; then
    # Conservative block (all-deleted dirty list, or infra failure).
    # Cannot revalidate → fail-closed. Use the same I-class exit 2 posture
    # the legacy "cannot revalidate" path uses below.
    echo "[rein] flush: coverage dirty list could not be validated (all paths deleted, infra failure, or similar). Remove stale entries from $PROJECT_DIR/trail/dod/.plan-coverage-dirty.processing manually if no longer relevant." >&2
    log_block "plan-coverage-dirty conservative block" "$COMMAND"
    exit 2
  fi
  # flush_rc == 1 (FAIL) falls through — the BLOCK_MARKERS loop below picks
  # up the newly-created .coverage-mismatch entry and emits P2 deny.
  # flush_rc == 0 (all PASS) falls through — BLOCK_MARKERS finds no marker.

  for marker in "${BLOCK_MARKERS[@]}"; do
    if [ -f "$marker" ]; then
      heal_target=$(revalidate_coverage_marker "$marker" 2>/dev/null)
      heal_rc=$?
      case "$heal_rc" in
        0)
          # Stale marker — validator now passes. Silent self-heal + continue
          # to the next marker (or fall through to remaining gates).
          rm -f "$marker"
          continue
          ;;
        1)
          # [P2] policy block — JSON deny: coverage validator FAIL (rc=1, identifiable target)
          marker_name=$(basename "$marker")
          deny_emit "The coverage check found that a plan or task record does not yet list this command's changes as implemented. Update the 'covers' list in the failing file to match what has actually been done, then re-run to clear the check automatically." "COVERAGE_MISMATCH" "$heal_target"; rc=$?
          log_block "coverage-mismatch" "$COMMAND"
          exit "$rc"
          ;;
        *)
          # [I3] infra integrity — exit 2 유지 (JSON deny 미전환): coverage marker target 식별 불가 (rc=2)
          # Cannot revalidate (no target / lib unavailable). Fall back to the
          # legacy conservative block — better to false-positive than silently
          # bypass coverage discipline.
          echo "[rein] A coverage check failure marker exists ($marker) but the target file inside it could not be identified. Fix the plan or task record so the validator can run, or remove the marker file directly if it is no longer relevant." >&2
          log_block "coverage-mismatch" "$COMMAND"
          exit 2
          ;;
      esac
    fi
  done
fi

# --- 테스트 실행은 리뷰 stamp 게이트 대상이 아님 (GUARD-1, 2026-05-19) ---
# 이전에는 pytest/jest 등 테스트 *실행* 자체를 .codex-reviewed stamp 없으면
# 차단했다. 이는 TDD red-green 루프를 구조적으로 불가능하게 만들었다 — 코드를
# 작성/리뷰하기 전에 실패하는 재현 테스트를 먼저 돌릴 수 없었다. 게이트 대상은
# *커밋/완료 선언* 이며, 그것은 바로 아래 `git commit` 게이트가 강제한다.
# 근거: need-to-confirm.md GUARD-1. coverage-matrix 마커의 pytest 차단은
# 별개 discipline 으로 위에서 그대로 유지된다.

# --- Codex 리뷰 stamp 검사 (git commit 시) ([P3]~[P6]) ---
# GMF-1: canonical $GIT_COMMIT_ERE (was literal "git commit").
if command_invokes "$GIT_COMMIT_ERE"; then
  if ! check_review_stamp "committing"; then
    exit 2
  fi
fi

# --- 커밋 메시지 포맷 검증 ([P7] / [I4] / [I5]) ---
# python3 helper 기반 (복합 명령 + heredoc + scope 지원)
# - 복합 명령에서 첫 "commit" 토큰 이후 구간만 분석 (다음 구분자 &&, ||, ;, | 전까지)
#   → 복합 명령의 tag 쪽 -m 을 오인하지 않음
# - heredoc 본문의 첫 줄을 multiline regex 로 정확히 추출
#   → $(cat <<'EOF' ... EOF) 형태 메시지도 올바로 검사됨
# - conventional commits scope 표기법 허용: type(scope)?: description
# 추출 로직 자체는 lib/extract-commit-msg.py 에 분리 (bash 의
# $(cmd <<HEREDOC) + `|| true` 파서 한계를 피하기 위함).
# GMF-1: canonical $GIT_COMMIT_ERE (was literal "git commit").
if command_invokes "$GIT_COMMIT_ERE"; then
  EXTRACT_SCRIPT="$SCRIPT_DIR/lib/extract-commit-msg.py"
  # Helper 누락은 fail-open 으로 두지 않는다. heredoc 우회와 같은 silent
  # bypass 를 막기 위해, helper 가 없거나 python3 가 동작하지 않으면 BLOCK.
  if [ ! -f "$EXTRACT_SCRIPT" ]; then
    # [I4] infra integrity — exit 2 유지 (JSON deny 미전환): 커밋 메시지 검증 helper 누락
    echo "[rein] The commit message cannot be validated because the helper script is missing (expected at: $EXTRACT_SCRIPT). Run 'rein update' to restore the missing file." >&2
    log_block "commit msg helper 누락" "$EXTRACT_SCRIPT"
    exit 2
  fi
  # python3 존재 여부는 bg_resolve_python_or_die 가 이미 gate 했다. PYTHON_RUNNER
  # 배열은 이 시점에 set 되어 있으며 strict-resolver 통과한 인터프리터이다.
  # 배열 확장 `"${PYTHON_RUNNER[@]}"` 로 token 경계를 보존해야 안전하다.
  COMMIT_MSG=$("${PYTHON_RUNNER[@]}" "$EXTRACT_SCRIPT" "$COMMAND" 2>/dev/null)
  EXTRACT_RC=$?
  if [ "$EXTRACT_RC" -ne 0 ]; then
    # [I5] infra integrity — exit 2 유지 (JSON deny 미전환): 커밋 메시지 helper 실행 실패
    echo "[rein] The commit message could not be extracted because the helper script failed (exit $EXTRACT_RC). Check that Python is working correctly and run 'rein update' if the problem persists." >&2
    log_block "commit msg helper 실패" "$EXTRACT_SCRIPT"
    exit 2
  fi

  if [ -n "$COMMIT_MSG" ]; then
    FIRST_LINE=$(printf '%s' "$COMMIT_MSG" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$FIRST_LINE" ]; then
      if ! echo "$FIRST_LINE" | grep -qE "^(feat|fix|docs|refactor|test|chore)(\([a-zA-Z0-9_-]+\))?: .+"; then
        # Co-Authored-By 라인은 면제
        if ! echo "$FIRST_LINE" | grep -qE "^Co-Authored-By:"; then
          # [P7] policy block — JSON deny
          deny_emit "The commit message does not follow Conventional Commits format. Use: <type>(<scope>)?: <description> — where type is feat|fix|docs|refactor|test|chore and scope uses only letters, digits, underscores, or hyphens." "COMMIT_MSG_FORMAT" "$FIRST_LINE"; rc=$?
          log_block "커밋 메시지 포맷 위반" "$FIRST_LINE"
          exit "$rc"
        fi
      fi
    fi
  fi
fi

exit 0
