#!/usr/bin/env python3
"""Phase 2c HK-5: stdin 으로 NUL-delimited PostToolUse envelope JSON 들을 받아
모든 hookSpecificOutput.additionalContext 를 "\n\n---\n\n" separator 로 concat
하여 단일 envelope JSON 으로 stdout 출력.

호출 패턴 (post-edit-aggregator.sh):

    output_cache_collect "$tool_use_id" | python3 aggregate-envelopes.py

stdin 이 비어 있거나 parse 가능한 envelope 이 하나도 없으면 silent exit 0
(stdout empty) — aggregator caller 가 이를 보고 print skip 결정.
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    raw = sys.stdin.buffer.read()
    if not raw:
        return 0

    parts = [p for p in raw.split(b"\x00") if p.strip()]
    contexts: list[str] = []

    for part in parts:
        try:
            env = json.loads(part)
        except Exception:
            continue
        if not isinstance(env, dict):
            continue
        hso = env.get("hookSpecificOutput")
        if not isinstance(hso, dict):
            continue
        ctx = hso.get("additionalContext")
        if not isinstance(ctx, str) or not ctx:
            continue
        contexts.append(ctx)

    if not contexts:
        return 0

    merged_ctx = "\n\n---\n\n".join(contexts)
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": merged_ctx,
        }
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
