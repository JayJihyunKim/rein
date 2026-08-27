#!/bin/bash
# tests/hooks/test-pre-edit-discipline-gate-repo-scope.sh
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대): pre-edit-dod-gate.sh 삭제 후
# spec-review-gate 축은 pre-edit-discipline-gate.sh 가 이어받는다. 이 파일의
# 검증 대상은 GSD-1/GSD-2 spec 관련성 판정뿐 — 활성작업(active-task) 축과
# 무관하므로 파일명만 새 훅으로 rename, 로직/단언은 불변.
#
# GSD-1 / GSD-2 (dod-2026-08-05-gate-scope-defects) — spec 게이트 판정 범위.
#
# 결함 1 (GSD-1): 표식의 path= 가 타 저장소 절대경로여도 파일이 실존하면 판정에
#   포함돼, 다른 저장소 문서의 미리뷰 상태가 이 저장소 편집 전체를 잠갔다
#   (2026-08-04 실측: 타 저장소 표식 25건 유입 → 전체 편집 차단).
#   수리 계약: 저장소 밖 path= 표식은 판정 제외 + 비차단 경고.
#
# 결함 2 (GSD-2): 미리뷰 문서가 현재 진행 중 작업과 무관해도 소스 전체가
#   차단됐다 (한 세션 28회 실측). 수리 계약: 활성 작업 기준서(또는 그 plan ref
#   문서)가 참조하는 문서만 차단, 무관 문서는 비차단 경고. 설계→코딩 순서
#   강제(관련 문서 차단)는 그대로 유지 — FN 금지.
#
# Test harness: tests/hooks/lib/test-harness.sh (행위 기반 — 실제 훅 실행 +
# 종료코드/stderr 단언).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-harness.sh"

_compute_hash() {
  printf '%s' "$1" | shasum 2>/dev/null | cut -c1-16
}

# 미리뷰 스펙 seeding — path= 를 호출자가 지정.
_seed_pending_marker_for() {
  local spec_file="$1"
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(_compute_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "created=2026-08-05T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
}

# 저장소 안 미리뷰 스펙 생성 + 표식.
_seed_inside_unreviewed_spec() {
  mkdir -p "$SANDBOX/docs/specs"
  INSIDE_SPEC="$SANDBOX/docs/specs/2026-08-05-feature-x.md"
  echo "# Spec feature-x (not yet reviewed)" > "$INSIDE_SPEC"
  _seed_pending_marker_for "$INSIDE_SPEC"
}

# 저장소 밖(타 저장소) 미리뷰 스펙 생성 + 표식.
_seed_outside_unreviewed_spec() {
  OUTSIDE_REPO=$(mktemp -d "/tmp/other-repo-XXXXXX")
  mkdir -p "$OUTSIDE_REPO/docs/specs"
  OUTSIDE_SPEC="$OUTSIDE_REPO/docs/specs/2026-08-05-other-repo-doc.md"
  echo "# Other repo spec (never reviewed there)" > "$OUTSIDE_SPEC"
  _seed_pending_marker_for "$OUTSIDE_SPEC"
}

_cleanup_outside_repo() {
  [ -n "${OUTSIDE_REPO:-}" ] && [ -d "$OUTSIDE_REPO" ] && rm -rf "$OUTSIDE_REPO"
  OUTSIDE_REPO=""
}

_edit_scripts_input() {
  printf '{"tool_input": {"file_path": "%s/scripts/rein-something.sh"}, "tool_result": {}}' "$SANDBOX"
}

# ---------------------------------------------------------------
# GSD-1: 저장소 밖 표식
# ---------------------------------------------------------------

# G1: 타 저장소 문서를 가리키는 미리뷰 표식만 있을 때 — 이 저장소 소스 편집은
#     허용(exit 0)돼야 하고, 비차단 경고가 나와야 한다.
#     Pre-fix: exit 2 (전역 차단). Post-fix: exit 0 + WARNING.
test_outside_repo_marker_does_not_block() {
  seed_dod "dod-2026-08-05-unrelated-work.md" '# DoD: unrelated work
- slug: unrelated-work'
  _seed_outside_unreviewed_spec

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "outside-repo marker must not block this repository's edits"
  assert_stderr_contains "outside" "non-blocking warning should mention the ignored outside-repo marker"
  _cleanup_outside_repo
}

# G2: 저장소 밖 표식은 경고만 — 표식 파일 자체는 삭제되지 않는다 (판정 제외만).
test_outside_repo_marker_not_deleted() {
  seed_dod "dod-2026-08-05-unrelated-work.md" '# DoD: unrelated work
- slug: unrelated-work'
  _seed_outside_unreviewed_spec
  local hash
  hash=$(_compute_hash "$OUTSIDE_SPEC")

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_file_exists "trail/dod/.spec-reviews/${hash}.pending"
  _cleanup_outside_repo
}

# ---------------------------------------------------------------
# GSD-2: 관련성 기반 차단/경고 분리
# ---------------------------------------------------------------

# G3 (FN 금지 — 핵심 보존 계약): 활성 DoD 가 참조하는 문서의 미리뷰는 여전히
#     차단(exit 2)돼야 한다. 설계→코딩 순서 강제는 관련 문서에 대해 유지.
test_related_unreviewed_spec_still_blocks() {
  _seed_inside_unreviewed_spec
  seed_dod "dod-2026-08-05-feature-x.md" "# DoD: feature-x
- slug: feature-x
- 설계: docs/specs/2026-08-05-feature-x.md"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 2 "a spec referenced by the active DoD must still block source edits when unreviewed"
}

# G3b: plan ref: 경유 참조도 관련으로 판정 — DoD 가 plan 을 가리키고 plan 이
#      spec 을 참조하면 차단 유지.
test_related_via_plan_ref_still_blocks() {
  _seed_inside_unreviewed_spec
  mkdir -p "$SANDBOX/docs/plans"
  printf '# Plan feature-x\n\ndesign ref: docs/specs/2026-08-05-feature-x.md\n' \
    > "$SANDBOX/docs/plans/2026-08-05-feature-x-plan.md"
  seed_dod "dod-2026-08-05-feature-x.md" "# DoD: feature-x
- slug: feature-x
- plan ref: docs/plans/2026-08-05-feature-x-plan.md"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 2 "a spec referenced via the DoD's plan ref must still block when unreviewed"
}

# G3c (코드 리뷰 R1 High 재현): plan ref 표기에 절 주석(§4.2 등)이 붙어도
#      첫 토큰이 경로로 쓰여 관련 판정이 유지된다.
test_related_via_annotated_plan_ref_still_blocks() {
  _seed_inside_unreviewed_spec
  mkdir -p "$SANDBOX/docs/plans"
  printf '# Plan feature-x\n\ndesign ref: docs/specs/2026-08-05-feature-x.md\n' \
    > "$SANDBOX/docs/plans/2026-08-05-feature-x-plan.md"
  seed_dod "dod-2026-08-05-feature-x.md" "# DoD: feature-x
- slug: feature-x
- plan ref: docs/plans/2026-08-05-feature-x-plan.md §4.2 (구현 계획)"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 2 "plan ref with trailing section annotation must still resolve and block"
}

# G2c: orphan(짝 없는 리뷰 완료 표식) 경로도 저장소 밖이면 판정 제외 —
#      깨진 시각 필드(원래 fail-closed 차단)여도 외부 표식이면 경고만.
test_outside_repo_orphan_reviewed_marker_skipped() {
  seed_dod "dod-2026-08-05-unrelated-work.md" '# DoD: unrelated work
- slug: unrelated-work'
  _seed_outside_unreviewed_spec
  local hash
  hash=$(_compute_hash "$OUTSIDE_SPEC")
  rm -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  {
    echo "path=$OUTSIDE_SPEC"
    echo "reviewed=garbled-not-iso"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "an outside-repo orphan reviewed marker must not block (even with garbled fields)"
  assert_stderr_contains "outside" "outside-repo orphan marker should be warned about"
  _cleanup_outside_repo
}

# G9 (R2 High 재현): 저장소 **안** symlink 가 밖의 문서를 가리키는 표식도
#      물리 정규화로 "밖" 판정 — 텍스트 접두사만 보면 안쪽으로 오판해
#      교차 저장소 차단이 재현된다.
test_internal_symlink_to_outside_marker_skipped() {
  seed_dod "dod-2026-08-05-unrelated-work.md" '# DoD: unrelated work
- slug: unrelated-work'
  _seed_outside_unreviewed_spec
  mkdir -p "$SANDBOX/docs/specs"
  ln -s "$OUTSIDE_SPEC" "$SANDBOX/docs/specs/linked-doc.md"
  local hash
  hash=$(_compute_hash "$OUTSIDE_SPEC")
  rm -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  _seed_pending_marker_for "$SANDBOX/docs/specs/linked-doc.md"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "a marker whose in-repo symlink path resolves outside must not block"
  assert_stderr_contains "outside" "internal-symlink-to-outside marker should be warned about"
  _cleanup_outside_repo
}

# G10 (R2 High 재현): 선택기(1계층 표식)가 특정한 작업 기준서가 따로 있으면,
#      **다른** 미완료 기준서가 문서를 참조해도 그 문서의 미리뷰는 경고로
#      강등된다 — 관련성의 기준은 "현재 선택된 작업"이다.
test_other_active_dod_reference_warns_when_selected_dod_unrelated() {
  _seed_inside_unreviewed_spec
  # 1계층 선택은 표식+실존+경계 검사만 요구한다 — 범위 연결 절은 불필요하고,
  # 넣으면 샌드박스에 없는 커버리지 검증기가 호출돼 별개 사유로 차단된다.
  seed_dod "dod-2026-08-05-selected-work.md" '# DoD: selected work
- slug: selected-work (docs/specs 참조 없음)'
  seed_dod "dod-2026-08-04-other-work.md" "# DoD: other work
- slug: other-work
- 설계: docs/specs/2026-08-05-feature-x.md"
  echo "path=trail/dod/dod-2026-08-05-selected-work.md" > "$SANDBOX/trail/dod/.active-dod"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "a spec referenced only by a non-selected active DoD must warn, not block"
  assert_stderr_contains "WARNING" "non-selected DoD reference should downgrade to warning"
}

# G4: 무관 문서의 미리뷰는 차단하지 않고 경고만 — 소스 편집 허용(exit 0).
#     Pre-fix: exit 2 (전역 차단, 실측 28회). Post-fix: exit 0 + WARNING.
test_unrelated_unreviewed_spec_warns_not_blocks() {
  _seed_inside_unreviewed_spec
  seed_dod "dod-2026-08-05-unrelated-work.md" '# DoD: unrelated work
- slug: unrelated-work
- 설계 문서 없음 (작업 기준서 단독)'

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "an unreviewed spec unrelated to the active work must not block source edits"
  assert_stderr_contains "WARNING" "unrelated unreviewed spec should produce a non-blocking warning"
}

# G5: 관련 + 무관 혼재 — 관련 문서가 있으면 차단이 이긴다.
test_mixed_related_and_unrelated_blocks() {
  _seed_inside_unreviewed_spec
  mkdir -p "$SANDBOX/docs/specs"
  local other_spec="$SANDBOX/docs/specs/2026-08-05-unrelated-doc.md"
  echo "# Unrelated spec" > "$other_spec"
  _seed_pending_marker_for "$other_spec"
  seed_dod "dod-2026-08-05-feature-x.md" "# DoD: feature-x
- slug: feature-x
- 설계: docs/specs/2026-08-05-feature-x.md"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 2 "when related and unrelated pending specs coexist, the related one must still block"
}

# G6: 관련 문서가 리뷰 완료(신선)면 통과 — 관련성 분기가 리뷰 완료 판정을
#     오염시키지 않는다 (무회귀).
test_related_reviewed_spec_passes() {
  _seed_inside_unreviewed_spec
  local hash
  hash=$(_compute_hash "$INSIDE_SPEC")
  {
    echo "path=$INSIDE_SPEC"
    echo "reviewed=2026-08-05T12:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  seed_dod "dod-2026-08-05-feature-x.md" "# DoD: feature-x
- slug: feature-x
- 설계: docs/specs/2026-08-05-feature-x.md"

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "a freshly reviewed related spec must pass the gate"
}

# G7: 완료된(inbox 기록 있는) DoD 만 문서를 참조 — 관련성은 '활성' 기준서만
#     본다. 완료 작업의 문서 미리뷰는 경고로 강등.
test_completed_dod_reference_does_not_block() {
  _seed_inside_unreviewed_spec
  seed_dod "dod-2026-08-01-feature-x.md" "# DoD: feature-x (완료됨)
- slug: feature-x
- 설계: docs/specs/2026-08-05-feature-x.md"
  seed_inbox "2026-08-01-feature-x.md" "# 완료 기록"
  seed_dod "dod-2026-08-05-unrelated-work.md" '# DoD: unrelated work
- slug: unrelated-work'

  run_hook pre-edit-discipline-gate.sh "$(_edit_scripts_input)"
  assert_exit 0 "a spec referenced only by a completed DoD must not block (warn only)"
}

# G8 (tests/ 면제 무회귀): 관련 문서 차단 상태에서도 tests/ 편집은 허용
#     (reproduction-first / TDD).
test_tests_exempt_survives_related_block() {
  _seed_inside_unreviewed_spec
  seed_dod "dod-2026-08-05-feature-x.md" "# DoD: feature-x
- slug: feature-x
- 설계: docs/specs/2026-08-05-feature-x.md"

  local input
  input=$(printf '{"tool_input": {"file_path": "%s/tests/hooks/test-foo.sh"}, "tool_result": {}}' "$SANDBOX")
  run_hook pre-edit-discipline-gate.sh "$input"
  assert_exit 0 "tests/ edits must stay exempt even when a related spec blocks"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_outside_repo_marker_does_not_block pre-edit-discipline-gate.sh
run_test test_outside_repo_marker_not_deleted pre-edit-discipline-gate.sh
run_test test_related_unreviewed_spec_still_blocks pre-edit-discipline-gate.sh
run_test test_related_via_plan_ref_still_blocks pre-edit-discipline-gate.sh
run_test test_related_via_annotated_plan_ref_still_blocks pre-edit-discipline-gate.sh
run_test test_outside_repo_orphan_reviewed_marker_skipped pre-edit-discipline-gate.sh
run_test test_internal_symlink_to_outside_marker_skipped pre-edit-discipline-gate.sh
# 1계층 선택 표식이 있으면 게이트가 선택 기준서에 커버리지 검증기를 실행한다
# — 샌드박스에 검증기 스크립트를 함께 복사해야 별개 사유(검증기 부재 fail-
# closed)로 차단되지 않는다.
run_test test_other_active_dod_reference_warns_when_selected_dod_unrelated pre-edit-discipline-gate.sh rein-validate-coverage-matrix.py
run_test test_unrelated_unreviewed_spec_warns_not_blocks pre-edit-discipline-gate.sh
run_test test_mixed_related_and_unrelated_blocks pre-edit-discipline-gate.sh
run_test test_related_reviewed_spec_passes pre-edit-discipline-gate.sh
run_test test_completed_dod_reference_does_not_block pre-edit-discipline-gate.sh
run_test test_tests_exempt_survives_related_block pre-edit-discipline-gate.sh

summary
