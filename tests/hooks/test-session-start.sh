#!/bin/bash
# tests/hooks/test-session-start.sh
#
# Session start hook (session-start-load-trail.sh) 단위 테스트.
# Lean mode (2026-04-29~) 동작 검증:
#   - index.md 만 자동 주입
#   - inbox/daily/weekly 는 자동 주입에서 제외 (negative tests)
#   - freshness 경고 1줄 항상 출력
#   - pending spec review 요약은 유지

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# Helper: seed weekly file (test-harness 미제공, 여기서 정의)
seed_weekly() {
  local fname="$1"
  local content="${2:-# Weekly: ${fname%.md}}"
  printf '%s\n' "$content" > "$SANDBOX/trail/weekly/$fname"
}

seed_project_json() {
  mkdir -p "$SANDBOX/.rein"
  cat > "$SANDBOX/.rein/project.json" <<'JSON'
{"mode":"scaffold","scope":"project","version":"test"}
JSON
}

test_empty_trail() {
  # rein project marker 또는 trail/index.md 가 없으면 bootstrap path 에 맡기고 no-op
  run_hook "session-start-load-trail.sh"
  assert_exit 0 "should exit successfully"
  [ -z "$HOOK_STDOUT" ] || fail "uninitialized project should not emit trail context"
  echo "$HOOK_STDOUT" | grep -q "### trail/inbox" && fail "should not have inbox section"
  echo "$HOOK_STDOUT" | grep -q "### trail/daily" && fail "should not have daily section"
  echo "$HOOK_STDOUT" | grep -q "### trail/weekly" && fail "should not have weekly section"
}

test_with_index() {
  # index.md 만 있음 → index 출력 + freshness 경고
  seed_project_json
  printf '# Project Index\n- Item 1\n' > "$SANDBOX/trail/index.md"
  run_hook "session-start-load-trail.sh"
  assert_exit 0 "should exit successfully"
  echo "$HOOK_STDOUT" | grep -q "### trail/index.md" || fail "missing index.md section"
  echo "$HOOK_STDOUT" | grep -q "# Project Index" || fail "missing index.md content"
  echo "$HOOK_STDOUT" | grep -q "비권위 캐시" || fail "missing freshness warning"
}

test_freshness_warning_present() {
  # 어떤 trail 상태에서도 freshness 경고는 항상 emit
  seed_project_json
  printf '# Index\n' > "$SANDBOX/trail/index.md"
  run_hook "session-start-load-trail.sh"
  assert_exit 0 "should exit successfully"
  # 핵심 키워드: 비권위, git 명령 안내
  echo "$HOOK_STDOUT" | grep -q "비권위 캐시" || fail "missing 비권위 캐시 phrase"
  echo "$HOOK_STDOUT" | grep -q "git status\|git log\|git tag\|git ls-remote" || fail "missing git verification hint"
}

test_inbox_daily_weekly_not_emitted() {
  # inbox/daily/weekly 파일이 있어도 hook 출력에 등장하지 않아야 함 (lean mode)
  seed_project_json
  printf '# Index\n' > "$SANDBOX/trail/index.md"
  seed_inbox "2026-04-15-task1.md" "Inbox content task1"
  seed_inbox "2026-04-14-task2.md" "Inbox content task2"
  seed_daily "2026-04-13.md" "Daily content 13"
  seed_daily "2026-04-12.md" "Daily content 12"
  seed_weekly "2026-W16.md" "Weekly content W16"
  seed_weekly "2026-W15.md" "Weekly content W15"

  run_hook "session-start-load-trail.sh"
  assert_exit 0 "should exit successfully"

  # index.md 는 emit
  echo "$HOOK_STDOUT" | grep -q "### trail/index.md" || fail "missing index.md section"

  # inbox/daily/weekly 모두 emit 되지 않아야 함
  echo "$HOOK_STDOUT" | grep -q "### trail/inbox/" && fail "inbox should not be emitted in lean mode"
  echo "$HOOK_STDOUT" | grep -q "### trail/daily/" && fail "daily should not be emitted in lean mode"
  echo "$HOOK_STDOUT" | grep -q "### trail/weekly/" && fail "weekly should not be emitted in lean mode"

  # 내용도 노출되지 않아야 함
  echo "$HOOK_STDOUT" | grep -q "Inbox content task1" && fail "inbox content leaked"
  echo "$HOOK_STDOUT" | grep -q "Daily content 13" && fail "daily content leaked"
  echo "$HOOK_STDOUT" | grep -q "Weekly content W16" && fail "weekly content leaked"
}

test_pending_spec_review_summary() {
  # trail/dod/.spec-reviews/abc.pending 존재 → 출력 상단에 "⚠️ 미해결 spec review 1건" 포함
  seed_project_json
  printf '# Index\n' > "$SANDBOX/trail/index.md"
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  printf 'path=/tmp/test-design.md\ncreated=2026-04-13\n' > "$SANDBOX/trail/dod/.spec-reviews/abc.pending"

  run_hook "session-start-load-trail.sh"
  assert_exit 0 "should exit successfully"

  echo "$HOOK_STDOUT" | grep -q "⚠️ 미해결 spec review: 1건" || fail "missing spec review warning"
  echo "$HOOK_STDOUT" | grep -q "/tmp/test-design.md" || fail "missing spec review path"
}

test_pending_spec_review_empty() {
  # pending 마커 없음 → 요약 섹션 자체가 출력되지 않음
  seed_project_json
  printf '# Index\n' > "$SANDBOX/trail/index.md"
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  # 디렉토리만 있고 .pending 파일 없음

  run_hook "session-start-load-trail.sh"
  assert_exit 0 "should exit successfully"

  echo "$HOOK_STDOUT" | grep -q "미해결 spec review" && fail "should not show spec review warning when no pending files"
}

main() {
  run_test test_empty_trail                        session-start-load-trail.sh
  run_test test_with_index                         session-start-load-trail.sh
  run_test test_freshness_warning_present          session-start-load-trail.sh
  run_test test_inbox_daily_weekly_not_emitted     session-start-load-trail.sh
  run_test test_pending_spec_review_summary        session-start-load-trail.sh
  run_test test_pending_spec_review_empty          session-start-load-trail.sh
  summary
}

main "$@"
