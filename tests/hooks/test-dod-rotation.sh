#!/bin/bash
# tests/hooks/test-dod-rotation.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# ============================================================
# 레거시 스윕 시나리오
# ============================================================

test_legacy_sweep_happy_path() {
  # given: 레거시 포맷 dod 3개, 신 포맷 dod 1개
  seed_dod "dod-old-task-a.md" "# old A
- content A"
  seed_dod "dod-old-task-b.md" "# old B
- content B"
  seed_dod "dod-legacy-typo.md" "# typo
- content C"
  seed_dod "dod-2026-04-13-new-work.md" "# new work
- still pending"

  # when
  run_hook "inbox-compress.sh"

  # then
  assert_exit 0 "sweep 이 hook 종료코드에 영향 없어야 함"

  # 레거시 3개는 LEGACY_ARCHIVE.md 로 이동
  assert_file_exists "trail/dod/LEGACY_ARCHIVE.md"
  assert_file_missing "trail/dod/dod-old-task-a.md"
  assert_file_missing "trail/dod/dod-old-task-b.md"
  assert_file_missing "trail/dod/dod-legacy-typo.md"

  # 내용 보존
  assert_file_contains "trail/dod/LEGACY_ARCHIVE.md" "content A"
  assert_file_contains "trail/dod/LEGACY_ARCHIVE.md" "content B"
  assert_file_contains "trail/dod/LEGACY_ARCHIVE.md" "content C"
  assert_file_contains "trail/dod/LEGACY_ARCHIVE.md" "## dod-old-task-a.md"

  # 신 포맷은 건드리지 않음
  assert_file_exists "trail/dod/dod-2026-04-13-new-work.md"
  assert_file_not_contains "trail/dod/LEGACY_ARCHIVE.md" "new work"

  # stderr NOTICE
  assert_stderr_contains "3개의 레거시 DoD"
}

test_legacy_sweep_idempotent() {
  # given: 이미 비어 있음
  seed_dod "dod-2026-04-13-new.md" "# new"

  # when: 두 번 실행
  run_hook "inbox-compress.sh"
  run_hook "inbox-compress.sh"

  # then: 아무 변화 없음
  assert_exit 0
  assert_file_exists "trail/dod/dod-2026-04-13-new.md"
  assert_file_missing "trail/dod/LEGACY_ARCHIVE.md"
}

test_legacy_sweep_no_dod_dir() {
  # given: dod 디렉토리 자체가 없는 극단 케이스
  rmdir "$SANDBOX/trail/dod"

  # when
  run_hook "inbox-compress.sh"

  # then: 에러 없이 종료
  assert_exit 0
}

# ============================================================
# 통합 회전 시나리오
# ============================================================

test_rotation_happy_path_same_day() {
  # given: 어제 날짜로 inbox + 매칭 dod
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-fix-bug.md" "# DoD fix-bug
- 통과 기준 A
- 통과 기준 B"
  seed_inbox "${y}-fix-bug.md" "# fix-bug 완료
- 변경 파일: src/foo.py
- 요약: 버그 수정"

  # when
  run_hook "inbox-compress.sh"

  # then
  assert_exit 0
  assert_file_exists "trail/daily/${y}.md"
  assert_file_missing "trail/inbox/${y}-fix-bug.md"
  assert_file_missing "trail/dod/dod-${y}-fix-bug.md"

  # daily 포맷 검증
  assert_file_contains "trail/daily/${y}.md" "<!-- source: ${y}-fix-bug.md -->"
  assert_file_contains "trail/daily/${y}.md" "## fix-bug"
  assert_file_contains "trail/daily/${y}.md" "### DoD"
  assert_file_contains "trail/daily/${y}.md" "통과 기준 A"
  assert_file_contains "trail/daily/${y}.md" "### 완료 기록"
  assert_file_contains "trail/daily/${y}.md" "변경 파일: src/foo.py"
}

test_rotation_today_skipped() {
  # given: 오늘 날짜 inbox + dod (아직 처리되면 안 됨)
  local t
  t=$(date +%Y-%m-%d)
  seed_dod "dod-${t}-wip.md" "# wip"
  seed_inbox "${t}-wip.md" "# wip inbox"

  # when
  run_hook "inbox-compress.sh"

  # then: 오늘 파일은 그대로 남음
  assert_exit 0
  assert_file_exists "trail/inbox/${t}-wip.md"
  assert_file_exists "trail/dod/dod-${t}-wip.md"
  assert_file_missing "trail/daily/${t}.md"
}

test_rotation_multi_day() {
  # given: dod 는 3일 전, inbox 는 어제 (다일 작업)
  local start end
  start=$(date -v-3d +%Y-%m-%d 2>/dev/null || date -d '3 days ago' +%Y-%m-%d)
  end=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${start}-big-refactor.md" "# DoD big-refactor
- marker-START"
  seed_inbox "${end}-big-refactor.md" "# big-refactor 완료
- marker-END"

  # when
  run_hook "inbox-compress.sh"

  # then: END 날짜 daily 에 병합
  assert_exit 0
  assert_file_exists "trail/daily/${end}.md"
  assert_file_missing "trail/daily/${start}.md"
  assert_file_missing "trail/inbox/${end}-big-refactor.md"
  assert_file_missing "trail/dod/dod-${start}-big-refactor.md"
  assert_file_contains "trail/daily/${end}.md" "marker-START"
  assert_file_contains "trail/daily/${end}.md" "marker-END"
}

test_rotation_idempotent() {
  # given: 어제 inbox + dod
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-foo.md" "# dod foo"
  seed_inbox "${y}-foo.md" "# inbox foo"

  # 첫 실행 — daily 생성
  run_hook "inbox-compress.sh"
  assert_file_exists "trail/daily/${y}.md"

  # 두 번째 실행 — /tmp 마커 삭제 + 재실행 (같은 날 두 번째 훅 호출 시뮬레이션)
  rm -f /tmp/.claude-inbox-compressed-*
  # 두 번째 실행을 위해 inbox 를 다시 만들어 "이미 병합된 소스" 시뮬레이션
  seed_inbox "${y}-foo.md" "# inbox foo duplicate"

  run_hook "inbox-compress.sh"

  # then: daily 에 섹션이 두 번 쓰여지지 않아야 함 (멱등 마커가 감지)
  local count
  count=$(grep -cF "<!-- source: ${y}-foo.md -->" "$SANDBOX/trail/daily/${y}.md" || echo 0)
  [ "$count" = "1" ] || fail "daily 에 source 마커가 $count 번 나타남 (기대: 1)"
  # inbox 는 멱등 경로에서 제거됨
  assert_file_missing "trail/inbox/${y}-foo.md"
}

test_rotation_slug_reuse_safe() {
  # given: 과거에 완료된 slug 가 daily 에 이미 있는 상황에서
  #        오늘 같은 slug 로 새 dod 를 만들어도 회전 로직이 과거를 건드리지 않음
  local old y
  old=$(date -v-5d +%Y-%m-%d 2>/dev/null || date -d '5 days ago' +%Y-%m-%d)
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)

  # 과거 daily 에 fix-typo 섹션
  seed_daily "${old}.md" "# Daily Summary: ${old}

---
<!-- source: ${old}-fix-typo.md -->
## fix-typo

### 완료 기록
- 오래된 고침"

  # 어제 새로 완료한 fix-typo (같은 slug)
  seed_dod "dod-${y}-fix-typo.md" "# new fix-typo"
  seed_inbox "${y}-fix-typo.md" "# new fix-typo done
- 오늘의 새 작업"

  # when
  run_hook "inbox-compress.sh"

  # then
  assert_exit 0
  # 새 회전은 yesterday daily 에 기록
  assert_file_exists "trail/daily/${y}.md"
  assert_file_contains "trail/daily/${y}.md" "오늘의 새 작업"
  # 과거 daily 는 그대로 유지, 새 내용 삽입 없음
  assert_file_contains "trail/daily/${old}.md" "오래된 고침"
  assert_file_not_contains "trail/daily/${old}.md" "오늘의 새 작업"
}

test_rotation_inbox_without_dod() {
  # given: inbox 만 있고 매칭 dod 없음 (사용자가 dod 없이 inbox 작성)
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_inbox "${y}-no-dod-task.md" "# no dod task"

  # when
  run_hook "inbox-compress.sh"

  # then: daily 에 완료 기록만 쓰이고 DoD 블록은 없음
  assert_exit 0
  assert_file_exists "trail/daily/${y}.md"
  assert_file_contains "trail/daily/${y}.md" "## no-dod-task"
  assert_file_contains "trail/daily/${y}.md" "### 완료 기록"
  assert_file_not_contains "trail/daily/${y}.md" "### DoD"
  assert_file_missing "trail/inbox/${y}-no-dod-task.md"
}

# ============================================================
# orphan 완료 DoD 보정 스윕 시나리오
# ============================================================

test_orphan_completed_dod_archived_by_source_marker() {
  # given: inbox 는 이미 사라졌지만 daily 에 동일 slug source marker 가 있음
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-orphan-fix.md" "# orphan fix DoD
- preserve this content"
  seed_daily "${y}.md" "# Daily Summary: ${y}

---
<!-- source: ${y}-orphan-fix.md -->
## orphan-fix

### 완료 기록
- done"

  # when
  run_hook "inbox-compress.sh"

  # then: DoD 원본은 completed archive 로 이동
  assert_exit 0
  assert_file_missing "trail/dod/dod-${y}-orphan-fix.md"
  assert_file_exists "trail/dod/COMPLETED_ARCHIVE.md"
  assert_file_contains "trail/dod/COMPLETED_ARCHIVE.md" "## dod-${y}-orphan-fix.md"
  assert_file_contains "trail/dod/COMPLETED_ARCHIVE.md" "preserve this content"
  assert_stderr_contains "1개의 완료 DoD"
}

test_orphan_completed_dod_archived_by_exact_dod_filename() {
  # given: source slug 는 변경됐지만 daily 완료 기록이 정확한 DoD 파일명을 언급함
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-old-slug.md" "# old slug DoD
- old slug criteria"
  seed_daily "${y}.md" "# Daily Summary: ${y}

---
<!-- source: ${y}-new-slug.md -->
## new-slug

### 완료 기록
- DoD: trail/dod/dod-${y}-old-slug.md"

  # when
  run_hook "inbox-compress.sh"

  # then: exact basename 증거로 안전하게 아카이브
  assert_exit 0
  assert_file_missing "trail/dod/dod-${y}-old-slug.md"
  assert_file_exists "trail/dod/COMPLETED_ARCHIVE.md"
  assert_file_contains "trail/dod/COMPLETED_ARCHIVE.md" "old slug criteria"
}

test_orphan_completed_dod_preserves_today_even_with_evidence() {
  # given: 오늘 DoD 는 아직 작업 중일 수 있으므로 daily 증거가 있어도 보존
  local t
  t=$(date +%Y-%m-%d)
  seed_dod "dod-${t}-active-today.md" "# active today"
  seed_daily "${t}.md" "# Daily Summary: ${t}

---
<!-- source: ${t}-active-today.md -->
## active-today"

  # when
  run_hook "inbox-compress.sh"

  # then
  assert_exit 0
  assert_file_exists "trail/dod/dod-${t}-active-today.md"
  assert_file_missing "trail/dod/COMPLETED_ARCHIVE.md"
}

test_orphan_completed_dod_preserves_without_archive_evidence() {
  # given: 오래됐지만 daily/weekly 완료 증거가 없는 DoD
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-still-pending.md" "# still pending"
  seed_daily "${y}.md" "# Daily Summary: ${y}

---
## unrelated-task"

  # when
  run_hook "inbox-compress.sh"

  # then
  assert_exit 0
  assert_file_exists "trail/dod/dod-${y}-still-pending.md"
  assert_file_missing "trail/dod/COMPLETED_ARCHIVE.md"
}

test_orphan_completed_dod_preserves_heading_substring() {
  # given: slug 가 heading 의 부분 문자열일 뿐인 경우
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-foo.md" "# foo"
  seed_daily "${y}.md" "# Daily Summary: ${y}

---
## foo-extra"

  # when
  run_hook "inbox-compress.sh"

  # then
  assert_exit 0
  assert_file_exists "trail/dod/dod-${y}-foo.md"
  assert_file_missing "trail/dod/COMPLETED_ARCHIVE.md"
}

test_orphan_completed_dod_skips_when_daily_marker_exists() {
  # given: 오늘 trail-rotate 가 이미 한 번 실행되어 daily rotation marker 가 있음
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  run_hook "inbox-compress.sh"
  assert_exit 0

  seed_dod "dod-${y}-late-cleanup.md" "# late cleanup"
  seed_daily "${y}.md" "# Daily Summary: ${y}

---
<!-- source: ${y}-late-cleanup.md -->
## late-cleanup"

  # when: 같은 날 두 번째 실행
  run_hook "inbox-compress.sh"

  # then: 성능 최적화로 daily marker 가 있으면 orphan sweep 전 즉시 skip
  assert_exit 0
  assert_file_exists "trail/dod/dod-${y}-late-cleanup.md"
  assert_file_missing "trail/dod/COMPLETED_ARCHIVE.md"
}

test_orphan_completed_dod_skips_when_matching_inbox_exists() {
  # given: daily 에 같은 slug 흔적이 있어도 inbox driver 가 아직 남아 있는 정상 회전 대상
  local y
  y=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  seed_dod "dod-${y}-normal-rotation.md" "# normal rotation DoD
- criteria must go to daily"
  seed_inbox "${y}-normal-rotation.md" "# normal rotation done"
  seed_daily "${y}.md" "# Daily Summary: ${y}

---
## normal-rotation"

  # when
  run_hook "inbox-compress.sh"

  # then: 보정 archive 가 아니라 기존 inbox-driven 회전으로 병합
  assert_exit 0
  assert_file_missing "trail/dod/dod-${y}-normal-rotation.md"
  assert_file_missing "trail/inbox/${y}-normal-rotation.md"
  assert_file_missing "trail/dod/COMPLETED_ARCHIVE.md"
  assert_file_contains "trail/daily/${y}.md" "### DoD"
  assert_file_contains "trail/daily/${y}.md" "criteria must go to daily"
}

# ============================================================
# Main
# ============================================================
main() {
  run_test test_legacy_sweep_happy_path       inbox-compress.sh trail-rotate.sh
  run_test test_legacy_sweep_idempotent       inbox-compress.sh trail-rotate.sh
  run_test test_legacy_sweep_no_dod_dir       inbox-compress.sh trail-rotate.sh
  run_test test_rotation_happy_path_same_day  inbox-compress.sh trail-rotate.sh
  run_test test_rotation_today_skipped        inbox-compress.sh trail-rotate.sh
  run_test test_rotation_multi_day            inbox-compress.sh trail-rotate.sh
  run_test test_rotation_idempotent           inbox-compress.sh trail-rotate.sh
  run_test test_rotation_slug_reuse_safe      inbox-compress.sh trail-rotate.sh
  run_test test_rotation_inbox_without_dod    inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_archived_by_source_marker inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_archived_by_exact_dod_filename inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_preserves_today_even_with_evidence inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_preserves_without_archive_evidence inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_preserves_heading_substring inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_skips_when_daily_marker_exists inbox-compress.sh trail-rotate.sh
  run_test test_orphan_completed_dod_skips_when_matching_inbox_exists inbox-compress.sh trail-rotate.sh
  summary
}

main "$@"
