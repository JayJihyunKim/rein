#!/usr/bin/env python3
"""
rein-heal-legacy-pending.py — auto-stamp legacy pending spec-review markers.

Pending marker (`trail/dod/.spec-reviews/<hash>.pending`) 가 가리키는 문서가
이미 git tag (예: v1.0.0) 에 도달 가능한 commit 에 포함되어 있다면,
해당 pending 을 자동 `.reviewed` stamp 로 전환한다.

- reviewer 필드: `retrospective-shipped-<tag>` (또는 `retrospective-shipped` 가장
  최근 도달 가능 tag 가 없으면)
- 이미 `.reviewed` 가 있으면 skip (멱등성)
- 신규 미병합 문서 (tag 도달 불가) 는 건드리지 않음 — 기존 gate 워크플로 유지

Governance 근거: `.claude/rules/legacy-shipped-pending.md`

Usage:
    python3 scripts/rein-heal-legacy-pending.py [--dry-run] [--quiet]

Exit codes:
    0 = 성공 (변경분 stdout 에 보고)
    1 = 실패 (git repo 아님 등)
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def run_git(args: list[str], cwd: Path) -> tuple[int, str]:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.returncode, result.stdout.strip()
    except (subprocess.SubprocessError, FileNotFoundError):
        return 1, ""


def list_all_tags(project_dir: Path) -> list[str]:
    """Repo 의 모든 tag (정렬: 최신 먼저).

    Note: rein 은 dev/main 단방향 워크플로로 dev 는 main 에 머지되지 않는다 —
    tag 는 main 커밋에 달리므로 `--merged HEAD` (dev 브랜치에서) 는 공집합.
    따라서 모든 tag 를 대상으로 해당 path 가 존재하는지 개별 체크.
    """
    rc, out = run_git(["tag", "--sort=-creatordate"], project_dir)
    if rc != 0 or not out:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def path_in_tag(project_dir: Path, path: str, tag: str) -> bool:
    """주어진 path 가 tag 시점의 tree 에 존재하는지."""
    rc, _ = run_git(["cat-file", "-e", f"{tag}:{path}"], project_dir)
    return rc == 0


def _parse_iso8601(ts: str) -> "datetime.datetime | None":
    """ISO 8601 (+offset) 을 timezone-aware datetime 으로 파싱. None on failure."""
    import datetime

    if not ts:
        return None
    ts = ts.strip()
    # Python 3.7+ fromisoformat (3.11+ 에서 offset 전부 지원)
    # 3.9 호환을 위해 trailing 'Z' → '+00:00' 치환
    ts_norm = ts.replace("Z", "+00:00")
    try:
        dt = datetime.datetime.fromisoformat(ts_norm)
    except ValueError:
        return None
    # naive → UTC 로 가정 (보수적)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def tag_commit_timestamp(project_dir: Path, tag: str) -> "datetime.datetime | None":
    """tag 의 commit timestamp (timezone-aware datetime). 실패 시 None."""
    rc, out = run_git(["log", "-1", "--format=%cI", tag], project_dir)
    if rc != 0 or not out:
        return None
    return _parse_iso8601(out.strip())


def file_last_commit_timestamp(
    project_dir: Path, rel_path: str
) -> "datetime.datetime | None":
    """dev branch 기준 파일의 마지막 commit timestamp. 미커밋이면 None."""
    rc, out = run_git(["log", "-1", "--format=%cI", "--", rel_path], project_dir)
    if rc != 0 or not out:
        return None
    return _parse_iso8601(out.strip())


def find_shipped_tag(
    project_dir: Path, rel_path: str, tags: list[str]
) -> "tuple[str | None, str, datetime.datetime | None]":
    """rel_path 의 "shipped" 판정 + 해당 tag + tag commit time 반환.

    rein dev/main 단방향 워크플로:
    - docs/specs, docs/plans 는 main 제외 → tag tree 에 없음
    - 대신 **dev 의 파일 last-commit 시각이 가장 최근 tag 생성 시각보다 같거나 이전**이면
      "해당 tag 릴리즈 사이클에 속한 문서" 로 간주 → legacy-shipped

    반환: (tag or None, reason string, tag_datetime or None)
    """
    # 파일이 tag 의 tree 에 직접 있으면 (일반 경로)
    for tag in tags:
        if path_in_tag(project_dir, rel_path, tag):
            tag_dt = tag_commit_timestamp(project_dir, tag)
            return tag, f"found in {tag} tree", tag_dt

    # dev-only 문서: tag 생성 시각과 파일 last-commit 비교 (timezone-aware)
    file_dt = file_last_commit_timestamp(project_dir, rel_path)
    if file_dt is None:
        return None, "no git commit history (uncommitted new doc)", None

    for tag in tags:
        tag_dt = tag_commit_timestamp(project_dir, tag)
        if tag_dt is None:
            continue
        if file_dt <= tag_dt:
            return (
                tag,
                f"dev commit {file_dt.isoformat()} <= tag {tag} @ {tag_dt.isoformat()}",
                tag_dt,
            )

    return (
        None,
        f"dev commit {file_dt.isoformat()} is after all tags (new work since release)",
        None,
    )


def parse_pending_marker(marker_path: Path) -> dict[str, str]:
    """pending marker 파일 파싱 — key=value 라인들."""
    data: dict[str, str] = {}
    try:
        for line in marker_path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                data[k.strip()] = v.strip()
    except OSError:
        pass
    return data


def iso8601_utc() -> str:
    import datetime

    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def heal_marker(
    project_dir: Path,
    pending_marker: Path,
    tags: list[str],
    dry_run: bool,
) -> tuple[bool, str]:
    """pending marker 하나 처리. (healed, reason) 반환.

    CRITICAL freshness check: pending marker 자체의 `created=` timestamp 가
    선택된 tag 의 commit timestamp 보다 **같거나 이전** 이어야 heal 가능.
    즉 "릴리즈 tag 전에 생성된 pending" 만 legacy 로 간주한다. 릴리즈 이후
    재생성된 fresh pending (코드 편집 → gate 에 의해 생성) 은 auto-heal 대상
    아님 — gate 의 원래 의도 (설계 → 코딩 순서 강제) 보존.
    """
    data = parse_pending_marker(pending_marker)
    abs_path = data.get("path", "").strip()
    if not abs_path:
        return False, "no path field"

    # absolute → relative (project_dir 기준)
    try:
        rel_path = str(Path(abs_path).resolve().relative_to(project_dir.resolve()))
    except ValueError:
        return False, f"path outside project_dir: {abs_path}"

    # 대상 문서가 현재 repo 에서 존재하는지
    if not (project_dir / rel_path).exists():
        return False, f"target file does not exist: {rel_path}"

    # tag 도달 가능 여부 (dev 단방향 워크플로 보정 포함)
    shipped_tag, reason, tag_dt = find_shipped_tag(project_dir, rel_path, tags)
    if shipped_tag is None:
        return False, reason

    # CRITICAL: pending marker 의 created 가 tag 이전이어야 legacy 로 판정
    # 이 체크가 빠지면 릴리즈 후 새 pending 이 auto-heal 되어 gate 가 우회됨.
    pending_created_raw = data.get("created", "").strip()
    pending_created_dt = _parse_iso8601(pending_created_raw) if pending_created_raw else None

    if pending_created_dt is None:
        return (
            False,
            f"no created= field in pending marker (cannot verify freshness; skip for safety)",
        )

    if tag_dt is not None and pending_created_dt > tag_dt:
        return (
            False,
            f"pending created {pending_created_dt.isoformat()} AFTER tag {shipped_tag} @ {tag_dt.isoformat()} — fresh unreviewed pending, not legacy",
        )

    # 이미 reviewed 마커가 있으면 skip
    hash_val = pending_marker.stem  # <hash>.pending → <hash>
    reviewed_marker = pending_marker.parent / f"{hash_val}.reviewed"
    if reviewed_marker.exists():
        if not dry_run:
            pending_marker.unlink(missing_ok=True)
        return True, f"already reviewed (cleaned pending), tag={shipped_tag}"

    # reviewed stamp 생성 — rein-mark-spec-reviewed.sh 와 schema 일치 (reviewed= 필드명)
    reviewer = f"retrospective-shipped-{shipped_tag}"
    content = (
        f"path={abs_path}\n"
        f"reviewer={reviewer}\n"
        f"reviewed={iso8601_utc()}\n"
        f"mechanism=rein-heal-legacy-pending\n"
    )

    if dry_run:
        return True, f"would stamp as {reviewer}"

    tmp_path = reviewed_marker.with_suffix(".reviewed.tmp")
    tmp_path.write_text(content, encoding="utf-8")
    tmp_path.replace(reviewed_marker)
    pending_marker.unlink(missing_ok=True)

    return True, f"stamped as {reviewer}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="실제 stamp 하지 않고 계획만 출력")
    parser.add_argument("--quiet", action="store_true", help="변경 없을 때 stdout 출력 생략")
    parser.add_argument("--project-dir", default=None, help="프로젝트 루트 override (기본: git toplevel)")
    args = parser.parse_args(argv)

    # project_dir
    if args.project_dir:
        project_dir = Path(args.project_dir).resolve()
    else:
        script_dir = Path(__file__).parent.resolve()
        project_dir = script_dir.parent
        if not (project_dir / ".git").exists():
            # fallback: git rev-parse --show-toplevel
            rc, out = run_git(["rev-parse", "--show-toplevel"], Path.cwd())
            if rc != 0 or not out:
                print("ERROR: not inside a git repo", file=sys.stderr)
                return 1
            project_dir = Path(out).resolve()

    spec_reviews_dir = project_dir / "trail" / "dod" / ".spec-reviews"
    if not spec_reviews_dir.is_dir():
        if not args.quiet:
            print(f"rein-heal-legacy-pending: no spec-reviews dir at {spec_reviews_dir}")
        return 0

    # 모든 tag 목록 (rein 의 dev/main 단방향 워크플로 때문에 HEAD reachability 불가)
    tags = list_all_tags(project_dir)
    if not tags and not args.quiet:
        print("rein-heal-legacy-pending: no tags in repo; nothing to heal")
        return 0

    # 각 pending 처리
    pending_markers = sorted(spec_reviews_dir.glob("*.pending"))
    healed = 0
    skipped = 0
    total = len(pending_markers)

    for marker in pending_markers:
        did_heal, reason = heal_marker(project_dir, marker, tags, args.dry_run)
        if did_heal:
            healed += 1
            print(f"  heal: {marker.name} — {reason}")
        else:
            skipped += 1
            if not args.quiet:
                print(f"  skip: {marker.name} — {reason}")

    if healed > 0 or not args.quiet:
        verb = "would heal" if args.dry_run else "healed"
        print(f"rein-heal-legacy-pending: {verb} {healed}/{total} marker(s); {skipped} skipped")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
