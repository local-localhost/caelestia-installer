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

Installer have 2 choice:

- Manual confirmations
- Automatic mode


## Optional components

```sh
bash install.sh --spotify --vscode codium --discord --zen
```

## Subcommands

```text
install     Full install flow
check       Preflight checks only
deps        Install package dependencies only
repos       Clone or update managed repositories only
build       Build and install the CLI and shell only
link        Link managed dotfiles only
init        Initialize first-run state only
diagnose    Print installer diagnostics
uninstall   Best-effort uninstall of files installed by this script
```

Examples:

```sh
bash install.sh check
bash install.sh repos
bash install.sh build
bash install.sh link
bash install.sh init
```

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