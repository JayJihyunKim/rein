#!/usr/bin/env bash
# rein-release-cleanup — GitHub Releases 페이지 일괄 cleanup
#
# Usage:
#   rein-release-cleanup.sh --dry-run --repo=<owner/name>
#   rein-release-cleanup.sh --apply   --repo=<owner/name>
#
# 동작:
#   1. 기존 v1.0.0 release page 가 있으면 먼저 delete (--cleanup-tag 사용 안 함).
#      mirror 가 막 push 한 신규 v1.0.0 tag 를 보존하기 위해 page 만 제거.
#   2. 19 pre-v1 release 는 release+tag 동반 delete (--cleanup-tag).
#
# 주의: 본 helper 는 spec §4 Step 9 (mirror 이후) 에서 호출. 이전 단계
# (Step 4 main HEAD retag → Step 5 atomic push → Step 6 mirror) 에서
# public 에 신규 v1.0.0 tag 가 push 된 상태. Step 10 의 gh release create
# 는 그 신규 tag 를 그대로 사용해야 하므로 v1.0.0 의 tag 는 보존.
set -euo pipefail

PRE_V1=(
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
REPO=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) APPLY=false ;;
    --apply)   APPLY=true ;;
    --repo=*)  REPO="${arg#--repo=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done
if [[ -z "$REPO" ]]; then
  echo "--repo=<owner/name> required" >&2; exit 2
fi

echo "rein-release-cleanup: repo=$REPO apply=$APPLY"

# Dry-run: 인증/네트워크 무관하게 실행 예정 명령 20건 (1 v1.0.0 + 19 pre-v1) 출력.
# Apply: gh release view 로 존재 여부 확인 후 실제 delete.
if ! $APPLY; then
  echo "DRY: gh release delete v1.0.0 --repo $REPO --yes  (no --cleanup-tag — preserve newly mirrored tag)"
  for t in "${PRE_V1[@]}"; do
    echo "DRY: gh release delete $t --repo $REPO --yes --cleanup-tag"
  done
  exit 0
fi

# Step 1: 기존 v1.0.0 release page 만 cleanup (tag 보존)
if gh release view v1.0.0 --repo "$REPO" >/dev/null 2>&1; then
  # NOTE: --cleanup-tag 사용 안 함. mirror 가 push 한 신규 v1.0.0 tag 보존.
  gh release delete v1.0.0 --repo "$REPO" --yes \
    && echo "deleted: v1.0.0 page (tag preserved)" \
    || echo "skip:    v1.0.0 (delete failed)"
else
  echo "skip:    v1.0.0 (no existing release page)"
fi

# Step 2: 19 pre-v1 release+tag 동반 cleanup
for t in "${PRE_V1[@]}"; do
  if gh release view "$t" --repo "$REPO" >/dev/null 2>&1; then
    gh release delete "$t" --repo "$REPO" --yes --cleanup-tag \
      && echo "deleted: $t (release+tag)" \
      || echo "skip:    $t (delete failed)"
  else
    echo "skip:    $t (no release page)"
  fi
done
