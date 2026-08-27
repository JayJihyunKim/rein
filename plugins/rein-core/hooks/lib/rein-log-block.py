#!/usr/bin/env python3
"""Shared block-log writer — masking + split write + live-only count (SSOT).

The git-tracked incident log must never carry raw command text, secret
values, or the operator's home directory. Callers delegate here so the
record schema and those rules live in one place. Hook callers include
`lib/bash-guard-infra.sh`'s `log_block` and the pre-edit gate family
(discipline / coverage / task), plus `pre-bash-commit-review-gate.sh`.

Masking and path rules are NOT implemented here. `mask()` delegates to
`rein.shadow.masking.redact()` and `mask_tracked_path()` adds
`rein.shadow.paths.normalize()` — those two modules are the source of
truth for what counts as a secret and which private-home shapes are
recognized. If either cannot be loaded, this file does not fall back to a
local copy of the rules (that would defeat the SSOT); it substitutes a
fixed placeholder for the whole value instead. Fail-closed everywhere:
a missing engine costs diagnostic detail, never a leak. The caller's
contract is unaffected — `main()` always prints a count and exits 0.

Both engines are loaded by direct file load
(`importlib.util.spec_from_file_location` against a self-located path,
never registered in `sys.modules`), not by dotted import. That closes
substitution of the target modules through the module cache. It does not
close stdlib/import-machinery poisoning or replacement of the expected
file on disk — both presuppose control of this process's interpreter or
of the installed tree, which is outside what a masking layer can hold.

Every sink is normalized: the tracked record's path-mode target, the
verb inside `safe_command_repr()` (an executable invoked by absolute path
would otherwise carry a username), and the local raw log. The raw log is
included because rein does not create ignore rules in a user's project,
so "it is untracked anyway" is not a guarantee outside this repository.

Review trajectory for these decisions: `docs/reports/v2-phase-gates.md`,
Phase 7 wave 4.

Usage:
    rein-log-block.py HOOK REASON TARGET TRACKED_JSONL RAW_JSONL MODE TEST_MODE

    MODE       "command" — TARGET is shell command text. The tracked record
                 stores only "<verb> #<sha12>"; the hash is over the original
                 TARGET, so records correlate across changes to the verb's
                 representation.
               "path"    — TARGET is a file path / short literal.
    TEST_MODE  "1" → source=test (excluded from the repeat-warning count and
               from incident aggregation), anything else → source=live.

stdout: the live count of (hook, reason) records — legacy records without a
source field count as live (never under-warn on old data). Logging is
best-effort: any unexpected error still prints a count (0) and exits 0 so the
caller's deny/exit semantics are unaffected.
"""
import hashlib
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone

RAW_ROTATE_THRESHOLD = 1000  # rotate when the raw log exceeds this many lines
RAW_ROTATE_KEEP = 500        # lines kept after rotation


def _locate_package_parent():
    # self-location (cwd/symlink independent), mirroring bin/rein. This
    # file sits two levels under the bundle root, so walk up three.
    here = os.path.realpath(__file__)
    return os.path.dirname(os.path.dirname(os.path.dirname(here)))


def _load_verified_symbol(module_relparts, symbol_name, private_name):
    """Load `symbol_name` straight from the self-located file, never via
    `sys.modules`/`sys.path` (see module docstring for why).

    The loaded module is deliberately not registered in `sys.modules`, so
    `private_name` is only its internal `__name__` and a collision with a
    real module name is harmless. Returns None — fail-closed — if the
    expected file is absent or the load raises.
    """
    package_parent = _locate_package_parent()
    expected_path = os.path.realpath(
        os.path.join(package_parent, *module_relparts)
    )
    if not os.path.isfile(expected_path):
        return None
    try:
        spec = importlib.util.spec_from_file_location(private_name, expected_path)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception:
        return None
    return getattr(module, symbol_name, None)


_MASK_UNAVAILABLE = "<mask-unavailable>"
_PATH_NORMALIZE_UNAVAILABLE = "<path-normalize-unavailable>"

# Import once at module load — never retried per call (hot path: every
# blocked command runs this module). On failure _v2_redact / _v2_path_normalize
# stay None and mask() / mask_tracked_path() fail closed (see docstrings).
try:
    _v2_redact = _load_verified_symbol(
        ("rein", "shadow", "masking.py"), "redact", "_rein_verified__masking"
    )
except Exception:
    _v2_redact = None

try:
    _v2_path_normalize = _load_verified_symbol(
        ("rein", "shadow", "paths.py"), "normalize", "_rein_verified__paths"
    )
except Exception:
    _v2_path_normalize = None

# Wrappers/verbs whose first argument is the meaningful subcommand.
_SUBCOMMAND_VERBS = {
    "git", "npm", "pnpm", "yarn", "docker", "kubectl", "python", "python3",
    "bash", "sh", "uv", "pip", "pip3", "cargo", "make", "gh", "rein",
}
_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def mask(text):
    """Delegate to the v2 masking SSOT (`rein.shadow.masking.redact`).

    Fail-closed: no rule is reimplemented locally, so an unavailable
    engine replaces the whole value with a placeholder.
    """
    if _v2_redact is None:
        return _MASK_UNAVAILABLE
    try:
        return _v2_redact(text)
    except Exception:
        return _MASK_UNAVAILABLE


def mask_tracked_path(text):
    """Secret masking (`mask()`) plus private-path normalization
    (`rein.shadow.paths.normalize`). Applied to every sink — see the
    module docstring.

    Normalization abbreviates a recognized home prefix to `<HOME>/...`;
    `paths.py` decides which shapes qualify. Fail-closed in two layers: an
    unavailable masking engine already closes the value, and unavailable
    normalization returns a placeholder rather than the masked-but-not-
    normalized text (which would still carry the home path).
    """
    masked = mask(text)
    if masked == _MASK_UNAVAILABLE:
        return masked
    if _v2_path_normalize is None:
        return _PATH_NORMALIZE_UNAVAILABLE
    try:
        return _v2_path_normalize(masked)
    except Exception:
        return _PATH_NORMALIZE_UNAVAILABLE


def safe_command_repr(target):
    """Tracked-file representation of a command: verb + content hash only.

    The verb goes through `mask_tracked_path()`, not plain `mask()`: an
    executable invoked by absolute path *is* the verb, so secret masking
    alone would leave a home path in it. The hash stays over the original
    `target`, so it is unaffected by how the verb is rendered.
    """
    tokens = target.split()
    i = 0
    while i < len(tokens) and _ENV_ASSIGN.match(tokens[i]):
        i += 1
    verb = tokens[i] if i < len(tokens) else ""
    if verb in _SUBCOMMAND_VERBS and i + 1 < len(tokens) \
            and not tokens[i + 1].startswith("-"):
        verb = verb + " " + tokens[i + 1]
    verb = mask_tracked_path(verb)[:48] if verb else "unknown"
    sha = hashlib.sha256(target.encode("utf-8", "replace")).hexdigest()[:12]
    return "%s #%s" % (verb, sha)


def append_line(path, record):
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


def _safe_parse_record(raw):
    """tracked jsonl 한 줄을 안전하게 파싱 — 신뢰 가능한 dict 이면 반환, 아니면
    None. 손상 바이트/깊은 중첩/비객체가 반복 경고 카운트를 죽이지 않도록
    디코딩·파싱(RecursionError 포함 넓게)·스키마 실패를 모두 흡수한다.
    (aggregate 스크립트의 동명 헬퍼와 같은 규칙 — 두 파일이 서로를 import
    하지 않으므로 작은 순수 함수를 각자 둔다.)
    """
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        rec = json.loads(raw)
    except Exception:
        return None
    return rec if isinstance(rec, dict) else None


def live_count(tracked_path, hook, reason):
    n = 0
    try:
        with open(tracked_path, "rb") as f:
            for raw in f:
                e = _safe_parse_record(raw)
                if e is None:
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
        # applies mask_tracked_path() to the verb internally
        tracked_target = safe_command_repr(target)
    else:
        tracked_target = mask_tracked_path(target)[:200]

    append_line(tracked_path, {
        "ts": ts, "hook": hook, "reason": reason,
        "target": tracked_target, "source": source,
    })
    append_line(raw_path, {
        # Local raw log: normalized too — see the module docstring for
        # why "it is gitignored" does not hold in a user's project.
        "ts": ts, "hook": hook, "reason": reason,
        "target": mask_tracked_path(target), "source": source,
    })
    rotate_raw(raw_path)
    print(live_count(tracked_path, hook, reason))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception:
        # Best-effort logging: never break the caller's block/deny path.
        print(0)
