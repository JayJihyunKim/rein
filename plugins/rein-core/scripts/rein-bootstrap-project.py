#!/usr/bin/env python3
"""Bootstrap Rein repo-local state without mutating plugin settings.

This helper is intended for plugin installs where the plugin is already
enabled but the current git repository has not been initialized for Rein yet.
It creates only repo-local state: ``.rein/``, ``.rein/policy/``, and
``trail/``. It deliberately refuses Claude plugin cache/marketplace paths so a
mis-resolved cwd cannot pollute the plugin installation cache.

``--project-dir`` must resolve to a git
repository. A non-git directory is refused by default because Rein's review
and commit gates (and their record-keeping) are bound to git state — without
a repository only the edit gate is meaningful. Pass ``--allow-non-git`` to
initialize repo-local state in a non-git directory anyway (the v1.1.1
fallback: ``trail/`` + ``.rein/`` created in place, no git command is ever
invoked).

Pass ``--ensure-gitignore`` for a separate heal-only sub-mode: for an
ALREADY-bootstrapped ``--project-dir`` (has ``.rein/project.json``) inside a
git repository, it appends any missing rein runtime ``.gitignore`` patterns
and exits 0 — every other flag is ignored, and it creates nothing else (no
trail/, no policy dir, no marker). A non-git or un-bootstrapped
``--project-dir`` is a silent no-op (exit 0). Intended for a session-start
hook to call best-effort on every session so a project bootstrapped before
``REIN_RUNTIME_GITIGNORE_PATTERNS`` grew (e.g. before ``/.rein/state.json``
was added) gets healed without a full re-bootstrap.

Exit codes:
  0                       success (git repo, or non-git with --allow-non-git)
  2                       generic safety refusal (sensitive path, plugin
                          storage, git-root mismatch, symlinked .gitignore —
                          see ``fail()``)
  NON_GIT_REFUSED_EXIT    ``--project-dir`` is not a git repository and
                          --allow-non-git was not passed (module-level
                          constant below; distinct from both the generic exit
                          2 above and lib/bootstrap-check.sh's own bash-side
                          codes 10/11, which are a different tool answering a
                          different question — "has bootstrap already run",
                          not "is this a git repo")
  DEGRADED_MARKER_STUCK_EXIT
                          repo-local state (trail/, .rein/) was written
                          successfully, but a stale SessionStart degraded
                          marker under .claude/cache could not be removed
                          (module-level constant below). Governance stays
                          off for the rest of the session until the marker
                          is removed by hand or the session is restarted.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import signal
import stat
import subprocess
import sys
from pathlib import Path

try:
    import fcntl
except ImportError:  # non-POSIX — bootstrap already fails on missing O_NOFOLLOW
    fcntl = None


TRAIL_SUBDIRS = (
    "inbox",
    "daily",
    "weekly",
    "decisions",
    "dod",
    "incidents",
    "agent-candidates",
)

POLICY_HOOKS_TEMPLATE = """# .rein/policy/hooks.yaml
#
# Operational profile (Phase 4):
#   profile: lean       # exploratory work — disables plan-coverage, spec-review-gate, dod-routing-check
#   profile: standard   # (default) all gates enabled
#   profile: strict     # release / security-sensitive — reserved for stricter future defaults
#
# Per-hook toggles (override the profile):
#   <hook-name>: false                # disable
#   <hook-name>: { enabled: false }   # equivalent structured form
#
# Resolution: per-hook entry > profile default > built-in default (enabled).
# Empty file = use plugin defaults (everything enabled).
"""

POLICY_RULES_TEMPLATE = """# .rein/policy/rules.yaml
# Add <rule-name>: | followed by replacement rule text to override bundled
# prompt rules for this repo. Empty file = use plugin defaults.
"""

POLICY_PERSONA_TEMPLATE = """# .rein/policy/persona.yaml
#
# Persona layer — OFF by default (neutral). Only an explicit `enabled: true`
# activates it; the response rules always win over any persona.
#
# Built-in presets: boss-ace, jennie, choi-haengbae
# Custom presets live in .rein/policy/persona/<name>.md (create them via the
# persona skill — ask "페르소나 만들어줘" / "pick a persona").
#
# To enable:
#   enabled: true
#   preset: boss-ace
enabled: false
"""

INDEX_TEMPLATE = """# trail/index.md

> Rein 프로젝트 상태 — 매 세션 종료 시 갱신.
"""

SECURITY_PROFILE_TEMPLATE = """# 이 파일은 rein bootstrap 이 생성한 default. 프로젝트 정책에 맞게 수정.
# 가벼운 검사는 `security_level: base`, 더 엄격한 검사는 `security_level: strict`
# (strict 는 미정의 — 사용자 정의 필요). rules 본문은 plugin source 에서 자동 read;
# 본문 자체를 override 하려면 `.claude/security/rules/<level>.md` 를 직접 생성.
security_level: standard
"""


def _read_plugin_version() -> str:
    """Read version from the plugin's .claude-plugin/plugin.json manifest.

    BG-F (v1.3.0): the bootstrap CLI's --version default historically hardcoded
    "1.0.0", which drifted from the plugin.json SoT (e.g. v1.2.0). Reading the
    manifest dynamically keeps `.rein/project.json` in sync with the installed
    plugin version. Falls back to "1.0.0" if the manifest is unreadable so the
    bootstrap remains usable even when run from an unusual location.
    """
    try:
        plugin_root = Path(__file__).resolve().parent.parent
        manifest = plugin_root / ".claude-plugin" / "plugin.json"
        return json.loads(manifest.read_text(encoding="utf-8"))["version"]
    except Exception:
        return "1.0.0"  # last-resort fallback


# Distinct exit code for "project_dir is not a git repository and
# --allow-non-git was not passed" — see the module docstring's exit-code
# table. Kept apart from fail()'s generic 2 so callers/tests can distinguish
# "not a git repo" from every other safety refusal.
NON_GIT_REFUSED_EXIT = 3

# Distinct exit code for "bootstrap itself succeeded, but the stale
# SessionStart degraded marker could not be removed" — see the module
# docstring's exit-code table and _clear_degraded_marker(). Kept apart from
# both NON_GIT_REFUSED_EXIT and fail()'s generic 2 so callers/tests can
# distinguish this class of failure (governance stays dormant despite a
# reported success) from every other exit path.
DEGRADED_MARKER_STUCK_EXIT = 4

# Upper bounds so a session-start heal call can never hang the hook that
# waits on it: git probe subprocess timeout, and a SIGALRM hard stop for the
# whole `--ensure-gitignore` sub-mode (default SIGALRM action terminates the
# process; the calling hook treats any non-zero exit as best-effort).
GIT_PROBE_TIMEOUT_SECONDS = 10
ENSURE_GITIGNORE_TIMEOUT_SECONDS = 15


def fail(message: str, code: int = 2) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def is_plugin_storage(path: Path) -> bool:
    normalized = str(path.resolve())
    return normalized.endswith("/.claude/plugins") or "/.claude/plugins/" in normalized


def _refuse_sensitive_or_unsafe(project_dir: Path) -> None:
    """Mirror bootstrap-check.sh helper's safety net.

    Reject sensitive paths (filesystem root, $HOME) and plugin cache paths so a
    mis-resolved or copy-pasted --project-dir cannot pollute system locations.
    Plugin storage prefix (~/.claude/plugins/...) remains covered by the existing
    ``is_plugin_storage`` check; this helper extends coverage to (1) "/" and
    (2) ``$HOME`` and (3) ``~/.claude/plugins/cache/...`` explicitly.
    """
    resolved = project_dir.resolve()

    # (1) sensitive path: filesystem root
    if str(resolved) == "/":
        fail(f"refusing to bootstrap filesystem root: {resolved}")

    # (2) sensitive path: $HOME
    home = Path.home().resolve()
    if resolved == home:
        fail(f"refusing to bootstrap home directory: {resolved}")

    # (3) plugin cache path: ~/.claude/plugins/cache/* prefix
    plugin_cache = (home / ".claude" / "plugins" / "cache").resolve()
    try:
        resolved.relative_to(plugin_cache)
        fail(f"refusing to bootstrap inside plugin cache: {resolved}")
    except ValueError:
        pass  # not under plugin cache — OK


# Env vars stripped from every git subprocess this script spawns — mirrors
# hooks/lib/bootstrap-check.sh's own git walk-up sanitization so an
# inherited GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / GIT_INDEX_FILE cannot
# redirect discovery onto an unrelated repository (a caller might invoke
# this script directly, not only via session-start-bootstrap.sh's own
# stripped invocation). GIT_CEILING_DIRECTORIES is deliberately left in
# place — policy-sensitive, left to the caller.
_GIT_ENV_STRIP_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
)


def _git_subprocess_env() -> dict[str, str]:
    env = os.environ.copy()
    for name in _GIT_ENV_STRIP_VARS:
        env.pop(name, None)
    return env


def git_root_for(path: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_git_subprocess_env(),
            timeout=GIT_PROBE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    # Capture bytes (no text=True) and remove exactly ONE trailing LF — git's
    # own line terminator — rather than result.stdout.strip(), which would
    # also eat a trailing newline (or other whitespace) that is part of the
    # directory name itself. os.fsdecode (surrogateescape) mirrors how the
    # OS handed the path to git in the first place.
    raw = result.stdout
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    root = os.fsdecode(raw)
    return Path(root).resolve() if root else None


def write_text_if_missing(path: Path, content: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


# Rein runtime state paths that must stay OUT of git. Kept in sync with this
# repo's own .gitignore and with rein/platform/storage/local.py's
# GITIGNORE_PATTERN ("/.rein/state/"). `/.rein/state.json` / `/.rein/
# state-pending-*.log` / `/.rein/.onboarded` cover the hook-rewritten
# runtime files that live directly under `.rein/` (not inside one of the
# three directories above) — without them a bootstrapped project tracks
# `.rein/state.json` by default, and every hook invocation that rewrites it
# changes the review-subject digest out from under an in-flight review.
REIN_RUNTIME_GITIGNORE_PATTERNS = (
    "/.rein/state/",
    "/.rein/cache/",
    "/.rein/logs/",
    "/.rein/state.json",
    "/.rein/state-pending-*.log",
    "/.rein/.onboarded",
)


def ensure_rein_runtime_gitignored(root: Path) -> bool:
    """Idempotently register rein's runtime state dirs in the project's .gitignore.

    Returns True when a pattern was actually appended, False when every
    pattern was already present (no-op) — callers that only want to notify
    the user on a real change (the ``--ensure-gitignore`` sub-mode below)
    use this to stay silent on repeat runs.

    Without this, `.rein/state/` (the evidence ledger) is untracked and gets
    swept into `worktree_changeset()` (git status --untracked-files=all), so the
    very first evidence issuance changes its own review subject and
    self-invalidates — the gate fails closed and locks the user out. The storage
    layer (rein/platform/storage/local.py) already documents that a `.gitignore`
    `/.rein/state/` pattern guarantees non-tracking; this makes bootstrap
    actually create it. Existing content and ordering are preserved (append
    only); patterns already present are not duplicated.

    Threat model: honest user. A symlinked .gitignore is refused via O_NOFOLLOW
    (this protects the legitimate dotfiles case where .gitignore is a symlink).
    Hardlinks and other adversarial self-targeting of the write are OUT of scope
    — rein's threat model is an honest agent/user, not a user attacking their own
    project (see the release-gate DoD's threat-model note).
    """
    gitignore = root / ".gitignore"
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if nofollow == 0:
        # This platform (e.g. a native-Windows Python) lacks O_NOFOLLOW, so we
        # cannot atomically refuse a symlinked .gitignore — the append could be
        # redirected outside the project. rein targets POSIX/WSL; fail loudly
        # rather than silently weaken the no-symlink-follow contract to
        # best-effort.
        fail(
            "O_NOFOLLOW is unavailable on this platform — cannot safely write "
            f"{gitignore}. rein requires POSIX/WSL; register "
            f"{', '.join(REIN_RUNTIME_GITIGNORE_PATTERNS)} manually."
        )

    # ONE descriptor for the whole read → compute-missing → append sequence,
    # held under an exclusive lock: two concurrent callers (parallel
    # SessionStart hooks of the same project) would otherwise both read the
    # old content and both append the same block. O_NOFOLLOW refuses a
    # SYMLINKED .gitignore atomically at open time (an append through a
    # symlink could land OUTSIDE the project) — no TOCTOU window between an
    # is_symlink() check and the write; a symlink means we cannot safely
    # register the patterns, so the whole bootstrap FAILS (leaving
    # `.rein/state/` tracked while the completion sentinel is written would
    # stamp the project "bootstrapped" with the self-invalidation live).
    # O_NONBLOCK keeps a FIFO at this path from parking us in open(2) (the
    # session-start hook waits on this call synchronously); the fstat right
    # after refuses anything that is not a regular file.
    nonblock = getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(
            gitignore,
            os.O_RDWR | os.O_APPEND | os.O_CREAT | nofollow | nonblock,
            0o644,
        )
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            fail(
                f".gitignore is a symlink: {gitignore} — refusing to follow it. "
                f"Register {', '.join(REIN_RUNTIME_GITIGNORE_PATTERNS)} in the "
                "real file, then re-run."
            )
        if exc.errno in (errno.ENXIO, errno.EISDIR):
            # ENXIO: reader-less FIFO under O_NONBLOCK on platforms that
            # refuse O_RDWR on pipes; EISDIR: a directory at the path. Same
            # refusal as the fstat check below, without a traceback.
            fail(f".gitignore is not a regular file: {gitignore} — refusing to touch it.")
        raise
    try:
        _refuse_non_regular_gitignore(fd, gitignore)
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        existing = _read_all(fd)

        # Exact-line match (no strip): git treats a LEADING space as part of
        # the pattern, so " /.rein/state/" does NOT ignore .rein/state/.
        # Stripping would false-positive it as already present and skip the
        # real append, reopening the self-invalidation.
        present = set(existing.splitlines())
        missing = [p for p in REIN_RUNTIME_GITIGNORE_PATTERNS if p not in present]
        if not missing:
            return False
        prefix = "" if (not existing or existing.endswith("\n")) else "\n"
        block = prefix + "\n# Rein runtime state — git 미추적 (증거 원장/캐시/로그)\n"
        block += "\n".join(missing) + "\n"
        _write_all(fd, block.encode("utf-8"))
        return True
    finally:
        # Releases the lock too (flock is per open file description).
        os.close(fd)


def _read_all(fd: int) -> str:
    """Read the whole .gitignore without ever raising on its bytes.

    Contract: `.gitignore` is a byte file to git, not a UTF-8 file — a
    project's existing comments may be Latin-1 or any other encoding we
    have no reason to assume. Bytes that are not valid UTF-8 are decoded
    with the ``surrogateescape`` error handler so they round-trip losslessly
    (re-encoding the result with the same handler reproduces the original
    bytes exactly); we never re-encode this return value ourselves (writes
    are append-only via ``_write_all`` on our own newly built, surrogate-free
    ``block``, so
    the original bytes on disk are never rewritten). Rejecting a non-UTF-8
    file here instead would lock legitimate Latin-1 (or other non-UTF-8)
    projects out of bootstrap entirely — preservation, not validation, is
    the goal. The missing-pattern comparison this feeds
    (``ensure_rein_runtime_gitignored``) is line-wise against the ASCII
    patterns in ``REIN_RUNTIME_GITIGNORE_PATTERNS``, which stays correct
    regardless of what encoding the rest of the file is in.
    """
    os.lseek(fd, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", "surrogateescape")


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def _refuse_non_regular_gitignore(fd: int, gitignore: Path) -> None:
    """Fail unless ``fd`` refers to a regular file (caller owns/closes fd).

    Checked on the already-open descriptor (not on the path) so a FIFO,
    device or socket swapped in at this path cannot slip between a path
    check and the read/write.
    """
    if stat.S_ISREG(os.fstat(fd).st_mode):
        return
    fail(f".gitignore is not a regular file: {gitignore} — refusing to touch it.")


def ensure_gitignore_only(project_dir: Path) -> int:
    """``--ensure-gitignore`` sub-mode — heal an existing project's .gitignore
    without touching anything else (BG heal-existing-projects, 2026-09-04
    review-digest self-invalidation fix — see the ``docs/reports`` issue
    this closes).

    Triggers ONLY when both hold: ``<project_dir>/.rein/project.json``
    exists (already bootstrapped) AND ``project_dir`` resolves inside a git
    repository (read-only ``git rev-parse --show-toplevel`` probe via
    ``git_root_for`` — no mutating git command is ever run). Either
    condition failing is a silent no-op (exit 0): a non-git or
    un-bootstrapped directory gets no file created here — trail/, the
    policy dir, and the completion marker are ``bootstrap()``'s job, not
    this sub-mode's.

    Prints exactly one fixed line to stdout (no path — directory names may
    contain newlines) when ``ensure_rein_runtime_gitignored`` actually
    appended something; stays silent otherwise. session-start
    hooks call this on every session for every already-bootstrapped
    project, so silence-on-no-op keeps it from spamming users who have
    nothing to heal.
    """
    # Hard upper bound for the whole sub-mode (POSIX only): the calling
    # SessionStart hook waits on this process synchronously, so no code path
    # below may hang it — SIGALRM's default action terminates us, and the
    # hook treats that non-zero exit as best-effort. The timer is process-
    # wide, so it is cancelled on every exit path (an in-process caller must
    # not be killed ~15 s after a successful return).
    has_alarm = hasattr(signal, "alarm")
    if has_alarm:
        signal.alarm(ENSURE_GITIGNORE_TIMEOUT_SECONDS)
    try:
        return _ensure_gitignore_only_unbounded(project_dir)
    finally:
        if has_alarm:
            signal.alarm(0)


def _ensure_gitignore_only_unbounded(project_dir: Path) -> int:
    project_dir = project_dir.resolve()
    # is_file(), not exists(): a directory left at this path (e.g. by a
    # mis-scripted tool) must NOT count as "already bootstrapped" — exists()
    # would be true for a directory too, tricking this heal-only sub-mode
    # into touching a project that never actually completed bootstrap().
    if not (project_dir / ".rein" / "project.json").is_file():
        return 0
    if git_root_for(project_dir) is None:
        return 0
    if ensure_rein_runtime_gitignored(project_dir):
        # The path is deliberately NOT echoed: a directory name may contain
        # newlines, which would break the one-line stdout contract above.
        print("[bootstrap] registered rein runtime .gitignore patterns (.rein/state.json etc.)")
    return 0


def ensure_security_profile(project_root: Path) -> None:
    """Create default `.claude/security/profile.yaml` if absent (SEC-1).

    Writes only the profile (idempotent — never overwrites existing files).
    Rules bodies (`base.md`, `standard.md`) stay in the plugin source (SEC-3);
    the security-reviewer agent resolves them via SEC-2's priority list. This
    boundary is the core of SEC-1: bootstrap creates the profile pointer, not
    the rule bodies.
    """
    profile_path = project_root / ".claude" / "security" / "profile.yaml"
    if profile_path.exists():
        return
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    profile_path.write_text(SECURITY_PROFILE_TEMPLATE, encoding="utf-8")
    print(f"[bootstrap] security profile created: {profile_path}")


def bootstrap(
    project_dir: Path, scope: str, version: str, allow_non_git: bool = False
) -> tuple[Path, bool]:
    project_dir = project_dir.resolve()
    _refuse_sensitive_or_unsafe(project_dir)
    if is_plugin_storage(project_dir):
        fail(f"refusing to bootstrap inside Claude plugin storage: {project_dir}")

    git_root = git_root_for(project_dir)
    non_git = False
    if git_root is None:
        # Refuse by default — Rein's
        # review/commit gates are bound to git state, so a non-git project
        # only ever gets the edit gate. This check sits AFTER the sensitive-
        # path / plugin-storage refusals above (both raise via fail(), exit
        # 2) so a dangerous path is still refused for the reason it's
        # actually dangerous, not misreported as "not a git repository".
        if not allow_non_git:
            fail(
                f"{project_dir} is not a git repository — run `git init` first "
                "(rein's review and commit gates are bound to git state), or "
                "pass --allow-non-git to initialize anyway",
                code=NON_GIT_REFUSED_EXIT,
            )
        # Task 2.3 (v1.1.1): non-git fallback — use project_dir itself as the
        # bootstrap root. We never invoke `git init` or any mutating git
        # command. trail/ + .rein/ are created in-place so the user can adopt
        # Rein without first turning the directory into a git repo.
        non_git = True
        root = project_dir
    else:
        if git_root != project_dir:
            fail(
                f"project-dir must be the git root: got {project_dir}, root is {git_root}"
            )
        if is_plugin_storage(git_root):
            fail(f"refusing to bootstrap plugin cache repository: {git_root}")
        root = git_root

    rein_dir = root / ".rein"
    policy_dir = rein_dir / "policy"
    trail_dir = root / "trail"

    # Partial-bootstrap fix (v1.3.0+1, codex round 1 missed defect #3):
    # `.rein/project.json` is the COMPLETION SENTINEL. Write it LAST and
    # atomically (temp + os.replace) so its presence guarantees every prior
    # step succeeded. Pre-fix, the marker was written before trail/ +
    # security profile + policy files. If the script crashed mid-run (SIGINT,
    # disk full, kernel kill, permission flip), bootstrap-check.sh would
    # observe `.rein/project.json` AND `trail/` (created by mkdir during the
    # crash) and report "bootstrapped" → false PASS, downstream gates run
    # against an incomplete repo and surface confusing errors (e.g. missing
    # trail/index.md when emit_file_block tries to read it).
    rein_dir.mkdir(parents=True, exist_ok=True)
    policy_dir.mkdir(parents=True, exist_ok=True)
    ensure_rein_runtime_gitignored(root)
    write_text_if_missing(policy_dir / "hooks.yaml", POLICY_HOOKS_TEMPLATE)
    write_text_if_missing(policy_dir / "rules.yaml", POLICY_RULES_TEMPLATE)
    write_text_if_missing(policy_dir / "persona.yaml", POLICY_PERSONA_TEMPLATE)

    for subdir in TRAIL_SUBDIRS:
        target = trail_dir / subdir
        target.mkdir(parents=True, exist_ok=True)
        (target / ".gitkeep").touch(exist_ok=True)
    write_text_if_missing(trail_dir / "index.md", INDEX_TEMPLATE)

    ensure_security_profile(root)

    # Marker write — LAST step, atomic. Use os.replace so the marker either
    # appears fully formed or not at all (no partial JSON observable by
    # bootstrap-check.sh). Idempotent: if marker already exists from a prior
    # successful run we leave it (preserves user-edited fields if any future
    # version adds them).
    project_json = rein_dir / "project.json"
    if project_json.is_dir():
        # Explicit refusal instead of letting write_text()/os.replace() below
        # raise IsADirectoryError — a directory at the marker path means
        # something else created it (or a prior crash left it), and treating
        # it as "already bootstrapped" (is_file() below would say no, so we
        # would otherwise fall through and try to write) would either crash
        # with a traceback or silently pretend to succeed.
        fail(f".rein/project.json is a directory: {project_json} — remove it, then re-run.")
    if not project_json.is_file():
        payload = {
            "mode": "plugin",
            "scope": scope,
            "version": version,
        }
        tmp_path = project_json.with_suffix(".json.tmp")
        tmp_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        os.replace(tmp_path, project_json)

    return root, non_git


def _clear_degraded_marker(root: Path) -> bool:
    """Remove a stale SessionStart degraded marker after a successful run.

    SessionStart writes ``<project>/.claude/cache/.rein-session-degraded``
    when it can't bootstrap (git missing / non-git dir / user opt-out /
    bootstrap refused) so downstream gates pass through for the rest of that
    session. Once THIS script has bootstrapped the project successfully
    (git-repo path, or non-git via --allow-non-git), that marker is stale —
    without clearing it here, governance would stay dormant until the next
    SessionStart, forcing an unnecessary session restart right after the
    user approved and ran the fix.

    Returns True when the marker was absent (no-op) or removed successfully.
    Returns False when the marker exists but could not be removed — the
    caller must not report overall success in that case, since governance
    stays dormant (every downstream gate keeps passing through) for the rest
    of the session despite repo-local state having been written correctly.
    """
    marker = root / ".claude" / "cache" / ".rein-session-degraded"
    if not marker.exists():
        return True
    try:
        marker.unlink()
    except FileNotFoundError:
        # A race between the exists() check above and unlink() (another
        # session's cleanup, a concurrent SessionStart) already removed the
        # marker — that IS the desired end state, not a failure.
        return True
    except OSError as exc:
        print(
            f"error: could not remove stale degraded marker at {marker}: {exc}",
            file=sys.stderr,
        )
        return False
    print(f"[bootstrap] cleared degraded marker at {marker} — governance resumes this session.")
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Bootstrap Rein repo-local state for an already-enabled plugin."
    )
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--scope", default="plugin")
    parser.add_argument("--version", default=_read_plugin_version())
    parser.add_argument(
        "--allow-non-git",
        action="store_true",
        help=(
            "Initialize repo-local state in a directory that is not a git "
            "repository. Without this flag, a non-git --project-dir is "
            f"refused (exit {NON_GIT_REFUSED_EXIT}) because rein's review "
            "and commit gates are bound to git state."
        ),
    )
    parser.add_argument(
        "--ensure-gitignore",
        action="store_true",
        help=(
            "Heal-only sub-mode for an ALREADY-bootstrapped --project-dir: "
            "append any missing rein runtime .gitignore patterns "
            "(REIN_RUNTIME_GITIGNORE_PATTERNS) and exit 0. A silent no-op "
            "(exit 0) when --project-dir is not a git repository or has no "
            ".rein/project.json yet — creates no other file (no trail/, no "
            "policy dir, no completion marker). Every other flag is "
            "ignored in this mode. Intended for session-start hooks to "
            "heal projects bootstrapped before REIN_RUNTIME_GITIGNORE_"
            "PATTERNS grew to cover /.rein/state.json et al."
        ),
    )
    args = parser.parse_args(argv)

    if args.ensure_gitignore:
        return ensure_gitignore_only(Path(args.project_dir))

    root, non_git = bootstrap(
        Path(args.project_dir), args.scope, args.version, allow_non_git=args.allow_non_git
    )
    if non_git:
        print(f"Non-git project — initialized trail/ at {root}.")
    else:
        print(f"Rein repo state bootstrapped at {root}")
    if not _clear_degraded_marker(root):
        return DEGRADED_MARKER_STUCK_EXIT
    return 0


if __name__ == "__main__":
    sys.exit(main())
