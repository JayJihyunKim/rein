#!/usr/bin/env python3
"""Shared block-log writer — masking + split write + live-only count (SSOT).

v1 safety release ① (trail/dod/dod-2026-08-07-v1-safety-prerelease.md):
the git-tracked incident log must never carry raw command text or secret
values. Callers (lib/bash-guard-infra.sh log_block, pre-edit-dod-gate.sh
log_block) delegate here so the masking rules and record schema live in
exactly one place.

Usage:
    rein-log-block.py HOOK REASON TARGET TRACKED_JSONL RAW_JSONL MODE TEST_MODE

    MODE       "command" — TARGET is shell command text. The tracked record
                 stores only "<verb> #<sha12>" (no raw text at all).
               "path"    — TARGET is a file path / short literal. The tracked
                 record stores the masked literal (paths are already visible
                 in git; masking is defensive).
    TEST_MODE  "1" → source=test (excluded from the repeat-warning count and
               from incident aggregation), anything else → source=live.

stdout: the live count of (hook, reason) records — legacy records without a
source field count as live (never under-warn on old data). Logging is
best-effort: any unexpected error still prints a count (0) and exits 0 so the
caller's deny/exit semantics are unaffected.
"""
import hashlib
import json
import re
import sys
from datetime import datetime, timezone

RAW_ROTATE_THRESHOLD = 1000  # rotate when the raw log exceeds this many lines
RAW_ROTATE_KEEP = 500        # lines kept after rotation

# Masking: value-bearing secret patterns. The tracked file never receives raw
# command text, so these guard the *local* raw log (and path-mode literals).
_MASK_PATTERNS = [
    # Authorization: Bearer xyz / authorization=xyz — mask the whole value.
    (re.compile(r"(?i)(authorization\s*[:=]\s*)(\S+(?:\s+\S+)?)"), r"\1<REDACTED>"),
    # key=value / key: value for identifiers containing a sensitive keyword.
    # NOT \b-anchored: \b treats "_" as a word char, so GITHUB_TOKEN= /
    # AWS_SECRET_ACCESS_KEY= (the most common env-var secret shapes) would
    # slip through a \btoken\b match (sonnet-fallback review R1 High).
    # Over-masking lookalikes (e.g. "tokenize=") is the accepted fail-closed
    # direction — this feeds a local debug log, not a precision report.
    (re.compile(
        r"(?i)([A-Za-z0-9_-]*(?:token|secret|password|passwd|pwd|"
        r"api[_-]?key|apikey|access[_-]?key|credential[s]?|auth)"
        r"[A-Za-z0-9_-]*)(\s*[=:]\s*)(\S+)"),
     r"\1\2<REDACTED>"),
    # URL credentials: scheme://user:pass@host
    (re.compile(r"://([^/\s:@]+):([^/\s@]+)@"), r"://<REDACTED>@"),
    # Basic-auth flag values: curl -u user:pass / --user user:pass.
    # Colon required so numeric/uid usages (`useradd -u 1000`) stay untouched.
    (re.compile(r"(^|\s)(-u|--user)(\s+)([^\s:]+:\S+)"), r"\1\2\3<REDACTED>"),
    # Standalone bearer tokens.
    (re.compile(r"(?i)\b(bearer)\s+(\S+)"), r"\1 <REDACTED>"),
]

# Wrappers/verbs whose first argument is the meaningful subcommand.
_SUBCOMMAND_VERBS = {
    "git", "npm", "pnpm", "yarn", "docker", "kubectl", "python", "python3",
    "bash", "sh", "uv", "pip", "pip3", "cargo", "make", "gh", "rein",
}
_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def mask(text):
    for pattern, repl in _MASK_PATTERNS:
        text = pattern.sub(repl, text)
    return text


def safe_command_repr(target):
    """Tracked-file representation of a command: verb + content hash only."""
    tokens = target.split()
    i = 0
    while i < len(tokens) and _ENV_ASSIGN.match(tokens[i]):
        i += 1
    verb = tokens[i] if i < len(tokens) else ""
    if verb in _SUBCOMMAND_VERBS and i + 1 < len(tokens) \
            and not tokens[i + 1].startswith("-"):
        verb = verb + " " + tokens[i + 1]
    verb = mask(verb)[:48] if verb else "unknown"
    sha = hashlib.sha256(target.encode("utf-8", "replace")).hexdigest()[:12]
    return "%s #%s" % (verb, sha)


def append_line(path, record):
    import os
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def rotate_raw(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
        if len(lines) > RAW_ROTATE_THRESHOLD:
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(lines[-RAW_ROTATE_KEEP:])
    except OSError:
        pass


def live_count(tracked_path, hook, reason):
    n = 0
    try:
        with open(tracked_path, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("hook") == hook and e.get("reason") == reason \
                        and e.get("source", "live") != "test":
                    n += 1
    except OSError:
        pass
    return n


def main(argv):
    hook, reason, target, tracked_path, raw_path, mode, test_mode = argv[1:8]
    source = "test" if test_mode == "1" else "live"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")

    if mode == "command":
        tracked_target = safe_command_repr(target)
    else:
        tracked_target = mask(target)[:200]

    append_line(tracked_path, {
        "ts": ts, "hook": hook, "reason": reason,
        "target": tracked_target, "source": source,
    })
    append_line(raw_path, {
        "ts": ts, "hook": hook, "reason": reason,
        "target": mask(target), "source": source,
    })
    rotate_raw(raw_path)
    print(live_count(tracked_path, hook, reason))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception:
        # Best-effort logging: never break the caller's block/deny path.
        print(0)
