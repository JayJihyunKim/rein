#!/usr/bin/env python3
"""Update frontmatter status of auto-*.md incident files.

Used by /incidents-to-rule skill to close pending incidents after human decision.
Preserves key order in frontmatter and appends a history entry to the body.
"""
import argparse
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

VALID_STATUSES = {"processed", "declined", "error"}
FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def append_trace(project_dir: Path, message: str) -> None:
    """Append one line to .incident-skill-trace.log. Best effort."""
    try:
        log_dir = project_dir / "trail/dod"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / ".incident-skill-trace.log"
        ts = utcnow_iso()
        with open(log_path, "a") as f:
            f.write(f"{ts} rein-mark-incident-processed: {message}\n")
    except OSError:
        pass


def atomic_write(path: Path, content: str, retries: int = 1) -> None:
    last_err = None
    for _ in range(retries + 1):
        tmp_path = None
        try:
            fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp.")
            with os.fdopen(fd, "w") as f:
                f.write(content)
            os.replace(tmp_path, str(path))
            return
        except OSError as e:
            last_err = e
            if tmp_path is not None:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
            time.sleep(0.1)
    raise last_err  # type: ignore


def update_status(path: Path, new_status: str, reason: str) -> str:
    """Return 'updated' | 'noop' | raises ValueError."""
    text = path.read_text()
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError(f"no frontmatter: {path}")

    fm_block = m.group(1)
    body = text[m.end():]

    # Parse + rewrite status line in place (preserve key order and formatting).
    new_lines = []
    found_status = False
    current_status = None
    for line in fm_block.splitlines():
        if ":" not in line:
            new_lines.append(line)
            continue
        key, _, val = line.partition(":")
        if key.strip() == "status":
            found_status = True
            current_status = val.strip().strip('"')
            new_lines.append(f'status: "{new_status}"')
        else:
            new_lines.append(line)

    if not found_status:
        raise ValueError(f"no status key in frontmatter: {path}")

    if current_status == new_status:
        return "noop"

    ts = utcnow_iso()
    history_line = f"- {ts}: {current_status} → {new_status} ({reason})"

    if "## 승격 이력" in body:
        # 승격 이력 섹션 내부에만 append. 이후에 다른 마크다운 섹션이 있어도 안전.
        idx = body.index("## 승격 이력")
        head = body[:idx]
        tail = body[idx:]
        # 승격 이력 섹션의 끝 (다음 ##N 섹션 헤더 직전 또는 파일 끝) 찾기.
        m = re.search(r"\n(## )", tail[len("## 승격 이력"):])
        if m:
            split_at = len("## 승격 이력") + m.start() + 1  # include preceding newline
            section = tail[:split_at]
            after_section = tail[split_at:]
        else:
            section = tail
            after_section = ""
        section_lines = section.rstrip("\n").splitlines()
        cleaned = [ln for ln in section_lines if ln.strip() != "(사용자 결정 기록)"]
        while len(cleaned) > 1 and cleaned[-1].strip() == "":
            cleaned.pop()
        cleaned.append(history_line)
        new_section = "\n".join(cleaned) + "\n"
        new_body = head + new_section + (after_section if after_section else "")
    else:
        sep = "" if body.endswith("\n") else "\n"
        new_body = f"{body}{sep}\n## 승격 이력\n\n{history_line}\n"

    new_content = f"---\n" + "\n".join(new_lines) + "\n---\n" + new_body
    atomic_write(path, new_content)
    return "updated"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Path to auto-*.md file")
    parser.add_argument("status", choices=sorted(VALID_STATUSES),
                        help="New status")
    parser.add_argument("--reason", default="no reason given",
                        help="Short reason for the decision (one line)")
    args = parser.parse_args()

    path = Path(args.path).resolve()
    if not path.exists():
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        return 1
    if not path.name.startswith("auto-") or not path.name.endswith(".md"):
        print(f"ERROR: not an auto-*.md incident file: {path}", file=sys.stderr)
        return 1

    # trail/incidents/<file> → project root (two levels up from incidents dir)
    project_dir = path.parent.parent.parent
    append_trace(project_dir, f"start path={path.name} status={args.status}")
    try:
        result = update_status(path, args.status, args.reason)
        append_trace(project_dir, f"ok path={path.name} result={result}")
    except ValueError as e:
        append_trace(project_dir, f"error path={path.name} err={e}")
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    if result == "noop":
        print(f"NOOP: {path.name} already {args.status}")
    else:
        print(f"OK: {path.name} → {args.status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
