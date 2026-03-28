#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/pkg"

REPO_OWNER="${REPO_OWNER:-local-localhost}"
GITHUB_REPO_BASE="https://github.com/$REPO_OWNER"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$XDG_STATE_HOME/caelestia-installer"

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.local/share/caelestia}"
CLI_DIR="${CLI_DIR:-$HOME/.local/share/caelestia-cli}"
SHELL_DIR="${SHELL_DIR:-$XDG_CONFIG_HOME/quickshell/caelestia}"

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-$GITHUB_REPO_BASE/caelestia.git}"
CLI_REPO_URL="${CLI_REPO_URL:-$GITHUB_REPO_BASE/cli.git}"
SHELL_REPO_URL="${SHELL_REPO_URL:-$GITHUB_REPO_BASE/shell.git}"

YES=false
INSTALL_SPOTIFY=false
INSTALL_DISCORD=false
INSTALL_ZEN=false
VSCODE_VARIANT=""

PACMAN_ARGS=(--needed)
PACMAN_REMOVE_ARGS=()
YAY_ARGS=(--needed)
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
Usage: $SCRIPT_NAME [options]

Installer for Caelestia dotfiles

Options:
  -h, --help            Show this help text
  -y, --yes             Non-interactive mode where possible
  --spotify             Install Spotify + Spicetify integration
  --discord             Install Discord + OpenAsar + Equicord
  --zen                 Install Zen Browser integration
  --vscode <variant>    Install editor integration. Variant: code | codium


Examples:
  ./$SCRIPT_NAME
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

run_root() {
  sudo "$@"
}

cleanup() {
  local tmp_dir=""

  if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi

  for tmp_dir in "${TEMP_DIRS[@]}"; do
    [[ -n "$tmp_dir" && -e "$tmp_dir" ]] && rm -rf -- "$tmp_dir"
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

register_temp_dir() {
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
    PACMAN_ARGS+=(--noconfirm)
    PACMAN_REMOVE_ARGS+=(--noconfirm)
    YAY_ARGS+=(
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
  source /etc/os-release

  OS_ID="${ID:-}"
  case "$OS_ID" in
    arch|cachyos)
      ;;
    *)
      die "Unsupported distribution: ${OS_ID:-unknown}. This installer support only Arch Linux."
      ;;
  esac
}

ensure_not_root() {
  [[ "$EUID" -ne 0 ]] || die "Run this installer as a regular user, not as root."
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
    run_root pacman -S "${PACMAN_ARGS[@]}" yay
    return
  fi

  run_root pacman -S "${PACMAN_ARGS[@]}" git base-devel

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  register_temp_dir "$tmp_dir"

  git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp_dir/yay"
  (
    cd "$tmp_dir/yay"
    makepkg -si "${MAKEPKG_ARGS[@]}"
  )
  rm -rf -- "$tmp_dir"
}

remove_quickshell_git() {
  if ! pacman -Q quickshell-git >/dev/null 2>&1; then
    return
  fi

  warn "Removing 'quickshell-git' so stable 'quickshell' can be installed."
  run_root pacman -Rns "${PACMAN_REMOVE_ARGS[@]}" quickshell-git
}

install_packages() {
  remove_quickshell_git

  log "Installing official repository packages..."
  run_root pacman -S "${PACMAN_ARGS[@]}" "${PACMAN_PACKAGES[@]}"

  log "Installing AUR packages..."
  yay -S "${YAY_ARGS[@]}" "${AUR_PACKAGES[@]}"
}

remove_conflicting_packages() {
  local conflicts=()
  local pkg=""

  for pkg in caelestia-meta caelestia-cli caelestia-cli-git caelestia-shell caelestia-shell-git; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      conflicts+=("$pkg")
    fi
  done

  if ((${#conflicts[@]} == 0)); then
    return
  fi

  warn "Detected conflicting packaged Caelestia installs: ${conflicts[*]}"

  if confirm "Remove conflicting packaged versions before installing from source?"; then
    run_root pacman -Rns "${PACMAN_REMOVE_ARGS[@]}" "${conflicts[@]}"
  else
    die "Conflicting packaged Caelestia versions must be removed before continuing."
  fi
}

remove_stale_caelestia_binary() {
  local owner=""

  [[ -e /usr/bin/caelestia ]] || return

  if pacman -Qo /usr/bin/caelestia >/dev/null 2>&1; then
    owner="$(pacman -Qo /usr/bin/caelestia 2>/dev/null | awk '{print $5}')"
    die "/usr/bin/caelestia is owned by package '$owner'. Remove the conflicting package first and rerun the installer."
  fi

  warn "Removing unowned stale binary: /usr/bin/caelestia"
  run_root rm -f /usr/bin/caelestia
}

update_or_clone_repo() {
  local repo_dir="$1"
  local repo_url="$2"
  local label="$3"
  local origin_url=""
  local branch=""

  if [[ -e "$repo_dir" ]] && git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"

    if [[ "$origin_url" != "$repo_url" ]]; then
      warn "$label repo at $repo_dir has a different origin: $origin_url"
      warn "Using the existing checkout without changing its remote."
      return
    fi

    if [[ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
      warn "$label repo has local changes, skipping git pull: $repo_dir"
      return
    fi

    branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || true)"
    if [[ -z "$branch" ]]; then
      warn "$label repo is not on a branch, skipping git pull: $repo_dir"
      return
    fi

    log "Updating $label repo in $repo_dir"
    git -C "$repo_dir" fetch --tags --prune origin
    git -C "$repo_dir" pull --ff-only --tags origin "$branch"
    if git -C "$repo_dir" submodule status >/dev/null 2>&1; then
      git -C "$repo_dir" submodule update --init --recursive
    fi
    return
  fi

  if [[ -e "$repo_dir" ]]; then
    backup_path "$repo_dir"
  fi

  mkdir -p "$(dirname "$repo_dir")"
  log "Cloning $label repo into $repo_dir"
  git clone "$repo_url" "$repo_dir"
  if git -C "$repo_dir" submodule status >/dev/null 2>&1; then
    git -C "$repo_dir" submodule update --init --recursive
  fi
}

install_cli() {
  log "Installing caelestia-cli from source..."
  update_or_clone_repo "$CLI_DIR" "$CLI_REPO_URL" "CLI"
  remove_stale_caelestia_binary

  (
    cd "$CLI_DIR"
    rm -f dist/*.whl
    python -m build --wheel --no-isolation
    run_root python -m installer dist/*.whl
    run_root install -Dm644 completions/caelestia.fish /usr/share/fish/vendor_completions.d/caelestia.fish
  )
}

install_shell() {
  log "Installing caelestia-shell from source..."
  update_or_clone_repo "$SHELL_DIR" "$SHELL_REPO_URL" "shell"

  (
    cd "$SHELL_DIR"
    cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/
    cmake --build build
    run_root cmake --install build
  )
}

install_dotfiles() {
  log "Installing dotfiles..."
  update_or_clone_repo "$DOTFILES_DIR" "$DOTFILES_REPO_URL" "dotfiles"

  link_path "$DOTFILES_DIR/hypr" "$XDG_CONFIG_HOME/hypr"
  link_path "$DOTFILES_DIR/foot" "$XDG_CONFIG_HOME/foot"
  link_path "$DOTFILES_DIR/fish" "$XDG_CONFIG_HOME/fish"
  link_path "$DOTFILES_DIR/fastfetch" "$XDG_CONFIG_HOME/fastfetch"
  link_path "$DOTFILES_DIR/uwsm" "$XDG_CONFIG_HOME/uwsm"
  link_path "$DOTFILES_DIR/btop" "$XDG_CONFIG_HOME/btop"
  link_path "$DOTFILES_DIR/starship.toml" "$XDG_CONFIG_HOME/starship.toml"

  chmod u+x "$XDG_CONFIG_HOME/hypr/scripts/"*.fish

  write_if_missing "$XDG_CONFIG_HOME/caelestia/hypr-vars.conf"
  write_if_missing "$XDG_CONFIG_HOME/caelestia/hypr-user.conf"
}

initialize_caelestia() {
  log "Running first-time Caelestia initialization..."
  mkdir -p "$XDG_STATE_HOME/caelestia"

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
  yay -S "${YAY_ARGS[@]}" spotify spicetify-cli spicetify-marketplace-bin

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
    run_root pacman -S "${PACMAN_ARGS[@]}" code
    program="code"
    folder="$XDG_CONFIG_HOME/Code/User"
    flags_target="$XDG_CONFIG_HOME/code-flags.conf"
  else
    yay -S "${YAY_ARGS[@]}" vscodium-bin vscodium-bin-marketplace
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
  yay -S "${YAY_ARGS[@]}" zen-browser-bin

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
  run_root pacman -S "${PACMAN_ARGS[@]}" discord
  yay -S "${YAY_ARGS[@]}" equicord-installer-bin

  if command -v Equilotl >/dev/null 2>&1; then
    run_root Equilotl -install -location /opt/discord || true
    run_root Equilotl -install-openasar -location /opt/discord || true
  else
    warn "Equilotl was not found after installing equicord-installer-bin."
  fi

  yay -Rns "${PACMAN_REMOVE_ARGS[@]}" equicord-installer-bin || true
}

print_summary() {
  cat <<EOF

Installation complete.

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
  load_package_lists
  setup_package_args
  require_supported_os
  trap cleanup EXIT INT TERM
  export PACMAN_AUTH="${PACMAN_AUTH:-sudo}"
  ensure_sudo
  acquire_lock

  log "Preparing installation for $OS_ID"

  if ! confirm "Continue with the installation?"; then
    die "Installation cancelled by user."
  fi

  ensure_yay
  remove_conflicting_packages
  install_packages
  install_cli
  install_shell
  install_dotfiles
  initialize_caelestia

  $INSTALL_SPOTIFY && install_spotify
  [[ -n "$VSCODE_VARIANT" ]] && install_vscode "$VSCODE_VARIANT"
  $INSTALL_ZEN && install_zen
  $INSTALL_DISCORD && install_discord

  print_summary
}

main "$@"
