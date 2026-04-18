#!/usr/bin/env python3
"""Aggregate blocks.jsonl into incident files. Called from stop-session-gate.sh."""
import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

THRESHOLD = int(os.environ.get("REIN_INCIDENT_THRESHOLD", "2"))
LOCK_TTL_SEC = 300


def utcnow_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def compute_hash(hook, reason):
    return hashlib.sha1(f"{hook}|{reason}".encode("utf-8")).hexdigest()[:16]


def acquire_lock(lock_path):
    """fcntl.flock 기반 lock — 커널이 프로세스 종료 시 자동 해제하므로 manual stale 검사 불필요.

    구버전 race 회피: stale 파일을 미리 unlink 하지 않는다. 항상 같은 lock_path 를 open(a+)
    하고 flock(LOCK_EX|LOCK_NB) 만 시도. 다른 프로세스가 점유 중이면 BlockingIOError. 점유한 프로세스가
    종료(crash 포함)되면 커널이 자동 해제하므로 다음 호출은 즉시 성공.
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fp = open(lock_path, "a+")  # O_RDWR|O_CREAT, append mode 로 truncate 회피
    try:
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fp.close()
        return None
    # 진단용: PID 와 시작 시각을 파일 내에 기록 (정보용)
    fp.seek(0)
    fp.truncate()
    fp.write(json.dumps({"pid": os.getpid(), "started_at": time.time()}))
    fp.flush()
    return fp


def atomic_write(path: Path, content: str):
    """Same-dir tempfile + os.replace."""
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp_path, str(path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(text):
    """Returns (fm_dict, body). JSON-quoted 값은 json.loads 로 unescape."""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(1).splitlines():
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        v = v.strip()
        # JSON-quoted (with double quotes) → 정식 파싱으로 escape 복원
        if len(v) >= 2 and v.startswith('"') and v.endswith('"'):
            try:
                v = json.loads(v)
            except json.JSONDecodeError:
                v = v[1:-1]  # fallback
        fm[k.strip()] = v
    return fm, text[m.end():]


def serialize_frontmatter(fm: dict) -> str:
    lines = ["---"]
    for k, v in fm.items():
        # JSON-quote values to handle quotes/colons
        lines.append(f'{k}: {json.dumps(v, ensure_ascii=False)}')
    lines.append("---")
    return "\n".join(lines)


def render_incident(fm: dict, examples: list, body_extra: str = "") -> str:
    fm_block = serialize_frontmatter(fm)
    examples_block = "\n".join(str(e) for e in examples) if examples else "(no examples)"
    return f"""{fm_block}

# Incident: {fm['hook']} / {fm['reason']}

## 예시 (최근 최대 5건)

```
{examples_block}
```

## 분석 메모

(incidents-to-rule 스킬이 분석 결과를 여기에 기록)

## 승격 이력

{body_extra or '(사용자 결정 기록)'}
"""


def find_open_incident(incidents_dir: Path, hook: str, hash_: str):
    """Returns (path, fm) of latest pending incident in suffix series, or None.

    Suffix 번호로 numeric sort (descending). lexical sort 면 -10 < -2 가 되어 잘못됨.
    """
    base_name = f"auto-{hook}-{hash_}"
    pattern = f"{base_name}*.md"

    def suffix_num(path: Path) -> int:
        stem = path.stem  # 'auto-hook-hash' or 'auto-hook-hash-N'
        if stem == base_name:
            return 0  # base = suffix 0
        rest = stem[len(base_name) + 1:]  # after '-'
        try:
            return int(rest)
        except ValueError:
            return -1  # 잘못된 형식은 뒤로

    candidates = sorted(incidents_dir.glob(pattern), key=suffix_num, reverse=True)
    for path in candidates:
        try:
            fm, _ = parse_frontmatter(path.read_text())
            if fm.get("status") == "pending":
                return path, fm
        except Exception:
            continue
    return None


def next_suffix_path(incidents_dir: Path, hook: str, hash_: str):
    """Return next available auto-<hook>-<hash>[-N].md path."""
    base = incidents_dir / f"auto-{hook}-{hash_}.md"
    if not base.exists():
        return base
    n = 2
    while True:
        p = incidents_dir / f"auto-{hook}-{hash_}-{n}.md"
        if not p.exists():
            return p
        n += 1


def aggregate(project_dir: Path):
    incidents_dir = project_dir / "trail/incidents"
    blocks_jsonl = incidents_dir / "blocks.jsonl"
    watermark = incidents_dir / ".last-processed-line"
    lock_path = incidents_dir / ".aggregate.lock"

    if not blocks_jsonl.exists():
        return 0, 0

    incidents_dir.mkdir(parents=True, exist_ok=True)
    fp = acquire_lock(lock_path)
    if fp is None:
        print("NOTICE: incident 집계 skip (다른 세션 처리 중)", file=sys.stderr)
        return 0, 0

    try:
        last_line = 0
        if watermark.exists():
            try:
                last_line = int(watermark.read_text().strip())
            except ValueError:
                last_line = 0

        # 새 라인만 읽기
        with open(blocks_jsonl) as f:
            all_lines = f.readlines()
        total = len(all_lines)
        if total <= last_line:
            return 0, 0

        new_lines = all_lines[last_line:]
        # 패턴 카운트 + 예시 수집
        counts = defaultdict(int)
        examples = defaultdict(list)
        bad_path = blocks_jsonl.with_suffix(".jsonl.bad")
        bad_lines = []
        for idx, line in enumerate(new_lines, start=last_line + 1):
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                # 손상된 라인은 별도 파일에 격리 + 경고
                bad_lines.append((idx, line))
                continue
            hook = e.get("hook", "")
            reason = e.get("reason", "")
            target = e.get("target", "")
            if not hook or not reason:
                continue
            key = (hook, reason)
            counts[key] += 1
            if len(examples[key]) < 5:
                examples[key].append(target)

        if bad_lines:
            with open(bad_path, "a") as bad_f:
                for idx, line in bad_lines:
                    bad_f.write(f"# line {idx}\n{line}")
            print(f"WARNING: {len(bad_lines)} 손상 라인 → {bad_path}", file=sys.stderr)

        created = 0
        updated = 0
        now = utcnow_iso()
        for (hook, reason), count in counts.items():
            hash_ = compute_hash(hook, reason)
            open_inc = find_open_incident(incidents_dir, hook, hash_)

            # 기존 pending 이 있으면 THRESHOLD 와 무관하게 무조건 누적 갱신한다.
            # 이전 로직은 증가분이 1건(threshold=2 미만) 이면 skip 되어 느린 반복
            # 패턴의 count/last_seen_at 이 영구 과소 집계되었음 (codex v0.7.2 High).
            # THRESHOLD 는 "신규 incident 생성" 여부 판정에만 사용.
            if open_inc:
                path, fm = open_inc
                old_count = int(fm.get("count", "0"))
                fm["count"] = str(old_count + count)
                fm["last_seen_at"] = now
                _, body = parse_frontmatter(path.read_text())
                content = serialize_frontmatter(fm) + "\n" + body
                atomic_write(path, content)
                updated += 1
            elif count >= THRESHOLD:
                # 모든 suffix 가 closed + 이번 배치가 THRESHOLD 이상 → 새 파일 발급
                new_path = next_suffix_path(incidents_dir, hook, hash_)
                fm = {
                    "status": "pending",
                    "pattern_hash": hash_,
                    "hook": hook,
                    "reason": reason,
                    "count": str(count),
                    "first_seen": now,
                    "last_seen_at": now,
                }
                content = render_incident(fm, examples[(hook, reason)])
                atomic_write(new_path, content)
                created += 1
            # else: open_inc 없고 count < THRESHOLD → skip

        # watermark advance (atomic) — lock 안에서 incident 생성과 묶음
        atomic_write(watermark, str(total))

        # Write session state snapshot for SessionStart to detect abnormal termination.
        snapshot = {
            "watermark": total,
            "pending_hashes": list_pending_hashes(incidents_dir),
            "timestamp": now,
            "session_end": False,
        }
        snapshot_path = incidents_dir / ".last-aggregate-state.json"
        atomic_write(snapshot_path, json.dumps(snapshot, ensure_ascii=False, indent=2))

        if created or updated:
            print(f"NOTICE: incident patterns — created={created}, updated={updated}", file=sys.stderr)

        return created, updated

    finally:
        # lock_path.unlink 하지 않음. 파일을 삭제하면 다른 프로세스가
        # 먼저 O_CREAT 로 새 inode 를 잡아 flock 이 서로 다른 객체에 걸리게 되어
        # 동시 집계 race 가 발생함 (codex v0.7.2 review High).
        # 고정 경로 파일에 대해 flock 만 사용하는 것이 올바르다.
        try:
            fcntl.flock(fp, fcntl.LOCK_UN)
            fp.close()
        except Exception:
            pass


def list_pending_hashes(incidents_dir: Path) -> list:
    """Return sorted list of pattern_hash values for all files with status=pending."""
    hashes = set()
    for path in incidents_dir.glob("auto-*.md"):
        try:
            fm, _ = parse_frontmatter(path.read_text())
            if fm.get("status", "") == "pending":
                h = fm.get("pattern_hash", "")
                if h:
                    hashes.add(h)
        except Exception:
            continue
    return sorted(hashes)


def count_pending(project_dir: Path) -> int:
    incidents_dir = project_dir / "trail/incidents"
    if not incidents_dir.exists():
        return 0
    n = 0
    # glob 이 auto-*.md 만 반환하므로 startswith 필터 불필요.
    # SKILL.md 정책: 루트의 frontmatter 없는 .md 파일은 무시 (legacy INC-*.md 는 legacy/ 서브디렉토리 opt-in).
    for path in incidents_dir.glob("auto-*.md"):
        try:
            fm, _ = parse_frontmatter(path.read_text())
            if fm.get("status", "") == "pending":
                n += 1
        except Exception:
            continue
    return n


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=os.environ.get("REIN_PROJECT_DIR"))
    parser.add_argument("--count-pending", action="store_true",
                        help="aggregate 대신 pending 개수만 출력")
    args = parser.parse_args()
    project_dir = Path(args.project_dir or ".").resolve()

    if args.count_pending:
        print(count_pending(project_dir))
        sys.exit(0)

    created, updated = aggregate(project_dir)
    sys.exit(0)
