#!/bin/bash
# lib/git-subcommand-model.sh — canonical git subcommand token model (SSOT).
#
# GMF-1 / GMF-2 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.1–3.2). This is
# the single authoritative definition of how rein recognises a `git commit`
# (and `git merge`/`rebase`/`am`) invocation. Three consumers source it so no
# literal is mirrored (drift is structurally impossible):
#
#   1. lib/bash-classifier.sh      — gate trigger (CLASS_NEEDS_TC)
#   2. pre-bash-dispatcher.sh      — state-machine class (_SM_CLASS)
#   3. pre-bash-test-commit-gate.sh — gate-internal command_invokes
#
# Side-effect-free pure definition file (same posture as portable.sh /
# path-policy.sh): it defines ERE constants + one clause-start matcher and runs
# no command and mutates no global state. Sourcing it is idempotent — re-source
# from a second consumer is harmless.
#
# Why a SEPARATE lib (not bash-guard-infra.sh): bash-guard-infra.sh has a heavy
# call contract (BG_GUARD_NAME preset, portable/python-runner/project-dir
# pre-source, bg_infra_init). The lightweight classifier/dispatcher must not pay
# that. safety-guard also sources bash-guard-infra but does NOT use this token
# model (its P10 GIT_COMMIT_PREFIX matcher is out of scope), so putting the
# model there would couple safety-guard to a lib it never reads.

# Known git global options that may appear between `git` and the subcommand.
# Explicit allowlist (spec §3.1) — NOT a generic "-*" wildcard, so that
# `git --bogus commit` / `git -Z commit` (options git itself rejects) are
# conservatively NON-matched rather than over-matched as commit.
#   -C <path> / -c <kv> / --git-dir[=| ]<path> / --work-tree[=| ]<path>
#   -p / --paginate / --no-pager / --no-replace-objects / --bare /
#   --literal-pathspecs
# Token separator is [[:space:]]+ (multiple spaces allowed).
GIT_GLOBAL_OPT='(-C[[:space:]]+[^;&|[:space:]]+|-c[[:space:]]+[^;&|[:space:]]+|--git-dir(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|--work-tree(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|-p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs)'

# git <zero or more global options> <subcommand> — the prefix up to (and
# including the whitespace before) the subcommand token.
GIT_SUBCMD_PREFIX="git([[:space:]]+${GIT_GLOBAL_OPT})*[[:space:]]+"

# commit detection ERE (GMF-1). `commit` is closed by a shell-token boundary
# (spec §3.1 R2 HIGH — `\b` is forbidden because it fires between `commit` and
# `-graph`, failing to exclude `git commit-graph write`). After `commit` there
# must be a space / shell separator (; | & () / end of string.
#   `\$` survives double-quote interpolation as `$` (end anchor) for grep.
GIT_COMMIT_ERE="${GIT_SUBCMD_PREFIX}commit([[:space:]]|;|\||&|\(|\$)"

# merge/rebase/am exemption ERE (GMF-2): same prefix + subcommand alternation
# + the same shell-token boundary.
GIT_MERGE_ERE="${GIT_SUBCMD_PREFIX}(merge|rebase|am)([[:space:]]|;|\||&|\(|\$)"

# git_clause_invokes "<ERE>" "<command-string>"
#   Return 0 if the ERE matches at a command-clause start in the command
#   string, else 1. Clause start = string/line start or right after a shell
#   separator (`;` `&` `|` `(`, incl. the last char of `&&`/`||`). Leading
#   `VAR=value` env assignments and command wrappers (env/sudo/command/nohup/
#   time/exec) are skipped. This is the SAME clause-start model as
#   bash-guard-infra.sh::command_invokes (line 196), so a mention such as
#   `echo "git commit"` / `grep git commit -m x` is correctly non-matched.
#
#   classifier/dispatcher call this directly (they do not source
#   bash-guard-infra.sh); test-commit-gate uses bash-guard-infra's
#   command_invokes with the ERE constants above — both share the same anchor.
git_clause_invokes() {
  local ere="$1" cmd="$2"
  printf '%s' "$cmd" | grep -qE \
    "(^|[;&|(])[[:space:]]*((env|sudo|command|nohup|time|exec)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(${ere})"
}
