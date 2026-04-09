# caelestia-installer

Official installer for the full Caelestia setup. This is the supported
end-to-end installation path for the dotfiles, CLI, and shell.

## Supported systems

- Arch Linux
- CachyOS

## Quick start

```sh
git clone https://github.com/local-localhost/caelestia-installer.git
cd caelestia-installer
bash install.sh
```

## Non-interactive install

```sh
bash install.sh -y
```

## Optional components

```sh
bash install.sh -y --spotify --vscode codium --discord --zen
```

## What it manages

- Clones or updates the managed `caelestia`, `cli`, and `shell` repositories
- Installs required packages
- Builds and installs the CLI and shell from source
- Symlinks the dotfiles into XDG-aware locations
- Initializes first-run Caelestia state files

By default the managed checkouts live in:

- `DOTFILES_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/caelestia`
- `CLI_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-cli`
- `SHELL_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia`

All of those locations can be overridden through environment variables before
running the installer.

## Options

```text
-h, --help
-y, --yes
--spotify
--discord
--zen
--vscode code
--vscode codium
```
