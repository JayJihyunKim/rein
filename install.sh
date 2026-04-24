#!/usr/bin/env bash
#
# install.sh — rein CLI installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
#   REIN_INSTALL_YES=1 bash install.sh    # non-interactive
#
# Environment variables:
#   REIN_INSTALL_SOURCE   — local rein.sh path (test/dev override)
#   REIN_INSTALL_YES      — skip prompts, default Y
#
set -euo pipefail

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

info()  { echo -e "${GREEN}$*${NC}" >&2; }
warn()  { echo -e "${YELLOW}$*${NC}" >&2; }
error() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

REIN_HOME="$HOME/.rein"
REIN_BIN="$REIN_HOME/bin"
REIN_EXEC="$REIN_BIN/rein"
REIN_ENV="$REIN_HOME/env"
REIN_RAW_URL="${REIN_INSTALL_URL:-https://raw.githubusercontent.com/JayJihyunKim/rein/main/scripts/rein.sh}"

# CLI-adjacent helpers must be installed beside rein so runtime resolution
# (BASH_SOURCE sibling lookup inside rein.sh) succeeds on the first
# `rein update`. Keep this list in sync with CLI_HELPER_SCRIPTS in
# scripts/rein.sh (v1.1.3 hotfix — before this, fresh installs crashed on
# first v2 update with `No such file or directory` for rein-manifest-v2.py).
REIN_CLI_HELPERS=(
  "rein-manifest-v2.py"
  "rein-path-match.py"
  "rein-job-wrapper.sh"
)

# reject_symlink(path) — abort if path is a symlink
reject_symlink() {
  if [[ -L "$1" ]]; then
    error "Refusing to overwrite symlink at $1 — possible symlink attack"
  fi
}

# ---------------------------------------------------------------------------
# download_rein(target_path)
# Downloads scripts/rein.sh from main to target_path.
# Honors REIN_INSTALL_SOURCE (local file path) for testing.
# Uses atomic write (tmp file + mv) to avoid partial downloads.
# ---------------------------------------------------------------------------
download_rein() {
  local dest="$1"
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")

  if [[ -n "${REIN_INSTALL_SOURCE:-}" ]]; then
    cp "$REIN_INSTALL_SOURCE" "$tmp"
  else
    if ! command -v curl >/dev/null 2>&1; then
      rm -f "$tmp"
      error "curl not found. Please install curl first."
    fi
    if ! curl -fsSL "$REIN_RAW_URL" -o "$tmp"; then
      rm -f "$tmp"
      error "Failed to download rein from $REIN_RAW_URL"
    fi
  fi

  # Sanity check: file must be non-empty and contain VERSION line
  if [[ ! -s "$tmp" ]] || ! grep -q '^VERSION=' "$tmp"; then
    rm -f "$tmp"
    error "Downloaded file is not a valid rein.sh (missing VERSION)"
  fi

  chmod +x "$tmp"
  reject_symlink "$dest"
  mv "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# download_cli_helper(name)
# Fetches a CLI-adjacent helper into $REIN_BIN alongside rein. Mirrors
# download_rein's atomic tmp+mv + REIN_INSTALL_SOURCE override. Non-fatal:
# missing helpers warn but do not abort installation. v1.1.3 hotfix.
# ---------------------------------------------------------------------------
download_cli_helper() {
  local name="$1"
  local dest="$REIN_BIN/$name"
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")

  if [[ -n "${REIN_INSTALL_SOURCE:-}" ]]; then
    # Dev override: look for helper as sibling of REIN_INSTALL_SOURCE.
    local src_dir
    src_dir=$(cd "$(dirname "$REIN_INSTALL_SOURCE")" 2>/dev/null && pwd -P)
    if [[ -n "$src_dir" && -f "$src_dir/$name" ]]; then
      cp "$src_dir/$name" "$tmp"
    else
      rm -f "$tmp"
      warn "CLI helper $name not found next to REIN_INSTALL_SOURCE (skipped)"
      return 1
    fi
  else
    # Strip the rein.sh basename from REIN_RAW_URL to derive the helper URL.
    local base_url="${REIN_RAW_URL%/*}"
    local url="$base_url/$name"
    if ! curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      warn "Failed to download $name from $url (skipped)"
      return 1
    fi
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    warn "$name download is empty (skipped)"
    return 1
  fi

  chmod +x "$tmp"
  reject_symlink "$dest"
  mv "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# write_env_file()
# Writes $REIN_ENV with a POSIX-compatible PATH setup.
# Idempotent — always overwrites (managed file, not user-edited).
# ---------------------------------------------------------------------------
write_env_file() {
  reject_symlink "$REIN_ENV"
  cat > "$REIN_ENV" <<'EOF'
#!/bin/sh
# rein shell setup — managed file, do not edit manually
case ":${PATH}:" in
    *:"$HOME/.rein/bin":*) ;;
    *) export PATH="$HOME/.rein/bin:$PATH" ;;
esac
EOF
}

# ---------------------------------------------------------------------------
# detect_shell_rc()
# Returns (prints) the path to the user's shell rc file to modify.
# Priority:
#   1) $SHELL-based guess (zsh→.zshrc, bash→.bashrc, fish→config.fish)
#   2) First existing file among common candidates
#   3) Falls back to ~/.profile (creates if missing)
# ---------------------------------------------------------------------------
detect_shell_rc() {
  local shell_name="${SHELL##*/}"
  case "$shell_name" in
    zsh)
      echo "$HOME/.zshrc"
      return 0
      ;;
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then
        echo "$HOME/.bashrc"
      else
        echo "$HOME/.bash_profile"
      fi
      return 0
      ;;
    fish)
      echo "$HOME/.config/fish/config.fish"
      return 0
      ;;
  esac

  # Unknown shell — fall back to first existing common rc
  local candidate
  for candidate in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo "$HOME/.profile"
}

# ---------------------------------------------------------------------------
# append_env_source(rc_path)
# Appends shell-appropriate PATH setup to rc_path.
# Fish shell gets fish-compatible syntax; others get POSIX `. "$HOME/.rein/env"`.
# Idempotent. Creates rc_path if missing.
# ---------------------------------------------------------------------------
append_env_source() {
  local rc="$1"
  local is_fish=0
  [[ "$rc" == *"/fish/"* ]] && is_fish=1

  [[ -f "$rc" ]] || {
    mkdir -p "$(dirname "$rc")"
    touch "$rc"
  }

  if [[ $is_fish -eq 1 ]]; then
    local fish_line='set -gx PATH "$HOME/.rein/bin" $PATH'
    if grep -qF '.rein/bin' "$rc"; then
      return 0
    fi
    printf '\n# Added by rein installer\n%s\n' "$fish_line" >> "$rc"
  else
    local line='. "$HOME/.rein/env"'
    if grep -qF "$line" "$rc"; then
      return 0
    fi
    printf '\n# Added by rein installer\n%s\n' "$line" >> "$rc"
  fi
}

# ---------------------------------------------------------------------------
# prompt_yes(question)
# Prompts user for Y/n (default Y). Returns 0 for yes, 1 for no.
# Auto-Y when:
#   - REIN_INSTALL_YES=1
#   - stdin is not a tty (pipe mode: curl | bash)
# ---------------------------------------------------------------------------
prompt_yes() {
  local q="$1"
  if [[ "${REIN_INSTALL_YES:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    return 0
  fi
  read -r -p "$q [Y/n] " ans
  case "$ans" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# check_old_install()
# Detects legacy installation at /usr/local/bin/rein and warns.
# Never calls sudo — prints the removal command for the user to run.
# Test override: REIN_OLD_INSTALL_PATH
# ---------------------------------------------------------------------------
check_old_install() {
  local old_path="${REIN_OLD_INSTALL_PATH:-/usr/local/bin/rein}"
  if [[ -e "$old_path" ]]; then
    warn ""
    warn "⚠️  Old installation detected at $old_path"
    warn ""
    warn "    To remove it (requires sudo):"
    warn "      sudo rm $old_path"
    warn ""
    warn "    The new installation at \$HOME/.rein/bin/rein takes precedence"
    warn "    in PATH once you source ~/.rein/env, but removing the old file"
    warn "    prevents confusion."
    warn ""
  fi
}

main() {
  check_old_install
  mkdir -p "$REIN_BIN"
  download_rein "$REIN_EXEC"

  # v1.1.3 hotfix: install CLI-adjacent helpers beside rein. Before this,
  # fresh installs were missing rein-manifest-v2.py etc. and crashed on
  # first `rein update` entering the v2 path.
  #
  # Policy: missing/failed helper → warn + continue (do NOT abort install).
  # download_cli_helper returns 1 on skip, so we swallow with `|| true`
  # because install.sh runs under `set -e`. Rationale — main rein.sh must
  # still land so the user has a working entry point; missing helper is
  # recoverable via `rein update` later when reaching a complete template.
  local helper
  for helper in "${REIN_CLI_HELPERS[@]}"; do
    download_cli_helper "$helper" || true
  done

  write_env_file
  info "Installed: $REIN_EXEC"
  info "Env file:   $REIN_ENV"

  local rc
  rc=$(detect_shell_rc)
  if prompt_yes "Add '. \"\$HOME/.rein/env\"' to $rc?"; then
    append_env_source "$rc"
    info "Updated:    $rc"
  else
    warn "Skipped rc update. Add this line manually to your shell rc:"
    warn "  . \"\$HOME/.rein/env\""
  fi

  info ""
  info "To start using rein now, run: source ~/.rein/env"
}

if [[ -z "${INSTALL_SOURCED:-}" ]]; then
  main "$@"
fi
