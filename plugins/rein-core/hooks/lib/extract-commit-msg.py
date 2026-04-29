#!/usr/bin/env python3
"""Extract the commit message first-line from a raw bash COMMAND string.

Used by pre-bash-guard.sh to validate conventional commit format in a way
that is robust against three historical bugs:

  1) Compound commands like `<commit-cmd> && git tag -m "..."` where the
     previous extractor conflated the tag's -m argument with the commit's.
  2) Heredoc-based commit messages `-m "$(cat <<'EOF' ... EOF)"` which the
     previous sed-based extractor silently failed on, bypassing validation.
  3) Conventional commits scope notation `fix(auth): foo` which the previous
     regex rejected.

Usage:
    extract-commit-msg.py <COMMAND>

Exit 0 with the extracted first line on stdout, or exit 0 with empty stdout
if no commit-style -m was found. Never throws — pre-bash-guard should treat
empty output as "skip format check".
"""

import re
import sys


def find_separator(s: str) -> int:
    """Return index of the first shell separator (&&, ||, ;, |) outside quotes.

    Escape-aware: inside double quotes, ``\\"`` and ``\\$`` and other
    backslash-escaped chars do not toggle quote state. Single quotes do not
    process escapes (POSIX). This matches bash word splitting closely enough
    for our use case (locating the end of the commit invocation in a
    compound command).
    """
    in_dq = in_sq = False
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        # Escaped char inside double quotes: skip both bytes.
        if c == "\\" and in_dq and i + 1 < n:
            i += 2
            continue
        # Outside any quotes, a backslash also escapes the next char.
        if c == "\\" and not in_dq and not in_sq and i + 1 < n:
            i += 2
            continue
        if c == '"' and not in_sq:
            in_dq = not in_dq
            i += 1
            continue
        if c == "'" and not in_dq:
            in_sq = not in_sq
            i += 1
            continue
        if not in_dq and not in_sq:
            if s[i:i + 2] in ("&&", "||"):
                return i
            if c in (";", "|"):
                return i
        i += 1
    return n


def extract(cmd: str) -> str:
    """Return the first line of the commit message, or ''."""
    m = re.search(r"\bgit\s+commit\b", cmd)
    if not m:
        return ""

    rest = cmd[m.end():]
    scope = rest[:find_separator(rest)]

    # 1) heredoc: <<TAG / <<'TAG' / <<-TAG. The closing marker must occupy
    # its own line (optional leading whitespace, then EOL or end-of-string)
    # to avoid prefix-matching inside longer markers like EOF-TAG.
    h = re.search(
        r"<<-?\s*(?:'(\w[\w-]*)'|\"(\w[\w-]*)\"|(\w[\w-]*))[^\n]*\n"
        r"(.*?)\n[ \t]*(?:\1|\2|\3)[ \t]*(?:\n|$)",
        scope,
        re.DOTALL,
    )
    if h:
        first = h.group(4).split("\n", 1)[0].strip()
        if first:
            return first

    # 2) -m "..." or --message "..."
    dq = re.search(r'(?:-m|--message)\s+"([^"]*)"', scope)
    if dq:
        first = dq.group(1).split("\n", 1)[0].strip()
        if first:
            return first

    # 3) -m '...' or --message '...'
    sq = re.search(r"(?:-m|--message)\s+'([^']*)'", scope)
    if sq:
        first = sq.group(1).split("\n", 1)[0].strip()
        if first:
            return first

    # 4) --message=VALUE (quoted or single bare token)
    eq = re.search(r"--message=(?:\"([^\"]*)\"|'([^']*)'|(\S+))", scope)
    if eq:
        val = eq.group(1) or eq.group(2) or eq.group(3) or ""
        first = val.split("\n", 1)[0].strip()
        if first:
            return first

    return ""


def main() -> int:
    try:
        cmd = sys.argv[1] if len(sys.argv) > 1 else ""
        result = extract(cmd)
        if result:
            sys.stdout.write(result + "\n")
        return 0
    except Exception:
        return 0


if __name__ == "__main__":
    sys.exit(main())
