# decky-installer <img src="https://img.shields.io/github/downloads/SteamDeckHomebrew/decky-installer/total"/>

Installer for [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader).

## Quick start

```bash
curl -L https://github.com/SteamDeckHomebrew/decky-installer/raw/main/decky-installer.sh | bash
```

Or download and run manually:

```bash
curl -LO https://github.com/SteamDeckHomebrew/decky-installer/raw/main/decky-installer.sh
chmod +x decky-installer.sh
./decky-installer.sh
```

Running without arguments in an interactive terminal opens a menu. On a desktop with Zenity installed, a GUI progress window is shown automatically.

## Commands

```
decky-installer.sh [command] [args]
```

| Command | Args | Description |
|---|---|---|
| `install` | `[version]` | Install latest stable, or a specific version (e.g. `v3.2.6`) |
| `uninstall` | — | Export a backup, then remove Decky and all data |
| `rollback` | `[version]` | Switch to a previously archived version |
| `cleanup` | `[keep]` | Delete old archived versions; keep the N newest (default: 3) |
| `export` | — | Archive plugins and settings to `~/Downloads/decky-export-<timestamp>.tar.gz` |
| `import` | `<archive> <strategy>` | Restore from an export archive |
| `doctor` | — | Run health checks on an existing installation |
| `help` | — | Show usage |

Each command also accepts `help` as its first argument for per-command usage details.

### Import strategies

| Strategy | Behaviour |
|---|---|
| `backup-wipe-import` | Export current data, wipe user-facing content, then extract the archive |
| `merge-overwrite` | Extract the archive on top of existing data |

## Environment variables

| Variable | Description |
|---|---|
| `DECKY_LOADER_RELEASE_TYPE=prerelease` | Target the prerelease channel instead of stable |
| `GITHUB_TOKEN=<token>` | Authenticate GitHub API calls (raises rate limit from 60 to 5000 req/hr) |
| `HOMEBREW_FOLDER=<path>` | Override the install location (default: `~/homebrew`). Useful for SD card installs. |
| `DECKY_CLEANUP_KEEP=<n>` | Default number of archived versions `cleanup` retains (default: `3`). Can be overridden per-run by passing the argument directly. |
| `NO_COLOR=1` | Disable all colored output, regardless of TTY state. |

## How to install manually

### 1. Preflight

The invoking user must have `sudo` access — either with a password or via `NOPASSWD` in the sudoers file.

### 2. Directory setup

Create the required directory structure:

```shell
# create all three directories at once
mkdir -p ~/homebrew/plugins ~/homebrew/services ~/homebrew/archive/

# services/ must be root
sudo chown -R root: ~/homebrew/services
```

- `plugins/` — user plugins, owned by the user
- `services/` — active PluginLoader binary and unit, owned by root
- `archive/` — versioned snapshots for rollback

### 3. Artifacts

Download the following for your target version (e.g. `v3.2.6`) from the [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader/):

- [PluginLoader](https://github.com/SteamDeckHomebrew/decky-loader/releases) — the binary
- [plugin_loader-release.service](https://github.com/SteamDeckHomebrew/decky-loader/blob/main/dist/plugin_loader-release.service) — the systemd unit

Also create a `.loader.version` file containing the version tag:

```shell
# the installer reads this file to know which version is active
printf 'v3.2.6' > ~/homebrew/archive/v3.2.6/.loader.version
```

Store all three files in `~/homebrew/archive/<version>/`.

### 4. Create plugin_loader.service

Replace the `${HOMEBREW_FOLDER}` placeholder with the absolute path to your homebrew folder:

```shell
# expand the placeholder and write directly to the systemd unit directory
sed "s|\${HOMEBREW_FOLDER}|${HOME}/homebrew|g" \
  ~/homebrew/archive/v3.2.6/plugin_loader-release.service \
  | sudo tee /etc/systemd/system/plugin_loader.service
```

### 5. Service deployment

```shell
# stop gracefully if already running; ignore error if not installed yet
sudo systemctl stop plugin_loader 2>/dev/null || true

# copy binary and version marker into the active services directory
sudo cp ~/homebrew/archive/v3.2.6/PluginLoader ~/homebrew/services/PluginLoader
sudo chmod +x ~/homebrew/services/PluginLoader
sudo cp ~/homebrew/archive/v3.2.6/.loader.version ~/homebrew/services/.loader.version

# pick up the newly installed unit file
sudo systemctl daemon-reload

# enable so it starts on boot, and start it immediately
sudo systemctl enable --now plugin_loader
```

## DeckyLoader Doctor

`doctor` is a standalone diagnostic tool — run it any time to check an existing installation. It verifies:

- PluginLoader binary exists and is executable
- Installed version is detected
- Plugins directory exists
- CEF remote debugging file is in place
- systemd unit is installed, enabled, and active
- PluginLoader process is running
- Ports 1337 (backend) and 8080 (Steam CEF debugger) are listening
- Backend responds on `http://127.0.0.1:1337`
- Recent `journalctl` output from the service

## Export and import

`export` creates a `tar.gz` of `~/homebrew/` excluding `services/` and `archive/`, preserving plugins, settings, and other user-facing data.

`import` extracts that archive back into `~/homebrew/`, with an optional wipe-first step to start clean.
