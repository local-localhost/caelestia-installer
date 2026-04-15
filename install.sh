#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/pkg"

REPO_OWNER="${REPO_OWNER:-local-localhost}"
GITHUB_REPO_BASE="https://github.com/$REPO_OWNER"
SYSTEM_PYTHON="${SYSTEM_PYTHON:-/usr/bin/python}"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$XDG_STATE_HOME/caelestia-installer"

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.local/share/caelestia}"
CLI_DIR="${CLI_DIR:-$HOME/.local/share/caelestia-cli}"
SHELL_DIR="${SHELL_DIR:-$XDG_CONFIG_HOME/quickshell/caelestia}"

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-$GITHUB_REPO_BASE/caelestia.git}"
CLI_REPO_URL="${CLI_REPO_URL:-$GITHUB_REPO_BASE/cli.git}"
SHELL_REPO_URL="${SHELL_REPO_URL:-$GITHUB_REPO_BASE/shell.git}"

DOTFILES_REPO_REF="${DOTFILES_REPO_REF:-main}"
CLI_REPO_REF="${CLI_REPO_REF:-main}"
SHELL_REPO_REF="${SHELL_REPO_REF:-main}"

SUBCOMMAND="install"
YES=false
INSTALL_SPOTIFY=false
INSTALL_DISCORD=false
INSTALL_ZEN=false
VSCODE_VARIANT=""

PACMAN_BOOTSTRAP_ARGS=(--needed)
PACMAN_INSTALL_ARGS=()
PACMAN_REMOVE_ARGS=()
YAY_BOOTSTRAP_ARGS=(--needed)
YAY_INSTALL_ARGS=()
MAKEPKG_ARGS=()

BACKUP_DIR=""
OS_ID=""
LOCK_FILE="$STATE_DIR/install.lock"
SUDO_KEEPALIVE_PID=""
TEMP_DIRS=()
PACMAN_PACKAGES=()
AUR_PACKAGES=()

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [subcommand] [options]

Installer for the Caelestia dotfiles

Subcommands:
  install              Run the full installation flow (default)
  check                Run preflight checks only
  deps                 Install package dependencies only
  repos                Clone or update managed repositories only
  build                Build and install the CLI and shell only
  link                 Link managed dotfiles only
  init                 Initialize first-run Caelestia state only
  diagnose             Print local installer diagnostics
  uninstall            Best-effort uninstall of files installed by this script

Options:
  -h, --help            Show this help text
  -y, --yes             Automatic mode without confirmation prompts
  --spotify             Install Spotify + Spicetify integration
  --discord             Install Discord + OpenAsar + Equicord
  --zen                 Install Zen Browser integration
  --vscode <variant>    Install editor integration. Variant: code | codium

Environment overrides:
  REPO_OWNER            GitHub owner for managed repos (default: local-localhost)
  DOTFILES_REPO_URL     Override the dotfiles repo URL
  CLI_REPO_URL          Override the CLI repo URL
  SHELL_REPO_URL        Override the shell repo URL
  DOTFILES_REPO_REF     Managed dotfiles ref to install (default: main)
  CLI_REPO_REF          Managed CLI ref to install (default: main)
  SHELL_REPO_REF        Managed shell ref to install (default: main)
  DOTFILES_DIR          Override the managed dotfiles checkout directory
  CLI_DIR               Override the managed CLI checkout directory
  SHELL_DIR             Override the managed shell checkout directory
  SYSTEM_PYTHON         Python used for CLI build/install cleanup (default: /usr/bin/python)

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME check
  ./$SCRIPT_NAME repos
  ./$SCRIPT_NAME build --vscode codium
  ./$SCRIPT_NAME -y --spotify --vscode codium --zen --discord
EOF
}

log() {
  printf '\033[1;36m:: %s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33m:: %s\033[0m\n' "$*" >&2
}

die() {
  printf '\033[1;31m!! %s\033[0m\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

system_python_purelib_dir() {
  "$SYSTEM_PYTHON" - <<'PY'
import sysconfig
print(sysconfig.get_paths()["purelib"])
PY
}

expand_home_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  path="${path//\$\{HOME\}/$HOME}"
  path="${path//\$HOME/$HOME}"
  printf '%s\n' "$path"
}

default_wallpaper_dir() {
  local pictures_dir=""

  if [[ -n "${CAELESTIA_WALLPAPERS_DIR:-}" ]]; then
    expand_home_path "$CAELESTIA_WALLPAPERS_DIR"
    return
  fi

  pictures_dir="${XDG_PICTURES_DIR:-$HOME/Pictures}"
  pictures_dir="$(expand_home_path "$pictures_dir")"
  printf '%s/Wallpapers\n' "$pictures_dir"
}

run_root() {
  sudo "$@"
}

cleanup() {
  local tmp_path=""

  if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi

  for tmp_path in "${TEMP_DIRS[@]}"; do
    [[ -n "$tmp_path" && -e "$tmp_path" ]] && rm -rf -- "$tmp_path"
  done
  TEMP_DIRS=()

  exec 9>&- 2>/dev/null || true
}

acquire_lock() {
  need_cmd flock
  mkdir -p "$STATE_DIR"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another caelestia-installer process is already running."
}

register_temp_path() {
  TEMP_DIRS+=( "$1" )
}

load_package_list() {
  local list_path="$1"
  local -n target_array="$2"

  [[ -r "$list_path" ]] || die "Package list not found: $list_path"

  mapfile -t target_array < <(
    sed -E 's/[[:space:]]+#.*$//' "$list_path" | sed -E '/^[[:space:]]*$/d'
  )

  ((${#target_array[@]} > 0)) || die "Package list is empty: $list_path"
}

load_package_lists() {
  load_package_list "$PKG_DIR/pacman.txt" PACMAN_PACKAGES
  load_package_list "$PKG_DIR/aur.txt" AUR_PACKAGES
}

confirm() {
  local prompt="$1"
  local reply=""

  if $YES; then
    return 0
  fi

  read -r -p "$prompt [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
}

ensure_backup_dir() {
  if [[ -n "$BACKUP_DIR" ]]; then
    return
  fi

  BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  log "Backups will be stored in $BACKUP_DIR"
}

backup_path() {
  local path="$1"
  local destination=""

  [[ -e "$path" || -L "$path" ]] || return 0

  ensure_backup_dir
  destination="$BACKUP_DIR$path"
  mkdir -p "$(dirname "$destination")"
  mv "$path" "$destination"
  log "Moved existing path to backup: $path"
}

paths_are_same_content() {
  local source_path="$1"
  local target_path="$2"

  [[ -e "$source_path" || -L "$source_path" ]] || return 1
  [[ -e "$target_path" || -L "$target_path" ]] || return 1

  if [[ -d "$source_path" && -d "$target_path" ]]; then
    diff -qr "$source_path" "$target_path" >/dev/null 2>&1
    return
  fi

  if [[ -f "$source_path" && -f "$target_path" ]]; then
    cmp -s "$source_path" "$target_path"
    return
  fi

  if [[ -L "$source_path" && -L "$target_path" ]]; then
    [[ "$(readlink "$source_path")" == "$(readlink "$target_path")" ]]
    return
  fi

  return 1
}

link_path() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "$(dirname "$target_path")"

  if [[ -L "$target_path" ]] && [[ "$(readlink -f "$target_path")" == "$(readlink -f "$source_path")" ]]; then
    log "Already linked: $target_path"
    return
  fi

  if [[ -e "$target_path" || -L "$target_path" ]]; then
    if paths_are_same_content "$source_path" "$target_path"; then
      rm -rf -- "$target_path"
      log "Replacing identical existing path with symlink: $target_path"
    else
      backup_path "$target_path"
    fi
  fi

  ln -sfn "$source_path" "$target_path"
  log "Linked $target_path -> $source_path"
}

write_if_missing() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  [[ -e "$path" || -L "$path" ]] || : > "$path"
}

write_text_if_missing() {
  local path="$1"
  local content="$2"

  mkdir -p "$(dirname "$path")"
  [[ -e "$path" || -L "$path" ]] || printf '%s' "$content" > "$path"
}

parse_args() {
  local subcommand_seen=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|check|deps|repos|build|link|init|diagnose|uninstall)
        $subcommand_seen && die "Subcommand already specified: $SUBCOMMAND"
        SUBCOMMAND="$1"
        subcommand_seen=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -y|--yes)
        YES=true
        ;;
      --spotify)
        INSTALL_SPOTIFY=true
        ;;
      --discord)
        INSTALL_DISCORD=true
        ;;
      --zen)
        INSTALL_ZEN=true
        ;;
      --vscode)
        shift
        [[ $# -gt 0 ]] || die "--vscode requires a value: code or codium"
        [[ "$1" == "code" || "$1" == "codium" ]] || die "--vscode accepts only 'code' or 'codium'"
        VSCODE_VARIANT="$1"
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

setup_package_args() {
  if $YES; then
    PACMAN_BOOTSTRAP_ARGS+=(--noconfirm)
    PACMAN_INSTALL_ARGS+=(--noconfirm)
    PACMAN_REMOVE_ARGS+=(--noconfirm)
    YAY_BOOTSTRAP_ARGS+=(
      --noconfirm
      --answerclean None
      --answerdiff None
      --answeredit None
      --answerupgrade None
    )
    YAY_INSTALL_ARGS+=(
      --noconfirm
      --answerclean None
      --answerdiff None
      --answeredit None
      --answerupgrade None
    )
    MAKEPKG_ARGS+=(--noconfirm)
  fi
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release

  OS_ID="${ID:-}"
  case "$OS_ID" in
    arch|cachyos)
      ;;
    *)
      die "Unsupported distribution: ${OS_ID:-unknown}. This installer supports only Arch Linux"
      ;;
  esac
}

ensure_not_root() {
  [[ "$EUID" -ne 0 ]] || die "Run this installer as a regular user, not as root."
}

subcommand_is_mutating() {
  case "$1" in
    install|deps|repos|build|link|init|uninstall)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

subcommand_needs_sudo() {
  case "$1" in
    install|deps|build|uninstall)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

choose_confirmation_mode() {
  local reply=""

  if ! subcommand_is_mutating "$SUBCOMMAND"; then
    return
  fi

  if $YES; then
    return
  fi

  if [[ ! -t 0 ]]; then
    warn "No interactive terminal detected. Falling back to automatic mode."
    YES=true
    return
  fi

  printf '\n'
  printf 'Choose execution mode:\n'
  printf '  1. Manual confirmations (recommended)\n'
  printf '  2. Automatic mode\n'
  read -r -p "Select mode [1/2]: " reply

  case "$reply" in
    2)
      YES=true
      log "Automatic mode selected."
      ;;
    ""|1)
      YES=false
      log "Manual confirmation mode selected."
      ;;
    *)
      warn "Unknown selection '$reply'. Falling back to manual confirmation mode."
      YES=false
      ;;
  esac
}

ensure_sudo() {
  need_cmd sudo
  log "Requesting sudo access..."
  sudo -v

  if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    return
  fi

  (
    while true; do
      sleep 60
      sudo -n -v >/dev/null 2>&1 || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

ensure_yay() {
  if command -v yay >/dev/null 2>&1; then
    return
  fi

  log "yay not found, installing it..."

  if [[ "$OS_ID" == "cachyos" ]]; then
    run_root pacman -S "${PACMAN_BOOTSTRAP_ARGS[@]}" yay
    return
  fi

  run_root pacman -S "${PACMAN_BOOTSTRAP_ARGS[@]}" git base-devel
  need_cmd makepkg

  local tmp_dir=""
  tmp_dir="$(mktemp -d)"
  register_temp_path "$tmp_dir"

  git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp_dir/yay"
  (
    cd "$tmp_dir/yay"
    makepkg -si "${MAKEPKG_ARGS[@]}"
  )
}

preflight_check_command() {
  local command_name="$1"
  local display_name="$2"
  local -n missing_ref="$3"

  if [[ "$command_name" == /* ]]; then
    [[ -x "$command_name" ]] || missing_ref+=("$display_name ($command_name)")
    return
  fi

  command -v "$command_name" >/dev/null 2>&1 || missing_ref+=("$display_name")
}

preflight_check_repo_access() {
  local repo_url="$1"
  local display_name="$2"
  local -n missing_ref="$3"

  git ls-remote "$repo_url" HEAD >/dev/null 2>&1 || missing_ref+=("$display_name ($repo_url)")
}

preflight_check_pacman_packages() {
  local -n missing_ref="$1"
  local pkg=""

  for pkg in "${PACMAN_PACKAGES[@]}"; do
    pacman -Si -- "$pkg" >/dev/null 2>&1 || missing_ref+=("$pkg")
  done
}

preflight_check_aur_packages() {
  local -n missing_ref="$1"
  local pkg=""
  local rpc_url=""
  local response_file=""

  if command -v yay >/dev/null 2>&1; then
    for pkg in "${AUR_PACKAGES[@]}"; do
      yay -Si -- "$pkg" >/dev/null 2>&1 || missing_ref+=("$pkg")
    done
    return
  fi

  rpc_url="https://aur.archlinux.org/rpc/v5/info?"
  for pkg in "${AUR_PACKAGES[@]}"; do
    rpc_url+="arg[]=$pkg&"
  done

  response_file="$(mktemp)"
  register_temp_path "$response_file"
  curl -fsSL "$rpc_url" -o "$response_file" || die "Failed to query the AUR RPC endpoint during preflight."

  mapfile -t missing_ref < <(
    "$SYSTEM_PYTHON" - "$response_file" "${AUR_PACKAGES[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

found = {entry.get("Name") for entry in data.get("results", [])}

for pkg in sys.argv[2:]:
    if pkg not in found:
        print(pkg)
PY
  )
}

run_preflight() {
  local missing_commands=()
  local missing_repos=()
  local missing_pacman_packages=()
  local missing_aur_packages=()
  local base_commands=(bash sed diff cmp flock git readlink ln find)
  local pkg_commands=(pacman sudo curl)
  local build_commands=(cmake)
  local cmd=""

  log "Running preflight checks for '$SUBCOMMAND'..."

  for cmd in "${base_commands[@]}"; do
    preflight_check_command "$cmd" "$cmd" missing_commands
  done

  if subcommand_is_mutating "$SUBCOMMAND" || [[ "$SUBCOMMAND" == "check" ]]; then
    for cmd in "${pkg_commands[@]}"; do
      preflight_check_command "$cmd" "$cmd" missing_commands
    done
  fi

  if [[ "$SUBCOMMAND" =~ ^(install|build|check|diagnose)$ ]]; then
    for cmd in "${build_commands[@]}"; do
      preflight_check_command "$cmd" "$cmd" missing_commands
    done
    preflight_check_command "$SYSTEM_PYTHON" "system python" missing_commands
  fi

  if [[ "$SUBCOMMAND" =~ ^(install|deps|check)$ ]] && ! command -v yay >/dev/null 2>&1; then
    if [[ "$OS_ID" != "cachyos" ]]; then
      preflight_check_command "makepkg" "makepkg" missing_commands
    fi
    warn "yay not found. It will be bootstrapped during installation."
  fi

  if [[ "$SUBCOMMAND" =~ ^(install|repos|build|link|check)$ ]]; then
    preflight_check_repo_access "$DOTFILES_REPO_URL" "dotfiles repo" missing_repos
    preflight_check_repo_access "$CLI_REPO_URL" "CLI repo" missing_repos
    preflight_check_repo_access "$SHELL_REPO_URL" "shell repo" missing_repos
  fi

  if [[ "$SUBCOMMAND" =~ ^(install|deps|check)$ ]]; then
    preflight_check_pacman_packages missing_pacman_packages
    preflight_check_aur_packages missing_aur_packages
  fi

  if ((${#missing_commands[@]} > 0)); then
    warn "Missing commands:"
    printf '  - %s\n' "${missing_commands[@]}" >&2
  fi

  if ((${#missing_repos[@]} > 0)); then
    warn "Unavailable managed repositories:"
    printf '  - %s\n' "${missing_repos[@]}" >&2
  fi

  if ((${#missing_pacman_packages[@]} > 0)); then
    warn "Unavailable pacman packages:"
    printf '  - %s\n' "${missing_pacman_packages[@]}" >&2
  fi

  if ((${#missing_aur_packages[@]} > 0)); then
    warn "Unavailable AUR packages:"
    printf '  - %s\n' "${missing_aur_packages[@]}" >&2
  fi

  if ((${#missing_commands[@]} > 0 || ${#missing_repos[@]} > 0 || ${#missing_pacman_packages[@]} > 0 || ${#missing_aur_packages[@]} > 0)); then
    die "Preflight checks failed. Resolve the issues above before continuing."
  fi

  log "Preflight checks passed."
}

install_packages() {
  log "Installing official repository packages..."
  run_root pacman -S "${PACMAN_INSTALL_ARGS[@]}" "${PACMAN_PACKAGES[@]}"

  log "Installing AUR packages..."
  yay -S "${YAY_INSTALL_ARGS[@]}" "${AUR_PACKAGES[@]}"
}

remove_conflicting_packages() {
  local candidates=(
    caelestia-shell-git
    caelestia-shell
    caelestia-cli-git
    caelestia-cli
    caelestia-meta
  )
  local installed_packages=()
  local conflicts=()
  local pkg=""

  mapfile -t installed_packages < <(pacman -Qq 2>/dev/null || true)

  for pkg in "${candidates[@]}"; do
    if printf '%s\n' "${installed_packages[@]}" | grep -Fxq -- "$pkg"; then
      conflicts+=("$pkg")
    fi
  done

  if ((${#conflicts[@]} == 0)); then
    return
  fi

  warn "Detected conflicting packaged Caelestia installs: ${conflicts[*]}"

  if confirm "Remove conflicting packaged versions before installing from source?"; then
    for pkg in "${conflicts[@]}"; do
      if ! pacman -Q "$pkg" >/dev/null 2>&1; then
        log "Skipping already removed conflict: $pkg"
        continue
      fi

      log "Removing conflicting package: $pkg"
      run_root pacman -R "${PACMAN_REMOVE_ARGS[@]}" "$pkg"
    done
  else
    die "Conflicting packaged Caelestia versions must be removed before continuing."
  fi
}

is_caelestia_conflicting_package() {
  case "$1" in
    caelestia-meta|caelestia-cli|caelestia-cli-git|caelestia-shell|caelestia-shell-git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remove_known_caelestia_package_conflict() {
  local pkg="$1"

  if ! is_caelestia_conflicting_package "$pkg"; then
    return 1
  fi

  if ! pacman -Q "$pkg" >/dev/null 2>&1; then
    log "Skipping already removed conflict: $pkg"
    return 0
  fi

  warn "Removing remaining conflicting Caelestia package: $pkg"
  run_root pacman -R "${PACMAN_REMOVE_ARGS[@]}" "$pkg"
}

remove_stale_caelestia_binary() {
  local owner=""

  [[ -e /usr/bin/caelestia ]] || return 0

  if pacman -Qo /usr/bin/caelestia >/dev/null 2>&1; then
    owner="$(pacman -Qqo /usr/bin/caelestia 2>/dev/null || true)"
    if [[ -n "$owner" ]] && remove_known_caelestia_package_conflict "$owner"; then
      return 0
    fi
    die "/usr/bin/caelestia is owned by package '$owner'. Remove the conflicting package first and rerun the installer."
  fi

  warn "Removing unowned stale binary: /usr/bin/caelestia"
  run_root rm -f /usr/bin/caelestia
}

remove_stale_cli_python_package() {
  local purelib=""
  local package_dir=""
  local owner=""
  local cleanup_paths=()
  local path=""
  local dist_info=()

  [[ -x "$SYSTEM_PYTHON" ]] || die "System Python not found: $SYSTEM_PYTHON"

  purelib="$(system_python_purelib_dir)"
  [[ -n "$purelib" ]] || die "Could not determine Python site-packages directory."

  package_dir="$purelib/caelestia"
  shopt -s nullglob
  dist_info=( "$purelib"/caelestia-*.dist-info )
  shopt -u nullglob

  [[ -e "$package_dir" ]] && cleanup_paths+=( "$package_dir" )
  for path in "${dist_info[@]}"; do
    [[ -e "$path" ]] && cleanup_paths+=( "$path" )
  done

  ((${#cleanup_paths[@]} > 0)) || return 0

  for path in "${cleanup_paths[@]}"; do
    if pacman -Qo "$path" >/dev/null 2>&1; then
      owner="$(pacman -Qqo "$path" 2>/dev/null || true)"
      if [[ -n "$owner" ]] && remove_known_caelestia_package_conflict "$owner"; then
        continue
      fi
      die "$path is owned by package '$owner'. Remove the conflicting package first and rerun the installer."
    fi
  done

  warn "Removing previous manually installed caelestia Python files."
  run_root rm -rf -- "${cleanup_paths[@]}"
}

remove_old_dependency_conflicts() {
  local cleanup_list=(
    quickshell
    qtengine
    qtengine-bin
  )
  local installed_conflicts=()
  local pkg=""

  for pkg in "${cleanup_list[@]}"; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      installed_conflicts+=( "$pkg" )
    fi
  done

  if ((${#installed_conflicts[@]} == 0)); then
    return
  fi

  warn "Detected shared packages that may conflict with the managed Caelestia build: ${installed_conflicts[*]}"
  if ! confirm "Remove these shared packages now?"; then
    warn "Skipping shared package removal at user request."
    return
  fi

  for pkg in "${installed_conflicts[@]}"; do
    warn "Removing conflicting package: $pkg"
    if ! run_root pacman -Rns "${PACMAN_REMOVE_ARGS[@]}" "$pkg"; then
      warn "Regular removal failed for $pkg, trying a forced dependency cleanup."
      run_root pacman -Rdd "${PACMAN_REMOVE_ARGS[@]}" "$pkg" || die "Failed to remove conflicting package: $pkg"
    fi
  done
}

cleanup_old_install_state() {
  log "Cleaning up old installs and conflicting packages..."
  remove_conflicting_packages
  remove_old_dependency_conflicts
  remove_stale_caelestia_binary
  remove_stale_cli_python_package
}

update_or_clone_repo() {
  local repo_dir="$1"
  local repo_url="$2"
  local repo_ref="$3"
  local label="$4"
  local origin_url=""
  local current_branch=""

  if [[ -e "$repo_dir" ]] && git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"

    if [[ "$origin_url" != "$repo_url" ]]; then
      if [[ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
        die "$label repo at $repo_dir has origin '$origin_url' and local changes. Refusing to install from an unmanaged checkout. Back up or clean the repo, or point ${label^^}_REPO_URL to the repo you want."
      fi

      warn "$label repo at $repo_dir has a different origin: $origin_url"
      warn "Repointing it to the configured repo: $repo_url"
      git -C "$repo_dir" remote set-url origin "$repo_url"
    fi

    if [[ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
      die "$label repo at $repo_dir has local changes. Refusing to install from a dirty checkout because the installer must use the configured fork at $repo_url."
    fi

    log "Updating $label repo in $repo_dir from $repo_url at ref $repo_ref"
    git -C "$repo_dir" fetch --tags --prune origin

    git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$repo_ref" \
      || die "$label repo does not have origin ref '$repo_ref': $repo_url"

    current_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || true)"
    if [[ "$current_branch" != "$repo_ref" ]]; then
      if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$repo_ref"; then
        git -C "$repo_dir" checkout "$repo_ref"
      else
        git -C "$repo_dir" checkout -b "$repo_ref" --track "origin/$repo_ref"
      fi
    fi

    git -C "$repo_dir" branch --set-upstream-to "origin/$repo_ref" "$repo_ref" >/dev/null 2>&1 || true
    git -C "$repo_dir" pull --ff-only --tags origin "$repo_ref"
    if git -C "$repo_dir" submodule status >/dev/null 2>&1; then
      git -C "$repo_dir" submodule update --init --recursive
    fi
    return
  fi

  if [[ -e "$repo_dir" ]]; then
    backup_path "$repo_dir"
  fi

  mkdir -p "$(dirname "$repo_dir")"
  log "Cloning $label repo into $repo_dir from $repo_url at ref $repo_ref"
  git clone --branch "$repo_ref" --single-branch "$repo_url" "$repo_dir"
  if git -C "$repo_dir" submodule status >/dev/null 2>&1; then
    git -C "$repo_dir" submodule update --init --recursive
  fi
}

sync_dotfiles_repo() {
  update_or_clone_repo "$DOTFILES_DIR" "$DOTFILES_REPO_URL" "$DOTFILES_REPO_REF" "dotfiles"
}

sync_cli_repo() {
  update_or_clone_repo "$CLI_DIR" "$CLI_REPO_URL" "$CLI_REPO_REF" "CLI"
}

sync_shell_repo() {
  update_or_clone_repo "$SHELL_DIR" "$SHELL_REPO_URL" "$SHELL_REPO_REF" "shell"
}

sync_managed_repos() {
  sync_dotfiles_repo
  sync_cli_repo
  sync_shell_repo
}

repo_version_for_cmake() {
  local repo_dir="$1"
  local version=""
  local commit_count=""

  version="$(git -C "$repo_dir" describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$version" ]]; then
    printf '%s\n' "${version#v}"
    return 0
  fi

  commit_count="$(git -C "$repo_dir" rev-list --count HEAD 2>/dev/null || true)"
  [[ -n "$commit_count" ]] || commit_count="0"

  printf '\033[1;36m:: %s\033[0m\n' \
    "No git tags found in $repo_dir, using fallback version 0.0.$commit_count" >&2
  printf '0.0.%s\n' "$commit_count"
}

install_cli() {
  log "Installing caelestia-cli from source..."
  sync_cli_repo
  remove_stale_caelestia_binary
  remove_stale_cli_python_package

  (
    cd "$CLI_DIR"
    rm -f dist/*.whl
    "$SYSTEM_PYTHON" -m build --wheel --no-isolation
    run_root "$SYSTEM_PYTHON" -m installer dist/*.whl
    run_root install -Dm644 completions/caelestia.fish /usr/share/fish/vendor_completions.d/caelestia.fish
  )
}

install_shell() {
  local version=""
  local revision=""

  log "Installing caelestia-shell from source..."
  sync_shell_repo
  version="$(repo_version_for_cmake "$SHELL_DIR")"
  revision="$(git -C "$SHELL_DIR" rev-parse HEAD)"

  (
    cd "$SHELL_DIR"
    cmake -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/ \
      -DVERSION="$version" \
      -DGIT_REVISION="$revision"
    cmake --build build
    run_root cmake --install build
  )
}

warn_quickshell_default_config() {
  local quickshell_dir="$XDG_CONFIG_HOME/quickshell"
  local default_config="$quickshell_dir/shell.qml"
  local resolved_dir=""
  local resolved_config=""

  if [[ -L "$quickshell_dir" ]]; then
    resolved_dir="$(readlink -f "$quickshell_dir" 2>/dev/null || true)"
    if [[ -n "$resolved_dir" ]]; then
      warn "Detected an existing quickshell config symlink: $quickshell_dir -> $resolved_dir"
    fi
  fi

  if [[ -e "$default_config" ]]; then
    resolved_config="$(readlink -f "$default_config" 2>/dev/null || true)"
    warn "Detected an existing quickshell default config: ${resolved_config:-$default_config}"
    warn "The plain 'quickshell' command will launch that config, not Caelestia."
    warn "Start Caelestia with 'caelestia shell -d' or 'qs -c caelestia'."
  fi
}

install_dotfiles() {
  local hypr_scripts=()

  log "Installing dotfiles..."
  sync_dotfiles_repo

  link_path "$DOTFILES_DIR/hypr" "$XDG_CONFIG_HOME/hypr"
  link_path "$DOTFILES_DIR/foot" "$XDG_CONFIG_HOME/foot"
  link_path "$DOTFILES_DIR/fish" "$XDG_CONFIG_HOME/fish"
  link_path "$DOTFILES_DIR/fastfetch" "$XDG_CONFIG_HOME/fastfetch"
  link_path "$DOTFILES_DIR/uwsm" "$XDG_CONFIG_HOME/uwsm"
  link_path "$DOTFILES_DIR/btop" "$XDG_CONFIG_HOME/btop"
  link_path "$DOTFILES_DIR/starship.toml" "$XDG_CONFIG_HOME/starship.toml"

  shopt -s nullglob
  hypr_scripts=( "$XDG_CONFIG_HOME"/hypr/scripts/*.fish )
  shopt -u nullglob
  if ((${#hypr_scripts[@]} > 0)); then
    chmod u+x "${hypr_scripts[@]}"
  fi

  write_if_missing "$XDG_CONFIG_HOME/caelestia/hypr-vars.conf"
  write_if_missing "$XDG_CONFIG_HOME/caelestia/hypr-user.conf"
}

initialize_caelestia() {
  local wallpaper_dir=""

  log "Running first-time Caelestia initialization..."
  mkdir -p "$XDG_CONFIG_HOME/caelestia" "$XDG_STATE_HOME/caelestia" "$XDG_STATE_HOME/caelestia/wallpaper"
  wallpaper_dir="$(default_wallpaper_dir)"
  mkdir -p "$wallpaper_dir"

  write_text_if_missing "$XDG_CONFIG_HOME/caelestia/shell.json" "{}"
  write_text_if_missing "$XDG_STATE_HOME/caelestia/notifs.json" "[]"
  write_if_missing "$XDG_STATE_HOME/caelestia/wallpaper/path.txt"

  if command -v caelestia >/dev/null 2>&1; then
    if [[ ! -f "$XDG_STATE_HOME/caelestia/scheme.json" ]]; then
      caelestia scheme set -n shadotheme || warn "Failed to create the initial scheme state automatically."
    fi
  else
    warn "The 'caelestia' command is not available yet, skipping scheme initialization."
  fi

  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    if command -v hyprctl >/dev/null 2>&1; then
      hyprctl reload >/dev/null 2>&1 || true
    fi

    if command -v qs >/dev/null 2>&1 && command -v caelestia >/dev/null 2>&1; then
      caelestia shell -d >/dev/null 2>&1 || true
    fi
  fi
}

install_spotify() {
  log "Installing Spotify + Spicetify integration..."
  yay -S "${YAY_INSTALL_ARGS[@]}" spotify spicetify-cli spicetify-marketplace-bin

  run_root chmod a+wr /opt/spotify
  run_root chmod a+wr /opt/spotify/Apps -R

  link_path "$DOTFILES_DIR/spicetify" "$XDG_CONFIG_HOME/spicetify"

  if command -v spicetify >/dev/null 2>&1; then
    spicetify backup apply || true
    spicetify config current_theme caelestia color_scheme caelestia custom_apps marketplace || true
    spicetify apply || true
  fi
}

install_vscode() {
  local variant="$1"
  local program=""
  local folder=""
  local flags_target=""
  local vsix=()

  log "Installing editor integration for $variant..."

  if [[ "$variant" == "code" ]]; then
    run_root pacman -S "${PACMAN_INSTALL_ARGS[@]}" code
    program="code"
    folder="$XDG_CONFIG_HOME/Code/User"
    flags_target="$XDG_CONFIG_HOME/code-flags.conf"
  else
    yay -S "${YAY_INSTALL_ARGS[@]}" vscodium-bin vscodium-bin-marketplace
    program="codium"
    folder="$XDG_CONFIG_HOME/VSCodium/User"
    flags_target="$XDG_CONFIG_HOME/codium-flags.conf"
  fi

  link_path "$DOTFILES_DIR/vscode/settings.json" "$folder/settings.json"
  link_path "$DOTFILES_DIR/vscode/keybindings.json" "$folder/keybindings.json"
  link_path "$DOTFILES_DIR/vscode/flags.conf" "$flags_target"

  shopt -s nullglob
  vsix=( "$DOTFILES_DIR"/vscode/caelestia-vscode-integration/caelestia-vscode-integration-*.vsix )
  shopt -u nullglob

  if ((${#vsix[@]} > 0)) && command -v "$program" >/dev/null 2>&1; then
    "$program" --install-extension "${vsix[0]}" || true
  else
    warn "VSIX extension not found or $program is unavailable. Skipping extension installation."
  fi
}

install_zen() {
  local hosts_dir="$HOME/.mozilla/native-messaging-hosts"
  local lib_dir="$HOME/.local/lib/caelestia"
  local manifest_target="$hosts_dir/caelestiafox.json"
  local profiles=()

  log "Installing Zen Browser integration..."
  yay -S "${YAY_INSTALL_ARGS[@]}" zen-browser-bin

  mkdir -p "$hosts_dir" "$lib_dir"

  if [[ -e "$manifest_target" || -L "$manifest_target" ]]; then
    backup_path "$manifest_target"
  fi

  cp "$DOTFILES_DIR/zen/native_app/manifest.json" "$manifest_target"
  sed -i "s|{{ \$lib }}|$lib_dir|g" "$manifest_target"
  link_path "$DOTFILES_DIR/zen/native_app/app.fish" "$lib_dir/caelestiafox"

  shopt -s nullglob
  profiles=( "$HOME"/.zen/*/chrome )
  shopt -u nullglob

  case "${#profiles[@]}" in
    0)
      warn "Zen profile not found yet. Install or launch Zen once, then link userChrome manually."
      ;;
    1)
      link_path "$DOTFILES_DIR/zen/userChrome.css" "${profiles[0]}/userChrome.css"
      ;;
    *)
      warn "Multiple Zen profiles detected. Link userChrome.css manually to the profile you want."
      ;;
  esac
}

install_discord() {
  log "Installing Discord integration..."
  run_root pacman -S "${PACMAN_INSTALL_ARGS[@]}" discord
  yay -S "${YAY_INSTALL_ARGS[@]}" equicord-installer-bin

  if command -v Equilotl >/dev/null 2>&1; then
    run_root Equilotl -install -location /opt/discord || true
    run_root Equilotl -install-openasar -location /opt/discord || true
  else
    warn "Equilotl was not found after installing equicord-installer-bin."
  fi

  yay -Rns "${PACMAN_REMOVE_ARGS[@]}" equicord-installer-bin || true
}

path_owned_by_package() {
  pacman -Qo "$1" >/dev/null 2>&1
}

remove_unowned_path() {
  local path="$1"
  local owner=""

  [[ -e "$path" || -L "$path" ]] || return 0

  if path_owned_by_package "$path"; then
    owner="$(pacman -Qqo "$path" 2>/dev/null || true)"
    warn "Skipping package-owned path during uninstall: $path${owner:+ (owner: $owner)}"
    return 0
  fi

  run_root rm -rf -- "$path"
  log "Removed $path"
}

remove_link_if_points_to() {
  local target_path="$1"
  local source_path="$2"
  local resolved_target=""
  local resolved_source=""

  [[ -L "$target_path" ]] || return 0

  resolved_target="$(readlink -f "$target_path" 2>/dev/null || true)"
  resolved_source="$(readlink -f "$source_path" 2>/dev/null || true)"

  if [[ -n "$resolved_source" && "$resolved_target" == "$resolved_source" ]]; then
    rm -f -- "$target_path"
    log "Removed managed symlink: $target_path"
  fi
}

uninstall_shell() {
  local manifest="$SHELL_DIR/build/install_manifest.txt"
  local installed_path=""

  [[ -r "$manifest" ]] || {
    warn "Shell install manifest not found at $manifest. Skipping shell uninstall."
    return
  }

  while IFS= read -r installed_path; do
    [[ -n "$installed_path" ]] || continue
    remove_unowned_path "$installed_path"
  done < "$manifest"
}

uninstall_cli() {
  local installed_paths=()
  local installed_path=""

  mapfile -t installed_paths < <(
    "$SYSTEM_PYTHON" - <<'PY'
import importlib.metadata
import sys

try:
    dist = importlib.metadata.distribution("caelestia")
except importlib.metadata.PackageNotFoundError:
    sys.exit(0)

for file in dist.files or []:
    print(dist.locate_file(file))
PY
  )

  for installed_path in "${installed_paths[@]}"; do
    remove_unowned_path "$installed_path"
  done

  remove_unowned_path "/usr/bin/caelestia"
  remove_unowned_path "/usr/share/fish/vendor_completions.d/caelestia.fish"
}

uninstall_dotfiles_links() {
  remove_link_if_points_to "$XDG_CONFIG_HOME/hypr" "$DOTFILES_DIR/hypr"
  remove_link_if_points_to "$XDG_CONFIG_HOME/foot" "$DOTFILES_DIR/foot"
  remove_link_if_points_to "$XDG_CONFIG_HOME/fish" "$DOTFILES_DIR/fish"
  remove_link_if_points_to "$XDG_CONFIG_HOME/fastfetch" "$DOTFILES_DIR/fastfetch"
  remove_link_if_points_to "$XDG_CONFIG_HOME/uwsm" "$DOTFILES_DIR/uwsm"
  remove_link_if_points_to "$XDG_CONFIG_HOME/btop" "$DOTFILES_DIR/btop"
  remove_link_if_points_to "$XDG_CONFIG_HOME/starship.toml" "$DOTFILES_DIR/starship.toml"
}

run_install_command() {
  if ! confirm "Continue with the full installation?"; then
    die "Installation cancelled by user."
  fi

  ensure_yay
  cleanup_old_install_state
  install_packages
  install_cli
  install_shell
  warn_quickshell_default_config
  install_dotfiles
  initialize_caelestia

  $INSTALL_SPOTIFY && install_spotify
  [[ -n "$VSCODE_VARIANT" ]] && install_vscode "$VSCODE_VARIANT"
  $INSTALL_ZEN && install_zen
  $INSTALL_DISCORD && install_discord
}

run_deps_command() {
  if ! confirm "Install package dependencies now?"; then
    die "Dependency installation cancelled by user."
  fi

  ensure_yay
  cleanup_old_install_state
  install_packages
}

run_repos_command() {
  if ! confirm "Clone or update the managed repositories now?"; then
    die "Repository sync cancelled by user."
  fi

  sync_managed_repos
}

run_build_command() {
  if ! confirm "Build and install the CLI and shell now?"; then
    die "Build cancelled by user."
  fi

  install_cli
  install_shell
}

run_link_command() {
  if ! confirm "Link managed dotfiles now?"; then
    die "Link step cancelled by user."
  fi

  warn_quickshell_default_config
  install_dotfiles
}

run_init_command() {
  if ! confirm "Initialize first-run Caelestia state now?"; then
    die "Initialization cancelled by user."
  fi

  initialize_caelestia
}

run_uninstall_command() {
  if ! confirm "Run a best-effort uninstall of files installed by this script?"; then
    die "Uninstall cancelled by user."
  fi

  uninstall_shell
  uninstall_cli
  uninstall_dotfiles_links
}

diagnose_repo() {
  local label="$1"
  local repo_dir="$2"

  printf '\n[%s]\n' "$label"
  printf '  dir: %s\n' "$repo_dir"

  if [[ -e "$repo_dir" ]] && git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  origin: %s\n' "$(git -C "$repo_dir" remote get-url origin 2>/dev/null || printf 'n/a')"
    printf '  branch: %s\n' "$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
    printf '  head: %s\n' "$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || printf 'n/a')"
    printf '  status: %s\n' "$(git -C "$repo_dir" status --short --branch | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  else
    printf '  status: missing or not a git repo\n'
  fi
}

run_diagnose_command() {
  printf 'Caelestia installer diagnostics\n'
  printf '  subcommand: %s\n' "$SUBCOMMAND"
  printf '  repo owner: %s\n' "$REPO_OWNER"
  printf '  system python: %s\n' "$SYSTEM_PYTHON"
  printf '  os id: %s\n' "$OS_ID"
  printf '  dotfiles repo: %s @ %s\n' "$DOTFILES_REPO_URL" "$DOTFILES_REPO_REF"
  printf '  cli repo: %s @ %s\n' "$CLI_REPO_URL" "$CLI_REPO_REF"
  printf '  shell repo: %s @ %s\n' "$SHELL_REPO_URL" "$SHELL_REPO_REF"
  printf '  dotfiles dir: %s\n' "$DOTFILES_DIR"
  printf '  cli dir: %s\n' "$CLI_DIR"
  printf '  shell dir: %s\n' "$SHELL_DIR"
  printf '\n'
  printf 'Commands:\n'
  printf '  sudo: %s\n' "$(command -v sudo 2>/dev/null || printf 'missing')"
  printf '  git: %s\n' "$(command -v git 2>/dev/null || printf 'missing')"
  printf '  pacman: %s\n' "$(command -v pacman 2>/dev/null || printf 'missing')"
  printf '  yay: %s\n' "$(command -v yay 2>/dev/null || printf 'missing')"
  printf '  cmake: %s\n' "$(command -v cmake 2>/dev/null || printf 'missing')"
  printf '  python: %s\n' "$(command -v "$SYSTEM_PYTHON" 2>/dev/null || printf 'missing')"

  diagnose_repo "dotfiles" "$DOTFILES_DIR"
  diagnose_repo "cli" "$CLI_DIR"
  diagnose_repo "shell" "$SHELL_DIR"
}

print_summary() {
  cat <<EOF

Operation complete.

Next recommended steps:
  1. If you use a login manager, configure and enable it separately
  2. Log into hyprland
  3. Run 'nwg-displays' and set your monitor layout

If any existing config paths were replaced, backups are in:
  ${BACKUP_DIR:-No backups were needed}
EOF
}

main() {
  parse_args "$@"
  ensure_not_root
  require_supported_os
  load_package_lists
  trap cleanup EXIT INT TERM
  acquire_lock

  run_preflight

  if [[ "$SUBCOMMAND" == "check" ]]; then
    return
  fi

  choose_confirmation_mode
  setup_package_args
  export PACMAN_AUTH="${PACMAN_AUTH:-sudo}"

  if subcommand_needs_sudo "$SUBCOMMAND"; then
    ensure_sudo
  fi

  case "$SUBCOMMAND" in
    install)
      run_install_command
      print_summary
      ;;
    deps)
      run_deps_command
      print_summary
      ;;
    repos)
      run_repos_command
      print_summary
      ;;
    build)
      run_build_command
      print_summary
      ;;
    link)
      run_link_command
      print_summary
      ;;
    init)
      run_init_command
      print_summary
      ;;
    diagnose)
      run_diagnose_command
      ;;
    uninstall)
      run_uninstall_command
      print_summary
      ;;
    *)
      die "Unhandled subcommand: $SUBCOMMAND"
      ;;
  esac
}

main "$@"
