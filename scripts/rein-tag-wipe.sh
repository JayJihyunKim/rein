#!/usr/bin/env bash
# rein-tag-wipe — local + 지정 remote 에서 pre-v1 19 tag 일괄 force-delete
#
# Usage:
#   rein-tag-wipe.sh --dry-run [--remote=<name>] [--mode=local|remote|both]
#   rein-tag-wipe.sh --apply   [--remote=<name>] [--mode=local|remote|both]
#
# --remote 기본값: origin
# --mode 기본값: both (local + remote 양쪽)
#
# Scope: v0.4.x ~ v2.0.0 의 19 pre-v1 tag 만. v1.0.0 은 보존 (dev cycle 의
# 옛 v1.0.0 wipe 는 caller 책임 — Phase 4 Step 4.1 이 helper 호출 직후
# `git tag -d v1.0.0 && git push origin --delete v1.0.0` 별도 실행. Phase 4
# Step 4.5 의 public cleanup 은 helper 만 호출하여 신규 v1.0.0 tag 보존).
set -euo pipefail

TAGS=(
  v0.4.1 v0.4.2 v0.4.3 v0.6.1
  v0.7.0 v0.7.4 v0.7.5
  v0.8.0
  v0.9.0 v0.9.1
  v0.10.0 v0.10.1
  v1.1.0 v1.1.1 v1.1.2 v1.1.3 v1.1.4
  v1.2.1
  v2.0.0
)

APPLY=false
REMOTE=origin
MODE=both
for arg in "$@"; do
  case "$arg" in
    --dry-run) APPLY=false ;;
    --apply)   APPLY=true ;;
    --remote=*) REMOTE="${arg#--remote=}" ;;
    --mode=*) MODE="${arg#--mode=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

echo "rein-tag-wipe: mode=$MODE remote=$REMOTE apply=$APPLY"
echo "tags (${#TAGS[@]}): ${TAGS[*]}"

if [[ "$MODE" == "local" || "$MODE" == "both" ]]; then
  for t in "${TAGS[@]}"; do
    if $APPLY; then
      git tag -d "$t" 2>/dev/null && echo "local deleted: $t" || echo "local skip:    $t (not present)"
    else
      echo "DRY: git tag -d $t"
    fi
  done
fi

if [[ "$MODE" == "remote" || "$MODE" == "both" ]]; then
  for t in "${TAGS[@]}"; do
    if $APPLY; then
      git push "$REMOTE" --delete "refs/tags/$t" 2>&1 \
        && echo "remote deleted: $REMOTE/$t" \
        || echo "remote skip:    $REMOTE/$t (not present or already deleted)"
    else
      echo "DRY: git push $REMOTE --delete refs/tags/$t"
    fi
  done
fi
