#!/usr/bin/env python3
"""Manage trail/agent-candidates/<hash>.md files.

Subcommands:
  create  — initialize candidate with decision=pending (skip if exists and not pending)
  decide  — set decision to approved/declined/pending with reason
"""
import argparse
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)

# hash 는 파일명 컴포넌트로 직접 사용되므로 path traversal 방지를 위해 안전 문자
# 집합으로 제한한다 (codex v0.7.2 review Medium). 기본 16자 SHA1 prefix 를 비롯한
# 사용자 정의 식별자(agent 이름 등) 도 허용하되 / 또는 `..` 등 경로 문자는 차단.
HASH_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

VALID_DECISIONS = {"pending", "approved", "declined"}


def hash_type(value: str) -> str:
    if not HASH_RE.match(value):
        raise argparse.ArgumentTypeError(
            f"invalid hash {value!r}: must match [A-Za-z0-9_-]{{1,64}}"
        )
    return value


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


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


def candidate_path(project_dir: Path, hash_: str) -> Path:
    return project_dir / "trail/agent-candidates" / f"{hash_}.md"


def render_candidate(hash_: str, source_incident: str, role: str, decision: str) -> str:
    role_escaped = role.replace('"', '\\"')
    src_escaped = source_incident.replace('"', '\\"')
    return f'''---
pattern_hash: "{hash_}"
source_incident: "{src_escaped}"
decision: "{decision}"
evaluated_at: "{utcnow_iso()}"
role_one_liner: "{role_escaped}"
---

# 에이전트 후보: {hash_}

## 역할 (한 문장)
{role}

## 근거
{source_incident}

## 기존 에이전트로 해결 불가 이유
(사용자/스킬이 기록)

## DoD
(사용자/스킬이 기록)
'''


def read_decision(path: Path) -> str:
    text = path.read_text()
    m = FRONTMATTER_RE.match(text)
    if not m:
        return ""
    for line in m.group(1).splitlines():
        if line.strip().startswith("decision:"):
            return line.split(":", 1)[1].strip().strip('"')
    return ""


def cmd_create(args: argparse.Namespace) -> int:
    project_dir = Path(args.project_dir).resolve()
    path = candidate_path(project_dir, args.hash)
    if path.exists():
        current = read_decision(path)
        if current != "pending":
            print(f"SKIP: {path.name} already decided ({current})")
            return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    content = render_candidate(args.hash, args.source_incident,
                               args.role_one_liner, "pending")
    atomic_write(path, content)
    print(f"OK: {path.name} created")
    return 0


def cmd_decide(args: argparse.Namespace) -> int:
    project_dir = Path(args.project_dir).resolve()
    path = candidate_path(project_dir, args.hash)
    if not path.exists():
        print(f"ERROR: candidate not found: {path}", file=sys.stderr)
        return 1
    text = path.read_text()
    new_lines = []
    found_decision = False
    for line in text.splitlines():
        if line.strip().startswith("decision:"):
            new_lines.append(f'decision: "{args.decision}"')
            found_decision = True
        elif line.strip().startswith("evaluated_at:"):
            new_lines.append(f'evaluated_at: "{utcnow_iso()}"')
        else:
            new_lines.append(line)
    if not found_decision:
        print(f"ERROR: decision field not found in {path}", file=sys.stderr)
        return 1
    atomic_write(path, "\n".join(new_lines) + "\n")
    print(f"OK: {path.name} → {args.decision} ({args.reason})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_create = sub.add_parser("create")
    p_create.add_argument("--hash", required=True, type=hash_type)
    p_create.add_argument("--source-incident", required=True)
    p_create.add_argument("--role-one-liner", required=True)
    p_create.add_argument("--project-dir", default=".")

    p_decide = sub.add_parser("decide")
    p_decide.add_argument("--hash", required=True, type=hash_type)
    p_decide.add_argument("--decision", required=True, choices=sorted(VALID_DECISIONS))
    p_decide.add_argument("--reason", default="")
    p_decide.add_argument("--project-dir", default=".")

    args = parser.parse_args()
    if args.cmd == "create":
        return cmd_create(args)
    return cmd_decide(args)


if __name__ == "__main__":
    sys.exit(main())
