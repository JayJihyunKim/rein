#!/bin/bash
# hooks/lib/spec-review-gate.sh
#
# Spec-review axis of the "code review" transition boundary (feature-builder-
# refactor task step 2 — 첫 전환 축(코드 리뷰) 분리). Extracted verbatim from
# pre-edit-dod-gate.sh's inline "Spec review gate" block (previously the
# ~488 lines right after the incident-review-pending check) so that when the
# v2 governance runtime takes over review-authority decisions, this whole
# judgment can be swapped out as one unit without touching the DoD-existence
# / governance-stage / routing-gate logic that stays in pre-edit-dod-gate.sh.
#
# This is a MECHANICAL move, not a rewrite: every case pattern, SR-1/SR-1.b
# tiered staleness check, and GSD-1/GSD-2 relevance-filter below is copied
# byte-for-byte from the original inline block. No decision logic changed.
#
# Companion boundary (out of scope for this file, see hooks/lib/code-review-
# gate.sh instead): the CODE-review half of pre-bash-test-commit-gate.sh's
# check_review_stamp() — this file only covers the SPEC/PLAN document review
# gate that runs at edit time, not the implementation-code review gate that
# runs at commit time. The security-review axis (also inside
# check_review_stamp()) is untouched by either extraction.
#
# Producers of the markers this function reads (unchanged by this move):
#   hooks/post-edit-spec-review-gate.sh   — writes trail/dod/.spec-reviews/
#                                            *.pending and clears *.reviewed
#                                            on a canonical spec/plan edit
#   scripts/rein-mark-spec-reviewed.sh    — writes *.reviewed after a PASS
#
# Contract for the caller (CURRENT: pre-edit-discipline-gate.sh — the
# successor to, and byte-for-byte behavioral continuation of, the
# now-deleted pre-edit-dod-gate.sh; it runs as a child of pre-edit-
# dispatcher.sh's guaranteed-sequential invocation, Phase 7 wave 3 ③-b
# round 6, 2026-08-23):
#   Source this file, then call `rein_check_spec_review_gate` with NO
#   arguments at the exact point the old inline block used to run. The
#   function reads ambient globals the caller has already established:
#     PROJECT_DIR, DOD_DIR, INBOX_DIR, FILE_PATH, PYTHON_RUNNER (array)
#   and calls `log_block` (defined locally in the caller, NOT this file —
#   a second local copy exists in pre-bash-test-commit-gate.sh; the two are
#   deliberately not shared, see that hook's own comment).
#   On a blocking outcome the function calls `exit 2` directly (exactly as
#   the original inline code did) — because it runs SOURCED into the
#   caller's own shell process, `exit` here terminates the whole hook, not
#   just the function. It never `return`s a "please exit" signal for the
#   caller to interpret.
#
# HISTORY, not current contract (Phase 7 wave 3 ③-b round 1 → round 6,
# 2026-08-14 → 2026-08-23): this file's various `REIN_GATE_PEEK_MODE`
# guards below (each with its own local "Ordering correction" / round-2
# comment, e.g. around the `.skip-spec-gate` consumption) were added so
# that pre-edit-coverage-gate.sh could safely call this same function in a
# READ-ONLY "peek" mode — see lib/incident-review-gate.sh's header for the
# full rationale and the parallel/non-deterministic-scheduling history that
# motivated it. That peek (`_rein_precheck_would_block` in pre-edit-
# coverage-gate.sh) was REMOVED at round 6 when pre-edit-dispatcher.sh
# replaced the parallel/peek model with guaranteed sequential child
# execution — coverage-gate running at all is now itself proof this gate
# already passed for the same edit, so there is nothing left to peek at.
#
# CURRENT state of every `REIN_GATE_PEEK_MODE` guard in this file: they are
# an INERT defense layer with zero live consumers (no caller sets this
# variable to "1" any more) — left in place in case a future caller
# reintroduces a same-process peek; they cost nothing while unused. Do not
# read their presence as evidence that a peek path is still exercised in
# production.
#
# All state (RUN_SPEC_GATE, SKIP_SPEC_GATE, SPEC_REVIEWS_DIR, GSD_* corpus
# vars, the _spec_*/_dod_is_active_file/_gsd_* helper functions) is local to
# this file/function — none of it was referenced anywhere else in
# pre-edit-dod-gate.sh before the move (verified: every one of these
# symbols occurred ONLY inside the block being extracted).

if [ -n "${__REIN_SPEC_REVIEW_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_SPEC_REVIEW_GATE_LOADED=1

rein_check_spec_review_gate() {
# --- Spec review gate ---
SKIP_SPEC_GATE="$PROJECT_DIR/trail/dod/.skip-spec-gate"
SPEC_REVIEWS_DIR="$PROJECT_DIR/trail/dod/.spec-reviews"

# GSD-1 / GSD-2 (dod-2026-08-05-gate-scope-defects): 표식 판정의 저장소 경계 +
# 현재 작업 관련성.
#   GSD-1 — 표식의 path= 가 이 저장소 밖을 가리키면 판정에서 제외한다 (비차단
#   경고). 타 저장소 문서 표식 유입(2026-08-04 실측 25건)이, 그 문서가 저쪽
#   세션에서 편집되는 순간 이 저장소 편집 전체를 잠갔다.
#   GSD-2 — 미리뷰/stale 로 판정된 문서가 현재 진행 중 작업과 무관하면 차단
#   대신 비차단 경고로 강등한다 (실측: 무관 문서 1건이 소스 전체 잠금 28회).
#   활성 작업이 참조하는 문서의 차단(설계→코딩 순서 강제)은 그대로 유지 —
#   게이트 계열에서 FN(놓침)이 FP(오차단)보다 나쁘다는 원칙은 "관련" 판정을
#   문자열 매칭 3형(상대경로/기준서 직접·plan ref 경유·basename)으로 넓게
#   잡는 쪽으로 반영한다.

# _spec_marker_outside_repo <path> — path 가 **증명 가능하게** 저장소 밖일 때만
# 0 반환. 증명 불가(파이썬 실패 등)는 1 — 기존대로 판정에 포함 (차단 방향
# fail-closed).
#
# 항상 물리 정규화(realpath)로 판정한다 (코드 리뷰 R2 High): 텍스트 접두사
# fast-path 는 "저장소 안 symlink 가 밖의 문서를 가리키는" 표식을 안쪽으로
# 오판해 GSD-1 이 막으려던 교차 저장소 차단을 재현시켰다 (실측). 표식은
# 문서당 1~수 개 수준이라 표식당 파이썬 1회는 수용 (판정 결과는 표식 경로
# 기준으로 단조 — 같은 경로 재판정 없음은 루프 구조가 보장).
_spec_marker_outside_repo() {
  "${PYTHON_RUNNER[@]}" -c '
import os, sys
project = os.path.realpath(sys.argv[1])
target = os.path.realpath(os.path.join(project, sys.argv[2]))
try:
    inside = os.path.commonpath([project, target]) == project
except ValueError:
    inside = False
sys.exit(0 if not inside else 1)
' "$PROJECT_DIR" "$1" 2>/dev/null
}

# _dod_is_active_file <dod_file> — 신 포맷(dod-YYYY-MM-DD-*.md) + 같은 slug 의
# inbox 완료 기록 부재 = 활성. (routing-gate 의 active 판정과 동일 규칙.)
_dod_is_active_file() {
  local dod_file="$1" fname slug inbox_file inbox_slug_val
  fname=$(basename "$dod_file")
  echo "$fname" | grep -q '^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-' || return 1
  slug=$(echo "$fname" | sed 's/^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//' | sed 's/\.md$//')
  if [ -d "$INBOX_DIR" ]; then
    for inbox_file in "$INBOX_DIR"/[0-9]*.md; do
      [ -f "$inbox_file" ] || continue
      inbox_slug_val=$(basename "$inbox_file" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
      [ "$inbox_slug_val" = "$slug" ] && return 1
    done
  fi
  return 0
}

# _spec_related_to_active_work <spec path> — 관련 = 활성 작업 기준서 본문에
# 문서 경로(상대형)나 파일명이 등장, 또는 기준서의 `plan ref:` 문서 본문에
# 등장. 결정론적 문자열 매칭만 사용 (실행·해석 없음). basename 매칭은 표식
# path= 표기(예: /private/tmp vs /tmp)가 PROJECT_DIR 접두사와 어긋나 상대형
# 매칭이 빗나가는 경우의 FN 방어 — 문서 파일명이 날짜-슬러그라 충돌이 드물고,
# 과잉 매칭은 차단 방향(안전한 쪽) 오차다.
#
# 비용 (코드 리뷰 R1 Medium): 활성 DoD 본문 + plan ref 문서 본문을 **1회만**
# 수집해 말뭉치로 캐시한다 — 표식마다 DoD×inbox 를 재스캔하던 O(N×D×I) 를
# 표식당 grep 2회로 줄인다. plan ref 값은 **첫 공백 전 토큰만** 경로로 쓴다
# (R1 High: `plan ref: docs/plans/foo.md §4.2` 처럼 절 표기·설명이 붙는 실전
# 표기가 경로 조립을 깨 관련 문서를 무관으로 강등시켰다).
GSD_RELATED_CORPUS=""
GSD_RELATED_CORPUS_BUILT=false
# 말뭉치에 DoD 1개 + 그 plan ref 문서들을 추가.
_gsd_corpus_add_dod() {
  local dod_file="$1" plan_ref plan_path
  [ -f "$dod_file" ] || return 0
  GSD_RELATED_CORPUS+=$(cat "$dod_file" 2>/dev/null)$'\n'
  while IFS= read -r plan_ref; do
    [ -n "$plan_ref" ] || continue
    plan_path="$plan_ref"
    case "$plan_path" in /*) ;; *) plan_path="$PROJECT_DIR/$plan_path" ;; esac
    [ -f "$plan_path" ] || continue
    GSD_RELATED_CORPUS+=$(cat "$plan_path" 2>/dev/null)$'\n'
  done < <(grep -E '^[[:space:]*-]*plan ref:' "$dod_file" 2>/dev/null \
           | sed -e 's/^[[:space:]*-]*plan ref:[[:space:]]*//' \
                 -e 's/^`//' -e 's/[[:space:]].*$//' -e 's/`$//')
}
# 관련성의 기준 (코드 리뷰 R2 High): "현재 선택된 작업" 이다 — 선택기
# (select_active_dod)가 특정한 기준서 1개(+그 plan ref 문서)만 말뭉치로
# 쓴다. 선택기가 특정하지 못하면(계층 0 — 후보 부재/레거시 포맷) 전 활성
# 기준서로 폴백한다 — 어느 활성 작업의 문서인지 알 수 없는 상태에서 좁게
# 잡으면 관련 문서 차단을 놓치는 FN 방향이 되기 때문 (게이트 원칙: FN > FP).
_gsd_build_related_corpus() {
  [ "$GSD_RELATED_CORPUS_BUILT" = true ] && return 0
  GSD_RELATED_CORPUS_BUILT=true
  local sad_line sad_tier sad_path dod_file
  sad_line=$(cd "$PROJECT_DIR" && select_active_dod 2>/dev/null) || sad_line=""
  sad_tier=$(printf '%s' "$sad_line" | cut -f1)
  sad_path=$(printf '%s' "$sad_line" | cut -f2)
  if [ -n "$sad_path" ] && [ "$sad_tier" != "0" ]; then
    case "$sad_path" in /*) ;; *) sad_path="$PROJECT_DIR/$sad_path" ;; esac
    if [ -f "$sad_path" ]; then
      _gsd_corpus_add_dod "$sad_path"
      return 0
    fi
  fi
  for dod_file in "$DOD_DIR"/dod-[0-9]*.md; do
    [ -f "$dod_file" ] || continue
    _dod_is_active_file "$dod_file" || continue
    _gsd_corpus_add_dod "$dod_file"
  done
}
_spec_related_to_active_work() {
  local spec_abs="$1" spec_rel spec_base
  spec_rel="${spec_abs#"$PROJECT_DIR"/}"
  spec_base=$(basename "$spec_abs")
  _gsd_build_related_corpus
  printf '%s' "$GSD_RELATED_CORPUS" | grep -qF -- "$spec_rel" && return 0
  printf '%s' "$GSD_RELATED_CORPUS" | grep -qF -- "$spec_base" && return 0
  return 1
}

# 미해결 문서를 관련성에 따라 차단/경고 목록으로 분류해 기록.
GSD_BLOCKING_SPECS=""
GSD_WARN_SPECS=""
GSD_OUTSIDE_MARKERS=""
_record_unresolved_spec() {
  if _spec_related_to_active_work "$1"; then
    GSD_BLOCKING_SPECS="${GSD_BLOCKING_SPECS}${1}"$'\n'
  else
    GSD_WARN_SPECS="${GSD_WARN_SPECS}${1}"$'\n'
  fi
}

# stderr 로 나가는 표식 유래 값 소독 (제어문자 제거 + 길이 상한 — 기존
# _spec_gen_sanitize 와 동일 원칙).
_gsd_sanitize() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200; }

# M1 (2026-06-16): decide whether to run the spec gate this edit.
# Default: run iff the .spec-reviews dir exists (gate is active).
#
# .skip-spec-gate is advertised as a ONE-SHOT bypass but the old entry test
# (`[ ! -f "$SKIP_SPEC_GATE" ]`) only *checked* the marker and never removed
# it, so it became a permanent off-switch — every edit skipped the gate until
# the file was hand-deleted (root cause: no rm -f, unlike .skip-stop-gate which
# is consumed on match in stop-session-gate.sh). Fix: when the marker is present
# AND the gate is active, CONSUME it (rm -f) before skipping, then verify the
# removal. fail-closed — if removal can't be proven (a remaining dir or any
# non-regular path: fifo/socket/device), do NOT honor the bypass: run the gate
# normally. This prevents an un-removable marker from reinstating the
# permanent-bypass bug.
RUN_SPEC_GATE=false
if [ -d "$SPEC_REVIEWS_DIR" ]; then
  RUN_SPEC_GATE=true
  if [ -e "$SKIP_SPEC_GATE" ]; then
    # Consume the one-shot marker, then branch on whether removal is PROVEN.
    # Proof uses `! -e` (not `! -f && ! -d`): a remaining non-regular path
    # (fifo/socket/device/dir) must also count as "not consumed" → fail-closed,
    # else such a marker would reinstate the permanent-bypass bug (codex R1 High).
    #
    # REIN_GATE_PEEK_MODE 가드 (Phase 7 wave 3 ③-b code review round 1): peek
    # (coverage-gate 의 precheck)는 이 1회성 마커를 실제로 소비하면 안 된다 —
    # 병렬·순서 비보장 훅 실행에서 peek 가 먼저 뛰면 진짜(enforcing) 호출보다
    # 먼저 마커를 지워버려 나중에 도는 집행 훅이 바이패스를 못 보고 사용자가
    # 승인한 편집을 차단할 수 있다. peek 모드에서는 제거를 생략한다 — 그러면
    # 아래 "제거 증명" 검사가 실패해 기존에도 있던 fail-closed(게이트 유지)
    # 방향으로 떨어진다(안전한 쪽. rm 실패든 peek 의 의도적 생략이든 판정
    # 분기는 동일하게 처리된다).
    if [ "${REIN_GATE_PEEK_MODE:-0}" != "1" ]; then
      rm -f "$SKIP_SPEC_GATE" 2>/dev/null || true
    fi
    if [ ! -e "$SKIP_SPEC_GATE" ]; then
      RUN_SPEC_GATE=false   # marker truly consumed → skip the gate this once
      _bypass_msg="skip-spec-gate consumed (one-shot spec-review bypass)"
    else
      # removal not proven → fail-closed: gate stays enforced (RUN_SPEC_GATE=true)
      _bypass_msg="skip-spec-gate consume_failed; fail_closed (gate enforced)"
    fi
    # Audit the actual outcome — log AFTER the result is known so a fail-closed
    # path never records a false "consumed" (codex R1 Medium, honest-audit model).
    # fail-soft: logging must never abort the hook.
    #
    # REIN_GATE_PEEK_MODE 가드 (Phase 7 wave 3 ③-b code review round 2,
    # Medium — 재현 완료): round 1 은 바로 위 `rm -f` 만 peek 가드로 감쌌지만,
    # 이 mkdir+append 는 무조건 실행됐다 — peek(코드 리뷰의 정확한 재현
    # 조건: coverage-gate 단독 실행)도 이 감사 로그에 실제 줄을 하나 남겼다.
    # 서브셸은 진짜 파일 쓰기를 되돌릴 수 없다 — `rm -f` 를 못 되돌리는 것과
    # 정확히 같은 이유로, 이 append 도 peek 에서는 절대 일어나면 안 된다
    # ("peek 는 판정만 하고 절대 변이하지 않는다"는 계약을 이 소비 블록
    # 전체로 완결한다). peek 모드에서는 로그 기록 자체를 생략한다 — 판정
    # 결과(_bypass_msg, RUN_SPEC_GATE)에는 영향 없다.
    if [ "${REIN_GATE_PEEK_MODE:-0}" != "1" ]; then
      BYPASS_LOG="$PROJECT_DIR/trail/incidents/auto-mode-bypass.log"
      mkdir -p "$(dirname "$BYPASS_LOG")" 2>/dev/null || true
      # Match the existing writer to this same log (lib/auto-mode.sh) — both use
      # `date -u +%FT%TZ` so the shared audit file keeps one timestamp format.
      printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$_bypass_msg" \
        >> "$BYPASS_LOG" 2>/dev/null || true
    fi
  fi
fi

if [ "$RUN_SPEC_GATE" = true ]; then
  UNRESOLVED_SPECS=false
  # Strict ISO 8601 shape shared by SR-1 (.pending vs .reviewed compare) and
  # SR-1.b (orphan .reviewed vs spec mtime compare). Both rein writers use
  # `date -u +%Y-%m-%dT%H:%M:%S` (UTC, no offset); the legacy healer's
  # trailing `Z` is stripped before matching.
  spec_iso_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'
  for pending_marker in "$SPEC_REVIEWS_DIR"/*.pending; do
    [ -f "$pending_marker" ] || continue

    spec_path=$(grep -E '^path=' "$pending_marker" 2>/dev/null | head -1 | sed 's/^path=//')
    [ -z "$spec_path" ] && continue

    # GSD-1: 타 저장소 문서 표식은 이 저장소의 판정 대상이 아니다 — 제외 후
    # 아래에서 비차단 경고 1회.
    if _spec_marker_outside_repo "$spec_path"; then
      GSD_OUTSIDE_MARKERS="${GSD_OUTSIDE_MARKERS}${pending_marker}"$'\n'
      continue
    fi

    # spec 파일이 아직 존재하는지 확인
    if [ ! -f "$spec_path" ]; then
      continue
    fi

    # 리뷰 완료 마커가 있는지 확인 (hash.reviewed)
    hash_val=$(basename "$pending_marker" .pending)
    reviewed_marker="$SPEC_REVIEWS_DIR/${hash_val}.reviewed"
    if [ ! -f "$reviewed_marker" ]; then
      _record_unresolved_spec "$spec_path"
      continue
    fi

    # SR-1: existence alone is not enough — a spec re-edited after its review
    # re-creates .pending whose created= is newer than .reviewed's reviewed=,
    # while the old .reviewed lingers (review-bypass). Compare the two rein-
    # written timestamps. Strict ISO 8601 shape — a missing OR garbled
    # timestamp (e.g. `created=0000`, which would sort below a valid reviewed=
    # and slip past a bare lexical compare) cannot prove freshness →
    # fail-closed. After shape validation both are fixed-width, so a
    # digit-only numeric compare is locale-independent (avoids bash `[[ > ]]`
    # collation). Backstops the post-edit gate's .reviewed removal and
    # catches a stale state already on disk.
    pending_created=$(grep -E '^created=' "$pending_marker" 2>/dev/null | head -1 | sed -e 's/^created=//' -e 's/Z$//')
    reviewed_at=$(grep -E '^reviewed=' "$reviewed_marker" 2>/dev/null | head -1 | sed -e 's/^reviewed=//' -e 's/Z$//')
    if ! [[ "$pending_created" =~ $spec_iso_re ]] || ! [[ "$reviewed_at" =~ $spec_iso_re ]]; then
      _record_unresolved_spec "$spec_path"   # missing/garbled timestamp → fail-closed
      continue
    fi
    if [ "${pending_created//[!0-9]/}" -gt "${reviewed_at//[!0-9]/}" ]; then
      _record_unresolved_spec "$spec_path"   # spec edited after review → stale review
      continue
    fi
  done

  # SR-1.b: orphan .reviewed backstop. SR-1's freshness check only fires
  # when a .pending sibling exists. If the post-edit hook fails to fire
  # (hooks disabled, external IDE write, `git checkout` restoring the spec,
  # MultiEdit JSON parse failure → exit 0) the new .pending is never
  # created. The old .reviewed lingers as an orphan and the loop above
  # never runs for that hash → source edits proceed with unreviewed spec
  # changes. Pre-existing trust boundary (.pending-keyed), not a new gap
  # from SR-1. Mitigation: iterate orphan .reviewed markers (no matching
  # .pending) and decide staleness by CONTENT (see the tiered logic below).
  # The original mtime compare (R1 risk, "accepted" in an earlier revision)
  # produced real false-positives — checkout/cherry-pick/rotation bump mtime
  # without changing content — so it was replaced (SR-1.b-MTIME-FP).
  # GSD-2: 차단이 이미 확정된 경우에만 orphan 스캔을 생략한다 (성능 —
  # 어차피 차단되고, orphan 스캔은 표식당 파이썬 해시 비용이 든다).
  if [ -z "$GSD_BLOCKING_SPECS" ]; then
    # SR-1.b-MTIME-FP fix (codex Mode B "tightened A", 2026-05-29): the orphan
    # backstop previously compared the spec's filesystem mtime against
    # reviewed=, but git checkout / cherry-pick / rotation bump mtime WITHOUT
    # changing content → false "stale" → unrelated source edits chain-blocked
    # (2026-05-29 incident: 25 dev-only docs). Decide staleness by CONTENT
    # (content_sha anchor), with a git committer-time fallback restricted to
    # retrospective/healer markers (whose origin is knowable), and the legacy
    # mtime path only for non-retro / non-git markers.
    #
    # 2026-05-31 follow-up: also recognise the `retrospective-cherry-pick-mtime-fp*`
    # provenance class. Those markers were deliberately re-stamped on 2026-05-29
    # to absorb exactly this mtime FP, but were previously unrecognised and fell
    # to the mtime path — so the FP they were meant to fix still fired. Routing
    # them through the committer-time tier clears the mtime FP SOUNDLY: plain
    # checkout / branch-switch / rotation bump only the filesystem mtime, NOT
    # committer-time, so a spec committed before review reads as fresh; while a
    # genuine post-review commit (or a spec cherry-picked/integrated after
    # review) has committer-time > reviewed and is still blocked (no
    # false-negative). committer-time — not author-time — is the sound signal:
    # author-time would wrongly allow a pre-review-authored commit that was only
    # integrated into this branch AFTER review (its content was never reviewed).
    #
    # git work-tree detection, computed once. Sanitized per BC-INFO1 class so a
    # poisoned GIT_DIR/GIT_WORK_TREE cannot redirect discovery to a decoy repo.
    SR1B_GIT_WORKTREE=false
    if [ "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
            git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
      SR1B_GIT_WORKTREE=true
    fi
    for reviewed_marker in "$SPEC_REVIEWS_DIR"/*.reviewed; do
      [ -f "$reviewed_marker" ] || continue

      hash_val=$(basename "$reviewed_marker" .reviewed)
      # Skip if a matching .pending exists — that path is handled by the
      # SR-1 branch above and we must not double-count or apply the orphan
      # semantics (which would override SR-1's content-timestamp logic).
      if [ -f "$SPEC_REVIEWS_DIR/${hash_val}.pending" ]; then
        continue
      fi

      spec_path=$(grep -E '^path=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^path=//')
      [ -z "$spec_path" ] && continue

      # GSD-1: 타 저장소 문서 표식 제외 (pending 루프와 동일).
      if _spec_marker_outside_repo "$spec_path"; then
        GSD_OUTSIDE_MARKERS="${GSD_OUTSIDE_MARKERS}${reviewed_marker}"$'\n'
        continue
      fi

      # Deleted spec → skip (matches existing test_gate_ignores_deleted_spec).
      [ -f "$spec_path" ] || continue

      reviewed_at=$(grep -E '^reviewed=' "$reviewed_marker" 2>/dev/null | head -1 | sed -e 's/^reviewed=//' -e 's/Z$//')
      if ! [[ "$reviewed_at" =~ $spec_iso_re ]]; then
        _record_unresolved_spec "$spec_path"    # missing/garbled timestamp → fail-closed
        continue
      fi

      content_sha_stored=$(grep -E '^content_sha=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^content_sha=//')

      if [ -n "$content_sha_stored" ]; then
        # TIER 1 — content hash anchor (strict, FP-free + FN-safe). Byte hash of
        # the spec NOW vs the hash recorded at review. Immune to mtime / checkout
        # / cherry-pick / rotation; catches any committed OR uncommitted edit.
        spec_sha_now=$("${PYTHON_RUNNER[@]}" -c '
import hashlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        print(hashlib.sha256(f.read()).hexdigest())
except Exception:
    sys.exit(1)
' "$spec_path" 2>/dev/null) || {
          _record_unresolved_spec "$spec_path"   # unreadable spec → fail-closed
          continue
        }
        if [ "$spec_sha_now" != "$content_sha_stored" ]; then
          _record_unresolved_spec "$spec_path"   # content changed since review → stale
          continue
        fi
        continue                  # content unchanged → not stale
      fi

      # No content anchor (legacy marker). reviewed_epoch is needed by both
      # remaining tiers. fromisoformat parses naive ISO 8601 (no offset);
      # anchor to UTC since the writer uses `date -u`.
      reviewed_epoch=$("${PYTHON_RUNNER[@]}" -c '
import sys
from datetime import datetime, timezone
try:
    dt = datetime.fromisoformat(sys.argv[1]).replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    sys.exit(1)
' "$reviewed_at" 2>/dev/null) || {
        _record_unresolved_spec "$spec_path"   # malformed reviewed= despite regex pass → fail-closed
        continue
      }

      # Provenance gate for the git fallback: deliberate retrospective / healer
      # markers have a knowable origin, so a git author-time heuristic is
      # acceptable for them — but NOT for arbitrary contentless markers, whose
      # reviewed content is unknowable (codex Mode B: do not broadly bless).
      # Recognised provenance classes (each a deliberate, auditable namespace —
      # a normal review writes reviewer=codex/sonnet/… which never matches):
      #   - retrospective-shipped*              release-shipped / healer specs
      #   - retrospective-cherry-pick-mtime-fp* legacy markers re-stamped to
      #                                         absorb a checkout/cherry-pick
      #                                         mtime false-positive
      #   - mechanism=rein-heal-legacy-pending  legacy-pending healer
      reviewer_val=$(grep -E '^reviewer=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^reviewer=//')
      mechanism_val=$(grep -E '^mechanism=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^mechanism=//')
      is_retro=false
      case "$reviewer_val" in
        retrospective-shipped*|retrospective-cherry-pick-mtime-fp*) is_retro=true ;;
      esac
      [ "$mechanism_val" = "rein-heal-legacy-pending" ] && is_retro=true

      if [ "$is_retro" = true ] && [ "$SR1B_GIT_WORKTREE" = true ]; then
        # TIER 2 — constrained git committer-time fallback (retrospective only).
        # SOUND (no false-negative): a clean work-tree means the current content
        # IS the last commit touching the spec; committer-time ≤ reviewed means
        # that commit was integrated into THIS branch's history before review,
        # so its content was present at review time. Any post-review content
        # change is either a new commit (committer-time = now > reviewed → block)
        # or uncommitted (dirty → blocked just above). Plain checkout / branch
        # switch / rotation bump only the filesystem mtime, NOT committer-time,
        # so this tier clears the mtime false-positive without under-blocking.
        # A spec genuinely cherry-picked/integrated AFTER review has
        # committer-time = the integration moment > reviewed and is
        # conservatively blocked (we cannot prove the integrated content was the
        # reviewed content) — intended. NB: committer-time, not author-time —
        # author-time would wrongly allow a pre-review-authored commit that was
        # only integrated after review.
        rel_spec="${spec_path#"$PROJECT_DIR"/}"
        # Confirm the path is tracked (git log history alone is not proof).
        if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
             git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$rel_spec" >/dev/null 2>&1; then
          _record_unresolved_spec "$spec_path"   # untracked retro spec → cannot verify → fail-closed
          continue
        fi
        # Uncommitted working-tree change → cannot prove freshness → stale.
        if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
             git -C "$PROJECT_DIR" diff --quiet HEAD -- "$rel_spec" >/dev/null 2>&1; then
          _record_unresolved_spec "$spec_path"   # dirty → stale
          continue
        fi
        spec_commit_epoch=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
          git -C "$PROJECT_DIR" log -1 --format=%ct -- "$rel_spec" 2>/dev/null)
        if ! [[ "$spec_commit_epoch" =~ ^[0-9]+$ ]]; then
          _record_unresolved_spec "$spec_path"   # no commit history → fail-closed
          continue
        fi
        if [ "$spec_commit_epoch" -gt "$reviewed_epoch" ]; then
          _record_unresolved_spec "$spec_path"   # committed/integrated after review → cannot prove → stale
          continue
        fi
        continue                  # integrated before review, clean → content present at review
      fi

      # TIER 3 — mtime fallback (non-retrospective marker, or non-git project).
      # Preserves the pre-fix behavior where there is no checkout/cherry-pick FP
      # source; such markers migrate to TIER 1 on their next review. Python
      # getmtime avoids GNU vs BSD `stat` divergence; any failure is fail-closed.
      spec_mtime_epoch=$("${PYTHON_RUNNER[@]}" -c '
import os, sys
try:
    print(int(os.path.getmtime(sys.argv[1])))
except Exception:
    sys.exit(1)
' "$spec_path" 2>/dev/null) || {
        _record_unresolved_spec "$spec_path"   # unreadable mtime → fail-closed
        continue
      }
      if [ "$spec_mtime_epoch" -gt "$reviewed_epoch" ]; then
        _record_unresolved_spec "$spec_path"   # spec touched after review (legacy heuristic) → stale
        continue
      fi
    done
  fi

  # DOD-GATE-FP-TESTS (2026-05-29, incident 351623296a9bc1d8): the spec gate
  # blocks GLOBALLY on any unreviewed spec without consulting FILE_PATH. That
  # also blocked test files (tests/**), breaking reproduction-first / TDD
  # red-green — editing a failing test is the FIRST step of a fix, and the
  # test cannot touch real source, so it is no review-bypass. Exempt edits
  # whose target resolves under PROJECT_DIR/tests/. The containment check is
  # done in Python (normpath + commonpath) so an absolute OR repo-relative
  # FILE_PATH is handled, and a mere `tests` substring elsewhere (e.g.
  # src/tests-helper.ts) is NOT exempted. PYTHON_RUNNER is populated above;
  # a failure here falls through to the original block (fail-closed).
  # GSD-1: 저장소 밖 표식 — 판정 제외 사실을 비차단 경고로 알린다 (표식 파일은
  # 삭제하지 않는다 — 파일 파괴는 이 게이트의 권한 밖, 정리는 사람 판단).
  if [ -n "$GSD_OUTSIDE_MARKERS" ]; then
    while IFS= read -r _gsd_m; do
      [ -n "$_gsd_m" ] || continue
      _gsd_mp=$(_gsd_sanitize "$(grep -E '^path=' "$_gsd_m" 2>/dev/null | head -1 | sed 's/^path=//')")
      echo "WARNING: [dod-gate] spec-review marker points outside this repository — ignored for gating: $(basename -- "$_gsd_m") (path=$_gsd_mp). If it belongs to another repository, remove the marker file from trail/dod/.spec-reviews/." >&2
    done <<< "$(printf '%s' "$GSD_OUTSIDE_MARKERS" | sort -u)"
  fi

  # GSD-2: 무관 문서의 미리뷰/stale — 차단하지 않고 경고로 가시성만 유지.
  if [ -n "$GSD_WARN_SPECS" ]; then
    while IFS= read -r _gsd_s; do
      [ -n "$_gsd_s" ] || continue
      echo "WARNING: [dod-gate] unreviewed/stale design document (not referenced by any active task record — not blocking this edit): $(_gsd_sanitize "$_gsd_s"). Review it before starting work that implements it (/codex-review)." >&2
    done <<< "$(printf '%s' "$GSD_WARN_SPECS" | sort -u)"
  fi

  UNRESOLVED_SPECS=false
  FIRST_BLOCKING_SPEC=""
  if [ -n "$GSD_BLOCKING_SPECS" ]; then
    UNRESOLVED_SPECS=true
    FIRST_BLOCKING_SPEC=$(printf '%s' "$GSD_BLOCKING_SPECS" | head -1)
  fi

  if [ "$UNRESOLVED_SPECS" = true ]; then
    if "${PYTHON_RUNNER[@]}" -c '
import os, sys
project = os.path.realpath(sys.argv[1])
tests_root = os.path.join(project, "tests")
target = os.path.realpath(os.path.join(project, sys.argv[2]))
try:
    inside = os.path.commonpath([tests_root, target]) == tests_root
except ValueError:
    inside = False
sys.exit(0 if inside else 1)
' "$PROJECT_DIR" "$FILE_PATH" 2>/dev/null; then
      echo "NOTICE: spec review gate skip — test file ($FILE_PATH) under tests/ is exempt from the unreviewed-spec block (reproduction-first / TDD)." >&2
      UNRESOLVED_SPECS=false
    fi
  fi

  if [ "$UNRESOLVED_SPECS" = true ]; then
    echo "[rein] A design document referenced by the active task record has not been reviewed yet. To proceed:" >&2
    echo "  1) Review the design document (/codex-review, or the spec-writer auto-review path)." >&2
    echo "  2) On PASS, mark it reviewed:" >&2
    echo "     bash <scripts-dir>/rein-mark-spec-reviewed.sh \"$(_gsd_sanitize "$FIRST_BLOCKING_SPEC")\" codex" >&2
    echo "     (scripts-dir = \${CLAUDE_PLUGIN_ROOT}/scripts/ on plugin install, \${PROJECT_DIR}/scripts/ on maintainer repo)" >&2
    log_block "미리뷰 사양 문서" "$FILE_PATH"
    exit 2
  fi
fi
}
