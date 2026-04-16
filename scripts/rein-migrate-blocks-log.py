#!/usr/bin/env python3
"""기존 blocks.log (pipe 포맷) 를 blocks.jsonl 로 1회 변환.

사용법: python3 scripts/rein-migrate-blocks-log.py [project_dir]

변환 포맷: "ts|hook|reason|target" → JSON 한 줄
multi-line entries (target 에 개행 포함): 첫 줄만 보존, 경고 출력.
원본은 blocks.log.legacy 로 보존.
"""
import json
import sys
from pathlib import Path


def main():
    project = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    src = project / "trail/incidents/blocks.log"
    dst = project / "trail/incidents/blocks.jsonl"
    archive = project / "trail/incidents/blocks.log.legacy"

    if not src.exists():
        print("no blocks.log to migrate", file=sys.stderr)
        return 0

    if dst.exists():
        print(f"WARN: {dst} already exists. archive blocks.log without conversion.",
              file=sys.stderr)
        src.rename(archive)
        return 0

    converted = 0
    skipped = 0
    with open(src) as f, open(dst, "w") as out:
        for lineno, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line:
                continue
            # parts[0..3]: ts | hook | reason | target (target may contain pipes)
            parts = line.split("|", 3)
            if len(parts) < 4:
                print(f"WARN: line {lineno}: malformed (fewer than 4 fields), skipping: {line!r}",
                      file=sys.stderr)
                skipped += 1
                continue
            ts, hook, reason, target = parts
            ts = ts.strip()
            hook = hook.strip()
            reason = reason.strip()
            target = target.strip()
            # multi-line target: keep only first line, warn
            if "\n" in target:
                first_line = target.split("\n", 1)[0]
                print(f"WARN: line {lineno}: multi-line target, keeping first line only",
                      file=sys.stderr)
                target = first_line
            entry = {"ts": ts, "hook": hook, "reason": reason, "target": target}
            out.write(json.dumps(entry, ensure_ascii=False) + "\n")
            converted += 1

    src.rename(archive)
    print(f"migrated {converted} entries (skipped {skipped}). archived: {archive}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
