# simple caelestia-installer


## Installation

```sh
git clone https://github.com/local-localhost/caelestia-installer.git
cd caelestia-installer
chmod +x install.sh
./install.sh
```

## without confirm

```sh
./install.sh -y
```

## Optional integrations

```sh
./install.sh -y --spotify --vscode codium --discord --zen
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

## Notes

- Existing config paths are backed up to `~/.local/state/caelestia-installer/backups/<timestamp>/`.
- After installation, run `nwg-displays` and set your monitor layout.