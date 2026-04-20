#!/usr/bin/env python3
"""Extract fields from a Claude Code hook JSON payload delivered on stdin.

Hooks receive a JSON object on stdin describing the tool invocation.  This
helper provides a safe, testable CLI so every hook can delegate all JSON
parsing to one place rather than scattering fragile ``python3 -c`` one-liners.

Exit codes
----------
0  : success — all requested fields resolved; values written to stdout
20 : invalid JSON (JSONDecodeError)
21 : a requested field/path is missing AND no --default was supplied
22 : stdin could not be decoded as UTF-8 (CRLF payloads are NOT a failure)

Usage examples
--------------
# Simple dotted-path field extraction
echo '{"tool_input":{"file_path":"/a/b"}}' | extract-hook-json.py \\
    --field tool_input.file_path

# Array-of with subfield — extracts file_path from each edit element
echo '{"edits":[{"file_path":"/a"},{"file_path":"/b"}]}' | extract-hook-json.py \\
    --array-of edits --subfield file_path

# Multiple field types mixed, with safe default on missing
echo '{"a":"x","b":[{"c":1},{"c":2}]}' | extract-hook-json.py \\
    --field a --array-of b --subfield c --default ''
"""

import argparse
import json
import re
import sys
from typing import Any, Optional


# ---------------------------------------------------------------------------
# Input loading
# ---------------------------------------------------------------------------

def load_payload(source: Optional[str]) -> Any:
    """Read and parse the JSON payload.

    Args:
        source: Path to an input file, or ``None`` to read from stdin.

    Returns:
        The parsed JSON value (typically a dict).

    Raises:
        SystemExit(20): The input is not valid JSON.
        SystemExit(22): The byte stream cannot be decoded as UTF-8.
            CRLF line endings are **not** an error; the standard ``json``
            module handles them transparently.
    """
    try:
        if source is not None:
            with open(source, "rb") as fh:
                raw = fh.read()
        else:
            raw = sys.stdin.buffer.read()
    except OSError as exc:
        print(f"extract-hook-json: cannot read input: {exc}", file=sys.stderr)
        sys.exit(22)

    try:
        text = raw.decode("utf-8")
    except (UnicodeDecodeError, ValueError) as exc:
        print(f"extract-hook-json: UTF-8 decode error: {exc}", file=sys.stderr)
        sys.exit(22)

    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        print(f"extract-hook-json: invalid JSON: {exc}", file=sys.stderr)
        sys.exit(20)


# ---------------------------------------------------------------------------
# Path handling
# ---------------------------------------------------------------------------

_BRACKET_RE = re.compile(r"\[(\d+)\]")


def normalize_path(raw_path: str) -> str:
    """Convert bracket notation to dotted notation.

    ``a[0].b``  →  ``a.0.b``
    ``a[0][1]`` →  ``a.0.1``

    Args:
        raw_path: A dotted or bracket-style path string.

    Returns:
        The normalised dotted path string.
    """
    return _BRACKET_RE.sub(r".\1", raw_path)


def _parse_segments(dotted: str) -> list[str]:
    """Split a normalised dotted path into individual segments."""
    return dotted.split(".")


def resolve_field(data: Any, dotted_path: str) -> tuple[bool, Any]:
    """Walk *data* following *dotted_path* and return the value.

    Each segment of the path is applied in order:
    - If the segment is a decimal integer literal, it is used as a list index.
    - Otherwise it is used as a dict key.
    - A type mismatch or key/index error is treated as *missing*.

    Args:
        data: The root parsed JSON object.
        dotted_path: The field path, already bracket-normalised is fine too
            (``normalize_path`` is called internally).

    Returns:
        A ``(found, value)`` tuple.  ``found`` is ``False`` when any segment
        along the path is absent or of the wrong type.
    """
    path = normalize_path(dotted_path)
    segments = _parse_segments(path)
    node: Any = data
    for seg in segments:
        if seg == "":
            # Ignore empty segments produced by leading/trailing dots.
            continue
        try:
            if seg.lstrip("-").isdigit():
                idx = int(seg)
                node = node[idx]
            else:
                node = node[seg]
        except (KeyError, IndexError, TypeError):
            return False, None
    return True, node


# ---------------------------------------------------------------------------
# Array-of resolution
# ---------------------------------------------------------------------------

def resolve_array_of(
    data: Any,
    array_path: str,
    subfield: Optional[str],
    default: Optional[str],
) -> tuple[bool, list[str]]:
    """Resolve ``--array-of`` *array_path* optionally drilling into *subfield*.

    Args:
        data: The root parsed JSON object.
        array_path: Dotted path to the array within *data*.
        subfield: When supplied and an element is a dict, extract this key
            from each element.  When ``None``, dicts are serialised with
            ``json.dumps``.
        default: Fallback value when a subfield key is missing from an element.
            ``None`` means "skip the element silently".

    Returns:
        A ``(ok, values)`` tuple where *ok* is ``False`` when *array_path*
        itself is missing or does not point to a list.  Individual missing
        subfields do not make *ok* False; they produce the *default* value
        (or are omitted when *default* is ``None``).
    """
    found, arr = resolve_field(data, array_path)
    if not found or not isinstance(arr, list):
        return False, []

    results: list[str] = []
    for element in arr:
        if isinstance(element, dict):
            if subfield is not None:
                if subfield in element:
                    results.append(str(element[subfield]))
                elif default is not None:
                    results.append(default)
                # else: no default → silently skip this element
            else:
                results.append(json.dumps(element, ensure_ascii=False))
        else:
            results.append(str(element))
    return True, results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Extract fields from a Claude Code hook JSON payload.",
        epilog=(
            "Examples:\n"
            "  echo '{\"tool_input\":{\"file_path\":\"/a/b\"}}' | %(prog)s"
            " --field tool_input.file_path\n"
            "  echo '{\"edits\":[{\"file_path\":\"/a\"},{\"file_path\":\"/b\"}]}'"
            " | %(prog)s --array-of edits --subfield file_path\n"
            "  echo '{\"a\":\"x\",\"b\":[{\"c\":1}]}' | %(prog)s"
            " --field a --array-of b --subfield c --default ''\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "--stdin",
        dest="use_stdin",
        action="store_true",
        default=True,
        help="Read JSON from stdin (default).",
    )
    source.add_argument(
        "--input-file",
        metavar="PATH",
        dest="input_file",
        default=None,
        help="Read JSON from a file instead of stdin.",
    )
    parser.add_argument(
        "--field",
        metavar="DOTTED.PATH",
        dest="fields",
        action="append",
        default=None,
        help=(
            "Dotted path to extract (repeatable).  Integer segments are list "
            "indices; others are dict keys.  Bracket notation a[0].b is "
            "normalised to a.0.b automatically."
        ),
    )
    parser.add_argument(
        "--array-of",
        metavar="ARRAY.PATH",
        dest="arrays",
        action="append",
        default=None,
        help=(
            "Dotted path to a list; each element is emitted on its own line "
            "(repeatable).  Pair with --subfield to drill into dict elements."
        ),
    )
    parser.add_argument(
        "--subfield",
        metavar="FIELD",
        dest="subfield",
        default=None,
        help=(
            "When an --array-of element is a dict, extract this key.  "
            "Elements missing the key are omitted unless --default is given."
        ),
    )
    parser.add_argument(
        "--default",
        metavar="STR",
        dest="default",
        default=None,
        help=(
            "Value to emit for any missing field or array-of path.  "
            "When present, a missing field never causes exit 21."
        ),
    )
    parser.add_argument(
        "--strip-newlines",
        dest="strip_newlines",
        action="store_true",
        default=False,
        help="Remove all CR (\\r) and LF (\\n) characters from each extracted value.",
    )
    parser.add_argument(
        "--separator",
        metavar="STR",
        dest="separator",
        default="\n",
        help="String used to join multiple values (default: newline).",
    )
    return parser


def main() -> int:  # noqa: C901 — acceptable complexity for a CLI dispatcher
    parser = _build_parser()
    args = parser.parse_args()

    fields: list[str] = args.fields or []
    arrays: list[str] = args.arrays or []

    if not fields and not arrays:
        parser.error("at least one of --field or --array-of is required")

    # Load JSON payload
    data = load_payload(args.input_file)

    # Collect values in argparse argv order.
    # Because argparse appends to separate lists we cannot interleave them
    # directly; however the task specification states:
    #   "argparse 순서대로 평면화" — the caller controls order via argv.
    # We reconstruct the intended order by scanning sys.argv for the option
    # names so that --field a --array-of b --field c produces [a, b[], c].
    ordered_specs: list[tuple[str, str]] = []  # (kind, value)
    field_iter = iter(fields)
    array_iter = iter(arrays)
    i = 1
    argv = sys.argv[1:]
    n = len(argv)
    while i <= n:
        tok = argv[i - 1] if i <= n else None
        if tok == "--field":
            try:
                ordered_specs.append(("field", next(field_iter)))
            except StopIteration:
                pass
            i += 2
        elif tok is not None and tok.startswith("--field="):
            # argparse 의 --field=VAL equal-sign 형태도 순서 보존 대상.
            try:
                ordered_specs.append(("field", next(field_iter)))
            except StopIteration:
                pass
            i += 1
        elif tok == "--array-of":
            try:
                ordered_specs.append(("array", next(array_iter)))
            except StopIteration:
                pass
            i += 2
        elif tok is not None and tok.startswith("--array-of="):
            try:
                ordered_specs.append(("array", next(array_iter)))
            except StopIteration:
                pass
            i += 1
        else:
            i += 1

    # Drain any remaining (should not happen with well-formed argv, but guard)
    for val in field_iter:
        ordered_specs.append(("field", val))
    for val in array_iter:
        ordered_specs.append(("array", val))

    collected: list[str] = []
    missing_exit: bool = False

    for kind, spec in ordered_specs:
        # Reject wildcard `*` in dotted paths: spec 는 wildcard 미지원 — 배열 순회는
        # 반드시 --array-of 로 명시해야 한다. `*` 를 silent 하게 literal dict key 로
        # 취급하던 기존 동작은 사용자 기대와 다르므로 exit 21 로 끊는다.
        if "*" in spec:
            print(
                f"extract-hook-json: wildcard '*' is unsupported in path '{spec}' "
                "(배열 순회는 --array-of 로 명시)",
                file=sys.stderr,
            )
            return 21
        if kind == "field":
            found, value = resolve_field(data, spec)
            if found:
                collected.append(str(value))
            else:
                if args.default is not None:
                    collected.append(args.default)
                else:
                    print(
                        f"extract-hook-json: missing field '{spec}'",
                        file=sys.stderr,
                    )
                    missing_exit = True
                    break
        else:  # kind == "array"
            ok, values = resolve_array_of(data, spec, args.subfield, args.default)
            if ok:
                collected.extend(values)
            else:
                if args.default is not None:
                    collected.append(args.default)
                else:
                    print(
                        f"extract-hook-json: missing or non-list path '{spec}'",
                        file=sys.stderr,
                    )
                    missing_exit = True
                    break

    if missing_exit:
        return 21

    # Apply --strip-newlines
    if args.strip_newlines:
        collected = [v.replace("\r", "").replace("\n", "") for v in collected]

    output = args.separator.join(collected)
    sys.stdout.write(output)
    if output:
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
