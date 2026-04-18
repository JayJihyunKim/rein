#!/usr/bin/env python3
"""Emit Stop hook block JSON. Input: pending count as argv[1].

Separated as a standalone script so that Stop hook shell code stays tiny and
the JSON generation is safe (json.dumps escapes all special characters).
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("ERROR: pending count required", file=sys.stderr)
        return 1
    try:
        pending = int(sys.argv[1])
    except ValueError:
        print(f"ERROR: invalid pending count: {sys.argv[1]!r}", file=sys.stderr)
        return 1

    if pending <= 0:
        print(f"ERROR: pending count must be positive, got {pending}", file=sys.stderr)
        return 1

    payload = {
        "decision": "block",
        "reason": (
            f"pending incident {pending}건. "
            f"/incidents-to-rule 호출 후 /incidents-to-agent 호출하여 "
            f"rule/agent 승격 여부를 결정하세요. "
            f"보류 시 touch trail/dod/.incident-decision-deferred."
        ),
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
