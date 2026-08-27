#!/bin/bash
# hooks/lib/routing-gate.sh
#
# Routing axis of the precondition chain pre-edit-dod-gate.sh owns before it
# ever reaches the DoD-existence / coverage branch (dod-gate fix cycle,
# 2026-08-14 — coverage-gate precondition-awareness). Extracted verbatim
# from pre-edit-dod-gate.sh's inline "BEGIN routing-gate ... END
# routing-gate" block (the '## 라우팅 추천' section presence + approved_by_
# user: true enforcement, plus the M4 spec-review-generator fail-open check
# bundled inside that same marked region in the original source) so that
# pre-edit-coverage-gate.sh can independently re-derive "is this currently
# blocking" WITHOUT hand-copying the marker-glob / approval-parsing decision
# tree into a second location that could silently drift from this one (the
# same rationale lib/dod-found.sh and lib/source-path-classify.sh already
# established for their own predicates).
#
# This is a MECHANICAL move, not a rewrite: every case (missing-section glob
# block, M4 spec-review-gen-failed conservative block, approved_by_user
# parsing, both one-shot bypasses) is copied byte-for-byte from the original
# inline block, including its internal "BEGIN/END routing-gate" grouping —
# that boundary is the original author's own unit of extraction, so this
# move does not re-decompose it. No decision logic changed.
#
# Contract for the caller (CURRENT: pre-edit-discipline-gate.sh, the
# ENFORCING caller — the successor to, and byte-for-byte behavioral
# continuation of, the now-deleted pre-edit-dod-gate.sh; it runs as a child
# of pre-edit-dispatcher.sh's guaranteed-sequential invocation, Phase 7
# wave 3 ③-b round 6, 2026-08-23):
#   Source this file, then call `rein_check_routing_gate` with NO arguments
#   at the exact point the old inline block used to run. The function reads
#   ambient globals the caller has already established:
#     DOD_DIR, INBOX_DIR, FILE_PATH
#   and calls `log_block` (defined locally in the caller — see
#   lib/incident-review-gate.sh's header for why this is never shared).
#   On a blocking outcome the function calls `exit 2` directly — because it
#   runs SOURCED into the caller's own shell process, `exit` here terminates
#   the whole hook, not just the function. It never `return`s a "please
#   exit" signal.
#
# HISTORY, not current contract (Phase 7 wave 3 ③-b round 1 → round 6,
# 2026-08-14 → 2026-08-23) — kept for the record, but the "READ-ONLY
# peeking caller" described below no longer exists in production. See
# lib/incident-review-gate.sh's header for the full parallel history (same
# pattern applied here verbatim: subshell + locally neutralized `log_block`)
# and for why it was REMOVED at round 6 when pre-edit-dispatcher.sh replaced
# the parallel/peek model with guaranteed sequential child execution —
# coverage-gate running at all is now itself proof this gate already passed
# for the same edit, so there is nothing left to peek at.
#
# Ordering correction (round 1, historical): an earlier revision of this
# paragraph claimed the one-shot ROUTING_BYPASS / SPEC_GEN_BYPASS markers
# were safe to mutate here because "hooks.json lists pre-edit-dod-gate.sh
# (now pre-edit-discipline-gate.sh) BEFORE this hook in the same PreToolUse
# matcher group, so any such bypass has already been consumed ... by the
# time this precheck runs". That was false at the time: Claude Code ran
# every hook matched to the same event IN PARALLEL with "the order ...
# non-deterministic" (hooks guide) — hooks.json's listed order was a
# configuration-array ordering, not an execution schedule. A peek that
# happened to win that race would have consumed the user's one-shot bypass
# for real before the enforcing hook ever saw it, causing that hook to then
# block an edit the user had just approved. The round-1 fix guarded the
# three `rm -f` sites below (two ROUTING_BYPASS branches + the
# SPEC_GEN_BYPASS branch) with `REIN_GATE_PEEK_MODE` (set by the peek
# caller — pre-edit-coverage-gate.sh's `_rein_precheck_would_block`) so
# calling this function from a peek reproduced the exact same judgment
# without ever performing the mutation for real.
#
# CURRENT state of the `REIN_GATE_PEEK_MODE` guards below: they are an
# INERT defense layer with zero live consumers (no caller sets this
# variable to "1" any more — the peek that used to set it was deleted at
# round 6) — left in place in case a future caller reintroduces a
# same-process peek; they cost nothing while unused. Do not read their
# presence as evidence that a peek path is still exercised in production.
#
# All state (ROUTING_BYPASS, ACTIVE_DODS, MISSING_MARKERS,
# SPEC_GEN_BYPASS, SPEC_GEN_MARKER, ROUTING_VIOLATIONS, the
# _spec_gen_sanitize helper) is local to this file/function — none of it was
# referenced anywhere else in pre-edit-dod-gate.sh before the move (every
# one of these symbols occurred ONLY inside the block being extracted).

if [ -n "${__REIN_ROUTING_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_ROUTING_GATE_LOADED=1

rein_check_routing_gate() {
# BEGIN routing-gate
# DoD 의 '## 라우팅 추천' 섹션 + approved_by_user: true 검증.
# active DoD (= 신포맷 dod 파일 존재 AND 같은 slug inbox 파일 없음) 전체를 검사.
# 섹션 있으면서 approved_by_user 가 누락/false 인 경우 BLOCK. 섹션 아예 없는 경우도 BLOCK.
#
# 바이패스: trail/dod/.skip-routing-gate 마커 (reason 기록 후 1회 사용 → 자동 삭제)
ROUTING_BYPASS="$DOD_DIR/.skip-routing-gate"
# active DoD 목록은 (b) 섹션(approved_by_user 검사)에서 bash 배열
# (ACTIVE_DODS)로 수집한다 — 이 값이 왜 임시파일이 아니라 배열인지는 (b)
# 섹션 진입 직전 주석에 전체 history(round 2/3/4)가 정리되어 있다.
# (a) 신규 DoD 섹션 누락 차단: post-edit-dod-routing-check.sh 가 DoD 작성 시
#     '## 라우팅 추천' 섹션 없으면 .routing-missing-<basename> 마커를 남긴다.
#     마커가 있으면 바로 BLOCK. legacy DoD 는 post-write 이전에 작성된 것이라 마커 없음.
shopt -s nullglob
MISSING_MARKERS=("$DOD_DIR"/.routing-missing-*)
shopt -u nullglob
if [ "${#MISSING_MARKERS[@]}" -gt 0 ]; then
  if [ -f "$ROUTING_BYPASS" ]; then
    REASON=$(grep '^reason=' "$ROUTING_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")
    echo "WARNING: routing gate 1회성 바이패스 (missing section) — reason: $REASON" >&2
    log_block "routing missing section bypass" "$FILE_PATH"
    # REIN_GATE_PEEK_MODE 가드: peek 는 이 1회성 마커를 실제로 소비하면 안 된다
    # (파일 헤더의 "Ordering correction" 절 참조 — enforcing 호출만 소비).
    [ "${REIN_GATE_PEEK_MODE:-0}" = "1" ] || rm -f "$ROUTING_BYPASS"
  else
    echo "[rein] The following task records are missing the '## 라우팅 추천' routing section:" >&2
    for m in "${MISSING_MARKERS[@]}"; do
      echo "  - $(basename -- "$m" | sed 's/^\.routing-missing-//')" >&2
    done
    echo "  Add a '## 라우팅 추천' section to the task record with fields: agent / skills / mcps / rationale / approved_by_user." >&2
    echo "  The PostToolUse hook will inject the routing procedure body after the task record is saved." >&2
    echo "  Emergency bypass: echo 'reason=<reason>' > $ROUTING_BYPASS" >&2
    log_block "routing section missing" "$FILE_PATH"
    exit 2
  fi
fi

# (a2) M4 (2026-06-16): spec-review 생성기 fail-open 차단.
#      post-edit-spec-review-gate.sh 가 python 미해결 / JSON 파싱 실패 시
#      (편집된 spec 경로를 알 수 없으므로) generic 보수 마커
#      .spec-review-gen-failed 를 남긴다. 마커가 있으면 미상 spec 변경이
#      미리뷰 상태일 수 있으므로 보수적으로 차단한다. routing-missing
#      glob-block 패턴(위 (a))과 동형이되 별도 마커/바이패스를 쓰므로 routing
#      분기를 침범하지 않는다.
#
# 데드락 탈출구: trail/dod/.skip-spec-gen-gate 마커 (reason 기록 후 1회 사용
#      → 즉시 rm -f 소비, M1 .skip-spec-gate consume-on-use 와 일관).
SPEC_GEN_BYPASS="$DOD_DIR/.skip-spec-gen-gate"
SPEC_GEN_MARKER="$DOD_DIR/.spec-review-gen-failed"
# Sanitize untrusted marker field values before echoing to stderr — strip
# control chars (incl. terminal escapes that could spoof the log/terminal) and
# cap length. Mirrors pre-bash-test-commit-gate.sh sanitize_marker_path
# (2026-06-16 통합 보안리뷰 INFO-2).
_spec_gen_sanitize() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200; }
if [ -e "$SPEC_GEN_MARKER" ]; then
  if [ -e "$SPEC_GEN_BYPASS" ]; then
    SPEC_GEN_REASON=$(_spec_gen_sanitize "$(grep '^reason=' "$SPEC_GEN_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")")
    # consume-on-use + 제거 증명 (M1 .skip-spec-gate 와 일관, 통합 보안리뷰 INFO-1):
    # rm 후 `[ ! -e ]` 로 실제 제거를 증명해야 1회 통과를 허용한다. 제거 불가
    # (디렉토리/특수파일 등)면 fail-closed — un-removable 바이패스가 영구 우회로
    # 굳는 것을 막는다.
    #
    # REIN_GATE_PEEK_MODE 가드: peek 는 이 1회성 마커를 실제로 소비하면 안 된다
    # (파일 헤더의 "Ordering correction" 절 참조). peek 모드에서 제거를
    # 생략하면 아래 "제거 증명" 검사가 그대로 기존 fail-closed 방향(게이트
    # 유지)으로 떨어진다 — un-removable 케이스와 동일한 안전한 분기 재사용.
    if [ "${REIN_GATE_PEEK_MODE:-0}" != "1" ]; then
      rm -f "$SPEC_GEN_BYPASS" 2>/dev/null || true
    fi
    if [ ! -e "$SPEC_GEN_BYPASS" ]; then
      echo "WARNING: spec-review generator gate 1회성 바이패스 소비 — reason: $SPEC_GEN_REASON" >&2
      log_block "spec-review gen-failed bypass" "$FILE_PATH"
      # 제거 증명 성공 → 이번 편집 1회 통과 (아래로 fall through)
    else
      echo "[rein] The spec-review bypass marker could not be removed — failing closed (bypass not honored)." >&2
      log_block "spec-review gen-failed bypass consume failed" "$FILE_PATH"
      exit 2
    fi
  else
    SPEC_GEN_CAUSE=$(_spec_gen_sanitize "$(grep '^cause=' "$SPEC_GEN_MARKER" 2>/dev/null | head -1 | cut -d= -f2- || echo "unknown")")
    echo "[rein] The spec-review marker generator failed (cause=$SPEC_GEN_CAUSE)." >&2
    echo "  An unidentified spec change may be unreviewed, so source edits are blocked conservatively." >&2
    echo "  Resolve the underlying python / JSON-parse failure, then re-edit the spec so the marker auto-heals." >&2
    echo "  Emergency bypass (one-shot): echo 'reason=<reason>' > $SPEC_GEN_BYPASS" >&2
    log_block "spec-review generator failed" "$FILE_PATH"
    exit 2
  fi
fi

# (b) 섹션이 있는 active DoD 는 approved_by_user: true 강제.
#
# active DoD 목록은 임시파일이 아니라 bash 배열(ACTIVE_DODS)로 모은다
# (Phase 7 wave 3 ③-b code review round 4, High — 재현 완료). history:
#   - round 2 (Medium): `ACTIVE_DODS_TMP=$(mktemp)` 를 함수 진입 시점에
#     무조건 만들었는데, (a)/(a2)의 조기 exit 2 경로가 유일한 정리 지점
#     (rm -f)에 도달하지 못해 차단 1회당 임시파일이 하나씩 누수됐다.
#     수리: mktemp 호출을 실제 사용 지점(여기)으로 옮겨 조기 exit 경로가
#     임시파일을 아예 만들지 않도록 좁혔다.
#   - round 3 (High): 그렇게 옮긴 `$(mktemp)` 자체가 실패(디스크 가득/
#     TMPDIR 쓰기 불가 등)해도 실패를 표시 없이 빈 문자열로 캡처했다.
#     그 값을 검증 없이 쓰면 이후 `while ... done < "$ACTIVE_DODS_TMP"`
#     가 빈 파일명 리다이렉트 오류로 조용히 실패(set -e 없음)해 while
#     루프 본문이 한 번도 안 돌고, ROUTING_VIOLATIONS 가 항상 빈 채로
#     남아 미승인 active DoD 가 그대로 통과했다(fail-open). 수리:
#     mktemp 의 성공(exit 0)과 실제 파일 생성을 확인해 실패 시 fail-closed.
#   - round 4 (High, 이번 수리): round 3 수리는 "생성"만 검증했지, 그
#     다음 `printf ... >> "$ACTIVE_DODS_TMP"` append 자체의 실패(디스크
#     고갈·권한 변경 등으로 파일은 생겼지만 쓰기가 안 되는 경우)는 검사
#     하지 않았다 — 파일 존재 검사는 통과하지만 내용이 비거나 일부만
#     채워져, 그 뒤 while 루프가 위반을 놓치고 ROUTING_VIOLATIONS 가
#     빈 채로 남는 동일한 클래스의 fail-open 이 재현됐다(리뷰어 재현:
#     rc=0 이면서 읽기 전용 파일을 반환하는 가짜 mktemp + 미승인 DoD →
#     exit 0 통과. tests/hooks/test-pre-edit-discipline-gate.sh 의
#     REPRO-6/REPRO-7 참조).
#
#     이 세 라운드는 전부 "임시파일 하나에 의존해 상태를 주고받는다"는
#     같은 뿌리에서 나온 서로 다른 실패 지점(생성 실패 / 쓰기 실패 /
#     읽기 실패)이었다. 매 라운드 새 검사를 추가하는 대신 임시파일
#     자체를 없앤다 — 이 함수는 sourced 되어 호출자의 bash 프로세스
#     안에서 직접 실행되므로(다른 shell 로 fork 되지 않음) bash 배열을
#     그대로 쓸 수 있고, 배열 append 는 디스크 I/O 가 아니라 프로세스
#     메모리 연산이라 mktemp 의 생성/쓰기/읽기 실패라는 세 클래스
#     전부가 이 코드 경로에서 구조적으로 사라진다. 아래 수집 루프는
#     `for dod_file in "$DOD_DIR"/dod-[0-9]*.md; do ... done` 형태의
#     일반 for 루프(파이프/서브셸이 아님)이므로 배열이 이 함수의 스코프에
#     그대로 남는다 — process substitution 이나 command substitution
#     서브셸 안에 배열 채우기 코드를 넣으면 서브셸 종료와 함께 배열이
#     사라지는 고전적 실수가 되므로 주의.
ACTIVE_DODS=()

if [ -d "$DOD_DIR" ]; then
  for dod_file in "$DOD_DIR"/dod-[0-9]*.md; do
    [ -f "$dod_file" ] || continue
    fname=$(basename "$dod_file")
    echo "$fname" | grep -q '^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-' || continue

    # opt-in: `## 라우팅 추천` 섹션이 없으면 enforcement 대상 외
    if ! grep -q '^## 라우팅 추천' "$dod_file" 2>/dev/null; then
      continue
    fi

    dod_slug=$(echo "$fname" | sed 's/^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//' | sed 's/\.md$//')

    is_active=true
    if [ -d "$INBOX_DIR" ]; then
      for inbox_file in "$INBOX_DIR"/[0-9]*.md; do
        [ -f "$inbox_file" ] || continue
        inbox_slug_val=$(basename "$inbox_file" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
        if [ "$inbox_slug_val" = "$dod_slug" ]; then
          is_active=false
          break
        fi
      done
    fi

    if [ "$is_active" = true ]; then
      ACTIVE_DODS+=("$dod_file")
    fi
  done
fi

ROUTING_VIOLATIONS=""
for active_dod in "${ACTIVE_DODS[@]}"; do
  [ -f "$active_dod" ] || continue
  # `## 라우팅 추천` 섹션 범위만 추출 (다음 `^## ` 직전까지).
  # approved_by_user: true (선택적 inline # 주석 허용) 이 범위 내에 있어야 통과.
  # awk: 첫 `## 라우팅 추천` 섹션만 추출. 중복 섹션이 있어도 이어붙이지 않는다.
  SECTION=$(awk '
    /^## 라우팅 추천/ {if (!seen) {in_sec=1; seen=1}; next}
    in_sec && /^## / {in_sec=0}
    in_sec {print}
  ' "$active_dod" 2>/dev/null)
  # 이 루프에 들어온 시점에서 섹션 존재는 이미 확인됨.
  if ! printf '%s\n' "$SECTION" | grep -qE '^[[:space:]]*approved_by_user:[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$'; then
    ROUTING_VIOLATIONS="$ROUTING_VIOLATIONS
  - $(basename "$active_dod"): 섹션 내 approved_by_user: true 없음 (pending/false)"
  fi
done

if [ -n "$ROUTING_VIOLATIONS" ]; then
  if [ -f "$ROUTING_BYPASS" ]; then
    REASON=$(grep '^reason=' "$ROUTING_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")
    echo "WARNING: routing gate 1회성 바이패스 — reason: $REASON" >&2
    log_block "routing gate bypass" "$FILE_PATH"
    # REIN_GATE_PEEK_MODE 가드: peek 는 이 1회성 마커를 실제로 소비하면 안 된다
    # (파일 헤더의 "Ordering correction" 절 참조 — enforcing 호출만 소비).
    [ "${REIN_GATE_PEEK_MODE:-0}" = "1" ] || rm -f "$ROUTING_BYPASS"
  else
    printf "[rein] The following active task records have a routing section without user approval:%b\n" "$ROUTING_VIOLATIONS" >&2
    echo "  To proceed:" >&2
    echo "  1) Confirm the routing plan with the user." >&2
    echo "  2) Add the approval line to the '## 라우팅 추천' section, then retry the edit." >&2
    echo "  Approval line format: a standalone YAML line inside the '## 라우팅 추천' section," >&2
    echo "    'approved_by_user: true' (no quotes). Leading spaces and a trailing inline '#' comment are OK." >&2
    echo "    Not recognized: bullet (- approved_by_user: true), bold (**approved_by_user: true**), or quoted (approved_by_user: \"true\")." >&2
    echo "  Emergency bypass: echo 'reason=<reason>' > $ROUTING_BYPASS" >&2
    log_block "routing section 위반" "$FILE_PATH"
    exit 2
  fi
fi

# END routing-gate
}
