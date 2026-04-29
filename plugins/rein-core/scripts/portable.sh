# .claude/hooks/lib/portable.sh
#
# Cross-platform shell helpers for rein hooks. Source this file at the top
# of every hook that needs file metadata or date arithmetic:
#
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=./lib/portable.sh
#   . "$SCRIPT_DIR/lib/portable.sh"
#
# Supported platforms:
#   - macOS (Darwin): BSD coreutils
#   - Linux: GNU coreutils
#   - Windows via WSL2: GNU coreutils (same as Linux)
#   - Git Bash / MSYS2: best-effort GNU coreutils
#
# Design notes:
#   - Uses `uname` to dispatch between BSD and GNU variants explicitly.
#     The previous `stat -f ... || stat -c ...` chain was unsafe because
#     GNU `stat -f` returns exit 0 in filesystem-info mode, which poisoned
#     downstream arithmetic with non-numeric text.
#   - All functions must produce numeric output (for *_epoch/*_size) or
#     empty/fallback output, never unbound/arbitrary text — hooks typically
#     run under `set -u` and `$(( ))` must not see stray identifiers.

# ------------------------------------------------------------
# portable_stat_size FILE
#   Print the byte size of FILE on stdout.
#   Missing file or any failure → "0" (never non-numeric).
# ------------------------------------------------------------
portable_stat_size() {
  local sz
  case "$(uname)" in
    Darwin) sz=$(stat -f %z "$1" 2>/dev/null) ;;
    *)      sz=$(stat -c %s "$1" 2>/dev/null) ;;
  esac
  case "$sz" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$sz" ;;
  esac
}

# ------------------------------------------------------------
# portable_mtime_epoch FILE
#   Print the modification time of FILE as unix epoch seconds.
#   Missing file or any failure → "0".
# ------------------------------------------------------------
portable_mtime_epoch() {
  local t
  case "$(uname)" in
    Darwin) t=$(stat -f %m "$1" 2>/dev/null) ;;
    *)      t=$(stat -c %Y "$1" 2>/dev/null) ;;
  esac
  case "$t" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$t" ;;
  esac
}

# ------------------------------------------------------------
# portable_mtime_date FILE
#   Print the modification date of FILE in YYYY-MM-DD form.
#   Missing file or any failure → empty string.
# ------------------------------------------------------------
portable_mtime_date() {
  local d
  case "$(uname)" in
    Darwin) d=$(stat -f "%Sm" -t "%Y-%m-%d" "$1" 2>/dev/null) ;;
    *)      d=$(stat -c "%y" "$1" 2>/dev/null | cut -d' ' -f1) ;;
  esac
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) echo "$d" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------
# portable_date_ymd_to_epoch YYYY-MM-DD
#   Convert a date string to unix epoch seconds (midnight local time).
#   Failure → empty string (caller checks).
# ------------------------------------------------------------
portable_date_ymd_to_epoch() {
  local ymd="$1"
  local epoch
  epoch=$(date -j -f "%Y-%m-%d" "$ymd" +%s 2>/dev/null \
         || date -d "$ymd" +%s 2>/dev/null)
  case "$epoch" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$epoch" ;;
  esac
}
