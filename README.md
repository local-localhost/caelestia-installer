# caelestia-installer

the best caelestia dotfiles installer with improvements in shell(example - more fixes than original shell and dotfiles, improvements for nvidia, more configurable)

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
uninstall   Best-effort uninstall of files installed by this script
```

## Options

```text
-h, --help
--spotify
--discord
--zen
--vscode code
--vscode codium
```